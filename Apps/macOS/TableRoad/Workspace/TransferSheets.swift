import AppKit
import SwiftUI
import TableRoadCore
import TableRoadDrivers
import TableRoadSQL
import TableRoadTransfer

// MARK: - Export

/// Export Tables… (TablePlus-style): tables on the left with Structure / Drop / Data (SQL) or Data columns,
/// format and options on the right. In column mode, one table with a field picker instead.
struct ExportSheet: View {
    let model: WorkspaceModel
    let request: TransferRequest
    @Environment(\.dismiss) private var dismiss

    enum Format: String, CaseIterable, Identifiable {
        case csv = "CSV"
        case json = "JSON"
        case sql = "SQL"
        case excel = "EXCEL"
        var id: Self { self }
    }

    struct Flags: Hashable {
        var structure = true
        var drop = true
        var data = true
        var any: Bool { structure || drop || data }
    }

    @AppStorage("export.format") private var format: Format = .sql
    @State private var csv = CSVOptions()
    @AppStorage("export.gzip") private var gzip = false
    @State private var fileName = ""
    // Tables, keyed "database\u{1}table".
    @State private var tablesByDatabase: [String: [TableInfo]] = [:]
    @State private var expanded: Set<String> = []
    @State private var flags: [String: Flags] = [:]
    // Column mode.
    @State private var columns: [ColumnDetail] = []
    @State private var chosenColumns: Set<String> = []
    // Running.
    @State private var progress: ExportProgress?
    @State private var task: Task<Void, Never>?
    @State private var outcome: Outcome?

    enum Outcome {
        case done(ExportResult)
        case failed(String)
    }

    private var columnTable: String? {
        if case .exportColumns(let table) = request { table } else { nil }
    }

    var body: some View {
        Group {
            if let outcome {
                OutcomeView(outcome: outcome) { dismiss() }
            } else if let progress {
                ProgressPanel(
                    title: "Exporting \(progress.item)",
                    detail: progressDetail(progress),
                    fraction: progressFraction(progress)
                ) { task?.cancel() }
            } else if let columnTable {
                columnMode(columnTable)
            } else {
                tablesMode
            }
        }
        .task { await load() }
    }

    // MARK: Layouts

