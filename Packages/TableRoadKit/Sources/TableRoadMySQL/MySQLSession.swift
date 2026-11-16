import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import TableRoadCore
import TableRoadSQL

/// A MySQL or MariaDB connection.
public actor MySQLSession: TransactionalSession {
    public let kind: DatabaseKind
    public let serverVersion: String
    public private(set) var currentDatabase: String?
    public nonisolated let dialect: MySQLDialect
    /// Whether the session is TLS-encrypted (shown as a padlock in the workspace).
    public nonisolated let isEncrypted: Bool

    private let connection: MySQLConnection
    private let config: MySQLConnectConfig
    private let usedTLS: Bool
    /// Server-side thread ID, used by `KILL QUERY` from a second connection.
    private let threadID: UInt64
    private let lock = AsyncSerialLock()
    private static let logger = Logger(label: "TableRoad.MySQL")

    private init(
        connection: MySQLConnection, config: MySQLConnectConfig, usedTLS: Bool, version: String, threadID: UInt64,
        database: String?, sqlMode: String
    ) {
        self.connection = connection
        self.config = config
        self.usedTLS = usedTLS
        self.isEncrypted = usedTLS
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
        let (connection, usedTLS) = try await openConnection(config)
        do {
            let rows = try await connection.simpleQuery(
                "SELECT VERSION(), CONNECTION_ID(), DATABASE(), @@SESSION.sql_mode"
            ).get()
            let values = rows.first.map { row in row.values.map { $0.flatMap { String(buffer: $0) } } } ?? []
            return MySQLSession(
                connection: connection, config: config, usedTLS: usedTLS,
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
        MySQLConnection, Bool
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
        var tls: TLSConfiguration?
        switch mode {
        case .disable:
            tls = nil
        case .prefer, .require:
            var unverified = TLSConfiguration.makeClientConfiguration()
            unverified.certificateVerification = .none
            tls = unverified
        case .verifyFull:
            tls = .makeClientConfiguration()
        }

        let connection = try await mapErrors { try await attempt(tls: tls) }
        guard tls != nil else { return (connection, false) }

        // mysql-nio silently continues in plain text when the server doesn't advertise SSL,
        // so ask the server whether this session is actually encrypted.
        // TODO(Phase 3 hardening): patch mysql-nio to fail the handshake instead; a status query
        // catches misconfigured servers but not an active downgrade attack.
        let encrypted: Bool
        do {
            let rows = try await connection.simpleQuery("SHOW SESSION STATUS LIKE 'Ssl_cipher'").get()
            let cipher = rows.first?.values.dropFirst().first.flatMap { $0.map { String(buffer: $0) } } ?? ""
            encrypted = !cipher.isEmpty
        } catch {
            try? await connection.close().get()
            throw mapError(error)
        }
        if !encrypted && mode != .prefer {
            try? await connection.close().get()
            throw DatabaseError(.tls, "The server doesn't support TLS, but this connection requires it.")
        }
        return (connection, encrypted)
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
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(dialect.stringLiteral(database)) AND TABLE_NAME = \(dialect.stringLiteral(table))
            ORDER BY ORDINAL_POSITION
            """
        return try await textRows(sql).map { row in
            ColumnDetail(
                name: row[0] ?? "", type: row[1] ?? "", isNullable: row[2] == "YES", isPrimaryKey: row[3] == "PRI",
                defaultValue: row[4], extra: row[5].flatMap { $0.isEmpty ? nil : $0 },
                comment: row[6].flatMap { $0.isEmpty ? nil : $0 })
        }
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
