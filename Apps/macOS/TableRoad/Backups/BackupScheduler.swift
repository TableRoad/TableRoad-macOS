import AppKit
import Foundation
import Observation
import TableRoadBackup
import TableRoadCore
import TableRoadDrivers
import TableRoadSQL
import TableRoadStorage
import UserNotifications

/// Runs backup schedules while TableRoad is open (checking every 30 seconds, and catching up on runs missed while
/// it was closed), tracks progress, posts notifications, and keeps the login agent that opens TableRoad in the
/// background when a schedule is due.
@MainActor @Observable
final class BackupScheduler {
    let store: BackupStore
    private let connections: ConnectionStore
    /// Live progress of running schedules (and ad-hoc syncs), by schedule id.
    private(set) var progress: [UUID: BackupProgress] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var timer: Timer?
    /// Launched by the login agent: quit once due runs finish, unless someone started using the app.
    private let isBackgroundLaunch = CommandLine.arguments.contains(BackupLaunchAgent.argument)

    init(store: BackupStore, connections: ConnectionStore) {
        self.store = store
        self.connections = connections
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        runDue()
        updateLaunchAgent()
        if isBackgroundLaunch { quitWhenIdle() }
    }

    func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }

    /// Starts every enabled schedule that's due.
    func runDue() {
        for schedule in store.due() where tasks[schedule.id] == nil {
            run(schedule, scheduled: true)
        }
    }

    /// Run Now (also for disabled or manual schedules).
    func runNow(_ id: UUID) {
        guard let schedule = store.schedule(id), tasks[id] == nil else { return }
        run(schedule, scheduled: false)
    }

    /// Runs a schedule that isn't saved (Sync database ▸ Sync Now). The result is returned, not stored.
    func runAdHoc(_ schedule: BackupSchedule) async -> BackupRun {
        let context = makeContext()
        let id = schedule.id
        let run = await BackupRunner.run(schedule, context: context) { [weak self] step in
            Task { @MainActor in self?.progress[id] = step }
        }
        progress[id] = nil
        return run
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    private func run(_ schedule: BackupSchedule, scheduled: Bool) {
        let id = schedule.id
        // Another copy of TableRoad (e.g. a second build) may run the same schedules from the same file.
        guard let lock = ScheduleLock(id: id, directory: store.logDirectory.deletingLastPathComponent()) else {
            if scheduled {
                store.record(
                    BackupRun(status: .cancelled, message: "Already running elsewhere."), for: id, rescheduleFrom: .now)
            }
            return
        }
        let context = makeContext()
        let started = Date.now
        progress[id] = BackupProgress(step: "Starting…")
        var running = BackupRun(startedAt: started)
        running.message = "Running…"
        store.record(running, for: id)
        tasks[id] = Task { [weak self] in
            let result = await BackupRunner.run(schedule, context: context, runID: running.id, startedAt: started) {
                step in
                Task { @MainActor in self?.progress[id] = step }
            }
            lock.release()
            guard let self else { return }
            self.tasks[id] = nil
            self.progress[id] = nil
            self.store.record(result, for: id, rescheduleFrom: scheduled ? .now : nil)
            self.notify(schedule: self.store.schedule(id) ?? schedule, run: result)
            if self.isBackgroundLaunch { self.quitWhenIdle() }
        }
    }

    /// Connections are resolved now, on the main actor; the run itself happens off it.
    private func makeContext() -> BackupContext {
        var profiles: [UUID: (ConnectionProfile, String?)] = [:]
        for profile in connections.profiles {
            profiles[profile.id] = (profile, connections.password(for: profile.id))
        }
        let snapshot = profiles
        return BackupContext(
            connect: { id in
                guard let (profile, password) = snapshot[id] else {
                    throw BackupError("The connection was deleted.")
                }
                return try await Drivers.connect(profile, password: password)
            },
            connectionName: { id in snapshot[id]?.0.name },
            syntax: { id in snapshot[id].map { Drivers.statementSyntax($0.0.kind) } ?? .mysql },
            logDirectory: store.logDirectory)
    }

    // MARK: Notifications

    private func notify(schedule: BackupSchedule, run: BackupRun) {
        guard run.status == .failed || (run.status == .succeeded && schedule.notifyOnSuccess) else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = run.status == .succeeded ? "\(schedule.name) finished" : "\(schedule.name) failed"
            content.body = run.message
            if run.status == .failed { content.sound = .default }
            center.add(UNNotificationRequest(identifier: run.id.uuidString, content: content, trigger: nil))
        }
    }

    /// Asks for permission up front when "Notify when a backup works" is switched on.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Background launches

    /// Re-writes the login agent after schedules change (installed only while some schedule wants it).
    func updateLaunchAgent() {
        #if DEBUG
            if DevFixtures.isEnabled { return }  // never touch the real login agents from a fixture run
        #endif
        let intervals = store.schedules
            .filter { $0.isEnabled && $0.launchWhenClosed && $0.problem == nil }
            .compactMap(\.repeats.calendarInterval)
        BackupLaunchAgent.update(intervals: intervals)
    }

    private func quitWhenIdle() {
        guard tasks.isEmpty, isBackgroundLaunch else { return }
        // Someone opened a window or switched to the app meanwhile: keep running.
        if NSApp.isActive || NSApp.windows.contains(where: { $0.isVisible && $0.isKeyWindow }) { return }
        NSApp.terminate(nil)
    }
}

/// Holds an advisory lock on `<id>.lock` while a schedule runs, so only one TableRoad process runs it.
final class ScheduleLock: Sendable {
    private let descriptor: Int32

    init?(id: UUID, directory: URL) {
        let folder = directory.appending(path: "Backups/Locks")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appending(path: "\(id.uuidString).lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// `~/Library/LaunchAgents/<bundle id>.backups.plist`: opens TableRoad hidden, in the background, at each enabled
/// schedule's times (launchd also fires missed times after the Mac wakes). Does nothing if TableRoad is running;
/// the running app's own timer handles the schedule.
enum BackupLaunchAgent {
    static let argument = "--run-due-backups"

    static var label: String { (Bundle.main.bundleIdentifier ?? "app.tableroad") + ".backups" }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static func update(intervals: [[String: Int]]) {
        let domain = "gui/\(getuid())"
        if intervals.isEmpty {
            guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
            launchctl(["bootout", "\(domain)/\(label)"])
            try? FileManager.default.removeItem(at: plistURL)
            return
        }
        let appPath = Bundle.main.bundlePath
        let executable = Bundle.main.executableURL?.lastPathComponent ?? "TableRoad"
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/bin/sh", "-c",
                // Only launch when this app isn't already running (open -j would hide a running copy).
                "pgrep -xq \(shellQuoted(executable)) || /usr/bin/open -g -j -a \(shellQuoted(appPath)) --args \(argument)",
            ],
            "StartCalendarInterval": intervals,
            "ProcessType": "Background",
        ]
        guard
            let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return }
        if let existing = try? Data(contentsOf: plistURL), existing == data { return }
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        launchctl(["bootout", "\(domain)/\(label)"])
        try? data.write(to: plistURL, options: .atomic)
        launchctl(["bootstrap", domain, plistURL.path])
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
