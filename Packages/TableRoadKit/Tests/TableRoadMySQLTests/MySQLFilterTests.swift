import TableRoadCore
import TableRoadSQL
import Testing

@testable import TableRoadMySQL

/// Filters run against real servers: escaping bugs only show up there.
@Suite(.enabled(if: TestServer.available, "Start docker/compose.yml to run MySQL integration tests"))
struct MySQLFilterTests {
    static let awkward = [#"it's"#, #"C:\temp\new"#, "50%_off", "plain", "ünïcødé 🚗"]

    func withScratch(_ server: TestServer, _ body: (MySQLSession) async throws -> Void) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        _ = try await session.execute(
            "CREATE TEMPORARY TABLE filters (id INT PRIMARY KEY, name VARCHAR(50) CHARACTER SET utf8mb4, n INT NULL)")
        for (index, value) in Self.awkward.enumerated() {
            _ = try await session.execute(
                "INSERT INTO filters VALUES (\(index + 1), \(session.dialect.stringLiteral(value)), \(index == 0 ? "NULL" : String(index * 10)))"
            )
        }
        try await body(session)
    }

    func ids(_ session: MySQLSession, _ filters: [ColumnFilter], matchAll: Bool = true) async throws -> [Int64] {
        let database = await session.currentDatabase ?? "tableroad"
        let query = PageQuery(
            database: database, table: "filters", sort: [ColumnSort(column: "id")],
            filters: FilterSet(filters: filters, matchAll: matchAll))
        guard case .rows(let result) = try await session.execute(query.selectSQL(session.dialect)) else { return [] }
        return result.rows.compactMap { if case .int(let id) = $0[0] { id } else { nil } }
    }

    @Test(arguments: TestServer.allCases)
    func equalsMatchesAwkwardValuesExactly(server: TestServer) async throws {
        try await withScratch(server) { session in
            for (index, value) in Self.awkward.enumerated() {
                do {
                    let result = try await ids(session, [ColumnFilter(column: "name", op: .equals, value: value)])
                    #expect(result == [Int64(index + 1)])
                }
            }
        }
    }

    @Test(arguments: TestServer.allCases)
    func likeTreatsWildcardsLiterally(server: TestServer) async throws {
        try await withScratch(server) { session in
            do {
                let result = try await ids(session, [ColumnFilter(column: "name", op: .contains, value: "%_")])
                #expect(result == [3])
            }
            do {
                let result = try await ids(session, [ColumnFilter(column: "name", op: .contains, value: #"\te"#)])
                #expect(result == [2])
            }
            do {
                let result = try await ids(session, [ColumnFilter(column: "name", op: .beginsWith, value: "it'")])
                #expect(result == [1])
            }
        }
    }

    @Test(arguments: TestServer.allCases)
    func nullsListsAndCombinations(server: TestServer) async throws {
        try await withScratch(server) { session in
            do {
                let result = try await ids(session, [ColumnFilter(column: "n", op: .isNull)])
                #expect(result == [1])
            }
            do {
                let result = try await ids(session, [ColumnFilter(column: "n", op: .isIn, value: "10, 30")])
                #expect(result == [2, 4])
            }
            let both = [
                ColumnFilter(column: "n", op: .greaterThan, value: "15"),
                ColumnFilter(column: "name", op: .equals, value: "plain"),
            ]
            do {
                let result = try await ids(session, both, matchAll: true)
                #expect(result == [4])
            }
            do {
                let result = try await ids(session, both, matchAll: false)
                #expect(result == [3, 4, 5])
            }
        }
    }

    /// Changes the server's global sql_mode, so it must not overlap other tests that read it.
    @Test(.serialized, arguments: TestServer.allCases)
    func escapingFollowsNoBackslashEscapesMode(server: TestServer) async throws {
        let admin = try await MySQLSession.connect(server.rootConfig)
        guard case .rows(let original) = try await admin.execute("SELECT @@GLOBAL.sql_mode"),
            case .text(let originalMode) = original.rows.first?.first
        else {
            await admin.close()
            Issue.record("couldn't read sql_mode")
            return
        }
        _ = try await admin.execute("SET GLOBAL sql_mode = CONCAT(@@GLOBAL.sql_mode, ',NO_BACKSLASH_ESCAPES')")

        var failure: (any Error)?
        do {
            try await withScratch(server) { session in
                #expect(session.dialect.backslashEscapes == false)
                let result = try await ids(session, [ColumnFilter(column: "name", op: .equals, value: #"C:\temp\new"#)])
                #expect(result == [2])
            }
        } catch {
            failure = error
        }
        // Always restore the exact original mode before finishing.
        _ = try await admin.execute("SET GLOBAL sql_mode = \(admin.dialect.stringLiteral(originalMode))")
        await admin.close()
        if let failure { throw failure }
    }
}
