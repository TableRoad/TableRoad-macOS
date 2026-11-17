import Foundation
import TableRoadCore
import TableRoadSQL

/// ClickHouse spelling: backticks, backslash escapes, LIKE escaped with backslash (no ESCAPE clause).
public struct ClickHouseDialect: SQLDialect {
    public var family: SQLFamily { .clickhouse }
    public init() {}

    public func quoteIdentifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`") + "`"
    }

    public func stringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    public func bytesLiteral(_ data: Data) -> String {
        "unhex('" + data.map { String(format: "%02X", $0) }.joined() + "')"
    }

    public func useDatabaseSQL(_ name: String) -> String? { "USE \(quoteIdentifier(name))" }
    public var likeEscapeCharacter: String { "\\" }
    public var likeEscapeClause: String { "" }

    /// Arrays/maps decoded from JSON become ClickHouse literals: `['a', 'b']`, `map('k', 1)`.
    public func jsonLiteral(_ json: String) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else {
            return stringLiteral(json)
        }
        return literal(value)
    }

    private func literal(_ value: Any) -> String {
        switch value {
        case is NSNull: return "NULL"
        case let text as String: return stringLiteral(text)
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID()
                ? (number.boolValue ? "true" : "false") : number.stringValue
        case let array as [Any]: return "[" + array.map(literal).joined(separator: ", ") + "]"
        case let object as [String: Any]:
            return "map("
                + object.sorted { $0.key < $1.key }.map { stringLiteral($0.key) + ", " + literal($0.value) }
                .joined(separator: ", ") + ")"
        default: return stringLiteral("\(value)")
        }
    }
}

/// Settings for a ClickHouse server's HTTP interface (8123, or 8443 with TLS).
public struct ClickHouseConnectConfig: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var database: String?
    public var useTLS: Bool

    public init(
        host: String, port: Int = 8123, username: String = "default", password: String? = nil,
        database: String? = nil, useTLS: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.useTLS = useTLS
    }

    public init(profile: ConnectionProfile, password: String?) {
        self.init(
            host: profile.host, port: profile.port, username: profile.username.isEmpty ? "default" : profile.username,
            password: password, database: profile.database.flatMap { $0.isEmpty ? nil : $0 },
            useTLS: profile.tls == .require || profile.tls == .verifyCA || profile.tls == .verifyFull)
    }
}

