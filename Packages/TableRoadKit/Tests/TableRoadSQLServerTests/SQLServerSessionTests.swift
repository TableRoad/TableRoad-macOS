import Darwin
import Foundation
import TableRoadCore
import TableRoadSQL
import Testing

@testable import TableRoadSQLServer

/// The SQL Server container from docker/compose.yml (sa / TableRoad!2026 on port 11433).
enum MSSQL {
    static let port = 11433
    static func config(
        database: String? = "tableroad", tls: TLSMode = .prefer, password: String = "TableRoad!2026",
        bootstrap: String? = nil
    ) -> SQLServerConnectConfig {
        SQLServerConnectConfig(
            host: "127.0.0.1", port: port, username: "sa", password: password, database: database, tls: tls,
            bootstrapSQL: bootstrap)
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

    /// Creates the `tableroad` database and a `shop` schema with sample tables (idempotent).
    static func seed() async throws {
        let master = try await SQLServerSession.connect(config(database: "master"))
        _ = try await master.execute("IF DB_ID('tableroad') IS NULL CREATE DATABASE tableroad")
        await master.close()
        let session = try await SQLServerSession.connect(config())
        defer { Task { await session.close() } }
        for statement in [
            "IF OBJECT_ID('shop.orders') IS NOT NULL DROP TABLE shop.orders",
            "IF OBJECT_ID('shop.customer_names') IS NOT NULL DROP VIEW shop.customer_names",
            "IF OBJECT_ID('shop.customers') IS NOT NULL DROP TABLE shop.customers",
            "IF OBJECT_ID('shop.types') IS NOT NULL DROP TABLE shop.types",
            "IF SCHEMA_ID('shop') IS NULL EXEC('CREATE SCHEMA shop')",
            """
            CREATE TABLE shop.customers (
                id INT IDENTITY(1,1) CONSTRAINT pk_customers PRIMARY KEY,
                email NVARCHAR(200) NOT NULL CONSTRAINT uq_customers_email UNIQUE,
                name NVARCHAR(100) NULL,
                active BIT NOT NULL DEFAULT 1
            )
            """,
            """
            CREATE TABLE shop.orders (
                id BIGINT IDENTITY(1,1) PRIMARY KEY,
                customer_id INT NOT NULL CONSTRAINT fk_orders_customer REFERENCES shop.customers(id) ON DELETE CASCADE,
                total DECIMAL(12,2) NOT NULL,
                placed_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
            )
            """,
            "CREATE INDEX ix_orders_placed ON shop.orders (placed_at)",
            "CREATE VIEW shop.customer_names AS SELECT id, name FROM shop.customers",
            """
            CREATE TABLE shop.types (
                id INT PRIMARY KEY, t_tinyint TINYINT, t_smallint SMALLINT, t_bigint BIGINT, t_bit BIT,
                t_decimal DECIMAL(38,6), t_numeric NUMERIC(5,0), t_money MONEY, t_smallmoney SMALLMONEY,
                t_real REAL, t_float FLOAT, t_date DATE, t_time TIME(7), t_datetime DATETIME,
                t_smalldatetime SMALLDATETIME, t_datetime2 DATETIME2(7), t_dto DATETIMEOFFSET(3),
                t_char CHAR(5), t_varchar VARCHAR(50), t_varchar_max VARCHAR(MAX), t_nchar NCHAR(3),
                t_nvarchar NVARCHAR(50), t_nvarchar_max NVARCHAR(MAX), t_binary BINARY(3), t_varbinary VARBINARY(10),
                t_varbinary_max VARBINARY(MAX), t_guid UNIQUEIDENTIFIER, t_xml XML, t_text TEXT, t_ntext NTEXT,
                t_image IMAGE, t_variant SQL_VARIANT
            )
            """,
            """
            INSERT INTO shop.types VALUES (1, 255, -32768, 9223372036854775807, 1,
                -12345678901234567890.123456, 99999, 922337203685477.5807, -214748.3648,
                1.5, 2.25, '2026-11-17', '13:45:30.1234567', '2026-11-17 13:45:30.997',
                '2026-11-17 13:45', '0001-01-01 00:00:00.0000001', '2026-11-17 23:30:00.123 +05:30',
                'ab', 'café', REPLICATE(CAST('x' AS VARCHAR(MAX)), 9000), N'日本', N'Zoë 🚀',
                REPLICATE(CAST(N'é' AS NVARCHAR(MAX)), 5000), 0x0A0B0C, 0x00FF, 0xDEADBEEF,
                '6F9619FF-8B86-D011-B42D-00C04FC964FF', '<a b="1">x</a>', 'old text', N'old ntext',
                0x01020304, CAST(42 AS INT))
            """,
            "INSERT INTO shop.types (id) VALUES (2)",
        ] {
            _ = try await session.execute(statement)
        }
        var values: [String] = []
        for index in 1...25 { values.append("(N'user\(index)@example.com', N'User \(index)', \(index % 2))") }
        _ = try await session.execute(
            "INSERT INTO shop.customers (email, name, active) VALUES " + values.joined(separator: ", "))
        _ = try await session.execute(
            "INSERT INTO shop.orders (customer_id, total) SELECT id, id * 10.5 FROM shop.customers")
    }
}

@Suite(.enabled(if: MSSQL.available, "Start the SQL Server container (docker/compose.yml) to run these"), .serialized)
struct SQLServerSessionTests {
    init() async throws {
        try await MSSQL.seed()
    }

