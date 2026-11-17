import Foundation
import Observation
import TableRoadCore
import TableRoadMySQL
import TableRoadSQL

/// A SQL editor tab. Each tab runs on its own connection, opened on first run, so a long query never blocks
/// table browsing or other tabs, and session state (transactions, variables, temp tables) persists between runs.
@MainActor @Observable
final class QueryEditorModel {
    var title: String
    var text = ""
    /// The saved query this tab was opened from (Save Query updates it).
    var savedQueryID: UUID?
    /// Called after every run with its statements and the database it ran against (feeds query history).
    var onRunFinished: ([StatementResult], String?) -> Void = { _, _ in }
    /// One entry per statement in the last run (plus notes like "connection lost").
    private(set) var statements: [StatementResult] = []
    private(set) var notes: [Message] = []
    /// Which results tab is showing.
    var selectedTab: ResultTab = .messages
    /// Statements that produced rows past this many don't get a tab (each holds its rows in memory).
    nonisolated static let maxResultTabs = 50
    private(set) var isRunning = false
    /// When the current run started (drives the live timer).
    private(set) var runStartedAt: Date?
    /// Whether this tab currently holds an open connection.
    private(set) var isConnected = false
    /// Server-side id of this tab's connection (shown as "this app" in the process list).
    private(set) var processID: UInt64?
    var selectedRows = IndexSet()

    /// The sidebar's database. Applied before the next run when it changes; a `USE` in the script still wins.
    var database: String?

    private let connect: @Sendable () async throws -> MySQLSession
    private var session: MySQLSession?
    /// Last sidebar database applied to the session.
    private var appliedDatabase: String?
    private var cancelRequested = false

    struct Message: Identifiable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    /// What one statement in a run produced.
    struct StatementResult: Identifiable {
        enum Outcome {
            case rows(ResultSet)
            /// Returned rows, but over the result-tab limit; only the count is kept.
            case rowsNotKept(Int)
            case affected(UInt64)
            case failed(String)
        }

        let id = UUID()
        /// 1-based position in the run.
        let number: Int
        let sql: String
        let outcome: Outcome
        let elapsed: Duration

        var hasTab: Bool {
            switch outcome {
            case .rows, .failed: true
            case .rowsNotKept, .affected: false
            }
        }

        var isFailure: Bool {
            if case .failed = outcome { true } else { false }
        }

        var summary: String {
            switch outcome {
            case .rows(let rows): "\(rows.rows.count.formatted()) row(s)"
            case .rowsNotKept(let count):
                "\(count.formatted()) row(s), not kept (over \(QueryEditorModel.maxResultTabs) results)"
            case .affected(let count): "\(count.formatted()) row(s) affected"
            case .failed(let message): message
            }
        }

        var elapsedText: String {
            elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        }
    }

    enum ResultTab: Hashable {
        case statement(UUID)
        case messages
    }

    /// Statements that get their own tab (row results and errors), in order.
    var resultTabs: [StatementResult] { statements.filter(\.hasTab) }

    var selectedStatement: StatementResult? {
        guard case .statement(let id) = selectedTab else { return nil }
        return statements.first { $0.id == id }
    }

    /// Rows of the selected tab, if it's a result set.
    var result: ResultSet? {
        if case .rows(let rows) = selectedStatement?.outcome { rows } else { nil }
    }

    init(title: String, database: String?, connect: @escaping @Sendable () async throws -> MySQLSession) {
        self.title = title
        self.database = database
        self.connect = connect
    }

    var inspectorRow: InspectorRow? {
        guard let result, let statement = selectedStatement, let row = selectedRows.first, row < result.rows.count
        else { return nil }
        return InspectorRow(
            title: "Result \(statement.number), row \(row + 1)", columns: result.columns, values: result.rows[row],
            details: Array(repeating: nil, count: result.columns.count),
            states: Array(repeating: .normal, count: result.columns.count))
    }

