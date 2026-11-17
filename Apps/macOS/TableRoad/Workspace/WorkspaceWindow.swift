import SwiftUI
import TableRoadCore
import TableRoadDesign
import TableRoadStorage

/// The workspaces open in one window (connections or databases), like TablePlus's left-hand rail. The window owns
/// their connections: switching between them keeps every one connected; closing one disconnects it.
@MainActor @Observable
final class WorkspaceWindowModel {
    private(set) var workspaces: [WorkspaceModel] = []
    var selectedID: WorkspaceModel.ID?

    init(first: WorkspaceModel) {
        workspaces = [first]
        selectedID = first.id
    }

    var selected: WorkspaceModel? {
        workspaces.first { $0.id == selectedID } ?? workspaces.first
    }

    /// Adds a workspace, starts connecting it, and switches to it.
    func add(_ workspace: WorkspaceModel) {
        workspaces.append(workspace)
        selectedID = workspace.id
        Task { await workspace.connectIfNeeded() }
    }

    /// Closes a workspace, disconnecting it. The window keeps at least one.
    func close(_ id: WorkspaceModel.ID) {
        guard workspaces.count > 1, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let workspace = workspaces.remove(at: index)
        if selectedID == id { selectedID = workspaces[min(index, workspaces.count - 1)].id }
        Task { await workspace.disconnect() }
    }

    /// Selects the next (or previous) workspace, wrapping around.
    func cycle(by offset: Int) {
        guard workspaces.count > 1, let index = workspaces.firstIndex(where: { $0.id == selected?.id }) else {
            return
        }
        selectedID = workspaces[(index + offset + workspaces.count) % workspaces.count].id
    }

    func disconnectAll() {
        for workspace in workspaces { Task { await workspace.disconnect() } }
    }
}

/// A workspace window: the selected workspace, with the rail on the left once there's more than one.
struct WorkspaceWindowView: View {
    @State private var window: WorkspaceWindowModel
    @Environment(WorkspaceRegistry.self) private var registry
    @Environment(ConnectionStore.self) private var store

    init(profile: ConnectionProfile, password: String?) {
        _window = State(initialValue: WorkspaceWindowModel(first: WorkspaceModel(profile: profile, password: password)))
    }

    /// Uses existing workspaces (previews pass ones that are already "connected", so nothing hits the network).
    init(window: WorkspaceWindowModel) {
        _window = State(initialValue: window)
    }

    var body: some View {
        Group {
            if let workspace = window.selected {
                // A fresh view per workspace: its sidebar, tabs and toolbar belong to that workspace.
                WorkspaceView(model: workspace, window: window)
                    .id(workspace.id)
            }
        }
        .environment(window)
        .focusedSceneValue(\.workspaceWindow, window)
        .task {
            #if DEBUG
                // TABLEROAD_OPEN_ALSO=<connection name>: open a second workspace in this window (for testing).
                if let name = DevFixtures.environment["TABLEROAD_OPEN_ALSO"], window.workspaces.count == 1,
                    let profile = store.profiles.first(where: { $0.name == name })
                {
                    let current = window.workspaces[0].id
                    window.add(WorkspaceModel(profile: profile, password: store.password(for: profile.id)))
                    window.selectedID = current
                }
            #endif
        }
        .onDisappear {
            for workspace in window.workspaces { registry.unregister(workspace) }
            window.disconnectAll()
        }
    }
}

extension FocusedValues {
    /// The frontmost workspace window (for the File menu's workspace commands).
    @Entry var workspaceWindow: WorkspaceWindowModel?
}

/// File menu: open a connection in the front window, switch and close workspaces.
struct WorkspaceMenuButtons: View {
    @FocusedValue(\.workspaceWindow) private var window
    @Environment(ConnectionStore.self) private var store

