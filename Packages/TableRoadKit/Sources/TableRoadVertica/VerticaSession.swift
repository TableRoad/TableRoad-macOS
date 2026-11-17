import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import TableRoadCore
import TableRoadSQL

/// Vertica spelling: "double quotes", standard strings, LIMIT/OFFSET, schemas as databases.
public struct VerticaDialect: SQLDialect {
    public init() {}

    public func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func stringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public func bytesLiteral(_ data: Data) -> String {
        "HEX_TO_BINARY('" + data.map { String(format: "%02x", $0) }.joined() + "')"
    }

    public func createDatabaseSQL(_ name: String, characterSet: String?, collation: String?) throws -> String {
        "CREATE SCHEMA \(quoteIdentifier(name))"
    }

    public func dropDatabaseSQL(_ name: String) -> String { "DROP SCHEMA \(quoteIdentifier(name)) CASCADE" }
    public func useDatabaseSQL(_ name: String) -> String? { "SET SEARCH_PATH TO \(quoteIdentifier(name)), public" }
    public var supportsWriteLimit: Bool { false }
    public var emptyInsertValues: String { "DEFAULT VALUES" }
    public func likeOperand(_ quotedColumn: String) -> String { "\(quotedColumn)::VARCHAR" }
}

public struct VerticaConnectConfig: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var database: String
    public var tls: TLSMode
    public var tlsFiles: TLSFiles
    public var bootstrapSQL: String?

    public init(
        host: String, port: Int = 5433, username: String, password: String?, database: String,
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
            database: profile.database ?? "", tls: profile.tls, tlsFiles: profile.tlsFiles,
            bootstrapSQL: profile.bootstrapSQL)
    }
}

