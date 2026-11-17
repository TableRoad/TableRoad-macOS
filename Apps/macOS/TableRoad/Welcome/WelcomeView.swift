import AppKit
import SwiftUI
import TableRoadBackup
import TableRoadCore
import TableRoadDesign
import TableRoadStorage
import UniformTypeIdentifiers

/// TablePlus-style launcher: brand panel on the left; grouped, searchable connections on the right.
struct WelcomeView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(WelcomeRouter.self) private var router
    @Environment(BackupScheduler.self) private var scheduler
    @Environment(\.openWindow) private var openWindow
    @State private var scheduleSearch = ""
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var editor: EditorRequest?
    @State private var showingURLImport = false
    @State private var showingEnginePicker = false
    @State private var pendingDelete: ConnectionProfile?
    @State private var pendingGroupDelete: ConnectionGroup?
    @State private var groupEditor: ConnectionGroup?
    @State private var exportRequest: ExportConnectionsRequest?
    @State private var importData: Data?
    @State private var alert: String?

    /// Which profile the form sheet edits.
    struct EditorRequest: Identifiable {
        let id = UUID()
        var profile: ConnectionProfile?
        var password: String?
        var isNew = false
    }

    struct ExportConnectionsRequest: Identifiable {
        let id = UUID()
        var title: String
        /// nil = every connection.
        var ids: Set<UUID>?
        var fileName: String
    }

    var body: some View {
        HStack(spacing: 0) {
            switch router.mode {
            case .connections:
                brandPanel
                connectionPanel
            case .backups:
                backupsSidebar
                backupsPanel
            }
        }
        // Backups need room for the schedule editor.
        .frame(width: router.mode == .connections ? 800 : 1040, height: router.mode == .connections ? 480 : 660)
        .task {
            #if DEBUG
                if let name = DevFixtures.openConnection, let profile = store.profiles.first(where: { $0.name == name })
                {
                    open(profile.id)
                }
            #endif
        }
        .sheet(item: $editor) { request in
            ConnectionFormView(
                profile: request.profile, password: request.password,
                sshPassword: request.profile.flatMap { store.sshPassword(for: $0.id) },
                onSaved: { saved in selection = [saved.id.uuidString] },
                onConnect: { saved in open(saved.id) },
                isNewOverride: request.isNew
            )
            .environment(store)
        }
        .sheet(isPresented: $showingURLImport) {
            ImportURLSheet { parsed in
                editor = EditorRequest(profile: parsed.profile, password: parsed.password, isNew: true)
            }
        }
        .sheet(isPresented: $showingEnginePicker) {
            EnginePickerSheet(
                onCreate: { kind in newConnection(kind) },
                onImport: { showingURLImport = true },
                onNewGroup: { newGroup() })
        }
        .sheet(item: $groupEditor) { group in
            GroupEditorSheet(group: group) { saved in
                do { try store.save(saved) } catch { alert = error.localizedDescription }
            }
        }
        .sheet(item: $exportRequest) { request in
            ExportConnectionsSheet(request: request) { includePasswords, includeSSH, password in
                exportConnections(
                    request, includePasswords: includePasswords, includeSSH: includeSSH, password: password)
            }
        }
        .sheet(item: Binding(get: { importData.map(ImportFileRequest.init) }, set: { importData = $0?.data })) {
            request in
            ImportPasswordSheet { password in try importBundle(request.data, password: password) }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { try? store.delete(pendingDelete.id) }
                pendingDelete = nil
            }
        } message: {
            Text("Its saved password is removed from the Keychain too.")
        }
        .confirmationDialog(
            "Delete the group “\(pendingGroupDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingGroupDelete != nil }, set: { if !$0 { pendingGroupDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                if let pendingGroupDelete { try? store.deleteGroup(pendingGroupDelete.id) }
                pendingGroupDelete = nil
            }
        } message: {
            Text("Its connections aren't deleted; they move out of the group.")
        }

        .alert(
            "Something Went Wrong", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
        ) {
            Button("OK") { alert = nil }
        } message: {
            Text(alert ?? "")
        }
    }

    // MARK: Mode switch and Sync database

    /// Connections | Backups, next to the window buttons (like TablePlus).
    private var modeSwitch: some View {
        @Bindable var router = router
        return HStack(spacing: 2) {
            modeButton(.connections, symbol: "powerplug.fill", help: "Connections")
            modeButton(.backups, symbol: "clock.arrow.circlepath", help: "Backups and schedules (⇧⌘B)")
        }
        .padding(3)
        .background(Color.white.opacity(0.12), in: Capsule())
    }

    private func modeButton(_ mode: WelcomeRouter.Mode, symbol: String, help: String) -> some View {
        Button {
            router.mode = mode
            if mode == .backups && router.selectedScheduleID == nil {
                router.selectedScheduleID = scheduler.store.schedules.first?.id
            }
        } label: {
            Image(systemName: symbol)
                .frame(width: 30, height: 24)
                .background(router.mode == mode ? Color.white.opacity(0.22) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var syncDatabaseButton: some View {
        Button {
            openWindow(id: "sync-database")
        } label: {
            Label("Sync database", systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Backups

    private var backupsSidebar: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: 40)
            ScheduleListView(search: scheduleSearch)
            syncDatabaseButton
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(Brand.teal)
        // Beside the window's close/minimise/zoom buttons.
        .overlay(alignment: .topLeading) {
            modeSwitch.padding(.leading, 84).padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
    }

    private var backupsPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    let schedule = BackupSchedule()
                    scheduler.store.save(schedule)
                    router.selectedScheduleID = schedule.id
                } label: {
                    Image(systemName: "plus").frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .frame(height: 34)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .help("New schedule")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search for schedule…", text: $scheduleSearch)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(12)
            if let id = router.selectedScheduleID, scheduler.store.schedule(id) != nil {
                ScheduleEditorView(scheduleID: id)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("No Schedule Selected", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(
                        "Back up databases to a folder on a schedule, sync them into another connection, or restore dump files."
                    )
                } actions: {
                    Button("New Schedule") {
                        let schedule = BackupSchedule()
                        scheduler.store.save(schedule)
                        router.selectedScheduleID = schedule.id
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Brand panel

    private var brandPanel: some View {
        VStack(spacing: 14) {
            Spacer()
            RoadMark(size: 140)
            Wordmark(size: 30)
            VStack(spacing: 4) {
                Text("Version \(Bundle.main.shortVersion) · Open source (\(ProjectLinks.licenceName))")
                    .foregroundStyle(Brand.cream.opacity(0.6))
                Link("TableRoad on GitHub", destination: ProjectLinks.repository)
                    .foregroundStyle(Brand.amber)
            }
            .font(.caption)
            Spacer()
            VStack(spacing: 8) {
                Button {
                    showingEnginePicker = true
                } label: {
                    Text("Create Connection…").frame(maxWidth: .infinity)
                }
                .keyboardShortcut("n")
                Button {
                    showingURLImport = true
                } label: {
                    Text("Import from URL…").frame(maxWidth: .infinity)
                }
            }
            // Same width for both buttons.
            .frame(width: 200)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            syncDatabaseButton
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(Brand.teal)
        // Beside the window's close/minimise/zoom buttons.
        .overlay(alignment: .topLeading) {
            modeSwitch.padding(.leading, 84).padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Connection panel

    private var connectionPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Button {
                        showingEnginePicker = true
                    } label: {
                        Image(systemName: "plus").frame(width: 30, height: 30)
                    }
                    .help("New connection (⌘N)")
                    Button(action: newGroup) {
                        Image(systemName: "folder.badge.plus").frame(width: 30, height: 30)
                    }
                    .help("New group")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .frame(height: 34)
                .background(Color.primary.opacity(0.06), in: Capsule())
                // Matches the workspace's connection pill.
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search for connection…", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(12)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu { backgroundMenu(group: nil, connection: nil) }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError = store.loadError {
            ContentUnavailableView(
                "Couldn't Load Connections", systemImage: "exclamationmark.triangle", description: Text(loadError)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.profiles.isEmpty && store.groups.isEmpty {
            ContentUnavailableView {
                Label("No Connections", systemImage: "cylinder.split.1x2")
            } description: {
                Text("Create a connection, paste a connection URL, or import a .tableroad file.")
            } actions: {
                Button("Create Connection…") { showingEnginePicker = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(visibleGroups) { group in
                    groupRow(group)
                }
                ForEach(connections(in: nil)) { profile in
                    connectionRow(profile)
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 22)
            .contextMenu(forSelectionType: String.self) { ids in
                let profiles = ids.compactMap { UUID(uuidString: $0) }.compactMap(store.profile(id:))
                if let profile = profiles.first {
                    connectionMenu(profile, all: profiles)
                } else if let id = ids.first, let group = groupFor(tag: id) {
                    groupMenu(group)
                } else {
                    backgroundMenu(group: nil, connection: nil)
                }
            } primaryAction: { ids in
                if let id = ids.compactMap(UUID.init(uuidString:)).first, store.profile(id: id) != nil { open(id) }
            }
            .onKeyPress(.return) {
                if let id = selection.compactMap(UUID.init(uuidString:)).first, store.profile(id: id) != nil {
                    open(id)
                }
                return .handled
            }
        }
    }

    private func groupRow(_ group: ConnectionGroup) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { !search.isEmpty || group.isExpanded },
                set: { open in
                    var updated = group
                    updated.isExpanded = open
                    try? store.save(updated)
                })
        ) {
            ForEach(connections(in: group.id)) { connectionRow($0) }
        } label: {
            HStack(spacing: 8) {
                GroupIconView(icon: group.icon, size: 26)
                Text(group.name).font(.headline)
                Text("\(connections(in: group.id).count)").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .dropDestination(for: String.self) { items, _ in
                let ids = Set(items.compactMap(UUID.init(uuidString:)))
                try? store.move(ids, to: group.id)
                return !ids.isEmpty
            }
        }
        .tag("group:" + group.id.uuidString)
    }

    private func connectionRow(_ profile: ConnectionProfile) -> some View {
        ConnectionRow(profile: profile)
            .tag(profile.id.uuidString)
            .draggable(profile.id.uuidString)
    }

    // MARK: Menus

    @ViewBuilder
    private func backgroundMenu(group: ConnectionGroup?, connection: ConnectionProfile?) -> some View {
        Menu("New") {
            Button("Group…", action: newGroup)
            Button("Connection…") { showingEnginePicker = true }
            Menu("Import Connection") {
                Button("From URL…") { showingURLImport = true }
                Button("From File…", action: importFromFile)
            }
        }
        Menu("Export Connections") {
            Button("Export All…") {
                exportRequest = ExportConnectionsRequest(
                    title: "Export All Connections", ids: nil, fileName: "Connections")
            }
            .disabled(store.profiles.isEmpty)
            if let group {
                Button("Export This Group…") { exportGroup(group) }
            }
            if let connection {
                Button("Export This Connection…") { exportConnection(connection) }
            }
        }
    }

    @ViewBuilder
    private func connectionMenu(_ profile: ConnectionProfile, all: [ConnectionProfile]) -> some View {
        Button("Connect") { open(profile.id) }
        Button("Edit…") { edit(profile) }
        Button("Duplicate") { _ = try? store.duplicate(profile) }
        Button("Copy as URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ConnectionURL.string(for: profile), forType: .string)
        }
        Divider()
        Menu("Move to Group") {
            Button("No Group") { try? store.move(Set(all.map(\.id)), to: nil) }
            Divider()
            ForEach(store.groups) { group in
                Button(group.name) { try? store.move(Set(all.map(\.id)), to: group.id) }
            }
            Divider()
            Button("New Group…") {
                let group = ConnectionGroup(name: "New Group")
                try? store.save(group)
                try? store.move(Set(all.map(\.id)), to: group.id)
                groupEditor = group
            }
        }
        Divider()
        backgroundMenu(group: profile.groupID.flatMap(store.group(id:)), connection: profile)
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = profile }
    }

    @ViewBuilder
    private func groupMenu(_ group: ConnectionGroup) -> some View {
        Button("New Connection in Group…") { newConnection(.mysql, group: group.id, pick: true) }
        Button("Rename / Change Icon…") { groupEditor = group }
        Divider()
        backgroundMenu(group: group, connection: nil)
        Divider()
        Button("Delete Group…", role: .destructive) { pendingGroupDelete = group }
    }

    // MARK: Data

    private var visibleGroups: [ConnectionGroup] {
        let sorted = store.groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(search) || !connections(in: $0.id).isEmpty }
    }

    private func connections(in groupID: UUID?) -> [ConnectionProfile] {
        let groupIDs = Set(store.groups.map(\.id))
        let members = store.profiles.filter { profile in
            // Connections pointing at a deleted group show at the top level.
            groupID == nil ? profile.groupID.map { !groupIDs.contains($0) } ?? true : profile.groupID == groupID
        }
        let sorted = members.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !search.isEmpty else { return sorted }
        let groupName = groupID.flatMap(store.group(id:))?.name ?? ""
        if groupName.localizedCaseInsensitiveContains(search) { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search)
                || ($0.database ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private func groupFor(tag: String) -> ConnectionGroup? {
        guard tag.hasPrefix("group:"), let id = UUID(uuidString: String(tag.dropFirst(6))) else { return nil }
        return store.group(id: id)
    }

    // MARK: Actions

    private func open(_ id: UUID) {
        openWindow(value: id)
    }

    private func edit(_ profile: ConnectionProfile) {
        editor = EditorRequest(profile: profile, password: store.password(for: profile.id))
    }

    private func newConnection(_ kind: DatabaseKind, group: UUID? = nil, pick: Bool = false) {
        if pick {
            showingEnginePicker = true
            return
        }
        let groupID = group ?? selectedGroupID
        let profile = ConnectionProfile(
            name: "", kind: kind, host: kind.isFileBased ? "" : "127.0.0.1", port: kind.defaultPort,
            username: kind.family == .postgres ? "postgres" : kind.family == .mysql ? "root" : "",
            groupID: groupID)
        // Let the engine picker close first.
        DispatchQueue.main.async { editor = EditorRequest(profile: profile, isNew: true) }
    }

    /// The group of the selected row, so "+" adds to it.
    private var selectedGroupID: UUID? {
        for tag in selection {
            if let group = groupFor(tag: tag) { return group.id }
            if let id = UUID(uuidString: tag), let groupID = store.profile(id: id)?.groupID { return groupID }
        }
        return nil
    }

    private func newGroup() {
        let group = ConnectionGroup(name: "New Group")
        DispatchQueue.main.async { groupEditor = group }
    }

    private func exportGroup(_ group: ConnectionGroup) {
        exportRequest = ExportConnectionsRequest(
            title: "Export “\(group.name)”", ids: Set(connections(in: group.id).map(\.id)), fileName: group.name)
    }

    private func exportConnection(_ profile: ConnectionProfile) {
        exportRequest = ExportConnectionsRequest(
            title: "Export “\(profile.name)”", ids: [profile.id], fileName: profile.name)
    }

    private func exportConnections(
        _ request: ExportConnectionsRequest, includePasswords: Bool, includeSSH: Bool, password: String
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = request.fileName + ".tableroad"
        panel.allowedContentTypes = [UTType(filenameExtension: "tableroad") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bundle = store.bundle(
                for: request.ids, includePasswords: includePasswords, includeSSHPasswords: includeSSH)
            try ConnectionFile.encode(bundle, password: password).write(to: url, options: .atomic)
        } catch {
            alert = error.localizedDescription
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import connections from a .tableroad file"
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            if try ConnectionFile.isEncrypted(data) {
                importData = data
            } else {
                try importBundle(data, password: nil)
            }
        } catch {
            alert = (error as? ConnectionFileError)?.description ?? error.localizedDescription
        }
    }

    private func importBundle(_ data: Data, password: String?) throws {
        let imported = try store.importBundle(ConnectionFile.decode(data, password: password))
        selection = Set(imported.map(\.id.uuidString))
    }

    private struct ImportFileRequest: Identifiable {
        let id = UUID()
        let data: Data
    }
}

/// Engine badge: coloured circle with a two-letter abbreviation.
struct EngineBadge: View {
    let kind: DatabaseKind
    var size: CGFloat = 30

    var body: some View {
        Circle()
            .fill(Color(hex: kind.badgeColor))
            .frame(width: size, height: size)
            .overlay {
                Text(kind.badge)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}

struct ConnectionRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 10) {
            EngineBadge(kind: profile.kind, size: 28)
                .overlay(alignment: .bottomTrailing) {
                    if let accent = profile.displayAccent {
                        Circle().fill(accent).frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .help("\(profile.kind.displayName) · \(subtitle)")
    }

    private var subtitle: String {
        if profile.kind.isFileBased { return profile.host }
        var parts = ["\(profile.host)"]
        if let database = profile.database { parts.append(database) }
        if profile.ssh != nil { parts.append("via SSH") }
        return parts.joined(separator: " : ")
    }
}

/// A group's icon: SF Symbol or a picked image.
struct GroupIconView: View {
    let icon: ConnectionGroup.Icon
    var size: CGFloat = 26

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.55))
                .foregroundStyle(Brand.amber)
                .frame(width: size, height: size)
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                Image(systemName: "folder.fill").frame(width: size, height: size)
            }
        }
    }
}

// MARK: - Sheets

/// TablePlus-style grid of engines with search.
struct EnginePickerSheet: View {
    var onCreate: (DatabaseKind) -> Void
    var onImport: () -> Void
    var onNewGroup: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: DatabaseKind = .mysql

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain).onSubmit(create)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.primary.opacity(0.06), in: Capsule())
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 8), count: 6), spacing: 10) {
                    ForEach(kinds) { kind in
                        Button {
                            selection = kind
                        } label: {
                            VStack(spacing: 6) {
                                EngineBadge(kind: kind, size: 44)
                                Text(kind.displayName).font(.callout).multilineTextAlignment(.center)
                                    .lineLimit(2).frame(height: 32, alignment: .top)
                                if !kind.isAvailable {
                                    Text("Coming soon").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(6)
                            .frame(width: 104)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selection == kind ? Color.accentColor : .clear, lineWidth: 2)
                            )
                            .opacity(kind.isAvailable ? 1 : 0.45)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { if kind.isAvailable { create() } })
                    }
                }
                .padding(4)
            }
            .frame(height: 400)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import Connection") {
                    dismiss()
                    DispatchQueue.main.async(execute: onImport)
                }
                Button("New Group") {
                    dismiss()
                    onNewGroup()
                }
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!selection.isAvailable)
            }
        }
        .padding(20)
        .frame(width: 720)
        .onChange(of: search) { if let first = kinds.first(where: \.isAvailable) ?? kinds.first { selection = first } }
    }

    private var kinds: [DatabaseKind] {
        let all = DatabaseKind.allCases.sorted { ($0.isAvailable ? 0 : 1) < ($1.isAvailable ? 0 : 1) }
        guard !search.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    private func create() {
        guard selection.isAvailable else { return }
        dismiss()
        onCreate(selection)
    }
}

