import TableRoadCore
import TableRoadSQL
import Testing

@testable import TableRoadMySQL

@Suite(.enabled(if: TestServer.available, "Start docker/compose.yml to run MySQL integration tests"))
struct MySQLEditTests {
    func scratch(_ server: TestServer) async throws -> MySQLSession {
        let session = try await MySQLSession.connect(server.config())
        _ = try await session.execute(
            """
            CREATE TEMPORARY TABLE edits (
                id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(50) NOT NULL, amount DECIMAL(8,2) NULL,
                created DATETIME NOT NULL DEFAULT '2026-01-01 00:00:00'
            ) CHARACTER SET utf8mb4
            """)
        _ = try await session.execute("INSERT INTO edits (name, amount) VALUES ('a', 1.00), ('b', 2.00), ('c', 3.00)")
        return session
    }

    func rows(_ session: MySQLSession) async throws -> [[CellValue]] {
        guard
            case .rows(let result) = try await session.execute(
                "SELECT id, name, amount, created FROM edits ORDER BY id")
        else { return [] }
        return result.rows
    }

    @Test(arguments: TestServer.allCases)
    func appliesUpdateInsertDeleteAtomically(server: TestServer) async throws {
        let session = try await scratch(server)
        defer { Task { await session.close() } }
        let database = await session.currentDatabase ?? "tableroad"
        let builder = TableChangeBuilder(database: database, table: "edits", dialect: session.dialect)
        let changes: [RowChange] = [
            .update(
                key: RowKey([("id", "1")]),
                set: [
                    ColumnEdit(column: "name", edit: .text(#"it's a \ test 🚗"#)),
                    ColumnEdit(column: "amount", edit: .null),
                ]),
            .insert([
                ColumnEdit(column: "id", edit: .defaultValue), ColumnEdit(column: "name", edit: .text("new")),
                ColumnEdit(column: "amount", edit: .text("9.5")), ColumnEdit(column: "created", edit: .defaultValue),
            ]),
            .delete(key: RowKey([("id", "2")])),
        ]
        let affected = try await session.executeTransaction(changes.map(builder.statement))
        #expect(affected == [1, 1, 1])

        let result = try await rows(session)
        #expect(result.map { $0[0] } == [.int(1), .int(3), .int(4)])
        #expect(result[0][1] == .text(#"it's a \ test 🚗"#))
        #expect(result[0][2] == .null)
        #expect(result[2][2] == .decimal("9.50"))
        #expect(result[2][3] == .temporal("2026-01-01 00:00:00"))
    }

    @Test(arguments: TestServer.allCases)
    func failureRollsBackEverything(server: TestServer) async throws {
        let session = try await scratch(server)
        defer { Task { await session.close() } }
        let database = await session.currentDatabase ?? "tableroad"
        let builder = TableChangeBuilder(database: database, table: "edits", dialect: session.dialect)
        let before = try await rows(session)
        let changes: [RowChange] = [
            .update(key: RowKey([("id", "1")]), set: [ColumnEdit(column: "name", edit: .text("changed"))]),
            // NOT NULL violation fails the second statement.
            .update(key: RowKey([("id", "2")]), set: [ColumnEdit(column: "name", edit: .null)]),
        ]
        await #expect {
            _ = try await session.executeTransaction(changes.map(builder.statement))
        } throws: { error in
            (error as? TransactionError)?.statementIndex == 1
        }
        let after = try await rows(session)
        #expect(after == before)
    }
}