    private var tablesMode: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Items").font(.headline)
                    Spacer()
                    ForEach(flagColumns, id: \.self) { title in
                        Text(title).font(.caption).frame(width: 52)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                List {
                    ForEach(model.databases, id: \.self) { database in
                        databaseRows(database)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 20)
            }
            .frame(width: 400)
            Divider()
            optionsPanel
                .frame(width: 400)
                .padding(16)
        }
        .frame(height: 480)
    }

    private func columnMode(_ table: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export table “\(table)”").font(.headline).frame(maxWidth: .infinity)
            Text("Select fields to export").font(.callout)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(columns) { column in
                        let on = chosenColumns.contains(column.name)
                        Button {
                            if on { chosenColumns.remove(column.name) } else { chosenColumns.insert(column.name) }
                        } label: {
                            Text(column.name)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity)
                                .background(
                                    on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(height: 120)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button("All") { chosenColumns = Set(columns.map(\.name)) }
                Button("None") { chosenColumns = [] }
                Spacer()
                Text("\(chosenColumns.count) of \(columns.count) fields").foregroundStyle(.secondary).font(.caption)
            }
            .controlSize(.small)
            optionsPanel
        }
        .padding(20)
        .frame(width: 520)
    }

    private var optionsPanel: some View {
        VStack(spacing: 12) {
            Picker("Format", selection: $format) {
                ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch format {
                case .csv: csvOptions
                case .json: centred("Export data as JSON: an array of objects, keys in column order.")
                case .sql:
                    VStack(spacing: 10) {
                        Toggle("Compress the file using Gzip", isOn: $gzip).toggleStyle(.checkbox)
                        if columnTable == nil {
                            Text("Choose Structure (CREATE), Drop (DROP … IF EXISTS) and Data (INSERT) per table.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .excel: centred("Export data as Excel (.xlsx), one sheet per table.")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("File name:")
                TextField("File name", text: $fileName).labelsHidden()
                Text(fileExtension).foregroundStyle(.secondary)
            }
            if let reason = disabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…", action: chooseDestination)
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabledReason != nil)
            }
        }
    }

    private var csvOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Convert NULL to EMPTY", isOn: $csv.nullAsEmpty)
            Toggle("Convert line break to space", isOn: $csv.lineBreaksToSpace)
            Toggle("Put field names in the first row", isOn: $csv.header)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Delimiter").gridColumnAlignment(.trailing)
                    Picker("Delimiter", selection: $csv.delimiter) {
                        Text(",").tag(",")
                        Text(";").tag(";")
                        Text("Tab").tag("\t")
                        Text("|").tag("|")
                    }
                }
                GridRow {
                    Text("Quoting")
                    Picker("Quoting", selection: $csv.quoting) {
                        ForEach(CSVOptions.Quoting.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                GridRow {
                    Text("Line break")
                    Picker("Line break", selection: $csv.lineBreak) {
                        Text("\\n").tag("\n")
                        Text("\\r\\n").tag("\r\n")
                    }
                }
                GridRow {
                    Text("Decimal")
                    Picker("Decimal", selection: $csv.decimalSeparator) {
                        Text(".").tag(".")
                        Text(",").tag(",")
                    }
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity)
    }

    private func centred(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Table tree

    private var flagColumns: [String] { format == .sql ? ["Structure", "Drop", "Data"] : ["Data"] }

    @ViewBuilder
    private func databaseRows(_ database: String) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expanded.contains(database) },
                set: { open in
                    if open {
                        expanded.insert(database)
                        Task { await loadTables(database) }
                    } else {
                        expanded.remove(database)
                    }
                })
        ) {
            ForEach(tablesByDatabase[database] ?? []) { table in
                HStack(spacing: 6) {
                    Image(systemName: table.kind == .table ? "tablecells" : "eye").foregroundStyle(.secondary)
                    Text(table.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    checkboxes(database: database, table: table)
                }
            }
        } label: {
            HStack {
                Image(systemName: "cylinder").foregroundStyle(.secondary)
                Text(database).lineLimit(1)
                Spacer()
                databaseCheckboxes(database)
            }
        }
    }

    private func key(_ database: String, _ table: String) -> String { database + "\u{1}" + table }

    @ViewBuilder
    private func checkboxes(database: String, table: TableInfo) -> some View {
        let id = key(database, table.name)
        let current = flags[id] ?? Flags(structure: false, drop: false, data: false)
        if format == .sql {
            CheckBox(state: current.structure ? .on : .off) { flags[id, default: off].structure.toggle() }
            CheckBox(state: current.drop ? .on : .off) { flags[id, default: off].drop.toggle() }
            // A view's rows can't be inserted back into it.
            CheckBox(state: current.data && table.kind == .table ? .on : .off) {
                flags[id, default: off].data.toggle()
            }
            .disabled(table.kind != .table)
        } else {
            CheckBox(state: current.data ? .on : .off) { flags[id, default: off].data.toggle() }
        }
    }

    private var off: Flags { Flags(structure: false, drop: false, data: false) }

    @ViewBuilder
    private func databaseCheckboxes(_ database: String) -> some View {
        if format == .sql {
            databaseCheckbox(database, \.structure)
            databaseCheckbox(database, \.drop)
            databaseCheckbox(database, \.data)
        } else {
            databaseCheckbox(database, \.data)
        }
    }

    private func databaseCheckbox(_ database: String, _ flag: WritableKeyPath<Flags, Bool>) -> some View {
        let tables = tablesByDatabase[database] ?? []
        let on = tables.filter { flags[key(database, $0.name)]?[keyPath: flag] == true }.count
        let state: CheckBox.State = on == 0 ? .off : on == tables.count ? .on : .mixed
        return CheckBox(state: state) {
            Task {
                await loadTables(database)
                let all = tablesByDatabase[database] ?? []
                let turnOn = state != .on
                for table in all {
                    flags[key(database, table.name), default: off][keyPath: flag] = turnOn
                }
            }
        }
    }

    // MARK: Data

    private func load() async {
        guard let database = model.selectedDatabase else { return }
        if let columnTable {
            fileName = columnTable
            columns = (try? await model.session?.columns(of: columnTable, in: database)) ?? []
            chosenColumns = Set(columns.map(\.name))
            if format == .sql { format = .csv }
            return
        }
        expanded = [database]
        await loadTables(database)
        if case .export(let names) = request {
            for name in names { flags[key(database, name)] = Flags() }
            fileName = names.count == 1 ? names.first! : database
        }
    }

    private func loadTables(_ database: String) async {
        guard tablesByDatabase[database] == nil else { return }
        tablesByDatabase[database] = await model.tables(in: database)
    }

    private var items: [ExportItem] {
        if let columnTable, let database = model.selectedDatabase {
            let ordered = columns.map(\.name).filter { chosenColumns.contains($0) }
            return [ExportItem(database: database, table: columnTable, columns: ordered)]
        }
        return flags.compactMap { id, flags in
            let parts = id.split(separator: "\u{1}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let isView = tablesByDatabase[parts[0]]?.first { $0.name == parts[1] }?.kind != .table
            let item = ExportItem(
                database: parts[0], table: parts[1], isView: isView, structure: flags.structure, drop: flags.drop,
                data: flags.data && !isView)
            return format == .sql ? (flags.any ? item : nil) : (flags.data ? item : nil)
        }
        .sorted { $0.id < $1.id }
    }

    private var kind: ExportKind {
        switch format {
        case .csv: .csv(csv)
        case .json: .json
        case .sql: .sql(gzip: gzip)
        case .excel: .excel
        }
    }

    /// Shown after the file name: ".sql", or "(folder)" when CSV/JSON write one file per table.
    private var fileExtension: String {
        kind.writesFolder(itemCount: items.count) ? "(folder)" : "." + kind.fileExtension
    }

    private var disabledReason: String? {
        if columnTable != nil && chosenColumns.isEmpty { return "Choose at least one field." }
        if items.isEmpty { return "Tick at least one table." }
        if fileName.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a file name." }
        return nil
    }

    // MARK: Running

    private func chooseDestination() {
        let items = items
        let kind = kind
        let name = fileName.trimmingCharacters(in: .whitespaces)
        let destination: URL
        if kind.writesFolder(itemCount: items.count) {
            let panel = NSOpenPanel()
            panel.title = "Choose where to create the “\(name)” folder"
            panel.prompt = "Export"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            destination = folder.appending(path: name)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name + "." + kind.fileExtension
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        let connect = model.connector()
        progress = ExportProgress(item: items.first?.table ?? "", itemIndex: 0, itemCount: items.count, rows: 0)
        task = Task {
            do {
                let result = try await TableExport.run(
                    items: items, kind: kind, destination: destination,
                    connect: connect,
                    progress: { update in Task { @MainActor in progress = update } })
                outcome = .done(result)
            } catch {
                // Don't leave a half-written file (or folder) behind.
                try? FileManager.default.removeItem(at: destination)
                outcome = .failed(
                    error is CancellationError
                        ? "Export cancelled."
                        : (error as? TransferError)?.description
                            ?? error.localizedDescription)
            }
        }
    }

    private func progressDetail(_ progress: ExportProgress) -> String {
        let rows = progress.estimatedRows.map { " of ~\($0.formatted())" } ?? ""
        return "Table \(progress.itemIndex + 1) of \(progress.itemCount) · \(progress.rows.formatted())\(rows) rows"
    }

    private func progressFraction(_ progress: ExportProgress) -> Double? {
        guard progress.itemCount > 0 else { return nil }
        let within = progress.estimatedRows.map { $0 > 0 ? min(1, Double(progress.rows) / Double($0)) : 0 } ?? 0
        return (Double(progress.itemIndex) + within) / Double(progress.itemCount)
    }

    private struct OutcomeView: View {
        let outcome: Outcome
        var onDone: () -> Void

        var body: some View {
            VStack(spacing: 14) {
                switch outcome {
                case .done(let result):
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                    Text("Exported \(result.rows.formatted()) rows").font(.headline)
                    if let first = result.files.first {
                        Text(result.files.count > 1 ? first.deletingLastPathComponent().path : first.path)
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .multilineTextAlignment(.center)
                    }
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(result.files) }
                        Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                    }
                case .failed(let message):
                    Image(systemName: "xmark.octagon.fill").font(.largeTitle).foregroundStyle(.red)
                    Text("Export didn't finish").font(.headline)
                    Text(message).font(.callout).textSelection(.enabled).multilineTextAlignment(.center)
                    Button("Close", action: onDone).keyboardShortcut(.defaultAction)
                }
            }
            .padding(30)
            .frame(width: 460)
        }
    }
}

