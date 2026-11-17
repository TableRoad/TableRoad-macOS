import SwiftUI
import TableRoadCore
import TableRoadDesign
import TableRoadStorage

/// One workspace: database/table sidebar, tab strip, and the selected tab. Inside a `WorkspaceWindowView` it also
/// shows the window's workspace rail when there's more than one.
struct WorkspaceView: View {
    @State private var model: WorkspaceModel
    /// The window holding this workspace (nil in previews of a lone workspace).
    var window: WorkspaceWindowModel?
    @Environment(WorkspaceRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow
    @Environment(QueryHistoryStore.self) private var history
    @State private var savingQuery: QueryEditorModel?
    @State private var showingDatabases = false
    @State private var toolbarMetrics = ToolbarMetrics()

    /// Uses an existing model (previews pass one that's already "connected", so nothing hits the network).
    init(model: WorkspaceModel, window: WorkspaceWindowModel? = nil) {
        _model = State(initialValue: model)
        self.window = window
    }

    var body: some View {
        Group {
            switch model.state {
            case .connecting:
                ProgressView("Connecting to \(model.profile.name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsPassword(let error):
                PasswordPromptView(model: model, error: error)
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
        // The title stays for the Window menu and Mission Control, but isn't drawn: the toolbar pill shows it.
        .navigationTitle(model.profile.name)
        .toolbar(removing: .title)
        .task { await model.connectIfNeeded() }
        .onAppear {
            registry.register(model)
            let history = history
            model.recordHistory = { history.record($0) }
        }
        .onDisappear {
            // In a window, switching workspaces hides this view without closing it: the window disconnects.
            guard window == nil else { return }
            registry.unregister(model)
            Task { await model.disconnect() }
        }
    }

    /// The toolbar's free space, measured from where the toolbar actually placed the pill and the right-hand
    /// buttons (see ToolbarMetrics). Too wide pushes the pill and everything after it into the overflow menu.
    private var pillWidth: CGFloat {
        toolbarMetrics.pillWidth
    }

    private var trailingButtonCount: Int {
        2 + (model.supportsProcessList ? 1 : 0) + (model.profile.kind.isFileBased ? 0 : 1)
    }

    private var connected: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: showsRail ? 272 : 200, ideal: showsRail ? 312 : 240, max: showsRail ? 472 : 400)
        } detail: {
            VStack(spacing: 0) {
                if let color = model.profile.displayAccent {
                    color.frame(height: 3)
                }
                ConnectionBanner(model: model)
                if !model.tabs.isEmpty {
                    TabStrip(model: model)
                    Divider()
                }
                tabContent
            }
            // Attached to the whole detail column (Apple's recommended placement). Wrapping only the grid made
            // macOS 26 draw the toolbar's edge blur over the grid's header and first row when the inspector was closed.
            .inspector(isPresented: $model.isInspectorVisible) {
                inspectorContent
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 600)
            }
            // Measured with the inspector included: the toolbar spans both.
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                toolbarMetrics.detailWidth = $0
            }
        }
        .sheet(isPresented: $showingDatabases) {
            DatabasePickerSheet(
                model: model,
                onOpenInNewWorkspace: window.map { window in
                    { database in window.add(model.sibling(database: database)) }
                })
        }
        .sheet(item: $savingQuery) { editor in
            SaveQuerySheet(editor: editor, connectionID: model.profile.id)
        }
        .sheet(item: $model.transfer) { request in
            switch request {
            case .export, .exportColumns: ExportSheet(model: model, request: request)
            case .importDump: ImportDumpSheet(model: model)
            }
        }
        .background {
            // ⇧⌘E: export the tables selected in the sidebar (or the open table).
            Button("") {
                var names = model.sidebarSelection
                if names.isEmpty, case .table(let browser) = model.selectedTab?.content { names = [browser.table] }
                model.transfer = .export(names)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .hidden()
        }
        .toolbar {
            // Next to the sidebar toggle, like TablePlus.
            ToolbarItem(placement: .navigation) {
                Button {
                    showingDatabases = true
                } label: {
                    Label("Databases", systemImage: "cylinder.split.1x2")
                }
                .keyboardShortcut("k")
                .help("Open, create or drop a database (⌘K) · current: \(model.selectedDatabase ?? "none")")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    model.newQueryTab()
                } label: {
                    Label("New Query", systemImage: "plus.rectangle.on.rectangle")
                }
                .keyboardShortcut("t")
                .help("New query tab (⌘T)")
            }
            // Leading (not centred) so it starts right after the database button and runs to the right-hand group.
            ToolbarItem(placement: .navigation) {
                ConnectionPillView(model: model, width: pillWidth)
                    .measuringToolbarPill(toolbarMetrics)
                    .onAppear { toolbarMetrics.trailingCount = trailingButtonCount }
                    .onChange(of: trailingButtonCount) { toolbarMetrics.trailingCount = $1 }
            }
            // macOS 26 wraps toolbar items in its own glass capsule; hide it so the pill's colour fills the shape.
            .hidingSharedBackground()
            ToolbarItem {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Reload tables, databases and open tabs, e.g. after changes made elsewhere (⇧⌘R)")
                .measuringToolbarButton("refresh", in: toolbarMetrics)
            }
            ToolbarItem {
                if model.supportsProcessList {
                    Button {
                        openWindow(id: "running-queries", value: model.profile.id)
                    } label: {
                        Label("Running Queries", systemImage: "list.bullet.rectangle")
                    }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .help("Show running queries and kill stuck ones (⌥⌘P)")
                    .measuringToolbarButton("processes", in: toolbarMetrics)
                }
            }
            ToolbarItem {
                Button {
                    model.isInspectorVisible.toggle()
                } label: {
                    Label("Row Inspector", systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the row inspector (⌥⌘I)")
                .measuringToolbarButton("inspector", in: toolbarMetrics)
            }
            ToolbarItem {
                // A real button (not a bare image) so the toolbar gives it standard spacing.
                // A local file has no network connection to encrypt.
                if !model.profile.kind.isFileBased {
                    EncryptionButton(isEncrypted: model.isEncrypted, cipher: model.tlsCipher)
                        .measuringToolbarButton("encryption", in: toolbarMetrics)
                }
            }
        }
    }

    private var showsRail: Bool { (window?.workspaces.count ?? 0) > 1 }

    @ViewBuilder
    private var sidebar: some View {
        if let window, showsRail {
            HStack(spacing: 0) {
                WorkspaceRail(window: window, current: model)
                SidebarView(model: model)
            }
        } else {
            SidebarView(model: model)
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch model.selectedTab?.content {
        case .table(let browser):
            // A selected row shows its fields; otherwise (or on the definition panes) the table's details.
            if browser.pane == .data, let row = browser.inspectorRow {
                RowInspectorView(row: row, editing: browser.inspectorEditing)
            } else {
                TableDetailsView(model: browser)
            }
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
                TableBrowserView(
                    model: browser, showInspector: { model.isInspectorVisible = true },
                    onFollowForeignKey: { model.follow($0) }
                )
                .id(tab.id)
            case .query(let editor):
                QueryEditorView(model: editor, onSaveQuery: { savingQuery = editor })
                    .id(tab.id)
            }
        } else {
            ContentUnavailableView(
                "No Tab Open", systemImage: "tablecells",
                description: Text("Pick a table from the sidebar, or press ⌘T for a query.")
            )
            // Fill the column, or the stripe and tab strip above float to the middle of the window.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ToolbarContent {
    /// Removes macOS 26's glass capsule behind a toolbar item (no-op on earlier systems, which don't draw one).
    @ToolbarContentBuilder
    func hidingSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Padlock showing whether the connection is TLS-encrypted; click for the cipher.
private struct EncryptionButton: View {
    let isEncrypted: Bool
    let cipher: String?
    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails.toggle()
        } label: {
            Label(
                isEncrypted ? "Encrypted" : "Not Encrypted", systemImage: isEncrypted ? "lock.fill" : "lock.open"
            )
            .foregroundStyle(isEncrypted ? Color.secondary : Color.orange)
        }
        .help(isEncrypted ? "TLS-encrypted connection" : "Unencrypted connection")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    isEncrypted ? "TLS-encrypted connection" : "Unencrypted connection",
                    systemImage: isEncrypted ? "lock.fill" : "lock.open"
                )
                .font(.headline)
                .foregroundStyle(isEncrypted ? Color.primary : Color.orange)
                if let cipher {
                    Text(cipher).font(.callout.monospaced()).textSelection(.enabled)
                } else {
                    Text("Data, including passwords in queries, is sent in plain text.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}

/// Browser-style tabs above the content.
struct TabStrip: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        tabs
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

    private var tabs: some View {
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

#if DEBUG
    #Preview("Workspace – table tab") {
        WorkspaceView(model: .preview())
            .environment(WorkspaceRegistry())
            .environment(PreviewData.store())
            .environment(PreviewData.savedQueries())
            .environment(PreviewData.history())
            .frame(width: 1100, height: 700)
    }

    #Preview("Workspace – query tab") {
        WorkspaceView(model: .preview(selectQueryTab: true))
            .environment(WorkspaceRegistry())
            .environment(PreviewData.store())
            .environment(PreviewData.savedQueries())
            .environment(PreviewData.history())
            .frame(width: 1100, height: 700)
    }

    #Preview("Workspace – reconnecting") {
        WorkspaceView(model: .preview(link: .reconnecting(attempt: 2, lastError: "Connection refused (errno: 61)")))
            .environment(WorkspaceRegistry())
            .environment(PreviewData.store())
            .environment(PreviewData.savedQueries())
            .environment(PreviewData.history())
            .frame(width: 1100, height: 700)
    }

    #Preview("Connection banners") {
        VStack(spacing: 0) {
            ConnectionBanner(model: .preview(link: .reconnecting(attempt: 3, lastError: "Connection refused")))
            ConnectionBanner(model: .preview(link: .lost("Couldn't connect: host unreachable")))
            ConnectionBanner(model: .preview(link: .restored))
        }
        .frame(width: 800)
    }

    #Preview("Tab strip") {
        TabStrip(model: .preview())
            .frame(width: 600)
    }
#endif
