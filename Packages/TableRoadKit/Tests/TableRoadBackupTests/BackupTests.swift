import Darwin
import Foundation
import TableRoadCore
import TableRoadMySQL
import TableRoadPostgres
import TableRoadSQL
import TableRoadTransfer
import Testing

@testable import TableRoadBackup

// MARK: - Schedule timing

struct ScheduleRepeatTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    @Test func dailyRunsLaterTodayOrTomorrow() {
        let daily = ScheduleRepeat.daily(hour: 2, minute: 0)
        #expect(daily.nextRun(after: date("2026-11-17 01:30"), calendar: calendar) == date("2026-11-17 02:00"))
        #expect(daily.nextRun(after: date("2026-11-17 02:00"), calendar: calendar) == date("2026-11-18 02:00"))
    }

    @Test func hourlyAndWeekly() {
        #expect(
            ScheduleRepeat.hourly(minute: 15).nextRun(after: date("2026-11-17 10:20"), calendar: calendar)
                == date("2026-11-17 11:15"))
        // 2026-11-17 is a Tuesday; weekday 2 is Monday.
        #expect(
            ScheduleRepeat.weekly(weekday: 2, hour: 9, minute: 30).nextRun(
                after: date("2026-11-17 10:00"), calendar: calendar) == date("2026-11-23 09:30"))
        #expect(ScheduleRepeat.manual.nextRun(after: .now) == nil)
    }

    @Test func launchdIntervalsUseZeroBasedWeekdays() {
        #expect(
            ScheduleRepeat.weekly(weekday: 1, hour: 3, minute: 5).calendarInterval == [
                "Weekday": 0, "Hour": 3, "Minute": 5,
            ])
        #expect(ScheduleRepeat.daily(hour: 2, minute: 0).calendarInterval == ["Hour": 2, "Minute": 0])
    }

    @Test func problemsExplainIncompleteSchedules() {
        let id = UUID()
        var schedule = BackupSchedule()
        #expect(schedule.problem != nil)
        schedule.source = .connection(id: id, databases: [DatabaseSelection(name: "shop")])
        schedule.target = .folder(path: "/tmp", keepLast: nil)
        #expect(schedule.problem == nil)
        schedule.target = .connection(id: id, database: "shop")
        #expect(schedule.problem == "A database can't be synced into itself.")
        schedule.target = .connection(id: id, database: "shop_copy")
        #expect(schedule.problem == nil)
        schedule.source = .files(["/tmp/a.sql"])
        schedule.target = .folder(path: "/tmp", keepLast: nil)
        #expect(schedule.problem == "Files can only be restored into a connection.")
    }

    @Test func historyKeepsFailuresInARow() {
        var schedule = BackupSchedule()
        schedule.record(BackupRun(status: .succeeded))
        schedule.record(BackupRun(status: .failed))
        schedule.record(BackupRun(status: .failed))
        #expect(schedule.recentFailures == 2)
        for _ in 0..<60 { schedule.record(BackupRun(status: .succeeded)) }
        #expect(schedule.history.count == BackupSchedule.historyLimit)
    }
}

// MARK: - Files and scripts

