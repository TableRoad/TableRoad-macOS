import Foundation
import TableRoadCore
import TableRoadSQL
import TableRoadTransfer
import Testing

@testable import TableRoadOracle

@Suite(
    .enabled(if: OracleTestServer.available, "Start the oracle service in docker/compose.yml"), .serialized,
    .timeLimit(.minutes(2)))
struct OracleSessionTests {
    func session() async throws -> OracleSession {
        let session = try await OracleSession.connect(OracleTestServer.config)
        try await OracleTestServer.prepare(session)
        return session
    }

    func rows(_ session: OracleSession, _ sql: String) async throws -> ResultSet {
        guard case .rows(let result) = try await session.execute(sql) else {
            Issue.record("expected rows for \(sql)")
            return .empty
        }
        return result
    }

    @Test func connectsAndReportsSession() async throws {
        let session = try await OracleSession.connect(OracleTestServer.config)
        #expect(await session.serverVersion.hasPrefix("23."))
        #expect(await session.currentDatabase == "TABLEROAD")
        #expect(session.processID != 0)
        #expect(session.capabilities.databaseNoun == "schema")
        await session.close()
    }

    @Test func everyType() async throws {
        let session = try await session()
        let result = try await rows(session, "SELECT * FROM tr_types ORDER BY id")
        #expect(
            result.columns.map(\.typeName) == [
                "NUMBER", "NUMBER", "NUMBER", "NUMBER", "NUMBER", "FLOAT", "BINARY_FLOAT", "BINARY_DOUBLE", "VARCHAR2",
                "NVARCHAR2", "CHAR", "NCHAR", "DATE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE",
                "TIMESTAMP WITH LOCAL TIME ZONE", "INTERVAL YEAR TO MONTH", "INTERVAL DAY TO SECOND", "RAW", "CLOB",
                "NCLOB", "BLOB", "BOOLEAN",
            ])
        #expect(result.rows.count == 2)
        let row = result.rows[0]
        func value(_ name: String) -> CellValue? {
            result.columns.firstIndex { $0.name == name }.map { row[$0] }
        }
        #expect(value("ID") == .int(1))
        #expect(value("NUM_INT") == .int(-42))
        #expect(value("NUM_DEC") == .decimal("12345.6789"))
        #expect(value("NUM_ANY") == .decimal("0.000123"))
        #expect(value("NUM_FLOAT") == .decimal("1.5"))
        #expect(value("BF") == .double(1.5))
        #expect(value("BD") == .double(-2.25))
        #expect(value("VC") == .text("héllo ☃"))
        #expect(value("NVC") == .text("ünï ☃"))
        #expect(value("CH") == .text("ab   "))
        #expect(value("NCH") == .text("xy   "))
        #expect(value("DT") == .temporal("2024-02-29 13:14:15"))
        #expect(value("TS") == .temporal("2024-02-29 13:14:15.123456"))
        #expect(value("TSTZ") == .temporal("2024-02-29 13:14:15.5 +05:30"))
        #expect(value("TSLTZ") == .temporal("2024-02-29 13:14:15"))
        #expect(value("IYM") == .temporal("+1-02"))
        #expect(value("IDS") == .temporal("+3 04:05:06.789"))
        #expect(value("RW") == .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(value("CL") == .text("clob text ☃"))
        #expect(value("NCL") == .text("nclob ☃"))
        #expect(value("BL") == .bytes(Data([0x00, 0xFF, 0x10])))
        #expect(value("FLAG") == .bool(true))
        // The second row is all NULL apart from its key.
        #expect(result.rows[1].dropFirst().allSatisfy { $0 == .null })
        await session.close()
    }

    @Test func expressionsAndSpecialValues() async throws {
        let session = try await session()
        let result = try await rows(
            session,
            """
            SELECT NULL AS n, 0 AS zero, -1 AS minus_one, 1e125 AS huge, -0.5 AS half, 123456789012345678901234567890 AS big,
                   ROWID AS rid, CAST('x' AS VARCHAR2(10)) AS v, BINARY_DOUBLE_INFINITY AS inf, FALSE AS f
            FROM tr_types WHERE id = 1
            """)
        let row = try #require(result.rows.first)
        #expect(row[0] == .null)
        #expect(row[1] == .int(0))
        #expect(row[2] == .int(-1))
        #expect(row[3] == .decimal("1" + String(repeating: "0", count: 125)))
        #expect(row[4] == .decimal("-0.5"))
        #expect(row[5] == .decimal("123456789012345678901234567890"))
        #expect(row[6].displayText?.count == 18)
        #expect(row[7] == .text("x"))
        #expect(row[8] == .double(.infinity))
        #expect(row[9] == .bool(false))
        await session.close()
    }

    @Test func largeResultsSpanSeveralFetches() async throws {
        for disableEndOfResponse in [false, true] {
            let session = try await OracleSession.connect(
                OracleTestServer.config, disableEndOfResponse: disableEndOfResponse)
            try await OracleTestServer.prepare(session)
            let result = try await rows(session, "SELECT id, label FROM tr_big ORDER BY id")
            #expect(result.rows.count == 1000)
            #expect(result.rows.last == [.int(1000), .text("row 1000")])
            #expect(result.rows.map { $0[0] } == (1...1000).map { .int(Int64($0)) })

            // A LOB far larger than a packet, read inline.
            _ = try await session.execute(
                """
                DECLARE c CLOB; BEGIN
                  FOR i IN 1..4000 LOOP c := c || RPAD(TO_CHAR(i), 50, '.'); END LOOP;
                  UPDATE tr_types SET cl = c WHERE id = 2;
                END;
                """)
            let lob = try await rows(session, "SELECT cl, id FROM tr_types ORDER BY id")
            #expect(lob.rows.count == 2)
            #expect(lob.rows[1][0].displayText?.count == 200_000)
            #expect(lob.rows[1][0].displayText?.hasPrefix("1....") == true)
            let long = try await rows(session, "SELECT body FROM tr_long")
            #expect(long.rows.first?.first == .text("long text"))
            await session.close()
        }
    }

    @Test func pagingAndFilters() async throws {
        let session = try await session()
        let dialect = OracleDialect()
        let query = PageQuery(
            database: "TABLEROAD", table: "TR_BIG", sort: [ColumnSort(column: "ID", ascending: false)], limit: 10,
            offset: 20)
        let page = try await rows(session, query.selectSQL(dialect))
        #expect(page.rows.count == 10)
        #expect(page.rows.first?.first == .int(980))
        var filtered = PageQuery(database: "TABLEROAD", table: "TR_BIG", limit: 5)
        filtered.filters = FilterSet(filters: [ColumnFilter(column: "LABEL", op: .contains, value: "row 99")])
        let matches = try await rows(session, filtered.selectSQL(dialect))
        #expect(matches.rows.count == 5)
        let count = try await rows(session, filtered.countSQL(dialect))
        #expect(count.rows.first?.first == .int(11))
        await session.close()
    }

    @Test func editsThroughTableChanges() async throws {
        let session = try await session()
        let builder = TableChangeBuilder(database: "TABLEROAD", table: "TR_TYPES", dialect: OracleDialect())
        let affected = try await session.executeTransaction([
            builder.statement(
                for: .update(
                    key: RowKey([("ID", "1")]),
                    set: [
                        .init(column: "VC", edit: .text("it's :1 edited")),
                        .init(column: "NUM_DEC", edit: .text("7.25")),
                        .init(column: "DT", edit: .text("2025-01-02 03:04:05")),
                        .init(column: "TS", edit: .text("2025-01-02 03:04:05.5")), .init(column: "NVC", edit: .null),
                    ])),
            builder.statement(
                for: .insert([.init(column: "ID", edit: .text("3")), .init(column: "VC", edit: .text("new"))])),
            builder.statement(for: .delete(key: RowKey([("ID", "2")]))),
        ])
        #expect(affected == [1, 1, 1])
        let result = try await rows(session, "SELECT id, vc, num_dec, dt, ts, nvc FROM tr_types ORDER BY id")
        #expect(result.rows.map { $0[0] } == [.int(1), .int(3)])
        #expect(result.rows[0][1] == .text("it's :1 edited"))
        #expect(result.rows[0][2] == .decimal("7.25"))
        #expect(result.rows[0][3] == .temporal("2025-01-02 03:04:05"))
        #expect(result.rows[0][4] == .temporal("2025-01-02 03:04:05.5"))
        #expect(result.rows[0][5] == .null)

        // A failing statement rolls the whole transaction back.
        await #expect(throws: TransactionError.self) {
            try await session.executeTransaction([
                builder.statement(
                    for: .update(key: RowKey([("ID", "1")]), set: [.init(column: "VC", edit: .text("x"))])),
                builder.statement(for: .insert([.init(column: "ID", edit: .text("1"))])),
            ])
        }
        let after = try await rows(session, "SELECT vc FROM tr_types WHERE id = 1")
        #expect(after.rows.first?.first == .text("it's :1 edited"))
        await session.close()
    }

    @Test func catalog() async throws {
        let session = try await session()
        #expect(try await session.databases().contains("TABLEROAD"))
        let tables = try await session.tables(in: "TABLEROAD")
        #expect(tables.contains { $0.name == "TR_TYPES" && $0.kind == .table })
        #expect(tables.contains { $0.name == "TR_TYPES_VIEW" && $0.kind == .view })

        let columns = try await session.columns(of: "TR_TYPES", in: "TABLEROAD")
        #expect(columns.count == 23)
        #expect(columns.first?.isPrimaryKey == true)
        #expect(columns.first { $0.name == "VC" }?.type == "VARCHAR2(100 CHAR)")
        #expect(columns.first { $0.name == "VC" }?.comment == "Some text")
        #expect(columns.first { $0.name == "NUM_DEC" }?.type == "NUMBER(12,4)")
        #expect(columns.first { $0.name == "NUM_INT" }?.type == "NUMBER(10)")
        #expect(columns.first { $0.name == "RW" }?.type == "RAW(16)")
        #expect(columns.first { $0.name == "TS" }?.type == "TIMESTAMP(6)")

        let indexes = try await session.indexes(of: "TR_TYPES", in: "TABLEROAD")
        #expect(indexes.first?.isPrimary == true)
        #expect(indexes.contains { $0.name == "TR_TYPES_AUTHOR_IX" && $0.columns == ["AUTHOR_ID"] })

        let keys = try await session.foreignKeys(of: "TR_TYPES", in: "TABLEROAD")
        #expect(keys.count == 1)
        #expect(keys.first?.referencedTable == "TR_AUTHORS")
        #expect(keys.first?.referencedColumns == ["ID"])
        #expect(keys.first?.onDelete == "CASCADE")

        let ddl = try await session.createStatement(of: "TR_TYPES", in: "TABLEROAD")
        #expect(ddl.contains("CREATE TABLE"))
        let viewDDL = try await session.createStatement(of: "TR_TYPES_VIEW", in: "TABLEROAD")
        #expect(viewDDL.contains("VIEW"))

        let status = try await session.tableStatus(of: "TR_BIG", in: "TABLEROAD")
        #expect(status.comment == nil)
        #expect((status.dataBytes ?? 0) > 0)
        let typesStatus = try await session.tableStatus(of: "TR_TYPES", in: "TABLEROAD")
        #expect(typesStatus.comment == "Every type")
        #expect(try await session.tableSizes(in: "TABLEROAD")["TR_BIG"] ?? 0 > 0)

        try await session.useDatabase("TABLEROAD")
        #expect(await session.currentDatabase == "TABLEROAD")
        await session.close()
    }

    @Test func ddlAndRowCounts() async throws {
        let session = try await session()
        #expect(
            try await session.execute("CREATE TABLE tr_ddl (id NUMBER, name VARCHAR2(10));") == .affected(rowCount: 0))
        #expect(
            try await session.execute("INSERT INTO tr_ddl SELECT id, label FROM tr_big WHERE id <= 37")
                == .affected(rowCount: 37))
        #expect(try await session.execute("UPDATE tr_ddl SET name = 'x' WHERE id > 30") == .affected(rowCount: 7))
        #expect(try await session.execute("DELETE FROM tr_ddl") == .affected(rowCount: 37))
        #expect(try await session.execute("DROP TABLE tr_ddl PURGE") == .affected(rowCount: 0))
        await session.close()
    }

    @Test func errorsMapToDatabaseError() async throws {
        let session = try await session()
        do {
            _ = try await session.execute("SELECT * FROM no_such_table")
            Issue.record("expected an error")
        } catch let error as DatabaseError {
            #expect(error.code == 942)
            #expect(error.category == .query)
            #expect(error.message.hasPrefix("ORA-00942"))
        }
        await #expect(throws: DatabaseError.self) { try await session.execute("SELEC 1 FROM dual") }
        await #expect(throws: DatabaseError.self) {
            try await session.execute("INSERT INTO tr_authors VALUES (1, 'dup')")
        }
        // Still usable after errors.
        #expect(try await rows(session, "SELECT 1 FROM dual").rows == [[.int(1)]])

        do {
            _ = try await OracleSession.connect(
                OracleConnectConfig(
                    host: "127.0.0.1", port: OracleTestServer.port, username: "tableroad", password: "wrong",
                    serviceName: "FREEPDB1"))
            Issue.record("expected a login failure")
        } catch let error as DatabaseError {
            #expect(error.category == .authentication)
            #expect(error.code == 1017)
        }
        do {
            _ = try await OracleSession.connect(
                OracleConnectConfig(
                    host: "127.0.0.1", port: OracleTestServer.port, username: "tableroad", password: "tableroad",
                    serviceName: "NOPE"))
            Issue.record("expected a listener refusal")
        } catch let error as DatabaseError {
            #expect(error.code == 12514)
        }
        await session.close()
    }

    @Test func plsqlScriptsAndCommit() async throws {
        let session = try await session()
        try await session.run(
            """
            CREATE OR REPLACE PROCEDURE tr_add_author(p_id NUMBER, p_name VARCHAR2) AS
            BEGIN
              INSERT INTO tr_authors VALUES (p_id, p_name);
            END;
            /
            BEGIN tr_add_author(10, 'Butler'); END;
            /
            INSERT INTO tr_authors VALUES (11, 'Jemisin');
            """)
        // Autocommit: another session sees the rows.
        let other = try await OracleSession.connect(OracleTestServer.config)
        let result = try await rows(other, "SELECT name FROM tr_authors WHERE id >= 10 ORDER BY id")
        #expect(result.rows == [[.text("Butler")], [.text("Jemisin")]])
        _ = try await session.execute("DROP PROCEDURE tr_add_author")
        await other.close()
        await session.close()
    }

    /// Waits without Task.sleep (a plain dispatch timer).
    func pause(_ seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    @Test func cancelsARunningStatement() async throws {
        let session = try await OracleSession.connect(OracleTestServer.config)
        let task = Task {
            try await session.execute("SELECT COUNT(*) FROM all_objects a, all_objects b, all_objects c")
        }
        await pause(1)
        try await session.cancelCurrentQuery()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let error as DatabaseError {
            #expect(error.category == .cancelled)
            #expect(error.code == 1013)
        }
        #expect(try await rows(session, "SELECT 2 FROM dual").rows == [[.int(2)]])

        // A call that can't be interrupted finishes normally; the late break must not hit the next statement.
        let sleeper = Task { try await session.execute("BEGIN DBMS_SESSION.SLEEP(1.5); END;") }
        await pause(0.5)
        try await session.cancelCurrentQuery()
        _ = try? await sleeper.value
        #expect(try await rows(session, "SELECT 3 FROM dual").rows == [[.int(3)]])
        await session.close()
    }

    @Test func processListNeedsPrivileges() async throws {
        let user = try await OracleSession.connect(OracleTestServer.config)
        #expect(user.capabilities.processList == false)
        await user.close()
        let admin = try await OracleSession.connect(OracleTestServer.systemConfig)
        #expect(admin.capabilities.processList)
        let processes = try await admin.processList()
        #expect(processes.contains { $0.id == admin.processID })
        await admin.close()
    }

    @Test func exportsThroughTheDialect() async throws {
        let session = try await session()
        let file = FileManager.default.temporaryDirectory.appending(path: "tr-oracle-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await TableExport.run(
            items: [ExportItem(database: "TABLEROAD", table: "TR_BIG")], kind: .csv(CSVOptions()), destination: file,
            connect: OracleTestServer.connect)
        #expect(result.rows == 1000)
        await session.close()
    }
}
