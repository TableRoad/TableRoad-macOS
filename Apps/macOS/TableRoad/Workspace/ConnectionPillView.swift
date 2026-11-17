import SwiftUI
import TableRoadCore
import TableRoadDesign
import TableRoadStorage

/// "MySQL 8.4.13 : host : db" in the toolbar, tinted with the status colour. Click for connection details and
/// Disconnect / Reconnect / Edit (TablePlus-style).
struct ConnectionPillView: View {
    @Bindable var model: WorkspaceModel
    /// Fills the toolbar's free space, like TablePlus (worked out by the workspace from its width).
    var width: CGFloat = 420
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showingDetails = false
    @State private var editing = false

    var body: some View {
        Button {
            showingDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                if model.link != .ok {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(pillText)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 16)
            // As tall as the toolbar's own controls, with the colour filling the whole capsule. The width comes from
            // the window (toolbar items can't stretch; an oversized ideal width pushes everything into overflow).
            .frame(width: width, height: 34)
            .background(
                (model.profile.statusColor.swatch ?? Color.primary.opacity(0.06)),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Connection details")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            details
        }
        .sheet(isPresented: $editing) {
            ConnectionFormView(
                profile: model.profile, password: store.password(for: model.profile.id),
                sshPassword: store.sshPassword(for: model.profile.id),
                onSaved: { saved in
                    model.apply(edited: saved, password: store.password(for: saved.id))
                }
            )
            .environment(store)
        }
    }

    private var pillText: String {
        let driver = "\(model.profile.kind.displayName) \(shortVersion)"
        return [driver, model.profile.host, model.selectedDatabase ?? "—"].joined(separator: " : ")
    }

    private var shortVersion: String {
        model.serverVersion.split(separator: "-").first.map(String.init) ?? model.serverVersion
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusColorPicker(
                selection: Binding(
                    get: { model.profile.statusColor },
                    set: { color in
                        var updated = model.profile
                        updated.statusColor = color
                        try? store.save(updated, password: store.password(for: updated.id))
                        model.updateCosmetics(from: updated)
                    }))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Server", "\(model.profile.host):\(model.profile.port)")
                row("Driver", "\(model.profile.kind.displayName) \(model.serverVersion)")
                row("Database", model.selectedDatabase ?? "—")
                row("User", model.profile.username)
                row("Cipher", model.tlsCipher ?? "Insecure (no cipher)", warn: model.tlsCipher == nil)
                if model.profile.ssh != nil { row("Via SSH", model.profile.ssh?.host ?? "") }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Disconnect") {
                    showingDetails = false
                    dismiss()
                }
                Spacer()
                Button("Reconnect") {
                    showingDetails = false
                    model.reconnectAll()
                }
                Button("Edit…") {
                    showingDetails = false
                    editing = true
                }
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        GridRow {
            Text(label + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
                .foregroundStyle(warn ? .orange : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// Shown for "ask every time" connections before connecting.
struct PasswordPromptView: View {
    let model: WorkspaceModel
    let error: String?
    @State private var password = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("Password for \(model.profile.username)@\(model.profile.host)").font(.headline)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(connect)
            Button("Connect", action: connect)
                .keyboardShortcut(.defaultAction)
            Text("This connection doesn't store its password.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() {
        let typed = password
        Task { await model.connect(withPassword: typed) }
    }
}

#if DEBUG
    #Preview("Connection pill") {
        ConnectionPillView(model: .preview())
            .environment(PreviewData.store())
            .padding()
    }

    #Preview("Password prompt") {
        PasswordPromptView(model: .preview(), error: "Access denied for user 'app'@'10.0.0.5' (1045)")
            .frame(width: 600, height: 400)
    }
#endif
