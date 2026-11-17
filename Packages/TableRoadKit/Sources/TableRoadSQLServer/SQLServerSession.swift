import Foundation
import NIOCore
import NIOSSL
import TableRoadCore
import TableRoadSQL

/// T-SQL spelling: [brackets], N'unicode strings', OFFSET … FETCH paging, no LIMIT in UPDATE/DELETE.
public struct SQLServerDialect: SQLDialect {
    public init() {}

    public func quoteIdentifier(_ name: String) -> String {
        "[" + name.replacingOccurrences(of: "]", with: "]]") + "]"
    }

    public func stringLiteral(_ value: String) -> String {
        "N'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public func bytesLiteral(_ data: Data) -> String {
        data.isEmpty ? "0x" : "0x" + data.map { String(format: "%02X", $0) }.joined()
    }

    public func booleanLiteral(_ value: Bool) -> String { value ? "1" : "0" }

    /// "Databases" in the sidebar are the connected database's schemas (like PostgreSQL).
    public func createDatabaseSQL(_ name: String, characterSet: String?, collation: String?) throws -> String {
        "CREATE SCHEMA \(quoteIdentifier(name))"
    }

    public func dropDatabaseSQL(_ name: String) -> String { "DROP SCHEMA \(quoteIdentifier(name))" }
    public var supportsWriteLimit: Bool { false }
    public var emptyInsertValues: String { "DEFAULT VALUES" }

    /// LIKE on numbers and dates works after a cast to text.
    public func likeOperand(_ quotedColumn: String) -> String { "CAST(\(quotedColumn) AS NVARCHAR(MAX))" }

    /// OFFSET … FETCH needs an ORDER BY; without a sort, order by nothing in particular.
    public func pagingClause(limit: Int, offset: Int, ordered: Bool) -> String {
        (ordered ? "" : " ORDER BY (SELECT NULL)")
            + " OFFSET \(max(offset, 0)) ROWS FETCH NEXT \(max(limit, 0)) ROWS ONLY"
    }
}

/// Settings for a SQL Server connection. `database` is the database to open (its schemas are listed); empty uses
/// the login's default database.
public struct SQLServerConnectConfig: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var database: String?
    public var tls: TLSMode
    public var tlsFiles: TLSFiles
    public var bootstrapSQL: String?

    public init(
        host: String, port: Int = 1433, username: String, password: String?, database: String? = nil,
        tls: TLSMode = .prefer, tlsFiles: TLSFiles = TLSFiles(), bootstrapSQL: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tls = tls
        self.tlsFiles = tlsFiles
        self.bootstrapSQL = bootstrapSQL
    }

    public init(profile: ConnectionProfile, password: String?) {
        self.init(
            host: profile.host, port: profile.port, username: profile.username, password: password,
            database: profile.database.flatMap { $0.isEmpty ? nil : $0 }, tls: profile.tls, tlsFiles: profile.tlsFiles,
            bootstrapSQL: profile.bootstrapSQL)
    }
}

