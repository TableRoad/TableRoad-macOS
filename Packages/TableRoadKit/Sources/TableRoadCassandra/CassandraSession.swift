import Foundation
import NIOCore
import NIOSSL
import TableRoadCore
import TableRoadSQL

/// Settings for a Cassandra (or ScyllaDB, DataStax) node's native protocol port.
public struct CassandraConnectConfig: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    /// Keyspace to USE after connecting.
    public var keyspace: String?
    /// Cassandra has no STARTTLS: `prefer` tries TLS first and falls back to a plain connection.
    public var tls: TLSMode
    public var tlsFiles: TLSFiles

    public init(
        host: String, port: Int = 9042, username: String = "", password: String? = nil, keyspace: String? = nil,
        tls: TLSMode = .disable, tlsFiles: TLSFiles = TLSFiles()
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.keyspace = keyspace
        self.tls = tls
        self.tlsFiles = tlsFiles
    }

    public init(profile: ConnectionProfile, password: String?) {
        self.init(
            host: profile.host, port: profile.port, username: profile.username, password: password,
            keyspace: profile.database.flatMap { $0.isEmpty ? nil : $0 }, tls: profile.tls, tlsFiles: profile.tlsFiles)
    }
}

/// A Cassandra connection over the CQL native protocol (v4). Keyspaces are shown as databases.
///
/// There are no transactions: edits run as one logged BATCH (atomic, not isolated). Edit values arrive as text and
/// are written as literals of each column's type, which PREPARE reports. Statements can't be cancelled.
public actor CassandraSession: SQLClient {
    private let connection: CQLConnection
    private let lock = AsyncSerialLock()
    public let kind: DatabaseKind = .cassandra
    public let serverVersion: String
    public private(set) var currentDatabase: String?
    /// "keyspace.table" → column name → CQL type, for typing filter literals. Cleared on any schema change.
    private var columnTypes: [String: [String: String]] = [:]

    public nonisolated var sqlDialect: any SQLDialect { CassandraDialect() }
    public nonisolated var processID: UInt64 { 0 }
    public nonisolated let isEncrypted: Bool
    public nonisolated var tlsCipher: String? { isEncrypted ? "TLS" : nil }
    public nonisolated var capabilities: ClientCapabilities {
        ClientCapabilities(processList: false, createDatabases: true, databaseNoun: "keyspace", cancel: false)
    }

    static let systemKeyspaces: Set<String> = [
        "system", "system_auth", "system_schema", "system_distributed", "system_traces", "system_views",
        "system_virtual_schema",
    ]
    /// Rows per protocol page; results are read page by page with the paging state.
    static let pageSize: Int32 = 5000
    /// Sorting on a column the server can't ORDER BY reads the table here, up to this many rows.
    static let localSortLimit = 100_000

    public static func connect(_ config: CassandraConnectConfig) async throws -> CassandraSession {
        let connection = try await openConnection(config)
        do {
            guard case .rows(let local) = try await connection.query("SELECT release_version FROM system.local"),
                let version = local.rows.first?.first?.displayText
            else { throw DatabaseError(.connection, "The server didn't describe itself.") }
            var keyspace: String?
            if let wanted = config.keyspace,
                case .setKeyspace(let name) = try await connection.query(
                    "USE \(CassandraDialect().quoteIdentifier(wanted))")
            {
                keyspace = name
            }
            return CassandraSession(connection: connection, version: version, keyspace: keyspace)
        } catch {
            await connection.close()
            throw error
        }
    }

    private init(connection: CQLConnection, version: String, keyspace: String?) {
        self.connection = connection
        serverVersion = version
        currentDatabase = keyspace
        isEncrypted = connection.isEncrypted
    }

    static func openConnection(_ config: CassandraConnectConfig) async throws -> CQLConnection {
        var endpoint = CQLConnection.Endpoint(
            host: config.host, port: config.port, username: config.username, password: config.password, tls: nil)
        switch config.tls {
        case .disable:
            return try await CQLConnection.open(endpoint)
        case .prefer:
            endpoint.tls = try makeContext(.none, files: config.tlsFiles)
            do {
                return try await CQLConnection.open(endpoint)
            } catch let error as DatabaseError where error.category == .tls || error.category == .connection {
                endpoint.tls = nil  // no TLS on this port
                return try await CQLConnection.open(endpoint)
            }
        case .require:
            endpoint.tls = try makeContext(.none, files: config.tlsFiles)
        case .verifyCA:
            endpoint.tls = try makeContext(.noHostnameVerification, files: config.tlsFiles)
        case .verifyFull:
            endpoint.tls = try makeContext(.fullVerification, files: config.tlsFiles)
        }
        return try await CQLConnection.open(endpoint)
    }

    static func makeContext(_ verification: CertificateVerification, files: TLSFiles) throws -> NIOSSLContext {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = verification
        func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
        do {
            if let ca = files.caCertPath { tls.trustRoots = .file(expand(ca)) }
            if let cert = files.clientCertPath {
                tls.certificateChain = try NIOSSLCertificate.fromPEMFile(expand(cert)).map { .certificate($0) }
            }
            if let key = files.clientKeyPath {
                tls.privateKey = .privateKey(try NIOSSLPrivateKey(file: expand(key), format: .pem))
            }
            return try NIOSSLContext(configuration: tls)
        } catch {
            throw DatabaseError(.tls, "Couldn't set up TLS: \(error)")
        }
    }

    public func close() async { await connection.close() }

    // MARK: Statements

    public func execute(_ sql: String) async throws -> QueryOutcome {
        try await lock.run { try await self.executeLocked(sql) }
    }

    private func executeLocked(_ sql: String) async throws -> QueryOutcome {
        let (statement, offset) = CassandraDialect.extractOffset(Self.trimmed(sql))
        var cql = statement
        let isSelect = Self.keyword(of: cql) == "SELECT"
        if isSelect { cql = await typedLiterals(cql) }
        do {
            return try await fetch(cql, skip: offset ?? 0)
        } catch let error as DatabaseError where error.category == .query {
            let message = error.message.lowercased()
            // The data browser sorting on a column the server can't ORDER BY: sort here instead.
            if let offset, message.contains("order by") {
                return try await sortedLocally(cql, offset: offset)
            }
            // The browser's COUNT(*) with a filter on a non-key column.
            if isSelect, message.contains("allow filtering"),
                cql.range(of: #"^SELECT\s+COUNT\(\*\)\s+FROM"#, options: [.regularExpression, .caseInsensitive]) != nil
            {
                return try await fetch(cql + " ALLOW FILTERING", skip: 0)
            }
            throw error
        }
    }

    /// Runs one statement, reading every result page, skipping the first `skip` rows.
    private func fetch(_ cql: String, skip: Int = 0, cap: Int? = nil) async throws -> QueryOutcome {
        var pagingState: ByteBuffer?
        var columns: [CQLColumn] = []
        var rows: [[CellValue]] = []
        var skipped = 0
        repeat {
            switch try await connection.query(cql, pageSize: Self.pageSize, pagingState: pagingState) {
            case .rows(let page):
                if !page.columns.isEmpty { columns = page.columns }
                let dropped = min(skip - skipped, page.rows.count)
                skipped += dropped
                rows.append(contentsOf: page.rows.dropFirst(dropped))
                if let cap, rows.count > cap { throw Self.tooManyToSort }
                pagingState = page.pagingState
            case .setKeyspace(let keyspace):
                currentDatabase = keyspace
                return .affected(rowCount: 0)
            case .schemaChange:
                columnTypes = [:]
                return .affected(rowCount: 0)
            case .void, .prepared:
                return .affected(rowCount: 0)
            }
        } while pagingState != nil
        return .rows(
            ResultSet(
                columns: columns.map {
                    ResultColumn(name: $0.name, table: $0.table.isEmpty ? nil : $0.table, typeName: $0.type.name)
                }, rows: rows))
    }

    static var tooManyToSort: DatabaseError {
        DatabaseError(
            .query,
            "Cassandra can only sort by clustering columns within one partition. Sorting by this column reads the "
                + "whole table, which has more than \(localSortLimit.formatted()) rows: filter it first.")
    }

    /// `SELECT … ORDER BY a ASC, b DESC LIMIT n ALLOW FILTERING`: reads without ORDER BY and sorts here.
    private func sortedLocally(_ cql: String, offset: Int) async throws -> QueryOutcome {
        guard let order = cql.range(of: " ORDER BY ", options: [.backwards, .caseInsensitive]) else {
            throw DatabaseError(.query, "Couldn't sort this query.")
        }
        let tail = cql[order.upperBound...]
        guard
            let limitRange = tail.range(
                of: #"\s+LIMIT\s+\d+(\s+ALLOW\s+FILTERING)?\s*$"#, options: [.regularExpression, .caseInsensitive]),
            let limit = Int(tail[limitRange].filter(\.isNumber))
        else { throw DatabaseError(.query, "Couldn't sort this query.") }
        var keys: [(name: String, ascending: Bool)] = []
        for token in CQLScanner.tokens(String(tail[..<limitRange.lowerBound])) {
            if token.kind == .word, ["ASC", "DESC"].contains(token.value.uppercased()), !keys.isEmpty {
                keys[keys.count - 1].ascending = token.value.uppercased() == "ASC"
            } else if let name = CQLScanner.identifier(token) {
                keys.append((name, true))
            }
        }
        guard
            case .rows(let all) = try await fetch(
                cql[..<order.lowerBound] + " ALLOW FILTERING", skip: 0, cap: Self.localSortLimit)
        else { throw DatabaseError(.query, "Couldn't sort this query.") }
        let indexes = keys.compactMap { key in
            all.columns.firstIndex { $0.name == key.name }.map { ($0, key.ascending) }
        }
        let sorted = all.rows.enumerated().sorted { left, right in
            for (index, ascending) in indexes {
                let order = Self.compare(left.element[index], right.element[index])
                if order != 0 { return ascending ? order < 0 : order > 0 }
            }
            return left.offset < right.offset
        }.map(\.element)
        let start = min(offset, sorted.count)
        return .rows(ResultSet(columns: all.columns, rows: Array(sorted[start..<min(max(limit, start), sorted.count)])))
    }

    /// Orders values for local sorting: NULL first, numbers numerically, everything else by text.
    static func compare(_ left: CellValue, _ right: CellValue) -> Int {
        func number(_ value: CellValue) -> Double? {
            switch value {
            case .int(let n): Double(n)
            case .uint(let n): Double(n)
            case .double(let n): n
            case .decimal(let text): Double(text)
            default: nil
            }
        }
        switch (left, right) {
        case (.null, .null): return 0
        case (.null, _): return -1
        case (_, .null): return 1
        case (.int(let a), .int(let b)): return a < b ? -1 : a > b ? 1 : 0
        case (.bool(let a), .bool(let b)): return a == b ? 0 : a ? 1 : -1
        default:
            if let a = number(left), let b = number(right) { return a < b ? -1 : a > b ? 1 : 0 }
            let a = left.displayText ?? ""
            let b = right.displayText ?? ""
            return a < b ? -1 : a > b ? 1 : 0
        }
    }

    /// CQL won't compare a number (or uuid, boolean, blob) column with a string literal, but the filter bar always
    /// writes `'…'`: rewrite those literals for the queried table's column types.
    private func typedLiterals(_ cql: String) async -> String {
        let tokens = CQLScanner.tokens(cql)
        guard let target = CQLScanner.fromTarget(tokens), let keyspace = target.keyspace ?? currentDatabase,
            let types = try? await columnTypeMap(keyspace, target.table)
        else { return cql }
        func bareType(_ token: CQLToken) -> CQLType? {
            guard let name = CQLScanner.identifier(token), let typeName = types[name],
                let type = CQLType(scalarName: typeName)
            else { return nil }
            switch type {
            case .ascii, .varchar, .inet, .date, .time, .timestamp: return nil  // strings are fine
            default: return type
            }
        }
        var replacements: [(Range<String.Index>, String)] = []
        func retype(_ token: CQLToken, _ type: CQLType) {
            if token.kind == .string, let literal = try? CQLLiteral.render(token.value, as: type) {
                replacements.append((token.range, literal))
            }
        }
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            guard let type = bareType(tokens[index]) else { continue }
            var next = index + 1
            guard next < tokens.count else { break }
            if tokens[next].kind == .symbol, ["=", "<>", "!=", "<", "<=", ">", ">="].contains(tokens[next].value),
                next + 1 < tokens.count
            {
                retype(tokens[next + 1], type)
                continue
            }
            if tokens[next].kind == .word, tokens[next].value.uppercased() == "NOT" { next += 1 }
            guard next + 1 < tokens.count, tokens[next].kind == .word, tokens[next].value.uppercased() == "IN",
                tokens[next + 1].value == "("
            else { continue }
            var item = next + 2
            while item < tokens.count, tokens[item].value != ")" {
                retype(tokens[item], type)
                item += 1
            }
        }
        var output = cql
        for (range, literal) in replacements.reversed() {
            output = String(output[..<range.lowerBound]) + literal + String(output[range.upperBound...])
        }
        return output
    }

    private func columnTypeMap(_ keyspace: String, _ table: String) async throws -> [String: String] {
        let key = keyspace + "." + table
        if let cached = columnTypes[key] { return cached }
        let q = CassandraDialect()
        var map: [String: String] = [:]
        for row in try await rows(
            "SELECT column_name, type FROM system_schema.columns WHERE keyspace_name = \(q.stringLiteral(keyspace)) "
                + "AND table_name = \(q.stringLiteral(table))")
        {
            if let name = row[0].displayText, let type = row[1].displayText { map[name] = type }
        }
        columnTypes[key] = map
        return map
    }

    public func run(_ sql: String) async throws {
        for statement in StatementSplitter(syntax: .cql).split(sql) {
            _ = try await execute(statement.text)
        }
    }

    /// No transactions: every statement is checked and typed first (PREPARE), then all run as one logged BATCH,
    /// which Cassandra applies completely or not at all. CQL doesn't report affected rows, so each counts as 1.
    public func executeTransaction(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        try await lock.run { try await self.transactionLocked(statements) }
    }

    private func transactionLocked(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        var cql: [String] = []
        for (index, statement) in statements.enumerated() {
            do {
                cql.append(try await inlined(statement))
            } catch {
                throw TransactionError(statementIndex: index, underlying: Self.databaseError(error))
            }
        }
        guard !cql.isEmpty else { return [] }
        let script = cql.count == 1 ? cql[0] : "BEGIN BATCH\n" + cql.map { "  " + $0 + ";\n" }.joined() + "APPLY BATCH"
        do {
            _ = try await fetch(script)
        } catch {
            let underlying = Self.databaseError(error)
            throw TransactionError(
                statementIndex: 0, underlying: underlying, commitOutcomeUnknown: underlying.category == .connection)
        }
        return statements.map { _ in 1 }
    }

    /// The statement with its `?` values written as literals of the types PREPARE reports.
    private func inlined(_ statement: ParameterizedStatement) async throws -> String {
        let sql = Self.trimmed(statement.sql)
        guard !statement.parameters.isEmpty else { return sql }
        let prepared = try await connection.prepare(sql)
        guard prepared.variables.count == statement.parameters.count else {
            throw DatabaseError(
                .query,
                "The statement has \(prepared.variables.count) markers but \(statement.parameters.count) values.")
        }
        let literals = try zip(statement.parameters, prepared.variables).map { parameter, variable in
            switch parameter {
            case .null: "null"
            case .text(let text): try CQLLiteral.render(text, as: variable.type)
            }
        }
        return CQLScanner.substitute(sql, literals)
    }

    public func cancelCurrentQuery() async throws {
        throw DatabaseError(.unsupported, "Cassandra can't cancel a running query.")
    }

    public func processList() async throws -> [ServerProcess] { [] }

    public func kill(processID: UInt64, connection: Bool) async throws {
        throw DatabaseError(.unsupported, "Cassandra has no process list.")
    }

    // MARK: Introspection

    public func useDatabase(_ name: String) async throws {
        _ = try await execute("USE \(CassandraDialect().quoteIdentifier(name))")
    }

    public func databases() async throws -> [String] {
        try await rows("SELECT keyspace_name FROM system_schema.keyspaces").compactMap { $0.first?.displayText }
            .filter { !Self.systemKeyspaces.contains($0) }.sorted()
    }

    public func tables(in database: String) async throws -> [TableInfo] {
        let keyspace = CassandraDialect().stringLiteral(database)
        let tables = try await rows("SELECT table_name FROM system_schema.tables WHERE keyspace_name = \(keyspace)")
        let views = try await rows("SELECT view_name FROM system_schema.views WHERE keyspace_name = \(keyspace)")
        let estimates = (try? await sizeEstimates(database)) ?? [:]
        let items =
            tables.compactMap { $0.first?.displayText }.map {
                TableInfo(name: $0, kind: .table, estimatedRowCount: estimates[$0]?.partitions)
            } + views.compactMap { $0.first?.displayText }.map { TableInfo(name: $0, kind: .view) }
        return items.sorted { $0.name < $1.name }
    }

    /// Partition counts and bytes per table from `system.size_estimates` (refreshed by the server every few minutes).
    private func sizeEstimates(_ database: String) async throws -> [String: (partitions: Int, bytes: Int)] {
        var result: [String: (partitions: Int, bytes: Int)] = [:]
        for row in try await rows(
            "SELECT table_name, partitions_count, mean_partition_size FROM system.size_estimates "
                + "WHERE keyspace_name = \(CassandraDialect().stringLiteral(database))")
        {
            guard let table = row[0].displayText, case .int(let partitions) = row[1], case .int(let size) = row[2]
            else { continue }
            let current = result[table] ?? (0, 0)
            result[table] = (current.partitions + Int(partitions), current.bytes + Int(partitions * size))
        }
        return result
    }

    public func tableSizes(in database: String) async throws -> [String: Int64] {
        try await sizeEstimates(database).mapValues { Int64($0.bytes) }
    }

    private struct SchemaColumn {
        var name: String
        var type: String
        var kind: String
        var position: Int
        var order: String

        /// `SELECT *` order: partition key, clustering columns, static, regular.
        var rank: Int { ["partition_key": 0, "clustering": 1, "static": 2][kind] ?? 3 }
    }

    private func schemaColumns(_ table: String, _ database: String) async throws -> [SchemaColumn] {
        let q = CassandraDialect()
        let columns = try await rows(
            "SELECT column_name, type, kind, position, clustering_order FROM system_schema.columns "
                + "WHERE keyspace_name = \(q.stringLiteral(database)) AND table_name = \(q.stringLiteral(table))"
        ).map { row in
            var position = 0
            if case .int(let value) = row[3] { position = Int(value) }
            return SchemaColumn(
                name: row[0].displayText ?? "", type: row[1].displayText ?? "", kind: row[2].displayText ?? "",
                position: position, order: row[4].displayText ?? "none")
        }
        guard !columns.isEmpty else { throw DatabaseError(.query, "Table \(database).\(table) doesn't exist.") }
        columnTypes[database + "." + table] = Dictionary(columns.map { ($0.name, $0.type) }) { first, _ in first }
        return columns.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.rank < 2 ? $0.position < $1.position : $0.name < $1.name
        }
    }

    public func columns(of table: String, in database: String) async throws -> [ColumnDetail] {
        try await schemaColumns(table, database).map { column in
            let extra: String? =
                switch column.rank {
                case 0: "partition key"
                case 1: "clustering key (\(column.order.uppercased()))"
                case 2: "static"
                default: nil
                }
            return ColumnDetail(
                name: column.name, type: column.type, isNullable: column.rank >= 2, isPrimaryKey: column.rank < 2,
                extra: extra)
        }
    }

    public func tableStatus(of table: String, in database: String) async throws -> TableStatus {
        let q = CassandraDialect()
        let estimate = (try? await sizeEstimates(database))?[table]
        let filter = "WHERE keyspace_name = \(q.stringLiteral(database)) AND table_name = \(q.stringLiteral(table))"
        let comment =
            (try? await rows("SELECT comment FROM system_schema.tables \(filter)"))?.first?.first?.displayText
        return TableStatus(
            estimatedRows: estimate?.partitions, dataBytes: estimate?.bytes,
            comment: comment.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The primary key (as "PRIMARY") and secondary / SAI indexes.
    public func indexes(of table: String, in database: String) async throws -> [IndexDetail] {
        let q = CassandraDialect()
        let key = try await schemaColumns(table, database).filter { $0.rank < 2 }.map(\.name)
        var result = [IndexDetail(name: "PRIMARY", algorithm: "PRIMARY KEY", isUnique: true, columns: key)]
        for row in try await rows(
            "SELECT index_name, kind, options FROM system_schema.indexes WHERE keyspace_name = "
                + "\(q.stringLiteral(database)) AND table_name = \(q.stringLiteral(table))")
        {
            let options = Self.options(row[2])
            var algorithm = row[1].displayText == "CUSTOM" ? "CUSTOM" : "SECONDARY"
            if let className = options["class_name"] {
                let short = className.split(separator: ".").last.map(String.init) ?? className
                algorithm = short == "StorageAttachedIndex" ? "SAI" : short
            }
            result.append(
                IndexDetail(
                    name: row[0].displayText ?? "", algorithm: algorithm, isUnique: false,
                    columns: [options["target"] ?? ""]))
        }
        return result
    }

    private static func options(_ value: CellValue) -> [String: String] {
        guard case .json(let text) = value,
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]
        else { return [:] }
        return object
    }

    public func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail] { [] }

    /// Server-side DESCRIBE (Cassandra 4+), which includes the table's indexes; built from the schema otherwise.
    public func createStatement(of table: String, in database: String) async throws -> String {
        let name = CassandraDialect().qualified(database, table)
        for command in ["DESCRIBE TABLE", "DESCRIBE MATERIALIZED VIEW"] {
            guard case .rows(let result) = try? await fetch("\(command) \(name)"),
                let column = result.columns.firstIndex(where: { $0.name == "create_statement" })
            else { continue }
            let statements = result.rows.compactMap { $0[column].displayText }
            if !statements.isEmpty { return statements.joined(separator: "\n\n") }
        }
        return try await builtCreateStatement(table, database)
    }

    private func builtCreateStatement(_ table: String, _ database: String) async throws -> String {
        let q = CassandraDialect()
        let columns = try await schemaColumns(table, database)
        let partition = columns.filter { $0.rank == 0 }.map { q.quoteIdentifier($0.name) }
        let clustering = columns.filter { $0.rank == 1 }
        var key = partition.count == 1 ? partition[0] : "(" + partition.joined(separator: ", ") + ")"
        if !clustering.isEmpty { key += ", " + clustering.map { q.quoteIdentifier($0.name) }.joined(separator: ", ") }
        var lines = columns.map { "    \(q.quoteIdentifier($0.name)) \($0.type)\($0.rank == 2 ? " static" : "")," }
        lines.append("    PRIMARY KEY (\(key))")
        var ddl = "CREATE TABLE \(q.qualified(database, table)) (\n" + lines.joined(separator: "\n") + "\n)"
        if clustering.contains(where: { $0.order.lowercased() == "desc" }) {
            ddl +=
                " WITH CLUSTERING ORDER BY ("
                + clustering.map { "\(q.quoteIdentifier($0.name)) \($0.order.uppercased())" }.joined(separator: ", ")
                + ")"
        }
        ddl += ";"
        for index in try await indexes(of: table, in: database) where !index.isPrimary {
            ddl +=
                "\n\nCREATE INDEX \(q.quoteIdentifier(index.name)) ON \(q.qualified(database, table)) "
                + "(\(index.columns.first ?? ""));"
        }
        return ddl
    }

    public func characterSets() async throws -> [CharacterSetInfo] { [] }

    // MARK: Helpers

    private func rows(_ cql: String) async throws -> [[CellValue]] {
        guard case .rows(let result) = try await fetch(cql) else { return [] }
        return result.rows
    }

    static func trimmed(_ sql: String) -> String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
    }

    static func keyword(of cql: String) -> String {
        String(cql.prefix { $0.isLetter }).uppercased()
    }

    static func databaseError(_ error: any Error) -> DatabaseError {
        error as? DatabaseError ?? DatabaseError(.query, error.localizedDescription)
    }
}
