import Darwin
import Foundation
import NIOCore
import TableRoadCore
import TableRoadSQL
import TableRoadTransfer
import Testing

@testable import TableRoadCassandra

/// docker/compose.yml runs Cassandra 5 on 19042 with PasswordAuthenticator (cassandra / cassandra).
enum Cass {
    static let port = 19042
    static let config = CassandraConnectConfig(
        host: "127.0.0.1", port: port, username: "cassandra", password: "cassandra", tls: .disable)

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

    /// Idempotent schema and rows in keyspace `tableroad`.
    static func seed(_ session: CassandraSession) async throws {
        try await session.run(
            """
            CREATE KEYSPACE IF NOT EXISTS tableroad
                WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};
            CREATE TYPE IF NOT EXISTS tableroad.address (street text, zip int);
            CREATE TABLE IF NOT EXISTS tableroad.all_types (
                id int PRIMARY KEY, a_ascii ascii, a_bigint bigint, a_blob blob, a_boolean boolean, a_date date,
                a_decimal decimal, a_double double, a_duration duration, a_float float, a_inet inet, a_int int,
                a_smallint smallint, a_text text, a_time time, a_timestamp timestamp, a_timeuuid timeuuid,
                a_tinyint tinyint, a_uuid uuid, a_varint varint, a_list list<int>, a_set set<text>,
                a_map map<text, int>, a_tuple tuple<int, text>, a_udt frozen<address>,
                a_frozen_list frozen<list<list<int>>>, a_vector vector<float, 3>);
            INSERT INTO tableroad.all_types (id, a_ascii, a_bigint, a_blob, a_boolean, a_date, a_decimal, a_double,
                a_duration, a_float, a_inet, a_int, a_smallint, a_text, a_time, a_timestamp, a_timeuuid, a_tinyint,
                a_uuid, a_varint, a_list, a_set, a_map, a_tuple, a_udt, a_frozen_list, a_vector)
            VALUES (1, 'abc', -9223372036854775807, 0xcafe, true, '2024-02-29', -123.4500, 3.25, 1y2mo3d4h5m6s7ms,
                1.1, '::1', -42, -300, 'héllo ''quoted''', '12:34:56.789', '2024-01-02 03:04:05.678+0000',
                50554d6e-29bb-11e5-b345-feff819cdc9f, -7, 123e4567-e89b-12d3-a456-426614174000,
                123456789012345678901234567890, [1, 2, 3], {'x', 'y'}, {'k1': 1, 'k2': 2}, (1, 'two'),
                {street: 'Main', zip: 12345}, [[1], [2, 3]], [0.5, 1.5, 2.5]);
            INSERT INTO tableroad.all_types (id) VALUES (2);
            INSERT INTO tableroad.all_types (id, a_varint, a_decimal, a_inet, a_date) VALUES
                (3, -129, 0.001, '10.0.0.1', '1969-12-31');
            CREATE TABLE IF NOT EXISTS tableroad.events (
                tenant text, day date, ts timestamp, id int, level int, message text, tags set<text>,
                PRIMARY KEY ((tenant, day), ts, id)) WITH CLUSTERING ORDER BY (ts DESC, id ASC);
            CREATE INDEX IF NOT EXISTS events_level ON tableroad.events (level);
            CREATE TABLE IF NOT EXISTS tableroad.people (
                id int, tag text, score int, prefs map<text, int>, seen timestamp, PRIMARY KEY (id, tag));
            CREATE TABLE IF NOT EXISTS tableroad.counters (id int PRIMARY KEY, hits counter);
            """)
        var inserts = "BEGIN BATCH\n"
        for n in 0..<25 {
            inserts +=
                "INSERT INTO tableroad.events (tenant, day, ts, id, level, message) VALUES ('acme', '2024-01-01', "
                + "\(1_704_067_200_000 + Int64(n) * 1000), \(n), \(n % 5), 'event \(n)');\n"
        }
        try await session.run(inserts + "APPLY BATCH")
    }

    /// 6,000 rows in one partition: more than one protocol page.
    static func seedWide(_ session: CassandraSession) async throws {
        try await session.run("CREATE TABLE IF NOT EXISTS tableroad.wide (p int, c int, PRIMARY KEY (p, c))")
        var batch = "BEGIN UNLOGGED BATCH\n"
        for c in 0..<6000 { batch += "INSERT INTO tableroad.wide (p, c) VALUES (1, \(c));\n" }
        try await session.run(batch + "APPLY BATCH")
    }

    static func connectAndSeed() async throws -> CassandraSession {
        let session = try await CassandraSession.connect(config)
        try await seed(session)
        return session
    }
}

