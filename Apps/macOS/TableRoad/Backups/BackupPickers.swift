import AppKit
import SwiftUI
import TableRoadBackup
import TableRoadCore
import TableRoadDrivers
import TableRoadStorage
import TableRoadTransfer

/// Connections that can be backed up or synced (SQL engines with a working driver).
@MainActor
func backupConnections(_ store: ConnectionStore) -> [ConnectionProfile] {
    store.profiles.filter { $0.kind.isSQL && $0.kind != .redis && Drivers.isAvailable($0.kind) }
}

/// "Choose a Connection or Folder, Files…": a menu of saved connections (by group) plus folder/file choices.
struct EndpointMenu: View {
    enum Choice: Equatable {
        case connection(UUID)
        case folder(String)
        case files([String])
    }

    let placeholder: String
    let current: Choice?
    var allowsFolder = true
    var allowsFiles = false
    /// Folder chosen as a source holds dumps to read; as a target it receives them.
    var folderPrompt = "Choose"
    let onChoose: (Choice) -> Void
    @Environment(ConnectionStore.self) private var store

    var body: some View {
        Menu {
            let profiles = backupConnections(store)
            let ungrouped = profiles.filter { profile in !store.groups.contains { $0.id == profile.groupID } }
            ForEach(ungrouped) { profile in item(profile) }
            ForEach(store.groups) { group in
                let members = profiles.filter { $0.groupID == group.id }
                if !members.isEmpty {
                    Section(group.name) {
                        ForEach(members) { profile in item(profile) }
                    }
                }
            }
            if allowsFolder || allowsFiles { Divider() }
            if allowsFolder {
                Button("Folder…") { if let path = Self.chooseFolder(prompt: folderPrompt) { onChoose(.folder(path)) } }
            }
            if allowsFiles {
                Button("Files…") {
                    let paths = Self.chooseDumps()
                    if !paths.isEmpty { onChoose(.files(paths)) }
                }
            }
        } label: {
            label.frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func item(_ profile: ConnectionProfile) -> some View {
        Button {
            onChoose(.connection(profile.id))
        } label: {
            Text(profile.name)
            Text("\(profile.kind.displayName) · \(profile.host)")
        }
    }

    @ViewBuilder
    private var label: some View {
        switch current {
        case .connection(let id):
            if let profile = store.profile(id: id) {
                HStack(spacing: 10) {
                    EngineBadge(kind: profile.kind, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name).lineLimit(1)
                        Text("\(profile.kind.displayName) · \(profile.host)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                placeholderLabel("The connection was deleted. Choose another…")
            }
        case .folder(let path):
            pathLabel(icon: "folder.fill", title: (path as NSString).lastPathComponent, detail: path)
        case .files(let paths):
            pathLabel(
                icon: "doc.fill",
                title: paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files",
                detail: paths.count == 1
                    ? paths[0] : paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
        case nil:
            placeholderLabel(placeholder)
        }
    }

    private func placeholderLabel(_ text: String) -> some View {
        HStack {
            Text(text).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pathLabel(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func chooseFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func chooseDumps() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.init(filenameExtension: "sql")!, .init(filenameExtension: "gz")!]
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }
}

/// "Dump options for <database>": locking, routines/triggers/events and flags.
struct DumpOptionsView: View {
    let database: String
    @Binding var options: DumpOptions
    /// Engine features: events are MySQL/MariaDB only.
    var supportsEvents = true
    var onApplyToAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dump options for \(database)").font(.headline)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Locking")
                    Text(options.locking.explanation)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("Locking", selection: $options.locking) {
                    ForEach(DumpOptions.Locking.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            Toggle("Routines and triggers", isOn: $options.routinesAndTriggers)
            if supportsEvents { Toggle("Events", isOn: $options.events) }
            HStack {
                Text("Flags")
                Spacer()
                Menu(flagsSummary) {
                    Toggle("Structure (CREATE TABLE)", isOn: $options.structure)
                    Toggle("Data (INSERT)", isOn: $options.data)
                    Toggle("DROP TABLE before CREATE", isOn: $options.dropTables)
                    Toggle("CREATE DATABASE", isOn: $options.createDatabase)
                }
                .frame(width: 180)
            }
            if let onApplyToAll {
                HStack {
                    Spacer()
                    Button("Apply to All Databases", action: onApplyToAll)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(16)
        .frame(width: 420)
    }

    private var flagsSummary: String {
        var parts: [String] = []
        if options.structure { parts.append("Structure") }
        if options.data { parts.append("Data") }
        if options.dropTables { parts.append("DROP") }
        if options.createDatabase { parts.append("CREATE DB") }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: ", ")
    }
}

#if DEBUG
    #Preview("Dump options") {
        @Previewable @State var options = DumpOptions.standard
        DumpOptionsView(database: "shop", options: $options, onApplyToAll: {})
    }

    #Preview("Endpoint menu – empty") {
        EndpointMenu(placeholder: "Choose a Connection or Folder, Files…", current: nil, allowsFiles: true) { _ in }
            .environment(PreviewData.store())
            .padding()
            .frame(width: 420)
    }
#endif