/// A Vertica connection: simple-query protocol with text results.
public actor VerticaSession: SQLClient {
    private let connection: VerticaConnection
    private let config: VerticaConnectConfig
    private let lock = AsyncSerialLock()
    public let kind: DatabaseKind = .vertica
    public private(set) var serverVersion = ""
    public private(set) var currentDatabase: String?
    private var backendKey: (pid: UInt32, key: UInt32) = (0, 0)
    /// Vertica session ids are strings; the process list numbers them.
    private var sessionIDs: [UInt64: String] = [:]

    public nonisolated let isEncrypted: Bool
    public nonisolated var tlsCipher: String? { isEncrypted ? "TLS" : nil }
    public nonisolated var processID: UInt64 { 0 }
    public nonisolated var sqlDialect: any SQLDialect { VerticaDialect() }
    public nonisolated var capabilities: ClientCapabilities {
        ClientCapabilities(processList: true, createDatabases: true, databaseNoun: "schema", cancel: true)
    }

    public static func connect(_ config: VerticaConnectConfig) async throws -> VerticaSession {
        var context: NIOSSLContext?
        if config.tls != .disable {
            var tls = TLSConfiguration.makeClientConfiguration()
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
                if let key = config.tlsFiles.clientKeyPath { tls.privateKey = .file(expand(key)) }
                context = try NIOSSLContext(configuration: tls)
            } catch {
                throw DatabaseError(.tls, "Couldn't set up TLS: \(error)")
            }
        }
        let connection: VerticaConnection
        let encrypted: Bool
        do {
            (connection, encrypted) = try await VerticaConnection.connect(
                host: config.host, port: config.port, tls: context,
                required: config.tls != .prefer && config.tls != .disable,
                serverHostname: config.tls == .verifyFull ? config.host : nil)
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError(.connection, "Couldn't reach \(config.host):\(config.port): \(error)")
        }
        let session = VerticaSession(connection: connection, config: config, encrypted: encrypted)
        do {
            try await session.startup()
        } catch {
            await connection.close()
            throw error
        }
        return session
    }

    private init(connection: VerticaConnection, config: VerticaConnectConfig, encrypted: Bool) {
        self.connection = connection
        self.config = config
        isEncrypted = encrypted
    }

    private func startup() async throws {
        let allocator = connection.channel.allocator
        try await connection.send(
            VerticaProtocol.startup(user: config.username, database: config.database, allocator: allocator))
        loop: while true {
            let message = try await connection.receive()
            var body = message.body
            switch message.type {
            case UInt8(ascii: "R"):
                guard let code = body.readInteger(as: UInt32.self) else { throw VerticaProtocol.protocolError }
                if code == 0 || code == 11 { continue }  // OK, password grace period
                try await connection.send(
                    VerticaProtocol.password(
                        code: code, payload: body, user: config.username, password: config.password ?? "",
                        allocator: allocator))
            case UInt8(ascii: "K"):
                backendKey = (body.readInteger(as: UInt32.self) ?? 0, body.readInteger(as: UInt32.self) ?? 0)
            case UInt8(ascii: "S"):
                let name = body.readNullTerminatedString()
                let value = body.readNullTerminatedString()
                if name == "server_version" { serverVersion = value ?? "" }
            case UInt8(ascii: "E"):
                var error = VerticaProtocol.error(message.body)
                if error.category == .query { error.category = .authentication }
                throw error
            case UInt8(ascii: "Z"):
                break loop
            default:
                continue
            }
        }
        if serverVersion.isEmpty, let version = try await rows("SELECT VERSION()").first?.first ?? nil {
            serverVersion = version.replacingOccurrences(of: "Vertica Analytic Database ", with: "")
        }
        currentDatabase = try await rows("SELECT CURRENT_SCHEMA()").first?.first ?? "public"
        if let bootstrap = config.bootstrapSQL?.trimmingCharacters(in: .whitespacesAndNewlines), !bootstrap.isEmpty {
            for statement in StatementSplitter(syntax: .postgres).split(bootstrap) {
                _ = try await query(statement.text)
            }
        }
    }

    public func close() async {
        var terminate = connection.channel.allocator.buffer(capacity: 5)
        terminate.writeInteger(UInt8(ascii: "X"))
        terminate.writeInteger(UInt32(4))
        try? await connection.send(terminate)
        await connection.close()
    }

    // MARK: Statements

    public func execute(_ sql: String) async throws -> QueryOutcome {
        try await lock.run { try await self.query(sql) }
    }

    public func run(_ sql: String) async throws {
        _ = try await execute(sql)
    }

    /// One simple query: the last result set it produced, or the rows it affected.
    private func query(_ sql: String) async throws -> QueryOutcome {
        try await connection.send(VerticaProtocol.query(sql, allocator: connection.channel.allocator))
        var columns: [VerticaColumn] = []
        var rows: [[CellValue]] = []
        var result: ResultSet?
        var affected: UInt64 = 0
        var failure: DatabaseError?
        while true {
            let message = try await connection.receive()
            var body = message.body
            switch message.type {
            case UInt8(ascii: "T"):
                columns = try VerticaColumn.parse(&body)
                rows = []
            case UInt8(ascii: "D"):
                guard let count = body.readInteger(as: UInt16.self) else { continue }
                var row: [CellValue] = []
                row.reserveCapacity(Int(count))
                for index in 0..<Int(count) {
                    let length = body.readInteger(as: Int32.self) ?? -1
                    guard length >= 0, let bytes = body.readBytes(length: Int(length)) else {
                        row.append(.null)
                        continue
                    }
                    row.append(
                        index < columns.count
                            ? columns[index].decode(bytes) : .text(String(decoding: bytes, as: UTF8.self)))
                }
                rows.append(row)
            case UInt8(ascii: "C"):
                let tag = body.readNullTerminatedString() ?? ""
                // DML reports its row count as a one-row OUTPUT result.
                if columns.count == 1, columns[0].name == "OUTPUT", rows.count == 1, case .int(let count) = rows[0][0],
                    !tag.hasPrefix("SELECT")
                {
                    affected += UInt64(max(count, 0))
                    columns = []
                } else if !columns.isEmpty {
                    result = ResultSet(
                        columns: columns.map { ResultColumn(name: $0.name, table: $0.table, typeName: $0.typeName) },
                        rows: rows)
                    columns = []
                } else if let count = tag.split(separator: " ").last.flatMap({ UInt64($0) }) {
                    affected += count
                }
            case UInt8(ascii: "E"):
                failure = failure ?? VerticaProtocol.error(message.body)
            case UInt8(ascii: "Z"):
                if let failure { throw failure }
                if let result { return .rows(result) }
                return .affected(rowCount: affected)
            default:
                continue  // notices, parameter status, empty query…
            }
        }
    }

    public func cancelCurrentQuery() async throws {
        // A CancelRequest on a separate connection, like PostgreSQL.
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(5)).connect(host: config.host, port: config.port).get()
        var request = channel.allocator.buffer(capacity: 16)
        request.writeInteger(UInt32(16))
        request.writeInteger(VerticaProtocol.cancelRequestCode)
        request.writeInteger(backendKey.pid)
        request.writeInteger(backendKey.key)
        try await channel.writeAndFlush(request).get()
        try? await channel.close()
    }

    public func executeTransaction(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        try await lock.run {
            _ = try await self.query("BEGIN")
            var counts: [UInt64] = []
            for (index, statement) in statements.enumerated() {
                do {
                    guard case .affected(let count) = try await self.query(statement.inlined(VerticaDialect())) else {
                        counts.append(0)
                        continue
                    }
                    counts.append(count)
                } catch {
                    _ = try? await self.query("ROLLBACK")
                    throw TransactionError(
                        statementIndex: index,
                        underlying: error as? DatabaseError ?? DatabaseError(.query, "\(error)"))
                }
            }
            do {
                _ = try await self.query("COMMIT")
            } catch {
                let underlying = error as? DatabaseError ?? DatabaseError(.query, "\(error)")
                throw TransactionError(
                    statementIndex: statements.count, underlying: underlying,
                    commitOutcomeUnknown: underlying.category == .connection)
            }
            return counts
        }
    }

    private func rows(_ sql: String) async throws -> [[String?]] {
        guard case .rows(let result) = try await query(sql) else { return [] }
        return result.rows.map { $0.map(\.displayText) }
    }

    private func textRows(_ sql: String) async throws -> [[String?]] {
        try await lock.run { try await self.rows(sql) }
    }

    private func literal(_ text: String) -> String { VerticaDialect().stringLiteral(text) }

    // MARK: Catalog

    public func useDatabase(_ name: String) async throws {
        _ = try await execute("SET SEARCH_PATH TO \(VerticaDialect().quoteIdentifier(name)), public")
        currentDatabase = name
    }

    public func databases() async throws -> [String] {
        try await textRows(
            "SELECT schema_name FROM v_catalog.schemata WHERE NOT is_system_schema AND schema_name NOT LIKE 'v\\_%' ORDER BY schema_name"
        ).compactMap { $0[0] }
    }

    public func tables(in database: String) async throws -> [TableInfo] {
        let schema = literal(database)
        let tables = try await textRows(
            "SELECT table_name FROM v_catalog.tables WHERE table_schema = \(schema) ORDER BY table_name")
        let views = try await textRows(
            "SELECT table_name FROM v_catalog.views WHERE table_schema = \(schema) ORDER BY table_name")
        let counts = Dictionary(
            ((try? await textRows(
                """
                SELECT anchor_table_name, MAX(row_count) FROM (SELECT anchor_table_name, projection_name,
                    SUM(row_count) AS row_count FROM v_monitor.projection_storage
                    WHERE anchor_table_schema = \(schema) GROUP BY 1, 2) p GROUP BY 1
                """)) ?? []).compactMap { row in row[0].map { ($0, Int(row[1] ?? "") ?? 0) } },
            uniquingKeysWith: { $1 })
        return tables.compactMap { $0[0] }.map { TableInfo(name: $0, kind: .table, estimatedRowCount: counts[$0]) }
            + views.compactMap { $0[0] }.map { TableInfo(name: $0, kind: .view) }
    }

    public func columns(of table: String, in database: String) async throws -> [ColumnDetail] {
        let keys = Set(
            try await textRows(
                """
                SELECT column_name FROM v_catalog.primary_keys
                WHERE table_schema = \(literal(database)) AND table_name = \(literal(table))
                """
            ).compactMap { $0[0] })
        var columns = try await textRows(
            """
            SELECT column_name, data_type, is_nullable, column_default, is_identity FROM v_catalog.columns
            WHERE table_schema = \(literal(database)) AND table_name = \(literal(table)) ORDER BY ordinal_position
            """)
        if columns.isEmpty {
            columns = try await textRows(
                """
                SELECT column_name, data_type, 'true', NULL, 'false' FROM v_catalog.view_columns
                WHERE table_schema = \(literal(database)) AND table_name = \(literal(table)) ORDER BY ordinal_position
                """)
        }
        return columns.map { row in
            ColumnDetail(
                name: row[0] ?? "", type: row[1] ?? "", isNullable: row[2] == "true",
                isPrimaryKey: keys.contains(row[0] ?? ""),
                defaultValue: row[3], extra: row[4] == "true" ? "IDENTITY" : nil)
        }
    }

    public func tableStatus(of table: String, in database: String) async throws -> TableStatus {
        let rows =
            (try? await textRows(
                """
                SELECT MAX(row_count), MAX(used_bytes) FROM (SELECT projection_name, SUM(row_count) AS row_count,
                    SUM(used_bytes) AS used_bytes FROM v_monitor.projection_storage
                    WHERE anchor_table_schema = \(literal(database)) AND anchor_table_name = \(literal(table))
                    GROUP BY projection_name) p
                """)) ?? []
        let meta = try await textRows(
            """
            SELECT create_time::VARCHAR, (SELECT comment FROM v_catalog.comments WHERE object_type = 'TABLE'
                AND object_schema = \(literal(database)) AND object_name = \(literal(table)) LIMIT 1)
            FROM v_catalog.tables WHERE table_schema = \(literal(database)) AND table_name = \(literal(table))
            """)
        return TableStatus(
            estimatedRows: rows.first?[0].flatMap { Int($0) }, dataBytes: rows.first?[1].flatMap { Int($0) },
            engine: "Columnar", createdAt: meta.first?[0] ?? nil, comment: meta.first?[1] ?? nil)
    }

    public func tableSizes(in database: String) async throws -> [String: Int64] {
        let rows =
            (try? await textRows(
                """
                SELECT anchor_table_name, SUM(used_bytes) FROM v_monitor.projection_storage
                WHERE anchor_table_schema = \(literal(database)) GROUP BY 1
                """)) ?? []
        return Dictionary(
            rows.compactMap { row in row[0].map { ($0, Int64(row[1] ?? "") ?? 0) } }, uniquingKeysWith: { $1 })
    }

    /// Vertica has projections rather than indexes; they're listed in their place.
    public func indexes(of table: String, in database: String) async throws -> [IndexDetail] {
        let rows = try await textRows(
            """
            SELECT p.projection_name, p.is_segmented, pc.table_column_name FROM v_catalog.projections p
            JOIN v_catalog.projection_columns pc ON pc.projection_id = p.projection_id
            WHERE p.anchor_table_name = \(literal(table)) AND p.projection_schema = \(literal(database))
            ORDER BY p.projection_name, pc.sort_position, pc.column_position
            """)
        var indexes: [IndexDetail] = []
        for row in rows {
            guard let name = row[0], let column = row[2] else { continue }
            if let last = indexes.indices.last, indexes[last].name == name {
                indexes[last].columns.append(column)
            } else {
                indexes.append(
                    IndexDetail(
                        name: name, algorithm: row[1] == "true" ? "Segmented projection" : "Unsegmented projection",
                        isUnique: false, columns: [column]))
            }
        }
        return indexes
    }

    public func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail] {
        let rows = try await textRows(
            """
            SELECT constraint_name, column_name, reference_table_schema, reference_table_name, reference_column_name
            FROM v_catalog.foreign_keys WHERE table_schema = \(literal(database)) AND table_name = \(literal(table))
            ORDER BY constraint_name, ordinal_position
            """)
        var keys: [ForeignKeyDetail] = []
        for row in rows {
            let name = row[0] ?? ""
            if let last = keys.indices.last, keys[last].name == name {
                keys[last].columns.append(row[1] ?? "")
                keys[last].referencedColumns.append(row[4] ?? "")
            } else {
                keys.append(
                    ForeignKeyDetail(
                        name: name, columns: [row[1] ?? ""], referencedDatabase: row[2] ?? database,
                        referencedTable: row[3] ?? "", referencedColumns: [row[4] ?? ""], onUpdate: "NO ACTION",
                        onDelete: "NO ACTION"))
            }
        }
        return keys
    }

    public func createStatement(of table: String, in database: String) async throws -> String {
        let name = VerticaDialect().qualified(database, table)
        guard let ddl = try await textRows("SELECT EXPORT_OBJECTS('', \(literal(name)), false)").first?.first ?? nil
        else { throw DatabaseError(.query, "Vertica didn't return a definition for \(table).") }
        return ddl.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func characterSets() async throws -> [CharacterSetInfo] { [] }

    // MARK: Processes

    public func processList() async throws -> [ServerProcess] {
        let rows = try await textRows(
            """
            SELECT session_id, user_name, client_hostname, current_statement,
                DATEDIFF('second', statement_start, NOW()), transaction_description, last_statement
            FROM v_monitor.sessions ORDER BY login_timestamp
            """)
        sessionIDs = [:]
        return rows.enumerated().compactMap { index, row in
            guard let session = row[0] else { return nil }
            let id = UInt64(index + 1)
            sessionIDs[id] = session
            let statement = row[3].flatMap { $0.isEmpty ? nil : $0 }
            return ServerProcess(
                id: id, user: row[1] ?? "", host: row[2] ?? "", database: config.database,
                command: statement == nil ? "Idle" : "Query", seconds: Int(row[4] ?? "") ?? 0, state: row[5],
                info: statement ?? row[6])
        }
    }

    public func kill(processID: UInt64, connection: Bool) async throws {
        guard let session = sessionIDs[processID] else { return }
        _ = try await execute(
            connection
                ? "SELECT CLOSE_SESSION(\(literal(session)))" : "SELECT INTERRUPT_STATEMENT(\(literal(session)), -1)")
    }
}

