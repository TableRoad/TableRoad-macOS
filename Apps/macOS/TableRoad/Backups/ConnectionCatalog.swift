import Foundation
import Observation
import TableRoadCore
import TableRoadDrivers
import TableRoadSQL
import TableRoadStorage

/// Databases, tables and sizes of a saved connection, loaded on demand for the backup and sync pickers. Each load
/// opens a short-lived connection of its own.
@MainActor @Observable
final class ConnectionCatalog {
    enum State: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    let connectionID: UUID
    private(set) var state: State = .idle
    private(set) var databases: [String] = []
    private(set) var tables: [String: [TableInfo]] = [:]
    /// Bytes per table, by database (empty when the engine can't tell cheaply).
    private(set) var sizes: [String: [String: Int64]] = [:]
    private(set) var loadingTables: Set<String> = []
    /// What the UI calls a database on this server ("schema" for PostgreSQL).
    private(set) var databaseNoun = "database"
    private(set) var canCreateDatabases = false
    private let connect: @Sendable () async throws -> any SQLClient

    init(connectionID: UUID, store: ConnectionStore) {
        self.connectionID = connectionID
        let profile = store.profile(id: connectionID)
        let password = store.password(for: connectionID)
        connect = {
            guard let profile else { throw DatabaseError(.connection, "The connection was deleted.") }
            return try await Drivers.connect(profile, password: password)
        }
    }

    #if DEBUG
        /// Preview data, never touching the network.
        init(preview databases: [String: [String]]) {
            connectionID = UUID()
            connect = { throw DatabaseError(.connection, "Preview") }
            self.databases = databases.keys.sorted()
            for (database, names) in databases {
                tables[database] = names.map { TableInfo(name: $0, kind: .table) }
                sizes[database] = Dictionary(
                    uniqueKeysWithValues: names.enumerated().map { ($1, Int64(($0 + 1) * 98_304)) })
            }
            state = .loaded
        }
    #endif

    /// System schemas are never backed up or synced.
    static let systemDatabases: Set<String> = [
        "information_schema", "mysql", "performance_schema", "sys", "pg_catalog", "pg_toast", "crdb_internal",
        "pg_extension", "system", "INFORMATION_SCHEMA",
    ]

    func loadDatabases(force: Bool = false) async {
        guard force || state == .idle else { return }
        state = .loading
        do {
            let session = try await connect()
            defer { Task { await session.close() } }
            databases = try await session.databases().filter { !Self.systemDatabases.contains($0) }
            databaseNoun = session.capabilities.databaseNoun
            canCreateDatabases = session.capabilities.createDatabases
            state = .loaded
        } catch {
            state = .failed((error as? DatabaseError)?.message ?? error.localizedDescription)
        }
    }

    func loadTables(_ database: String) async {
        guard tables[database] == nil, !loadingTables.contains(database) else { return }
        loadingTables.insert(database)
        defer { loadingTables.remove(database) }
        guard let session = try? await connect() else { return }
        defer { Task { await session.close() } }
        tables[database] = ((try? await session.tables(in: database)) ?? []).filter { $0.kind != .systemView }
        sizes[database] = (try? await session.tableSizes(in: database)) ?? [:]
    }

    /// Total bytes of a database's tables, when known.
    func size(of database: String) -> Int64? {
        guard let known = sizes[database], !known.isEmpty else { return nil }
        return known.values.reduce(0, +)
    }

    func createDatabase(_ name: String) async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await session.run(session.sqlDialect.createDatabaseSQL(name, characterSet: nil, collation: nil))
        await loadDatabases(force: true)
    }
}

extension Int64 {
    var byteText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
