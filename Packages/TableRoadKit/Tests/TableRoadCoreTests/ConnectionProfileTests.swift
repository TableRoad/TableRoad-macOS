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

@Suite struct ColumnChoicesTests {
    @Test func parsesEnumAndSetValues() {
        let column = ColumnDetail(
            name: "s", type: "enum('pending','paid','it''s, ok')", isNullable: false, isPrimaryKey: false)
        #expect(column.choices == ["pending", "paid", "it's, ok"])
        #expect(
            ColumnDetail(name: "x", type: "set('a','b')", isNullable: true, isPrimaryKey: false).choices == ["a", "b"])
        #expect(ColumnDetail(name: "x", type: "varchar(20)", isNullable: true, isPrimaryKey: false).choices == nil)
    }
}

@Suite struct ConnectionProfileCompatibilityTests {
    /// A connections.json entry written before status colour, password storage, bootstrap SQL and TLS files existed.
    let v1JSON = """
        {"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","modifiedAt":"2026-11-16T21:00:00Z","name":"Old",
         "kind":"mysql","host":"db","port":3306,"username":"app","tls":"prefer","tag":"production",
         "safeMode":"confirmWrites"}
        """

    @Test func decodesProfilesSavedBeforeNewFields() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(ConnectionProfile.self, from: Data(v1JSON.utf8))
        #expect(profile.name == "Old")
        #expect(profile.tag == .production)
        #expect(profile.statusColor == .none)
        #expect(profile.passwordStorage == .keychain)
        #expect(profile.bootstrapSQL == nil)
        #expect(profile.tlsFiles.isEmpty)
    }

    @Test func roundTripsNewFields() throws {
        // Whole-second date: ISO-8601 on disk drops fractional seconds.
        let profile = ConnectionProfile(
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000), name: "New", kind: .mariadb, tls: .verifyCA,
            statusColor: .green, passwordStorage: .askEachTime,
            bootstrapSQL: "SET time_zone = '+00:00';", tlsFiles: TLSFiles(caCertPath: "/tmp/ca.pem"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ConnectionProfile.self, from: encoder.encode(profile)) == profile)
    }

    @Test func verifyCAFromURL() throws {
        #expect(try ConnectionURL.parse("mysql://a@h/db?ssl-mode=VERIFY_CA").profile.tls == .verifyCA)
    }
}

struct ConnectionURLStringTests {
    @Test func roundTripsWithoutPassword() throws {
        let parsed = try ConnectionURL.parse("mariadb://app:pw@db.example.com:3307/shop")
        let url = ConnectionURL.string(for: parsed.profile)
        #expect(url == "mariadb://app@db.example.com:3307/shop")
        #expect(try ConnectionURL.parse(url).profile.port == 3307)
        #expect(ConnectionURL.string(for: ConnectionProfile(name: "x", kind: .mysql, host: "h")) == "mysql://h")
    }
}
