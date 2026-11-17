import Foundation
import TableRoadCore
import TableRoadSQL
import Testing

@testable import TableRoadMySQL

/// Uses the root account: the test user can only touch its own database.
@Suite(.enabled(if: TestServer.available, "Start docker/compose.yml to run MySQL integration tests"))
struct MySQLDatabaseAdminTests {
    @Test(arguments: TestServer.allCases)
    func createAndDropDatabase(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.rootConfig)
        defer { Task { await session.close() } }
        let name = "tr_admin_\(UInt32.random(in: 0...UInt32.max))"
        _ = try await session.execute(
            session.dialect.createDatabaseSQL(name, characterSet: "utf8mb4", collation: "utf8mb4_unicode_ci"))
        #expect(try await session.databases().contains(name))

        guard
            case .rows(let result) = try await session.execute(
                "SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '\(name)'")
        else {
            Issue.record("expected rows")
            return
        }
        #expect(result.rows.first?.first?.displayText == "utf8mb4_unicode_ci")

        _ = try await session.execute(session.dialect.dropDatabaseSQL(name))
        #expect(try await !session.databases().contains(name))
    }

    @Test(arguments: TestServer.allCases)
    func characterSetsListCollations(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        let sets = try await session.characterSets()
        let utf8mb4 = try #require(sets.first { $0.name == "utf8mb4" })
        #expect(utf8mb4.collations.contains("utf8mb4_unicode_ci"))
        #expect(utf8mb4.defaultCollation != nil)
        #expect(utf8mb4.collations.contains(utf8mb4.defaultCollation ?? ""))
    }
}