// MARK: - Import

/// Import ▸ From SQL Dump…: runs a .sql / .sql.gz file statement by statement on its own connection.
struct ImportDumpSheet: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var database = ""
    @State private var stopOnError = true
    @State private var confirming = false
    @State private var progress: ImportProgress?
    @State private var task: Task<Void, Never>?
    @State private var result: ImportResult?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import SQL Dump").font(.headline)
            if let result {
                summary(result)
            } else if let progress {
                ProgressPanel(
                    title: "Importing \(file?.lastPathComponent ?? "")",
                    detail:
                        "\(progress.statements.formatted()) statements · \(progress.failures) error(s) · "
                        + ByteCountFormatter.string(fromByteCount: progress.bytesRead, countStyle: .file) + " of "
                        + ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file),
                    fraction: progress.totalBytes > 0 ? Double(progress.bytesRead) / Double(progress.totalBytes) : nil
                ) { task?.cancel() }
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { database = model.selectedDatabase ?? "" }
        .confirmationDialog(
            "Import into \(database) on \(model.profile.name)?", isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Import") { start() }
        } message: {
            Text(
                "This connection is marked as production or uses safe mode. The dump can create, drop and change tables."
            )
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.profile.safeMode == .readOnly {
                Label("This connection is read-only, so nothing can be imported.", systemImage: "lock")
                    .foregroundStyle(.orange)
            }
            HStack {
                Text(file?.path ?? "No file chosen").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(file == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: chooseFile)
            }
            Picker("Into database", selection: $database) {
                ForEach(model.databases, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Stop at the first error", isOn: $stopOnError).toggleStyle(.checkbox)
            Text("Statements run one at a time, outside a transaction (dumps contain CREATE/DROP, which commit).")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    if model.profile.tag == .production || model.profile.safeMode == .confirmWrites {
                        confirming = true
                    } else {
                        start()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(file == nil || database.isEmpty || model.profile.safeMode == .readOnly)
            }
        }
    }

    private func summary(_ result: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                result.failures.isEmpty
                    ? "Imported \(result.statements.formatted()) statements."
                    : result.stoppedOnError
                        ? "Stopped at statement \(result.failures.last?.statement ?? 0) after an error."
                        : "Ran \(result.statements.formatted()) statements; \(result.failures.count) failed.",
                systemImage: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(result.failures.isEmpty ? Color.green : Color.orange)
            if !result.failures.isEmpty {
                List(result.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(failure.statement): \(failure.message)").foregroundStyle(.red)
                        Text(failure.sql.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .textSelection(.enabled)
                }
                .frame(height: 180)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a SQL dump (.sql or .sql.gz)"
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { file = panel.url }
    }

    private func start() {
        guard let file else { return }
        let connect = model.connector()
        let database = database
        let stopOnError = stopOnError
        progress = ImportProgress(bytesRead: 0, totalBytes: 0, statements: 0, failures: 0)
        task = Task {
            do {
                result = try await SQLDumpImport.run(
                    file: file, database: database, stopOnError: stopOnError,
                    connect: connect,
                    progress: { update in Task { @MainActor in progress = update } })
            } catch {
                progress = nil
                self.error =
                    error is CancellationError
                    ? "Import cancelled. Statements already run stay applied."
                    : (error as? TransferError)?.description ?? error.localizedDescription
            }
            await model.loadTables()
        }
    }
}

// MARK: - Shared

/// Determinate (or spinning) progress with Cancel.
private struct ProgressPanel: View {
    let title: String
    let detail: String
    let fraction: Double?
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).lineLimit(1)
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Square checkbox with a mixed state (database rows).
struct CheckBox: View {
    enum State { case on, off, mixed }
    let state: State
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(
                systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square"
            )
            .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
            .font(.body)
        }
        .buttonStyle(.plain)
        .frame(width: 52)
    }
}

#if DEBUG
    #Preview("Export tables") {
        ExportSheet(model: .preview(), request: .export(["orders"]))
    }

    #Preview("Export columns") {
        ExportSheet(model: .preview(), request: .exportColumns("orders"))
    }

    #Preview("Import dump") {
        ImportDumpSheet(model: .preview())
    }
#endif