    @Test func connectsOverTLSAndReportsServer() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        #expect(session.isEncrypted)
        #expect(await session.serverVersion.hasPrefix("16."))
        #expect(session.processID > 0)
        #expect(await session.currentDatabase == "dbo")
    }

    @Test func connectsWithoutTLSWhenTheServerAllowsIt() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config(tls: .disable))
        defer { Task { await session.close() } }
        #expect(!session.isEncrypted)
        guard case .rows(let result) = try await session.execute("SELECT 1 AS one") else {
            Issue.record("no rows")
            return
        }
        #expect(result.rows == [[.int(1)]])
    }

    @Test func wrongPasswordIsAnAuthenticationError() async throws {
        do {
            _ = try await SQLServerSession.connect(MSSQL.config(password: "nope"))
            Issue.record("expected a login failure")
        } catch let error as DatabaseError {
            #expect(error.category == .authentication)
            #expect(error.code == 18456)
        }
    }

    @Test func decodesEveryType() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        guard case .rows(let result) = try await session.execute("SELECT * FROM shop.types ORDER BY id") else {
            Issue.record("no rows")
            return
        }
        let row = Dictionary(uniqueKeysWithValues: zip(result.columns.map(\.name), result.rows[0]))
        #expect(row["t_tinyint"] == .int(255))
        #expect(row["t_smallint"] == .int(-32768))
        #expect(row["t_bigint"] == .int(9_223_372_036_854_775_807))
        #expect(row["t_bit"] == .bool(true))
        #expect(row["t_decimal"] == .decimal("-12345678901234567890.123456"))
        #expect(row["t_numeric"] == .decimal("99999"))
        #expect(row["t_money"] == .decimal("922337203685477.5807"))
        #expect(row["t_smallmoney"] == .decimal("-214748.3648"))
        #expect(row["t_real"] == .double(1.5))
        #expect(row["t_float"] == .double(2.25))
        #expect(row["t_date"] == .temporal("2026-11-17"))
        #expect(row["t_time"] == .temporal("13:45:30.1234567"))
        #expect(row["t_datetime"] == .temporal("2026-11-17 13:45:30.997"))
        #expect(row["t_smalldatetime"] == .temporal("2026-11-17 13:45:00"))
        #expect(row["t_datetime2"] == .temporal("0001-01-01 00:00:00.0000001"))
        #expect(row["t_dto"] == .temporal("2026-11-17 23:30:00.123 +05:30"))
        #expect(row["t_char"] == .text("ab   "))
        #expect(row["t_varchar"] == .text("café"))
        #expect(row["t_varchar_max"]?.displayText?.count == 9000)
        #expect(row["t_nchar"] == .text("日本 "))
        #expect(row["t_nvarchar"] == .text("Zoë 🚀"))
        #expect(row["t_nvarchar_max"]?.displayText?.count == 5000)
        #expect(row["t_binary"] == .bytes(Data([0x0A, 0x0B, 0x0C])))
        #expect(row["t_varbinary"] == .bytes(Data([0x00, 0xFF])))
        #expect(row["t_varbinary_max"] == .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(row["t_guid"] == .uuid(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!))
        #expect(row["t_xml"] == .text("<a b=\"1\">x</a>"))
        #expect(row["t_text"] == .text("old text"))
        #expect(row["t_ntext"] == .text("old ntext"))
        #expect(row["t_image"] == .bytes(Data([1, 2, 3, 4])))
        #expect(row["t_variant"] == .int(42))
        #expect(result.columns.first { $0.name == "t_nvarchar" }?.typeName == "nvarchar(50)")
        // The second row is all NULLs.
        #expect(result.rows[1].dropFirst().allSatisfy { $0 == .null })
    }

    @Test func pagesWithOffsetFetch() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        let query = PageQuery(database: "shop", table: "customers", limit: 10, offset: 20)
        guard case .rows(let page) = try await session.execute(query.selectSQL(SQLServerDialect())) else {
            Issue.record("no rows")
            return
        }
        #expect(page.rows.count == 5)
        var sorted = query
        sorted.sort = [ColumnSort(column: "id", ascending: false)]
        sorted.offset = 0
        sorted.limit = 2
        guard case .rows(let top) = try await session.execute(sorted.selectSQL(SQLServerDialect())) else { return }
        #expect(top.rows.map { $0[0] } == [.int(25), .int(24)])
        guard case .rows(let count) = try await session.execute(query.countSQL(SQLServerDialect())) else { return }
        #expect(count.rows == [[.int(25)]])
    }

    @Test func filtersUseLikeOnAnyColumn() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        let filters = FilterSet(filters: [ColumnFilter(column: "id", op: .contains, value: "1")])
        let query = PageQuery(database: "shop", table: "customers", filters: filters)
        guard case .rows(let result) = try await session.execute(query.selectSQL(SQLServerDialect())) else { return }
        #expect(result.rows.count == 12)  // 1, 10–19, 21
    }

    @Test func errorsCarryTheServerMessage() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        do {
            _ = try await session.execute("SELECT * FROM shop.missing")
            Issue.record("expected an error")
        } catch let error as DatabaseError {
            #expect(error.category == .query)
            #expect(error.code == 208)
            #expect(error.message.contains("missing"))
        }
        // The session still works afterwards.
        guard case .rows(let result) = try await session.execute("SELECT N'ok'") else { return }
        #expect(result.rows == [[.text("ok")]])
    }

    @Test func affectedRowCounts() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        let outcome = try await session.execute("UPDATE shop.customers SET name = name WHERE id <= 3")
        #expect(outcome == .affected(rowCount: 3))
    }

    @Test func cancelStopsALongQuery() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        let started = Date.now
        let running = Task { try await session.execute("WAITFOR DELAY '00:00:20'; SELECT 1") }
        try await Task.sleep(for: .milliseconds(500))
        try await session.cancelCurrentQuery()
        do {
            _ = try await running.value
            Issue.record("expected cancellation")
        } catch let error as DatabaseError {
            #expect(error.category == .cancelled)
        }
        #expect(Date.now.timeIntervalSince(started) < 10)
        guard case .rows(let result) = try await session.execute("SELECT 2") else { return }
        #expect(result.rows == [[.int(2)]])
    }

    @Test func editsRunInATransaction() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        let builder = TableChangeBuilder(database: "shop", table: "customers", dialect: SQLServerDialect())
        let changes: [RowChange] = [
            .update(key: RowKey([("id", "1")]), set: [ColumnEdit(column: "name", edit: .text("Renamed O'Neil"))]),
            .insert([
                ColumnEdit(column: "email", edit: .text("new@example.com")), ColumnEdit(column: "name", edit: .null),
            ]),
            .delete(key: RowKey([("id", "2")])),
        ]
        let counts = try await session.executeTransaction(changes.map(builder.statement))
        #expect(counts == [1, 1, 1])
        guard case .rows(let renamed) = try await session.execute("SELECT name FROM shop.customers WHERE id = 1") else {
            return
        }
        #expect(renamed.rows == [[.text("Renamed O'Neil")]])

        // A failing statement rolls everything back.
        let failing: [RowChange] = [
            .update(key: RowKey([("id", "3")]), set: [ColumnEdit(column: "name", edit: .text("Should roll back"))]),
            .insert([ColumnEdit(column: "email", edit: .text("new@example.com"))]),  // duplicate email
        ]
        do {
            _ = try await session.executeTransaction(failing.map(builder.statement))
            Issue.record("expected a failure")
        } catch let error as TransactionError {
            #expect(error.statementIndex == 1)
        }
        guard case .rows(let kept) = try await session.execute("SELECT name FROM shop.customers WHERE id = 3") else {
            return
        }
        #expect(kept.rows == [[.text("User 3")]])
    }

    @Test func catalog() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        let schemas = try await session.databases()
        #expect(schemas.first == "dbo")
        #expect(schemas.contains("shop"))
        let tables = try await session.tables(in: "shop")
        #expect(tables.map(\.name) == ["customer_names", "customers", "orders", "types"])
        #expect(tables.first { $0.name == "customer_names" }?.kind == .view)
        #expect(tables.first { $0.name == "customers" }?.estimatedRowCount == 25)

        let columns = try await session.columns(of: "customers", in: "shop")
        #expect(columns.map(\.name) == ["id", "email", "name", "active"])
        #expect(columns[0].isPrimaryKey && columns[0].extra == "IDENTITY(1,1)")
        #expect(columns[1].type == "nvarchar(200)" && !columns[1].isNullable)
        #expect(columns[3].defaultValue == "1")

        let indexes = try await session.indexes(of: "customers", in: "shop")
        #expect(indexes.map(\.name) == ["pk_customers", "uq_customers_email"])
        #expect(indexes[1].isUnique)

        let keys = try await session.foreignKeys(of: "orders", in: "shop")
        #expect(keys.count == 1)
        #expect(keys[0].referencedDatabase == "shop" && keys[0].referencedTable == "customers")
        #expect(keys[0].onDelete == "CASCADE")

        let status = try await session.tableStatus(of: "customers", in: "shop")
        #expect(status.estimatedRows == 25)
        #expect((status.dataBytes ?? 0) > 0)
        #expect(try await session.tableSizes(in: "shop")["orders"] ?? 0 > 0)

        let ddl = try await session.createStatement(of: "orders", in: "shop")
        #expect(ddl.hasPrefix("CREATE TABLE [shop].[orders] ("))
        #expect(ddl.contains("[id] bigint IDENTITY(1,1) NOT NULL"))
        #expect(ddl.contains("REFERENCES [shop].[customers] ([id]) ON DELETE CASCADE"))
        #expect(ddl.contains("CREATE NONCLUSTERED INDEX [ix_orders_placed]"))
        let view = try await session.createStatement(of: "customer_names", in: "shop")
        #expect(view.hasPrefix("CREATE VIEW shop.customer_names"))
    }

    @Test func recreatesATableFromItsDDL() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        let ddl = try await session.createStatement(of: "customers", in: "shop")
        _ = try await session.execute("IF SCHEMA_ID('copy') IS NULL EXEC('CREATE SCHEMA copy')")
        _ = try await session.execute("IF OBJECT_ID('copy.customers') IS NOT NULL DROP TABLE copy.customers")
        let copy = ddl.replacingOccurrences(of: "[shop].[customers]", with: "[copy].[customers]")
            .replacingOccurrences(of: "pk_customers", with: "pk_copy").replacingOccurrences(
                of: "uq_customers_email", with: "uq_copy_email")
        for statement in StatementSplitter(syntax: .sqlserver).split(copy) {
            _ = try await session.execute(statement.text)
        }
        #expect(
            try await session.columns(of: "customers", in: "copy").map(\.name) == ["id", "email", "name", "active"])
        _ = try await session.execute("DROP TABLE copy.customers; DROP SCHEMA copy")
    }

    @Test func processListIncludesThisSession() async throws {
        let session = try await SQLServerSession.connect(MSSQL.config())
        defer { Task { await session.close() } }
        let processes = try await session.processList()
        #expect(processes.contains { $0.id == session.processID })
    }

    @Test func bootstrapStatementsRunAfterLogin() async throws {
        let session = try await SQLServerSession.connect(
            MSSQL.config(bootstrap: "SET LANGUAGE British\nGO\nSET DATEFORMAT dmy"))
        defer { Task { await session.close() } }
        guard case .rows(let result) = try await session.execute("SELECT @@LANGUAGE") else { return }
        #expect(result.rows == [[.text("British")]])
    }
}

