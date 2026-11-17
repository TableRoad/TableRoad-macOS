import AppKit
import Observation
import SwiftUI
import TableRoadCore
import TableRoadDesign
import TableRoadRedis

/// State for a Redis connection window: keys (scanned by pattern), the selected key's value, and a console.
@MainActor @Observable
final class RedisWorkspaceModel {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    struct ConsoleLine: Identifiable {
        let id = UUID()
        var text: String
        var isCommand: Bool
        var isError: Bool = false
    }

    let profile: ConnectionProfile
    private let password: String?
    private(set) var session: RedisSession?
    private(set) var state: State = .connecting
    private(set) var serverVersion = ""
    var pattern = "*"
    private(set) var keys: [RedisKey] = []
    private(set) var truncated = false
    private(set) var isScanning = false
    var selectedKey: String? {
        didSet { if oldValue != selectedKey { Task { await loadValue() } } }
    }
    private(set) var value: RedisValue?
    private(set) var error: String?
    private(set) var console: [ConsoleLine] = []
    var database = 0
    var showsConsole = false

    var isReadOnly: Bool { profile.safeMode == .readOnly }

    init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        self.password = password
        database = profile.database.flatMap { Int($0) } ?? 0
    }

    func connect() async {
        state = .connecting
        do {
            let session = try await RedisSession.connect(RedisConnectConfig(profile: profile, password: password))
            self.session = session
            serverVersion = await session.serverVersion
            state = .connected
            await scan()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        await session?.close()
        session = nil
    }

    func scan() async {
        guard let session else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let result = try await session.scan(pattern: pattern.isEmpty ? "*" : pattern)
            keys = result.keys
            truncated = result.truncated
            error = nil
            if let selectedKey, !keys.contains(where: { $0.name == selectedKey }) { self.selectedKey = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(database index: Int) async {
        guard let session else { return }
        do {
            try await session.command(["SELECT", String(index)])
            database = index
            selectedKey = nil
            await scan()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadValue() async {
        guard let session, let key = selectedKey else {
            value = nil
            return
        }
        do {
            value = try await session.value(of: key)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveString(_ text: String) async {
        guard !isReadOnly, let session, let key = selectedKey else { return }
        do {
            // KEEPTTL keeps an expiring key expiring.
            try await session.command(["SET", key, text, "KEEPTTL"])
            await loadValue()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setTTL(_ seconds: Int?) async {
        guard !isReadOnly, let session, let key = selectedKey else { return }
        do {
            if let seconds {
                try await session.command(["EXPIRE", key, String(seconds)])
            } else {
                try await session.command(["PERSIST", key])
            }
            await scan()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ names: [String]) async {
        guard !isReadOnly, let session, !names.isEmpty else { return }
        do {
            try await session.command(["UNLINK"] + names)
            if let selectedKey, names.contains(selectedKey) { self.selectedKey = nil }
            await scan()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Runs a console line like redis-cli. Read-only connections only allow commands that can't write.
    func run(_ line: String) async {
        let arguments = RedisSession.arguments(line)
        guard let session, let name = arguments.first else { return }
        console.append(ConsoleLine(text: "\(database)> " + line, isCommand: true))
        if isReadOnly && !Self.readOnlyCommands.contains(name.uppercased()) {
            console.append(ConsoleLine(text: "(error) This connection is read-only.", isCommand: false, isError: true))
            return
        }
        do {
            let reply = try await session.rawCommand(arguments)
            if name.uppercased() == "SELECT", case .simple = reply,
                let index = arguments.dropFirst().first.flatMap({ Int($0) })
            {
                database = index
            }
            let isError: Bool = if case .error = reply { true } else { false }
            console.append(ConsoleLine(text: reply.formatted(), isCommand: false, isError: isError))
        } catch {
            console.append(ConsoleLine(text: "(error) \(error.localizedDescription)", isCommand: false, isError: true))
        }
        if console.count > 1000 { console.removeFirst(console.count - 1000) }
    }

    static let readOnlyCommands: Set<String> = [
        "GET", "MGET", "STRLEN", "GETRANGE", "EXISTS", "TYPE", "TTL", "PTTL", "SCAN", "KEYS", "HGET", "HMGET",
        "HGETALL",
        "HKEYS", "HVALS", "HLEN", "HSCAN", "HEXISTS", "LRANGE", "LLEN", "LINDEX", "SMEMBERS", "SCARD", "SISMEMBER",
        "SSCAN", "SRANDMEMBER", "ZRANGE", "ZRANGEBYSCORE", "ZREVRANGE", "ZCARD", "ZSCORE", "ZRANK", "ZSCAN", "ZCOUNT",
        "XRANGE", "XREVRANGE", "XLEN", "XINFO", "INFO", "PING", "DBSIZE", "SELECT", "OBJECT", "MEMORY", "TIME",
        "CLIENT", "CONFIG", "SLOWLOG", "COMMAND", "ECHO", "RANDOMKEY",
    ]

    #if DEBUG
        static func preview() -> RedisWorkspaceModel {
            let model = RedisWorkspaceModel(
                profile: ConnectionProfile(name: "Cache", kind: .redis, host: "127.0.0.1", port: 6379), password: nil)
            model.state = .connected
            model.serverVersion = "7.4.1"
            model.keys = [
                RedisKey(name: "session:abc", type: "hash", ttl: 3600),
                RedisKey(name: "greeting", type: "string", ttl: nil),
                RedisKey(name: "queue:jobs", type: "list", ttl: nil),
                RedisKey(name: "leaderboard", type: "zset", ttl: nil),
            ]
            model.selectedKey = nil
            model.value = .hash([("user_id", "42"), ("csrf", "x1y2z3")])
            model.console = [
                ConsoleLine(text: "0> GET greeting", isCommand: true), ConsoleLine(text: "\"hello\"", isCommand: false),
            ]
            return model
        }
    #endif
}

/// The window for a Redis connection.
struct RedisWorkspaceView: View {
    @State private var model: RedisWorkspaceModel
    @State private var consoleInput = ""
    @State private var stringDraft = ""
    @State private var ttlDraft = ""
    @State private var confirmingDelete: [String]?

    init(profile: ConnectionProfile, password: String?) {
        _model = State(initialValue: RedisWorkspaceModel(profile: profile, password: password))
    }

    init(model: RedisWorkspaceModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            switch model.state {
            case .connecting:
                ProgressView("Connecting to \(model.profile.name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Connect", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { Task { await model.connect() } }
                }
            case .connected:
                connected
            }
        }
        .navigationTitle(model.profile.name)
        .toolbar(removing: .title)
        .task { if model.state == .connecting { await model.connect() } }
        .onDisappear { Task { await model.disconnect() } }
        .confirmationDialog(
            "Delete \(confirmingDelete?.count ?? 0) key(s)?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let names = confirmingDelete { Task { await model.delete(names) } }
                confirmingDelete = nil
            }
        }
    }

    private var connected: some View {
        NavigationSplitView {
            keyList.navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 480)
        } detail: {
            VStack(spacing: 0) {
                if let color = model.profile.displayAccent { color.frame(height: 3) }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.red.opacity(0.08))
                }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showsConsole {
                    Divider()
                    consoleView.frame(height: 220)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker(
                    "Database",
                    selection: Binding(
                        get: { model.database },
                        set: { index in
                            Task { await model.select(database: index) }
                        })
                ) {
                    ForEach(0..<16, id: \.self) { Text("db\($0)").tag($0) }
                }
                .help("Redis logical database")
            }
            ToolbarItem(placement: .principal) {
                Text("Redis \(model.serverVersion) : \(model.profile.host) : db\(model.database)")
                    .font(.callout.monospaced())
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(model.profile.statusColor.swatch ?? Color.primary.opacity(0.06), in: Capsule())
            }
            ToolbarItem {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }
            ToolbarItem {
                Button {
                    model.showsConsole.toggle()
                } label: {
                    Label("Console", systemImage: "terminal")
                }
                .keyboardShortcut("`", modifiers: [.command])
                .help("Show or hide the command console (⌘`)")
            }
        }
    }

    private var keyList: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("Pattern, e.g. user:*", text: $model.pattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.scan() } }
                if model.isScanning { ProgressView().controlSize(.small) }
            }
            .padding([.horizontal, .top], 8)
            List(model.keys, selection: $model.selectedKey) { key in
                HStack(spacing: 6) {
                    Text(key.type.uppercased().prefix(4))
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36)
                        .padding(.vertical, 1)
                        .background(Self.color(for: key.type), in: RoundedRectangle(cornerRadius: 3))
                    Text(key.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let ttl = key.ttl {
                        Image(systemName: "timer").font(.caption).foregroundStyle(.secondary).help("Expires in \(ttl)s")
                    }
                }
                .tag(key.name)
                .contextMenu {
                    Button("Copy Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key.name, forType: .string)
                    }
                    Button("Delete…", role: .destructive) { confirmingDelete = [key.name] }
                        .disabled(model.isReadOnly)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 20)
            Text(
                "\(model.keys.count.formatted()) key(s)"
                    + (model.truncated ? " (first 1,000 shown; narrow the pattern)" : "")
            )
            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
        }
    }

    static func color(for type: String) -> Color {
        switch type {
        case "string": .blue
        case "hash": .purple
        case "list": .green
        case "set": .orange
        case "zset": .pink
        case "stream": .teal
        default: .gray
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let key = model.selectedKey, let value = model.value {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(key).font(.headline.monospaced()).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    TextField("TTL (s)", text: $ttlDraft).frame(width: 90)
                    Button("Set TTL") { Task { await model.setTTL(Int(ttlDraft)) } }
                        .help("Seconds until the key expires; empty removes the expiry")
                    Button("Delete…", role: .destructive) { confirmingDelete = [key] }
                }
                .disabled(model.isReadOnly)
                .padding(10)
                Divider()
                valueView(value)
            }
            .onAppear(perform: syncDrafts)
            .onChange(of: model.value) { syncDrafts() }
        } else {
            ContentUnavailableView(
                "No Key Selected", systemImage: "key",
                description: Text("Pick a key on the left, or open the console (⌘`)."))
        }
    }

    private func syncDrafts() {
        if case .string(let text) = model.value { stringDraft = text }
        ttlDraft = model.keys.first { $0.name == model.selectedKey }?.ttl.map(String.init) ?? ""
    }

    @ViewBuilder
    private func valueView(_ value: RedisValue) -> some View {
        switch value {
        case .string:
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $stringDraft).font(.body.monospaced())
                Button("Save") { Task { await model.saveString(stringDraft) } }
                    .keyboardShortcut("s")
                    .disabled(
                        model.isReadOnly
                            || { if case .string(let text) = value { text == stringDraft } else { true } }())
            }
            .padding(10)
        case .hash(let pairs):
            table(["field", "value"], pairs.map { [$0.field, $0.value] })
        case .list(let items):
            table(["index", "value"], items.enumerated().map { [String($0.offset), $0.element] })
        case .set(let items):
            table(["member"], items.map { [$0] })
        case .zset(let items):
            table(["member", "score"], items.map { [$0.member, $0.score] })
        case .stream(let entries):
            table(
                ["id", "fields"], entries.map { [$0.id, $0.fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")] })
        case .missing:
            ContentUnavailableView(
                "Key Not Found", systemImage: "questionmark", description: Text("It may have expired."))
        case .unsupported(let type):
            ContentUnavailableView(
                "Unsupported Type", systemImage: "questionmark.square",
                description: Text("“\(type)” values can be read in the console."))
        }
    }

    private func table(_ columns: [String], _ rows: [[String]]) -> some View {
        DataGridView(
            result: ResultSet(
                columns: columns.map { ResultColumn(name: $0, typeName: "TEXT") },
                rows: rows.map { $0.map { CellValue.text($0) } }),
            revision: AnyHashable(rows))
    }

    private var consoleView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.console) { line in
                            Text(line.text)
                                .font(.callout.monospaced())
                                .foregroundStyle(line.isError ? .red : line.isCommand ? .secondary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.console.count) {
                    if let last = model.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack {
                Text("\(model.database)>").font(.callout.monospaced()).foregroundStyle(.secondary)
                TextField("Command, e.g. HGETALL session:abc", text: $consoleInput)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .onSubmit {
                        let line = consoleInput
                        consoleInput = ""
                        Task { await model.run(line) }
                    }
            }
            .padding(8)
            .background(.bar)
        }
    }
}

#if DEBUG
    #Preview("Redis workspace") {
        RedisWorkspaceView(model: .preview())
            .frame(width: 1000, height: 640)
    }
#endif
