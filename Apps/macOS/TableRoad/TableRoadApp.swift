import SwiftUI
import TableRoadCore
import TableRoadDesign
import TableRoadStorage

@main
struct TableRoadApp: App {
    @State private var store = Self.makeStore()
    @State private var registry = WorkspaceRegistry()
    @State private var savedQueries = SavedQueryStore(fileURL: Self.dataURL(SavedQueryStore.defaultFileURL()))
    @State private var history = QueryHistoryStore(fileURL: Self.dataURL(QueryHistoryStore.defaultFileURL()))

    /// Dev fixture runs keep their saved queries and history in a temporary folder, away from real data.
    private static func dataURL(_ url: URL) -> URL {
        #if DEBUG
            if DevFixtures.isEnabled {
                return FileManager.default.temporaryDirectory.appending(path: "tableroad-dev/\(url.lastPathComponent)")
            }
        #endif
        return url
    }

    @MainActor
    private static func makeStore() -> ConnectionStore {
        #if DEBUG
            if DevFixtures.isEnabled { return DevFixtures.makeStore() }
        #endif
        return ConnectionStore(
            fileURL: ConnectionStore.defaultFileURL(),
            secrets: KeychainSecretStore(service: (Bundle.main.bundleIdentifier ?? "TableRoad") + ".connections")
        )
    }

    init() {
        // NSApp exists once the app delegate is set up; apply on the next run-loop turn.
        DispatchQueue.main.async { AppearanceSetting.current.apply() }
    }

    var body: some Scene {
        Window("Welcome to TableRoad", id: "welcome") {
            WelcomeView()
                .environment(store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Always show the launcher at startup, even if it was closed last time; otherwise the app can launch
        // with no windows at all.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .newItem) {
                OpenWelcomeButton()
            }
        }

        WindowGroup("Workspace", for: UUID.self) { $connectionID in
            if let connectionID, let profile = store.profile(id: connectionID) {
                WorkspaceView(profile: profile, password: store.password(for: connectionID))
                    .environment(store)
                    .environment(registry)
                    .environment(savedQueries)
                    .environment(history)
            } else {
                ContentUnavailableView("Connection Not Found", systemImage: "questionmark.circle")
            }
        }
        .defaultSize(width: 1200, height: 760)
        // Connection windows hold live sessions; don't resurrect them (with possibly deleted IDs) at launch.
        .restorationBehavior(.disabled)

        WindowGroup("Running Queries", id: "running-queries", for: UUID.self) { $connectionID in
            if let connectionID {
                RunningQueriesWindow(connectionID: connectionID)
                    .environment(registry)
            }
        }
        .defaultSize(width: 1000, height: 560)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
    }
}

private struct OpenWelcomeButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Connections…") { openWindow(id: "welcome") }
            .keyboardShortcut("0", modifiers: [.command, .shift])
    }
}

#if DEBUG
    #Preview("Connections… button") {
        OpenWelcomeButton().padding()
    }
#endif
