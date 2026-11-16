import SwiftUI
import TableRoadCore
import TableRoadDesign
import TableRoadStorage

/// TablePlus-style launcher: brand panel on the left, saved connections on the right.
struct WelcomeView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var selection: UUID?
    @State private var search = ""
    @State private var editor: EditorRequest?
    @State private var showingURLImport = false
    @State private var pendingDelete: ConnectionProfile?

    /// Which profile the form sheet edits (`nil` profile = new connection).
    struct EditorRequest: Identifiable {
        let id = UUID()
        var profile: ConnectionProfile?
        var password: String?
    }

    var body: some View {
        HStack(spacing: 0) {
            brandPanel
            connectionPanel
        }
        .frame(width: 760, height: 460)
        .task {
            #if DEBUG
                if let name = DevFixtures.openConnection, let profile = store.profiles.first(where: { $0.name == name })
                {
                    open(profile.id)
                }
            #endif
        }
        .sheet(item: $editor) { request in
            ConnectionFormView(profile: request.profile, password: request.password) { saved in
                selection = saved.id
            }
            .environment(store)
        }
        .sheet(isPresented: $showingURLImport) {
            ImportURLSheet { parsed in
                editor = EditorRequest(profile: parsed.profile, password: parsed.password)
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?", isPresented: .constant(pendingDelete != nil),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { try? store.delete(pendingDelete.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Its saved password is removed from the Keychain too.")
        }
    }

    private var brandPanel: some View {
        VStack(spacing: 14) {
            Spacer()
            RoadMark(size: 140)
            Wordmark(size: 30)
            Text("Version \(Bundle.main.shortVersion)")
                .font(.caption)
                .foregroundStyle(Brand.cream.opacity(0.6))
            Spacer()
            VStack(spacing: 8) {
                Button("Create Connection…") { editor = EditorRequest() }
                    .keyboardShortcut("n")
                Button("Import from URL…") { showingURLImport = true }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 28)
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(Brand.teal)
        .environment(\.colorScheme, .dark)
    }

    private var filtered: [ConnectionProfile] {
        let sorted = store.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !search.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search)
        }
    }

    @ViewBuilder
    private var connectionPanel: some View {
        if let loadError = store.loadError {
            ContentUnavailableView(
                "Couldn't Load Connections", systemImage: "exclamationmark.triangle", description: Text(loadError)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.profiles.isEmpty {
            ContentUnavailableView {
                Label("No Connections", systemImage: "cylinder.split.1x2")
            } description: {
                Text("Create a connection, or paste a mysql:// or mariadb:// URL.")
            } actions: {
                Button("Create Connection…") { editor = EditorRequest() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                TextField("Search connections", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
                List(filtered, selection: $selection) { profile in
                    ConnectionRow(profile: profile).tag(profile.id)
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let profile = store.profile(id: id) {
                        Button("Connect") { open(id) }
                        Button("Edit…") { edit(profile) }
                        Button("Duplicate") { _ = try? store.duplicate(profile) }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = profile }
                    }
                } primaryAction: { ids in
                    ids.first.map(open)
                }
                .onKeyPress(.return) {
                    selection.map(open)
                    return .handled
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func open(_ id: UUID) {
        openWindow(value: id)
    }

    private func edit(_ profile: ConnectionProfile) {
        editor = EditorRequest(profile: profile, password: store.password(for: profile.id))
    }
}

struct ConnectionRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(profile.tag.color ?? .secondary.opacity(0.3))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(profile.kind.displayName)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = ["\(profile.username.isEmpty ? "" : profile.username + "@")\(profile.host):\(profile.port)"]
        if let database = profile.database { parts.append(database) }
        if profile.ssh != nil { parts.append("via SSH") }
        return parts.joined(separator: " · ")
    }
}

struct ImportURLSheet: View {
    var onImport: (ConnectionURL.Parsed) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from URL").font(.headline)
            TextField("mysql://user:password@host:3306/database", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(width: 440)
                .onSubmit(importURL)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Continue", action: importURL)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty)
            }
        }
        .padding(20)
    }

    private func importURL() {
        do {
            let parsed = try ConnectionURL.parse(text)
            dismiss()
            // Open the form after this sheet has gone so the user can review before saving.
            DispatchQueue.main.async { onImport(parsed) }
        } catch {
            self.error = "That doesn't look like a supported connection URL."
        }
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