/// A RowDescription field (protocol 3.16 layout).
struct VerticaColumn {
    var name: String
    var table: String?
    var typeOID: UInt32
    var typeModifier: Int32
    var udtName: String?

    static func parse(_ body: inout ByteBuffer) throws -> [VerticaColumn] {
        guard let count = body.readInteger(as: UInt16.self) else { throw VerticaProtocol.protocolError }
        guard count > 0 else { return [] }
        // User-defined types (GEOMETRY…) are listed once and referenced by index.
        var pool: [String] = []
        let poolCount = body.readInteger(as: UInt32.self) ?? 0
        for _ in 0..<poolCount {
            _ = body.readInteger(as: UInt32.self)
            pool.append(body.readNullTerminatedString() ?? "")
        }
        var columns: [VerticaColumn] = []
        for _ in 0..<count {
            let name = body.readNullTerminatedString() ?? ""
            let tableOID = body.readInteger(as: UInt64.self) ?? 0
            var table: String?
            if tableOID != 0 {
                _ = body.readNullTerminatedString()  // schema
                table = body.readNullTerminatedString()
            }
            _ = body.readInteger(as: UInt16.self)  // attribute number
            let isUDT = body.readInteger(as: UInt8.self) == 1
            let oid = body.readInteger(as: UInt32.self) ?? 0
            _ = body.readInteger(as: Int16.self)  // size
            _ = body.readInteger(as: UInt16.self)  // nullable
            _ = body.readInteger(as: UInt16.self)  // identity
            let modifier = body.readInteger(as: Int32.self) ?? -1
            _ = body.readInteger(as: UInt16.self)  // format
            columns.append(
                VerticaColumn(
                    name: name, table: table, typeOID: isUDT ? 0 : oid, typeModifier: modifier,
                    udtName: isUDT && Int(oid) < pool.count ? pool[Int(oid)] : nil))
        }
        return columns
    }

