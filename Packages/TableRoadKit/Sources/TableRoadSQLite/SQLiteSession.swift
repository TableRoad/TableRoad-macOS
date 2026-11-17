import Foundation
import SQLite3
import TableRoadCore
import TableRoadSQL

/// SQLite spelling: double-quoted identifiers, `?` parameters, no DATABASE statements.
public struct SQLiteDialect: SQLDialect {
    public var family: SQLFamily { .sqlite }
    public init() {}

    public func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func stringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public func booleanLiteral(_ value: Bool) -> String { value ? "1" : "0" }

    public func createDatabaseSQL(_ name: String, characterSet: String?, collation: String?) throws -> String {
        throw DatabaseError(.unsupported, "SQLite has one database per file. Create a new file instead.")
    }

    public var dumpPreamble: [String] { ["PRAGMA foreign_keys = OFF", "BEGIN TRANSACTION"] }
    public var dumpPostamble: [String] { ["COMMIT", "PRAGMA foreign_keys = ON"] }
}

/// A SQLite database file. Statements run on the actor; `cancelCurrentQuery` interrupts from any thread.
public actor SQLiteSession: SQLClient {
    /// The open handle (sqlite3_interrupt is safe to call from another thread, so cancel needs no actor hop).
    private nonisolated(unsafe) let db: OpaquePointer
    public let path: String
    public let kind: DatabaseKind = .sqlite
    public let serverVersion: String

    public nonisolated var sqlDialect: any SQLDialect { SQLiteDialect() }
    public nonisolated var processID: UInt64 { 0 }
    public nonisolated var isEncrypted: Bool { false }
    public nonisolated var tlsCipher: String? { nil }
    public nonisolated var capabilities: ClientCapabilities {
        ClientCapabilities(processList: false, createDatabases: false, databaseNoun: "schema")
    }

    public var currentDatabase: String? { "main" }

    /// Opens (or, with `create`, creates) a database file. `:memory:` gives an in-memory database.
    public static func open(path: String, create: Bool = false, readOnly: Bool = false) async throws -> SQLiteSession {
        let expanded = (path as NSString).expandingTildeInPath
        if !create && expanded != ":memory:" && !FileManager.default.fileExists(atPath: expanded) {
            throw DatabaseError(.connection, "There's no SQLite file at \(expanded).")
        }
        var handle: OpaquePointer?
        let flags =
            (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0))
            | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(expanded, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(status)"
            if let handle { sqlite3_close_v2(handle) }
            throw DatabaseError(.connection, "Couldn't open \(expanded): \(message)")
        }
        sqlite3_busy_timeout(handle, 5_000)
        sqlite3_extended_result_codes(handle, 1)
        let session = SQLiteSession(db: handle, path: expanded)
        // Fail early on files that aren't SQLite databases (sqlite3_open is lazy).
        do {
            _ = try await session.execute("SELECT count(*) FROM sqlite_master")
        } catch {
            throw DatabaseError(.connection, "\(expanded) isn't a SQLite database.")
        }
        return session
    }

    private init(db: OpaquePointer, path: String) {
        self.db = db
        self.path = path
        serverVersion = String(cString: sqlite3_libversion())
    }

    deinit { sqlite3_close_v2(db) }

    public func close() async {}

    // MARK: Statements

    public func execute(_ sql: String) async throws -> QueryOutcome {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let columnCount = Int(sqlite3_column_count(statement))
        var rows: [[CellValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw error(status) }
            rows.append((0..<columnCount).map { value(statement, Int32($0)) })
        }
        guard columnCount > 0 else { return .affected(rowCount: UInt64(sqlite3_changes64(db))) }
        let columns = (0..<columnCount).map { index -> ResultColumn in
            let name = String(cString: sqlite3_column_name(statement, Int32(index)))
            let table = sqlite3_column_table_name(statement, Int32(index)).map { String(cString: $0) }
            let type = sqlite3_column_decltype(statement, Int32(index)).map { String(cString: $0) } ?? ""
            return ResultColumn(name: name, table: table, typeName: type.uppercased())
        }
        return .rows(ResultSet(columns: columns, rows: rows))
    }

    public func run(_ sql: String) async throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw Self.databaseError(status, text)
        }
    }

    public func executeTransaction(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        do {
            try await run("BEGIN IMMEDIATE")
        } catch let error as DatabaseError {
            throw TransactionError(statementIndex: 0, underlying: error)
        }
        var affected: [UInt64] = []
        for (index, statement) in statements.enumerated() {
            do {
                let prepared = try prepare(statement.sql)
                defer { sqlite3_finalize(prepared) }
                for (offset, parameter) in statement.parameters.enumerated() {
                    switch parameter {
                    case .text(let value):
                        sqlite3_bind_text(prepared, Int32(offset + 1), value, -1, Self.transient)
                    case .null:
                        sqlite3_bind_null(prepared, Int32(offset + 1))
                    }
                }
                let status = sqlite3_step(prepared)
                guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error(status) }
                affected.append(UInt64(sqlite3_changes64(db)))
            } catch {
                try? await run("ROLLBACK")
                throw TransactionError(
                    statementIndex: index,
                    underlying: error as? DatabaseError ?? DatabaseError(.query, error.localizedDescription))
            }
        }
        do {
            try await run("COMMIT")
        } catch {
            try? await run("ROLLBACK")
            throw TransactionError(
                statementIndex: statements.count,
                underlying: error as? DatabaseError ?? DatabaseError(.query, error.localizedDescription))
        }
        return affected
    }

    /// Interrupts the running statement (it fails with "interrupted").
    public nonisolated func cancelCurrentQuery() async throws {
        sqlite3_interrupt(db)
    }

    public func processList() async throws -> [ServerProcess] { [] }

    public func kill(processID: UInt64, connection: Bool) async throws {
        throw DatabaseError(.unsupported, "SQLite has no server processes.")
    }

    // MARK: Introspection

    public func useDatabase(_ name: String) async throws {
        guard try await databases().contains(name) else {
            throw DatabaseError(.query, "No attached database named \(name).")
        }
    }

    private var catalog: SQLiteCatalog {
        SQLiteCatalog(textRows: { [self] sql in try await self.textRowsAsync(sql) })
    }

    private func textRowsAsync(_ sql: String) throws -> [[String?]] { try textRows(sql) }

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

    // MARK: Helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw error(status) }
        return statement
    }

    private func value(_ statement: OpaquePointer, _ index: Int32) -> CellValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, index))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .bytes(Data()) }
            return .bytes(Data(bytes: bytes, count: count))
        default:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        }
    }

    /// Every value as text (PRAGMA results).
    private func textRows(_ sql: String) throws -> [[String?]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let count = sqlite3_column_count(statement)
        var rows: [[String?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw error(status) }
            rows.append(
                (0..<count).map { index in
                    sqlite3_column_text(statement, index).map { String(cString: $0) }
                })
        }
        return rows
    }

    private func error(_ status: Int32) -> DatabaseError {
        Self.databaseError(status, String(cString: sqlite3_errmsg(db)))
    }

    static func databaseError(_ status: Int32, _ message: String) -> DatabaseError {
        let primary = status & 0xFF
        let category: DatabaseError.Category =
            switch primary {
            case SQLITE_INTERRUPT: .cancelled
            case SQLITE_CANTOPEN, SQLITE_NOTADB: .connection
            case SQLITE_AUTH, SQLITE_PERM, SQLITE_READONLY: .authentication
            default: .query
            }
        return DatabaseError(category, message, code: Int(status))
    }
}
