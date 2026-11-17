import Darwin
import Foundation
import TableRoadCore
import TableRoadSQL
import TableRoadTransfer
import Testing

@testable import TableRoadPostgres

/// CockroachDB speaks the PostgreSQL protocol; docker/compose.yml runs an insecure single node on 26257.
enum CRDB {
    static let config = PostgresConnectConfig(
        host: "127.0.0.1", port: 26257, username: "root", password: nil, database: "defaultdb", tls: .disable,
        kind: .cockroach)

    @Sendable static func connect() async throws -> any SQLClient { try await PostgresSession.connect(config) }

    static let available: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(26257).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }()
}

@Suite(.enabled(if: CRDB.available, "Start the cockroach service in docker/compose.yml"), .serialized)
struct CockroachTests {
    @Test func browseEditAndExport() async throws {
        let session = try await PostgresSession.connect(CRDB.config)
        #expect(await session.kind == .cockroach)
        let schema = "tr_\(UInt32.random(in: 0...UInt32.max))"
        try await session.run(PostgresDialect().createDatabaseSQL(schema, characterSet: nil, collation: nil))
        do {
            try await session.run(
                """
                CREATE TABLE \(schema).authors (id INT8 PRIMARY KEY DEFAULT unique_rowid(), name STRING NOT NULL);
                CREATE TABLE \(schema).books (id INT8 PRIMARY KEY, author_id INT8 REFERENCES \(schema).authors(id),
                    title STRING, price DECIMAL(8,2), tags STRING[]);
                CREATE INDEX books_author ON \(schema).books(author_id);
                INSERT INTO \(schema).authors (id, name) VALUES (1, 'Le Guin'), (2, 'Banks');
                INSERT INTO \(schema).books VALUES (10, 1, 'The Dispossessed', 9.99, ARRAY['sf']),
                    (11, 2, 'Excession', 8.50, NULL)
                """)
            #expect(try await session.databases().contains(schema))
            #expect(try await session.tables(in: schema).map(\.name) == ["authors", "books"])
            let columns = try await session.columns(of: "books", in: schema)
            #expect(columns.map(\.name) == ["id", "author_id", "title", "price", "tags"])
            #expect(columns.first?.isPrimaryKey == true)
            #expect(try await session.indexes(of: "books", in: schema).contains { $0.columns == ["author_id"] })
            #expect(try await session.foreignKeys(of: "books", in: schema).first?.referencedTable == "authors")
            _ = try await session.tableStatus(of: "books", in: schema)
            _ = try await session.createStatement(of: "books", in: schema)

            let query = PageQuery(database: schema, table: "books", sort: [ColumnSort(column: "price")], limit: 1)
            guard case .rows(let page) = try await session.execute(query.selectSQL(PostgresDialect())) else { return }
            #expect(page.rows.first?[3] == .decimal("8.50"))

            let builder = TableChangeBuilder(database: schema, table: "books", dialect: PostgresDialect())
            let affected = try await session.executeTransaction([
                builder.statement(
                    for: .update(key: RowKey([("id", "10")]), set: [.init(column: "price", edit: .text("10"))]))
            ])
            #expect(affected == [1])

            let file = FileManager.default.temporaryDirectory.appending(path: "tr-crdb-\(UUID()).csv")
            let result = try await TableExport.run(
                items: [ExportItem(database: schema, table: "books")], kind: .csv(CSVOptions()), destination: file,
                connect: CRDB.connect)
            #expect(result.rows == 2)
            _ = try await session.processList()
        } catch {
            Issue.record(error)
        }
        try await session.run(PostgresDialect().dropDatabaseSQL(schema))
    }
}
