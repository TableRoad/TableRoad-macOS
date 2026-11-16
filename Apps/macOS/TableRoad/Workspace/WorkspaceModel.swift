import Foundation
import Observation
import TableRoadCore
import TableRoadMySQL
import TableRoadSQL

/// One connection window: the session, the database list and the open tabs.
@MainActor @Observable
final class WorkspaceModel {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    nonisolated let profile: ConnectionProfile
    private nonisolated let password: String?
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
    private(set) var session: MySQLSession?
    private(set) var serverVersion = ""
    private(set) var isEncrypted = false

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
        state = .connecting
        do {
            let session = try await MySQLSession.connect(MySQLConnectConfig(profile: profile, password: password))
            self.session = session
            serverVersion = await session.serverVersion
            isEncrypted = session.isEncrypted
            databases = try await session.databases()
            state = .connected
            selectedDatabase = await session.currentDatabase ?? databases.first { !Self.systemDatabases.contains($0) }
            if tabs.isEmpty { newQueryTab() }
            startKeepAlive()
            #if DEBUG
                await loadTables()
                if let name = DevFixtures.openTable, let table = tables.first(where: { $0.name == name }) {
                    open(table: table)
                }
                if let sql = DevFixtures.runSQL, case .query(let editor) = tabs.first?.content {
                    editor.text = sql
                    selectedTabID = tabs.first?.id
                    if DevFixtures.environment["TABLEROAD_RUN_SQL_NOW"] != "0" { Task { await editor.run() } }
                }
            #endif
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        reconnectTask?.cancel()
        keepAliveTask?.cancel()
        for case .query(let editor) in tabs.map(\.content) { await editor.close() }
        await session?.close()
        session = nil
    }

    /// Opens another connection with the same settings (each query tab has its own).
    nonisolated func makeSession() async throws -> MySQLSession {
        try await MySQLSession.connect(MySQLConnectConfig(profile: profile, password: password))
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

    /// Swaps in a new main session and refreshes everything that used the old one.
    private func adopt(_ fresh: MySQLSession) async {
        let old = session
        session = fresh
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

    func loadTables() async {
        guard let session, let database = selectedDatabase else {
            tables = []
            return
        }
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

    func newQueryTab() {
        guard session != nil else { return }
        let count = tabs.filter { if case .query = $0.content { true } else { false } }.count
        let editor = QueryEditorModel(title: "Query \(count + 1)", database: selectedDatabase) { [weak self] in
            guard let self else { throw DatabaseError(.connection, "The window was closed.") }
            return try await self.makeSession()
        }
        let tab = WorkspaceTab(content: .query(editor))
        tabs.append(tab)
        selectedTabID = tab.id
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

    var title: String {
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
