import SwiftUI
import TableRoadCore
import TableRoadDesign

/// TablePlus-style launcher: brand panel on the left, saved connections on the right.
struct WelcomeView: View {
    @Environment(ConnectionList.self) private var connections
    @State private var showingURLImport = false

    var body: some View {
        HStack(spacing: 0) {
            brandPanel
            connectionPanel
        }
        .frame(width: 760, height: 460)
        .sheet(isPresented: $showingURLImport) {
            ImportURLSheet { profile in connections.add(profile) }
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
                Button("Create Connection…") {}
                    .disabled(true)
                    .help("Connection form arrives in Phase 1")
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

    @ViewBuilder
    private var connectionPanel: some View {
        if connections.profiles.isEmpty {
            ContentUnavailableView {
                Label("No Connections", systemImage: "cylinder.split.1x2")
            } description: {
                Text("Create a connection, or paste a postgres://, mysql://, mariadb:// or redis:// URL.")
            } actions: {
                Button("Import from URL…") { showingURLImport = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(connections.profiles) { profile in
                ConnectionRow(profile: profile)
            }
            .listStyle(.inset)
        }
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
    var onImport: (ConnectionProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from URL").font(.headline)
            TextField("postgres://user:password@host:5432/database", text: $text)
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
                Button("Import", action: importURL)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty)
            }
        }
        .padding(20)
    }

    private func importURL() {
        do {
            // The password is parsed but not kept yet; Phase 1 stores it in the Keychain.
            onImport(try ConnectionURL.parse(text).profile)
            dismiss()
        } catch {
            self.error = "That doesn't look like a supported connection URL (\(error))."
        }
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
