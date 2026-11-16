import Foundation
import Observation
import TableRoadCore
import TableRoadMySQL
import TableRoadSQL

/// Paged, sortable, filterable view of one table.
@MainActor @Observable
final class TableBrowserModel {
    let session: MySQLSession
    let database: String
    let table: String
    let pageSize = 300

    private(set) var result: ResultSet = .empty
    /// Schema columns (names, types, primary key), loaded once.
    private(set) var schemaColumns: [ColumnDetail] = []
    var totalRows: Int?
    private(set) var isLoading = false
    private(set) var error: String?
    var page = 0
    var sort: ColumnSort?

    /// The filter bar as being edited.
    var filters = FilterSet()
    /// The filters the current results were loaded with (edits apply on Return / Apply).
    private(set) var appliedFilters = FilterSet()
    var isFilterBarVisible = false

    /// Staged edits (see the Editing extension).
    var pending = PendingEdits()
    var commitError: String?
    var isCommitting = false
    /// Asks the grid to scroll to a cell and start editing it (e.g. after adding a row).
    var editRequest: GridEditRequest?
    /// Display rows selected in the grid (the inspector shows the first).
    var selectedRows = IndexSet()
    let safeMode: SafeMode
    /// Ask before committing (safe mode, or production-tagged connections).
    let confirmBeforeCommit: Bool

    init(session: MySQLSession, database: String, table: String, safeMode: SafeMode = .off, tag: ConnectionTag = .none)
    {
        self.session = session
        self.database = database
        self.table = table
        self.safeMode = safeMode
        self.confirmBeforeCommit = safeMode == .confirmWrites || tag == .production
    }

    var pageCount: Int {
        guard let totalRows else { return 1 }
        return max(1, Int((Double(totalRows) / Double(pageSize)).rounded(.up)))
    }

