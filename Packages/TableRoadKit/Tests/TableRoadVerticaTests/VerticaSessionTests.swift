import Darwin
import Foundation
import TableRoadCore
import TableRoadSQL
import Testing

@testable import TableRoadVertica

/// The Vertica container from docker/compose.yml (dbadmin, no password, database `tableroad`, port 15433).
enum VerticaServer {
    static let port = 15433
    static func config(tls: TLSMode = .prefer, password: String? = nil) -> VerticaConnectConfig {
        VerticaConnectConfig(
            host: "127.0.0.1", port: port, username: "dbadmin", password: password, database: "tableroad", tls: tls)
    }

    static let available: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }()

    static func seed(_ session: VerticaSession) async throws {
        for statement in [
            "DROP SCHEMA IF EXISTS shop CASCADE", "CREATE SCHEMA shop",
            "CREATE TABLE shop.customers (id INT NOT NULL PRIMARY KEY, email VARCHAR(200) NOT NULL, name VARCHAR(100))",
            """
            CREATE TABLE shop.orders (id IDENTITY(1,1) PRIMARY KEY, customer_id INT NOT NULL
                REFERENCES shop.customers(id), total NUMERIC(12,2))
            """,
            "CREATE VIEW shop.names AS SELECT id, name FROM shop.customers",
            """
            CREATE TABLE shop.types (id INT, t_bool BOOLEAN, t_float FLOAT, t_numeric NUMERIC(20,4), t_char CHAR(4),
                t_varchar VARCHAR(20), t_long LONG VARCHAR, t_date DATE, t_time TIME, t_timetz TIMETZ,
                t_ts TIMESTAMP, t_tstz TIMESTAMPTZ, t_interval INTERVAL DAY TO SECOND, t_binary VARBINARY(10),
                t_uuid UUID)
            """,
            """
            INSERT INTO shop.types VALUES (1, true, 2.5, 12345678.9012, 'ab', 'Zoë 🚀', 'long', '2026-11-17',
                '13:45:30', '13:45:30+05:30', '2026-11-17 13:45:30.123456', '2026-11-17 13:45:30+00',
                '1 day 02:03:04', HEX_TO_BINARY('00ff5c'), '6f9619ff-8b86-d011-b42d-00c04fc964ff')
            """,
            "INSERT INTO shop.types (id) VALUES (2)",
            "COMMIT",
        ] {
            _ = try await session.execute(statement)
        }
        for index in 1...25 {
            _ = try await session.execute(
                "INSERT INTO shop.customers VALUES (\(index), 'user\(index)@example.com', 'User \(index)')")
        }
        _ = try await session.execute(
            "INSERT INTO shop.orders (customer_id, total) SELECT id, id * 10.5 FROM shop.customers")
        _ = try await session.execute("COMMIT")
    }
}

@Suite(
    .enabled(if: VerticaServer.available, "Start the Vertica container (docker/compose.yml) to run these"), .serialized)
struct VerticaSessionTests {
    @Test func connectsAndQueries() async throws {
        let session = try await VerticaSession.connect(VerticaServer.config())
        defer { Task { await session.close() } }
        #expect(await !session.serverVersion.isEmpty)
        guard case .rows(let result) = try await session.execute("SELECT 1 AS one, 'x' AS two") else {
            Issue.record("no rows")
            return
        }
        #expect(result.columns.map(\.name) == ["one", "two"])
        #expect(result.rows == [[.int(1), .text("x")]])
    }

    @Test func seedsAndDecodesTypes() async throws {
        let session = try await VerticaSession.connect(VerticaServer.config())
        defer { Task { await session.close() } }
        try await VerticaServer.seed(session)
        guard case .rows(let result) = try await session.execute("SELECT * FROM shop.types ORDER BY id") else { return }
        let row = Dictionary(uniqueKeysWithValues: zip(result.columns.map(\.name), result.rows[0]))
        #expect(row["t_bool"] == .bool(true))
        #expect(row["t_float"] == .double(2.5))
        #expect(row["t_numeric"] == .decimal("12345678.9012"))
        #expect(row["t_varchar"] == .text("Zoë 🚀"))
        #expect(row["t_long"] == .text("long"))
        #expect(row["t_date"] == .temporal("2026-11-17"))
        #expect(row["t_ts"] == .temporal("2026-11-17 13:45:30.123456"))
        #expect(row["t_binary"] == .bytes(Data([0x00, 0xFF, 0x5C])))
        #expect(row["t_uuid"] == .uuid(UUID(uuidString: "6f9619ff-8b86-d011-b42d-00c04fc964ff")!))
        #expect(row["t_interval"]?.displayText?.hasPrefix("1 02:03:04") == true)
        #expect(result.columns.first { $0.name == "t_numeric" }?.typeName == "numeric(20,4)")
        #expect(result.rows[1].dropFirst().allSatisfy { $0 == .null })
    }

