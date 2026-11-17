import Foundation
import TableRoadCore
import Testing

@testable import TableRoadOracle

@Suite(
    .enabled(if: OracleTestServer.available, "Start the oracle service in docker/compose.yml"), .serialized,
    .timeLimit(.minutes(2)))
struct OracleProtocolTests {
    @Test func connectAuthenticateAndSelect() async throws {
        let connection = try await OracleConnection.open(OracleTestServer.endpoint)
        try await connection.authenticate(user: "tableroad", password: "tableroad")
        let result = try await connection.execute(
            "SELECT 1 AS one, 'x' AS letter, SYSDATE FROM dual", isQuery: true, isPLSQL: false, commit: false)
        #expect(result.columns?.map(\.name) == ["ONE", "LETTER", "SYSDATE"])
        #expect(result.rows.first?[0] == .int(1))
        #expect(result.rows.first?[1] == .text("x"))
        await connection.close()
    }
}
