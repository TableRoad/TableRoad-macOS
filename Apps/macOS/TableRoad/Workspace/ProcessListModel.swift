import Foundation
import Observation
import TableRoadCore
import TableRoadDrivers
import TableRoadSQL

/// Live view of `SHOW FULL PROCESSLIST` with kill actions. Runs on its own connection so it keeps working when
/// the browsing connection (or a query tab) is stuck behind a long query, which is exactly when it's needed.
@MainActor @Observable
final class ProcessListModel {
    enum RefreshInterval: Double, CaseIterable, Identifiable {
        case off = 0, oneSecond = 1, twoSeconds = 2, fiveSeconds = 5
        var id: Double { rawValue }
        var label: String { self == .off ? "Off" : "Every \(Int(rawValue))s" }
    }

    private(set) var processes: [ServerProcess] = []
    private(set) var lastError: String?
    private(set) var lastRefreshed: Date?
    private(set) var isRefreshing = false
    /// This monitor's own connection id.
    private(set) var monitorProcessID: UInt64?

    var refreshInterval: RefreshInterval = .twoSeconds {
        didSet { restartPolling() }
    }
    var hideIdle = true
    var onlyThisApp = false
    var search = ""
    var selection: ServerProcess.ID?
    var sortOrder = [KeyPathComparator(\ServerProcess.seconds, order: .reverse)]
    /// Queries running at least this long are highlighted.
    var longRunningSeconds = 10

    /// The workspace's own connections (browsing + query tabs), so they can be labelled and protected.
    var appProcessIDs: () -> Set<UInt64> = { [] }
    /// The main browsing connection's id (killing it forces a reconnect).
    var mainProcessID: () -> UInt64? = { nil }

    private let connect: @Sendable () async throws -> any SQLClient
    private var session: (any SQLClient)?
    private var pollTask: Task<Void, Never>?

    init(connect: @escaping @Sendable () async throws -> any SQLClient) {
        self.connect = connect
    }

    // MARK: Lifecycle

    func start() {
        restartPolling()
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        await session?.close()
        session = nil
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                guard let self, self.refreshInterval != .off else { return }
                try? await Task.sleep(for: .seconds(self.refreshInterval.rawValue))
                if Task.isCancelled { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let session = try await ensureSession()
            processes = try await session.processList()
            lastRefreshed = .now
            lastError = nil
            if let selection, !processes.contains(where: { $0.id == selection }) { self.selection = nil }
        } catch {
            lastError = error.localizedDescription
            if (error as? DatabaseError)?.category == .connection {
                // Drop the dead connection; the next refresh reconnects.
                await self.session?.close()
                self.session = nil
            }
        }
    }

    private func ensureSession() async throws -> any SQLClient {
        if let session { return session }
        let fresh = try await connect()
        session = fresh
        monitorProcessID = fresh.processID
        return fresh
    }

    // MARK: Killing

    func kill(_ process: ServerProcess, connection: Bool) async {
        do {
            let session = try await ensureSession()
            try await session.kill(processID: process.id, connection: connection)
            lastError = nil
        } catch {
            lastError = "Couldn't kill \(process.id): \(error.localizedDescription)"
        }
        await refresh()
    }

    // MARK: Presentation

    func isThisApp(_ process: ServerProcess) -> Bool {
        process.id == monitorProcessID || appProcessIDs().contains(process.id)
    }

    /// What a kill would affect, for the confirmation dialog.
    func warning(for process: ServerProcess, connection: Bool) -> String? {
        if process.id == monitorProcessID { return "This is the process list's own connection." }
        if process.id == mainProcessID() {
            return connection
                ? "This is TableRoad's browsing connection for this window; it will reconnect automatically."
                : "This is TableRoad's browsing connection for this window."
        }
        if appProcessIDs().contains(process.id) { return "This connection belongs to one of this window's query tabs." }
        return nil
    }

    var visibleProcesses: [ServerProcess] {
        processes
            .filter { !hideIdle || !$0.isIdle || $0.id == selection }
            .filter { !onlyThisApp || isThisApp($0) }
            .filter { process in
                search.isEmpty
                    || [
                        process.user, process.host, process.database ?? "", process.command, process.info ?? "",
                        String(process.id),
                    ]
                    .contains { $0.localizedCaseInsensitiveContains(search) }
            }
            .sorted(using: sortOrder)
    }

    var selectedProcess: ServerProcess? {
        processes.first { $0.id == selection }
    }
}

extension ServerProcess {
    /// Non-optional sort keys for SwiftUI `Table` columns.
    var databaseText: String { database ?? "" }
    var stateText: String { state ?? "" }
    var infoText: String { info ?? "" }
}

#if DEBUG
    // MARK: - Previews

    extension ProcessListModel {
        static func preview() -> ProcessListModel {
            let model = ProcessListModel { throw DatabaseError(.connection, "Previews don't connect.") }
            model.processes = [
                ServerProcess(
                    id: 4012, user: "app", host: "10.0.3.17:51544", database: "shop", command: "Query", seconds: 184,
                    state: "Sending data",
                    info:
                        "SELECT o.*, c.email FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.total > 400"
                ),
                ServerProcess(
                    id: 4019, user: "report", host: "10.0.3.22:40122", database: "shop", command: "Query", seconds: 12,
                    state: "Creating sort index", info: "SELECT status, SUM(total) FROM orders GROUP BY status"),
                ServerProcess(
                    id: 4031, user: "tableroad", host: "192.168.65.1:62001", database: "shop", command: "Query",
                    seconds: 0, state: "executing", info: "SHOW FULL PROCESSLIST"),
                ServerProcess(
                    id: 4030, user: "tableroad", host: "192.168.65.1:62000", database: "shop", command: "Sleep",
                    seconds: 41, state: nil, info: nil),
                ServerProcess(
                    id: 5, user: "event_scheduler", host: "localhost", database: nil, command: "Daemon", seconds: 90311,
                    state: "Waiting on empty queue", info: nil),
            ]
            model.monitorProcessID = 4031
            model.appProcessIDs = { [4030] }
            model.mainProcessID = { 4030 }
            model.selection = 4012
            model.hideIdle = false
            model.lastRefreshed = .now
            return model
        }
    }
#endif
