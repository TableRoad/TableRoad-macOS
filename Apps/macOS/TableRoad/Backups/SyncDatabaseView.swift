import AppKit
import SwiftUI
import TableRoadBackup
import TableRoadCore
import TableRoadStorage
import TableRoadTransfer

/// Sync database: pick databases and tables on the left, a connection (or folder) on the right, then Sync Now or
/// turn it into a schedule.
struct SyncDatabaseView: View {
    @Environment(BackupScheduler.self) private var scheduler
    @Environment(ConnectionStore.self) private var store
    @Environment(WelcomeRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var source: EndpointMenu.Choice?
    @State private var target: EndpointMenu.Choice?
    @State private var sourceCatalog: ConnectionCatalog?
    @State private var targetCatalog: ConnectionCatalog?
    /// Ticked databases, with their tables (nil = all) and dump options.
    @State private var selections: [String: DatabaseSelection] = [:]
    @State private var expanded: Set<String> = []
    @State private var targetDatabase: String?
    @State private var sourceSearch = ""
    @State private var targetSearch = ""
    @State private var optionsFor: String?
    @State private var keepLast = 7
    @State private var runningID: UUID?
    @State private var outcome: BackupRun?
    @State private var newDatabaseName: String?
    @State private var newDatabaseError: String?
    /// Id used while syncing (progress is reported under it).
    @State private var syncID = UUID()

    var body: some View {
        VStack(spacing: 12) {
            Text("Sync database").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                pane(title: "From") { fromPane }
                pane(title: "To") { toPane }
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            #if DEBUG
                // TABLEROAD_DEV_SYNC=1: Docker MySQL → Docker MariaDB, for trying the window without its menus.
                if DevFixtures.environment["TABLEROAD_DEV_SYNC"] == "1", source == nil,
                    let from = store.profiles.first(where: { $0.name == "Docker MySQL 8.4" }),
                    let to = store.profiles.first(where: { $0.name == "Docker MariaDB 11" })
                {
                    source = .connection(from.id)
                    target = .connection(to.id)
                }
            #endif
        }
        .task(id: sourceConnectionID) {
            selections = [:]
            expanded = []
            sourceCatalog = sourceConnectionID.map { ConnectionCatalog(connectionID: $0, store: store) }
            await sourceCatalog?.loadDatabases()
        }
        .task(id: targetConnectionID) {
            targetDatabase = nil
            targetCatalog = targetConnectionID.map { ConnectionCatalog(connectionID: $0, store: store) }
            await targetCatalog?.loadDatabases()
        }
        .alert(
            outcome?.status == .succeeded ? "Sync Finished" : "Sync Failed",
            isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })
        ) {
            if let log = outcome?.logFile {
                Button("Show Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
            }
            Button("OK") { outcome = nil }
        } message: {
            Text(outcome?.message ?? "")
        }
    }

    private var sourceConnectionID: UUID? {
        if case .connection(let id) = source { id } else { nil }
    }

    private var targetConnectionID: UUID? {
        if case .connection(let id) = target { id } else { nil }
    }

    // MARK: From

    @ViewBuilder
    private var fromPane: some View {
        EndpointMenu(
            placeholder: "Choose a Connection or Folder, Files…", current: source, allowsFiles: true,
            folderPrompt: "Restore From"
        ) { source = $0 }
        switch source {
        case .connection:
            searchField("Search for database…", text: $sourceSearch)
            sourceTree
        case .folder(let path):
            fileList(
                (try? FileManager.default.contentsOfDirectory(atPath: path))?
                    .filter { $0.hasSuffix(".sql") || $0.hasSuffix(".sql.gz") }.sorted() ?? [])
        case .files(let paths):
            fileList(paths.map { ($0 as NSString).lastPathComponent })
        case nil:
            placeholder("Choose a connection to list its databases.")
        }
    }

