import SwiftUI
import TableRoadCore

/// The Running Queries window for one connection (opened from the workspace toolbar, like TablePlus).
/// Uses its own connection, created from the workspace's current settings.
struct RunningQueriesWindow: View {
    let connectionID: UUID
    @Environment(WorkspaceRegistry.self) private var registry
    @State private var monitor: ProcessListModel?

    var body: some View {
        Group {
            if let workspace = registry.workspace(for: connectionID), workspace.state == .connected {
                Group {
                    if let monitor {
                        ProcessListView(model: monitor)
                    } else {
                        ProgressView()
                    }
                }
                .navigationTitle("Running Queries — \(workspace.profile.name)")
                .task { if monitor == nil { monitor = makeMonitor(for: workspace) } }
            } else {
                ContentUnavailableView(
                    "Not Connected", systemImage: "bolt.horizontal.circle",
                    description: Text("Open the connection's window first, then show Running Queries from its toolbar.")
                )
                .navigationTitle("Running Queries")
            }
        }
        .frame(minWidth: 760, minHeight: 360)
        .onDisappear {
            let monitor = monitor
            Task { await monitor?.stop() }
        }
    }

    private func makeMonitor(for workspace: WorkspaceModel) -> ProcessListModel {
        let monitor = ProcessListModel { [weak workspace] in
            guard let workspace else { throw DatabaseError(.connection, "The connection window was closed.") }
            return try await workspace.makeSession()
        }
        monitor.appProcessIDs = { [weak workspace] in workspace?.appProcessIDs ?? [] }
        monitor.mainProcessID = { [weak workspace] in workspace?.session?.processID }
        return monitor
    }
}

#if DEBUG
    #Preview("Running Queries – not connected") {
        RunningQueriesWindow(connectionID: UUID())
            .environment(WorkspaceRegistry())
    }
#endif
