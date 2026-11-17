import SwiftUI
import TableRoadCore
import TableRoadDesign

/// Server processes with live refresh, filters, and Kill Query / Kill Connection.
struct ProcessListView: View {
    @Bindable var model: ProcessListModel
    @State private var pendingKill: PendingKill?

    struct PendingKill: Identifiable {
        let process: ServerProcess
        let connection: Bool
        var id: String { "\(process.id)-\(connection)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = model.lastError {
                ErrorBanner(message: error)
            }
            table
            Divider()
            detail
        }
        .onAppear { model.start() }
        .confirmationDialog(
            pendingKill.map {
                $0.connection ? "Kill connection \($0.process.id)?" : "Kill the query on connection \($0.process.id)?"
            }
                ?? "",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible,
            presenting: pendingKill
        ) { kill in
            Button(kill.connection ? "Kill Connection" : "Kill Query", role: .destructive) {
                Task { await model.kill(kill.process, connection: kill.connection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { kill in
            Text(confirmationMessage(kill))
        }
    }

    private func confirmationMessage(_ kill: PendingKill) -> String {
        var lines = [
            "\(kill.process.user)@\(kill.process.host) · \(kill.process.command) for \(duration(kill.process.seconds))"
        ]
        if let sql = kill.process.info { lines.append(String(sql.prefix(300))) }
        lines.append(
            kill.connection
                ? "The connection is closed; any open transaction on it is rolled back."
                : "Only the running statement is stopped; the connection stays open.")
        if let warning = model.warning(for: kill.process, connection: kill.connection) { lines.append(warning) }
        return lines.joined(separator: "\n\n")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Refresh", selection: $model.refreshInterval) {
                ForEach(ProcessListModel.RefreshInterval.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Refresh now (⌘R)")
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Toggle("Hide idle", isOn: $model.hideIdle).toggleStyle(.checkbox)
            Toggle("Only TableRoad", isOn: $model.onlyThisApp).toggleStyle(.checkbox)
            TextField("Search user, host, database, SQL…", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Spacer()
            Text(summary).foregroundStyle(.secondary).monospacedDigit()
        }
        .controlSize(.small)
        .padding(8)
        .background(.bar)
    }

    private var summary: String {
        let visible = model.visibleProcesses.count
        let total = model.processes.count
        let time = model.lastRefreshed.map { " · updated \($0.formatted(date: .omitted, time: .standard))" } ?? ""
        return "\(visible) of \(total) connections\(time)"
    }

    // MARK: Table

    private var table: some View {
        Table(model.visibleProcesses, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("ID", value: \.id) { process in
                HStack(spacing: 4) {
                    Text(String(process.id)).monospacedDigit()
                    if model.isThisApp(process) {
                        Text("TableRoad")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .background(Brand.amber.opacity(0.25), in: Capsule())
                            .help("A connection opened by this window")
                    }
                }
            }
            .width(min: 60, ideal: 110)
            TableColumn("User", value: \.user)
                .width(min: 60, ideal: 90)
            TableColumn("Host", value: \.host)
                .width(min: 80, ideal: 140)
            TableColumn("Database", value: \.databaseText)
                .width(min: 60, ideal: 90)
            TableColumn("Command", value: \.command)
                .width(min: 60, ideal: 80)
            TableColumn("Time", value: \.seconds) { process in
                Text(duration(process.seconds))
                    .monospacedDigit()
                    .foregroundStyle(timeColor(process))
                    .fontWeight(isLongRunning(process) ? .semibold : .regular)
            }
            .width(min: 50, ideal: 70)
            TableColumn("State", value: \.stateText)
                .width(min: 60, ideal: 130)
            TableColumn("Query", value: \.infoText) { process in
                Text(process.infoText.replacingOccurrences(of: "\n", with: " "))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .help(process.infoText)
            }
        }
        .contextMenu(forSelectionType: ServerProcess.ID.self) { ids in
            if let id = ids.first, let process = model.processes.first(where: { $0.id == id }) {
                Button("Kill Query") { pendingKill = PendingKill(process: process, connection: false) }
                    .disabled(process.info == nil)
                Button("Kill Connection…") { pendingKill = PendingKill(process: process, connection: true) }
                Divider()
                Button("Copy Query") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(process.infoText, forType: .string)
                }
                .disabled(process.info == nil)
            }
        }
    }

    private func isLongRunning(_ process: ServerProcess) -> Bool {
        !process.isIdle && process.info != nil && process.seconds >= model.longRunningSeconds
    }

    private func timeColor(_ process: ServerProcess) -> Color {
        if isLongRunning(process) { return .red }
        if !process.isIdle && process.info != nil && process.seconds >= 2 { return .orange }
        return .primary
    }

    private func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let process = model.selectedProcess {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Connection \(String(process.id))").font(.headline)
                    Text("\(process.user)@\(process.host) · \(process.command) · \(duration(process.seconds))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Kill Query") { pendingKill = PendingKill(process: process, connection: false) }
                        .disabled(process.info == nil)
                        .help("Stop the running statement; the connection stays open")
                    Button("Kill Connection…", role: .destructive) {
                        pendingKill = PendingKill(process: process, connection: true)
                    }
                    .help("Close the connection; its open transaction is rolled back")
                }
                ScrollView {
                    Text(process.info ?? "No statement running.")
                        .font(.callout.monospaced())
                        .foregroundStyle(process.info == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)
            }
            .padding(10)
        } else {
            Text("Select a connection to see its full query and kill it.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        }
    }
}

#if DEBUG
    #Preview("Processes") {
        ProcessListView(model: .preview())
            .frame(width: 1100, height: 520)
    }
#endif
