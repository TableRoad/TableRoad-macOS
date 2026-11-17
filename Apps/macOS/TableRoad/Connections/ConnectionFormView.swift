import AppKit
import SwiftUI
import TableRoadCore
import TableRoadDesign
import TableRoadMySQL
import TableRoadStorage
import UniformTypeIdentifiers

/// Create or edit a connection (TablePlus-style layout): identity, server, TLS, and optional SSH.
struct ConnectionFormView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var profile: ConnectionProfile
    @State private var password: String
    @State private var sshPassword: String
    @State private var useSSH: Bool
    @State private var useSSHKey: Bool
    @State private var testState: TestState = .idle
    @State private var saveError: String?
    @State private var editingBootstrap = false
    private let isNew: Bool
    var onSaved: (ConnectionProfile) -> Void
    /// Called after Connect saves; opens the workspace.
    var onConnect: (ConnectionProfile) -> Void

    enum TestState: Equatable {
        case idle, testing
        case success(String)
        case failure(String)
    }

    init(
        profile: ConnectionProfile?, password: String?, sshPassword: String? = nil,
        onSaved: @escaping (ConnectionProfile) -> Void = { _ in },
        onConnect: @escaping (ConnectionProfile) -> Void = { _ in }
    ) {
        isNew = profile == nil
        let initial = profile ?? ConnectionProfile(name: "", kind: .mysql, username: "root")
        _profile = State(initialValue: initial)
        _password = State(initialValue: password ?? "")
        _sshPassword = State(initialValue: sshPassword ?? "")
        _useSSH = State(initialValue: initial.ssh != nil)
        if case .password = initial.ssh?.auth {
            _useSSHKey = State(initialValue: false)
        } else {
            _useSSHKey = State(initialValue: initial.ssh != nil)
        }
        self.onSaved = onSaved
        self.onConnect = onConnect
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("\(profile.kind.displayName) Connection").font(.headline)
            identitySection
            serverSection
            if useSSH { sshSection }
            footer
        }
        .padding(20)
        .frame(width: 600)
        .alert("Couldn't Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .sheet(isPresented: $editingBootstrap) {
            BootstrapCommandsSheet(
                sql: Binding(get: { profile.bootstrapSQL ?? "" }, set: { profile.bootstrapSQL = $0 }))
        }
    }

    // MARK: Sections

    private var identitySection: some View {
        FormBox {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                if isNew {
                    GridRow {
                        label("Type")
                        Picker("Type", selection: $profile.kind) {
                            ForEach(DatabaseKind.allCases) { kind in
                                Text(kind.displayName + (kind.isAvailable ? "" : " (coming soon)"))
                                    .tag(kind)
                                    .selectionDisabled(!kind.isAvailable)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: profile.kind) { old, new in
                            if profile.port == old.defaultPort { profile.port = new.defaultPort }
                        }
                    }
                }
                GridRow {
                    label("Name")
                    TextField("Name", text: $profile.name, prompt: Text(defaultName)).labelsHidden()
                }
                GridRow {
                    label("Status Color")
                    HStack(spacing: 8) {
                        StatusColorPicker(selection: $profile.statusColor)
                        Spacer(minLength: 12)
                        Text("Tag")
                        Picker("Tag", selection: $profile.tag) {
                            ForEach(ConnectionTag.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("Production-tagged connections ask before saving changes")
                    }
                }
                GridRow {
                    label("Safe Mode")
                    Picker("Safe Mode", selection: $profile.safeMode) {
                        ForEach(SafeMode.allCases, id: \.self) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private var serverSection: some View {
        FormBox {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Host/IP")
                    HStack {
                        TextField("Host", text: $profile.host, prompt: Text("127.0.0.1")).labelsHidden()
                        Text("Port")
                        TextField("Port", value: $profile.port, format: .number.grouping(.never))
                            .labelsHidden()
                            .frame(width: 70)
                    }
                }
                GridRow {
                    label("User")
                    TextField("User", text: $profile.username, prompt: Text("user name")).labelsHidden()
                }
                GridRow {
                    label("Password")
                    HStack {
                        SecureField("Password", text: $password, prompt: Text(passwordPrompt)).labelsHidden()
                            .disabled(profile.passwordStorage == .askEachTime)
                        Picker("Password storage", selection: $profile.passwordStorage) {
                            Text("Store in Keychain").tag(PasswordStorage.keychain)
                            Text("Ask every time").tag(PasswordStorage.askEachTime)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                GridRow {
                    label("Database")
                    HStack {
                        TextField("Database", text: databaseBinding, prompt: Text("database name")).labelsHidden()
                        Button(profile.bootstrapSQL?.isEmpty == false ? "Bootstrap commands ✓" : "Bootstrap commands…")
                        {
                            editingBootstrap = true
                        }
                        .help("SQL run every time a connection opens, e.g. SET time_zone = '+00:00'")
                    }
                }
                GridRow {
                    label("SSL mode")
                    Picker("SSL mode", selection: $profile.tls) {
                        ForEach(TLSMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .help(profile.tls.explanation)
                }
                GridRow {
                    label("SSL keys")
                    HStack {
                        CertificateButton(title: "Key", path: $profile.tlsFiles.clientKeyPath)
                        CertificateButton(title: "Cert", path: $profile.tlsFiles.clientCertPath)
                        CertificateButton(title: "CA Cert", path: $profile.tlsFiles.caCertPath)
                        Button {
                            profile.tlsFiles = TLSFiles()
                        } label: {
                            Image(systemName: "minus").frame(width: 12)
                        }
                        .disabled(profile.tlsFiles.isEmpty)
                        .help("Remove all certificate files")
                    }
                }
            }
        }
    }

    private var sshSection: some View {
        FormBox {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Server")
                    HStack {
                        TextField("SSH server", text: sshBinding(\.host), prompt: Text("192.168.1.1")).labelsHidden()
                        Text("Port")
                        TextField("SSH port", value: sshBinding(\.port), format: .number.grouping(.never))
                            .labelsHidden()
                            .frame(width: 70)
                    }
                }
                GridRow {
                    label("User")
                    TextField("SSH user", text: sshBinding(\.username), prompt: Text("user name")).labelsHidden()
                }
                if !useSSHKey {
                    GridRow {
                        label("Password")
                        SecureField("SSH password", text: $sshPassword, prompt: Text("password")).labelsHidden()
                    }
                }
                GridRow {
                    Toggle("Use SSH key", isOn: $useSSHKey).toggleStyle(.checkbox)
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button {
                                pickSSHKey()
                            } label: {
                                Text(sshKeyTitle).lineLimit(1).frame(maxWidth: .infinity)
                            }
                            .disabled(!useSSHKey)
                            Button {
                                profile.ssh?.auth = .agent(socketPath: nil)
                            } label: {
                                Image(systemName: "minus").frame(width: 12)
                            }
                            .disabled(!useSSHKey || sshKeyPath == nil)
                        }
                        Text("If no key is chosen, TableRoad uses ~/.ssh/config and your SSH agent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: useSSHKey) { _, usesKey in
            profile.ssh?.auth = usesKey ? .agent(socketPath: nil) : .password
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if testState != .idle { testStatus }
            HStack {
                Toggle(isOn: $useSSH) { Text("Over SSH") }
                    .toggleStyle(.button)
                    .onChange(of: useSSH) { _, enabled in
                        if enabled && profile.ssh == nil {
                            profile.ssh = SSHConfig(host: "", username: "", auth: .password)
                        }
                    }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: { save(thenConnect: false) })
                    .disabled(!profile.kind.isAvailable)
                Button("Test") { Task { await test() } }
                    .disabled(testState == .testing)
                Button("Connect", action: { save(thenConnect: true) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(!profile.kind.isAvailable)
            }
        }
    }

    // MARK: Helpers

    private func label(_ text: String) -> some View {
        Text(text).gridColumnAlignment(.trailing)
    }

    private var defaultName: String { profile.host.isEmpty ? "Untitled" : profile.host }

    private var passwordPrompt: String {
        profile.passwordStorage == .askEachTime ? "asked when connecting" : "password"
    }

    private var databaseBinding: Binding<String> {
        Binding {
            profile.database ?? ""
        } set: {
            profile.database = $0.isEmpty ? nil : $0
        }
    }

    private func sshBinding<Value>(_ keyPath: WritableKeyPath<SSHConfig, Value>) -> Binding<Value> {
        Binding {
            (profile.ssh ?? SSHConfig(host: "", username: "", auth: .password))[keyPath: keyPath]
        } set: { value in
            var ssh = profile.ssh ?? SSHConfig(host: "", username: "", auth: .password)
            ssh[keyPath: keyPath] = value
            profile.ssh = ssh
        }
    }

    private var sshKeyPath: String? {
        if case .privateKey(.file(let path)) = profile.ssh?.auth { return path }
        return nil
    }

    private var sshKeyTitle: String {
        sshKeyPath.map { ($0 as NSString).lastPathComponent } ?? "Import a private key…"
    }

    private func pickSSHKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose an SSH private key"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        profile.ssh?.auth = .privateKey(.file(path: url.path))
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(2)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3).help(message)
        }
    }

    private func test() async {
        if useSSH {
            testState = .failure("Connecting over SSH arrives in Phase 3; these settings are saved for then.")
            return
        }
        testState = .testing
        do {
            let session = try await MySQLSession.connect(MySQLConnectConfig(profile: profile, password: password))
            let version = await session.serverVersion
            let kind = await session.kind
            let cipher = session.tlsCipher
            await session.close()
            testState = .success(
                "Connected to \(kind.displayName) \(version) · " + (cipher.map { "TLS (\($0))" } ?? "unencrypted"))
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    private func save(thenConnect: Bool) {
        var profile = profile
        if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { profile.name = defaultName }
        if !useSSH { profile.ssh = nil }
        do {
            try store.save(profile, password: profile.passwordStorage == .keychain ? password : nil)
            try store.setSSHPassword(useSSH && !useSSHKey ? sshPassword : nil, for: profile.id)
            onSaved(profile)
            dismiss()
            if thenConnect { onConnect(profile) }
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Rounded panel grouping related fields.
private struct FormBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// None + pastel swatches, like TablePlus's Status Color.
struct StatusColorPicker: View {
    @Binding var selection: StatusColor

    var body: some View {
        HStack(spacing: 6) {
            ForEach(StatusColor.allCases, id: \.self) { color in
                Button {
                    selection = color
                } label: {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.swatch ?? Color.clear)
                        .overlay {
                            if color == .none {
                                Image(systemName: "nosign").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(
                                    selection == color ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: selection == color ? 2 : 0.5)
                        )
                        .frame(width: 30, height: 22)
                }
                .buttonStyle(.plain)
                .help(color.label)
                .accessibilityLabel("Status color \(color.label)")
            }
        }
    }
}

/// Picks a PEM file; shows its name once chosen.
private struct CertificateButton: View {
    let title: String
    @Binding var path: String?

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.title = "Choose the \(title) file (PEM)"
            panel.canChooseDirectories = false
            panel.showsHiddenFiles = true
            if panel.runModal() == .OK { path = panel.url?.path }
        } label: {
            // Frame inside the label so the bezel itself stretches.
            Text(path.map { ($0 as NSString).lastPathComponent } ?? "\(title)…")
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
        }
        .help(path ?? "Choose a PEM file")
    }
}

/// SQL run on every new connection.
struct BootstrapCommandsSheet: View {
    @Binding var sql: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bootstrap Commands").font(.headline)
            Text("Run on every new connection, before anything else. Separate statements with semicolons.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $sql)
                .font(.body.monospaced())
                .frame(width: 480, height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Text("e.g. SET time_zone = '+00:00'; SET SESSION sql_mode = 'TRADITIONAL'")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

extension DatabaseKind {
    /// Engines with a driver in this build.
    var isAvailable: Bool { self == .mysql || self == .mariadb }
}

extension SafeMode {
    var title: String {
        switch self {
        case .off: "Silent – send queries to the server without asking"
        case .confirmWrites: "Alert – confirm before saving changes"
        case .readOnly: "Read-only – block all changes"
        }
    }

    var systemImage: String {
        switch self {
        case .off: "lock.open"
        case .confirmWrites: "exclamationmark.shield"
        case .readOnly: "lock"
        }
    }
}

extension TLSMode {
    var title: String {
        switch self {
        case .disable: "DISABLED"
        case .prefer: "PREFERRED"
        case .require: "REQUIRED"
        case .verifyCA: "VERIFY_CA"
        case .verifyFull: "VERIFY_IDENTITY"
        }
    }

    var explanation: String {
        switch self {
        case .disable: "Never use TLS."
        case .prefer: "Use TLS if the server offers it."
        case .require: "Require TLS; don't check the certificate."
        case .verifyCA: "Require TLS and check the certificate against the CA (not the hostname)."
        case .verifyFull: "Require TLS and check the certificate and hostname."
        }
    }
}

#if DEBUG
    #Preview("New connection") {
        ConnectionFormView(profile: nil, password: nil)
            .environment(PreviewData.store(empty: true))
    }

    #Preview("Edit with SSH") {
        ConnectionFormView(profile: PreviewData.profiles[0], password: "secret")
            .environment(PreviewData.store())
    }

    #Preview("Bootstrap commands") {
        BootstrapCommandsSheet(sql: .constant("SET time_zone = '+00:00';"))
    }
#endif
