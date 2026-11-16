import SwiftUI
import TableRoadCore
import TableRoadDesign
import TableRoadStorage

@main
struct TableRoadApp: App {
    @State private var store = Self.makeStore()

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

    var body: some Scene {
        Window("Welcome to TableRoad", id: "welcome") {
            WelcomeView()
                .environment(store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .newItem) {
                OpenWelcomeButton()
            }
        }

        WindowGroup("Workspace", for: UUID.self) { $connectionID in
            if let connectionID, let profile = store.profile(id: connectionID) {
                WorkspaceView(profile: profile, password: store.password(for: connectionID))
            } else {
                ContentUnavailableView("Connection Not Found", systemImage: "questionmark.circle")
            }
        }
        .defaultSize(width: 1200, height: 760)
        // Connection windows hold live sessions; don't resurrect them (with possibly deleted IDs) at launch.
        .restorationBehavior(.disabled)
    }
}

private struct OpenWelcomeButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Connections…") { openWindow(id: "welcome") }
            .keyboardShortcut("0", modifiers: [.command, .shift])
    }
}