struct BackupFileTests {
    @Test func pruneKeepsNewestBackupsOfThatDatabaseOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tr-prune-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = [
            "shop_2026-11-01_02-00-00.sql.gz", "shop_2026-11-02_02-00-00.sql.gz", "shop_2026-11-03_02-00-00.sql.gz",
            "shop_archive_2026-11-01_02-00-00.sql.gz", "shop_notes.sql.gz", "other_2026-11-01_02-00-00.sql.gz",
        ]
        for name in names { FileManager.default.createFile(atPath: folder.appending(path: name).path, contents: nil) }
        let log = RunLog(url: folder.appending(path: "log.txt"))
        BackupRunner.prune(folder: folder, database: "shop", keep: 2, log: log)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(!left.contains("shop_2026-11-01_02-00-00.sql.gz"))
        #expect(left.isSuperset(of: names.filter { $0 != "shop_2026-11-01_02-00-00.sql.gz" }))
    }

    @Test func scriptsGetEnvironmentAndFailOnErrors() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tr-script-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let logURL = folder.appending(path: "run.log")
        let log = RunLog(url: logURL)
        try await ScriptRunner.run(
            "echo \"name=$TR_SCHEDULE_NAME\"; pwd", environment: ["TR_SCHEDULE_NAME": "Nightly"], timeout: 10, log: log)
        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.contains("name=Nightly"))
        #expect(text.contains(FileManager.default.homeDirectoryForCurrentUser.path))

        await #expect(throws: BackupError.self) {
            try await ScriptRunner.run("echo oops >&2; exit 3", environment: [:], timeout: 10, log: log)
        }
        // A #! line picks the interpreter.
        try await ScriptRunner.run("#!/bin/zsh\necho $ZSH_NAME", environment: [:], timeout: 10, log: log)
        #expect(try String(contentsOf: logURL, encoding: .utf8).contains("zsh"))
    }

    @Test func scriptsStopAtTheTimeout() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tr-timeout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = RunLog(url: folder.appending(path: "run.log"))
        let started = Date.now
        do {
            try await ScriptRunner.run("sleep 30", environment: [:], timeout: 1, log: log)
            Issue.record("expected a timeout")
        } catch let error as BackupError {
            #expect(error.message.contains("within 1 seconds"))
        }
        #expect(Date.now.timeIntervalSince(started) < 10)
    }
}

// MARK: - Integration (docker/compose.yml)

func reachable(_ port: Int) -> Bool {
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
}

/// Root on the MySQL / MariaDB containers (backups create databases).
enum Servers {
    static let mysql = UUID()
    static let mariadb = UUID()
    static let postgres = UUID()

    static func context(logs: URL) -> BackupContext {
        BackupContext(
            connect: { id in
                switch id {
                case postgres:
                    try await PostgresSession.connect(
                        PostgresConnectConfig(
                            host: "127.0.0.1", port: 15432, username: "tableroad", password: "tableroad",
                            database: "tableroad"))
                default:
                    try await MySQLSession.connect(
                        MySQLConnectConfig(
                            host: "127.0.0.1", port: id == mysql ? 13306 : 13307, username: "root",
                            password: "tableroad", database: nil, tls: .prefer))
                }
            },
            connectionName: { id in id == mysql ? "MySQL" : id == mariadb ? "MariaDB" : "PostgreSQL" },
            syntax: { id in id == postgres ? .postgres : .mysql },
            logDirectory: logs)
    }

    static func rows(_ sql: String, on id: UUID, context: BackupContext) async throws -> [[String?]] {
        let session = try await context.connect(id)
        defer { Task { await session.close() } }
        guard case .rows(let result) = try await session.execute(sql) else { return [] }
        return result.rows.map { $0.map(\.displayText) }
    }

    static func run(_ statements: [String], on id: UUID, context: BackupContext) async throws {
        let session = try await context.connect(id)
        defer { Task { await session.close() } }
        for statement in statements { try await session.run(statement) }
    }
}

@Suite(
    .enabled(if: reachable(13306) && reachable(13307), "Start docker/compose.yml to run backup integration tests"),
    .serialized)
struct MySQLBackupTests {
    static let servers = [Servers.mysql, Servers.mariadb]

