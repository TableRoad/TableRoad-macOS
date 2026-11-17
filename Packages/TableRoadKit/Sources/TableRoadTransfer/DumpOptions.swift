import Foundation
import TableRoadCore
import TableRoadSQL

/// How a whole database is dumped (backups and Sync database). Per-table choices live in `ExportItem`.
public struct DumpOptions: Codable, Sendable, Hashable {
    /// Keeping the dump consistent while other clients write.
    public enum Locking: String, Codable, Sendable, CaseIterable, Identifiable {
        /// One transaction with a consistent snapshot: nothing is blocked; InnoDB/PostgreSQL tables stay consistent.
        case snapshot
        /// LOCK TABLES … READ (MySQL) / LOCK TABLE … IN SHARE MODE (PostgreSQL): consistent for every engine, but
        /// writers wait until the dump finishes.
        case lockTables
        /// Plain reads: fastest, but tables may change while they're dumped.
        case none

        public var id: Self { self }
        public var title: String {
            switch self {
            case .snapshot: "No locks (snapshot)"
            case .lockTables: "Lock tables"
            case .none: "None"
            }
        }
        public var explanation: String {
            switch self {
            case .snapshot:
                "No locks keeps InnoDB and PostgreSQL tables consistent; tables of other engines may change while they are dumped."
            case .lockTables: "Every table stays consistent, but writes wait until the dump has finished."
            case .none: "Tables may change while they are dumped."
            }
        }
    }

    public var locking: Locking
    /// Stored procedures, functions and triggers (MySQL, MariaDB, PostgreSQL; triggers for SQLite).
    public var routinesAndTriggers: Bool
    /// Scheduled events (MySQL and MariaDB).
    public var events: Bool
    public var structure: Bool
    public var data: Bool
    /// DROP TABLE IF EXISTS before each CREATE, so the dump replaces existing tables.
    public var dropTables: Bool
    /// CREATE DATABASE IF NOT EXISTS + USE at the top, so the dump recreates the database by itself.
    public var createDatabase: Bool

    public init(
        locking: Locking = .snapshot, routinesAndTriggers: Bool = true, events: Bool = false, structure: Bool = true,
        data: Bool = true, dropTables: Bool = true, createDatabase: Bool = false
    ) {
        self.locking = locking
        self.routinesAndTriggers = routinesAndTriggers
        self.events = events
        self.structure = structure
        self.data = data
        self.dropTables = dropTables
        self.createDatabase = createDatabase
    }

    public static let standard = DumpOptions()

    // Tolerates files written before a field existed.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DumpOptions()
        locking = try c.decodeIfPresent(Locking.self, forKey: .locking) ?? defaults.locking
        routinesAndTriggers =
            try c.decodeIfPresent(Bool.self, forKey: .routinesAndTriggers) ?? defaults.routinesAndTriggers
        events = try c.decodeIfPresent(Bool.self, forKey: .events) ?? defaults.events
        structure = try c.decodeIfPresent(Bool.self, forKey: .structure) ?? defaults.structure
        data = try c.decodeIfPresent(Bool.self, forKey: .data) ?? defaults.data
        dropTables = try c.decodeIfPresent(Bool.self, forKey: .dropTables) ?? defaults.dropTables
        createDatabase = try c.decodeIfPresent(Bool.self, forKey: .createDatabase) ?? defaults.createDatabase
    }
}

/// Engine-specific parts of a database dump: locking statements and routines, triggers and events.
enum DumpExtras {
    enum Engine { case mysql, postgres, sqlite, other }

    static func engine(_ dialect: any SQLDialect) -> Engine {
        switch dialect.family {
        case .mysql: .mysql
        case .postgres: .postgres
        case .sqlite: .sqlite
        case .clickhouse, .other: .other
        }
    }

    /// Statements that start the dump's consistent view (run on the export's own session).
    static func begin(
        _ locking: DumpOptions.Locking, tables: [(database: String, table: String)], dialect: any SQLDialect
    )
        -> [String]
    {
        switch (engine(dialect), locking) {
        case (.mysql, .snapshot):
            return [
                "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ", "START TRANSACTION WITH CONSISTENT SNAPSHOT",
            ]
        case (.mysql, .lockTables):
            guard !tables.isEmpty else { return [] }
            return [
                "LOCK TABLES "
                    + tables.map { dialect.qualified($0.database, $0.table) + " READ" }.joined(separator: ", ")
            ]
        case (.postgres, .snapshot):
            return ["BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"]
        case (.postgres, .lockTables):
            let lock =
                tables.isEmpty
                ? []
                : [
                    "LOCK TABLE " + tables.map { dialect.qualified($0.database, $0.table) }.joined(separator: ", ")
                        + " IN SHARE MODE"
                ]
            return ["BEGIN ISOLATION LEVEL REPEATABLE READ"] + lock
        case (.sqlite, .snapshot), (.sqlite, .lockTables):
            return ["BEGIN"]
        default:
            return []
        }
    }

    static func end(_ locking: DumpOptions.Locking, dialect: any SQLDialect) -> [String] {
        switch (engine(dialect), locking) {
        case (.mysql, .snapshot): ["COMMIT"]
        case (.mysql, .lockTables): ["UNLOCK TABLES"]
        case (.postgres, .snapshot), (.postgres, .lockTables), (.sqlite, .snapshot), (.sqlite, .lockTables):
            ["COMMIT"]
        default: []
        }
    }