/// A ClickHouse connection over HTTP. Each statement is one request (HTTP is stateless), so the current database is
/// tracked here and sent with every request. ClickHouse has no transactions and no unique keys: tables open
/// read-only in the browser.
public actor ClickHouseSession: SQLClient {
    private let config: ClickHouseConnectConfig
    private let http: URLSession
    public let kind: DatabaseKind = .clickhouse
    public let serverVersion: String
    public private(set) var currentDatabase: String?
    /// The running statement's query_id, for KILL QUERY.
    private var runningQuery: String?
    /// Process ids shown in the list → ClickHouse query ids (which are strings).
    private var queryIDs: [UInt64: String] = [:]

    public nonisolated var sqlDialect: any SQLDialect { ClickHouseDialect() }
    public nonisolated var processID: UInt64 { 0 }
    public nonisolated let isEncrypted: Bool
    public nonisolated var tlsCipher: String? { isEncrypted ? "HTTPS" : nil }
    public nonisolated var capabilities: ClientCapabilities {
        ClientCapabilities(processList: true, createDatabases: true)
    }

    public static func connect(_ config: ClickHouseConnectConfig) async throws -> ClickHouseSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3600
        configuration.httpMaximumConnectionsPerHost = 4
        let http = URLSession(configuration: configuration)
        let probe = try await request(
            config, http: http, sql: "SELECT version(), currentDatabase() FORMAT JSONCompact",
            database: config.database,
            queryID: UUID().uuidString)
        guard let row = probe.rows.first, row.count == 2 else {
            throw DatabaseError(.connection, "The server didn't answer like ClickHouse.")
        }
        return ClickHouseSession(
            config: config, http: http, version: row[0].displayText ?? "", database: row[1].displayText)
    }

    private init(config: ClickHouseConnectConfig, http: URLSession, version: String, database: String?) {
        self.config = config
        self.http = http
        serverVersion = version
        currentDatabase = database
        isEncrypted = config.useTLS
    }

    public func close() async { http.invalidateAndCancel() }

    // MARK: Statements

    public func execute(_ sql: String) async throws -> QueryOutcome {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        if let database = Self.useTarget(trimmed) {
            try await useDatabase(database)
            return .affected(rowCount: 0)
        }
        let returnsRows = Self.returnsRows(trimmed)
        let body = returnsRows && !Self.hasFormat(trimmed) ? trimmed + "\nFORMAT JSONCompact" : trimmed
        let id = UUID().uuidString
        runningQuery = id
        defer { runningQuery = nil }
        let response = try await Self.request(config, http: http, sql: body, database: currentDatabase, queryID: id)
        if returnsRows { return .rows(response.resultSet) }
        // Dropping the current database: later requests must not name it.
        if let current = currentDatabase,
            trimmed.range(
                of:
                    #"^DROP\s+DATABASE\s+(IF\s+EXISTS\s+)?[`"]?\#(NSRegularExpression.escapedPattern(for: current))[`"]?$"#,
                options: [.regularExpression, .caseInsensitive]) != nil
        {
            currentDatabase = "default"
        }
        return .affected(rowCount: response.writtenRows)
    }

    public func run(_ sql: String) async throws {
        for statement in StatementSplitter(syntax: .mysql).split(sql) {
            _ = try await execute(statement.text)
        }
    }

    /// No transactions: statements run one after another (tables are read-only in the browser anyway).
    public func executeTransaction(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        var affected: [UInt64] = []
        for (index, statement) in statements.enumerated() {
            do {
                guard case .affected(let count) = try await execute(statement.inlined(ClickHouseDialect())) else {
                    affected.append(0)
                    continue
                }
                affected.append(count)
            } catch {
                throw TransactionError(
                    statementIndex: index,
                    underlying: error as? DatabaseError ?? DatabaseError(.query, error.localizedDescription))
            }
        }
        return affected
    }

    public func cancelCurrentQuery() async throws {
        guard let id = runningQuery else { return }
        try await killQuery(id)
    }

    private nonisolated func killQuery(_ id: String) async throws {
        _ = try await Self.request(
            config, http: URLSession.shared,
            sql: "KILL QUERY WHERE query_id = \(ClickHouseDialect().stringLiteral(id)) ASYNC FORMAT JSONCompact",
            database: nil, queryID: UUID().uuidString)
    }

    public func processList() async throws -> [ServerProcess] {
        let result = try await rows(
            "SELECT query_id, user, address, current_database, toUInt64(elapsed), query FROM system.processes")
        queryIDs = [:]
        return result.compactMap { row in
            guard let queryID = row[0] else { return nil }
            let id = Self.stableID(queryID)
            queryIDs[id] = queryID
            return ServerProcess(
                id: id, user: row[1] ?? "", host: row[2] ?? "", database: row[3], command: "Query",
                seconds: Int(row[4] ?? "0") ?? 0, state: "running", info: row[5])
        }
    }

    public func kill(processID: UInt64, connection: Bool) async throws {
        guard let queryID = queryIDs[processID] else {
            throw DatabaseError(.query, "That query has finished or the list is out of date. Refresh and try again.")
        }
        try await killQuery(queryID)
    }

    /// FNV-1a: a stable numeric id for a ClickHouse query id.
    static func stableID(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash & 0x7FFF_FFFF_FFFF_FFFF
    }

    // MARK: Introspection

    public func useDatabase(_ name: String) async throws {
        guard try await databases().contains(name) else {
            throw DatabaseError(.query, "Database \(name) doesn't exist.")
        }
        currentDatabase = name
    }

    public func databases() async throws -> [String] {
        try await rows("SELECT name FROM system.databases ORDER BY name").compactMap { $0.first ?? nil }
    }

    public func tables(in database: String) async throws -> [TableInfo] {
        let q = ClickHouseDialect()
        return try await rows(
            "SELECT name, engine, total_rows FROM system.tables WHERE database = \(q.stringLiteral(database)) "
                + "ORDER BY name"
        ).map { row in
            let engine = row[1] ?? ""
            return TableInfo(
                name: row[0] ?? "", kind: engine.hasSuffix("View") ? .view : .table,
                estimatedRowCount: row[2].flatMap { Int($0) })
        }
    }

    public func columns(of table: String, in database: String) async throws -> [ColumnDetail] {
        let q = ClickHouseDialect()
        return try await rows(
            """
            SELECT name, type, default_kind, default_expression, comment, is_in_sorting_key
            FROM system.columns WHERE database = \(q.stringLiteral(database)) AND table = \(q.stringLiteral(table))
            ORDER BY position
            """
        ).map { row in
            let type = row[1] ?? ""
            let kind = row[2] ?? ""
            return ColumnDetail(
                // Sorting keys aren't unique, so nothing is a primary key for editing purposes.
                name: row[0] ?? "", type: type, isNullable: type.hasPrefix("Nullable("), isPrimaryKey: false,
                defaultValue: kind == "DEFAULT" ? row[3] : nil,
                extra: ["MATERIALIZED", "ALIAS"].contains(kind)
                    ? "\(kind == "ALIAS" ? "VIRTUAL" : "STORED") GENERATED" : (row[5] == "1" ? "sorting key" : nil),
                comment: row[4].flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    public func tableStatus(of table: String, in database: String) async throws -> TableStatus {
        let q = ClickHouseDialect()
        let result = try await rows(
            """
            SELECT total_rows, total_bytes, engine, comment, toString(metadata_modification_time)
            FROM system.tables WHERE database = \(q.stringLiteral(database)) AND name = \(q.stringLiteral(table))
            """)
        guard let row = result.first else { throw DatabaseError(.query, "Table \(table) not found.") }
        return TableStatus(
            estimatedRows: row[0].flatMap { Int($0) }, dataBytes: row[1].flatMap { Int($0) }, engine: row[2],
            updatedAt: row[4], comment: row[3].flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The sorting key (as "PRIMARY", like TablePlus) and data-skipping indexes.
    public func indexes(of table: String, in database: String) async throws -> [IndexDetail] {
        let q = ClickHouseDialect()
        let filter = "database = \(q.stringLiteral(database)) AND table = \(q.stringLiteral(table))"
        var result: [IndexDetail] = []
        let key = try await rows(
            "SELECT name FROM system.columns WHERE \(filter) AND is_in_sorting_key = 1 ORDER BY position")
        if !key.isEmpty {
            result.append(
                IndexDetail(
                    name: "PRIMARY", algorithm: "SORTING KEY", isUnique: false, columns: key.compactMap { $0[0] }))
        }
        for row in try await rows("SELECT name, type, expr FROM system.data_skipping_indices WHERE \(filter)") {
            result.append(
                IndexDetail(
                    name: row[0] ?? "", algorithm: (row[1] ?? "").uppercased(), isUnique: false, columns: [row[2] ?? ""]
                ))
        }
        return result
    }

    public func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail] { [] }

    /// SHOW CREATE TABLE, without the database prefix so a dump can be loaded into another database.
    public func createStatement(of table: String, in database: String) async throws -> String {
        let q = ClickHouseDialect()
        guard let ddl = try await rows("SHOW CREATE TABLE \(q.qualified(database, table))").first?.first ?? nil else {
            throw DatabaseError(.query, "No CREATE statement for \(table).")
        }
        for prefix in ["\(database).", q.quoteIdentifier(database) + "."] {
            if let range = ddl.range(of: " " + prefix) {
                return ddl.replacingCharacters(in: range, with: " ")
            }
        }
        return ddl
    }

    public func characterSets() async throws -> [CharacterSetInfo] { [] }

    // MARK: HTTP

    private func rows(_ sql: String) async throws -> [[String?]] {
        let response = try await Self.request(
            config, http: http, sql: sql + "\nFORMAT JSONCompact", database: currentDatabase,
            queryID: UUID().uuidString)
        return response.rows.map { row in row.map(\.displayText) }
    }

    struct Response {
        var resultSet: ResultSet
        var writtenRows: UInt64
        var rows: [[CellValue]] { resultSet.rows }
    }

    static func request(
        _ config: ClickHouseConnectConfig, http: URLSession, sql: String, database: String?, queryID: String
    ) async throws -> Response {
        var components = URLComponents()
        components.scheme = config.useTLS ? "https" : "http"
        components.host = config.host
        components.port = config.port
        components.path = "/"
        var items = [
            URLQueryItem(name: "query_id", value: queryID),
            // Big integers as JSON numbers when they fit; dates stay text either way.
            URLQueryItem(name: "output_format_json_quote_64bit_integers", value: "0"),
            URLQueryItem(name: "output_format_json_quote_decimals", value: "1"),
            // Buffer the result so a failure mid-query comes back as an HTTP error, not a truncated 200.
            URLQueryItem(name: "wait_end_of_query", value: "1"),
        ]
        if let database { items.append(URLQueryItem(name: "database", value: database)) }
        components.queryItems = items
        guard let url = components.url else { throw DatabaseError(.connection, "Invalid host \(config.host).") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(sql.utf8)
        request.setValue(config.username, forHTTPHeaderField: "X-ClickHouse-User")
        if let password = config.password { request.setValue(password, forHTTPHeaderField: "X-ClickHouse-Key") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw DatabaseError(.cancelled, "The query was cancelled.")
        } catch {
            throw DatabaseError(
                .connection, "Couldn't reach \(config.host):\(config.port): \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw serverError(String(decoding: data, as: UTF8.self), status: status) }
        let summary = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-ClickHouse-Summary")
        let written =
            summary.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .flatMap { ($0["written_rows"] as? String).flatMap { UInt64($0) } } ?? 0
        guard !data.isEmpty else { return Response(resultSet: .empty, writtenRows: written) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("Exception") { throw serverError(text, status: status) }
            return Response(resultSet: .empty, writtenRows: written)
        }
        return Response(resultSet: ClickHouseValues.resultSet(json), writtenRows: written)
    }

    static func serverError(_ body: String, status: Int) -> DatabaseError {
        let message = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = message.range(of: #"Code: (\d+)"#, options: .regularExpression)
            .flatMap { Int(message[$0].dropFirst(6)) }
        let category: DatabaseError.Category =
            switch code {
            case 516, 192, 193, 194, 195, 196: .authentication
            case 394: .cancelled
            default: status == 0 ? .connection : .query
            }
        // "Code: 60. DB::Exception: Table x doesn't exist. (UNKNOWN_TABLE) (version …)" → the readable middle.
        var text = message
        if let range = text.range(of: "DB::Exception: ") { text = String(text[range.upperBound...]) }
        if let range = text.range(of: " (version ") { text = String(text[..<range.lowerBound]) }
        return DatabaseError(category, text, code: code)
    }

    static func returnsRows(_ sql: String) -> Bool {
        let head = sql.drop(while: { $0.isWhitespace || $0 == "(" }).prefix(9).uppercased()
        return ["SELECT", "WITH", "SHOW", "DESCRIBE", "DESC ", "EXISTS", "EXPLAIN", "CHECK"].contains {
            head.hasPrefix($0)
        }
    }

    static func hasFormat(_ sql: String) -> Bool {
        sql.range(of: #"\bFORMAT\s+\w+\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `USE db` (HTTP has no session, so it's handled locally).
    static func useTarget(_ sql: String) -> String? {
        guard sql.range(of: #"^USE\s+"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let name = sql.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "`\""))
    }
}

/// Decodes `FORMAT JSONCompact` ({"meta": [{name, type}], "data": [[…]]}) into TableRoad values.
enum ClickHouseValues {
    static func resultSet(_ json: [String: Any]) -> ResultSet {
        let meta = json["meta"] as? [[String: Any]] ?? []
        let columns = meta.map {
            ResultColumn(name: $0["name"] as? String ?? "", typeName: ($0["type"] as? String ?? "").uppercased())
        }
        let types = meta.map { $0["type"] as? String ?? "" }
        let data = json["data"] as? [[Any]] ?? []
        let rows = data.map { row in
            row.enumerated().map { index, value in decode(value, type: index < types.count ? types[index] : "") }
        }
        return ResultSet(columns: columns, rows: rows)
    }

    static func decode(_ value: Any, type rawType: String) -> CellValue {
        if value is NSNull { return .null }
        var type = rawType
        for wrapper in ["Nullable(", "LowCardinality("] where type.hasPrefix(wrapper) {
            type = String(type.dropFirst(wrapper.count).dropLast())
        }
        if type.hasPrefix("Array(") || type.hasPrefix("Map(") || type.hasPrefix("Tuple(") || type.hasPrefix("JSON")
            || type.hasPrefix("Object(")
        {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data()
            return .json(String(decoding: data, as: UTF8.self))
        }
        if type == "Bool" { return (value as? Bool).map { .bool($0) } ?? .text("\(value)") }
        if type.hasPrefix("Int") || type.hasPrefix("UInt") {
            if let number = value as? NSNumber { return .int(number.int64Value) }
            if let text = value as? String { return Int64(text).map { .int($0) } ?? .decimal(text) }
        }
        if type.hasPrefix("Float") {
            if let number = value as? NSNumber { return .double(number.doubleValue) }
            if let text = value as? String { return Double(text).map { .double($0) } ?? .text(text) }
        }
        if type.hasPrefix("Decimal") {
            if let text = value as? String { return .decimal(text) }
            if let number = value as? NSNumber { return .decimal(number.stringValue) }
        }
        if type.hasPrefix("Date") { return .temporal("\(value)") }
        if type == "UUID", let text = value as? String, let uuid = UUID(uuidString: text) { return .uuid(uuid) }
        if let text = value as? String { return .text(text) }
        if let number = value as? NSNumber { return .decimal(number.stringValue) }
        return .text("\(value)")
    }
}
