import Darwin
import Foundation
import TableRoadCore
import Testing

@testable import TableRoadMySQL

/// Engines from docker/compose.yml. Tests skip when the port isn't reachable.
enum TestServer: String, CaseIterable, CustomTestStringConvertible {
    case mysql, mariadb

    var port: Int { self == .mysql ? 13306 : 13307 }
    var expectedKind: DatabaseKind { self == .mysql ? .mysql : .mariadb }
    var testDescription: String { rawValue }

    func config(
        tls: TLSMode = .prefer, username: String = "tableroad", password: String = "tableroad",
        database: String? = "tableroad"
    ) -> MySQLConnectConfig {
        MySQLConnectConfig(
            host: "127.0.0.1", port: port, username: username, password: password, database: database, tls: tls)
    }

    /// Root account from docker/compose.yml, for tests that change global settings.
    var rootConfig: MySQLConnectConfig { config(username: "root") }

    static let available: Bool = allCases.allSatisfy { isReachable(port: $0.port) }

    static func isReachable(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

@Suite(.enabled(if: TestServer.available, "Start docker/compose.yml to run MySQL integration tests"))
struct MySQLSessionTests {
    @Test(arguments: TestServer.allCases, [TLSMode.disable, .prefer, .require])
    func connectsAndDetectsFlavor(server: TestServer, tls: TLSMode) async throws {
        let session = try await MySQLSession.connect(server.config(tls: tls))
        #expect(await session.kind == server.expectedKind)
        #expect(await session.currentDatabase == "tableroad")
        // Both Docker images offer TLS, so prefer must not silently downgrade.
        #expect(session.isEncrypted == (tls != .disable))
        await session.close()
    }

    @Test(arguments: TestServer.allCases)
    func wrongPasswordIsAuthenticationError(server: TestServer) async {
        await #expect {
            _ = try await MySQLSession.connect(server.config(password: "wrong"))
        } throws: { error in
            (error as? DatabaseError)?.category == .authentication
        }
    }

    @Test(arguments: TestServer.allCases)
    func decodesTypes(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        let outcome = try await session.execute(
            """
            SELECT c.id, c.email, c.is_active, c.metadata, c.created_at, o.total, o.status, NULL AS nothing,
                   CAST(18446744073709551615 AS UNSIGNED) AS big, UNHEX('CAFE') AS raw
            FROM customers c JOIN orders o ON o.customer_id = c.id ORDER BY o.id LIMIT 1
            """)
        guard case .rows(let result) = outcome, let row = result.rows.first else {
            Issue.record("expected rows")
            return
        }
        #expect(result.columns.map(\.name).prefix(3) == ["id", "email", "is_active"])
        #expect(result.columns[0].table == "customers")
        if case .int = row[0] {} else { Issue.record("id should be int, got \(row[0])") }
        if case .text(let email) = row[1] { #expect(email.hasSuffix("@example.com")) } else { Issue.record("email") }
        if case .decimal = row[5] {} else { Issue.record("total should be decimal, got \(row[5])") }
        if case .temporal = row[4] {} else { Issue.record("created_at should be temporal, got \(row[4])") }
        #expect(row[6] == .text("pending") || row[6] == .text("paid") || row[6] == .text("shipped"))
        #expect(row[7] == .null)
        #expect(row[8] == .uint(UInt64.max))
        #expect(row[9] == .bytes(Data([0xCA, 0xFE])))
        // MySQL reports JSON natively; MariaDB stores JSON as LONGTEXT.
        switch row[3] {
        case .json(let text), .text(let text): #expect(text.contains("tier"))
        default: Issue.record("metadata should be JSON text, got \(row[3])")
        }
    }

    @Test(arguments: TestServer.allCases)
    func affectedRowsAndEmptyResults(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        _ = try await session.execute("CREATE TEMPORARY TABLE scratch (id INT PRIMARY KEY, name VARCHAR(20))")
        #expect(
            try await session.execute("INSERT INTO scratch VALUES (1,'a'),(2,'b'),(3,'c')") == .affected(rowCount: 3))
        #expect(try await session.execute("UPDATE scratch SET name = 'z' WHERE id > 1") == .affected(rowCount: 2))
        #expect(try await session.execute("SELECT * FROM scratch WHERE id = 99") == .rows(.empty))
    }

    @Test(arguments: TestServer.allCases)
    func queryErrorsCarryServerCode(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        await #expect {
            _ = try await session.execute("SELECT * FROM no_such_table")
        } throws: { error in
            (error as? DatabaseError)?.code == 1146
        }
        // The session stays usable after an error.
        #expect(try await session.execute("SELECT 1") != .rows(.empty))
    }

    @Test(arguments: TestServer.allCases)
    func introspection(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config(database: nil))
        defer { Task { await session.close() } }
        #expect(try await session.databases().contains("tableroad"))
        let tables = try await session.tables(in: "tableroad")
        #expect(tables.map(\.name) == ["customers", "orders"])
        let columns = try await session.columns(of: "orders", in: "tableroad")
        #expect(columns.first?.name == "id")
        #expect(columns.first?.isPrimaryKey == true)
        #expect(columns.first { $0.name == "status" }?.type.hasPrefix("enum(") == true)
        try await session.useDatabase("tableroad")
        #expect(await session.currentDatabase == "tableroad")
    }

    @Test(arguments: TestServer.allCases)
    func cancelsLongRunningQuery(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        let start = Date()
        async let slow = session.execute("SELECT SLEEP(20)")
        try await Task.sleep(for: .milliseconds(500))
        try await session.cancelCurrentQuery()
        // KILL QUERY on SLEEP() returns 1 (interrupted) rather than an error on both engines.
        _ = try? await slow
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(try await session.execute("SELECT 1") != .rows(.empty))
    }
}