@Suite(.enabled(if: Cass.available, "Start the cassandra service in docker/compose.yml"), .serialized)
struct CassandraTests {
    @Test func connectsAndListsKeyspaces() async throws {
        let session = try await Cass.connectAndSeed()
        #expect(await session.serverVersion.hasPrefix("5."))
        #expect(await session.kind == .cassandra)
        #expect(session.isEncrypted == false)
        let keyspaces = try await session.databases()
        #expect(keyspaces.contains("tableroad"))
        #expect(!keyspaces.contains { CassandraSession.systemKeyspaces.contains($0) })
        try await session.useDatabase("tableroad")
        #expect(await session.currentDatabase == "tableroad")
        _ = try await session.execute("USE system")
        #expect(await session.currentDatabase == "system")
        await session.close()
    }

    @Test func keyspaceOnConnectAndPreferFallsBackToPlain() async throws {
        var config = Cass.config
        config.keyspace = "tableroad"
        config.tls = .prefer
        let session = try await CassandraSession.connect(config)
        #expect(await session.currentDatabase == "tableroad")
        #expect(session.isEncrypted == false)
        await session.close()
    }

    @Test func tablesColumnsAndIndexes() async throws {
        let session = try await Cass.connectAndSeed()
        let tables = try await session.tables(in: "tableroad")
        #expect(Set(["all_types", "events", "people", "counters"]).isSubset(of: Set(tables.map(\.name))))
        #expect(tables.allSatisfy { $0.kind == .table })

        let columns = try await session.columns(of: "events", in: "tableroad")
        #expect(columns.map(\.name) == ["tenant", "day", "ts", "id", "level", "message", "tags"])
        #expect(columns.filter(\.isPrimaryKey).map(\.name) == ["tenant", "day", "ts", "id"])
        #expect(columns[2].extra == "clustering key (DESC)")
        #expect(columns.first { $0.name == "tags" }?.type == "set<text>")

        let indexes = try await session.indexes(of: "events", in: "tableroad")
        #expect(indexes.first?.isPrimary == true)
        #expect(indexes.first?.columns == ["tenant", "day", "ts", "id"])
        #expect(indexes.contains { $0.name == "events_level" && $0.columns == ["level"] })
        #expect(try await session.foreignKeys(of: "events", in: "tableroad").isEmpty)
        _ = try await session.tableStatus(of: "events", in: "tableroad")
        await session.close()
    }

    @Test func everyTypeDecodes() async throws {
        let session = try await Cass.connectAndSeed()
        guard
            case .rows(let result) = try await session.execute(
                "SELECT * FROM tableroad.all_types WHERE id IN (1, 2, 3)")
        else {
            Issue.record("No rows")
            return
        }
        let names = result.columns.map(\.name)
        func value(_ id: Int64, _ column: String) -> CellValue? {
            guard let row = result.rows.first(where: { $0[0] == .int(id) }), let index = names.firstIndex(of: column)
            else { return nil }
            return row[index]
        }
        #expect(result.columns.first { $0.name == "a_map" }?.typeName == "map<text, int>")
        #expect(result.columns.first?.table == "all_types")
        #expect(value(1, "a_ascii") == .text("abc"))
        #expect(value(1, "a_bigint") == .int(-9_223_372_036_854_775_807))
        #expect(value(1, "a_blob") == .bytes(Data([0xCA, 0xFE])))
        #expect(value(1, "a_boolean") == .bool(true))
        #expect(value(1, "a_date") == .temporal("2024-02-29"))
        #expect(value(1, "a_decimal") == .decimal("-123.4500"))
        #expect(value(1, "a_double") == .double(3.25))
        #expect(value(1, "a_duration") == .text("1y2mo3d4h5m6s7ms"))
        #expect(value(1, "a_float") == .double(1.1))
        #expect(value(1, "a_inet") == .text("::1"))
        #expect(value(1, "a_int") == .int(-42))
        #expect(value(1, "a_smallint") == .int(-300))
        #expect(value(1, "a_text") == .text("héllo 'quoted'"))
        #expect(value(1, "a_time") == .temporal("12:34:56.789"))
        #expect(value(1, "a_timestamp") == .temporal("2024-01-02 03:04:05.678+0000"))
        #expect(value(1, "a_timeuuid") == .uuid(UUID(uuidString: "50554d6e-29bb-11e5-b345-feff819cdc9f")!))
        #expect(value(1, "a_tinyint") == .int(-7))
        #expect(value(1, "a_uuid") == .uuid(UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!))
        #expect(value(1, "a_varint") == .decimal("123456789012345678901234567890"))
        #expect(value(1, "a_list") == .json("[1,2,3]"))
        #expect(value(1, "a_set") == .json(#"["x","y"]"#))
        #expect(value(1, "a_map") == .json(#"{"k1":1,"k2":2}"#))
        #expect(value(1, "a_tuple") == .json(#"[1,"two"]"#))
        #expect(value(1, "a_udt") == .json(#"{"street":"Main","zip":12345}"#))
        #expect(value(1, "a_frozen_list") == .json("[[1],[2,3]]"))
        #expect(value(1, "a_vector") == .json("[0.5,1.5,2.5]"))
        #expect(value(2, "a_text") == .null)
        #expect(value(2, "a_map") == .null)
        #expect(value(3, "a_varint") == .decimal("-129"))
        #expect(value(3, "a_decimal") == .decimal("0.001"))
        #expect(value(3, "a_inet") == .text("10.0.0.1"))
        #expect(value(3, "a_date") == .temporal("1969-12-31"))

        try await session.run("UPDATE tableroad.counters SET hits = hits + 3 WHERE id = 1")
        guard case .rows(let counters) = try await session.execute("SELECT hits FROM tableroad.counters WHERE id = 1"),
            case .int(let hits) = counters.rows.first?.first
        else {
            Issue.record("No counter")
            return
        }
        #expect(hits >= 3)
        await session.close()
    }

