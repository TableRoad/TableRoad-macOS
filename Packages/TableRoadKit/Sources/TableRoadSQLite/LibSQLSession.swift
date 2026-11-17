import Foundation
import TableRoadCore
import TableRoadSQL

public struct LibSQLConnectConfig: Sendable, Hashable {
    /// e.g. `https://my-db-org.turso.io` or `http://127.0.0.1:8080` (libsql:// is turned into https://).
    public var url: URL
    /// Auth token (Turso database token); nil for an open local sqld.
    public var token: String?

    public init(url: URL, token: String? = nil) {
        self.url = url
        self.token = token
    }

    /// The profile's host can be a full URL (libsql://…, https://…) or a host name with the port field.
    public init(profile: ConnectionProfile, password: String?) throws {
        var text = profile.host.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("libsql://") { text = "https://" + text.dropFirst("libsql://".count) }
        if !text.contains("://") {
            let secure = profile.tls != .disable && profile.tls != .prefer
            text = (secure ? "https://" : "http://") + text + ":\(profile.port)"
        }
        guard let url = URL(string: text) else { throw DatabaseError(.connection, "Invalid URL \(profile.host).") }
        self.init(url: url, token: password.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// LibSQL / Turso over the Hrana HTTP protocol (`/v2/pipeline`). SQLite dialect and catalog.
/// Transactions keep a server-side stream open with its baton.
public actor LibSQLSession: SQLClient {
    private let config: LibSQLConnectConfig
    private let http: URLSession
    public let kind: DatabaseKind = .libsql
    public let serverVersion: String
    public var currentDatabase: String? { "main" }
    private var runningTask: Task<Data, any Error>?

    public nonisolated var sqlDialect: any SQLDialect { SQLiteDialect() }
    public nonisolated var processID: UInt64 { 0 }
    public nonisolated let isEncrypted: Bool
    public nonisolated var tlsCipher: String? { isEncrypted ? "HTTPS" : nil }
    public nonisolated var capabilities: ClientCapabilities {
        ClientCapabilities(processList: false, createDatabases: false, databaseNoun: "schema")
    }

    public static func connect(_ config: LibSQLConnectConfig) async throws -> LibSQLSession {
        let session = LibSQLSession(config: config)
        let version = try await session.textRowsAsync("SELECT sqlite_version()").first?.first ?? nil
        await session.setVersion(version ?? "")
        return session
    }

    private init(config: LibSQLConnectConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        http = URLSession(configuration: configuration)
        serverVersion = ""
        isEncrypted = config.url.scheme == "https"
    }

    private var version = ""
    private func setVersion(_ value: String) { version = value }

    public func close() async { http.invalidateAndCancel() }

    // MARK: Statements

    public func execute(_ sql: String) async throws -> QueryOutcome {
        let (result, _) = try await pipeline([.execute(sql, [])], baton: nil, close: true)
        return result[0]
    }

    public func run(_ sql: String) async throws {
        let statements = StatementSplitter(syntax: .postgres).split(sql).map(\.text)
        guard !statements.isEmpty else { return }
        _ = try await pipeline(statements.map { .execute($0, []) }, baton: nil, close: true, stopOnError: true)
    }

    public func executeTransaction(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        // BEGIN opens a stream; its baton carries the transaction across requests.
        let (_, baton) = try await pipeline([.execute("BEGIN", [])], baton: nil, close: false)
        var affected: [UInt64] = []
        var current = baton
        for (index, statement) in statements.enumerated() {
            do {
                let (result, next) = try await pipeline(
                    [.execute(statement.sql, statement.parameters)], baton: current, close: false)
                current = next
                if case .affected(let count) = result[0] { affected.append(count) } else { affected.append(0) }
            } catch {
                _ = try? await pipeline([.execute("ROLLBACK", [])], baton: current, close: true)
                throw TransactionError(
                    statementIndex: index,
                    underlying: error as? DatabaseError ?? DatabaseError(.query, error.localizedDescription))
            }
        }
        do {
            _ = try await pipeline([.execute("COMMIT", [])], baton: current, close: true)
        } catch {
            throw TransactionError(
                statementIndex: statements.count,
                underlying: error as? DatabaseError ?? DatabaseError(.query, error.localizedDescription))
        }
        return affected
    }

    /// Abandons the in-flight HTTP request (the server finishes the statement on its own).
    public func cancelCurrentQuery() async throws {
        runningTask?.cancel()
    }

    public func processList() async throws -> [ServerProcess] { [] }

    public func kill(processID: UInt64, connection: Bool) async throws {
        throw DatabaseError(.unsupported, "LibSQL has no process list.")
    }

    // MARK: Catalog (shared with SQLite)

    private var catalog: SQLiteCatalog {
        SQLiteCatalog(textRows: { [self] sql in try await self.textRowsAsync(sql) })
    }

    private func textRowsAsync(_ sql: String) async throws -> [[String?]] {
        guard case .rows(let result) = try await execute(sql) else { return [] }
        return result.rows.map { row in row.map(\.displayText) }
    }

    public func useDatabase(_ name: String) async throws {}
    public func databases() async throws -> [String] { try await catalog.databases() }
    public func tables(in database: String) async throws -> [TableInfo] { try await catalog.tables(in: database) }
    public func columns(of table: String, in database: String) async throws -> [ColumnDetail] {
        try await catalog.columns(of: table, in: database)
    }
    public func tableStatus(of table: String, in database: String) async throws -> TableStatus {
        try await catalog.tableStatus(of: table, in: database)
    }
    public func indexes(of table: String, in database: String) async throws -> [IndexDetail] {
        try await catalog.indexes(of: table, in: database)
    }
    public func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail] {
        try await catalog.foreignKeys(of: table, in: database)
    }
    public func createStatement(of table: String, in database: String) async throws -> String {
        try await catalog.createStatement(of: table, in: database)
    }
    public func characterSets() async throws -> [CharacterSetInfo] { [] }

    // MARK: Hrana over HTTP

    enum Request {
        case execute(String, [SQLParameter])
    }

    /// Sends statements in one pipeline. Returns each result and the baton for continuing the stream.
    private func pipeline(
        _ requests: [Request], baton: String?, close: Bool, stopOnError: Bool = false
    ) async throws -> ([QueryOutcome], String?) {
        var items: [[String: Any]] = requests.map { request in
            switch request {
            case .execute(let sql, let parameters):
                var statement: [String: Any] = ["sql": sql, "want_rows": true]
                if !parameters.isEmpty {
                    statement["args"] = parameters.map { parameter -> [String: Any] in
                        switch parameter {
                        case .text(let value): ["type": "text", "value": value]
                        case .null: ["type": "null"]
                        }
                    }
                }
                return ["type": "execute", "stmt": statement]
            }
        }
        if close { items.append(["type": "close"]) }
        var body: [String: Any] = ["requests": items]
        if let baton { body["baton"] = baton }

        var request = URLRequest(url: config.url.appending(path: "v2/pipeline"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let http = http
        let task = Task { () throws -> Data in
            do {
                let (data, response) = try await http.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    throw DatabaseError(.authentication, "The server rejected the auth token (HTTP \(status)).")
                }
                guard status == 200 else {
                    throw DatabaseError(.query, "HTTP \(status): " + String(decoding: data.prefix(500), as: UTF8.self))
                }
                return data
            } catch is CancellationError {
                throw DatabaseError(.cancelled, "The query was cancelled.")
            } catch let error as URLError where error.code == .cancelled {
                throw DatabaseError(.cancelled, "The query was cancelled.")
            } catch let error as DatabaseError {
                throw error
            } catch {
                throw DatabaseError(
                    .connection, "Couldn't reach \(config.url.host() ?? ""): \(error.localizedDescription)")
            }
        }
        runningTask = task
        defer { runningTask = nil }
        let data = try await task.value

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]]
        else { throw DatabaseError(.query, "Unexpected reply from the server.") }
        var outcomes: [QueryOutcome] = []
        for result in results.prefix(requests.count) {
            if result["type"] as? String == "error" {
                let error = result["error"] as? [String: Any]
                throw DatabaseError(.query, error?["message"] as? String ?? "Statement failed.")
            }
            let response = result["response"] as? [String: Any]
            guard let payload = response?["result"] as? [String: Any] else {
                outcomes.append(.affected(rowCount: 0))
                continue
            }
            outcomes.append(Self.outcome(payload))
        }
        _ = stopOnError
        return (outcomes, json["baton"] as? String)
    }

    static func outcome(_ result: [String: Any]) -> QueryOutcome {
        let columns = (result["cols"] as? [[String: Any]] ?? []).map {
            ResultColumn(name: $0["name"] as? String ?? "", typeName: ($0["decltype"] as? String ?? "").uppercased())
        }
        let rows = (result["rows"] as? [[[String: Any]]] ?? []).map { row in row.map(value) }
        if columns.isEmpty {
            return .affected(rowCount: UInt64((result["affected_row_count"] as? NSNumber)?.intValue ?? 0))
        }
        return .rows(ResultSet(columns: columns, rows: rows))
    }

    static func value(_ cell: [String: Any]) -> CellValue {
        switch cell["type"] as? String {
        case "null": return .null
        case "integer":
            let text = (cell["value"] as? String) ?? (cell["value"] as? NSNumber)?.stringValue ?? ""
            return Int64(text).map { .int($0) } ?? .decimal(text)
        case "float": return .double((cell["value"] as? NSNumber)?.doubleValue ?? 0)
        case "blob": return .bytes(Data(base64Encoded: Self.padded(cell["base64"] as? String ?? "")) ?? Data())
        default: return .text(cell["value"] as? String ?? "")
        }
    }

    /// Hrana sends base64 without padding.
    static func padded(_ text: String) -> String {
        text + String(repeating: "=", count: (4 - text.count % 4) % 4)
    }
}
