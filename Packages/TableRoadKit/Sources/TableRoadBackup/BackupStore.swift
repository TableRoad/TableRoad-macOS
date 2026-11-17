import Foundation
import Observation
import TableRoadStorage

/// Backup schedules, persisted as JSON (`backups.json`).
@MainActor @Observable
public final class BackupStore {
    public private(set) var schedules: [BackupSchedule] = []
    public private(set) var loadError: String?
    private let file: JSONFile<[BackupSchedule]>

    public init(fileURL: URL) {
        file = JSONFile(url: fileURL)
        do { schedules = try file.load() ?? [] } catch { loadError = file.describe(error) }
    }

    public static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "TableRoad/backups.json")
    }

    /// Where run logs go: `Backups/Logs/<run id>.log` next to the store.
    public var logDirectory: URL {
        file.url.deletingLastPathComponent().appending(path: "Backups/Logs")
    }

    public func schedule(_ id: UUID) -> BackupSchedule? {
        schedules.first { $0.id == id }
    }

    /// Adds or replaces a schedule, recomputing when it next runs if its timing changed.
    public func save(_ schedule: BackupSchedule) {
        var schedule = schedule
        let previous = self.schedule(schedule.id)
        if previous == nil || previous?.repeats != schedule.repeats || previous?.isEnabled != schedule.isEnabled
            || schedule.nextRunAt == nil
        {
            schedule.reschedule()
        }
        schedule.modifiedAt = .now
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
        persist()
    }

    public func delete(_ id: UUID) {
        schedules.removeAll { $0.id == id }
        persist()
    }

    /// Records a run (in progress or finished). A finished scheduled run moves `nextRunAt` on.
    public func record(_ run: BackupRun, for id: UUID, rescheduleFrom date: Date? = nil) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].record(run)
        if let date { schedules[index].reschedule(after: date) }
        persist()
    }

    /// Enabled schedules whose time has come (including ones missed while TableRoad was closed).
    public func due(at date: Date = .now) -> [BackupSchedule] {
        schedules.filter { $0.isEnabled && $0.problem == nil && ($0.nextRunAt.map { $0 <= date } ?? false) }
    }

    private func persist() {
        guard loadError == nil else { return }  // never overwrite a file that couldn't be read
        try? file.save(schedules)
    }
}
