import SwiftUI
import TableRoadCore
import TableRoadDesign
import TableRoadMySQL
import TableRoadStorage

/// Create or edit a connection, with a live "Test" button.
struct ConnectionFormView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var profile: ConnectionProfile
    @State private var password: String
    @State private var testState: TestState = .idle
    @State private var saveError: String?
    private let isNew: Bool
    var onSaved: (ConnectionProfile) -> Void = { _ in }

    enum TestState: Equatable {
        case idle, testing
        case success(String)
        case failure(String)
    }

    init(profile: ConnectionProfile?, password: String?, onSaved: @escaping (ConnectionProfile) -> Void = { _ in }) {
        self.isNew = profile == nil
        _profile = State(initialValue: profile ?? ConnectionProfile(name: "", kind: .mysql, username: "root"))
        _password = State(initialValue: password ?? "")
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $profile.name, prompt: Text(defaultName))
                    Picker("Type", selection: $profile.kind) {
                        ForEach(DatabaseKind.allCases) { kind in
                            Text(kind.displayName + (kind.isAvailable ? "" : " (coming soon)"))
                                .tag(kind)
                                .selectionDisabled(!kind.isAvailable)
                        }
                    }
                    .onChange(of: profile.kind) { old, new in
                        if profile.port == old.defaultPort { profile.port = new.defaultPort }
                    }
                    Picker("Tag", selection: $profile.tag) {
                        ForEach(ConnectionTag.allCases, id: \.self) { tag in
                            Label {
                                Text(tag.label)
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(tag.color ?? .secondary)
                            }
                            .tag(tag)
                        }
                    }
                }
                Section {
                    LabeledContent("Host") {
                        HStack {
                            TextField("Host", text: $profile.host, prompt: Text("127.0.0.1")).labelsHidden()
                            TextField("Port", value: $profile.port, format: .number.grouping(.never))
                                .labelsHidden()
                                .frame(width: 70)
                        }
                    }
                    TextField("User", text: $profile.username)
                    SecureField("Password", text: $password)
                    TextField("Database", text: databaseBinding, prompt: Text("optional"))
                    Picker("TLS", selection: $profile.tls) {
                        Text("Disabled").tag(TLSMode.disable)
                        Text("Preferred").tag(TLSMode.prefer)
                        Text("Required").tag(TLSMode.require)
                        Text("Verify certificate").tag(TLSMode.verifyFull)
                    }
                }
                Section {
                    LabeledContent("SSH") {
                        Text("Over SSH arrives in Phase 3").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                testStatus
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Test") { Task { await test() } }
                    .disabled(testState == .testing)
                Button(isNew ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!profile.kind.isAvailable)
            }
            .padding(16)
        }
        .frame(width: 520)
        .alert("Couldn't Save", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var defaultName: String {
        profile.host.isEmpty ? "Untitled" : profile.host
    }

    private var databaseBinding: Binding<String> {
        Binding {
            profile.database ?? ""
        } set: {
            profile.database = $0.isEmpty ? nil : $0
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
            Text("Connecting…").foregroundStyle(.secondary)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
                .help(message)
        }
    }

    private func test() async {
        testState = .testing
        do {
            let session = try await MySQLSession.connect(MySQLConnectConfig(profile: profile, password: password))
            let version = await session.serverVersion
            let kind = await session.kind
            await session.close()
            let lock = session.isEncrypted ? "TLS" : "unencrypted"
            testState = .success("Connected to \(kind.displayName) \(version) (\(lock))")
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    private func save() {
        var profile = profile
        if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { profile.name = defaultName }
        do {
            try store.save(profile, password: password)
            onSaved(profile)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

extension DatabaseKind {
    /// Engines with a driver in this build.
    var isAvailable: Bool { self == .mysql || self == .mariadb }
}
