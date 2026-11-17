import SwiftUI
import TableRoadCore
import TableRoadSQL

/// "Open database" (⌘K): search, open, create and drop databases.
struct DatabasePickerSheet: View {
    let model: WorkspaceModel
    /// Opens a database alongside this one, in the window's rail (nil hides the option).
    var onOpenInNewWorkspace: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?
    @State private var creating = false
    @State private var dropping: String?

    var body: some View {
        VStack(spacing: 10) {
            Text("Open \(noun.capitalized)").font(.headline)
            TextField("Search for \(noun)…", text: $search)
                .textFieldStyle(.roundedBorder)
            List(filtered, id: \.self, selection: $selection) { name in
                DatabaseRow(
                    name: name, isSystem: WorkspaceModel.systemDatabases.contains(name),
                    isCurrent: name == model.selectedDatabase)
            }
            .contextMenu(forSelectionType: String.self) { names in
                if let name = names.first {
                    Button("Open") { open(name) }
                    if let onOpenInNewWorkspace {
                        Button("Open in New Workspace") {
                            onOpenInNewWorkspace(name)
                            dismiss()
                        }
                    }
                    Divider()
                    Button("Drop Database…", role: .destructive) { dropping = name }
                        .disabled(!canDrop(name))
                }
            } primaryAction: { names in
                if let name = names.first { open(name) }
            }
            .frame(minHeight: 260)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Drop…", role: .destructive) { dropping = selection }
                    .disabled(selection.map { !canDrop($0) } ?? true)
                    .help(model.canModifyDatabases ? "Delete the selected database" : "This connection is read-only")
                Button("New…") { creating = true }
                    .disabled(!model.canModifyDatabases)
                    .help(model.canModifyDatabases ? "Create a database" : "This connection is read-only")
                if let onOpenInNewWorkspace {
                    Button("Open in New Workspace") {
                        if let selection { onOpenInNewWorkspace(selection) }
                        dismiss()
                    }
                    .keyboardShortcut(.return, modifiers: .option)
                    .disabled(selection == nil)
                    .help("Open it alongside this one, in the window's rail (⌥↩)")
                }
                Button("Open") { if let selection { open(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 540, height: 460)
        .onAppear { selection = model.selectedDatabase }
        .task { await model.reloadDatabases() }
        .onSubmit(of: .text) { if filtered.count == 1 { open(filtered[0]) } }
        .sheet(isPresented: $creating) {
            CreateDatabaseSheet(model: model) { created in
                selection = created
                dismiss()
            }
        }
        .sheet(item: Binding(get: { dropping.map(DropTarget.init) }, set: { dropping = $0?.name })) { target in
            DropDatabaseSheet(model: model, name: target.name) { selection = nil }
        }
    }

    /// "database", or "schema" for PostgreSQL.
    private var noun: String { model.session?.capabilities.databaseNoun ?? "database" }

    private var filtered: [String] {
        search.isEmpty ? model.databases : model.databases.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private func canDrop(_ name: String) -> Bool {
        model.canModifyDatabases && !WorkspaceModel.systemDatabases.contains(name)
    }

    private func open(_ name: String) {
        model.selectedDatabase = name
        dismiss()
    }

    private struct DropTarget: Identifiable {
        let name: String
        var id: String { name }
    }
}

private struct DatabaseRow: View {
    let name: String
    let isSystem: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.fill")
                .foregroundStyle(isSystem ? Color.secondary : Color.accentColor)
            Text(name)
            if isSystem {
                Text("system").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark").foregroundStyle(.secondary).help("Current database")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Name, character set and collation (both optional: the server's defaults are used otherwise).
struct CreateDatabaseSheet: View {
    let model: WorkspaceModel
    var onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var characterSet = ""
    @State private var collation = ""
    @State private var sets: [CharacterSetInfo] = []
    @State private var error: String?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Database").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Name", text: $name, prompt: Text("database_name")).labelsHidden()
                }
                GridRow {
                    Text("Character set")
                    Picker("Character set", selection: $characterSet) {
                        Text("Server default").tag("")
                        Divider()
                        ForEach(sets) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .onChange(of: characterSet) { collation = "" }
                }
                GridRow {
                    Text("Collation")
                    Picker("Collation", selection: $collation) {
                        Text(defaultCollationLabel).tag("")
                        if let set = selectedSet {
                            Divider()
                            ForEach(set.collations, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    .labelsHidden()
                    .disabled(selectedSet == nil)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { sets = (try? await model.characterSets()) ?? [] }
    }

    private var selectedSet: CharacterSetInfo? { sets.first { $0.name == characterSet } }

    private var defaultCollationLabel: String {
        selectedSet?.defaultCollation.map { "Default (\($0))" } ?? "Default"
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                try await model.createDatabase(
                    trimmed, characterSet: characterSet.isEmpty ? nil : characterSet,
                    collation: collation.isEmpty ? nil : collation)
                dismiss()
                onCreated(trimmed)
            } catch {
                self.error = (error as? DDLError)?.description ?? error.localizedDescription
            }
        }
    }
}

/// Dropping needs the name typed out: it deletes every table in the database.
struct DropDatabaseSheet: View {
    let model: WorkspaceModel
    let name: String
    var onDropped: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var error: String?
    @State private var isDropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Drop database “\(name)”?", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(
                "This permanently deletes the database and every table, view and routine in it on "
                    + "\(model.profile.host). It can't be undone."
            )
            .fixedSize(horizontal: false, vertical: true)
            if model.profile.tag == .production {
                Label("This connection is tagged Production.", systemImage: "flag.fill").foregroundStyle(.orange)
            }
            Text("Type the database name to confirm:").font(.callout)
            TextField(name, text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            HStack {
                if isDropping { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Drop Database", role: .destructive, action: drop)
                    .disabled(confirmation != name || isDropping)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func drop() {
        isDropping = true
        Task {
            defer { isDropping = false }
            do {
                try await model.dropDatabase(name)
                onDropped()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#if DEBUG
    #Preview("Open database") {
        DatabasePickerSheet(model: .preview())
    }

    #Preview("New database") {
        CreateDatabaseSheet(model: .preview()) { _ in }
    }

    #Preview("Drop database") {
        DropDatabaseSheet(model: .preview(), name: "shop") {}
    }
#endif