/// A SQL Server (or Azure SQL) connection over TDS 7.4, written from the MS-TDS specification.
public actor SQLServerSession: SQLClient {
    private let connection: TDSConnection
    private let lock = AsyncSerialLock()
    public let kind: DatabaseKind = .sqlserver
    public private(set) var serverVersion: String
    /// The schema the browser is showing (SQL Server has no per-session default schema to switch).
    public private(set) var currentDatabase: String?
    /// The connected database (`DB_NAME()`).
    private var catalog: String
    private var packetSize = TDS.defaultPacketSize
    /// Descriptor of the open transaction (sent with every batch while one is open).
    private var transaction: UInt64 = 0
    /// Set while an attention (cancel) is outstanding, until the server acknowledges it.
    private var attentionPending = false
    private var isRunning = false

    private nonisolated let spid = SPIDBox()
    public nonisolated var processID: UInt64 { spid.value }
    public nonisolated let isEncrypted: Bool
    public nonisolated let tlsCipher: String?
    public nonisolated var sqlDialect: any SQLDialect { SQLServerDialect() }
    public nonisolated var capabilities: ClientCapabilities {
        ClientCapabilities(processList: true, createDatabases: true, databaseNoun: "schema", cancel: true)
    }

    public static func connect(_ config: SQLServerConnectConfig) async throws -> SQLServerSession {
        let connection: TDSConnection
        do {
            connection = try await TDSConnection.connect(host: config.host, port: config.port)
        } catch {
            throw DatabaseError(.connection, "Couldn't reach \(config.host):\(config.port): \(error)")
        }
        do {
            let encrypted = try await negotiate(connection, config: config)
            let session = SQLServerSession(connection: connection, encrypted: encrypted)
            try await session.login(config)
            return session
        } catch {
            await connection.close()
            throw error
        }
    }

    private init(connection: TDSConnection, encrypted: Bool) {
        self.connection = connection
        isEncrypted = encrypted
        tlsCipher = encrypted ? "TLS 1.2" : nil
        serverVersion = ""
        catalog = ""
    }

    /// PRELOGIN, then TLS when either side wants it. Returns whether the connection is encrypted.
    private static func negotiate(_ connection: TDSConnection, config: SQLServerConnectConfig) async throws -> Bool {
        let wanted: TDS.Encryption = config.tls == .disable ? .notSupported : .on
        try await connection.send(
            .preLogin, TDS.preLogin(encryption: wanted, allocator: connection.channel.allocator),
            packetSize: TDS.defaultPacketSize)
        let reply = try await connection.receive()
        let server = TDS.encryption(inPreLoginResponse: reply.payload) ?? .notSupported
        switch (wanted, server) {
        case (.notSupported, .required):
            throw DatabaseError(.tls, "The server requires an encrypted connection; turn on SSL for this connection.")
        case (.notSupported, _):
            return false
        case (_, .notSupported):
            if config.tls == .prefer { return false }
            throw DatabaseError(.tls, "The server doesn't support encrypted connections.")
        default:
            var tls = TLSConfiguration.makeClientConfiguration()
            // TDS 7.x carries TLS 1.2 inside PRELOGIN packets (TLS 1.3 needs TDS 8 strict mode).
            tls.maximumTLSVersion = .tlsv12
            switch config.tls {
            case .disable, .prefer, .require: tls.certificateVerification = .none
            case .verifyCA: tls.certificateVerification = .noHostnameVerification
            case .verifyFull: tls.certificateVerification = .fullVerification
            }
            func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
            do {
                if let ca = config.tlsFiles.caCertPath { tls.trustRoots = .file(expand(ca)) }
                if let cert = config.tlsFiles.clientCertPath {
                    tls.certificateChain = try NIOSSLCertificate.fromPEMFile(expand(cert)).map { .certificate($0) }
                }
                if let key = config.tlsFiles.clientKeyPath {
                    tls.privateKey = .privateKey(try NIOSSLPrivateKey(file: expand(key), format: .pem))
                }
                let context = try NIOSSLContext(configuration: tls)
                let hostname = config.tls == .verifyFull && !config.host.isIPAddress ? config.host : nil
                try await connection.startTLS(context: context, serverHostname: hostname)
            } catch let error as DatabaseError {
                throw error
            } catch {
                throw DatabaseError(.tls, "Couldn't set up TLS: \(error)")
            }
            return true
        }
    }

    private func login(_ config: SQLServerConnectConfig) async throws {
        let login = TDS.Login(
            hostName: ProcessInfo.processInfo.hostName, userName: config.username, password: config.password ?? "",
            appName: "TableRoad", serverName: config.host, database: config.database ?? "",
            packetSize: TDS.defaultPacketSize)
        try await connection.send(
            .login7, TDS.login7(login, allocator: connection.channel.allocator), packetSize: packetSize)
        let response = try await readResponse()
        apply(response)
        guard response.loginAck != nil else {
            let error = response.errors.first
            throw DatabaseError(
                error?.number == 18456 ? .authentication : .connection,
                error?.message ?? "SQL Server refused the login.", code: error?.number)
        }
        let probe = try await rows(
            "SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), @@SPID, DB_NAME(), SCHEMA_NAME()")
        serverVersion = probe.first?[0] ?? response.loginAck?.version ?? ""
        spid.value = UInt64(probe.first?[1] ?? "") ?? 0
        catalog = probe.first?[2] ?? config.database ?? ""
        currentDatabase = probe.first?[3] ?? "dbo"
        if let bootstrap = config.bootstrapSQL?.trimmingCharacters(in: .whitespacesAndNewlines), !bootstrap.isEmpty {
            for statement in StatementSplitter(syntax: .sqlserver).split(bootstrap) {
                _ = try await executeLocked(statement.text)
            }
        }
    }

    public func close() async {
        await connection.close()
    }

    // MARK: Statements

    public func execute(_ sql: String) async throws -> QueryOutcome {
        try await lock.run { try await self.executeLocked(sql) }
    }

    private func executeLocked(_ sql: String) async throws -> QueryOutcome {
        let response = try await batch(sql)
        if let result = response.results.last(where: { !$0.columns.isEmpty }) {
            return .rows(
                ResultSet(
                    columns: result.columns.map { ResultColumn(name: $0.name, typeName: $0.typeName) },
                    rows: result.rows))
        }
        return .affected(rowCount: response.rowCount)
    }

    /// Sends one batch and reads its response; server errors become `DatabaseError`s.
    private func batch(_ sql: String) async throws -> TDSResponse {
        isRunning = true
        defer { isRunning = false }
        try await connection.send(
            .sqlBatch, TDS.sqlBatch(sql, transaction: transaction, allocator: connection.channel.allocator),
            packetSize: packetSize)
        let response = try await readResponse()
        apply(response)
        if response.attentionAcknowledged || attentionPending {
            attentionPending = false
            throw DatabaseError(.cancelled, "The query was cancelled.")
        }
        if let error = response.errors.first(where: { $0.severity > 10 }) {
            throw DatabaseError(error.severity >= 20 ? .connection : .query, error.message, code: error.number)
        }
        return response
    }

    private func readResponse() async throws -> TDSResponse {
        var message = try await connection.receive()
        var response: TDSResponse
        do {
            var parser = TDSTokenParser(message.payload)
            response = try parser.parse()
            // After a cancel the server finishes the current message, then acknowledges in another.
            while attentionPending && !response.attentionAcknowledged {
                message = try await connection.receive()
                var next = TDSTokenParser(message.payload)
                let more = try next.parse()
                response.attentionAcknowledged = more.attentionAcknowledged
            }
        } catch let error as TDSParseError {
            throw DatabaseError(.query, error.message)
        }
        return response
    }

    private func apply(_ response: TDSResponse) {
        if let size = response.packetSize { packetSize = size }
        if let transaction = response.transaction { self.transaction = transaction }
        if let database = response.database { catalog = database }
    }

    public func cancelCurrentQuery() async throws {
        guard isRunning, !attentionPending else { return }
        attentionPending = true
        try await connection.send(.attention, ByteBuffer(), packetSize: packetSize)
    }

    public func run(_ sql: String) async throws {
        _ = try await execute(sql)
    }

    public func executeTransaction(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        try await lock.run {
            _ = try await self.batch("SET XACT_ABORT ON; BEGIN TRANSACTION")
            var counts: [UInt64] = []
            for (index, statement) in statements.enumerated() {
                do {
                    let response = try await self.batch(statement.inlined(SQLServerDialect()))
                    counts.append(response.rowCount)
                } catch {
                    _ = try? await self.batch("IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION")
                    let underlying = error as? DatabaseError ?? DatabaseError(.query, "\(error)")
                    throw TransactionError(statementIndex: index, underlying: underlying)
                }
            }
            do {
                _ = try await self.batch("COMMIT TRANSACTION")
            } catch {
                let underlying = error as? DatabaseError ?? DatabaseError(.query, "\(error)")
                throw TransactionError(
                    statementIndex: statements.count, underlying: underlying,
                    commitOutcomeUnknown: underlying.category == .connection)
            }
            return counts
        }
    }

    /// Internal queries, every value as text.
    private func rows(_ sql: String) async throws -> [[String?]] {
        guard case .rows(let result) = try await executeLocked(sql) else { return [] }
        return result.rows.map { $0.map(\.displayText) }
    }

    private func textRows(_ sql: String) async throws -> [[String?]] {
        try await lock.run { try await self.rows(sql) }
    }

    // MARK: Catalog

    public func useDatabase(_ name: String) async throws {
        currentDatabase = name
    }

    /// Schemas of the connected database that the user can see (not the built-in role schemas).
    public func databases() async throws -> [String] {
        try await textRows(
            """
            SELECT s.name FROM sys.schemas s
            WHERE s.name NOT IN ('sys', 'INFORMATION_SCHEMA', 'guest')
                AND s.name NOT LIKE 'db[_]%' ORDER BY CASE WHEN s.name = 'dbo' THEN 0 ELSE 1 END, s.name
            """
        ).compactMap { $0[0] }
    }

    public func tables(in database: String) async throws -> [TableInfo] {
        let schema = SQLServerDialect().stringLiteral(database)
        return try await textRows(
            """
            SELECT o.name, o.type, (SELECT SUM(p.rows) FROM sys.partitions p
                WHERE p.object_id = o.object_id AND p.index_id IN (0, 1))
            FROM sys.objects o WHERE o.schema_id = SCHEMA_ID(\(schema)) AND o.type IN ('U', 'V') AND o.is_ms_shipped = 0
            ORDER BY o.name
            """
        ).compactMap { row in
            guard let name = row[0] else { return nil }
            let isView = row[1]?.trimmingCharacters(in: .whitespaces) == "V"
            return TableInfo(name: name, kind: isView ? .view : .table, estimatedRowCount: row[2].flatMap { Int($0) })
        }
    }

    private func objectID(_ table: String, _ schema: String) -> String {
        let dialect = SQLServerDialect()
        return "OBJECT_ID(\(dialect.stringLiteral(dialect.qualified(schema, table))))"
    }

    public func columns(of table: String, in database: String) async throws -> [ColumnDetail] {
        try await textRows(
            """
            SELECT c.name, t.name, c.max_length, c.precision, c.scale, c.is_nullable, c.is_identity,
                OBJECT_DEFINITION(c.default_object_id), c.collation_name, CAST(ep.value AS NVARCHAR(4000)),
                CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i
                    ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                    WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id)
                THEN 1 ELSE 0 END,
                cc.definition, IDENT_SEED(\(SQLServerDialect().stringLiteral(SQLServerDialect().qualified(database, table)))),
                IDENT_INCR(\(SQLServerDialect().stringLiteral(SQLServerDialect().qualified(database, table))))
            FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
            LEFT JOIN sys.extended_properties ep ON ep.class = 1 AND ep.major_id = c.object_id
                AND ep.minor_id = c.column_id AND ep.name = 'MS_Description'
            LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
            WHERE c.object_id = \(objectID(table, database)) ORDER BY c.column_id
            """
        ).map { row in
            let type = Self.typeName(
                row[1] ?? "", maxLength: Int(row[2] ?? "") ?? 0, precision: Int(row[3] ?? "") ?? 0,
                scale: Int(row[4] ?? "") ?? 0)
            var extra: String?
            if row[6] == "true" || row[6] == "1" { extra = "IDENTITY(\(row[12] ?? "1"),\(row[13] ?? "1"))" }
            if let computed = row[11] { extra = "AS \(computed)" }
            return ColumnDetail(
                name: row[0] ?? "", type: type, isNullable: row[5] == "true" || row[5] == "1",
                isPrimaryKey: row[10] == "1", defaultValue: row[7].map(Self.unwrapDefault), extra: extra,
                comment: row[9], collation: row[8])
        }
    }

    /// `nvarchar(50)`, `decimal(10,2)`, `varbinary(max)`…
    static func typeName(_ base: String, maxLength: Int, precision: Int, scale: Int) -> String {
        switch base {
        case "varchar", "char", "varbinary", "binary":
            return "\(base)(\(maxLength == -1 ? "max" : String(maxLength)))"
        case "nvarchar", "nchar":
            return "\(base)(\(maxLength == -1 ? "max" : String(maxLength / 2)))"
        case "decimal", "numeric":
            return "\(base)(\(precision),\(scale))"
        case "datetime2", "time", "datetimeoffset":
            return "\(base)(\(scale))"
        default:
            return base
        }
    }

    /// Defaults come back wrapped: `((0))`, `(N'x')`, `(getdate())`.
    static func unwrapDefault(_ text: String) -> String {
        var value = text
        while value.hasPrefix("("), value.hasSuffix(")") {
            let inner = String(value.dropFirst().dropLast())
            // Stop at "(a) + (b)": the outer parentheses aren't a matching pair.
            var depth = 0
            var balanced = true
            for character in inner {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth < 0 {
                    balanced = false
                    break
                }
            }
            guard balanced, depth == 0 else { break }
            value = inner
        }
        return value
    }

    public func tableStatus(of table: String, in database: String) async throws -> TableStatus {
        let rows = try await textRows(
            """
            SELECT SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END),
                SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.in_row_data_page_count + ps.lob_used_page_count
                    + ps.row_overflow_used_page_count ELSE 0 END) * 8192,
                SUM(CASE WHEN ps.index_id > 1 THEN ps.used_page_count ELSE 0 END) * 8192,
                SUM(ps.reserved_page_count - ps.used_page_count) * 8192,
                (SELECT CONVERT(VARCHAR(19), o.create_date, 120) FROM sys.objects o WHERE o.object_id = \(objectID(table, database))),
                (SELECT CONVERT(VARCHAR(19), o.modify_date, 120) FROM sys.objects o WHERE o.object_id = \(objectID(table, database))),
                (SELECT CAST(ep.value AS NVARCHAR(4000)) FROM sys.extended_properties ep WHERE ep.class = 1
                    AND ep.major_id = \(objectID(table, database)) AND ep.minor_id = 0 AND ep.name = 'MS_Description'),
                CAST(IDENT_CURRENT(\(SQLServerDialect().stringLiteral(SQLServerDialect().qualified(database, table)))) AS BIGINT)
            FROM sys.dm_db_partition_stats ps WHERE ps.object_id = \(objectID(table, database))
            """)
        guard let row = rows.first else { return TableStatus() }
        return TableStatus(
            estimatedRows: row[0].flatMap { Int($0) }, dataBytes: row[1].flatMap { Int($0) },
            indexBytes: row[2].flatMap { Int($0) }, freeBytes: row[3].flatMap { Int($0) },
            autoIncrement: row[7].flatMap { Int($0) }.map { $0 + 1 }, collation: nil, createdAt: row[4],
            updatedAt: row[5], comment: row[6])
    }

    public func tableSizes(in database: String) async throws -> [String: Int64] {
        let rows = try await textRows(
            """
            SELECT o.name, SUM(ps.used_page_count) * 8192 FROM sys.dm_db_partition_stats ps
            JOIN sys.objects o ON o.object_id = ps.object_id
            WHERE o.schema_id = SCHEMA_ID(\(SQLServerDialect().stringLiteral(database))) AND o.type = 'U'
            GROUP BY o.name
            """)
        return Dictionary(
            rows.compactMap { row in row[0].map { ($0, Int64(row[1] ?? "") ?? 0) } }, uniquingKeysWith: { $1 })
    }

    public func indexes(of table: String, in database: String) async throws -> [IndexDetail] {
        let rows = try await textRows(
            """
            SELECT i.name, i.type_desc, i.is_unique, i.is_primary_key, c.name
            FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE i.object_id = \(objectID(table, database)) AND i.name IS NOT NULL AND ic.is_included_column = 0
            ORDER BY i.is_primary_key DESC, i.name, ic.key_ordinal
            """)
        var indexes: [IndexDetail] = []
        for row in rows {
            guard let name = row[0], let column = row[4] else { continue }
            if let last = indexes.indices.last, indexes[last].name == name {
                indexes[last].columns.append(column)
            } else {
                indexes.append(
                    IndexDetail(
                        name: name, algorithm: (row[1] ?? "").replacingOccurrences(of: "_", with: " ").capitalized,
                        isUnique: row[2] == "true" || row[2] == "1", columns: [column],
                        comment: row[3] == "true" || row[3] == "1" ? "Primary key" : nil))
            }
        }
        return indexes
    }

    public func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail] {
        let rows = try await textRows(
            """
            SELECT fk.name, pc.name, SCHEMA_NAME(rt.schema_id), rt.name, rc.name,
                fk.update_referential_action_desc, fk.delete_referential_action_desc
            FROM sys.foreign_keys fk
            JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
            JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
            JOIN sys.tables rt ON rt.object_id = fkc.referenced_object_id
            JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
            WHERE fk.parent_object_id = \(objectID(table, database))
            ORDER BY fk.name, fkc.constraint_column_id
            """)
        var keys: [ForeignKeyDetail] = []
        func action(_ text: String?) -> String { (text ?? "NO_ACTION").replacingOccurrences(of: "_", with: " ") }
        for row in rows {
            let name = row[0] ?? ""
            if let last = keys.indices.last, keys[last].name == name {
                keys[last].columns.append(row[1] ?? "")
                keys[last].referencedColumns.append(row[4] ?? "")
            } else {
                keys.append(
                    ForeignKeyDetail(
                        name: name, columns: [row[1] ?? ""], referencedDatabase: row[2] ?? database,
                        referencedTable: row[3] ?? "", referencedColumns: [row[4] ?? ""], onUpdate: action(row[5]),
                        onDelete: action(row[6])))
            }
        }
        return keys
    }

    /// SQL Server has no SHOW CREATE TABLE: views come from their definition; tables are rebuilt from the catalog.
    public func createStatement(of table: String, in database: String) async throws -> String {
        let dialect = SQLServerDialect()
        let name = dialect.qualified(database, table)
        let kind = try await textRows(
            "SELECT type, OBJECT_DEFINITION(object_id) FROM sys.objects WHERE object_id = \(objectID(table, database))")
        guard let first = kind.first else {
            throw DatabaseError(.query, "\(table) doesn't exist in \(database).")
        }
        if first[0]?.trimmingCharacters(in: .whitespaces) == "V" {
            return (first[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let columns = try await columns(of: table, in: database)
        let indexes = try await indexes(of: table, in: database)
        let keys = try await foreignKeys(of: table, in: database)
        var lines = columns.map { column -> String in
            if let extra = column.extra, extra.hasPrefix("AS ") {
                return "  \(dialect.quoteIdentifier(column.name)) \(extra)"
            }
            var line = "  \(dialect.quoteIdentifier(column.name)) \(column.type)"
            if let extra = column.extra { line += " \(extra)" }
            if let collation = column.collation { line += " COLLATE \(collation)" }
            line += column.isNullable ? " NULL" : " NOT NULL"
            if let value = column.defaultValue { line += " DEFAULT (\(value))" }
            return line
        }
        if let primary = indexes.first(where: { $0.comment == "Primary key" }) {
            lines.append(
                "  CONSTRAINT \(dialect.quoteIdentifier(primary.name)) PRIMARY KEY \(primary.algorithm.uppercased()) ("
                    + primary.columns.map(dialect.quoteIdentifier).joined(separator: ", ") + ")")
        }
        for key in keys {
            var line =
                "  CONSTRAINT \(dialect.quoteIdentifier(key.name)) FOREIGN KEY ("
                + key.columns.map(dialect.quoteIdentifier).joined(separator: ", ") + ") REFERENCES "
                + dialect.qualified(key.referencedDatabase, key.referencedTable) + " ("
                + key.referencedColumns.map(dialect.quoteIdentifier).joined(separator: ", ") + ")"
            if key.onDelete != "NO ACTION" { line += " ON DELETE \(key.onDelete)" }
            if key.onUpdate != "NO ACTION" { line += " ON UPDATE \(key.onUpdate)" }
            lines.append(line)
        }
        var sql = "CREATE TABLE \(name) (\n" + lines.joined(separator: ",\n") + "\n)"
        for index in indexes where index.comment != "Primary key" {
            sql +=
                ";\nCREATE \(index.isUnique ? "UNIQUE " : "")\(index.algorithm.uppercased()) INDEX "
                + "\(dialect.quoteIdentifier(index.name)) ON \(name) ("
                + index.columns.map(dialect.quoteIdentifier).joined(separator: ", ") + ")"
        }
        return sql
    }

    public func characterSets() async throws -> [CharacterSetInfo] { [] }

    // MARK: Processes

    public func processList() async throws -> [ServerProcess] {
        try await textRows(
            """
            SELECT s.session_id, s.login_name, s.host_name, DB_NAME(s.database_id),
                COALESCE(r.command, s.status),
                DATEDIFF(SECOND, COALESCE(r.start_time, s.last_request_start_time), GETDATE()),
                COALESCE(r.wait_type, r.status), t.text
            FROM sys.dm_exec_sessions s
            LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
            OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
            WHERE s.is_user_process = 1 ORDER BY s.session_id
            """
        ).compactMap { row in
            guard let id = row[0].flatMap({ UInt64($0) }) else { return nil }
            return ServerProcess(
                id: id, user: row[1] ?? "", host: row[2] ?? "", database: row[3], command: row[4] ?? "",
                seconds: max(Int(row[5] ?? "") ?? 0, 0), state: row[6], info: row[7])
        }
    }

    /// SQL Server can only end a whole session (`KILL`), not just its statement.
    public func kill(processID: UInt64, connection: Bool) async throws {
        _ = try await execute("KILL \(processID)")
    }
}

/// The session's server process id (@@SPID), known only after login but read from any thread.
private final class SPIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UInt64 = 0
    var value: UInt64 {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

extension String {
    fileprivate var isIPAddress: Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, self, &v4) == 1 || inet_pton(AF_INET6, self, &v6) == 1
    }
}
