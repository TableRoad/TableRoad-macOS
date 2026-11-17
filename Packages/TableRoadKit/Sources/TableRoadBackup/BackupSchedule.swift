import Foundation
import TableRoadTransfer

/// A backup or database sync that runs on a schedule (or on demand): what to dump, where it goes, and the scripts
/// around it. Stored as JSON by `BackupStore`.
public struct BackupSchedule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Disabled schedules only run when started by hand.
    public var isEnabled: Bool
    public var repeats: ScheduleRepeat
    /// Post a notification when a run succeeds (failures always notify).
    public var notifyOnSuccess: Bool
    /// Open TableRoad in the background when a run is due and the app isn't running (login agent).
    public var launchWhenClosed: Bool
    public var source: BackupSource
    public var target: BackupTarget
    public var scripts: BackupScripts
    /// Most recent first, capped at `historyLimit`.
    public var history: [BackupRun]
    /// When the schedule should next run (nil for manual schedules). Kept so missed runs happen on launch.
    public var nextRunAt: Date?
    public var modifiedAt: Date

    public static let historyLimit = 50

    public init(
        id: UUID = UUID(), name: String = "Untitled Schedule", isEnabled: Bool = true,
        repeats: ScheduleRepeat = .daily(hour: 2, minute: 0), notifyOnSuccess: Bool = false,
        launchWhenClosed: Bool = false, source: BackupSource = .none, target: BackupTarget = .none,
        scripts: BackupScripts = BackupScripts(), history: [BackupRun] = [], nextRunAt: Date? = nil,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.repeats = repeats
        self.notifyOnSuccess = notifyOnSuccess
        self.launchWhenClosed = launchWhenClosed
        self.source = source
        self.target = target
        self.scripts = scripts
        self.history = history
        self.nextRunAt = nextRunAt
        self.modifiedAt = modifiedAt
    }

    /// Why the schedule can't run yet, or nil when it's complete.
    public var problem: String? {
        switch (source, target) {
        case (.none, _): return "Choose what to back up."
        case (_, .none): return "Choose where the backup goes."
        case (.connection(_, let databases), _) where databases.isEmpty: return "Choose at least one database."
        case (.files(let paths), _) where paths.isEmpty: return "Choose at least one file."
        case (.files, .folder), (.folder, .folder): return "Files can only be restored into a connection."
        case (.connection(let from, let databases), .connection(let to, let database)):
            if from == to && (database == nil || databases.contains { $0.name == database }) {
                return "A database can't be synced into itself."
            }
            if database != nil && databases.count > 1 {
                return "Several databases can only sync into databases of the same names."
            }
            return nil
        case (.files, .connection(_, nil)), (.folder, .connection(_, nil)):
            return "Choose the database to restore into."
        default:
            return nil
        }
    }

    /// Recomputes `nextRunAt` from `date` (after saving or running).
    public mutating func reschedule(after date: Date = .now, calendar: Calendar = .current) {
        nextRunAt = isEnabled ? repeats.nextRun(after: date, calendar: calendar) : nil
    }

    public mutating func record(_ run: BackupRun) {
        history.removeAll { $0.id == run.id }
        history.insert(run, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    /// Failures in a row since the last success (shown as a warning badge on the schedule).
    public var recentFailures: Int {
        history.prefix { $0.status == .failed }.count
    }

    // Tolerates files written before a field existed.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Schedule"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        repeats = try c.decodeIfPresent(ScheduleRepeat.self, forKey: .repeats) ?? .manual
        notifyOnSuccess = try c.decodeIfPresent(Bool.self, forKey: .notifyOnSuccess) ?? false
        launchWhenClosed = try c.decodeIfPresent(Bool.self, forKey: .launchWhenClosed) ?? false
        source = try c.decodeIfPresent(BackupSource.self, forKey: .source) ?? .none
        target = try c.decodeIfPresent(BackupTarget.self, forKey: .target) ?? .none
        scripts = try c.decodeIfPresent(BackupScripts.self, forKey: .scripts) ?? BackupScripts()
        history = try c.decodeIfPresent([BackupRun].self, forKey: .history) ?? []
        nextRunAt = try c.decodeIfPresent(Date.self, forKey: .nextRunAt)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .now
    }
}

