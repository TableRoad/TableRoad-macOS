import Foundation
import Observation
import TableRoadCore
import TableRoadDrivers
import TableRoadSQL

/// Paged, sortable, filterable view of one table.
@MainActor @Observable
final class TableBrowserModel {
    /// Replaced by the workspace when the main connection is re-established. `nil` only in previews.
    var session: (any SQLClient)?
    /// Tells the workspace the main connection dropped.
    var onConnectionLost: (any Error) -> Void = { _ in }
    let database: String
    let table: String
    let pageSize = 300

    private(set) var result: ResultSet = .empty {
        didSet { dataVersion &+= 1 }
    }
    /// Bumped whenever `result` changes (cheap identity for the grid, instead of hashing every cell).
    private(set) var dataVersion = 0
    /// When the current load started (drives the loading overlay's timer).
    private(set) var loadStartedAt: Date?
    /// Schema columns (names, types, primary key), loaded once.
    private(set) var schemaColumns: [ColumnDetail] = []
    /// This table's foreign keys, loaded with the schema (drives the grid's → links to referenced rows).
    private(set) var foreignKeys: [ForeignKeyDetail] = []
    /// Rows in the table (with the applied filters). Exact unless `totalIsEstimate`; nil when not counted.
    var totalRows: Int?
    /// `totalRows` is the storage engine's estimate (large tables aren't counted automatically).
    private(set) var totalIsEstimate = false
    /// An explicit COUNT(*) is running (see `count(includeFilters:)`).
    private(set) var isCounting = false
    private(set) var countStartedAt: Date?
    private(set) var countError: String?
    /// Result of counting the whole table while filters were applied (shown in the count popover only).
    private(set) var unfilteredCount: Int?
    private var countTask: Task<Void, Never>?
    /// Bumped when the filters change, so a count that finishes afterwards is ignored.
    private var countGeneration = 0
    /// Sizes, row estimate and comment (cheap; never scans the table). Shown in the inspector.
    private(set) var status: TableStatus?
    /// Tables at least this big (by estimate) show the estimate instead of running COUNT(*) on every open.
    static let estimateThreshold = 100_000
    /// Estimates can be badly stale (MariaDB reports 0 for freshly loaded tables), so data size counts too.
    static let largeTableBytes = 64 << 20

    /// Data grid, or a read-only view of the table's definition.
    enum Pane: String, CaseIterable, Identifiable {
        case data = "Data"
        case structure = "Structure"
        case indexes = "Indexes"
        case ddl = "DDL"
        var id: Self { self }
    }

    var pane: Pane = .data
    /// Loaded the first time a definition pane is shown (and again on refresh).
    private(set) var structure: TableStructure?
    private(set) var structureError: String?
    private(set) var isLoadingStructure = false
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

    init(
        session: (any SQLClient)?, database: String, table: String, safeMode: SafeMode = .off,
        tag: ConnectionTag = .none
    ) {
        self.session = session
        self.database = database
        self.table = table
        self.safeMode = safeMode
        self.confirmBeforeCommit = safeMode == .confirmWrites || tag == .production
    }

    var pageCount: Int {
        let known = totalRows.map { max(1, Int((Double($0) / Double(pageSize)).rounded(.up))) } ?? page + 1
        // With no exact total, a full page means there may be more: always allow the next one.
        if result.rows.count == pageSize && (totalRows == nil || totalIsEstimate) { return max(known, page + 2) }
        return known
    }

    /// Big enough that counting every time it's opened would be slow (or hurt the server).
    var isLargeTable: Bool {
        (status?.estimatedRows ?? 0) >= Self.estimateThreshold || (status?.dataBytes ?? 0) >= Self.largeTableBytes
    }

    var columnNames: [String] {
        schemaColumns.isEmpty ? result.columns.map(\.name) : schemaColumns.map(\.name)
    }

    /// SQL spelling for this table's server (MySQL defaults when there's no session, i.e. previews).
    var dialect: any SQLDialect { session?.sqlDialect ?? MySQLDialect(flavor: .mysql) }