    func makeSource(_ server: UUID, _ context: BackupContext) async throws {
        try await Servers.run(
            [
                "DROP DATABASE IF EXISTS tr_backup_src", "DROP DATABASE IF EXISTS tr_backup_restore",
                "DROP DATABASE IF EXISTS tr_backup_sync", "CREATE DATABASE tr_backup_src",
                "CREATE TABLE tr_backup_src.authors (id INT PRIMARY KEY, name VARCHAR(50))",
                "CREATE TABLE tr_backup_src.books (id INT AUTO_INCREMENT PRIMARY KEY, author_id INT, title VARCHAR(80), FOREIGN KEY (author_id) REFERENCES tr_backup_src.authors(id))",
                "CREATE TABLE tr_backup_src.audit (id INT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(80))",
                "INSERT INTO tr_backup_src.authors VALUES (1, 'Le Guin'), (2, 'O''Brien')",
                "INSERT INTO tr_backup_src.books (author_id, title) VALUES (1, 'The Dispossessed'), (2, 'Semi; colon')",
                "CREATE VIEW tr_backup_src.titles AS SELECT title FROM tr_backup_src.books",
                """
                CREATE TRIGGER tr_backup_src.books_audit AFTER INSERT ON tr_backup_src.books FOR EACH ROW
                BEGIN INSERT INTO audit (note) VALUES (CONCAT('added ', NEW.title)); END
                """,
                """
                CREATE PROCEDURE tr_backup_src.book_count(OUT total INT)
                BEGIN SELECT COUNT(*) INTO total FROM books; END
                """,
            ], on: server, context: context)
    }

    @Test(arguments: servers)
    func backupToFolderThenRestore(server: UUID) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tr-backup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = Servers.context(logs: folder.appending(path: "logs"))
        try await makeSource(server, context)

        var schedule = BackupSchedule(name: "Nightly")
        schedule.source = .connection(id: server, databases: [DatabaseSelection(name: "tr_backup_src")])
        schedule.target = .folder(path: folder.appending(path: "out").path, keepLast: 3)
        schedule.scripts.after = "echo \"status=$TR_STATUS files=$TR_BACKUP_FILES\""
        let run = await BackupRunner.run(schedule, context: context)
        #expect(run.status == .succeeded, "\(run.message)")
        #expect(run.files.count == 1)
        let file = try #require(run.files.first)
        #expect(file.hasSuffix(".sql.gz") && file.contains("tr_backup_src_"))
        let log = try String(contentsOfFile: try #require(run.logFile), encoding: .utf8)
        #expect(log.contains("status=succeeded files=\(file)"))

        var restore = BackupSchedule(name: "Restore")
        restore.source = .files([file])
        restore.target = .connection(id: server, database: "tr_backup_restore")
        let restored = await BackupRunner.run(restore, context: context)
        #expect(restored.status == .succeeded, "\(restored.message)")
        #expect(
            try await Servers.rows("SELECT COUNT(*) FROM tr_backup_restore.books", on: server, context: context) == [
                ["2"]
            ])
        #expect(
            try await Servers.rows(
                "SELECT name FROM tr_backup_restore.authors WHERE id = 2", on: server, context: context)
                == [["O'Brien"]])
        // The trigger and procedure came along (and work).
        try await Servers.run(
            ["INSERT INTO tr_backup_restore.books (author_id, title) VALUES (1, 'Lathe')"], on: server, context: context
        )
        #expect(
            try await Servers.rows(
                "SELECT note FROM tr_backup_restore.audit ORDER BY id DESC LIMIT 1", on: server, context: context)
                == [["added Lathe"]])
        #expect(
            try await Servers.rows(
                "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'tr_backup_restore'",
                on: server, context: context) == [["1"]])
    }

    @Test(arguments: servers)
    func syncIntoAnotherDatabaseWithSelectedTables(server: UUID) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tr-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = Servers.context(logs: folder)
        try await makeSource(server, context)

        var options = DumpOptions(locking: .lockTables, routinesAndTriggers: false)
        options.dropTables = true
        var schedule = BackupSchedule(name: "Sync")
        schedule.source = .connection(
            id: server,
            databases: [
                DatabaseSelection(name: "tr_backup_src", tables: ["authors", "books", "gone"], options: options)
            ])
        schedule.target = .connection(id: server, database: "tr_backup_sync")
        let run = await BackupRunner.run(schedule, context: context)
        #expect(run.status == .succeeded, "\(run.message)")
        let tables = try await Servers.rows(
            "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'tr_backup_sync' ORDER BY 1",
            on: server, context: context)
        #expect(tables == [["authors"], ["books"]])
        #expect(
            try await Servers.rows(
                "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = 'tr_backup_sync'", on: server,
                context: context) == [["0"]])
        let log = try String(contentsOfFile: try #require(run.logFile), encoding: .utf8)
        #expect(log.contains("Skipped tr_backup_src.gone"))

        // Running again replaces the copy rather than failing on existing tables.
        let again = await BackupRunner.run(schedule, context: context)
        #expect(again.status == .succeeded, "\(again.message)")
        #expect(
            try await Servers.rows("SELECT COUNT(*) FROM tr_backup_sync.books", on: server, context: context) == [["2"]]
        )
    }

    @Test func syncRefusesDifferentKindsOfServer() async throws {
        guard reachable(15432) else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "tr-mixed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = Servers.context(logs: folder)
        try await makeSource(Servers.mysql, context)
        var schedule = BackupSchedule(name: "Mixed")
        schedule.source = .connection(id: Servers.mysql, databases: [DatabaseSelection(name: "tr_backup_src")])
        schedule.target = .connection(id: Servers.postgres, database: "copy")
        let run = await BackupRunner.run(schedule, context: context)
        #expect(run.status == .failed)
        #expect(run.message.contains("different kind of server"))
    }

    @Test func failingBeforeScriptStopsTheRun() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tr-before-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = Servers.context(logs: folder)
        var schedule = BackupSchedule(name: "Guarded")
        schedule.source = .connection(id: Servers.mysql, databases: [DatabaseSelection(name: "tableroad")])
        schedule.target = .folder(path: folder.appending(path: "out").path, keepLast: nil)
        schedule.scripts.before = "exit 1"
        let run = await BackupRunner.run(schedule, context: context)
        #expect(run.status == .failed)
        #expect(run.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "out").path))
    }
}