    @ViewBuilder
    private var sourceTree: some View {
        if let catalog = sourceCatalog {
            switch catalog.state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder(message)
            case .loaded:
                List {
                    ForEach(catalog.databases.filter(matches(sourceSearch)), id: \.self) { database in
                        databaseRow(database, catalog: catalog)
                        if expanded.contains(database) {
                            if let tables = catalog.tables[database] {
                                ForEach(tables) { table in
                                    tableRow(table, database: database, catalog: catalog)
                                }
                            } else {
                                ProgressView().controlSize(.small).padding(.leading, 40)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func databaseRow(_ database: String, catalog: ConnectionCatalog) -> some View {
        HStack(spacing: 6) {
            Button {
                if expanded.contains(database) {
                    expanded.remove(database)
                } else {
                    expanded.insert(database)
                    Task { await catalog.loadTables(database) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded.contains(database) ? 90 : 0))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            Toggle(isOn: databaseTicked(database)) { Text(database).fontWeight(.medium) }
                .toggleStyle(.checkbox)
            if let size = catalog.size(of: database) {
                Text(size.byteText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selections[database] != nil {
                Button("Options…") { optionsFor = database }
                    .controlSize(.small)
                    .popover(
                        isPresented: Binding(get: { optionsFor == database }, set: { if !$0 { optionsFor = nil } }),
                        arrowEdge: .trailing
                    ) {
                        DumpOptionsView(
                            database: database, options: options(database),
                            supportsEvents: sourceKind?.family == .mysql,
                            onApplyToAll: {
                                guard let options = selections[database]?.options else { return }
                                for name in selections.keys { selections[name]?.options = options }
                            })
                    }
            }
        }
    }

    private func tableRow(_ table: TableInfo, database: String, catalog: ConnectionCatalog) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: tableTicked(table.name, database: database, all: catalog.tables[database] ?? [])) {
                Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
            }
            .toggleStyle(.checkbox)
            if let size = catalog.sizes[database]?[table.name] {
                Text(size.byteText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 40)
    }

    private var sourceKind: DatabaseKind? {
        sourceConnectionID.flatMap { store.profile(id: $0)?.kind }
    }

    private func databaseTicked(_ database: String) -> Binding<Bool> {
        Binding(
            get: { selections[database] != nil },
            set: { on in
                selections[database] = on ? DatabaseSelection(name: database) : nil
                if on { Task { await sourceCatalog?.loadTables(database) } }
            })
    }

    /// Unticking a table turns "all tables" into an explicit list; ticking every table returns to "all".
    private func tableTicked(_ table: String, database: String, all: [TableInfo]) -> Binding<Bool> {
        Binding(
            get: {
                guard let selection = selections[database] else { return false }
                return selection.tables?.contains(table) ?? true
            },
            set: { on in
                var selection = selections[database] ?? DatabaseSelection(name: database, tables: [])
                var tables = Set(selection.tables ?? all.map(\.name))
                if on { tables.insert(table) } else { tables.remove(table) }
                if tables.isEmpty {
                    selections[database] = nil
                    return
                }
                selection.tables = tables.count == all.count ? nil : all.map(\.name).filter(tables.contains)
                selections[database] = selection
            })
    }

    private func options(_ database: String) -> Binding<DumpOptions> {
        Binding(
            get: { selections[database]?.options ?? .standard },
            set: { selections[database]?.options = $0 })
    }

    // MARK: To

    @ViewBuilder
    private var toPane: some View {
        EndpointMenu(placeholder: "Choose a Connection or Folder…", current: target, folderPrompt: "Back Up Here") {
            target = $0
        }
        switch target {
        case .connection:
            searchField("Search for database…", text: $targetSearch)
            targetList
        case .folder:
            VStack(alignment: .leading, spacing: 8) {
                Text("Each database goes to a file of its own, named after it and the date.")
                    .foregroundStyle(.secondary)
                Picker("Keep", selection: $keepLast) {
                    Text("Every backup").tag(0)
                    ForEach([1, 3, 7, 14, 30, 60], id: \.self) { Text("The last \($0) of each database").tag($0) }
                }
                .fixedSize()
                Spacer()
            }
            .padding(.top, 4)
        default:
            placeholder("Choose where the databases go.")
        }
    }

    @ViewBuilder
    private var targetList: some View {
        if let catalog = targetCatalog {
            switch catalog.state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder(message)
            case .loaded:
                VStack(spacing: 6) {
                    List(selection: $targetDatabase) {
                        if !isRestore {
                            Text("Databases with the same names").italic().tag(String?.none)
                        }
                        ForEach(catalog.databases.filter(matches(targetSearch)), id: \.self) { database in
                            Label(database, systemImage: "cylinder").tag(String?.some(database))
                        }
                    }
                    .listStyle(.inset)
                    HStack {
                        Button("New \(catalog.databaseNoun)") { newDatabaseName = "" }
                            .disabled(!catalog.canCreateDatabases)
                        Spacer()
                    }
                }
                .alert(
                    "New \(catalog.databaseNoun)",
                    isPresented: Binding(get: { newDatabaseName != nil }, set: { if !$0 { newDatabaseName = nil } })
                ) {
                    TextField("Name", text: Binding(get: { newDatabaseName ?? "" }, set: { newDatabaseName = $0 }))
                    Button("Create") { createTargetDatabase(catalog) }
                    Button("Cancel", role: .cancel) { newDatabaseName = nil }
                }
                .alert(
                    "Couldn't Create It",
                    isPresented: Binding(get: { newDatabaseError != nil }, set: { if !$0 { newDatabaseError = nil } })
                ) {
                    Button("OK") { newDatabaseError = nil }
                } message: {
                    Text(newDatabaseError ?? "")
                }
            }
        }
    }

    private func createTargetDatabase(_ catalog: ConnectionCatalog) {
        let name = (newDatabaseName ?? "").trimmingCharacters(in: .whitespaces)
        newDatabaseName = nil
        guard !name.isEmpty else { return }
        Task {
            do {
                try await catalog.createDatabase(name)
                targetDatabase = name
            } catch {
                newDatabaseError = (error as? DatabaseError)?.message ?? error.localizedDescription
            }
        }
    }

    private var isRestore: Bool {
        switch source {
        case .files, .folder: true
        default: false
        }
    }

    // MARK: Footer

    private var schedule: BackupSchedule {
        var schedule = BackupSchedule(id: syncID, name: defaultName, repeats: .daily(hour: 2, minute: 0))
        switch source {
        case .connection(let id):
            let ordered = (sourceCatalog?.databases ?? []).compactMap { selections[$0] }
            schedule.source = .connection(id: id, databases: ordered)
        case .folder(let path): schedule.source = .folder(path)
        case .files(let paths): schedule.source = .files(paths)
        case nil: break
        }
        switch target {
        case .connection(let id): schedule.target = .connection(id: id, database: targetDatabase)
        case .folder(let path): schedule.target = .folder(path: path, keepLast: keepLast == 0 ? nil : keepLast)
        case .files, nil: break
        }
        return schedule
    }

    private var defaultName: String {
        let from = sourceConnectionID.flatMap { store.profile(id: $0)?.name } ?? "Files"
        let to: String =
            switch target {
            case .connection(let id): store.profile(id: id)?.name ?? "connection"
            case .folder(let path): (path as NSString).lastPathComponent
            default: "…"
            }
        return "\(from) → \(to)"
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismissWindow() }
                .keyboardShortcut(.cancelAction)
            if let progress = scheduler.progress[syncID], runningID != nil {
                ProgressView(value: progress.fraction ?? 0).frame(width: 120)
                Text(progress.step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let problem = schedule.problem, source != nil, target != nil {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Schedule…") {
                var saved = schedule
                saved.id = UUID()
                scheduler.store.save(saved)
                scheduler.updateLaunchAgent()
                router.mode = .backups
                router.selectedScheduleID = saved.id
                openWindow(id: "welcome")
                dismissWindow()
            }
            .disabled(schedule.problem != nil || runningID != nil)
            Button("Sync Now") {
                let job = schedule
                runningID = job.id
                Task {
                    outcome = await scheduler.runAdHoc(job)
                    runningID = nil
                    if let catalog = targetCatalog { await catalog.loadDatabases(force: true) }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(schedule.problem != nil || runningID != nil)
        }
    }

    // MARK: Helpers

    private func pane(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func searchField(_ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileList(_ names: [String]) -> some View {
        List(names, id: \.self) { Label($0, systemImage: "doc") }
            .listStyle(.inset)
            .overlay { if names.isEmpty { placeholder("No .sql or .sql.gz files") } }
    }

    private func matches(_ search: String) -> (String) -> Bool {
        let term = search.trimmingCharacters(in: .whitespaces)
        return { term.isEmpty || $0.localizedCaseInsensitiveContains(term) }
    }
}

#if DEBUG
    #Preview("Sync database – empty") {
        SyncDatabaseView()
            .environment(BackupScheduler.preview())
            .environment(PreviewData.store())
            .environment(WelcomeRouter())
            .frame(width: 900, height: 600)
    }
#endif