    func load() async {
        guard let session else { return }
        await stopCounting()
        isLoading = true
        loadStartedAt = .now
        var shouldCount = false
        defer {
            isLoading = false
            loadStartedAt = nil
            if shouldCount { count(includeFilters: true) }
        }
        do {
            if schemaColumns.isEmpty {
                schemaColumns = try await session.columns(of: table, in: database)
                // Optional extra: without them the grid just has no → links.
                foreignKeys = (try? await session.foreignKeys(of: table, in: database)) ?? []
            }
            if status == nil {
                // Optional extra: if information_schema can't be read, the table still loads (and gets counted).
                status = try? await session.tableStatus(of: table, in: database)
            }
            let query = PageQuery(
                database: database, table: table, sort: sort.map { [$0] } ?? [], filters: appliedFilters,
                limit: pageSize, offset: page * pageSize)
            let fetched = try await session.execute(query.selectSQL(session.sqlDialect))
            if case .rows(let rows) = fetched {
                // Empty page: mysql-nio drops headers, so take them from the schema.
                result =
                    rows.columns.isEmpty
                    ? ResultSet(
                        columns: schemaColumns.map { ResultColumn(name: $0.name, table: table, typeName: $0.type) },
                        rows: [])
                    : rows
            }
            shouldCount = updateTotal()
            error = nil
        } catch {
            if (error as? DatabaseError)?.category == .connection {
                self.error = "Connection lost. Reconnecting…"
                onConnectionLost(error)
            } else if (error as? DatabaseError)?.category == .cancelled {
                self.error =
                    result.rows.isEmpty
                    ? "Loading was cancelled." : "Loading was cancelled; showing the previous results."
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    /// Works out the total from what's known after loading a page. Returns true if it should be counted exactly.
    private func updateTotal() -> Bool {
        let offset = page * pageSize
        let fetched = result.rows.count
        // A short page is the last one, so the total is exact (and corrects any estimate).
        if fetched < pageSize && (fetched > 0 || page == 0) {
            totalRows = offset + fetched
            totalIsEstimate = false
            return false
        }
        if let total = totalRows {
            if total < offset + fetched { totalRows = offset + fetched }
            return false
        }
        guard isLargeTable else { return true }  // small: an exact COUNT(*) is cheap
        if appliedFilters.activeCount == 0, let estimate = status?.estimatedRows {
            totalRows = max(estimate, offset + fetched)
            totalIsEstimate = true
        }
        return false  // large: only counted when asked (the count popover)
    }

    /// Runs COUNT(*) in the background (after the page is shown). Cancelled by any new page load.
    func count(includeFilters: Bool) {
        guard let session, !isCounting else { return }
        let filtered = includeFilters && appliedFilters.activeCount > 0
        let query = PageQuery(
            database: database, table: table, filters: filtered ? appliedFilters : FilterSet(), limit: 0, offset: 0)
        let generation = countGeneration
        isCounting = true
        countStartedAt = .now
        countError = nil
        countTask = Task { [weak self] in
            let outcome: Result<Int, any Error>
            do {
                guard case .rows(let rows) = try await session.execute(query.countSQL(session.sqlDialect)) else {
                    throw DatabaseError(.query, "COUNT(*) returned no rows.")
                }
                switch rows.rows.first?.first {
                case .int(let value): outcome = .success(Int(value))
                case .uint(let value): outcome = .success(Int(value))
                default: throw DatabaseError(.query, "COUNT(*) returned an unexpected value.")
                }
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.isCounting = false
            self.countStartedAt = nil
            self.countTask = nil
            guard generation == self.countGeneration else { return }
            switch outcome {
            case .success(let total):
                if filtered || self.appliedFilters.activeCount == 0 {
                    self.totalRows = total
                    self.totalIsEstimate = false
                } else {
                    self.unfilteredCount = total
                }
            case .failure(let error):
                if (error as? DatabaseError)?.category != .cancelled {
                    self.countError = error.localizedDescription
                }
            }
        }
    }

    /// Stops a running count on the server.
    func cancelCount() {
        guard isCounting, let session else { return }
        Task { try? await session.cancelCurrentQuery() }
    }

    /// Cancels a running count and waits for it, so it doesn't hold the connection while a page loads.
    private func stopCounting() async {
        guard isCounting, let task = countTask else { return }
        cancelCount()
        await task.value
    }

    /// Discards the total so the next load works it out again (filters changed, rows added or removed).
    private func resetTotal() {
        totalRows = nil
        totalIsEstimate = false
        unfilteredCount = nil
        countError = nil
        countGeneration &+= 1
    }

    // MARK: - Structure

    func show(_ pane: Pane) {
        self.pane = pane
        if pane != .data { Task { await loadStructure() } }
    }

    func loadStructure() async {
        guard let session, structure == nil, !isLoadingStructure else { return }
        isLoadingStructure = true
        defer { isLoadingStructure = false }
        do {
            let columns = try await session.columns(of: table, in: database)
            let indexes = try await session.indexes(of: table, in: database)
            let foreignKeys = try await session.foreignKeys(of: table, in: database)
            let ddl = try await session.createStatement(of: table, in: database)
            structure = TableStructure(columns: columns, indexes: indexes, foreignKeys: foreignKeys, ddl: ddl)
            structureError = nil
        } catch {
            structureError = error.localizedDescription
        }
    }

    /// What the grid should reload on: new rows or different staged edits.
    var gridRevision: AnyHashable { AnyHashable([dataVersion, pending.hashValue]) }

    /// Kills the running page/count query on the server (the load then reports "cancelled").
    func cancelLoad() {
        guard isLoading, let session else { return }
        Task { try? await session.cancelCurrentQuery() }
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
        resetTotal()
        status = nil
        structure = nil
        Task {
            await load()
            if pane != .data { await loadStructure() }
        }
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

    /// Starts with these filters applied (opening a referenced row). Call before the first load.
    func preset(filters: FilterSet) {
        self.filters = filters
        appliedFilters = filters
        isFilterBarVisible = !filters.filters.isEmpty
    }

    /// Re-queries with the filter bar's current contents, from page 1, with a fresh row count.
    func applyFilters() {
        guard guardNoPendingChanges() else { return }
        appliedFilters = filters
        page = 0
        resetTotal()
        Task { await load() }
    }

    /// Replaces the filters with one condition (from the grid's Quick Filter menu) and applies it.
    func quickFilter(_ filter: ColumnFilter) {
        filters = FilterSet(filters: [filter])
        isFilterBarVisible = true
        applyFilters()
    }

    /// The WHERE clause currently applied, for display.
    var appliedWhereSQL: String {
        appliedFilters.whereClause(dialect).trimmingCharacters(in: .whitespaces)
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

    /// The Quick Look editor can change any non-binary value of an editable, non-deleted row (multi-line too).
    func canEditInEditor(row: Int, column: Int) -> Bool {
        guard isEditable, row < displayResult.rows.count, !pending.deletes.contains(row) else { return false }
        if case .bytes = displayResult.rows[row][column] { return false }
        return true
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
        TableChangeBuilder(database: database, table: table, dialect: dialect)
    }

    var previewSQL: String {
        changes().map(builder.previewSQL).joined(separator: "\n")
    }

    /// Applies all staged edits in one transaction, then reloads the page.
    func commit() async {
        let changes = changes()
        guard let session else { return }
        guard !changes.isEmpty else {
            discardChanges()
            return
        }
        isCommitting = true
        defer { isCommitting = false }
        do {
            _ = try await session.executeTransaction(changes.map(builder.statement))
            let delta = pending.inserts.count - pending.deletes.count
            pending = PendingEdits()
            commitError = nil
            if let total = totalRows, !totalIsEstimate {
                totalRows = max(0, total + delta)  // exact stays exact, without re-counting
            } else {
                resetTotal()
            }
            await load()
        } catch {
            commitError = error.localizedDescription
            if let failure = error as? TransactionError, failure.isConnectionLoss {
                onConnectionLost(error)
            }
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

// MARK: - Foreign keys

/// Where a foreign key value points: the referenced table, filtered to the matching row(s).
struct ForeignKeyTarget: Equatable {
    var database: String
    var table: String
    var filters: FilterSet
}

extension TableBrowserModel {
    /// Result columns (display indexes) that are part of a foreign key.
    var foreignKeyColumns: Set<Int> {
        guard !foreignKeys.isEmpty else { return [] }
        let names = Set(foreignKeys.flatMap(\.columns))
        return Set(result.columns.indices.filter { names.contains(result.columns[$0].name) })
    }

    /// The row a foreign key cell refers to, or nil if the value can't be followed (NULL, binary, or another
    /// column of a composite key is NULL or not in the results).
    func foreignKeyTarget(row: Int, column: Int) -> ForeignKeyTarget? {
        let display = displayResult
        guard row < display.rows.count, column < display.columns.count else { return nil }
        let name = display.columns[column].name
        guard let key = foreignKeys.first(where: { $0.columns.contains(name) }),
            key.columns.count == key.referencedColumns.count
        else { return nil }
        var filters: [ColumnFilter] = []
        for (local, referenced) in zip(key.columns, key.referencedColumns) {
            guard let index = columnIndex(of: local) else { return nil }
            switch display.rows[row][index] {
            case .null, .bytes: return nil
            case let value:
                guard let text = value.displayText else { return nil }
                filters.append(ColumnFilter(column: referenced, op: .equals, value: text))
            }
        }
        return ForeignKeyTarget(
            database: key.referencedDatabase.isEmpty ? database : key.referencedDatabase,
            table: key.referencedTable, filters: FilterSet(filters: filters))
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

#if DEBUG
    // MARK: - Previews

    extension TableBrowserModel {
        /// An `orders` page with sample rows; optionally with filters applied and edits staged.
        static func preview(
            withFilters: Bool = false, withEdits: Bool = false, safeMode: SafeMode = .off, estimated: Bool = false,
            pane: Pane = .data
        ) -> TableBrowserModel {
            let model = TableBrowserModel(session: nil, database: "shop", table: "orders", safeMode: safeMode)
            model.schemaColumns = PreviewData.ordersSchema
            model.result = PreviewData.orders
            model.status = TableStatus(
                estimatedRows: estimated ? 226_374_516 : 9_870, dataBytes: estimated ? 82_799_157_248 : 1_589_248,
                indexBytes: estimated ? 41_661_054_976 : 245_760, freeBytes: 4_194_304, autoIncrement: 10_001,
                engine: "InnoDB", collation: "utf8mb4_0900_ai_ci", createdAt: "2026-11-02 09:14:55",
                comment: estimated ? nil : "Customer orders")
            if estimated && !withFilters {
                model.totalRows = 226_374_516
                model.totalIsEstimate = true
            } else if !estimated {
                model.totalRows = 10_000
            }
            model.pane = pane
            model.structure = PreviewData.ordersStructure
            model.foreignKeys = PreviewData.ordersStructure.foreignKeys
            if withFilters {
                model.filters = FilterSet(filters: [
                    ColumnFilter(column: "status", op: .equals, value: "paid"),
                    ColumnFilter(column: "total", op: .greaterThan, value: "100"),
                ])
                model.appliedFilters = model.filters
                model.isFilterBarVisible = true
            }
            if withEdits {
                model.pending.updates = [0: [3: .text("shipped")], 3: [4: .text("Leave at door")]]
                model.pending.deletes = [2]
                model.pending.inserts = [[1: .text("42"), 2: .text("19.99"), 3: .text("paid")]]
            }
            return model
        }
    }
#endif