struct SQLServerUnitTests {
    @Test func decimalsKeepEveryDigit() {
        // 1 = positive, then 123456789 little-endian.
        #expect(TDSTokenParser.decimal([1, 0x15, 0xCD, 0x5B, 0x07], scale: 4) == "12345.6789")
        #expect(TDSTokenParser.decimal([0, 5, 0, 0, 0], scale: 2) == "-0.05")
        #expect(TDSTokenParser.decimal([1, 0, 0, 0, 0], scale: 0) == "0")
    }

    @Test func datesFromDayNumbers() {
        #expect(TDSTokenParser.date(days: 0) == "0001-01-01")
        #expect(TDSTokenParser.date(days: 693_595) == "1900-01-01")
        #expect(TDSTokenParser.date(days: 739_571) == "2025-11-17")
    }

    @Test func defaultsLoseTheirParentheses() {
        #expect(SQLServerSession.unwrapDefault("((0))") == "0")
        #expect(SQLServerSession.unwrapDefault("(getdate())") == "getdate()")
        #expect(SQLServerSession.unwrapDefault("((1)+(2))") == "(1)+(2)")
    }

    @Test func splitterHandlesGoAndBrackets() {
        let script = "SELECT [a;b] FROM t;\nGO\nCREATE PROCEDURE p AS SELECT 1\ngo  \nSELECT 2 -- go\n"
        let statements = StatementSplitter(syntax: .sqlserver).split(script).map(\.text)
        #expect(statements == ["SELECT [a;b] FROM t", "CREATE PROCEDURE p AS SELECT 1", "SELECT 2 -- go"])
    }

    @Test func dialectPagesAndQuotes() {
        let dialect = SQLServerDialect()
        #expect(dialect.quoteIdentifier("a]b") == "[a]]b]")
        #expect(dialect.stringLiteral("O'Neil") == "N'O''Neil'")
        #expect(
            PageQuery(database: "dbo", table: "t", limit: 5, offset: 10).selectSQL(dialect)
                == "SELECT * FROM [dbo].[t] ORDER BY (SELECT NULL) OFFSET 10 ROWS FETCH NEXT 5 ROWS ONLY")
    }
}
