import SwiftUI
import TableRoadCore
import TableRoadDesign

@main
struct TableRoadApp: App {
    @State private var connections = ConnectionList()

    var body: some Scene {
        Window("Welcome to TableRoad", id: "welcome") {
            WelcomeView()
                .environment(connections)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// In-memory connection list for the Phase 0 shell. Phase 1 replaces this with the persistent
/// `ConnectionStore` (JSON in Application Support + Keychain) in TableRoadKit.
@MainActor @Observable
final class ConnectionList {
    var profiles: [ConnectionProfile] = []

    func add(_ profile: ConnectionProfile) {
        profiles.append(profile)
    }
}
