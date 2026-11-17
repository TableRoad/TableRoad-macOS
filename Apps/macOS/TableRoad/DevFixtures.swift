#if DEBUG
    import Foundation
    import TableRoadCore
    import TableRoadStorage

    /// Debug-only: launch with `TABLEROAD_DEV_FIXTURES=1` to use the docker/compose.yml databases with an
    /// in-memory secret store and a throwaway connections file (your real connections are untouched).
    /// `TABLEROAD_OPEN=<connection name>` opens that workspace; `TABLEROAD_OPEN_TABLE=<table>` opens a table in it;
    /// `TABLEROAD_RUN_SQL=<script>` puts a script in the first query tab and runs it (`TABLEROAD_RUN_SQL_NOW=0` to
    /// only fill it in).
    enum DevFixtures {
        static let environment = ProcessInfo.processInfo.environment
        static var isEnabled: Bool { environment["TABLEROAD_DEV_FIXTURES"] == "1" }
        static var openConnection: String? { environment["TABLEROAD_OPEN"] }
        static var openTable: String? { environment["TABLEROAD_OPEN_TABLE"] }
        /// SQL to pre-fill and run in the first query tab.
        static var runSQL: String? { environment["TABLEROAD_RUN_SQL"] }

        @MainActor
        static func makeStore() -> ConnectionStore {
            let file = FileManager.default.temporaryDirectory.appending(path: "tableroad-dev-\(UUID()).json")
            let store = ConnectionStore(fileURL: file, secrets: InMemorySecretStore())
            let docker = ConnectionGroup(name: "Docker", icon: .symbol("shippingbox.fill"))
            try? store.save(docker)
            let fixtures: [(String, DatabaseKind, Int, ConnectionTag)] = [
                ("Docker MySQL 8.4", .mysql, 13306, .local),
                ("Docker MariaDB 11", .mariadb, 13307, .development),
                ("Docker PostgreSQL 17", .postgres, 15432, .testing),
            ]
            for (name, kind, port, tag) in fixtures {
                let profile = ConnectionProfile(
                    name: name, kind: kind, host: "127.0.0.1", port: port, username: "tableroad", database: "tableroad",
                    tag: tag, groupID: docker.id)
                try? store.save(profile, password: "tableroad")
            }
            // A sample SQLite file (built with the system sqlite3 tool) for trying the SQLite driver.
            let sqlite = FileManager.default.temporaryDirectory.appending(path: "tableroad-sample.sqlite")
            if !FileManager.default.fileExists(atPath: sqlite.path) {
                let tool = Process()
                tool.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                tool.arguments = [
                    sqlite.path,
                    """
                    CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL, born INTEGER);
                    CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER REFERENCES authors(id),
                        title TEXT NOT NULL, published TEXT, price REAL, notes TEXT);
                    CREATE INDEX books_author ON books(author_id);
                    INSERT INTO authors (name, born) VALUES ('Ursula K. Le Guin', 1929), ('Iain M. Banks', 1954),
                        ('Octavia E. Butler', 1947);
                    INSERT INTO books (author_id, title, published, price, notes) VALUES
                        (1, 'The Dispossessed', '1974-05-01', 9.99, NULL), (1, 'A Wizard of Earthsea', '1968-11-01', 7.5, ''),
                        (2, 'Consider Phlebas', '1987-04-23', 10.99, '{"series": "Culture", "order": 1}'),
                        (3, 'Kindred', '1979-06-01', 8.25, 'Line one
                    Line two');
                    """,
                ]
                try? tool.run()
                tool.waitUntilExit()
            }
            try? store.save(
                ConnectionProfile(name: "Sample SQLite", kind: .sqlite, host: sqlite.path, groupID: docker.id),
                password: nil)
            return store
        }
    }
#endif
