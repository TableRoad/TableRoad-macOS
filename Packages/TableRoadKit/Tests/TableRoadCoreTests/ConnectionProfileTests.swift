import Foundation
import Testing

@testable import TableRoadCore

@Suite struct ConnectionProfileTests {
    @Test func codableRoundTripWithSSH() throws {
        let profile = ConnectionProfile(
            name: "Prod",
            kind: .mariadb,
            host: "10.0.0.5",
            username: "app",
            database: "shop",
            ssh: SSHConfig(
                host: "bastion.example.com", username: "deploy",
                auth: .privateKey(.file(path: "~/.ssh/id_ed25519"))),
            tag: .production,
            safeMode: .confirmWrites
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConnectionProfile.self, from: encoder.encode(profile))
        #expect(decoded.ssh == profile.ssh)
        #expect(decoded.port == 3306)
        #expect(decoded.tag == .production)
    }
}