    func run(_ script: String? = nil) async {
        let parsed = StatementSplitter(syntax: .mysql).split(script ?? text)
        guard !parsed.isEmpty, !isRunning else { return }
        isRunning = true
        runStartedAt = .now
        cancelRequested = false
        statements = []
        notes = []
        selectedRows = []
        defer {
            isRunning = false
            runStartedAt = nil
            selectDefaultTab()
            onRunFinished(statements, database)
        }

        let session: MySQLSession
        do {
            session = try await ensureSession()
        } catch {
            notes.append(Message(text: "Couldn't connect: \(error.localizedDescription)", isError: true))
            return
        }

        var reportedCancel = false
        defer {
            // Some statements (e.g. SLEEP) return normally when killed, so always say the run was cancelled.
            if cancelRequested && !reportedCancel {
                notes.append(Message(text: "Query cancelled.", isError: true))
            }
        }
        var keptResults = 0
        for (index, statement) in parsed.enumerated() {
            if cancelRequested {
                notes.append(
                    Message(text: "Cancelled; \(parsed.count - index) statement(s) not run.", isError: true))
                reportedCancel = true
                break
            }
            let start = ContinuousClock.now
            do {
                let outcome: StatementResult.Outcome
                switch try await session.execute(statement.text) {
                case .rows(let rows):
                    if keptResults < Self.maxResultTabs {
                        keptResults += 1
                        outcome = .rows(rows)
                    } else {
                        outcome = .rowsNotKept(rows.rows.count)
                    }
                case .affected(let count):
                    outcome = .affected(count)
                }
                record(statement, index, outcome, since: start)
            } catch {
                let databaseError = error as? DatabaseError
                if databaseError?.category == .cancelled || cancelRequested {
                    notes.append(Message(text: "Query cancelled.", isError: true))
                    reportedCancel = true
                } else {
                    record(statement, index, .failed(error.localizedDescription), since: start)
                }
                if databaseError?.category == .connection {
                    // The connection is gone; drop it so the next run reconnects.
                    await dropSession()
                    notes.append(Message(text: "Connection lost. It will reconnect on the next run.", isError: true))
                }
                if parsed.count > index + 1 {
                    notes.append(
                        Message(text: "Stopped; \(parsed.count - index - 1) statement(s) not run.", isError: true))
                }
                break
            }
        }
    }

    private func record(
        _ statement: StatementSplitter.Statement, _ index: Int, _ outcome: StatementResult.Outcome,
        since start: ContinuousClock.Instant
    ) {
        statements.append(
            StatementResult(
                number: index + 1, sql: statement.text, outcome: outcome, elapsed: ContinuousClock.now - start))
    }

    /// After a run: show the error if there was one, otherwise the last result set, otherwise Messages.
    func selectDefaultTab() {
        if let failure = statements.last(where: \.isFailure) {
            selectedTab = .statement(failure.id)
        } else if let last = statements.last(where: \.hasTab) {
            selectedTab = .statement(last.id)
        } else {
            selectedTab = .messages
        }
    }

    func select(_ tab: ResultTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        selectedRows = []
    }

    /// Kills the running statement on the server and stops the rest of the script.
    func cancel() async {
        guard isRunning, let session else { return }
        cancelRequested = true
        do {
            try await session.cancelCurrentQuery()
        } catch {
            notes.append(Message(text: "Cancel failed: \(error.localizedDescription)", isError: true))
        }
    }

    /// Closes this tab's connection (tab closed or window closing).
    func close() async {
        await dropSession()
    }

    private func ensureSession() async throws -> MySQLSession {
        let session: MySQLSession
        if let existing = self.session {
            session = existing
        } else {
            session = try await connect()
            self.session = session
            isConnected = true
            processID = session.processID
            appliedDatabase = await session.currentDatabase
        }
        if let database, database != appliedDatabase {
            try await session.useDatabase(database)
            appliedDatabase = database
        }
        return session
    }

    private func dropSession() async {
        let old = session
        session = nil
        isConnected = false
        processID = nil
        appliedDatabase = nil
        await old?.close()
    }
}

#if DEBUG
    // MARK: - Previews

    extension QueryEditorModel {
        enum PreviewState { case empty, results, failed, running }

        /// An editor with sample SQL and, depending on `state`, result tabs, an error, or a run in progress.
        static func preview(_ state: PreviewState = .results) -> QueryEditorModel {
            let model = QueryEditorModel(title: "Query 1", database: "shop") {
                throw DatabaseError(.connection, "Previews don't connect.")
            }
            model.text = """
                SELECT status, COUNT(*) AS n FROM orders GROUP BY status;
                UPDATE orders SET note = NULL WHERE id < 10;
                SELECT * FROM orders LIMIT 40;
                SELECT * FROM no_such_table;
                """
            switch state {
            case .empty:
                break
            case .running:
                model.isRunning = true
                model.runStartedAt = .now.addingTimeInterval(-3.2)
                model.isConnected = true
            case .results, .failed:
                model.isConnected = true
                model.statements = [
                    StatementResult(
                        number: 1, sql: "SELECT status, COUNT(*) AS n FROM orders GROUP BY status",
                        outcome: .rows(PreviewData.summary), elapsed: .milliseconds(6)),
                    StatementResult(
                        number: 2, sql: "UPDATE orders SET note = NULL WHERE id < 10", outcome: .affected(9),
                        elapsed: .milliseconds(13)),
                    StatementResult(
                        number: 3, sql: "SELECT * FROM orders LIMIT 40", outcome: .rows(PreviewData.orders),
                        elapsed: .milliseconds(9)),
                ]
                if state == .failed {
                    model.statements.append(
                        StatementResult(
                            number: 4, sql: "SELECT * FROM no_such_table",
                            outcome: .failed("Table 'shop.no_such_table' doesn't exist (1146)"),
                            elapsed: .milliseconds(4)))
                }
                model.selectDefaultTab()
            }
            return model
        }
    }
#endif

/// Lets a tab drive `.sheet(item:)` (identity is the object).
extension QueryEditorModel: Identifiable {}