/// Name and icon for a group.
struct GroupEditorSheet: View {
    @State var group: ConnectionGroup
    var onSave: (ConnectionGroup) -> Void
    @Environment(\.dismiss) private var dismiss

    static let symbols = [
        "folder.fill", "server.rack", "cloud.fill", "building.2.fill", "briefcase.fill", "house.fill",
        "hammer.fill", "flask.fill", "cart.fill", "shippingbox.fill", "globe", "lock.fill", "star.fill",
        "bolt.fill", "leaf.fill", "person.2.fill",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Group").font(.headline)
            HStack(spacing: 12) {
                GroupIconView(icon: group.icon, size: 44)
                TextField("Name", text: $group.name).textFieldStyle(.roundedBorder)
            }
            Text("Icon").font(.callout)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { name in
                    Button {
                        group.icon = .symbol(name)
                    } label: {
                        GroupIconView(icon: .symbol(name), size: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(
                                    group.icon == .symbol(name) ? Color.accentColor.opacity(0.2) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Choose Image…", action: chooseImage)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(group)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(group.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Any image, scaled down to 128 px PNG (kept small inside connections.json).
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        let side: CGFloat = 128
        let resized = NSImage(size: NSSize(width: side, height: side))
        resized.lockFocus()
        let scale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(
            in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        group.icon = .image(png)
    }
}

/// Export options: which secrets to include and the file's password (required when including secrets).
struct ExportConnectionsSheet: View {
    let request: WelcomeView.ExportConnectionsRequest
    var onExport: (_ includePasswords: Bool, _ includeSSH: Bool, _ password: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var includePasswords = true
    @State private var includeSSH = true
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.headline)
            Toggle("Include database passwords", isOn: $includePasswords)
            Toggle("Include server (SSH) passwords", isOn: $includeSSH)
            Text("Enter a password to secure the file").font(.callout)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            Text(
                needsPassword
                    ? "Passwords are only exported in an encrypted file. SSH/SSL private keys aren't included."
                    : "Without a password, the file contains no passwords. SSH/SSL private keys aren't included."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save…") {
                    dismiss()
                    let values = (includePasswords, includeSSH, password)
                    DispatchQueue.main.async { onExport(values.0, values.1, values.2) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(needsPassword && password.isEmpty)
            }
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(width: 400)
    }

    private var needsPassword: Bool { includePasswords || includeSSH }
}

struct ImportPasswordSheet: View {
    var onImport: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This file is protected").font(.headline)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).onSubmit(importFile)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import", action: importFile).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func importFile() {
        do {
            try onImport(password)
            dismiss()
        } catch {
            self.error = (error as? ConnectionFileError)?.description ?? error.localizedDescription
        }
    }
}

struct ImportURLSheet: View {
    var onImport: (ConnectionURL.Parsed) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from URL").font(.headline)
            TextField("mysql://user:password@host:3306/database", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(width: 440)
                .onSubmit(importURL)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Continue", action: importURL)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty)
            }
        }
        .padding(20)
    }

    private func importURL() {
        do {
            let parsed = try ConnectionURL.parse(text)
            dismiss()
            // Open the form after this sheet has gone so the user can review before saving.
            DispatchQueue.main.async { onImport(parsed) }
        } catch {
            self.error = "That doesn't look like a supported connection URL."
        }
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

#if DEBUG
    #Preview("Welcome – connections") {
        WelcomeView().environment(PreviewData.store())
            .environment(BackupScheduler.preview())
            .environment(WelcomeRouter())
    }

    #Preview("Welcome – backups") {
        let router = WelcomeRouter()
        router.mode = .backups
        let scheduler = BackupScheduler.preview()
        router.selectedScheduleID = scheduler.store.schedules.first?.id
        return WelcomeView().environment(PreviewData.store())
            .environment(scheduler)
            .environment(router)
    }

    #Preview("Welcome – empty") {
        WelcomeView().environment(PreviewData.store(empty: true))
            .environment(BackupScheduler.preview())
            .environment(WelcomeRouter())
    }

    #Preview("Engine picker") {
        EnginePickerSheet(onCreate: { _ in }, onImport: {}, onNewGroup: {})
    }

    #Preview("Group editor") {
        GroupEditorSheet(group: ConnectionGroup(name: "Clients")) { _ in }
    }

    #Preview("Export connections") {
        ExportConnectionsSheet(
            request: .init(title: "Export All Connections", ids: nil, fileName: "Connections")
        ) { _, _, _ in }
    }

    #Preview("Import password") {
        ImportPasswordSheet { _ in }
    }

    #Preview("Import from URL") {
        ImportURLSheet { _ in }
    }
#endif
