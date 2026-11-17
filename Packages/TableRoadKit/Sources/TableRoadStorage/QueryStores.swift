import Foundation
import Observation

/// A saved ("favourite") query. `connectionID` nil means it's offered for every connection.
public struct SavedQuery: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var sql: String
    public var connectionID: UUID?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(), name: String, sql: String, connectionID: UUID?, createdAt: Date = .now,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.sql = sql
        self.connectionID = connectionID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// One statement run from a query tab.
public struct QueryHistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var connectionID: UUID
    public var database: String?
    public var sql: String
    public var executedAt: Date
    public var durationMilliseconds: Int
    public var succeeded: Bool
    /// "300 rows", "2 rows affected", or the error.
    public var summary: String

    public init(
        id: UUID = UUID(), connectionID: UUID, database: String?, sql: String, executedAt: Date = .now,
        durationMilliseconds: Int, succeeded: Bool, summary: String
    ) {
        self.id = id
        self.connectionID = connectionID
        self.database = database
        self.sql = sql
        self.executedAt = executedAt
        self.durationMilliseconds = durationMilliseconds
        self.succeeded = succeeded
        self.summary = summary
    }
}

/// Saved queries, persisted as JSON (`queries.json`).
@MainActor @Observable
public final class SavedQueryStore {
    public private(set) var queries: [SavedQuery] = []
    public private(set) var loadError: String?
    private let file: JSONFile<[SavedQuery]>

    public init(fileURL: URL) {
        file = JSONFile(url: fileURL)
        do { queries = try file.load() ?? [] } catch { loadError = file.describe(error) }
    }

    public static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "TableRoad/queries.json")
    }

    /// This connection's queries plus the ones shared by all connections, by name.
    public func queries(for connectionID: UUID) -> [SavedQuery] {
        queries.filter { $0.connectionID == nil || $0.connectionID == connectionID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ query: SavedQuery) throws {
        var query = query
        query.modifiedAt = .now
        if let index = queries.firstIndex(where: { $0.id == query.id }) {
            queries[index] = query
        } else {
            queries.append(query)
        }
        try persist()
    }

    public func delete(_ id: UUID) throws {
        queries.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        if let loadError { throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: loadError]) }
        try file.save(queries)
    }
}

/// Query history, newest first, capped per connection (`history.json`). Stays on this Mac.
@MainActor @Observable
public final class QueryHistoryStore {
    public private(set) var entries: [QueryHistoryEntry] = []
    public private(set) var loadError: String?
    public let limitPerConnection: Int
    private let file: JSONFile<[QueryHistoryEntry]>

    public init(fileURL: URL, limitPerConnection: Int = 500) {
        self.limitPerConnection = limitPerConnection
        file = JSONFile(url: fileURL)
        do { entries = try file.load() ?? [] } catch { loadError = file.describe(error) }
    }

    public static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "TableRoad/history.json")
    }

    public func entries(for connectionID: UUID) -> [QueryHistoryEntry] {
        entries.filter { $0.connectionID == connectionID }
    }

    /// Adds one run's statements (in run order) and trims the oldest beyond the limit. Failures to write are
    /// ignored: history is a convenience and mustn't break running queries.
    public func record(_ newEntries: [QueryHistoryEntry]) {
        guard !newEntries.isEmpty else { return }
        entries.insert(contentsOf: newEntries.reversed(), at: 0)
        var counts: [UUID: Int] = [:]
        entries = entries.filter { entry in
            counts[entry.connectionID, default: 0] += 1
            return counts[entry.connectionID]! <= limitPerConnection
        }
        if loadError == nil { try? file.save(entries) }
    }

    public func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if loadError == nil { try? file.save(entries) }
    }

    public func clear(connectionID: UUID) {
        entries.removeAll { $0.connectionID == connectionID }
        if loadError == nil { try? file.save(entries) }
    }
}

/// Reads and atomically writes one Codable value as JSON (ISO-8601 dates).
/// A Codable value in a JSON file (ISO 8601 dates, written atomically). Shared by the app's stores.
public struct JSONFile<Value: Codable> {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// The store then refuses to overwrite the file, so nothing is lost.
    public func describe(_ error: any Error) -> String {
        "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
    }
}
