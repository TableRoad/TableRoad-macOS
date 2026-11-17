import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import TableRoadCore
import TableRoadSQL

/// A MySQL or MariaDB connection.
public actor MySQLSession: SQLClient {
    public let kind: DatabaseKind
    public let serverVersion: String
    public private(set) var currentDatabase: String?
    public nonisolated let dialect: MySQLDialect
    /// Whether the session is TLS-encrypted (shown as a padlock in the workspace).
    public nonisolated let isEncrypted: Bool
    /// Negotiated TLS cipher, e.g. `TLS_AES_256_GCM_SHA384`; nil when unencrypted.
    public nonisolated let tlsCipher: String?
    /// Login user (for the connection info popover).
    public nonisolated var username: String { config.username }
    public nonisolated var sqlDialect: any SQLDialect { dialect }
    public nonisolated var capabilities: ClientCapabilities {
        ClientCapabilities(processList: true, createDatabases: true)
    }
    public nonisolated var host: String { config.host }

    private let connection: MySQLConnection
    private let config: MySQLConnectConfig
    private let usedTLS: Bool
    /// Server-side thread ID, used by `KILL QUERY` from a second connection.
    private let threadID: UInt64
    private let lock = AsyncSerialLock()
    private static let logger = Logger(label: "TableRoad.MySQL")

    private init(
        connection: MySQLConnection, config: MySQLConnectConfig, cipher: String?, version: String, threadID: UInt64,
        database: String?, sqlMode: String
    ) {
        self.connection = connection
        self.config = config
        self.usedTLS = cipher != nil
        self.isEncrypted = cipher != nil
        self.tlsCipher = cipher
        self.serverVersion = version
        self.threadID = threadID
        self.currentDatabase = database
        let isMariaDB = version.localizedCaseInsensitiveContains("mariadb")
        self.kind = isMariaDB ? .mariadb : .mysql
        // sql_mode is read once at connect; a later `SET sql_mode` in the editor won't be reflected here.
        self.dialect = MySQLDialect(
            flavor: isMariaDB ? .mariadb : .mysql,
            backslashEscapes: !sqlMode.uppercased().contains("NO_BACKSLASH_ESCAPES"))
    }

    /// mysql-nio asserts if a connection is released while open (e.g. a window closed mid-query or an error path
    /// that skipped `close()`), so the session always closes its own connection on the way out.
    deinit {
        guard !connection.isClosed else { return }
        // Keep the connection alive until the close completes, or its own deinit assertion fires first.
        let connection = connection
        connection.close().whenComplete { _ in withExtendedLifetime(connection) {} }
    }

    // MARK: - Connecting

    public static func connect(_ config: MySQLConnectConfig) async throws -> MySQLSession {
        let (connection, cipher) = try await openConnection(config)
        do {
            if let bootstrap = config.bootstrapSQL {
                for statement in StatementSplitter(syntax: .mysql).split(bootstrap) {
                    do {
                        _ = try await connection.simpleQuery(statement.text).get()
                    } catch {
                        throw DatabaseError(
                            .query, "Bootstrap command failed (\(statement.text)): \(mapError(error).message)",
                            code: mapError(error).code)
                    }
                }
            }
            let rows = try await connection.simpleQuery(
                "SELECT VERSION(), CONNECTION_ID(), DATABASE(), @@SESSION.sql_mode"
            ).get()
            let values = rows.first.map { row in row.values.map { $0.flatMap { String(buffer: $0) } } } ?? []
            return MySQLSession(
                connection: connection, config: config, cipher: cipher,
                version: values.first.flatMap { $0 } ?? "unknown",
                threadID: values.dropFirst().first.flatMap { $0.flatMap(UInt64.init) } ?? 0,
                database: values.dropFirst(2).first.flatMap { $0 },
                sqlMode: values.dropFirst(3).first.flatMap { $0 } ?? ""
            )
        } catch {
            try? await connection.close().get()
            throw mapError(error)
        }
    }

    /// Opens the wire connection, honouring the TLS mode. `prefer` falls back to plain text.
    static func openConnection(_ config: MySQLConnectConfig, forceTLS: Bool? = nil) async throws -> (
        MySQLConnection, String?
    ) {
        let address: SocketAddress
        do {
            address = try await resolve(config.host, port: config.port)
        } catch {
            throw DatabaseError(.connection, "Couldn't resolve \(config.host): \(error.localizedDescription)")
        }

        func attempt(tls: TLSConfiguration?) async throws -> MySQLConnection {
            try await MySQLConnection.connect(
                to: address,
                username: config.username,
                database: config.database ?? "",
                password: config.password,
                tlsConfiguration: tls,
                // SNI must be a hostname; sending an IP literal makes the handshake fail.
                serverHostname: tls == nil || isIPAddress(config.host) ? nil : config.host,
                logger: logger,
                on: MultiThreadedEventLoopGroup.singleton.any()
            ).get()
        }

        let mode = forceTLS.map { $0 ? TLSMode.require : .disable } ?? config.tls
        let tls = try makeTLSConfiguration(mode: mode, files: config.tlsFiles)

        let connection = try await mapErrors { try await attempt(tls: tls) }
        guard tls != nil else { return (connection, nil) }

        // mysql-nio silently continues in plain text when the server doesn't advertise SSL,
        // so ask the server whether this session is actually encrypted.
        // TODO(Phase 3 hardening): patch mysql-nio to fail the handshake instead; a status query
        // catches misconfigured servers but not an active downgrade attack.
        let cipher: String?
        do {
            let rows = try await connection.simpleQuery("SHOW SESSION STATUS LIKE 'Ssl_cipher'").get()
            let value = rows.first?.values.dropFirst().first.flatMap { $0.map { String(buffer: $0) } } ?? ""
            cipher = value.isEmpty ? nil : value
        } catch {
            try? await connection.close().get()
            throw mapError(error)
        }
        if cipher == nil && mode != .prefer {
            try? await connection.close().get()
            throw DatabaseError(.tls, "The server doesn't support TLS, but this connection requires it.")
        }
        return (connection, cipher)
    }

    /// TLS settings for a mode (MySQL `ssl-mode` semantics) plus optional client certificate files.
    static func makeTLSConfiguration(mode: TLSMode, files: TLSFiles) throws -> TLSConfiguration? {
        guard mode != .disable else { return nil }
        var tls = TLSConfiguration.makeClientConfiguration()
        switch mode {
        case .disable: return nil
        case .prefer, .require: tls.certificateVerification = .none
        case .verifyCA: tls.certificateVerification = .noHostnameVerification
        case .verifyFull: tls.certificateVerification = .fullVerification
        }
        func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
        do {
            if let ca = files.caCertPath {
                tls.trustRoots = .file(expand(ca))
            }
            if let cert = files.clientCertPath {
                tls.certificateChain = try NIOSSLCertificate.fromPEMFile(expand(cert)).map { .certificate($0) }
            }
            if let key = files.clientKeyPath {
                tls.privateKey = .file(expand(key))
            }
        } catch {
            throw DatabaseError(.tls, "Couldn't read a TLS certificate file: \(error)")
        }
        return tls
    }

    static func isIPAddress(_ host: String) -> Bool {
        (try? SocketAddress(ipAddress: host, port: 0)) != nil
    }

    static func resolve(_ host: String, port: Int) async throws -> SocketAddress {
        try await Task.detached { try SocketAddress.makeAddressResolvingHost(host, port: port) }.value
    }

    public func close() async {
        try? await connection.close().get()
    }

    // MARK: - Statements

    public func execute(_ sql: String) async throws -> QueryOutcome {
        try await lock.run { try await self.executeLocked(sql) }
    }

    private func executeLocked(_ sql: String) async throws -> QueryOutcome {
        let rows: [MySQLRow]
        do {
            rows = try await connection.simpleQuery(sql).get()
        } catch {
            throw Self.mapError(error)
        }
        try await refreshCurrentDatabaseIfNeeded(after: sql)

        if let first = rows.first {
            let columns = first.columnDefinitions.map {
                ResultColumn(
                    name: $0.name, table: $0.orgTable.isEmpty ? nil : $0.orgTable,
                    typeName: MySQLValueDecoder.typeName($0))
            }
            let decoded = rows.map { row in
                zip(row.values, row.columnDefinitions).map { MySQLValueDecoder.decode($0, column: $1) }
            }
            return .rows(ResultSet(columns: columns, rows: decoded))
        }
        if Self.returnsRows(sql) {
            // mysql-nio's text protocol drops column metadata for empty results.
            return .rows(.empty)
        }
        // mysql-nio's text protocol doesn't expose the OK packet; ROW_COUNT() reports the previous statement.
        let count = try await connection.simpleQuery("SELECT ROW_COUNT()").get()
        let affected = count.first?.values.first.flatMap { $0.flatMap { Int64(String(buffer: $0)) } } ?? 0
        return .affected(rowCount: UInt64(max(affected, 0)))
    }

    /// Heuristic for statements that produce a result set even when empty.
    static func returnsRows(_ sql: String) -> Bool {
        let keyword = sql.drop { !$0.isLetter }.prefix { $0.isLetter }.uppercased()
        return [
            "SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "WITH", "VALUES", "TABLE", "CALL", "HELP", "CHECK",
            "ANALYZE",
        ]
        .contains(keyword)
    }

    private func refreshCurrentDatabaseIfNeeded(after sql: String) async throws {
        let keyword = sql.drop { !$0.isLetter }.prefix { $0.isLetter }.uppercased()
        guard keyword == "USE" || keyword == "DROP" else { return }
        let rows = try await connection.simpleQuery("SELECT DATABASE()").get()
        currentDatabase = rows.first?.values.first.flatMap { $0.flatMap { String(buffer: $0) } }
    }

    /// Runs a statement and discards any result (bulk work like importing a dump: no ROW_COUNT() round trip).
    public func run(_ sql: String) async throws {
        try await lock.run {
            do {
                _ = try await self.connection.simpleQuery(sql).get()
            } catch {
                throw Self.mapError(error)
            }
            try await self.refreshCurrentDatabaseIfNeeded(after: sql)
        }
    }

    public func executeTransaction(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        try await lock.run { try await self.executeTransactionLocked(statements) }
    }

    private func executeTransactionLocked(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        do {
            _ = try await connection.simpleQuery("START TRANSACTION").get()
        } catch {
            throw TransactionError(statementIndex: 0, underlying: Self.mapError(error))
        }
        var affected: [UInt64] = []
        for (index, statement) in statements.enumerated() {
            do {
                let binds = statement.parameters.map { parameter -> MySQLData in
                    switch parameter {
                    case .text(let value): MySQLData(string: value)
                    case .null: MySQLData.null
                    }
                }
                nonisolated(unsafe) var rows: UInt64 = 0
                _ = try await connection.query(statement.sql, binds, onMetadata: { rows = $0.affectedRows }).get()
                affected.append(rows)
            } catch {
                _ = try? await connection.simpleQuery("ROLLBACK").get()
                throw TransactionError(statementIndex: index, underlying: Self.mapError(error))
            }
        }
        do {
            _ = try await connection.simpleQuery("COMMIT").get()
        } catch {
            let mapped = Self.mapError(error)
            if mapped.category == .connection {
                // COMMIT may have reached the server before the connection died: the outcome is unknown.
                throw TransactionError(
                    statementIndex: statements.count, underlying: mapped, commitOutcomeUnknown: true)
            }
            _ = try? await connection.simpleQuery("ROLLBACK").get()
            throw TransactionError(statementIndex: statements.count, underlying: mapped)
        }
        return affected
    }

    /// Opens a short-lived second connection and kills the running statement (not the connection).
    public func cancelCurrentQuery() async throws {
        let (killer, _) = try await Self.openConnection(config, forceTLS: usedTLS)
        defer { Task { try? await killer.close().get() } }
        do {
            _ = try await killer.simpleQuery("KILL QUERY \(threadID)").get()
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Processes

    public nonisolated var processID: UInt64 { threadID }

    /// Without the PROCESS privilege the server only returns the user's own connections.
    public func processList() async throws -> [ServerProcess] {
        try await lock.run {
            let rows: [MySQLRow]
            do {
                rows = try await self.connection.simpleQuery("SHOW FULL PROCESSLIST").get()
            } catch {
                throw Self.mapError(error)
            }
            return rows.compactMap { row -> ServerProcess? in
                func text(_ name: String) -> String? {
                    guard let index = row.columnDefinitions.firstIndex(where: { $0.name.lowercased() == name }) else {
                        return nil
                    }
                    return row.values[index].map { String(buffer: $0) }
                }
                guard let id = text("id").flatMap(UInt64.init) else { return nil }
                return ServerProcess(
                    id: id, user: text("user") ?? "", host: text("host") ?? "", database: text("db"),
                    command: text("command") ?? "", seconds: text("time").flatMap { Int($0) } ?? 0,
                    state: text("state").flatMap { $0.isEmpty ? nil : $0 }, info: text("info"))
            }
        }
    }

    public func kill(processID: UInt64, connection: Bool) async throws {
        _ = try await execute(connection ? "KILL \(processID)" : "KILL QUERY \(processID)")
    }

    // MARK: - Introspection

    public func useDatabase(_ name: String) async throws {
        _ = try await execute("USE \(dialect.quoteIdentifier(name))")
        currentDatabase = name
    }

    public func databases() async throws -> [String] {
        try await strings("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME")
    }

    public func tables(in database: String) async throws -> [TableInfo] {
        let sql = """
            SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(dialect.stringLiteral(database)) ORDER BY TABLE_NAME
            """
        return try await textRows(sql).map { row in
            let kind: TableInfo.Kind =
                switch row[1] {
                case "VIEW": .view
                case "SYSTEM VIEW": .systemView
                default: .table
                }
            return TableInfo(name: row[0] ?? "", kind: kind, estimatedRowCount: row[2].flatMap { Int($0) })
        }
    }

    public func columns(of table: String, in database: String) async throws -> [ColumnDetail] {
        let sql = """
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT,
                CHARACTER_SET_NAME, COLLATION_NAME
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(dialect.stringLiteral(database)) AND TABLE_NAME = \(dialect.stringLiteral(table))
            ORDER BY ORDINAL_POSITION
            """
        return try await textRows(sql).map { row in
            ColumnDetail(
                name: row[0] ?? "", type: row[1] ?? "", isNullable: row[2] == "YES", isPrimaryKey: row[3] == "PRI",
                defaultValue: row[4], extra: row[5].flatMap { $0.isEmpty ? nil : $0 },
                comment: row[6].flatMap { $0.isEmpty ? nil : $0 }, characterSet: row[7], collation: row[8])
        }
    }

    public func tableStatus(of table: String, in database: String) async throws -> TableStatus {
        let sql = """
            SELECT TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, DATA_FREE, AUTO_INCREMENT, ENGINE, TABLE_COLLATION,
                CREATE_TIME, UPDATE_TIME, TABLE_COMMENT
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(dialect.stringLiteral(database)) AND TABLE_NAME = \(dialect.stringLiteral(table))
            """
        let rows = try await lock.run {
            // MySQL 8 caches these statistics for a day by default, so a table that grew since then would report
            // a stale (often zero) estimate. Ask for live values for this one query. MariaDB is always live.
            var live = false
            if self.dialect.flavor == .mysql {
                live = (try? await self.rawRows("SET @@SESSION.information_schema_stats_expiry = 0")) != nil
            }
            let result: Result<[[String?]], any Error>
            do { result = .success(try await self.rawRows(sql)) } catch { result = .failure(error) }
            if live { _ = try? await self.rawRows("SET @@SESSION.information_schema_stats_expiry = DEFAULT") }
            return try result.get()
        }
        guard let row = rows.first else { throw DatabaseError(.query, "Table \(table) not found.") }
        func int(_ index: Int) -> Int? { row[index].flatMap { Int($0) } }
        func text(_ index: Int) -> String? { row[index].flatMap { $0.isEmpty ? nil : $0 } }
        return TableStatus(
            estimatedRows: int(0), dataBytes: int(1), indexBytes: int(2), freeBytes: int(3), autoIncrement: int(4),
            engine: text(5), collation: text(6), createdAt: text(7), updatedAt: text(8), comment: text(9))
    }

    public func indexes(of table: String, in database: String) async throws -> [IndexDetail] {
        let sql = """
            SELECT INDEX_NAME, INDEX_TYPE, NON_UNIQUE, COLUMN_NAME, SUB_PART, CARDINALITY, INDEX_COMMENT
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = \(dialect.stringLiteral(database)) AND TABLE_NAME = \(dialect.stringLiteral(table))
            ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
            """
        var indexes: [IndexDetail] = []
        for row in try await textRows(sql) {
            let name = row[0] ?? ""
            let column = row[3].map { name in row[4].map { "\(name)(\($0))" } ?? name } ?? "(expression)"
            if let last = indexes.indices.last, indexes[last].name == name {
                indexes[last].columns.append(column)
                // Cardinality of the whole index is reported on its last column.
                indexes[last].cardinality = row[5].flatMap { Int($0) }
            } else {
                indexes.append(
                    IndexDetail(
                        name: name, algorithm: row[1] ?? "", isUnique: row[2] == "0", columns: [column],
                        cardinality: row[5].flatMap { Int($0) }, comment: row[6].flatMap { $0.isEmpty ? nil : $0 }))
            }
        }
        return indexes
    }

    public func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail] {
        // LEFT JOIN: MariaDB hides REFERENTIAL_CONSTRAINTS (the ON UPDATE / ON DELETE rules) from users with only
        // SELECT, while KEY_COLUMN_USAGE (the keys themselves) stays visible. The rules then come from the DDL.
        let sql = """
            SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME,
                k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
            FROM information_schema.KEY_COLUMN_USAGE k
            LEFT JOIN information_schema.REFERENTIAL_CONSTRAINTS r
                ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
                AND r.TABLE_NAME = k.TABLE_NAME
            WHERE k.TABLE_SCHEMA = \(dialect.stringLiteral(database)) AND k.TABLE_NAME = \(dialect.stringLiteral(table))
                AND k.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """
        var keys: [ForeignKeyDetail] = []
        var rulesHidden = false
        for row in try await textRows(sql) {
            let name = row[0] ?? ""
            if row[5] == nil || row[6] == nil { rulesHidden = true }
            if let last = keys.indices.last, keys[last].name == name {
                keys[last].columns.append(row[1] ?? "")
                keys[last].referencedColumns.append(row[4] ?? "")
            } else {
                keys.append(
                    ForeignKeyDetail(
                        name: name, columns: [row[1] ?? ""], referencedDatabase: row[2] ?? "",
                        referencedTable: row[3] ?? "", referencedColumns: [row[4] ?? ""],
                        onUpdate: row[5] ?? "RESTRICT", onDelete: row[6] ?? "RESTRICT"))
            }
        }
        if rulesHidden, let ddl = try? await createStatement(of: table, in: database) {
            let rules = Self.foreignKeyRules(inCreateStatement: ddl)
            for index in keys.indices {
                guard let rule = rules[keys[index].name] else { continue }
                keys[index].onUpdate = rule.onUpdate
                keys[index].onDelete = rule.onDelete
            }
        }
        return keys
    }

    /// ON UPDATE / ON DELETE rules per constraint name, read from SHOW CREATE TABLE output. A rule the DDL leaves
    /// out is the default, RESTRICT.
    static func foreignKeyRules(inCreateStatement ddl: String) -> [String: (onUpdate: String, onDelete: String)] {
        let action = "(RESTRICT|CASCADE|SET NULL|SET DEFAULT|NO ACTION)"
        guard
            let constraint = try? NSRegularExpression(
                pattern: "CONSTRAINT\\s+`((?:[^`]|``)+)`\\s+FOREIGN KEY[^\\n]*", options: [.caseInsensitive]),
            let onUpdate = try? NSRegularExpression(pattern: "ON UPDATE \(action)", options: [.caseInsensitive]),
            let onDelete = try? NSRegularExpression(pattern: "ON DELETE \(action)", options: [.caseInsensitive])
        else { return [:] }
        var rules: [String: (onUpdate: String, onDelete: String)] = [:]
        let text = ddl as NSString
        for match in constraint.matches(in: ddl, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1)).replacingOccurrences(of: "``", with: "`")
            let line = text.substring(with: match.range)
            func rule(_ pattern: NSRegularExpression) -> String {
                let range = NSRange(location: 0, length: (line as NSString).length)
                guard let found = pattern.firstMatch(in: line, range: range) else { return "RESTRICT" }
                return (line as NSString).substring(with: found.range(at: 1)).uppercased()
            }
            rules[name] = (rule(onUpdate), rule(onDelete))
        }
        return rules
    }

    /// Character sets with their collations, for CREATE DATABASE.
    public func characterSets() async throws -> [CharacterSetInfo] {
        // Defaults come from CHARACTER_SETS: MariaDB 11's defaults (UCA 14.0) appear in COLLATIONS with no
        // character set, so COLLATIONS alone misses them.
        var sets = try await textRows(
            "SELECT CHARACTER_SET_NAME, DEFAULT_COLLATE_NAME FROM information_schema.CHARACTER_SETS "
                + "ORDER BY CHARACTER_SET_NAME"
        ).compactMap { row in row[0].map { CharacterSetInfo(name: $0, defaultCollation: row[1]) } }
        let index = Dictionary(uniqueKeysWithValues: sets.enumerated().map { ($1.name, $0) })
        let collations = try await textRows(
            "SELECT CHARACTER_SET_NAME, COLLATION_NAME FROM information_schema.COLLATIONS ORDER BY COLLATION_NAME")
        for row in collations {
            guard let set = row[0], let collation = row[1], let position = index[set] else { continue }
            sets[position].collations.append(collation)
        }
        for position in sets.indices {
            if let fallback = sets[position].defaultCollation, !sets[position].collations.contains(fallback) {
                sets[position].collations.insert(fallback, at: 0)
            }
        }
        return sets
    }

    public func createStatement(of table: String, in database: String) async throws -> String {
        // Works for views too (the second column is then the CREATE VIEW).
        let rows = try await textRows("SHOW CREATE TABLE \(dialect.qualified(database, table))")
        guard let row = rows.first, row.count > 1, let ddl = row[1] else {
            throw DatabaseError(.query, "The server didn't return a CREATE statement for \(table).")
        }
        return ddl
    }

    /// Runs an internal query and returns every value as text (information_schema mixes charsets).
    private func textRows(_ sql: String) async throws -> [[String?]] {
        try await lock.run {
            try await self.rawRows(sql)
        }
    }

    private func rawRows(_ sql: String) async throws -> [[String?]] {
        do {
            return try await connection.simpleQuery(sql).get().map { row in
                row.values.map { $0.map { String(buffer: $0) } }
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    private func strings(_ sql: String) async throws -> [String] {
        try await textRows(sql).compactMap { $0.first ?? nil }
    }

    // MARK: - Errors

    static func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw mapError(error) }
    }

    static func mapError(_ error: any Error) -> DatabaseError {
        if let error = error as? DatabaseError { return error }
        if let error = error as? MySQLError {
            switch error {
            case .server(let packet):
                let code = Int(packet.errorCode.rawValue)
                let category: DatabaseError.Category =
                    switch code {
                    case 1044, 1045, 1698: .authentication
                    case 1317: .cancelled
                    default: .query
                    }
                return DatabaseError(category, packet.errorMessage, code: code)
            case .duplicateEntry(let message):
                return DatabaseError(.query, message, code: 1062)
            case .invalidSyntax(let message):
                return DatabaseError(.query, message, code: 1064)
            case .secureConnectionRequired:
                return DatabaseError(.tls, "The server requires a secure connection. Set TLS to Prefer or Require.")
            case .closed:
                return DatabaseError(.connection, "The connection was closed.")
            default:
                return DatabaseError(.connection, error.message)
            }
        }
        if error is NIOSSLError {
            return DatabaseError(.tls, "TLS handshake failed: \(error)")
        }
        if let error = error as? IOError {
            return DatabaseError(.connection, "Couldn't connect: \(error.description)")
        }
        if error is ChannelError {
            return DatabaseError(.connection, "Connection failed: \(error)")
        }
        return DatabaseError(.connection, String(describing: error))
    }
}
