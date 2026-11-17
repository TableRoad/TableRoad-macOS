import AppKit
import SwiftUI

/// App appearance: follow the system, or force light / dark.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }

    static let storageKey = "appearance"

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Applies to every window (AppKit grids and editors included, not just SwiftUI views).
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }

    /// The saved choice; in debug builds `TABLEROAD_APPEARANCE=light|dark` overrides it (for screenshots).
    static var current: AppearanceSetting {
        #if DEBUG
            if let forced = ProcessInfo.processInfo.environment["TABLEROAD_APPEARANCE"],
                let setting = AppearanceSetting(rawValue: forced)
            {
                return setting
            }
        #endif
        return UserDefaults.standard.string(forKey: storageKey).flatMap(AppearanceSetting.init) ?? .system
    }
}

/// TableRoad ▸ Settings… (⌘,).
struct SettingsView: View {
    @AppStorage(AppearanceSetting.storageKey) private var appearance: AppearanceSetting = .system

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("System follows macOS's Light/Dark setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onChange(of: appearance) { _, setting in setting.apply() }
    }
}

#if DEBUG
    #Preview("Settings") {
        SettingsView()
    }
#endif
