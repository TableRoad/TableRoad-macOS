import SwiftUI
import TableRoadCore
import TableRoadDesign

/// The per-connection window: database/table sidebar, tab strip, and the selected tab.
struct WorkspaceView: View {
    @State private var model: WorkspaceModel
    @State private var tableFilter = ""

    init(profile: ConnectionProfile, password: String?) {
        _model = State(initialValue: WorkspaceModel(profile: profile, password: password))
    }

    var body: some View {
        Group {
            switch model.state {
            case .connecting:
                ProgressView("Connecting to \(model.profile.name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Connect", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { Task { await model.connect() } }
                }
            case .connected:
                connected
            }
        }
        .navigationTitle(model.profile.name)
        .navigationSubtitle(subtitle)
        .task { await model.connect() }
        .onDisappear { Task { await model.disconnect() } }
    }

    private var subtitle: String {
        guard model.state == .connected else { return model.profile.kind.displayName }
        return "\(model.serverVersion) · \(model.profile.host)" + (model.isEncrypted ? " · TLS" : "")
    }

    private var connected: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if let color = model.profile.tag.color {
                    color.frame(height: 3)
                }
                ConnectionBanner(model: model)
                TabStrip(model: model)
                Divider()
                tabContent
            }
            // Attached to the whole detail column (Apple's recommended placement). Wrapping only the grid made
            // macOS 26 draw the toolbar's edge blur over the grid's header and first row when the inspector was closed.
            .inspector(isPresented: $model.isInspectorVisible) {
                inspectorContent
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 600)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.newQueryTab()
                } label: {
                    Label("New Query", systemImage: "plus.rectangle.on.rectangle")
                }
                .keyboardShortcut("t")
                .help("New query tab (⌘T)")
            }
            ToolbarItem {
                Button {
                    model.isInspectorVisible.toggle()
                } label: {
                    Label("Row Inspector", systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the row inspector (⌥⌘I)")
            }
            ToolbarItem {
                if model.isEncrypted {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help("TLS-encrypted connection")
                } else {
                    Image(systemName: "lock.open").foregroundStyle(.orange).help("Unencrypted connection")
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Database", selection: $model.selectedDatabase) {
                ForEach(model.databases, id: \.self) { database in
                    Text(database).tag(Optional(database))
                }
            }
            .labelsHidden()
            .padding(8)

            TextField("Filter tables", text: $tableFilter)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .bottom], 8)

            if let error = model.tablesError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
            List(filteredTables) { table in
                Button {
                    model.open(table: table)
                } label: {
                    // No row-count badge: InnoDB's TABLE_ROWS estimate is often wildly stale.
                    Label(table.name, systemImage: table.kind == .table ? "tablecells" : "eye")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }

    private var filteredTables: [TableInfo] {
        tableFilter.isEmpty
            ? model.tables : model.tables.filter { $0.name.localizedCaseInsensitiveContains(tableFilter) }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch model.selectedTab?.content {
        case .table(let browser):
            RowInspectorView(row: browser.inspectorRow, editing: browser.inspectorEditing)
        case .query(let editor):
            RowInspectorView(row: editor.inspectorRow, editing: nil)
        case nil:
            RowInspectorView(row: nil, editing: nil)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if let tab = model.selectedTab {
            switch tab.content {
            case .table(let browser):
                TableBrowserView(model: browser, showInspector: { model.isInspectorVisible = true })
                    .id(tab.id)
            case .query(let editor):
                QueryEditorView(model: editor)
                    .id(tab.id)
            }
        } else {
            ContentUnavailableView(
                "No Tab Open", systemImage: "tablecells",
                description: Text("Pick a table from the sidebar, or press ⌘T for a query."))
        }
    }
}

/// Browser-style tabs above the content.
struct TabStrip: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(model.tabs) { tab in
                    let selected = tab.id == model.selectedTabID
                    HStack(spacing: 6) {
                        Image(systemName: tab.systemImage).font(.caption)
                        Text(tab.title).lineLimit(1)
                        Button {
                            model.close(tab.id)
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
                    .overlay(alignment: .bottom) {
                        if selected { Brand.amber.frame(height: 2) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedTabID = tab.id }
                }
            }
        }
        .frame(height: 30)
        .background(.bar)
        .background {
            // ⌘W closes the selected tab instead of the window while tabs are open.
            Button("") { if let id = model.selectedTabID { model.close(id) } }
                .keyboardShortcut("w")
                .disabled(model.tabs.isEmpty)
                .hidden()
        }
    }
}

/// Shows the main connection's health: reconnecting, given up (with Reconnect), or briefly "reconnected".
private struct ConnectionBanner: View {
    let model: WorkspaceModel

    var body: some View {
        switch model.link {
        case .ok:
            EmptyView()
        case .reconnecting(let attempt, let lastError):
            banner(color: .orange) {
                ProgressView().controlSize(.small)
                Text("Connection lost. Reconnecting (attempt \(attempt) of \(WorkspaceModel.reconnectDelays.count))…")
                if !lastError.isEmpty {
                    Text(lastError).foregroundStyle(.secondary).lineLimit(1).help(lastError)
                }
                Spacer()
                Button("Retry Now") { model.reconnectNow() }
            }
        case .lost(let error):
            banner(color: .red) {
                Image(systemName: "bolt.horizontal.circle.fill")
                Text("Disconnected.")
                Text(error).foregroundStyle(.secondary).lineLimit(1).help(error)
                Spacer()
                Button("Reconnect") { model.reconnectNow() }
                    .buttonStyle(.borderedProminent)
            }
        case .restored:
            banner(color: .green) {
                Image(systemName: "checkmark.circle.fill")
                Text("Reconnected.")
                Spacer()
            }
        }
    }

    private func banner(color: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.14))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
