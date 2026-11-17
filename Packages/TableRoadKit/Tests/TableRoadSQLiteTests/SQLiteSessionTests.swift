import Foundation
import TableRoadCore
import TableRoadSQL
import Testing

@testable import TableRoadSQLite

struct SQLiteSessionTests {
    func makeDatabase() async throws -> (SQLiteSession, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "tr-\(UUID()).sqlite")
        let session = try await SQLiteSession.open(path: url.path, create: true)
        try await session.run(
            """
            CREATE TABLE customers (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, name TEXT);
            CREATE TABLE orders (
                id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
                total REAL, note TEXT DEFAULT 'none', data BLOB, doubled REAL GENERATED ALWAYS AS (total * 2));
            CREATE INDEX orders_customer ON orders(customer_id);
            CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 100;
            INSERT INTO customers (email, name) VALUES ('a@x.com', 'Ann'), ('b@x.com', NULL);
            INSERT INTO orders (customer_id, total, data) VALUES (1, 150.5, x'DEADBEEF'), (2, 20, NULL);
            """)
        return (session, url)
    }

    @Test func openingMissingOrNonSQLiteFilesFails() async throws {
        await #expect(throws: DatabaseError.self) {
            try await SQLiteSession.open(path: "/tmp/does-not-exist-\(UUID())")
        }
        let junk = FileManager.default.temporaryDirectory.appending(path: "tr-junk-\(UUID()).sqlite")
        try Data("not a database at all, just text that is long enough".utf8).write(to: junk)
        await #expect(throws: DatabaseError.self) { try await SQLiteSession.open(path: junk.path) }
    }

    @Test func queryTypesAndAffectedRows() async throws {
        let (session, _) = try await makeDatabase()
        guard
            case .rows(let result) = try await session.execute(
                "SELECT id, total, data, note, doubled FROM orders ORDER BY id")
        else {
            Issue.record("expected rows")
            return
        }
        #expect(result.columns.map(\.name) == ["id", "total", "data", "note", "doubled"])
        #expect(result.rows[0][0] == .int(1))
        #expect(result.rows[0][1] == .double(150.5))
        #expect(result.rows[0][2] == .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(result.rows[0][3] == .text("none"))
        #expect(result.rows[1][2] == .null)
        guard case .affected(let count) = try await session.execute("UPDATE orders SET note = 'x'") else {
            Issue.record("expected affected")
            return
        }
        #expect(count == 2)
        await #expect(throws: DatabaseError.self) { try await session.execute("SELECT * FROM missing") }
    }

    @Test func introspection() async throws {
        let (session, _) = try await makeDatabase()
        #expect(try await session.databases() == ["main"])
        let tables = try await session.tables(in: "main")
        #expect(tables.map(\.name) == ["big_orders", "customers", "orders"])
        #expect(tables.first?.kind == .view)
        let columns = try await session.columns(of: "orders", in: "main")
        #expect(columns.map(\.name) == ["id", "customer_id", "total", "note", "data", "doubled"])
        #expect(columns[0].isPrimaryKey)
        #expect(columns[3].defaultValue == "'none'")
        #expect(columns[5].extra == "VIRTUAL GENERATED")
        let indexes = try await session.indexes(of: "orders", in: "main")
        #expect(indexes.map(\.name) == ["PRIMARY", "orders_customer"])
        #expect(
            try await session.indexes(of: "customers", in: "main").contains { $0.isUnique && $0.columns == ["email"] })
        let keys = try await session.foreignKeys(of: "orders", in: "main")
        #expect(keys.first?.referencedTable == "customers")
        #expect(keys.first?.onDelete == "CASCADE")
        #expect(try await session.createStatement(of: "orders", in: "main").hasPrefix("CREATE TABLE orders"))
    }

    @Test func editingThroughTableChangeBuilder() async throws {
        let (session, _) = try await makeDatabase()
        let builder = TableChangeBuilder(database: "main", table: "customers", dialect: SQLiteDialect())
        let key = RowKey([("id", "2")])
        let changes: [RowChange] = [
            .update(key: key, set: [ColumnEdit(column: "name", edit: .text("Bea"))]),
            .insert([ColumnEdit(column: "email", edit: .text("c@x.com"))]),
        ]
        #expect(!builder.statement(for: changes[0]).sql.contains("LIMIT"))
        let affected = try await session.executeTransaction(changes.map(builder.statement))
        #expect(affected == [1, 1])

        // A failing change rolls back the whole batch.
        await #expect(throws: TransactionError.self) {
            try await session.executeTransaction([
                builder.statement(for: .update(key: key, set: [ColumnEdit(column: "name", edit: .text("Zed"))])),
                builder.statement(for: .insert([ColumnEdit(column: "email", edit: .text("a@x.com"))])),
            ])
        }
        guard case .rows(let result) = try await session.execute("SELECT name FROM customers WHERE id = 2") else {
            return
        }
        #expect(result.rows.first?.first == .text("Bea"))
    }

    @Test func pagingAndFilters() async throws {
        let (session, _) = try await makeDatabase()
        let query = PageQuery(
            database: "main", table: "orders", sort: [ColumnSort(column: "total", ascending: false)],
            filters: FilterSet(filters: [ColumnFilter(column: "note", op: .contains, value: "on")]), limit: 1)
        guard case .rows(let page) = try await session.execute(query.selectSQL(SQLiteDialect())) else { return }
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.first == .int(1))
        guard case .rows(let count) = try await session.execute(query.countSQL(SQLiteDialect())) else { return }
        #expect(count.rows.first?.first == .int(2))
    }

    @Test func interruptCancelsALongQuery() async throws {
        let session = try await SQLiteSession.open(path: ":memory:", create: true)
        let task = Task {
            try await session.execute(
                "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n")
        }
        try await Task.sleep(for: .milliseconds(200))
        try await session.cancelCurrentQuery()
        await #expect {
            _ = try await task.value
        } throws: { error in
            (error as? DatabaseError)?.category == .cancelled
        }
    }
}
