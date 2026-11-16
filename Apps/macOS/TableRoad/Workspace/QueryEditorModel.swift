import Foundation
import Observation
import TableRoadCore
import TableRoadMySQL
import TableRoadSQL

/// A SQL editor tab. Each tab runs on its own connection, opened on first run, so a long query never blocks
/// table browsing or other tabs, and session state (transactions, variables, temp tables) persists between runs.
@MainActor @Observable
final class QueryEditorModel {
    let title: String
    var text = ""
    private(set) var result: ResultSet?
    private(set) var messages: [Message] = []
    private(set) var isRunning = false
    /// When the current run started (drives the live timer).
    private(set) var runStartedAt: Date?
    /// Whether this tab currently holds an open connection.
    private(set) var isConnected = false
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

    init(title: String, database: String?, connect: @escaping @Sendable () async throws -> MySQLSession) {
        self.title = title
        self.database = database
        self.connect = connect
    }

    var inspectorRow: InspectorRow? {
        guard let result, let row = selectedRows.first, row < result.rows.count else { return nil }
        return InspectorRow(
            title: "Result row \(row + 1)", columns: result.columns, values: result.rows[row],
            details: Array(repeating: nil, count: result.columns.count),
            states: Array(repeating: .normal, count: result.columns.count))
    }

    func run(_ script: String? = nil) async {
        let statements = StatementSplitter(syntax: .mysql).split(script ?? text)
        guard !statements.isEmpty, !isRunning else { return }
        isRunning = true
        runStartedAt = .now
        cancelRequested = false
        messages = []
        defer {
            isRunning = false
            runStartedAt = nil
        }

        let session: MySQLSession
        do {
            session = try await ensureSession()
        } catch {
            messages.append(Message(text: "Couldn't connect: \(error.localizedDescription)", isError: true))
            return
        }

        var reportedCancel = false
        defer {
            // Some statements (e.g. SLEEP) return normally when killed, so always say the run was cancelled.
            if cancelRequested && !reportedCancel {
                messages.append(Message(text: "Query cancelled.", isError: true))
            }
        }
        for (index, statement) in statements.enumerated() {
            if cancelRequested {
                let remaining = statements.count - index
                messages.append(Message(text: "Cancelled; \(remaining) statement(s) not run.", isError: true))
                reportedCancel = true
                break
            }
            let start = ContinuousClock.now
            do {
                let outcome = try await session.execute(statement.text)
                let elapsed = (ContinuousClock.now - start).formatted(
                    .units(allowed: [.seconds, .milliseconds], width: .narrow))
                switch outcome {
                case .rows(let rows):
                    result = rows
                    selectedRows = []
                    messages.append(Message(text: "\(rows.rows.count) row(s) in \(elapsed)", isError: false))
                case .affected(let count):
                    messages.append(Message(text: "\(count) row(s) affected in \(elapsed)", isError: false))
                }
            } catch {
                let databaseError = error as? DatabaseError
                if databaseError?.category == .cancelled || cancelRequested {
                    messages.append(Message(text: "Query cancelled.", isError: true))
                    reportedCancel = true
                } else {
                    messages.append(Message(text: error.localizedDescription, isError: true))
                }
                if databaseError?.category == .connection {
                    // The connection is gone; drop it so the next run reconnects.
                    await dropSession()
                    messages.append(Message(text: "Connection lost. It will reconnect on the next run.", isError: true))
                }
                break
            }
        }
    }

    /// Kills the running statement on the server and stops the rest of the script.
    func cancel() async {
        guard isRunning, let session else { return }
        cancelRequested = true
        do {
            try await session.cancelCurrentQuery()
        } catch {
            messages.append(Message(text: "Cancel failed: \(error.localizedDescription)", isError: true))
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
        appliedDatabase = nil
        await old?.close()
    }
}
