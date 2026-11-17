import AppKit
import SwiftUI
import TableRoadBackup
import TableRoadCore
import TableRoadDesign
import TableRoadStorage
import TableRoadTransfer

/// Which half of the Welcome window is showing, and the schedule selected in Backups (shared with Sync database's
/// "Schedule…").
@MainActor @Observable
final class WelcomeRouter {
    enum Mode { case connections, backups }
    var mode: Mode = .connections
    var selectedScheduleID: UUID?
}

// MARK: - Schedule list

/// The schedules, in the Welcome window's left panel: name, failures, on/off, run/stop.
struct ScheduleListView: View {
    var search = ""
    @Environment(BackupScheduler.self) private var scheduler
    @Environment(WelcomeRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        List(selection: $router.selectedScheduleID) {
            ForEach(scheduler.store.schedules.filter(matches)) { schedule in
                ScheduleRow(schedule: schedule)
                    .tag(schedule.id)
                    .contextMenu { menu(for: schedule) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if scheduler.store.schedules.isEmpty {
                VStack(spacing: 8) {
                    Text("No Schedules").font(.headline)
                    Text("Back up databases on a schedule, or sync them into another connection.")
                        .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("New Schedule") { router.selectedScheduleID = newSchedule() }
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private func menu(for schedule: BackupSchedule) -> some View {
        Button(scheduler.isRunning(schedule.id) ? "Stop" : "Run Now") {
            if scheduler.isRunning(schedule.id) { scheduler.cancel(schedule.id) } else { scheduler.runNow(schedule.id) }
        }
        .disabled(schedule.problem != nil && !scheduler.isRunning(schedule.id))
        Button("Duplicate") {
            var copy = schedule
            copy.id = UUID()
            copy.name += " copy"
            copy.history = []
            copy.nextRunAt = nil
            scheduler.store.save(copy)
            scheduler.updateLaunchAgent()
            router.selectedScheduleID = copy.id
        }
        Divider()
        Button("Delete", role: .destructive) {
            scheduler.cancel(schedule.id)
            scheduler.store.delete(schedule.id)
            scheduler.updateLaunchAgent()
            if router.selectedScheduleID == schedule.id {
                router.selectedScheduleID = scheduler.store.schedules.first?.id
            }
        }
    }

    private func matches(_ schedule: BackupSchedule) -> Bool {
        let term = search.trimmingCharacters(in: .whitespaces)
        return term.isEmpty || schedule.name.localizedCaseInsensitiveContains(term)
    }

    private func newSchedule() -> UUID {
        let schedule = BackupSchedule()
        scheduler.store.save(schedule)
        return schedule.id
    }
}

private struct ScheduleRow: View {
    let schedule: BackupSchedule
    @Environment(BackupScheduler.self) private var scheduler

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.name).lineLimit(1)
                if let progress = scheduler.progress[schedule.id] {
                    Text(progress.step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if schedule.recentFailures > 0 {
                HStack(spacing: 2) {
                    Text("\(schedule.recentFailures)").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .help("The last \(schedule.recentFailures) run(s) failed")
            }
            Toggle("Enabled", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            Button {
                if scheduler.isRunning(schedule.id) {
                    scheduler.cancel(schedule.id)
                } else {
                    scheduler.runNow(schedule.id)
                }
            } label: {
                Image(systemName: scheduler.isRunning(schedule.id) ? "stop.fill" : "play.fill")
                    .foregroundStyle(scheduler.isRunning(schedule.id) ? Color.red : Color.green)
            }
            .buttonStyle(.borderless)
            .disabled(schedule.problem != nil && !scheduler.isRunning(schedule.id))
            .help(schedule.problem ?? (scheduler.isRunning(schedule.id) ? "Stop" : "Run now"))
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if let problem = schedule.problem { return problem }
        guard schedule.isEnabled, let next = schedule.nextRunAt else {
            return schedule.repeats == .manual ? "Manual" : "Off"
        }
        return "Next: " + next.formatted(.relative(presentation: .named))
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { schedule.isEnabled },
            set: { value in
                var updated = schedule
                updated.isEnabled = value
                scheduler.store.save(updated)
                scheduler.updateLaunchAgent()
            })
    }
}

// MARK: - Editor

/// Everything about one schedule, saved as it's edited: timing, From, To, scripts and history.
struct ScheduleEditorView: View {
    let scheduleID: UUID
    @Environment(BackupScheduler.self) private var scheduler
    @Environment(ConnectionStore.self) private var store
    @State private var sourceCatalog: ConnectionCatalog?
    @State private var targetCatalog: ConnectionCatalog?
    @State private var scriptTab = ScriptTab.before
    @State private var optionsFor: String?
    @State private var newDatabaseName: String?

    enum ScriptTab: String, CaseIterable, Identifiable {
        case before = "Before backup"
        case after = "After backup"
        var id: Self { self }
    }

    var body: some View {
        if scheduler.store.schedule(scheduleID) != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    timing
                    sectionTitle("From")
                    card { source }
                    caption(sourceCaption)
                    sectionTitle("To")
                    card { target }
                    sectionTitle("Scripts")
                    card { scripts }
                    caption(
                        "Scripts run with bash in your home folder, or with the shell their first line names. They get TR_SCHEDULE_NAME, TR_CONNECTION_NAME, TR_DATABASES (a line each), TR_OUTPUT_DIR, TR_RUN_ID and TR_LOG_FILE; the after script also gets TR_STATUS (succeeded or failed) and TR_BACKUP_FILES (a line each)."
                    )
                    sectionTitle("History")
                    card { history }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .task(id: schedule.wrappedValue.source.connectionID) {
                sourceCatalog = schedule.wrappedValue.source.connectionID.map {
                    ConnectionCatalog(connectionID: $0, store: store)
                }
                await sourceCatalog?.loadDatabases()
            }
            .task(id: schedule.wrappedValue.target.connectionID) {
                targetCatalog = schedule.wrappedValue.target.connectionID.map {
                    ConnectionCatalog(connectionID: $0, store: store)
                }
                await targetCatalog?.loadDatabases()
            }
        } else {
            ContentUnavailableView("No Schedule Selected", systemImage: "clock.arrow.circlepath")
        }
    }

    /// Edits save straight away (and re-sync the login agent when timing changes).
    private var schedule: Binding<BackupSchedule> {
        Binding(
            get: { scheduler.store.schedule(scheduleID) ?? BackupSchedule(id: scheduleID) },
            set: { value in
                let old = scheduler.store.schedule(scheduleID)
                scheduler.store.save(value)
                if old?.repeats != value.repeats || old?.isEnabled != value.isEnabled
                    || old?.launchWhenClosed != value.launchWhenClosed || old?.problem != value.problem
                {
                    scheduler.updateLaunchAgent()
                }
            })
    }

    // MARK: Timing

    private var timing: some View {
        VStack(alignment: .leading, spacing: 4) {
            card {
                VStack(spacing: 10) {
                    HStack {
                        Text("Name")
                        TextField("Name", text: schedule.name, prompt: Text("Untitled Schedule"))
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                    }
                    Divider()
                    RepeatEditor(repeats: schedule.repeats)
                    switchRow("Notify when a backup works", isOn: schedule.notifyOnSuccess)
                        .onChange(of: schedule.wrappedValue.notifyOnSuccess) { _, on in
                            if on { scheduler.requestNotificationPermission() }
                        }
                    switchRow("Open TableRoad for scheduled tasks", isOn: schedule.launchWhenClosed)
                }
            }
            caption("Failures always notify. If TableRoad is closed when a task is due, it opens in the background.")
        }
        .padding(.top, 4)
    }

    // MARK: From

    private var sourceChoice: EndpointMenu.Choice? {
        switch schedule.wrappedValue.source {
        case .none: nil
        case .connection(let id, _): .connection(id)
        case .files(let paths): .files(paths)
        case .folder(let path): .folder(path)
        }
    }

    private var sourceCaption: String {
        switch schedule.wrappedValue.source {
        case .connection:
            if case .folder = schedule.wrappedValue.target { "Each database goes to a file of its own." } else { "" }
        case .files: "The files are restored in this order."
        case .folder: "Every .sql and .sql.gz file in the folder is restored, by name."
        case .none: ""
        }
    }

    @ViewBuilder
    private var source: some View {
        VStack(alignment: .leading, spacing: 10) {
            EndpointMenu(
                placeholder: "Choose a Connection or Folder, Files…", current: sourceChoice, allowsFiles: true,
                folderPrompt: "Restore From"
            ) { choice in
                switch choice {
                case .connection(let id): schedule.wrappedValue.source = .connection(id: id, databases: [])
                case .folder(let path): schedule.wrappedValue.source = .folder(path)
                case .files(let paths): schedule.wrappedValue.source = .files(paths)
                }
            }
            if case .connection(_, let selected) = schedule.wrappedValue.source {
                databaseChecklist(selected: selected)
            }
        }
    }

    @ViewBuilder
    private func databaseChecklist(selected: [DatabaseSelection]) -> some View {
        if let catalog = sourceCatalog {
            switch catalog.state {
            case .idle, .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            case .loaded:
                let names = Set(selected.map(\.name))
                VStack(alignment: .leading, spacing: 4) {
                    // Selected databases that no longer exist stay visible so they can be unticked.
                    ForEach(
                        catalog.databases + selected.map(\.name).filter { !catalog.databases.contains($0) }, id: \.self
                    ) {
                        database in
                        HStack {
                            Toggle(isOn: databaseBinding(database)) {
                                Text(database)
                                if !catalog.databases.contains(database) {
                                    Text("(missing)").foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            if names.contains(database) {
                                if let tables = selected.first(where: { $0.name == database })?.tables {
                                    Text("\(tables.count) tables").font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Options…") { optionsFor = database }
                                    .controlSize(.small)
                                    .popover(isPresented: optionsBinding(database), arrowEdge: .trailing) {
                                        DumpOptionsView(
                                            database: database, options: optionsValue(database),
                                            supportsEvents: supportsEvents,
                                            onApplyToAll: { applyOptionsToAll(from: database) })
                                    }
                            }
                        }
                    }
                    if catalog.databases.isEmpty { Text("No databases").foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var supportsEvents: Bool {
        guard let id = schedule.wrappedValue.source.connectionID, let kind = store.profile(id: id)?.kind else {
            return false
        }
        return kind.family == .mysql
    }

    private func databaseBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .connection(_, let selected) = schedule.wrappedValue.source {
                    return selected.contains { $0.name == name }
                }
                return false
            },
            set: { on in
                guard case .connection(let id, var selected) = schedule.wrappedValue.source else { return }
                if on {
                    selected.append(DatabaseSelection(name: name))
                } else {
                    selected.removeAll { $0.name == name }
                }
                schedule.wrappedValue.source = .connection(id: id, databases: selected)
            })
    }

    private func optionsBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { optionsFor == name }, set: { if !$0 { optionsFor = nil } })
    }

    private func optionsValue(_ name: String) -> Binding<DumpOptions> {
        Binding(
            get: {
                if case .connection(_, let selected) = schedule.wrappedValue.source {
                    return selected.first { $0.name == name }?.options ?? .standard
                }
                return .standard
            },
            set: { options in
                guard case .connection(let id, var selected) = schedule.wrappedValue.source,
                    let index = selected.firstIndex(where: { $0.name == name })
                else { return }
                selected[index].options = options
                schedule.wrappedValue.source = .connection(id: id, databases: selected)
            })
    }

    private func applyOptionsToAll(from name: String) {
        guard case .connection(let id, var selected) = schedule.wrappedValue.source,
            let options = selected.first(where: { $0.name == name })?.options
        else { return }
        for index in selected.indices { selected[index].options = options }
        schedule.wrappedValue.source = .connection(id: id, databases: selected)
    }

    // MARK: To

    private var targetChoice: EndpointMenu.Choice? {
        switch schedule.wrappedValue.target {
        case .none: nil
        case .folder(let path, _): .folder(path)
        case .connection(let id, _): .connection(id)
        }
    }

    @ViewBuilder
    private var target: some View {
        VStack(alignment: .leading, spacing: 10) {
            EndpointMenu(
                placeholder: "Choose a Connection or Folder…", current: targetChoice, folderPrompt: "Back Up Here"
            ) { choice in
                switch choice {
                case .connection(let id): schedule.wrappedValue.target = .connection(id: id, database: nil)
                case .folder(let path): schedule.wrappedValue.target = .folder(path: path, keepLast: 7)
                case .files: break
                }
            }
            switch schedule.wrappedValue.target {
            case .folder(let path, let keepLast):
                HStack {
                    Text("Keep")
                    Picker("Keep", selection: keepBinding(path: path, keepLast: keepLast)) {
                        Text("every backup").tag(0)
                        ForEach([1, 3, 7, 14, 30, 60], id: \.self) { count in
                            Text("the last \(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("of each database")
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    }
                    .controlSize(.small)
                }
            case .connection(let id, let database):
                targetDatabasePicker(connection: id, database: database)
            case .none:
                EmptyView()
            }
        }
    }

    private func keepBinding(path: String, keepLast: Int?) -> Binding<Int> {
        Binding(
            get: { keepLast ?? 0 },
            set: { schedule.wrappedValue.target = .folder(path: path, keepLast: $0 == 0 ? nil : $0) })
    }

    @ViewBuilder
    private func targetDatabasePicker(connection id: UUID, database: String?) -> some View {
        let isRestore: Bool = {
            switch schedule.wrappedValue.source {
            case .files, .folder: true
            default: false
            }
        }()
        HStack {
            Text(isRestore ? "Restore into" : "Sync into")
            Spacer()
            Picker(
                "Database",
                selection: Binding(
                    get: { database ?? "" },
                    set: { value in
                        if value == "\u{0}new" {
                            newDatabaseName = ""
                        } else {
                            schedule.wrappedValue.target = .connection(id: id, database: value.isEmpty ? nil : value)
                        }
                    })
            ) {
                if !isRestore { Text("Databases with the same names").tag("") }
                ForEach(targetCatalog?.databases ?? [], id: \.self) { Text($0).tag($0) }
                if let database, !(targetCatalog?.databases.contains(database) ?? false) {
                    Text("\(database) (created when it runs)").tag(database)
                }
                if targetCatalog?.canCreateDatabases == true {
                    Divider()
                    Text("New \(targetCatalog?.databaseNoun ?? "database")…").tag("\u{0}new")
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
        }
        .alert(
            "New \(targetCatalog?.databaseNoun ?? "database")",
            isPresented: Binding(get: { newDatabaseName != nil }, set: { if !$0 { newDatabaseName = nil } })
        ) {
            TextField("Name", text: Binding(get: { newDatabaseName ?? "" }, set: { newDatabaseName = $0 }))
            Button("Use") {
                let name = (newDatabaseName ?? "").trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { schedule.wrappedValue.target = .connection(id: id, database: name) }
                newDatabaseName = nil
            }
            Button("Cancel", role: .cancel) { newDatabaseName = nil }
        } message: {
            Text("It's created on the target the first time the schedule runs.")
        }
    }

    // MARK: Scripts

    private var scripts: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Script", selection: $scriptTab) {
                    ForEach(ScriptTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("Timeout").foregroundStyle(.secondary)
                TextField("Timeout", value: schedule.scripts.timeout, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Text("s").foregroundStyle(.secondary)
            }
            TextEditor(text: scriptTab == .before ? schedule.scripts.before : schedule.scripts.after)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 110)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        }
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            let runs = schedule.wrappedValue.history
            if runs.isEmpty {
                Text("No runs yet").foregroundStyle(.secondary)
            } else {
                ForEach(runs.prefix(20)) { run in
                    RunRow(run: run)
                    if run.id != runs.prefix(20).last?.id { Divider() }
                }
            }
            HStack {
                if let problem = schedule.wrappedValue.problem {
                    Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                } else if let progress = scheduler.progress[scheduleID] {
                    ProgressView(value: progress.fraction ?? 0).frame(width: 80)
                    Text(progress.step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Show Logs") {
                    NSWorkspace.shared.open(scheduler.store.logDirectory)
                }
                .disabled(!FileManager.default.fileExists(atPath: scheduler.store.logDirectory.path))
                if scheduler.isRunning(scheduleID) {
                    Button("Stop") { scheduler.cancel(scheduleID) }
                } else {
                    Button("Run Now") { scheduler.runNow(scheduleID) }
                        .buttonStyle(.borderedProminent)
                        .disabled(schedule.wrappedValue.problem != nil)
                }
            }
        }
    }

    // MARK: Layout helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline).padding(.top, 10)
    }

    /// Label on the left, switch on the right (like System Settings).
    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    @ViewBuilder
    private func caption(_ text: String) -> some View {
        if !text.isEmpty { captionText(text) }
    }

    private func captionText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Repeat: Manually / Hourly at :mm / Daily at hh:mm / Weekly on day at hh:mm.
private struct RepeatEditor: View {
    @Binding var repeats: ScheduleRepeat

    enum Kind: String, CaseIterable, Identifiable {
        case manual = "Manually", hourly = "Hourly", daily = "Daily", weekly = "Weekly"
        var id: Self { self }
    }

    var body: some View {
        HStack {
            Text("Repeat")
            Spacer()
            Picker("Repeat", selection: kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            switch repeats {
            case .manual:
                EmptyView()
            case .hourly(let minute):
                Text("at minute")
                TextField(
                    "Minute",
                    value: Binding(get: { minute }, set: { repeats = .hourly(minute: min(max($0, 0), 59)) }),
                    format: .number
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
            case .daily(let hour, let minute):
                DatePicker(
                    "Time", selection: time(hour, minute) { repeats = .daily(hour: $0, minute: $1) },
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
            case .weekly(let weekday, let hour, let minute):
                Picker(
                    "Day",
                    selection: Binding(
                        get: { weekday }, set: { repeats = .weekly(weekday: $0, hour: hour, minute: minute) })
                ) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                DatePicker(
                    "Time", selection: time(hour, minute) { repeats = .weekly(weekday: weekday, hour: $0, minute: $1) },
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
            }
        }
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch repeats {
                case .manual: .manual
                case .hourly: .hourly
                case .daily: .daily
                case .weekly: .weekly
                }
            },
            set: { kind in
                let (hour, minute): (Int, Int) =
                    switch repeats {
                    case .daily(let h, let m), .weekly(_, let h, let m): (h, m)
                    case .hourly(let m): (2, m)
                    case .manual: (2, 0)
                    }
                repeats =
                    switch kind {
                    case .manual: .manual
                    case .hourly: .hourly(minute: minute)
                    case .daily: .daily(hour: hour, minute: minute)
                    case .weekly: .weekly(weekday: 2, hour: hour, minute: minute)
                    }
            })
    }

    private func time(_ hour: Int, _ minute: Int, set: @escaping (Int, Int) -> Void) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                set(parts.hour ?? 0, parts.minute ?? 0)
            })
    }
}

private struct RunRow: View {
    let run: BackupRun

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let finished = run.finishedAt {
                        Text(
                            Duration.seconds(finished.timeIntervalSince(run.startedAt)).formatted(
                                .units(width: .narrow))
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                Text(run.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if let log = run.logFile, FileManager.default.fileExists(atPath: log) {
                Button("Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                    .controlSize(.small)
            }
            if let file = run.files.first, FileManager.default.fileExists(atPath: file) {
                Button("Show") {
                    NSWorkspace.shared.activateFileViewerSelecting(run.files.map { URL(fileURLWithPath: $0) })
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch run.status {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
    extension BackupScheduler {
        /// A scheduler over a throwaway file with two sample schedules (never runs anything).
        static func preview() -> BackupScheduler {
            let file = FileManager.default.temporaryDirectory.appending(
                path: "tableroad-preview-backups-\(UUID()).json")
            let store = BackupStore(fileURL: file)
            let connections = PreviewData.store()
            var nightly = BackupSchedule(name: "Nightly shop backup", repeats: .daily(hour: 2, minute: 0))
            nightly.source = .connection(
                id: connections.profiles[0].id, databases: [DatabaseSelection(name: "shop")])
            nightly.target = .folder(path: "/Users/me/Backups", keepLast: 7)
            nightly.record(
                BackupRun(
                    startedAt: .now.addingTimeInterval(-90_000), finishedAt: .now.addingTimeInterval(-89_950),
                    status: .succeeded, message: "1 database, 12.4 MB"))
            nightly.record(
                BackupRun(
                    startedAt: .now.addingTimeInterval(-3_600), finishedAt: .now.addingTimeInterval(-3_590),
                    status: .failed, message: "Access denied for user 'app'@'%'"))
            store.save(nightly)
            store.save(BackupSchedule(name: "Untitled Schedule", repeats: .manual))
            return BackupScheduler(store: store, connections: connections)
        }
    }

    #Preview("Backups – list and editor") {
        let scheduler = BackupScheduler.preview()
        let router = WelcomeRouter()
        router.selectedScheduleID = scheduler.store.schedules.first?.id
        return HStack(spacing: 0) {
            ScheduleListView().frame(width: 280)
            ScheduleEditorView(scheduleID: scheduler.store.schedules[0].id)
        }
        .frame(width: 1000, height: 640)
        .environment(scheduler)
        .environment(router)
        .environment(PreviewData.store())
    }
#endif