    var typeName: String {
        if let udtName { return udtName }
        switch typeOID {
        case 5: return "boolean"
        case 6: return "int"
        case 7: return "float"
        case 8: return "char"
        case 9: return "varchar"
        case 10: return "date"
        case 11: return "time"
        case 12: return "timestamp"
        case 13: return "timestamptz"
        case 14: return "interval"
        case 15: return "timetz"
        case 16:
            guard typeModifier != -1 else { return "numeric" }
            return "numeric(\(((typeModifier - 4) >> 16) & 0xFFFF),\((typeModifier - 4) & 0xFF))"
        case 17: return "varbinary"
        case 20: return "uuid"
        case 114: return "interval year to month"
        case 115: return "long varchar"
        case 116: return "long varbinary"
        case 117: return "binary"
        case 300: return "row"
        case 301, 1500...1599: return "array"
        case 302: return "map"
        case 2700...2799: return "set"
        default: return "type \(typeOID)"
        }
    }

    func decode(_ bytes: [UInt8]) -> CellValue {
        let text = String(decoding: bytes, as: UTF8.self)
        switch typeOID {
        case 5: return .bool(text == "t")
        case 6: return Int64(text).map(CellValue.int) ?? .text(text)
        case 7: return Double(text).map(CellValue.double) ?? .text(text)
        case 16: return .decimal(text)
        case 10, 11, 12, 13, 14, 15, 114: return .temporal(text)
        case 17, 116, 117: return .bytes(Self.unescapeBinary(bytes))
        case 20: return UUID(uuidString: text).map(CellValue.uuid) ?? .text(text)
        case 300, 301, 302, 1500...1599, 2700...2799: return .json(text)
        default: return .text(text)
        }
    }

    /// Binary text format: `\\` is a backslash, `\ooo` an octal byte, everything else literal.
    static func unescapeBinary(_ bytes: [UInt8]) -> Data {
        var data = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x5C, index + 1 < bytes.count {
                if bytes[index + 1] == 0x5C {
                    data.append(0x5C)
                    index += 2
                    continue
                }
                if index + 3 < bytes.count,
                    let value = UInt8(String(decoding: bytes[(index + 1)...(index + 3)], as: UTF8.self), radix: 8)
                {
                    data.append(value)
                    index += 4
                    continue
                }
            }
            data.append(bytes[index])
            index += 1
        }
        return data
    }
}