    @Test func pagesWithOffsetAndProtocolPaging() async throws {
        let session = try await Cass.connectAndSeed()
        let dialect = CassandraDialect()
        guard case .rows(let all) = try await session.execute("SELECT * FROM tableroad.events") else { return }
        #expect(all.rows.count >= 25)

        let page = PageQuery(database: "tableroad", table: "events", limit: 10, offset: 10)
        let sql = page.selectSQL(dialect)
        #expect(sql.hasSuffix(" LIMIT 20 ALLOW FILTERING /* tableroad:offset=10 */"))
        guard case .rows(let second) = try await session.execute(sql) else { return }
        #expect(second.rows == Array(all.rows[10..<20]))
        #expect(second.columns.map(\.name) == all.columns.map(\.name))

        // Past the end: an empty page that still has its columns.
        let beyond = PageQuery(database: "tableroad", table: "events", limit: 10, offset: 10_000)
        guard case .rows(let empty) = try await session.execute(beyond.selectSQL(dialect)) else { return }
        #expect(empty.rows.isEmpty)
        #expect(!empty.columns.isEmpty)

        await session.close()
    }

    @Test func largeResultsStreamAcrossProtocolPages() async throws {
        let session = try await Cass.connectAndSeed()
        try await Cass.seedWide(session)
        guard case .rows(let rows) = try await session.execute("SELECT c FROM tableroad.wide WHERE p = 1") else {
            return
        }
        #expect(rows.rows.count == 6000)
        #expect(rows.rows.last == [.int(5999)])
        let page = PageQuery(database: "tableroad", table: "wide", limit: 100, offset: 5950)
        guard case .rows(let tail) = try await session.execute(page.selectSQL(CassandraDialect())) else { return }
        #expect(tail.rows.count == 50)
        #expect(tail.rows.first == [.int(1), .int(5950)])
        await session.close()
    }

    @Test func filtersUseAllowFilteringAndTypedLiterals() async throws {
        let session = try await Cass.connectAndSeed()
        let dialect = CassandraDialect()
        var filters = FilterSet(filters: [ColumnFilter(column: "message", op: .equals, value: "event 7")])
        var query = PageQuery(database: "tableroad", table: "events", filters: filters, limit: 50)
        guard case .rows(let byText) = try await session.execute(query.selectSQL(dialect)) else { return }
        #expect(byText.rows.count == 1)

        // An int column compared with the filter bar's quoted value.
        filters = FilterSet(filters: [
            ColumnFilter(column: "tenant", op: .equals, value: "acme"),
            ColumnFilter(column: "id", op: .greaterThanOrEqual, value: "20"),
        ])
        query = PageQuery(database: "tableroad", table: "events", filters: filters, limit: 50)
        guard case .rows(let byInt) = try await session.execute(query.selectSQL(dialect)) else { return }
        #expect(byInt.rows.count == 5)

        filters = FilterSet(filters: [ColumnFilter(column: "level", op: .isIn, value: "1, 2")])
        query = PageQuery(database: "tableroad", table: "events", filters: filters, limit: 50)
        guard case .rows(let byList) = try await session.execute(query.selectSQL(dialect)) else { return }
        #expect(byList.rows.count == 10)
        guard case .rows(let count) = try await session.execute(query.countSQL(dialect)) else { return }
        #expect(count.rows.first?.first == .int(10))
        await session.close()
    }

