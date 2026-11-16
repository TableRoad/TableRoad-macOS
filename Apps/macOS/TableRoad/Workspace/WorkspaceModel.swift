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
        for case .query(let editor) in tabs.map(\.content) { await editor.close() }
        await session?.close()
        session = nil
    }

    /// Opens another connection with the same settings (each query tab has its own).
    nonisolated func makeSession() async throws -> MySQLSession {
        try await MySQLSession.connect(MySQLConnectConfig(profile: profile, password: password))
    }

    static let systemDatabases: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]

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