    var columnNames: [String] {
        schemaColumns.isEmpty ? result.columns.map(\.name) : schemaColumns.map(\.name)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if schemaColumns.isEmpty {
                schemaColumns = try await session.columns(of: table, in: database)
            }
            let query = PageQuery(
                database: database, table: table, sort: sort.map { [$0] } ?? [], filters: appliedFilters,
                limit: pageSize, offset: page * pageSize)
            if case .rows(let rows) = try await session.execute(query.selectSQL(session.dialect)) {
                // Empty page: mysql-nio drops headers, so take them from the schema.
                result =
                    rows.columns.isEmpty
                    ? ResultSet(
                        columns: schemaColumns.map { ResultColumn(name: $0.name, table: table, typeName: $0.type) },
                        rows: [])
                    : rows
            }
            if totalRows == nil, case .rows(let count) = try await session.execute(query.countSQL(session.dialect)),
                case .int(let value) = count.rows.first?.first
            {
                totalRows = Int(value)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setSort(_ sort: ColumnSort?) {
        guard guardNoPendingChanges() else { return }
        self.sort = sort
        page = 0
        Task { await load() }
    }

    func go(toPage newPage: Int) {
        guard guardNoPendingChanges() else { return }
        page = min(max(newPage, 0), pageCount - 1)
        Task { await load() }
    }

    func refresh() {
        guard guardNoPendingChanges() else { return }
        totalRows = nil
        Task { await load() }
    }

    // MARK: - Filters

    func toggleFilterBar() {
        isFilterBarVisible.toggle()
        if isFilterBarVisible && filters.filters.isEmpty { addFilter() }
    }

    func addFilter(after id: ColumnFilter.ID? = nil) {
        let filter = ColumnFilter(column: columnNames.first ?? "")
        if let id, let index = filters.filters.firstIndex(where: { $0.id == id }) {
            filters.filters.insert(filter, at: index + 1)
        } else {
            filters.filters.append(filter)
        }
    }

    func removeFilter(_ id: ColumnFilter.ID) {
        filters.filters.removeAll { $0.id == id }
        if filters.filters.isEmpty {
            isFilterBarVisible = false
            applyFilters()
        }
    }

    /// Re-queries with the filter bar's current contents, from page 1, with a fresh row count.
    func applyFilters() {
        guard guardNoPendingChanges() else { return }
        appliedFilters = filters
        page = 0
        totalRows = nil
        Task { await load() }
    }

    /// The WHERE clause currently applied, for display.
    var appliedWhereSQL: String {
        appliedFilters.whereClause(session.dialect).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Editing

extension TableBrowserModel {
    var primaryKey: [String] { schemaColumns.filter(\.isPrimaryKey).map(\.name) }

    /// Why rows can't be edited, or nil if they can.
    var readOnlyReason: String? {
        if safeMode == .readOnly { return "Read-only connection" }
        if schemaColumns.isEmpty { return nil }  // still loading
        if primaryKey.isEmpty { return "No primary key: rows can't be identified safely" }
        if primaryKey.contains(where: { columnIndex(of: $0) == nil }) { return "Primary key not in results" }
        return nil
    }

    var isEditable: Bool { readOnlyReason == nil && !schemaColumns.isEmpty }
    var hasChanges: Bool { !pending.isEmpty }
    var pageRowCount: Int { result.rows.count }

    func columnIndex(of name: String) -> Int? {
        result.columns.firstIndex { $0.name == name }
    }

    /// Page rows with staged updates applied, followed by staged inserts.
    var displayResult: ResultSet {
        guard hasChanges else { return result }
        var rows = result.rows
        for (row, edits) in pending.updates where row < rows.count {
            for (column, edit) in edits { rows[row][column] = edit.displayValue }
        }
        for insert in pending.inserts {
            rows.append(result.columns.indices.map { insert[$0]?.displayValue ?? CellEdit.defaultValue.displayValue })
        }
        return ResultSet(columns: result.columns, rows: rows)
    }

    func cellState(row: Int, column: Int) -> GridCellState {
        if row >= pageRowCount {
            return pending.inserts[row - pageRowCount][column] == nil ? .insertedDefault : .inserted
        }
        if pending.deletes.contains(row) { return .deleted }
        return pending.updates[row]?[column] != nil ? .edited : .normal
    }

    /// Full text for the inline editor, or nil if the cell can't be edited inline.
    func editableText(row: Int, column: Int) -> String? {
        guard isEditable, row < displayResult.rows.count, !pending.deletes.contains(row) else { return nil }
        let value = displayResult.rows[row][column]
        switch value {
        case .bytes: return nil  // binary needs the inspector
        case .unsupported(let type, _) where type == "DEFAULT": return ""
        default:
            let text = value.displayText ?? ""
            return text.contains("\n") ? nil : text  // multi-line values need the inspector
        }
    }

    func setCell(row: Int, column: Int, to edit: CellEdit) {
        guard isEditable else { return }
        if row >= pageRowCount {
            pending.inserts[row - pageRowCount][column] = edit
            return
        }
        guard !pending.deletes.contains(row) else { return }
        let original = result.rows[row][column]
        let unchanged =
            switch edit {
            case .null: original == .null
            case .text(let text): original != .null && original.displayText == text
            case .defaultValue: false
            }
        if unchanged {
            pending.updates[row]?[column] = nil
            if pending.updates[row]?.isEmpty == true { pending.updates[row] = nil }
        } else {
            pending.updates[row, default: [:]][column] = edit
        }
    }

    func addRow() {
        guard isEditable else { return }
        pending.inserts.append([:])
        requestEditOfLastRow()
    }

    /// Scroll to the newest row and edit its first column that isn't an auto-generated key.
    private func requestEditOfLastRow() {
        let firstColumn =
            result.columns.indices.first { index in
                let detail = schemaColumns.first { $0.name == result.columns[index].name }
                return !(detail?.isPrimaryKey == true && detail?.extra?.contains("auto_increment") == true)
            } ?? 0
        editRequest = GridEditRequest(row: pageRowCount + pending.inserts.count - 1, column: firstColumn)
    }

    /// Allowed values for ENUM/SET columns.
    func choices(column: Int) -> [String]? {
        guard column < result.columns.count else { return nil }
        return schemaColumns.first { $0.name == result.columns[column].name }?.choices
    }

    func duplicateRow(_ row: Int) {
        guard isEditable, row < displayResult.rows.count else { return }
        let source = displayResult.rows[row]
        var insert: [Int: CellEdit] = [:]
        for (index, value) in source.enumerated() where !primaryKey.contains(result.columns[index].name) {
            switch value {
            case .null: insert[index] = .null
            case .unsupported(let type, _) where type == "DEFAULT": break
            case .bytes: break
            default: insert[index] = value.displayText.map(CellEdit.text)
            }
        }
        pending.inserts.append(insert)
        requestEditOfLastRow()
    }

    /// Marks page rows for deletion (toggles if all are already marked); removes staged inserts outright.
    func deleteRows(_ rows: IndexSet) {
        guard isEditable else { return }
        let pageRows = Set(rows.filter { $0 < pageRowCount })
        if !pageRows.isEmpty && pageRows.isSubset(of: pending.deletes) {
            pending.deletes.subtract(pageRows)
        } else {
            pending.deletes.formUnion(pageRows)
        }
        let insertIndexes = rows.filter { $0 >= pageRowCount }.map { $0 - pageRowCount }
        for index in insertIndexes.sorted(by: >) where index < pending.inserts.count {
            pending.inserts.remove(at: index)
        }
    }

    func discardChanges() {
        pending = PendingEdits()
        commitError = nil
    }

    /// Staged edits as row changes, in a stable order: updates, inserts, deletes.
    func changes() -> [RowChange] {
        let columns = result.columns.map(\.name)
        func key(for row: Int) -> RowKey? {
            var values: [(String, String)] = []
            for column in primaryKey {
                guard let index = columnIndex(of: column), let text = result.rows[row][index].displayText else {
                    return nil
                }
                values.append((column, text))
            }
            return RowKey(values)
        }
        var changes: [RowChange] = []
        for row in pending.updates.keys.sorted() where !pending.deletes.contains(row) {
            guard let key = key(for: row), let edits = pending.updates[row] else { continue }
            let set = edits.keys.sorted().map { ColumnEdit(column: columns[$0], edit: edits[$0]!) }
            changes.append(.update(key: key, set: set))
        }
        for insert in pending.inserts {
            changes.append(.insert(insert.keys.sorted().map { ColumnEdit(column: columns[$0], edit: insert[$0]!) }))
        }
        for row in pending.deletes.sorted() {
            if let key = key(for: row) { changes.append(.delete(key: key)) }
        }
        return changes
    }

    private var builder: TableChangeBuilder {
        TableChangeBuilder(database: database, table: table, dialect: session.dialect)
    }

    var previewSQL: String {
        changes().map(builder.previewSQL).joined(separator: "\n")
    }

    /// Applies all staged edits in one transaction, then reloads the page.
    func commit() async {
        let changes = changes()
        guard !changes.isEmpty else {
            discardChanges()
            return
        }
        isCommitting = true
        defer { isCommitting = false }
        do {
            _ = try await session.executeTransaction(changes.map(builder.statement))
            pending = PendingEdits()
            commitError = nil
            totalRows = nil
            await load()
        } catch {
            commitError = error.localizedDescription
        }
    }

    /// Sorting, paging, filtering and reloading would lose staged edits, so they're blocked until commit/discard.
    func guardNoPendingChanges() -> Bool {
        if hasChanges {
            commitError = "Commit (⌘S) or discard your changes first."
            return false
        }
        return true
    }
}

// MARK: - Inspector

extension TableBrowserModel {
    var inspectorRow: InspectorRow? {
        let display = displayResult
        guard let row = selectedRows.first, row < display.rows.count else { return nil }
        let isInsert = row >= pageRowCount
        let rowNumber = isInsert ? "New row \(row - pageRowCount + 1)" : "Row \(page * pageSize + row + 1)"
        return InspectorRow(
            title: selectedRows.count > 1 ? "\(rowNumber) (+\(selectedRows.count - 1) more selected)" : rowNumber,
            columns: display.columns,
            values: display.rows[row],
            details: display.columns.map { column in schemaColumns.first { $0.name == column.name } },
            states: display.columns.indices.map { cellState(row: row, column: $0) })
    }

    var inspectorEditing: InspectorEditing? {
        guard isEditable, let row = selectedRows.first, row < displayResult.rows.count,
            !pending.deletes.contains(row)
        else { return nil }
        return InspectorEditing(
            canEdit: { [weak self] column in
                guard let self, row < self.displayResult.rows.count else { return false }
                if case .bytes = self.displayResult.rows[row][column] { return false }  // binary editing: later
                return true
            },
            set: { [weak self] column, edit in self?.setCell(row: row, column: column, to: edit) },
            choices: { [weak self] column in self?.choices(column: column) })
    }
}