    @Test func catalogAndPaging() async throws {
        let session = try await VerticaSession.connect(VerticaServer.config())
        defer { Task { await session.close() } }
        #expect(try await session.databases().contains("shop"))
        let tables = try await session.tables(in: "shop")
        #expect(tables.map(\.name) == ["customers", "orders", "types", "names"])
        #expect(tables.last?.kind == .view)
        let columns = try await session.columns(of: "customers", in: "shop")
        #expect(columns.map(\.name) == ["id", "email", "name"])
        #expect(columns[0].isPrimaryKey && !columns[1].isNullable)
        #expect(try await session.columns(of: "names", in: "shop").map(\.name) == ["id", "name"])
        let keys = try await session.foreignKeys(of: "orders", in: "shop")
        #expect(keys.first?.referencedTable == "customers")
        #expect(!(try await session.indexes(of: "customers", in: "shop")).isEmpty)
        let ddl = try await session.createStatement(of: "customers", in: "shop")
        #expect(ddl.contains("CREATE TABLE shop.customers"))

        let query = PageQuery(
            database: "shop", table: "customers", sort: [ColumnSort(column: "id", ascending: true)], limit: 10,
            offset: 20)
        guard case .rows(let page) = try await session.execute(query.selectSQL(VerticaDialect())) else { return }
        #expect(page.rows.map { $0[0] } == (21...25).map { .int(Int64($0)) })
        let filtered = PageQuery(
            database: "shop", table: "customers",
            filters: FilterSet(filters: [ColumnFilter(column: "id", op: .contains, value: "2")]))
        guard case .rows(let matches) = try await session.execute(filtered.selectSQL(VerticaDialect())) else { return }
        #expect(matches.rows.count == 8)  // 2, 12, 20–25
    }

    @Test func editsAndErrors() async throws {
        let session = try await VerticaSession.connect(VerticaServer.config())
        defer { Task { await session.close() } }
        let builder = TableChangeBuilder(database: "shop", table: "customers", dialect: VerticaDialect())
        let counts = try await session.executeTransaction([
            builder.statement(
                for: .update(key: RowKey([("id", "1")]), set: [ColumnEdit(column: "name", edit: .text("O'Neil"))])),
            builder.statement(
                for: .insert([
                    ColumnEdit(column: "id", edit: .text("100")), ColumnEdit(column: "email", edit: .text("n@x")),
                ])),
            builder.statement(for: .delete(key: RowKey([("id", "100")]))),
        ])
        #expect(counts == [1, 1, 1])
        guard case .rows(let renamed) = try await session.execute("SELECT name FROM shop.customers WHERE id = 1") else {
            return
        }
        #expect(renamed.rows == [[.text("O'Neil")]])
        do {
            _ = try await session.execute("SELECT * FROM shop.missing")
            Issue.record("expected an error")
        } catch let error as DatabaseError {
            #expect(error.category == .query)
            #expect(error.message.contains("missing"))
        }
        guard case .rows(let ok) = try await session.execute("SELECT 2") else { return }
        #expect(ok.rows == [[.int(2)]])
    }

    @Test func cancelStopsALongQuery() async throws {
        let session = try await VerticaSession.connect(VerticaServer.config())
        defer { Task { await session.close() } }
        let started = Date.now
        let running = Task { try await session.execute("SELECT SLEEP(20)") }
        try await Task.sleep(for: .seconds(1))
        try await session.cancelCurrentQuery()
        // SLEEP returns early when interrupted (other statements fail with "cancelled").
        _ = try? await running.value
        #expect(Date.now.timeIntervalSince(started) < 10)
        guard case .rows(let after) = try await session.execute("SELECT 3") else { return }
        #expect(after.rows == [[.int(3)]])
    }

    @Test func passwordLoginUsesTheServersHash() async throws {
        let admin = try await VerticaSession.connect(VerticaServer.config())
        _ = try? await admin.execute("DROP USER tableroad_pw")
        _ = try await admin.execute("CREATE USER tableroad_pw IDENTIFIED BY 'S3cret!pw'")
        await admin.close()
        var config = VerticaServer.config(password: "S3cret!pw")
        config.username = "tableroad_pw"
        let session = try await VerticaSession.connect(config)
        guard case .rows(let result) = try await session.execute("SELECT CURRENT_USER()") else { return }
        #expect(result.rows == [[.text("tableroad_pw")]])
        await session.close()
        config.password = "wrong"
        do {
            _ = try await VerticaSession.connect(config)
            Issue.record("expected a login failure")
        } catch let error as DatabaseError {
            #expect(error.category == .authentication)
        }
    }

    @Test func processList() async throws {
        let session = try await VerticaSession.connect(VerticaServer.config())
        defer { Task { await session.close() } }
        #expect(!(try await session.processList()).isEmpty)
    }

    @Test func binaryUnescaping() {
        #expect(VerticaColumn.unescapeBinary(Array(#"a\\b\001\377"#.utf8)) == Data([0x61, 0x5C, 0x62, 0x01, 0xFF]))
    }
}