    var body: some View {
        Menu("Open Connection in This Window") {
            ForEach(store.profiles.filter { $0.kind != .redis }) { profile in
                Button(profile.name) {
                    window?.add(WorkspaceModel(profile: profile, password: store.password(for: profile.id)))
                }
            }
        }
        .disabled(window == nil)
        Button("Next Workspace") { window?.cycle(by: 1) }
            .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            .disabled((window?.workspaces.count ?? 0) < 2)
        Button("Previous Workspace") { window?.cycle(by: -1) }
            .keyboardShortcut(.upArrow, modifiers: [.command, .control])
            .disabled((window?.workspaces.count ?? 0) < 2)
        Button("Close Workspace") { if let id = window?.selected?.id { window?.close(id) } }
            .keyboardShortcut("w", modifiers: [.command, .control])
            .disabled((window?.workspaces.count ?? 0) < 2)
    }
}

/// The left-hand rail: one entry per workspace (engine badge and database), and + to open another.
struct WorkspaceRail: View {
    let window: WorkspaceWindowModel
    /// The workspace showing the rail (its connection is offered for "another database").
    let current: WorkspaceModel
    @Environment(ConnectionStore.self) private var store
    @State private var choosingDatabase = false

    var body: some View {
        VStack(spacing: 4) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(window.workspaces) { workspace in
                        RailItem(workspace: workspace, isSelected: workspace.id == window.selected?.id)
                            .onTapGesture { window.selectedID = workspace.id }
                            .contextMenu {
                                Button("Close") { window.close(workspace.id) }
                                    .disabled(window.workspaces.count < 2)
                            }
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            addMenu
                .padding(.bottom, 10)
        }
        .frame(width: 72)
        // The sidebar runs up behind the title bar: start the tint and divider below it, clear of the window buttons.
        .background {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Color.primary.opacity(0.03)
                    Divider()
                }
                .padding(.top, proxy.safeAreaInsets.top)
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $choosingDatabase) {
            DatabasePickerSheet(
                model: current,
                onOpenInNewWorkspace: { database in
                    window.add(current.sibling(database: database))
                })
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Another \(noun.capitalized) of \(current.profile.name)…") { choosingDatabase = true }
            Divider()
            let profiles = store.profiles.filter { $0.kind != .redis }
            let ungrouped = profiles.filter { profile in !store.groups.contains { $0.id == profile.groupID } }
            ForEach(ungrouped) { profile in connectionButton(profile) }
            ForEach(store.groups) { group in
                let members = profiles.filter { $0.groupID == group.id }
                if !members.isEmpty {
                    Section(group.name) {
                        ForEach(members) { profile in connectionButton(profile) }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .frame(width: 30, height: 26)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open another connection or database in this window")
    }

    private func connectionButton(_ profile: ConnectionProfile) -> some View {
        Button {
            window.add(WorkspaceModel(profile: profile, password: store.password(for: profile.id)))
        } label: {
            Text(profile.name)
            Text("\(profile.kind.displayName) · \(profile.host)")
        }
    }

    private var noun: String { current.session?.capabilities.databaseNoun ?? "database" }
}

private struct RailItem: View {
    let workspace: WorkspaceModel
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                EngineBadge(kind: workspace.profile.kind, size: 28)
                if let color = workspace.profile.statusColor.swatch {
                    Circle().fill(color).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                }
            }
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 62, height: 58)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .help("\(workspace.profile.name)\(workspace.selectedDatabase.map { " · \($0)" } ?? "")")
    }

    /// The database it's showing, or the connection's name before it has connected.
    private var title: String {
        workspace.selectedDatabase ?? workspace.profile.name
    }
}

#if DEBUG
    #Preview("Workspace window – two workspaces") {
        let first = WorkspaceModel.preview()
        let window = WorkspaceWindowModel(first: first)
        window.add(WorkspaceModel.preview(selectQueryTab: true))
        return WorkspaceWindowView(window: window)
            .environment(PreviewData.store())
            .environment(WorkspaceRegistry())
            .environment(PreviewData.savedQueries())
            .environment(PreviewData.history())
            .frame(width: 1200, height: 700)
    }

    #Preview("Rail") {
        let first = WorkspaceModel.preview()
        let window = WorkspaceWindowModel(first: first)
        window.add(WorkspaceModel.preview())
        return WorkspaceRail(window: window, current: first)
            .environment(PreviewData.store())
            .frame(height: 400)
    }
#endif
