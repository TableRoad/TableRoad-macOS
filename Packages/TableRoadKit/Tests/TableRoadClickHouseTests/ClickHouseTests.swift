import Darwin
import Foundation
import TableRoadCore
import TableRoadSQL
import TableRoadTransfer
import Testing

@testable import TableRoadClickHouse

enum CH {
    static let config = ClickHouseConnectConfig(
        host: "127.0.0.1", port: 18123, username: "tableroad", password: "tableroad", database: "tableroad")

    @Sendable static func connect() async throws -> any SQLClient { try await ClickHouseSession.connect(config) }

    static let available: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(18123).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }()
}

@Suite(.enabled(if: CH.available, "Start the clickhouse service in docker/compose.yml"), .serialized)
struct ClickHouseTests {
    @Test func dialectEscaping() {
        let dialect = ClickHouseDialect()
        #expect(dialect.stringLiteral(#"it's \ odd"#) == #"'it\'s \\ odd'"#)
        let filter = ColumnFilter(column: "name", op: .contains, value: "50%_off")
        #expect(filter.condition(dialect) == #"`name` LIKE '%50\\%\\_off%'"#)
    }

    @Test func endToEnd() async throws {
        let session = try await ClickHouseSession.connect(CH.config)
        #expect(await session.serverVersion.hasPrefix("24."))
        #expect(await session.currentDatabase == "tableroad")
        await #expect {
            _ = try await ClickHouseSession.connect(
                ClickHouseConnectConfig(host: "127.0.0.1", port: 18123, username: "tableroad", password: "nope"))
        } throws: { ($0 as? DatabaseError)?.category == .authentication }

        let database = "tr_\(UInt32.random(in: 0...UInt32.max))"
        try await session.run("CREATE DATABASE \(database)")
        do {
            try await session.run(
                """
                CREATE TABLE \(database).events (
                    id UInt64, name String, price Decimal(10, 2), at DateTime, tags Array(String),
                    note Nullable(String), score Float64, flag Bool, INDEX name_idx name TYPE bloom_filter GRANULARITY 1
                ) ENGINE = MergeTree ORDER BY (id) COMMENT 'Event log';
                INSERT INTO \(database).events
                SELECT number, concat('event ', toString(number)), number / 4, toDateTime('2026-01-01 00:00:00') + number,
                    ['a', 'b'], if(number % 2 = 0, NULL, 'odd'), number * 1.5, number % 2 = 0
                FROM numbers(4500);
                """)
            guard
                case .rows(let result) = try await session.execute(
                    "SELECT * FROM \(database).events ORDER BY id LIMIT 2")
            else {
                Issue.record("expected rows")
                return
            }
            #expect(result.columns.map(\.name) == ["id", "name", "price", "at", "tags", "note", "score", "flag"])
            let row = result.rows[1]
            #expect(row[0] == .int(1))
            #expect(row[1] == .text("event 1"))
            #expect(row[2] == .decimal("0.25"))
            #expect(row[3] == .temporal("2026-01-01 00:00:01"))
            #expect(row[4] == .json(#"["a","b"]"#))
            #expect(row[5] == .text("odd"))
            #expect(result.rows[0][5] == .null)
            #expect(row[7] == .bool(false))

            #expect(try await session.databases().contains(database))
            #expect(try await session.tables(in: database).map(\.name) == ["events"])
            let columns = try await session.columns(of: "events", in: database)
            #expect(columns.first?.extra == "sorting key")
            #expect(columns.contains { $0.name == "note" && $0.isNullable })
            let indexes = try await session.indexes(of: "events", in: database)
            #expect(indexes.map(\.name) == ["PRIMARY", "name_idx"])
            let status = try await session.tableStatus(of: "events", in: database)
            #expect(status.estimatedRows == 4500 && status.comment == "Event log")
            let ddl = try await session.createStatement(of: "events", in: database)
            #expect(ddl.hasPrefix("CREATE TABLE events"))

            try await session.useDatabase(database)
            let query = PageQuery(
                database: database, table: "events", sort: [ColumnSort(column: "id", ascending: false)],
                filters: FilterSet(filters: [ColumnFilter(column: "name", op: .endsWith, value: "99")]), limit: 3)
            guard case .rows(let page) = try await session.execute(query.selectSQL(ClickHouseDialect())) else { return }
            #expect(page.rows.map { $0[0] } == [.int(4499), .int(4399), .int(4299)])
            guard case .rows(let count) = try await session.execute(query.countSQL(ClickHouseDialect())) else { return }
            #expect(count.rows.first?.first == .int(45))

            let csv = FileManager.default.temporaryDirectory.appending(path: "tr-ch-\(UUID()).csv")
            let exported = try await TableExport.run(
                items: [ExportItem(database: database, table: "events")], kind: .csv(CSVOptions()), destination: csv,
                connect: CH.connect)
            #expect(exported.rows == 4500)

            // SQL dump into another database.
            let dump = FileManager.default.temporaryDirectory.appending(path: "tr-ch-\(UUID()).sql")
            _ = try await TableExport.run(
                items: [ExportItem(database: database, table: "events")], kind: .sql(gzip: false), destination: dump,
                connect: CH.connect)
            try await session.run("CREATE DATABASE \(database)_copy")
            let imported = try await SQLDumpImport.run(
                file: dump, database: "\(database)_copy", stopOnError: true, connect: CH.connect)
            #expect(imported.failures.isEmpty, "\(imported.failures.first?.message ?? "")")
            guard
                case .rows(let a) = try await session.execute("SELECT sum(cityHash64(*)) FROM \(database).events"),
                case .rows(let b) = try await session.execute("SELECT sum(cityHash64(*)) FROM \(database)_copy.events")
            else { return }
            #expect(a.rows == b.rows)
            #expect(!(try await session.processList()).isEmpty)
        } catch {
            Issue.record(error)
        }
        try await session.run("DROP DATABASE IF EXISTS \(database)")
        try await session.run("DROP DATABASE IF EXISTS \(database)_copy")
    }

    @Test func cancelKillsTheQuery() async throws {
        let session = try await ClickHouseSession.connect(CH.config)
        let task = Task {
            try await session.execute("SELECT sleepEachRow(0.5) FROM numbers(100) SETTINGS max_block_size = 1")
        }
        try await Task.sleep(for: .milliseconds(700))
        try await session.cancelCurrentQuery()
        await #expect(throws: DatabaseError.self) { _ = try await task.value }
    }
}
