import AppKit
import SwiftUI
import TableRoadCore
import TableRoadStorage

/// Items (tables with their columns), saved Queries, and History, TablePlus-style.
struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @State private var section: Section = .items
    @State private var search = ""

    enum Section: String, CaseIterable, Identifiable {
        case items = "Items"
        case queries = "Queries"
        case history = "History"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Sidebar", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 8)
            TextField(searchPrompt, text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
            switch section {
            case .items: ItemsList(model: model, search: search)
            case .queries: SavedQueriesList(model: model, search: search)
            case .history: HistoryList(model: model, search: search)
            }
        }
        .padding(.top, 8)
        // Denser rows, closer to TablePlus (macOS 26's default sidebar rows are tall).
        .environment(\.sidebarRowSize, .small)
        .environment(\.defaultMinListRowHeight, 20)
        .onChange(of: section) { search = "" }
    }

    private var searchPrompt: String {
        switch section {
        case .items: "Search for item…"
        case .queries: "Search saved queries…"
        case .history: "Search history…"
        }
    }
}

// MARK: - Items

private struct ItemsList: View {
    @Bindable var model: WorkspaceModel
    let search: String

    var body: some View {
        List(selection: $model.sidebarSelection) {
            if let error = model.tablesError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            let tables = filtered.filter { $0.kind == .table }
            let views = filtered.filter { $0.kind != .table }
            if !tables.isEmpty {
                Section("Tables") { ForEach(tables) { TableRow(model: model, table: $0) } }
            }
            if !views.isEmpty {
                Section("Views") { ForEach(views) { TableRow(model: model, table: $0) } }
            }
            if filtered.isEmpty && model.tablesError == nil {
                Text(search.isEmpty ? "No tables" : "No matches").foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        // ⌘-click / ⇧-click select several tables; a single click opens one.
        .onChange(of: model.sidebarSelection) { _, selection in
            if selection.count == 1, let name = selection.first,
                let table = model.tables.first(where: { $0.name == name })
            {
                model.open(table: table)
            }
        }
        .contextMenu(forSelectionType: String.self) { names in
            TablesMenu(model: model, names: names)
        }
    }

    private var filtered: [TableInfo] {
        search.isEmpty ? model.tables : model.tables.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
}

/// A table that expands to show its columns (loaded the first time it's opened).
private struct TableRow: View {
    @Bindable var model: WorkspaceModel
    let table: TableInfo

    var body: some View {
        DisclosureGroup(isExpanded: expanded) {
            if let columns = model.sidebarColumns[table.name] {
                ForEach(columns) { ColumnRow(column: $0) }
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            // No row-count badge: InnoDB's TABLE_ROWS estimate is often wildly stale.
            Label(table.name, systemImage: table.kind == .table ? "tablecells" : "eye")
                .lineLimit(1)
        }
        .tag(table.name)
    }

    private var expanded: Binding<Bool> {
        Binding {
            model.expandedTables.contains(table.name)
        } set: { open in
            if open {
                model.expandedTables.insert(table.name)
                Task { await model.loadSidebarColumns(for: table.name) }
            } else {
                model.expandedTables.remove(table.name)
            }
        }
    }
}

private struct ColumnRow: View {
    let column: ColumnDetail

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .opacity(column.isPrimaryKey ? 1 : 0)
                .help(column.isPrimaryKey ? "Primary key" : "")
            Text(column.name).lineLimit(1)
            Spacer(minLength: 6)
            Text(column.type)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help("\(column.name) \(column.type)\(column.isNullable ? "" : " NOT NULL")")
    }
}

/// Context menu for one or more selected tables (TablePlus-style).
private struct TablesMenu: View {
    let model: WorkspaceModel
    let names: Set<String>

    var body: some View {
        let tables = model.tables.filter { names.contains($0.name) }
        if !tables.isEmpty {
            Button(tables.count == 1 ? "Open in New Tab" : "Open \(tables.count) Tables") {
                tables.forEach { model.open(table: $0) }
            }
            Button("Open Structure") {
                for table in tables {
                    model.open(table: table)
                    if case .table(let browser) = model.selectedTab?.content { browser.show(.structure) }
                }
            }
            Divider()
            Button(tables.count == 1 ? "Copy Name" : "Copy Names") {
                copy(tables.map(\.name).joined(separator: "\n"))
            }
            Divider()
            Menu("Export") {
                Button("Export Tables…") { model.transfer = .export(Set(tables.map(\.name))) }
                Button("Export this Table with Column Selection…") {
                    model.transfer = .exportColumns(tables[0].name)
                }
                .disabled(tables.count != 1)
            }
            Menu("Import") {
                Button("From SQL Dump…") { model.transfer = .importDump }
            }
            Divider()
            if tables.count == 1 {
                Button("New Query: SELECT * FROM \(tables[0].name)") {
                    model.newQueryTab(
                        text: "SELECT * FROM `\(tables[0].name.replacingOccurrences(of: "`", with: "``"))` LIMIT 100;")
                }
            }
        }
    }
}

// MARK: - Saved queries

private struct SavedQueriesList: View {
    let model: WorkspaceModel
    let search: String
    @Environment(SavedQueryStore.self) private var store
    @State private var renaming: SavedQuery?

    var body: some View {
        List {
            ForEach(queries) { query in
                Button {
                    model.newQueryTab(text: query.sql, title: query.name, savedQueryID: query.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(query.name, systemImage: query.connectionID == nil ? "star.circle" : "star")
                            .lineLimit(1)
                        Text(query.sql.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(query.connectionID == nil ? "Saved for all connections" : "Saved for this connection")
                .contextMenu {
                    Button("Open in New Tab") {
                        model.newQueryTab(text: query.sql, title: query.name, savedQueryID: query.id)
                    }
                    Button("Rename…") { renaming = query }
                    Button("Copy SQL") { copy(query.sql) }
                    Divider()
                    Button("Delete", role: .destructive) { try? store.delete(query.id) }
                }
            }
            if queries.isEmpty {
                Text(
                    search.isEmpty
                        ? "No saved queries yet. Use Save Query… in a query tab to keep one here." : "No matches"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $renaming) { query in
            RenameQuerySheet(query: query) { renamed in try? store.save(renamed) }
        }
    }

    private var queries: [SavedQuery] {
        let all = store.queries(for: model.profile.id)
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.sql.localizedCaseInsensitiveContains(search)
        }
    }
}

private struct RenameQuerySheet: View {
    @State var query: SavedQuery
    var onSave: (SavedQuery) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Query").font(.headline)
            TextField("Name", text: $query.name).frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename") {
                    onSave(query)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(query.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

/// Name and scope for saving a query tab's SQL.
struct SaveQuerySheet: View {
    let editor: QueryEditorModel
    let connectionID: UUID
    @Environment(SavedQueryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var allConnections = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Save Query" : "Update Saved Query").font(.headline)
            TextField("Name", text: $name, prompt: Text("e.g. Orders awaiting shipment"))
            Toggle("Show for all connections", isOn: $allConnections)
                .toggleStyle(.checkbox)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if existing != nil {
                    Button("Save as New") { save(asNew: true) }
                }
                Button(existing == nil ? "Save" : "Update") { save(asNew: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            name = existing?.name ?? (editor.title.hasPrefix("Query ") ? "" : editor.title)
            allConnections = existing.map { $0.connectionID == nil } ?? false
        }
    }

    private var existing: SavedQuery? {
        editor.savedQueryID.flatMap { id in store.queries.first { $0.id == id } }
    }

    private func save(asNew: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var query =
            (asNew ? nil : existing)
            ?? SavedQuery(name: trimmed, sql: editor.text, connectionID: connectionID)
        query.name = trimmed
        query.sql = editor.text
        query.connectionID = allConnections ? nil : connectionID
        do {
            try store.save(query)
            editor.savedQueryID = query.id
            editor.title = trimmed
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - History

private struct HistoryList: View {
    let model: WorkspaceModel
    let search: String
    @Environment(QueryHistoryStore.self) private var history
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(days, id: \.day) { group in
                    Section(Self.dayTitle(group.day)) {
                        ForEach(group.entries) { HistoryRow(model: model, entry: $0) }
                    }
                }
                if entries.isEmpty {
                    Text(search.isEmpty ? "Statements you run in query tabs appear here." : "No matches")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Text("\(entries.count) statement(s)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear…") { confirmingClear = true }
                    .disabled(history.entries(for: model.profile.id).isEmpty)
            }
            .controlSize(.small)
            .padding(8)
        }
        .confirmationDialog("Clear this connection's query history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { history.clear(connectionID: model.profile.id) }
        }
    }

    private var entries: [QueryHistoryEntry] {
        let all = history.entries(for: model.profile.id)
        return search.isEmpty ? all : all.filter { $0.sql.localizedCaseInsensitiveContains(search) }
    }

    private var days: [(day: Date, entries: [QueryHistoryEntry])] {
        let calendar = Calendar.current
        var groups: [(day: Date, entries: [QueryHistoryEntry])] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.executedAt)
            if groups.last?.day == day {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((day, [entry]))
            }
        }
        return groups
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct HistoryRow: View {
    let model: WorkspaceModel
    let entry: QueryHistoryEntry
    @Environment(QueryHistoryStore.self) private var history

    var body: some View {
        Button {
            model.newQueryTab(text: entry.sql)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                    Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.sql + "\n\n" + entry.summary)
        .contextMenu {
            Button("Open in New Tab") { model.newQueryTab(text: entry.sql) }
            Button("Copy SQL") { copy(entry.sql) }
            Divider()
            Button("Delete", role: .destructive) { history.delete(entry.id) }
        }
    }

    private var detail: String {
        let time = entry.executedAt.formatted(date: .omitted, time: .shortened)
        let duration =
            entry.durationMilliseconds < 1000
            ? "\(entry.durationMilliseconds) ms"
            : (Double(entry.durationMilliseconds) / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
        return [time, entry.database, duration, entry.summary].compactMap { $0 }.joined(separator: " · ")
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

#if DEBUG
    #Preview("Sidebar – items") {
        SidebarView(model: .preview())
            .environment(PreviewData.savedQueries())
            .environment(PreviewData.history())
            .frame(width: 280, height: 500)
    }
#endif