    /// Routines, triggers and events of `database` as dump text (empty if none, or the engine has none).
    static func objects(
        in database: String, options: DumpOptions, session: any SQLClient, format: SQLDumpFormat
    ) async throws -> String {
        let dialect = session.sqlDialect
        var text = ""
        switch engine(dialect) {
        case .mysql:
            // Each needs its own DELIMITER block: bodies contain semicolons.
            func block(_ kind: String, _ name: String, _ create: String) -> String {
                "DROP \(kind) IF EXISTS \(dialect.quoteIdentifier(name));\nDELIMITER ;;\n"
                    + unqualified(strippingDefiner(create), database: database) + " ;;\nDELIMITER ;\n\n"
            }
            let literal = dialect.stringLiteral(database)
            if options.routinesAndTriggers {
                for row in try await rows(
                    "SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(literal) ORDER BY ROUTINE_TYPE, ROUTINE_NAME",
                    session)
                {
                    guard let name = row[0], let type = row[1] else { continue }
                    let show = try await rows(
                        "SHOW CREATE \(type) \(dialect.qualified(database, name))", session)
                    // Column 3 is NULL without the privilege to read the body.
                    guard let create = show.first?[safe: 2] ?? nil else { continue }
                    text += block(type, name, create)
                }
                for row in try await rows(
                    "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(literal) ORDER BY TRIGGER_NAME",
                    session)
                {
                    guard let name = row[0] else { continue }
                    let show = try await rows("SHOW CREATE TRIGGER \(dialect.qualified(database, name))", session)
                    guard let create = show.first?[safe: 2] ?? nil else { continue }
                    text += block("TRIGGER", name, create)
                }
            }
            if options.events {
                for row in try await rows(
                    "SELECT EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(literal) ORDER BY EVENT_NAME",
                    session)
                {
                    guard let name = row[0] else { continue }
                    let show = try await rows("SHOW CREATE EVENT \(dialect.qualified(database, name))", session)
                    guard let create = show.first?[safe: 3] ?? nil else { continue }
                    text += block("EVENT", name, create)
                }
            }
        case .postgres:
            guard options.routinesAndTriggers else { return "" }
            let literal = dialect.stringLiteral(database)
            // Definitions name objects outside the search path with their schema; with the dumped schema on the path
            // they come out unqualified, so they recreate in whichever schema the dump is loaded into.
            try? await session.run("SET search_path TO \(dialect.quoteIdentifier(database))")
            // Catalog functions may be missing on Postgres-compatible servers (CockroachDB): skip, don't fail.
            let functions =
                (try? await rows(
                    """
                    SELECT pg_get_functiondef(p.oid)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = \(literal) AND p.prokind IN ('f', 'p')
                        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
                    ORDER BY p.proname
                    """, session)) ?? []
            for row in functions {
                guard let create = row[0] else { continue }
                // pg_get_functiondef always qualifies the function's own name: unqualify it on the CREATE line.
                var lines = create.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if let header = lines.first {
                    lines[0] = header.replacingOccurrences(of: dialect.quoteIdentifier(database) + ".", with: "")
                        .replacingOccurrences(of: " \(database).", with: " ")
                }
                text += lines.joined(separator: "\n") + ";\n\n"
            }
            let triggers =
                (try? await rows(
                    """
                    SELECT pg_get_triggerdef(t.oid, true)::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = \(literal) AND NOT t.tgisinternal ORDER BY t.tgname
                    """, session)) ?? []
            for row in triggers { if let create = row[0] { text += create + ";\n\n" } }
        case .sqlite:
            guard options.routinesAndTriggers else { return "" }
            for row in try await rows(
                "SELECT sql FROM \(dialect.quoteIdentifier(database)).sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL ORDER BY name",
                session)
            {
                if let create = row[0] { text += create + ";\n\n" }
            }
        case .other:
            return ""
        }
        guard !text.isEmpty else { return "" }
        return format.comment("Routines, triggers and events") + text
    }

    /// Removes `database.` / `` `database`. `` qualifiers (MySQL view, trigger and routine definitions name their
    /// own database), so a dump recreates them in whichever database it's loaded into.
    static func unqualified(_ sql: String, database: String) -> String {
        let quoted = "`" + database.replacingOccurrences(of: "`", with: "``") + "`"
        var result = sql.replacingOccurrences(of: quoted + ".", with: "")
        // Unquoted only when the name is a plain identifier, and not as the tail of a longer name.
        if database.range(of: #"^[A-Za-z0-9_$]+$"#, options: .regularExpression) != nil {
            result = result.replacingOccurrences(
                of: #"(?<![A-Za-z0-9_$`.])"# + database + #"\.(?=[A-Za-z_`$])"#, with: "", options: .regularExpression)
        }
        return result
    }

    /// `DEFINER=user@host` usually names an account the target server lacks.
    static func strippingDefiner(_ create: String) -> String {
        create.replacingOccurrences(
            of: #"DEFINER=(`[^`]*`|'[^']*'|\S+)@(`[^`]*`|'[^']*'|\S+)\s+"#, with: "", options: .regularExpression)
    }

    private static func rows(_ sql: String, _ session: any SQLClient) async throws -> [[String?]] {
        guard case .rows(let result) = try await session.execute(sql) else { return [] }
        return result.rows.map { $0.map(\.displayText) }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
