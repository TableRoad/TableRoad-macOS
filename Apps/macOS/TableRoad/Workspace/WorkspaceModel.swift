import Foundation
import Observation
import TableRoadCore
import TableRoadDrivers
import TableRoadSQL
import TableRoadStorage

/// One connection window: the session, the database list and the open tabs.
@MainActor @Observable
final class WorkspaceModel {
    enum State: Equatable {
        case connecting
        /// "Ask every time" password: waiting for the user (with the previous attempt's error, if any).
        case needsPassword(String?)
        case connected
        case failed(String)
    }

    /// Replaced when the connection is edited from the workspace.
    private(set) var profile: ConnectionProfile
    private var password: String?
    private(set) var state: State = .connecting
    /// Health of the main (browsing) connection once connected.
    private(set) var link: LinkStatus = .ok

    enum LinkStatus: Equatable {
        case ok
        /// Lost; retrying automatically.
        case reconnecting(attempt: Int, lastError: String)
        /// Gave up retrying; waiting for the user.
        case lost(String)
        /// Briefly shown after a successful reconnect.
        case restored
    }

    /// Delays between automatic reconnect attempts; after the last one the user must press Reconnect.
    static let reconnectDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30),
    ]
    private var reconnectTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private(set) var session: (any SQLClient)?
    private(set) var serverVersion = ""
    private(set) var isEncrypted = false
    private(set) var tlsCipher: String?

    private(set) var databases: [String] = []
    var selectedDatabase: String? {
        didSet {
            guard oldValue != selectedDatabase else { return }
            Task { await loadTables() }
            for case .query(let editor) in tabs.map(\.content) { editor.database = selectedDatabase }
        }
    }
    private(set) var tables: [TableInfo] = []
    private(set) var tablesError: String?

    var tabs: [WorkspaceTab] = []
    /// Row inspector visibility, shared by all tabs in the window.
    var isInspectorVisible = false
    var selectedTabID: WorkspaceTab.ID?

    init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        self.password = password
    }

    func connect() async {
        if profile.passwordStorage == .askEachTime && password == nil {
            state = .needsPassword(nil)
            return
        }
        state = .connecting
        do {
            let session = try await makeSession()
            self.session = session
            serverVersion = await session.serverVersion
            isEncrypted = session.isEncrypted
            tlsCipher = session.tlsCipher
            databases = try await session.databases()
            state = .connected
            selectedDatabase = await session.currentDatabase ?? databases.first { !Self.systemDatabases.contains($0) }
            // Like TablePlus, a connection opens with no tabs: pick a table, or ⌘T for a query.
            startKeepAlive()
            #if DEBUG
                await loadTables()
                if let name = DevFixtures.openTable, let table = tables.first(where: { $0.name == name }) {
                    open(table: table)
                }
                if DevFixtures.runSQL != nil { newQueryTab() }
                if let sql = DevFixtures.runSQL, case .query(let editor) = tabs.last?.content {
                    editor.text = sql
                    selectedTabID = tabs.last?.id
                    if DevFixtures.environment["TABLEROAD_RUN_SQL_NOW"] != "0" { Task { await editor.run() } }
                }
            #endif
        } catch {
            if profile.passwordStorage == .askEachTime, (error as? DatabaseError)?.category == .authentication {
                password = nil
                state = .needsPassword(error.localizedDescription)
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Connects with a password typed at the prompt ("ask every time" connections). Kept in memory for this window.
    func connect(withPassword typed: String) async {
        password = typed
        await connect()
    }

    /// Applies settings edited from the workspace and reconnects everything with them.
    func apply(edited: ConnectionProfile, password newPassword: String?) {
        profile = edited
        if edited.passwordStorage == .keychain { password = newPassword }
        reconnectAll()
    }

    /// Fresh main connection; query tabs drop theirs and reopen on their next run with current settings.
    func reconnectAll() {
        guard state == .connected else {
            Task { await connect() }
            return
        }
        link = .reconnecting(attempt: 1, lastError: "")
        reconnectTask?.cancel()
        reconnectTask = Task {
            for case .query(let editor) in tabs.map(\.content) { await editor.close() }
            await reconnectLoop(firstError: "")
        }
    }

    func disconnect() async {
        reconnectTask?.cancel()
        keepAliveTask?.cancel()
        for case .query(let editor) in tabs.map(\.content) { await editor.close() }
        await session?.close()
        session = nil
    }

    /// Opens a connection with the current settings, off the main actor (export, import, query tabs).
    func connector() -> @Sendable () async throws -> any SQLClient {
        let profile = profile
        let password = password
        return { try await Drivers.connect(profile, password: password) }
    }

    /// Tables of any database (the export sheet lists other databases too).
    func tables(in database: String) async -> [TableInfo] {
        if database == selectedDatabase && !tables.isEmpty { return tables }
        return (try? await session?.tables(in: database)) ?? []
    }

    /// Tables selected in the sidebar (multi-select), and which transfer sheet is showing.
    var sidebarSelection: Set<String> = []
    var transfer: TransferRequest?

    /// Opens a connection with the current settings (the main one, each query tab's, and the process list's).
    func makeSession() async throws -> any SQLClient {
        try await connector()()
    }

    static let systemDatabases: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]

    // MARK: Reconnecting the main connection

    /// Called by anything that hit a connection error on the main session.
    func connectionLost(_ error: any Error) {
        guard state == .connected else { return }
        switch link {
        case .reconnecting: return  // already on it
        default: break
        }
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        link = .reconnecting(attempt: 1, lastError: message)
        reconnectTask?.cancel()
        reconnectTask = Task { await reconnectLoop(firstError: message) }
    }

    /// Manual retry after automatic attempts gave up.
    func reconnectNow() {
        reconnectTask?.cancel()
        link = .reconnecting(attempt: 1, lastError: "")
        reconnectTask = Task { await reconnectLoop(firstError: "") }
    }

    private func reconnectLoop(firstError: String) async {
        var lastError = firstError
        for (index, delay) in Self.reconnectDelays.enumerated() {
            link = .reconnecting(attempt: index + 1, lastError: lastError)
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            do {
                let fresh = try await makeSession()
                await adopt(fresh)
                link = .restored
                try? await Task.sleep(for: .seconds(3))
                if link == .restored { link = .ok }
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
        link = .lost(lastError)
    }

    /// Updates cosmetic settings (status colour) without reconnecting.
    func updateCosmetics(from edited: ConnectionProfile) {
        profile.statusColor = edited.statusColor
    }

    /// Swaps in a new main session and refreshes everything that used the old one.
    private func adopt(_ fresh: any SQLClient) async {
        let old = session
        session = fresh
        serverVersion = await fresh.serverVersion
        isEncrypted = fresh.isEncrypted
        tlsCipher = fresh.tlsCipher
        await old?.close()
        if let database = selectedDatabase { try? await fresh.useDatabase(database) }
        databases = (try? await fresh.databases()) ?? databases
        await loadTables()
        for case .table(let browser) in tabs.map(\.content) {
            browser.session = fresh
            // Pages with unsaved edits keep their data; everything else reloads.
            if !browser.hasChanges { browser.refresh() }
        }
    }

    /// Pings the main connection when idle: detects silent drops and keeps server idle timeouts at bay.
    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.link == .ok, let session = self.session else { continue }
                do {
                    _ = try await session.execute("SELECT 1")
                } catch let error as DatabaseError where error.category == .connection {
                    self.connectionLost(error)
                } catch {}
            }
        }
    }

    // MARK: Databases

    var canModifyDatabases: Bool {
        profile.safeMode != .readOnly && (session?.capabilities.createDatabases ?? true)
    }

    /// The server has a process list (not SQLite).
    var supportsProcessList: Bool { session?.capabilities.processList ?? true }

    func reloadDatabases() async {
        guard let session else { return }
        if let fresh = try? await session.databases() { databases = fresh }
    }

    func characterSets() async throws -> [CharacterSetInfo] {
        guard let session else { return [] }
        return try await session.characterSets()
    }

    /// Creates a database and switches to it.
    func createDatabase(_ name: String, characterSet: String?, collation: String?) async throws {
        guard let session else { throw DatabaseError(.connection, "Not connected.") }
        guard canModifyDatabases else { throw DatabaseError(.unsupported, "This connection is read-only.") }
        let sql = try session.sqlDialect.createDatabaseSQL(name, characterSet: characterSet, collation: collation)
        _ = try await session.execute(sql)
        await reloadDatabases()
        selectedDatabase = name.trimmingCharacters(in: .whitespaces)
    }

    /// Drops a database, closing its table tabs; if it was selected, switches to another one.
    func dropDatabase(_ name: String) async throws {
        guard let session else { throw DatabaseError(.connection, "Not connected.") }
        guard canModifyDatabases else { throw DatabaseError(.unsupported, "This connection is read-only.") }
        _ = try await session.execute(session.sqlDialect.dropDatabaseSQL(name))
        for tab in tabs {
            if case .table(let browser) = tab.content, browser.database == name { close(tab.id) }
        }
        await reloadDatabases()
        if selectedDatabase == name {
            selectedDatabase = databases.first { !Self.systemDatabases.contains($0) } ?? databases.first
        }
    }

    func loadTables() async {
        guard let session else { return }  // not connected (or a preview): keep what's shown
        guard let database = selectedDatabase else {
            tables = []
            return
        }
        sidebarColumns = [:]
        expandedTables = []
        sidebarSelection = []
        do {
            tables = try await session.tables(in: database)
            tablesError = nil
            try await session.useDatabase(database)
        } catch {
            if (error as? DatabaseError)?.category == .connection {
                connectionLost(error)
                return
            }
            tables = []
            tablesError = error.localizedDescription
        }
    }

    // MARK: Tabs

    func open(table: TableInfo) {
        guard let session, let database = selectedDatabase else { return }
        if let existing = tabs.first(where: { $0.tableKey == "\(database).\(table.name)" }) {
            selectedTabID = existing.id
            return
        }
        let browser = TableBrowserModel(
            session: session, database: database, table: table.name, safeMode: profile.safeMode, tag: profile.tag)
        browser.onConnectionLost = { [weak self] error in self?.connectionLost(error) }
        let tab = WorkspaceTab(content: .table(browser))
        tabs.append(tab)
        selectedTabID = tab.id
        Task { await browser.load() }
    }

    /// Opens a query tab, optionally pre-filled (from a saved query or the history).
    func newQueryTab(text: String = "", title: String? = nil, savedQueryID: UUID? = nil) {
        guard session != nil else { return }
        let count = tabs.filter { if case .query = $0.content { true } else { false } }.count
        let editor = QueryEditorModel(title: title ?? "Query \(count + 1)", database: selectedDatabase) {
            [weak self] in
            guard let self else { throw DatabaseError(.connection, "The window was closed.") }
            return try await self.makeSession()
        }
        editor.text = text
        editor.savedQueryID = savedQueryID
        editor.onRunFinished = { [weak self] statements, database in
            self?.recordRun(statements, database: database)
        }
        let tab = WorkspaceTab(content: .query(editor))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Set by the window to the query history store.
    var recordHistory: ([QueryHistoryEntry]) -> Void = { _ in }

    private func recordRun(_ statements: [QueryEditorModel.StatementResult], database: String?) {
        recordHistory(
            statements.map { statement in
                let (seconds, attoseconds) = statement.elapsed.components
                return QueryHistoryEntry(
                    connectionID: profile.id, database: database, sql: statement.sql,
                    durationMilliseconds: Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000),
                    succeeded: !statement.isFailure, summary: statement.summary)
            })
    }

    // MARK: Sidebar columns

    /// Columns of tables expanded in the sidebar, loaded on first expand (cleared when the database changes).
    private(set) var sidebarColumns: [String: [ColumnDetail]] = [:]
    var expandedTables: Set<String> = []

    func loadSidebarColumns(for table: String) async {
        guard sidebarColumns[table] == nil, let session, let database = selectedDatabase else { return }
        sidebarColumns[table] = (try? await session.columns(of: table, in: database)) ?? []
    }

    /// Server ids of this window's connections (browsing + query tabs).
    var appProcessIDs: Set<UInt64> {
        var ids: Set<UInt64> = []
        if let session { ids.insert(session.processID) }
        for case .query(let editor) in tabs.map(\.content) {
            if let id = editor.processID { ids.insert(id) }
        }
        return ids
    }

    func close(_ id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if case .query(let editor) = tabs[index].content {
            Task { await editor.close() }
        }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }
}

