import Foundation
import Testing

@testable import TableRoadStorage

@MainActor
struct QueryStoresTests {
    func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tableroad-tests-\(UUID().uuidString)/\(name)")
    }

    @Test func savedQueriesPersistAndFilterByConnection() throws {
        let url = tempURL("queries.json")
        let mine = UUID()
        let store = SavedQueryStore(fileURL: url)
        try store.save(SavedQuery(name: "b recent", sql: "SELECT 2", connectionID: mine))
        try store.save(SavedQuery(name: "A shared", sql: "SELECT 1", connectionID: nil))
        try store.save(SavedQuery(name: "other", sql: "SELECT 3", connectionID: UUID()))

        let reloaded = SavedQueryStore(fileURL: url)
        #expect(reloaded.queries(for: mine).map(\.name) == ["A shared", "b recent"])

        var renamed = try #require(reloaded.queries(for: mine).first)
        renamed.name = "Z shared"
        try reloaded.save(renamed)
        #expect(reloaded.queries.count == 3)
        try reloaded.delete(renamed.id)
        #expect(SavedQueryStore(fileURL: url).queries(for: mine).map(\.name) == ["b recent"])
    }

    @Test func historyIsNewestFirstAndCappedPerConnection() {
        let url = tempURL("history.json")
        let a = UUID()
        let b = UUID()
        let store = QueryHistoryStore(fileURL: url, limitPerConnection: 3)
        func entry(_ sql: String, _ id: UUID) -> QueryHistoryEntry {
            QueryHistoryEntry(
                connectionID: id, database: "db", sql: sql, durationMilliseconds: 1, succeeded: true, summary: "")
        }
        store.record([entry("1", a), entry("2", a)])
        store.record([entry("x", b)])
        store.record([entry("3", a), entry("4", a)])
        #expect(store.entries(for: a).map(\.sql) == ["4", "3", "2"])
        #expect(store.entries(for: b).map(\.sql) == ["x"])

        let reloaded = QueryHistoryStore(fileURL: url, limitPerConnection: 3)
        #expect(reloaded.entries(for: a).map(\.sql) == ["4", "3", "2"])
        reloaded.clear(connectionID: a)
        #expect(QueryHistoryStore(fileURL: url).entries.map(\.sql) == ["x"])
    }

    @Test func corruptFileIsNotOverwritten() throws {
        let url = tempURL("queries.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = SavedQueryStore(fileURL: url)
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) { try store.save(SavedQuery(name: "x", sql: "y", connectionID: nil)) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }
}