    @Test func sortsLocallyWhenTheServerCannot() async throws {
        let session = try await Cass.connectAndSeed()
        let query = PageQuery(
            database: "tableroad", table: "events", sort: [ColumnSort(column: "message", ascending: false)], limit: 3,
            offset: 1)
        guard case .rows(let page) = try await session.execute(query.selectSQL(CassandraDialect())) else { return }
        let index = page.columns.firstIndex { $0.name == "message" }!
        #expect(page.rows.map { $0[index] } == [.text("event 8"), .text("event 7"), .text("event 6")])
        await session.close()
    }

    @Test func editsThroughTableChanges() async throws {
        let session = try await Cass.connectAndSeed()
        try await session.run("DELETE FROM tableroad.people WHERE id = 100")
        let builder = TableChangeBuilder(database: "tableroad", table: "people", dialect: CassandraDialect())
        let insert = RowChange.insert([
            ColumnEdit(column: "id", edit: .text("100")), ColumnEdit(column: "tag", edit: .text("a")),
            ColumnEdit(column: "score", edit: .text("5")), ColumnEdit(column: "prefs", edit: .text(#"{"x": 1}"#)),
            ColumnEdit(column: "seen", edit: .text("2024-01-01 00:00:00.000+0000")),
        ])
        let second = RowChange.insert([
            ColumnEdit(column: "id", edit: .text("100")), ColumnEdit(column: "tag", edit: .text("b")),
            ColumnEdit(column: "score", edit: .null),
        ])
        #expect(
            try await session.executeTransaction([builder.statement(for: insert), builder.statement(for: second)]) == [
                1, 1,
            ])

        let update = RowChange.update(
            key: RowKey([("id", "100"), ("tag", "a")]),
            set: [
                ColumnEdit(column: "score", edit: .text("7")),
                ColumnEdit(column: "prefs", edit: .text(#"{"x": 2, "y": 3}"#)),
            ])
        let delete = RowChange.delete(key: RowKey([("id", "100"), ("tag", "b")]))
        _ = try await session.executeTransaction([builder.statement(for: update), builder.statement(for: delete)])
        guard
            case .rows(let rows) = try await session.execute(
                "SELECT tag, score, prefs, seen FROM tableroad.people WHERE id = 100")
        else { return }
        #expect(
            rows.rows == [
                [.text("a"), .int(7), .json(#"{"x":2,"y":3}"#), .temporal("2024-01-01 00:00:00.000+0000")]
            ])
        #expect(builder.previewSQL(for: update).contains("'7'"))

        // A bad value names the change that failed, and nothing is written.
        let bad = RowChange.update(
            key: RowKey([("id", "100"), ("tag", "a")]), set: [ColumnEdit(column: "score", edit: .text("lots"))])
        await #expect(throws: TransactionError.self) {
            try await session.executeTransaction([builder.statement(for: update), builder.statement(for: bad)])
        }
        do {
            _ = try await session.executeTransaction([builder.statement(for: update), builder.statement(for: bad)])
        } catch let error as TransactionError {
            #expect(error.statementIndex == 1)
        }
        await session.close()
    }

    @Test func exportsWithOffsetPaging() async throws {
        let session = try await Cass.connectAndSeed()
        try await Cass.seedWide(session)
        await session.close()
        let file = FileManager.default.temporaryDirectory.appending(path: "tr-cassandra-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await TableExport.run(
            items: [ExportItem(database: "tableroad", table: "wide")], kind: .csv(CSVOptions()), destination: file,
            connect: { try await CassandraSession.connect(Cass.config) })
        #expect(result.rows == 6000)
    }

    @Test func describesTables() async throws {
        let session = try await Cass.connectAndSeed()
        let ddl = try await session.createStatement(of: "events", in: "tableroad")
        #expect(ddl.contains("CREATE TABLE tableroad.events"))
        #expect(ddl.contains("CREATE INDEX events_level"))
        await session.close()
    }

    @Test func mapsErrors() async throws {
        let session = try await Cass.connectAndSeed()
        do {
            _ = try await session.execute("SELEC nonsense")
            Issue.record("Expected a syntax error")
        } catch let error as DatabaseError {
            #expect(error.category == .query)
            #expect(error.code == 0x2000)
        }
        do {
            _ = try await session.execute("SELECT * FROM tableroad.missing_table")
            Issue.record("Expected an invalid query error")
        } catch let error as DatabaseError {
            #expect(error.category == .query)
            #expect(error.code == 0x2200)
        }
        // The session is still usable after errors.
        #expect(try await session.databases().contains("tableroad"))
        await session.close()

        var wrong = Cass.config
        wrong.password = "wrong"
        await #expect {
            _ = try await CassandraSession.connect(wrong)
        } throws: { ($0 as? DatabaseError)?.category == .authentication }
        wrong.username = ""
        await #expect {
            _ = try await CassandraSession.connect(wrong)
        } throws: { ($0 as? DatabaseError)?.category == .authentication }
        await #expect {
            _ = try await CassandraSession.connect(CassandraConnectConfig(host: "127.0.0.1", port: 1))
        } throws: { ($0 as? DatabaseError)?.category == .connection }
    }

