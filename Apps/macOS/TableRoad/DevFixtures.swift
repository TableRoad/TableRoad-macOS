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
            let fixtures: [(String, DatabaseKind, Int, ConnectionTag)] = [
                ("Docker MySQL 8.4", .mysql, 13306, .local),
                ("Docker MariaDB 11", .mariadb, 13307, .development),
            ]
            for (name, kind, port, tag) in fixtures {
                let profile = ConnectionProfile(
                    name: name, kind: kind, host: "127.0.0.1", port: port, username: "tableroad", database: "tableroad",
                    tag: tag)
                try? store.save(profile, password: "tableroad")
            }
            return store
        }
    }
#endif