struct WorkspaceTab: Identifiable {
    enum Content {
        case table(TableBrowserModel)
        case query(QueryEditorModel)
    }

    let id = UUID()
    let content: Content

    /// Query tabs can be renamed (saving a query names the tab), so this reads the model on the main actor.
    @MainActor var title: String {
        switch content {
        case .table(let model): model.table
        case .query(let model): model.title
        }
    }

    var systemImage: String {
        switch content {
        case .table: "tablecells"
        case .query: "chevron.left.forwardslash.chevron.right"
        }
    }

    var tableKey: String? {
        if case .table(let model) = content { "\(model.database).\(model.table)" } else { nil }
    }
}

#if DEBUG
    // MARK: - Previews

    extension WorkspaceModel {
        /// A connected workspace with a table tab and a query tab, never touching the network.
        static func preview(link: LinkStatus = .ok, selectQueryTab: Bool = false) -> WorkspaceModel {
            var profile = PreviewData.profiles[0]
            profile.statusColor = .green
            let model = WorkspaceModel(profile: profile, password: nil)
            model.state = .connected
            model.serverVersion = "8.4.3"
            model.isEncrypted = true
            model.tlsCipher = "TLS_AES_256_GCM_SHA384"
            model.databases = ["information_schema", "mysql", "shop"]
            model.selectedDatabase = "shop"
            model.tables = PreviewData.tables
            model.link = link
            let table = WorkspaceTab(content: .table(.preview(withEdits: true)))
            let query = WorkspaceTab(content: .query(.preview(.failed)))
            model.tabs = [table, query]
            model.selectedTabID = selectQueryTab ? query.id : table.id
            return model
        }
    }
#endif

/// Which export/import sheet to show.
enum TransferRequest: Identifiable, Hashable {
    /// Export Tables… with these tables (in the current database) ticked.
    case export(Set<String>)
    /// Export one table, choosing its columns.
    case exportColumns(String)
    case importDump

    var id: String {
        switch self {
        case .export(let tables): "export:" + tables.sorted().joined(separator: ",")
        case .exportColumns(let table): "columns:" + table
        case .importDump: "import"
        }
    }
}