    @Test func createsAndDropsKeyspaces() async throws {
        let session = try await Cass.connectAndSeed()
        let dialect = CassandraDialect()
        let name = "tr_\(UInt32.random(in: 0...UInt32.max))"
        try await session.run(try dialect.createDatabaseSQL(name, characterSet: nil, collation: nil))
        #expect(try await session.databases().contains(name))
        try await session.run(dialect.dropDatabaseSQL(name))
        #expect(try await !session.databases().contains(name))
        await session.close()
    }
}

/// Encoding details that don't need a server.
struct CQLValueTests {
    @Test func varintsAndDecimals() {
        #expect(CQLValues.varintText([0x00]) == "0")
        #expect(CQLValues.varintText([0x7F]) == "127")
        #expect(CQLValues.varintText([0xFF, 0x7F]) == "-129")
        #expect(CQLValues.varintText([0x80]) == "-128")
        #expect(CQLValues.varintText([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) == "18446744073709551616")
        #expect(CQLValues.decimalText(unscaled: "-1234500", scale: 4) == "-123.4500")
        #expect(CQLValues.decimalText(unscaled: "1", scale: 3) == "0.001")
        #expect(CQLValues.decimalText(unscaled: "12", scale: -2) == "1200")
    }

    @Test func datesAndTimes() {
        #expect(CQLValues.dateText(0) == "1970-01-01")
        #expect(CQLValues.dateText(-1) == "1969-12-31")
        #expect(CQLValues.timestampText(-1) == "1969-12-31 23:59:59.999+0000")
        #expect(CQLValues.timeText(3_723_000_000_100) == "01:02:03.0000001")
    }

    @Test func durations() {
        var buffer = ByteBuffer(bytes: [0x02, 0x00, 0x03])  // 1 month, 0 days, -2 ns
        #expect(CQLValues.durationText(&buffer) == "-1mo2ns")
    }

    @Test func literals() throws {
        #expect(try CQLLiteral.render("42", as: .int) == "42")
        #expect(try CQLLiteral.render("it's", as: .varchar) == "'it''s'")
        #expect(throws: DatabaseError.self) { try CQLLiteral.render("x", as: .int) }
        #expect(try CQLLiteral.render(#"{"a": [1, 2]}"#, as: .map(.varchar, .set(.int))) == "{'a': {1, 2}}")
        #expect(try CQLLiteral.render(#"[1, "b"]"#, as: .tuple([.int, .varchar])) == "(1, 'b')")
        #expect(
            try CQLLiteral.render(
                #"{"zip": 1}"#, as: .udt(keyspace: "k", name: "a", fields: [.init(name: "zip", type: .int)]))
                == #"{"zip": 1}"#)
        #expect(try CQLLiteral.render("TRUE", as: .boolean) == "true")
    }

    @Test func dialectConventions() {
        let dialect = CassandraDialect()
        #expect(dialect.quoteIdentifier(#"a"b"#) == #""a""b""#)
        #expect(
            dialect.pagingClause(limit: 10, offset: 0, ordered: false)
                == " LIMIT 10 ALLOW FILTERING /* tableroad:offset=0 */")
        let (cql, offset) = CassandraDialect.extractOffset(
            "SELECT * FROM t LIMIT 30 ALLOW FILTERING /* tableroad:offset=20 */")
        #expect(cql == "SELECT * FROM t LIMIT 30 ALLOW FILTERING")
        #expect(offset == 20)
        #expect(CassandraDialect.extractOffset("SELECT 1").1 == nil)
        #expect(
            CQLScanner.substitute("UPDATE t SET a = ? WHERE b = '?' AND c = ?", ["1", "'x'"])
                == "UPDATE t SET a = 1 WHERE b = '?' AND c = 'x'")
        let filter = ColumnFilter(column: "a", op: .contains, value: "50%")
        #expect(filter.condition(dialect) == #""a" LIKE '%50%%'"#)
    }
}