@Suite(.enabled(if: reachable(15432), "Start docker/compose.yml to run PostgreSQL backup tests"), .serialized)
struct PostgresBackupTests {
    @Test func syncSchemaWithFunctionsAndTriggers() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tr-pgsync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = Servers.context(logs: folder)
        let pg = Servers.postgres
        try await Servers.run(
            [
                "DROP SCHEMA IF EXISTS tr_pg_src CASCADE", "DROP SCHEMA IF EXISTS tr_pg_copy CASCADE",
                "CREATE SCHEMA tr_pg_src",
                "CREATE TABLE tr_pg_src.items (id serial PRIMARY KEY, name text, touched int DEFAULT 0)",
                "INSERT INTO tr_pg_src.items (name) VALUES ('a'), ('b; c')",
                """
                CREATE FUNCTION tr_pg_src.touch() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN NEW.touched := NEW.touched + 1; RETURN NEW; END; $$
                """,
                "CREATE TRIGGER items_touch BEFORE UPDATE ON tr_pg_src.items FOR EACH ROW EXECUTE FUNCTION tr_pg_src.touch()",
            ], on: pg, context: context)

        var schedule = BackupSchedule(name: "PG sync")
        schedule.source = .connection(id: pg, databases: [DatabaseSelection(name: "tr_pg_src")])
        schedule.target = .connection(id: pg, database: "tr_pg_copy")
        let run = await BackupRunner.run(schedule, context: context)
        #expect(run.status == .succeeded, "\(run.message)")
        #expect(
            try await Servers.rows("SELECT count(*)::text FROM tr_pg_copy.items", on: pg, context: context) == [["2"]])
        // Inserting continues the copied sequence instead of colliding with copied ids.
        try await Servers.run(["INSERT INTO tr_pg_copy.items (name) VALUES ('d')"], on: pg, context: context)
        #expect(
            try await Servers.rows("SELECT max(id)::text FROM tr_pg_copy.items", on: pg, context: context) == [["3"]])
        let triggers = try await Servers.rows(
            """
            SELECT count(*)::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'tr_pg_copy' AND NOT t.tgisinternal
            """, on: pg, context: context)
        #expect(triggers == [["1"]])
        try await Servers.run(
            ["DROP SCHEMA tr_pg_src CASCADE", "DROP SCHEMA tr_pg_copy CASCADE"], on: pg, context: context)
    }
}
