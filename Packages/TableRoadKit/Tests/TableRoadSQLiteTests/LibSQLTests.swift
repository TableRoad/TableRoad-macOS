import Darwin
import Foundation
import TableRoadCore
import TableRoadSQL
import Testing

@testable import TableRoadSQLite

enum LibSQLServer {
    static let available: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(18080).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }()
}

@Suite(.enabled(if: LibSQLServer.available, "Start the libsql service in docker/compose.yml"), .serialized)
struct LibSQLTests {
    @Test func endToEnd() async throws {
        let profile = ConnectionProfile(name: "x", kind: .libsql, host: "127.0.0.1", port: 18080, tls: .disable)
        let session = try await LibSQLSession.connect(try LibSQLConnectConfig(profile: profile, password: nil))
        let table = "t_\(UInt32.random(in: 0...UInt32.max))"
        try await session.run(
            """
            CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, data BLOB);
            CREATE INDEX \(table)_name ON \(table)(name);
            INSERT INTO \(table) (name, score, data) VALUES ('a', 1.5, x'00ff'), ('b', NULL, NULL);
            """)
        guard case .rows(let result) = try await session.execute("SELECT * FROM \(table) ORDER BY id") else {
            Issue.record("expected rows")
            return
        }
        #expect(result.rows[0] == [.int(1), .text("a"), .double(1.5), .bytes(Data([0x00, 0xFF]))])
        #expect(result.rows[1][2] == .null)
        #expect(try await session.tables(in: "main").contains { $0.name == table })
        #expect(try await session.columns(of: table, in: "main").first?.isPrimaryKey == true)
        #expect(try await session.indexes(of: table, in: "main").contains { $0.name == "\(table)_name" })

        let builder = TableChangeBuilder(database: "main", table: table, dialect: SQLiteDialect())
        let affected = try await session.executeTransaction([
            builder.statement(
                for: .update(key: RowKey([("id", "2")]), set: [.init(column: "score", edit: .text("9"))])),
            builder.statement(for: .insert([.init(column: "name", edit: .text("c"))])),
        ])
        #expect(affected == [1, 1])
        // A failing statement rolls the whole transaction back.
        await #expect(throws: TransactionError.self) {
            try await session.executeTransaction([
                builder.statement(
                    for: .update(key: RowKey([("id", "1")]), set: [.init(column: "name", edit: .text("z"))])),
                builder.statement(for: .insert([.init(column: "name", edit: .null)])),
            ])
        }
        guard case .rows(let check) = try await session.execute("SELECT name FROM \(table) WHERE id = 1") else {
            return
        }
        #expect(check.rows.first?.first == .text("a"))
        try await session.run("DROP TABLE \(table)")
    }
}
