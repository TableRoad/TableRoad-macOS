import SwiftUI
import TableRoadBackup
import TableRoadCore
import TableRoadDesign
import TableRoadStorage

@main
struct TableRoadApp: App {
    @State private var store: ConnectionStore
    @State private var scheduler: BackupScheduler
    @State private var router = WelcomeRouter()
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
        let store = Self.makeStore()
        let scheduler = BackupScheduler(
            store: BackupStore(fileURL: Self.dataURL(BackupStore.defaultFileURL())), connections: store)
        _store = State(initialValue: store)
        _scheduler = State(initialValue: scheduler)
        #if DEBUG
            DevFixtures.seedSchedules(scheduler.store, connections: store)
        #endif
        // NSApp exists once the app delegate is set up; apply on the next run-loop turn.
        DispatchQueue.main.async {
            AppearanceSetting.current.apply()
            // Backups run whenever the app is open, with or without windows.
            scheduler.start()
        }
    }

    var body: some Scene {
        Window("Welcome to TableRoad", id: "welcome") {
            WelcomeView()
                .environment(store)
                .environment(scheduler)
                .environment(router)
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
                OpenWelcomeButton(router: router)
                BackupMenuButtons(router: router)
            }
            CommandGroup(replacing: .help) {
                HelpLinks()
            }
        }

        Window("Sync Database", id: "sync-database") {
            SyncDatabaseView()
                .environment(store)
                .environment(scheduler)
                .environment(router)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 620)
        .restorationBehavior(.disabled)

        WindowGroup("Workspace", for: UUID.self) { $connectionID in
            if let connectionID, let profile = store.profile(id: connectionID) {
                Group {
                    if profile.kind == .redis {
                        RedisWorkspaceView(profile: profile, password: store.password(for: connectionID))
                    } else {
                        WorkspaceView(profile: profile, password: store.password(for: connectionID))
                    }
                }
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

/// Help menu: the project on GitHub.
private struct HelpLinks: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("TableRoad on GitHub") { openURL(ProjectLinks.repository) }
        Button("Report an Issue…") { openURL(ProjectLinks.newIssue) }
        Button("Release Notes") { openURL(ProjectLinks.releases) }
        Divider()
        Button("Contributing Guide") { openURL(ProjectLinks.contributing) }
        Button("\(ProjectLinks.licenceName) Licence") { openURL(ProjectLinks.licence) }
    }
}

/// File ▸ Backups… and Sync Database….
private struct BackupMenuButtons: View {
    let router: WelcomeRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Backups…") {
            router.mode = .backups
            openWindow(id: "welcome")
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
        Button("Sync Database…") { openWindow(id: "sync-database") }
    }
}

private struct OpenWelcomeButton: View {
    let router: WelcomeRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Connections…") {
            router.mode = .connections
            openWindow(id: "welcome")
        }
        .keyboardShortcut("0", modifiers: [.command, .shift])
    }
}

#if DEBUG
    #Preview("Connections… button") {
        OpenWelcomeButton(router: WelcomeRouter()).padding()
    }

    #Preview("Help links") {
        VStack { HelpLinks() }.padding()
    }

    #Preview("Backup menu buttons") {
        VStack { BackupMenuButtons(router: WelcomeRouter()) }.padding()
    }
#endif