/// When a schedule runs. Times are local wall-clock times.
public enum ScheduleRepeat: Codable, Sendable, Hashable {
    /// Only when started by hand (Run Now, Sync Now).
    case manual
    case hourly(minute: Int)
    case daily(hour: Int, minute: Int)
    /// `weekday` uses Calendar numbering: 1 = Sunday … 7 = Saturday.
    case weekly(weekday: Int, hour: Int, minute: Int)

    /// The first matching time strictly after `date`.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        switch self {
        case .manual:
            return nil
        case .hourly(let minute):
            components.minute = minute
        case .daily(let hour, let minute):
            components.hour = hour
            components.minute = minute
        case .weekly(let weekday, let hour, let minute):
            components.weekday = weekday
            components.hour = hour
            components.minute = minute
        }
        components.second = 0
        // .nextTime skips times that don't exist on DST changes rather than failing.
        return calendar.nextDate(
            after: date, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first,
            direction: .forward)
    }

    /// launchd `StartCalendarInterval` keys for this repeat (nil for manual).
    public var calendarInterval: [String: Int]? {
        switch self {
        case .manual: nil
        case .hourly(let minute): ["Minute": minute]
        case .daily(let hour, let minute): ["Hour": hour, "Minute": minute]
        // launchd numbers weekdays 0 = Sunday.
        case .weekly(let weekday, let hour, let minute): ["Weekday": weekday - 1, "Hour": hour, "Minute": minute]
        }
    }

    public var summary: String {
        func time(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
        switch self {
        case .manual: return "Manually"
        case .hourly(let minute): return "Every hour at :\(String(format: "%02d", minute))"
        case .daily(let hour, let minute): return "Daily at \(time(hour, minute))"
        case .weekly(let weekday, let hour, let minute):
            let name = Calendar.current.weekdaySymbols[(weekday - 1 + 7) % 7]
            return "\(name)s at \(time(hour, minute))"
        }
    }
}

/// What a schedule reads.
public enum BackupSource: Codable, Sendable, Hashable {
    case none
    /// Databases of a saved connection, each with its own tables and dump options.
    case connection(id: UUID, databases: [DatabaseSelection])
    /// SQL dumps (.sql / .sql.gz) to restore, in order.
    case files([String])
    /// Every .sql / .sql.gz file in a folder, by name, read when the schedule runs.
    case folder(String)

    public var connectionID: UUID? {
        if case .connection(let id, _) = self { id } else { nil }
    }
}

/// One database of a source connection.
public struct DatabaseSelection: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    /// Tables and views to include; nil means all of them, including ones created later.
    public var tables: [String]?
    public var options: DumpOptions

    public var id: String { name }

    public init(name: String, tables: [String]? = nil, options: DumpOptions = .standard) {
        self.name = name
        self.tables = tables
        self.options = options
    }
}

/// Where a schedule writes.
public enum BackupTarget: Codable, Sendable, Hashable {
    case none
    /// One `<database>_<date>.sql.gz` per database; older files beyond `keepLast` (per database) are deleted.
    case folder(path: String, keepLast: Int?)
    /// Sync into a saved connection: into `database`, or (nil) into databases with the source names, created if
    /// missing.
    case connection(id: UUID, database: String?)

    public var connectionID: UUID? {
        if case .connection(let id, _) = self { id } else { nil }
    }
}

/// Shell scripts run before and after a backup (with bash in the home folder, or the script's #! shell).
public struct BackupScripts: Codable, Sendable, Hashable {
    public var before: String
    public var after: String
    /// Seconds each script may run before it's stopped (and the run fails).
    public var timeout: Int

    public init(before: String = "", after: String = "", timeout: Int = 600) {
        self.before = before
        self.after = after
        self.timeout = timeout
    }
}

/// The outcome of one run.
public struct BackupRun: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case running, succeeded, failed, cancelled }

    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    /// What happened, for the history list ("3 databases, 12.4 MB" or the error).
    public var message: String
    /// Files written (folder targets).
    public var files: [String]
    public var logFile: String?

    public init(
        id: UUID = UUID(), startedAt: Date = .now, finishedAt: Date? = nil, status: Status = .running,
        message: String = "", files: [String] = [], logFile: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.message = message
        self.files = files
        self.logFile = logFile
    }
}
