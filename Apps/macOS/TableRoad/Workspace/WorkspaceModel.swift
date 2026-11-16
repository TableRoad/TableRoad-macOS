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

    let profile: ConnectionProfile
    private let password: String?
    private(set) var state: State = .connecting
    private(set) var session: MySQLSession?
    private(set) var serverVersion = ""
    private(set) var isEncrypted = false

    private(set) var databases: [String] = []
    var selectedDatabase: String? {
        didSet {
            if oldValue != selectedDatabase { Task { await loadTables() } }
        }
    }
    private(set) var tables: [TableInfo] = []
    private(set) var tablesError: String?

    var tabs: [WorkspaceTab] = []
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
                    if DevFixtures.environment["TABLEROAD_RUN_SQL_NOW"] != "0" { await editor.run() }
                }
            #endif
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        await session?.close()
        session = nil
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
        let browser = TableBrowserModel(session: session, database: database, table: table.name)
        let tab = WorkspaceTab(content: .table(browser))
        tabs.append(tab)
        selectedTabID = tab.id
        Task { await browser.load() }
    }

    func newQueryTab() {
        guard let session else { return }
        let count = tabs.filter { if case .query = $0.content { true } else { false } }.count
        let tab = WorkspaceTab(content: .query(QueryEditorModel(session: session, title: "Query \(count + 1)")))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func close(_ id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
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

/// Paged, sortable view of one table.
@MainActor @Observable
final class TableBrowserModel {
    let session: MySQLSession
    let database: String
    let table: String
    let pageSize = 300

    private(set) var result: ResultSet = .empty
    private(set) var totalRows: Int?
    private(set) var isLoading = false
    private(set) var error: String?
    var page = 0
    var sort: ColumnSort?

    init(session: MySQLSession, database: String, table: String) {
        self.session = session
        self.database = database
        self.table = table
    }

    var pageCount: Int {
        guard let totalRows else { return 1 }
        return max(1, Int((Double(totalRows) / Double(pageSize)).rounded(.up)))
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let query = PageQuery(
            database: database, table: table, sort: sort.map { [$0] } ?? [], limit: pageSize, offset: page * pageSize)
        do {
            if case .rows(let rows) = try await session.execute(query.selectSQL(session.dialect)) {
                if rows.columns.isEmpty {
                    // Empty page: take headers from the schema so the grid still shows columns.
                    let columns = try await session.columns(of: table, in: database)
                    result = ResultSet(
                        columns: columns.map { ResultColumn(name: $0.name, table: table, typeName: $0.type) }, rows: [])
                } else {
                    result = rows
                }
            }
            if totalRows == nil, case .rows(let count) = try await session.execute(query.countSQL(session.dialect)),
                case .int(let value) = count.rows.first?.first
            {
                totalRows = Int(value)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setSort(_ sort: ColumnSort?) {
        self.sort = sort
        page = 0
        Task { await load() }
    }

    func go(toPage newPage: Int) {
        page = min(max(newPage, 0), pageCount - 1)
        Task { await load() }
    }

    func refresh() {
        totalRows = nil
        Task { await load() }
    }
}

/// A SQL editor tab: runs a script statement by statement and shows the last result.
@MainActor @Observable
final class QueryEditorModel {
    let session: MySQLSession
    let title: String
    var text = ""
    private(set) var result: ResultSet?
    private(set) var messages: [Message] = []
    private(set) var isRunning = false

    struct Message: Identifiable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    init(session: MySQLSession, title: String) {
        self.session = session
        self.title = title
    }

    func run(_ script: String? = nil) async {
        let statements = StatementSplitter(syntax: .mysql).split(script ?? text)
        guard !statements.isEmpty else { return }
        isRunning = true
        defer { isRunning = false }
        messages = []
        for statement in statements {
            let start = ContinuousClock.now
            do {
                let outcome = try await session.execute(statement.text)
                let elapsed = (ContinuousClock.now - start).formatted(
                    .units(allowed: [.seconds, .milliseconds], width: .narrow))
                switch outcome {
                case .rows(let rows):
                    result = rows
                    messages.append(Message(text: "\(rows.rows.count) row(s) in \(elapsed)", isError: false))
                case .affected(let count):
                    messages.append(Message(text: "\(count) row(s) affected in \(elapsed)", isError: false))
                }
            } catch {
                messages.append(Message(text: error.localizedDescription, isError: true))
                break
            }
        }
    }

    func cancel() async {
        do {
            try await session.cancelCurrentQuery()
        } catch {
            messages.append(Message(text: "Cancel failed: \(error.localizedDescription)", isError: true))
        }
    }
}
