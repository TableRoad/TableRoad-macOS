import Foundation
import TableRoadCore
import Testing

@testable import TableRoadMySQL

@Suite(.enabled(if: TestServer.available, "Start docker/compose.yml to run MySQL integration tests"))
struct MySQLConnectOptionsTests {
    @Test(arguments: TestServer.allCases)
    func bootstrapRunsOnEveryConnection(server: TestServer) async throws {
        var config = server.config()
        config.bootstrapSQL =
            "SET @tableroad_marker = 'hello';\nSET SESSION sql_mode = 'ANSI_QUOTES,NO_BACKSLASH_ESCAPES'"
        let session = try await MySQLSession.connect(config)
        defer { Task { await session.close() } }
        guard case .rows(let result) = try await session.execute("SELECT @tableroad_marker") else {
            Issue.record("expected rows")
            return
        }
        #expect(result.rows.first?.first == .text("hello"))
        // The dialect is read after bootstrap, so it sees the bootstrap's sql_mode.
        #expect(session.dialect.backslashEscapes == false)
    }

    @Test(arguments: TestServer.allCases)
    func failingBootstrapFailsTheConnection(server: TestServer) async {
        var config = server.config()
        config.bootstrapSQL = "SET @ok = 1; SELECT * FROM missing_table"
        await #expect {
            _ = try await MySQLSession.connect(config)
        } throws: { error in
            (error as? DatabaseError)?.message.contains("Bootstrap command failed") == true
        }
    }

    @Test(arguments: TestServer.allCases)
    func reportsCipher(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config(tls: .require))
        defer { Task { await session.close() } }
        #expect(session.tlsCipher?.isEmpty == false)
        let plain = try await MySQLSession.connect(server.config(tls: .disable))
        defer { Task { await plain.close() } }
        #expect(plain.tlsCipher == nil)
    }

    /// docker/certs/mysql-ca.pem is the CA MySQL's image generated (copied out with `docker cp`).
    static let mysqlCA: String? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../docker/certs/mysql-ca.pem").standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }()

    @Test(.enabled(if: mysqlCA != nil, "docker/certs/mysql-ca.pem not present"))
    func verifyCAAcceptsTheServerButVerifyIdentityChecksTheHostname() async throws {
        var config = TestServer.mysql.config(tls: .verifyCA)
        config.tlsFiles = TLSFiles(caCertPath: Self.mysqlCA)
        let verified = try await MySQLSession.connect(config)
        #expect(verified.isEncrypted)
        await verified.close()

        // The auto-generated certificate isn't issued for 127.0.0.1, so hostname verification must fail.
        config.tls = .verifyFull
        await #expect(throws: (any Error).self) {
            _ = try await MySQLSession.connect(config)
        }

        // Without the CA, VERIFY_CA can't trust a self-signed server.
        config.tls = .verifyCA
        config.tlsFiles = TLSFiles()
        await #expect(throws: (any Error).self) {
            _ = try await MySQLSession.connect(config)
        }
    }
}
