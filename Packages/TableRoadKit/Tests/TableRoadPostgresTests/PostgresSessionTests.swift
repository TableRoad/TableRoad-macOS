import Darwin
import Foundation
import TableRoadCore
import TableRoadSQL
import TableRoadTransfer
import Testing

@testable import TableRoadPostgres

/// The Postgres container from docker/compose.yml (seeded `shop` schema).
enum PG {
    static let config = PostgresConnectConfig(
        host: "127.0.0.1", port: 15432, username: "tableroad", password: "tableroad", database: "tableroad",
        tls: .prefer)

    @Sendable static func connect() async throws -> any SQLClient { try await PostgresSession.connect(config) }

    static let available: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(15432).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }()
}

@Suite(.enabled(if: PG.available, "Start docker/compose.yml to run PostgreSQL tests"), .serialized)
struct PostgresSessionTests {
    @Test func connectsAndDescribesItself() async throws {
        let session = try await PostgresSession.connect(PG.config)
        #expect(await session.serverVersion.hasPrefix("17"))
        #expect(session.processID > 0)
        #expect(session.databaseName == "tableroad")
        #expect(await session.currentDatabase == "public")
        await #expect {
            _ = try await PostgresSession.connect(
                PostgresConnectConfig(host: "127.0.0.1", port: 15432, username: "tableroad", password: "wrong"))
        } throws: { ($0 as? DatabaseError)?.category == .authentication }
    }

    @Test func typedResultsAndAffectedRows() async throws {
        let session = try await PostgresSession.connect(PG.config)
        guard
            case .rows(let result) = try await session.execute(
                "SELECT 1::int, 2.50::numeric, true, 'x'::text, '\\xdead'::bytea, '{\"a\":1}'::jsonb, "
                    + "'2026-01-02 03:04:05.25+00'::timestamptz, NULL::text, gen_random_uuid(), "
                    + "ARRAY['web', 'a b', NULL]::text[], '1999-12-31'::date, '1 day 02:00'::interval")
        else {
            Issue.record("expected rows")
            return
        }
        let row = result.rows[0]
        #expect(row[0] == .int(1))
        #expect(row[1] == .decimal("2.50"))
        #expect(row[2] == .bool(true))
        #expect(row[3] == .text("x"))
        #expect(row[4] == .bytes(Data([0xDE, 0xAD])))
        #expect(row[5] == .json(#"{"a": 1}"#))
        if case .temporal = row[6] {} else { Issue.record("timestamptz should be temporal: \(row[6])") }
        #expect(row[7] == .null)
        if case .uuid = row[8] {} else { Issue.record("uuid: \(row[8])") }
        #expect(row[6] == .temporal("2026-01-02 03:04:05.25+00"))
        #expect(row[9] == .text(#"{web,"a b",NULL}"#))
        #expect(row[10] == .temporal("1999-12-31"))
        #expect(row[11] == .temporal("1 day 02:00:00"))

        try await session.run("CREATE TEMP TABLE t (id int)")
        guard case .affected(let count) = try await session.execute("INSERT INTO t SELECT generate_series(1, 7)")
        else {
            Issue.record("expected affected")
            return
        }
        #expect(count == 7)
        guard case .rows(let returning) = try await session.execute("DELETE FROM t WHERE id < 3 RETURNING id")
        else {
            Issue.record("expected RETURNING rows")
            return
        }
        #expect(returning.rows.count == 2)
    }

    @Test func introspectionOfSeedSchema() async throws {
        let session = try await PostgresSession.connect(PG.config)
        let schemas = try await session.databases()
        #expect(schemas.contains("shop") && schemas.contains("public"))
        let tables = try await session.tables(in: "shop")
        #expect(tables.map(\.name) == ["customers", "orders"])
        let columns = try await session.columns(of: "customers", in: "shop")
        #expect(columns.map(\.name) == ["id", "email", "name", "is_active", "metadata", "created_at"])
        #expect(columns[0].isPrimaryKey && columns[0].extra == "serial" && columns[0].type == "bigint")
        #expect(columns[3].defaultValue == "true")
        let indexes = try await session.indexes(of: "orders", in: "shop")
        #expect(indexes.first?.name == "PRIMARY")
        #expect(indexes.contains { $0.name == "orders_customer_idx" && $0.columns == ["customer_id"] })
        let keys = try await session.foreignKeys(of: "orders", in: "shop")
        #expect(keys.first?.referencedTable == "customers" && keys.first?.columns == ["customer_id"])
        let status = try await session.tableStatus(of: "orders", in: "shop")
        #expect((status.dataBytes ?? 0) > 0)
        let ddl = try await session.createStatement(of: "customers", in: "shop")
        #expect(ddl.contains("\"id\" bigserial NOT NULL"))
        #expect(!ddl.contains("shop."))
    }

    @Test func editingWithUntypedParameters() async throws {
        let session = try await PostgresSession.connect(PG.config)
        try await session.run("CREATE TEMP TABLE edits (id int PRIMARY KEY, n numeric, flag boolean, at date)")
        let builder = TableChangeBuilder(database: "pg_temp", table: "edits", dialect: PostgresDialect())
        let insert = builder.statement(
            for: .insert([
                ColumnEdit(column: "id", edit: .text("1")), ColumnEdit(column: "n", edit: .text("2.5")),
                ColumnEdit(column: "flag", edit: .text("true")), ColumnEdit(column: "at", edit: .text("2026-11-17")),
            ]))
        #expect(insert.sql.contains("$4"))
        let update = builder.statement(
            for: .update(key: RowKey([("id", "1")]), set: [ColumnEdit(column: "n", edit: .null)]))
        #expect(!update.sql.contains("LIMIT"))
        #expect(try await session.executeTransaction([insert, update]) == [1, 1])
        // A failure rolls back everything.
        await #expect(throws: TransactionError.self) {
            try await session.executeTransaction([
                builder.statement(for: .insert([ColumnEdit(column: "id", edit: .text("2"))])),
                builder.statement(for: .insert([ColumnEdit(column: "id", edit: .text("not a number"))])),
            ])
        }
        guard case .rows(let rows) = try await session.execute("SELECT count(*) FROM edits") else { return }
        #expect(rows.rows.first?.first == .int(1))
    }

    @Test func pagingFiltersAndLikeOnNumbers() async throws {
        let session = try await PostgresSession.connect(PG.config)
        let query = PageQuery(
            database: "shop", table: "customers", sort: [ColumnSort(column: "id", ascending: false)],
            filters: FilterSet(filters: [ColumnFilter(column: "id", op: .contains, value: "99")]), limit: 5)
        guard case .rows(let page) = try await session.execute(query.selectSQL(PostgresDialect())) else { return }
        #expect(page.rows.count == 5)
        #expect(page.rows.first?.first == .int(4999))
    }

    @Test func cancelAndProcessList() async throws {
        let session = try await PostgresSession.connect(PG.config)
        let processes = try await session.processList()
        #expect(processes.contains { $0.id == session.processID })
        let task = Task { try await session.execute("SELECT pg_sleep(20)") }
        try await Task.sleep(for: .milliseconds(300))
        try await session.cancelCurrentQuery()
        await #expect {
            _ = try await task.value
        } throws: { ($0 as? DatabaseError)?.category == .cancelled }
    }

    @Test func dumpRoundTripIntoAnotherSchema() async throws {
        let admin = try await PostgresSession.connect(PG.config)
        let target = "tr_copy_\(UInt32.random(in: 0...UInt32.max))"
        try await admin.run(PostgresDialect().createDatabaseSQL(target, characterSet: nil, collation: nil))
        let file = FileManager.default.temporaryDirectory.appending(path: "tr-pg-\(UUID()).sql")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let exported = try await TableExport.run(
                items: [
                    ExportItem(database: "shop", table: "customers"), ExportItem(database: "shop", table: "orders"),
                ], kind: .sql(gzip: false), destination: file, connect: PG.connect)
            #expect(exported.rows == 25_000)
            let imported = try await SQLDumpImport.run(
                file: file, database: target, stopOnError: true, connect: PG.connect)
            #expect(
                imported.failures.isEmpty,
                "\(imported.failures.first?.message ?? "") in \(imported.failures.first?.sql ?? "")")
            for table in ["customers", "orders"] {
                let checksum =
                    "SELECT md5(string_agg(t::text, ',' ORDER BY t::text)) FROM %@.\(table) t"
                guard
                    case .rows(let a) = try await admin.execute(checksum.replacingOccurrences(of: "%@", with: "shop")),
                    case .rows(let b) = try await admin.execute(checksum.replacingOccurrences(of: "%@", with: target))
                else { continue }
                #expect(a.rows == b.rows, "\(table) differs")
            }
            // The serial sequence moved on, so new rows don't collide.
            try await admin.run("INSERT INTO \(target).customers (email) VALUES ('new@example.com')")
        } catch {
            Issue.record(error)
        }
        try await admin.run(PostgresDialect().dropDatabaseSQL(target))
    }
}
