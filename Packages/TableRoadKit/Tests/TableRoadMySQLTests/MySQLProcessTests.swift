import Foundation
import TableRoadCore
import Testing

@testable import TableRoadMySQL

@Suite(.enabled(if: TestServer.available, "Start docker/compose.yml to run MySQL integration tests"))
struct MySQLProcessTests {
    @Test(arguments: TestServer.allCases)
    func listsAndKillsARunningQuery(server: TestServer) async throws {
        let admin = try await MySQLSession.connect(server.config())
        let worker = try await MySQLSession.connect(server.config())
        defer {
            Task {
                await admin.close()
                await worker.close()
            }
        }

        let start = Date()
        async let slow = worker.execute("SELECT SLEEP(30) AS stuck")
        try await Task.sleep(for: .milliseconds(600))

        let processes = try await admin.processList()
        let stuck = try #require(processes.first { $0.id == worker.processID })
        #expect(stuck.command == "Query")
        #expect(stuck.info?.contains("SLEEP(30)") == true)
        #expect(stuck.user == "tableroad")
        #expect(processes.contains { $0.id == admin.processID })

        try await admin.kill(processID: stuck.id, connection: false)
        _ = try? await slow
        #expect(Date().timeIntervalSince(start) < 10)
        // KILL QUERY leaves the connection usable.
        #expect(try await worker.execute("SELECT 1") != .rows(.empty))
    }

    @Test(arguments: TestServer.allCases)
    func killConnectionDropsIt(server: TestServer) async throws {
        let admin = try await MySQLSession.connect(server.config())
        let victim = try await MySQLSession.connect(server.config())
        defer { Task { await admin.close() } }

        try await admin.kill(processID: victim.processID, connection: true)
        try await Task.sleep(for: .milliseconds(300))
        let remaining = try await admin.processList().map(\.id)
        #expect(!remaining.contains(victim.processID))
        await #expect {
            _ = try await victim.execute("SELECT 1")
        } throws: { error in
            (error as? DatabaseError)?.category == .connection
        }
    }
}
