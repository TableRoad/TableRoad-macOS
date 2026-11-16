import Testing

@testable import TableRoadCore

@Suite struct ConnectionURLTests {
    @Test func postgresFull() throws {
        let parsed = try ConnectionURL.parse(
            "postgres://alice:s%40cret@db.example.com:6543/app_prod?sslmode=verify-full")
        #expect(parsed.profile.kind == .postgres)
        #expect(parsed.profile.host == "db.example.com")
        #expect(parsed.profile.port == 6543)
        #expect(parsed.profile.username == "alice")
        #expect(parsed.profile.database == "app_prod")
        #expect(parsed.profile.tls == .verifyFull)
        #expect(parsed.password == "s@cret")
    }

    @Test func postgresqlSchemeAndDefaultPort() throws {
        let parsed = try ConnectionURL.parse("postgresql://bob@localhost")
        #expect(parsed.profile.kind == .postgres)
        #expect(parsed.profile.port == 5432)
        #expect(parsed.profile.database == nil)
        #expect(parsed.password == nil)
    }

    @Test(arguments: [("mysql", DatabaseKind.mysql), ("mariadb", .mariadb)])
    func mysqlFamily(scheme: String, kind: DatabaseKind) throws {
        let parsed = try ConnectionURL.parse("\(scheme)://root:pw@127.0.0.1/shop")
        #expect(parsed.profile.kind == kind)
        #expect(parsed.profile.port == 3306)
        #expect(parsed.profile.database == "shop")
    }

    @Test func redisWithDatabaseIndex() throws {
        let parsed = try ConnectionURL.parse("redis://:hunter2@cache:6380/3")
        #expect(parsed.profile.kind == .redis)
        #expect(parsed.profile.port == 6380)
        #expect(parsed.profile.database == "3")
        #expect(parsed.profile.tls == .disable)
        #expect(parsed.password == "hunter2")
    }

    @Test func redissMeansTLS() throws {
        let parsed = try ConnectionURL.parse("rediss://cache.example.com")
        #expect(parsed.profile.tls == .require)
        #expect(parsed.profile.port == 6379)
    }

    @Test func rejectsBadInput() {
        #expect(throws: ConnectionURL.ParseError.unsupportedScheme("mongodb")) {
            try ConnectionURL.parse("mongodb://localhost")
        }
        #expect(throws: ConnectionURL.ParseError.invalidRedisDatabase("99")) {
            try ConnectionURL.parse("redis://localhost/99")
        }
        #expect(throws: ConnectionURL.ParseError.missingHost) {
            try ConnectionURL.parse("postgres:///db")
        }
    }
}
