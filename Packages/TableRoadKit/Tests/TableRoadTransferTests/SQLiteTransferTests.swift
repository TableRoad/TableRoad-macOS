import Foundation
import TableRoadCore
import TableRoadSQL
import TableRoadSQLite
import Testing

@testable import TableRoadTransfer

/// Export and import against SQLite files (no server needed).
struct SQLiteTransferTests {
    func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tr-sqlite-\(UUID().uuidString)-\(name)")
    }

    @Test func sqlDumpRoundTripBetweenFiles() async throws {
        let source = temp("source.sqlite")
        let setup = try await SQLiteSession.open(path: source.path, create: true)
        try await setup.run(
            """
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, photo BLOB, score REAL);
            CREATE VIEW high AS SELECT * FROM people WHERE score > 5;
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 4500)
            INSERT INTO people (name, photo, score) SELECT 'p''' || i, x'00FF', i / 10.0 FROM n;
            """)
        let dump = temp("dump.sql")
        let connectSource: @Sendable () async throws -> any SQLClient = {
            try await SQLiteSession.open(path: source.path)
        }
        let result = try await TableExport.run(
            items: [
                ExportItem(database: "main", table: "people"),
                ExportItem(database: "main", table: "high", isView: true, data: false),
            ], kind: .sql(gzip: true), destination: dump, connect: connectSource)
        #expect(result.rows == 4500)

        let target = temp("target.sqlite")
        _ = try await SQLiteSession.open(path: target.path, create: true)
        let imported = try await SQLDumpImport.run(
            file: dump, database: nil, stopOnError: true,
            connect: { try await SQLiteSession.open(path: target.path) })
        #expect(imported.failures.isEmpty, "\(imported.failures.first?.message ?? "")")

        let check = try await SQLiteSession.open(path: target.path)
        guard case .rows(let rows) = try await check.execute("SELECT count(*), sum(score), max(name) FROM people"),
            case .rows(let original) = try await setup.execute("SELECT count(*), sum(score), max(name) FROM people")
        else {
            Issue.record("expected rows")
            return
        }
        #expect(rows.rows == original.rows)
        #expect(try await check.tables(in: "main").map(\.name) == ["high", "people"])
    }

    @Test func csvFromSQLite() async throws {
        let file = temp("db.sqlite")
        let setup = try await SQLiteSession.open(path: file.path, create: true)
        try await setup.run("CREATE TABLE t (a TEXT, b INTEGER); INSERT INTO t VALUES ('x,y', 1), (NULL, 2);")
        let csv = temp("t.csv")
        _ = try await TableExport.run(
            items: [ExportItem(database: "main", table: "t")], kind: .csv(CSVOptions()), destination: csv,
            connect: { try await SQLiteSession.open(path: file.path) })
        #expect(try String(contentsOf: csv, encoding: .utf8) == "a,b\n\"x,y\",1\n,2\n")
    }
}
