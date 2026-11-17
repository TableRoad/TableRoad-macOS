import AppKit
import SwiftUI
import TableRoadCore
import TableRoadSQL

/// Callbacks that make the grid editable. Rows/columns are display indexes (column = data column, not the # column).
struct GridEditing {
    var cellState: (Int, Int) -> GridCellState
    /// Full text to edit, or nil when the cell can't be edited inline.
    var editableText: (Int, Int) -> String?
    var setCell: (Int, Int, CellEdit) -> Void
    var deleteRows: (IndexSet) -> Void
    var duplicateRow: (Int) -> Void
    var addRow: () -> Void
    /// Whether a row is a staged insert (enables "Set to DEFAULT").
    var isInsertedRow: (Int) -> Bool
    /// Allowed values for ENUM/SET columns (offered as a "Set Value" menu).
    var choices: (Int) -> [String]?
    /// Scroll to and start editing a cell, once per request.
    var editRequest: GridEditRequest?
    /// Double-click on a cell that can't be edited inline (multi-line, binary) opens the inspector.
    var showInspector: () -> Void = {}
    /// Whether the Quick Look editor may change a cell (it handles multi-line text the inline editor can't).
    var canEditInEditor: (Int, Int) -> Bool = { _, _ in false }
}

/// Virtualised result grid backed by `NSTableView` (SwiftUI's `Table` can't handle wide, dynamic, large results).
struct DataGridView: NSViewRepresentable {
    var result: ResultSet
    /// Current sort (data browser only).
    var sort: ColumnSort?
    var sortable: Bool = false
    var onSort: (ColumnSort?) -> Void = { _ in }
    /// Row-number offset for paging (row 1 of page 2 shows "301").
    var rowNumberOffset: Int = 0
    var editing: GridEditing?
    /// Identifies the data being shown. When set, the grid only reloads when it changes (sorting, selection and
    /// loading spinners no longer trigger full reloads). `nil` reloads on every update.
    var revision: AnyHashable? = nil
    /// Selected display rows (drives the row inspector).
    var onSelectionChange: (IndexSet) -> Void = { _ in }
    /// Table the rows came from (for "Copy Rows As ▸ SQL INSERT" and export file names).
    var tableName: String? = nil
    var dialect: any SQLDialect = MySQLDialect(flavor: .mysql)
    /// Context-menu extras; each item only appears when its handler is set.
    var onRefresh: (() -> Void)? = nil
    var onQuickFilter: ((ColumnFilter) -> Void)? = nil
    var onInspect: (() -> Void)? = nil
    /// Data columns that are foreign keys: their values get a → that opens the referenced row.
    var foreignKeyColumns: Set<Int> = []
    /// Opens the row a foreign key cell refers to, in a new tab (row, column).
    var onFollowForeignKey: ((Int, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.onCopy = { [weak coordinator = context.coordinator] in coordinator?.copySelection() }
        tableView.onDelete = { [weak coordinator = context.coordinator] in coordinator?.deleteSelection() }
        tableView.onQuickLook = { [weak coordinator = context.coordinator] in coordinator?.quickLookSelection() }
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        tableView.action = #selector(Coordinator.clicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // The grid sits below SwiftUI's tab strip, not under the toolbar; automatic insets would reserve toolbar
        // space and let rows scroll under the header.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate,
        NSPopoverDelegate
    {
        weak var tableView: NSTableView?
        private var parent: DataGridView?
        private var columnSignature: [String] = []
        private var isApplyingSort = false
        /// Cell being edited inline.
        private var editingCell: (row: Int, column: Int, original: String)?
        private var editCancelled = false
        /// Move to the next cell after this edit ends (Tab).
        private var advanceAfterEdit = false
        private var lastEditRequestID: UUID?
        private var lastReportedSelection = IndexSet()
        private var lastRevision: AnyHashable?
        private var hasLoaded = false

        private static let rowNumberID = NSUserInterfaceItemIdentifier("#")
        private static let cellFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        private static let nullFont = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: .italicFontMask)

        func update(_ parent: DataGridView) {
            self.parent = parent
            guard let tableView else { return }
            let signature = parent.result.columns.map { "\($0.name)|\($0.typeName)" }
            if signature != columnSignature {
                columnSignature = signature
                rebuildColumns(tableView, parent: parent)
            }
            applySortIndicator(tableView, parent: parent)
            let dataChanged = parent.revision == nil || parent.revision != lastRevision || !hasLoaded
            // Reloading mid-edit would throw away what the user is typing.
            if dataChanged && tableView.editedRow < 0 {
                lastRevision = parent.revision
                hasLoaded = true
                let selection = tableView.selectedRowIndexes
                tableView.reloadData()
                tableView.selectRowIndexes(
                    selection.filteredIndexSet { $0 < tableView.numberOfRows }, byExtendingSelection: false)
            }
            if let request = parent.editing?.editRequest, request.id != lastEditRequestID {
                lastEditRequestID = request.id
                DispatchQueue.main.async { [weak self] in
                    guard let self, let tableView = self.tableView, request.row < tableView.numberOfRows else { return }
                    tableView.scrollRowToVisible(request.row)
                    tableView.selectRowIndexes(IndexSet(integer: request.row), byExtendingSelection: false)
                    if let tableColumn = tableView.tableColumns.firstIndex(where: {
                        $0.identifier.rawValue == String(request.column)
                    }) {
                        self.beginEditing(row: request.row, tableColumnIndex: tableColumn)
                    }
                }
            }
        }

        private func rebuildColumns(_ tableView: NSTableView, parent: DataGridView) {
            tableView.tableColumns.forEach(tableView.removeTableColumn)

            let numbers = NSTableColumn(identifier: Self.rowNumberID)
            numbers.title = ""
            numbers.width = 44
            numbers.minWidth = 30
            numbers.isEditable = false
            tableView.addTableColumn(numbers)

            for (index, column) in parent.result.columns.enumerated() {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                tableColumn.title = column.name
                tableColumn.headerCell.alignment = .center
                tableColumn.headerToolTip = "\(column.name) — \(column.typeName)"
                tableColumn.width = Self.initialWidth(for: index, in: parent.result)
                tableColumn.minWidth = 40
                if parent.sortable {
                    tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.name, ascending: true)
                }
                tableView.addTableColumn(tableColumn)
            }
        }

        private func applySortIndicator(_ tableView: NSTableView, parent: DataGridView) {
            isApplyingSort = true
            defer { isApplyingSort = false }
            if let sort = parent.sort {
                tableView.sortDescriptors = [NSSortDescriptor(key: sort.column, ascending: sort.ascending)]
            } else {
                tableView.sortDescriptors = []
            }
        }

        static func isNumericType(_ typeName: String) -> Bool {
            let type = typeName.uppercased()
            return ["INT", "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL"].contains { type.contains($0) }
                && !type.contains("POINT")
        }

        /// Width from the header and the first rows' content, capped so one long value can't take over.
        static func initialWidth(for index: Int, in result: ResultSet) -> CGFloat {
            let sample = result.rows.prefix(50).compactMap { $0[index].displayText?.prefix(80) }
            let longest = max(result.columns[index].name.count + 2, sample.map(\.count).max() ?? 4)
            return min(max(CGFloat(longest) * 7.5 + 16, 60), 360)
        }

        private func dataColumn(_ tableColumn: NSTableColumn?) -> Int? {
            tableColumn.flatMap { Int($0.identifier.rawValue) }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent?.result.rows.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, let tableColumn else { return nil }
            let cellView =
                tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? GridCellView
                ?? GridCellView(identifier: tableColumn.identifier)
            let cell = cellView.label
            cell.delegate = self
            cell.isEditable = false
            cellView.onFollow = nil

            if tableColumn.identifier == Self.rowNumberID {
                cell.stringValue = String(parent.rowNumberOffset + row + 1)
                cell.textColor = .tertiaryLabelColor
                cell.font = Self.cellFont
                cell.alignment = .right
                cellView.state = parent.editing?.cellState(row, 0) == .deleted ? .deleted : .normal
                return cellView
            }
            guard let index = dataColumn(tableColumn), row < parent.result.rows.count else { return cellView }
            let value = parent.result.rows[row][index]
            let state = parent.editing?.cellState(row, index) ?? .normal
            cellView.state = state

            if state == .insertedDefault {
                cell.stringValue = "DEFAULT"
                cell.textColor = .tertiaryLabelColor
                cell.font = Self.nullFont
            } else if let text = value.displayText, text.isEmpty {
                // An empty string, as distinct from NULL.
                cell.stringValue = "EMPTY"
                cell.textColor = .tertiaryLabelColor
                cell.font = Self.nullFont
            } else if let text = value.displayText {
                // Single-line cells render nothing after a newline, so show line breaks as ↵.
                let clipped = text.count > 500 ? String(text.prefix(500)) + "…" : text
                cell.stringValue =
                    clipped.contains(where: \.isNewline)
                    ? clipped.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(
                        separator: " ↵ ")
                    : clipped
                cell.textColor = .labelColor
                cell.font = Self.cellFont
            } else {
                cell.stringValue = "NULL"
                cell.textColor = .tertiaryLabelColor
                cell.font = Self.nullFont
            }
            if state == .deleted {
                cell.attributedStringValue = NSAttributedString(
                    string: cell.stringValue,
                    attributes: [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: cell.font ?? Self.cellFont,
                    ])
            }
            cell.alignment = value.isNumeric ? .right : .left
            if let follow = parent.onFollowForeignKey, parent.foreignKeyColumns.contains(index),
                state != .insertedDefault, state != .deleted, Self.isFollowable(value)
            {
                cellView.onFollow = { follow(row, index) }
            }
            return cellView
        }

        /// Values a foreign key link can be followed from (NULL points nowhere; binary can't be filtered on).
        static func isFollowable(_ value: CellValue) -> Bool {
            switch value {
            case .null, .bytes: false
            default: true
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, tableView.selectedRowIndexes != lastReportedSelection else { return }
            lastReportedSelection = tableView.selectedRowIndexes
            let selection = lastReportedSelection
            // Defer: SwiftUI state must not change during the view update that triggered a reselect.
            DispatchQueue.main.async { [weak self] in self?.parent?.onSelectionChange(selection) }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplyingSort, let parent, parent.sortable else { return }
            let sort = tableView.sortDescriptors.first.flatMap { descriptor in
                descriptor.key.map { ColumnSort(column: $0, ascending: descriptor.ascending) }
            }
            parent.onSort(sort)
        }

        // MARK: Inline editing

        @objc func doubleClicked(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0, tableView.clickedColumn >= 0 else { return }
            guard let editing = parent?.editing else {
                // Read-only grids (query results, structure): double-click shows the full value.
                quickLook(row: tableView.clickedRow, tableColumnIndex: tableView.clickedColumn)
                return
            }
            if let column = dataColumn(tableView.tableColumns[tableView.clickedColumn]),
                editing.editableText(tableView.clickedRow, column) == nil
            {
                // Multi-line text, JSON and HTML: the Quick Look editor (binary still goes to the inspector).
                if case .bytes = parent?.result.rows[tableView.clickedRow][column] {
                    editing.showInspector()
                } else {
                    quickLook(row: tableView.clickedRow, tableColumnIndex: tableView.clickedColumn)
                }
                return
            }
            beginEditing(row: tableView.clickedRow, tableColumnIndex: tableView.clickedColumn)
        }

        func beginEditing(row: Int, tableColumnIndex: Int) {
            guard let tableView, let editing = parent?.editing, row >= 0, tableColumnIndex >= 0,
                let column = dataColumn(tableView.tableColumns[tableColumnIndex]),
                let text = editing.editableText(row, column),
                let cellView = tableView.view(atColumn: tableColumnIndex, row: row, makeIfNecessary: true)
                    as? GridCellView
            else {
                NSSound.beep()
                return
            }
            editingCell = (row, column, text)
            editCancelled = false
            let field = cellView.label
            field.isEditable = true
            field.font = Self.cellFont
            field.textColor = .labelColor
            field.stringValue = text
            tableView.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                editCancelled = true
                tableView?.window?.makeFirstResponder(tableView)
                return true
            }
            if selector == #selector(NSResponder.insertTab(_:)) {
                advanceAfterEdit = true
                tableView?.window?.makeFirstResponder(tableView)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let cell = editingCell else { return }
            field.isEditable = false
            editingCell = nil
            let text = field.stringValue
            if !editCancelled && text != cell.original {
                parent?.editing?.setCell(cell.row, cell.column, .text(text))
            } else {
                tableView?.reloadData(
                    forRowIndexes: IndexSet(integer: cell.row),
                    columnIndexes: IndexSet(integersIn: 0..<(tableView?.numberOfColumns ?? 0)))
            }
            if advanceAfterEdit {
                advanceAfterEdit = false
                // Tab: continue with the next column in the same row (after SwiftUI re-renders).
                let nextColumn = cell.column + 1
                DispatchQueue.main.async { [weak self] in
                    guard let self, let tableView = self.tableView,
                        let index = tableView.tableColumns.firstIndex(where: {
                            $0.identifier.rawValue == String(nextColumn)
                        })
                    else { return }
                    self.beginEditing(row: cell.row, tableColumnIndex: index)
                }
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            menu.autoenablesItems = false
            guard let tableView, let parent else { return }
            let row = tableView.clickedRow
            let tableColumnIndex = tableView.clickedColumn
            if row >= 0 && !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let rows = tableView.selectedRowIndexes
            let column = tableColumnIndex >= 0 ? dataColumn(tableView.tableColumns[tableColumnIndex]) : nil
            let editing = parent.editing
            let value: CellValue? =
                if row >= 0, let column, row < parent.result.rows.count { parent.result.rows[row][column] } else {
                    nil
                }

            @discardableResult
            func item(
                _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true,
                in target: NSMenu? = nil, _ action: @escaping () -> Void
            ) -> NSMenuItem {
                let menuItem = ClosureMenuItem(title: title, action: action)
                menuItem.keyEquivalent = key
                menuItem.keyEquivalentModifierMask = modifiers
                menuItem.isEnabled = enabled
                (target ?? menu).addItem(menuItem)
                return menuItem
            }
            func submenu(_ title: String, enabled: Bool = true, _ build: (NSMenu) -> Void) {
                let sub = NSMenu()
                sub.autoenablesItems = false
                build(sub)
                let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                holder.submenu = sub
                holder.isEnabled = enabled && !sub.items.isEmpty
                menu.addItem(holder)
            }
            func separator() {
                if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            }

            // Inspect / edit
            if row >= 0, column != nil {
                item("Quick Look Editor", key: " ", modifiers: []) { [weak self] in
                    self?.quickLook(row: row, tableColumnIndex: tableColumnIndex)
                }
            }
            if row >= 0, let inspect = parent.onInspect ?? editing?.showInspector {
                item("Open in Inspector", inspect)
            }
            if row >= 0, let column, let editing {
                let canEdit = editing.editableText(row, column) != nil
                item("Edit Cell", enabled: canEdit) { [weak self] in
                    self?.beginEditing(row: row, tableColumnIndex: tableColumnIndex)
                }
                submenu("Set Value", enabled: canEdit) { sub in
                    if let choices = editing.choices(column) {
                        for choice in choices {
                            item(choice.isEmpty ? "(empty)" : choice, in: sub) {
                                rows.forEach { editing.setCell($0, column, .text(choice)) }
                            }
                        }
                        sub.addItem(.separator())
                    }
                    item("NULL", in: sub) { rows.forEach { editing.setCell($0, column, .null) } }
                    item("Empty String", in: sub) { rows.forEach { editing.setCell($0, column, .text("")) } }
                    if editing.isInsertedRow(row) {
                        item("DEFAULT", in: sub) { rows.forEach { editing.setCell($0, column, .defaultValue) } }
                    }
                }
            }
            if let refresh = parent.onRefresh {
                separator()
                item("Refresh", key: "r", refresh)
            }

            // Changes
            if let editing {
                separator()
                if row >= 0, let column {
                    let pasted = NSPasteboard.general.string(forType: .string)
                    item("Paste to Selected Cells", enabled: pasted != nil && editing.editableText(row, column) != nil)
                    {
                        guard let pasted else { return }
                        rows.forEach { editing.setCell($0, column, .text(pasted)) }
                    }
                }
                item("Add Row", key: "i") { editing.addRow() }
                if row >= 0 { item("Duplicate Row") { editing.duplicateRow(row) } }
            }

            // Copy
            if row >= 0 {
                separator()
                item(rows.count > 1 ? "Copy \(rows.count) Rows" : "Copy Row", key: "c") { [weak self] in
                    self?.copySelection()
                }
                submenu(rows.count > 1 ? "Copy Rows As" : "Copy Row As") { sub in
                    item("TSV with Header", in: sub) { [weak self] in self?.copyRows(rows, as: .tsv, header: true) }
                    for format in ExportFormat.allCases where format != .tsv {
                        item(format.rawValue, in: sub) { [weak self] in self?.copyRows(rows, as: format) }
                    }
                }
                if let column, let value {
                    item("Copy Cell") { Self.copy(value.displayText ?? "NULL") }
                    item("Copy Column Values") { [weak self] in
                        guard let self, let parent = self.parent else { return }
                        Self.copy(parent.result.rows.map { $0[column].displayText ?? "NULL" }.joined(separator: "\n"))
                    }
                    item("Copy Column Name") { Self.copy(parent.result.columns[column].name) }
                }
            }

            // Foreign key
            if let follow = parent.onFollowForeignKey, let column, let value, row >= 0,
                parent.foreignKeyColumns.contains(column)
            {
                separator()
                item("Open Referenced Row", enabled: Self.isFollowable(value)) { follow(row, column) }
            }

            // Quick filter (data browser)
            if let quickFilter = parent.onQuickFilter, let column, let value {
                separator()
                let name = parent.result.columns[column].name
                submenu("Quick Filter") { sub in
                    switch value {
                    case .null:
                        item("\(name) IS NULL", in: sub) { quickFilter(ColumnFilter(column: name, op: .isNull)) }
                        item("\(name) IS NOT NULL", in: sub) {
                            quickFilter(ColumnFilter(column: name, op: .isNotNull))
                        }
                    case .bytes:
                        item("\(name) IS NOT NULL", in: sub) {
                            quickFilter(ColumnFilter(column: name, op: .isNotNull))
                        }
                    default:
                        let text = value.displayText ?? ""
                        let shown = text.count > 40 ? String(text.prefix(40)) + "…" : text
                        item("\(name) = \(shown)", in: sub) {
                            quickFilter(ColumnFilter(column: name, op: .equals, value: text))
                        }
                        item("\(name) ≠ \(shown)", in: sub) {
                            quickFilter(ColumnFilter(column: name, op: .notEquals, value: text))
                        }
                        if !value.isNumeric && !text.isEmpty {
                            item("\(name) contains \(shown)", in: sub) {
                                quickFilter(ColumnFilter(column: name, op: .contains, value: text))
                            }
                        }
                        if value.isNumeric {
                            item("\(name) > \(shown)", in: sub) {
                                quickFilter(ColumnFilter(column: name, op: .greaterThan, value: text))
                            }
                            item("\(name) < \(shown)", in: sub) {
                                quickFilter(ColumnFilter(column: name, op: .lessThan, value: text))
                            }
                        }
                        item("\(name) IS NULL", in: sub) { quickFilter(ColumnFilter(column: name, op: .isNull)) }
                    }
                }
            }

            // Export
            if !parent.result.rows.isEmpty {
                separator()
                submenu("Export Current Page As") { sub in
                    for format in ExportFormat.allCases {
                        item("\(format.rawValue)…", in: sub) { [weak self] in self?.exportPage(as: format) }
                    }
                }
            }

            // Delete
            if row >= 0, let editing {
                separator()
                item(rows.count > 1 ? "Delete \(rows.count) Rows" : "Delete Row", key: "\u{8}", modifiers: []) {
                    editing.deleteRows(rows)
                }
            }
            if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        }

        // MARK: Quick Look

        /// Column last clicked, so Space can open Quick Look on the selected row's cell.
        private var lastClickedColumn = -1

        @objc func clicked(_ sender: Any?) {
            if let tableView, tableView.clickedColumn >= 0 { lastClickedColumn = tableView.clickedColumn }
        }

        func quickLookSelection() {
            guard let tableView, let row = tableView.selectedRowIndexes.first else { return }
            let column =
                lastClickedColumn > 0 && lastClickedColumn < tableView.numberOfColumns
                ? lastClickedColumn : min(1, tableView.numberOfColumns - 1)
            quickLook(row: row, tableColumnIndex: column)
        }

        private var popover: NSPopover?

        /// Shows the cell's full value in a popover under the cell (TablePlus's Quick Look Editor).
        func quickLook(row: Int, tableColumnIndex: Int) {
            guard let tableView, let parent, tableColumnIndex >= 0, tableColumnIndex < tableView.numberOfColumns,
                let column = dataColumn(tableView.tableColumns[tableColumnIndex]), row < parent.result.rows.count
            else { return }
            let value = parent.result.rows[row][column]
            let name = parent.result.columns[column].name
            let editable: Bool = {
                if case .bytes = value { return false }
                return parent.editing?.canEditInEditor(row, column) ?? false
            }()
            // Remember the row as shown, so a value edited after the page reloads can't land on another row.
            var snapshot = parent.result.rows[row]
            let document = CellDocument(
                title: [name, parent.tableName].compactMap { $0 }.joined(separator: " — "),
                text: value.displayText ?? "", isEditable: editable
            ) { [weak self] text in
                guard let self, let parent = self.parent, let editing = parent.editing,
                    row < parent.result.rows.count, parent.result.rows[row] == snapshot
                else {
                    return "The row changed (the page was reloaded or edited), so this value wasn't applied. "
                        + "Copy your text and open the cell again."
                }
                editing.setCell(row, column, .text(text))
                snapshot = self.parent?.result.rows[row] ?? snapshot
                return nil
            }
            popover?.close()
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.contentSize = NSSize(width: 760, height: 460)
            let controller = NSHostingController(
                rootView: CellEditorView(
                    document: document,
                    mode: .popover(openInWindow: { [weak popover] in
                        popover?.close()
                        CellEditorWindows.open(document)
                    })))
            popover.contentViewController = controller
            popover.delegate = self
            self.popover = popover
            self.popoverDocument = document
            tableView.scrollRowToVisible(row)
            let rect = tableView.frameOfCell(atColumn: tableColumnIndex, row: row)
            popover.show(relativeTo: rect, of: tableView, preferredEdge: .maxY)
        }

        private var popoverDocument: CellDocument?

        func popoverWillClose(_ notification: Notification) {
            // Closing the popover keeps the edit (it's staged, not saved to the server).
            popoverDocument?.commitChanges()
        }

        func popoverDidClose(_ notification: Notification) {
            popoverDocument = nil
            popover = nil
        }

        private func exporter(rows: IndexSet? = nil) -> ResultExporter? {
            guard let parent else { return nil }
            let selected = rows.map { $0.filter { $0 < parent.result.rows.count }.map { parent.result.rows[$0] } }
            return ResultExporter(
                columns: parent.result.columns.map(\.name), rows: selected ?? parent.result.rows,
                table: parent.tableName, dialect: parent.dialect)
        }

        private func copyRows(_ rows: IndexSet, as format: ExportFormat, header: Bool = true) {
            guard let exporter = exporter(rows: rows) else { return }
            Self.copy(exporter.render(format, includeHeader: header))
        }

        private func exportPage(as format: ExportFormat) {
            guard let exporter = exporter() else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(parent?.tableName ?? "results").\(format.fileExtension)"
            panel.title = "Export Current Page"
            panel.message = "Exports the \(exporter.rows.count) rows shown, as \(format.rawValue)."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try exporter.render(format).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }

        private static func copy(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        // MARK: Clipboard / keyboard

        /// ⌘C copies selected rows as tab-separated text.
        func copySelection() {
            guard let tableView, let parent else { return }
            let lines = tableView.selectedRowIndexes.map { row in
                parent.result.rows[row].map { $0.displayText ?? "NULL" }.joined(separator: "\t")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }

        /// ⌫ marks selected rows for deletion (or un-marks them).
        func deleteSelection() {
            guard let tableView, let editing = parent?.editing, !tableView.selectedRowIndexes.isEmpty else {
                NSSound.beep()
                return
            }
            editing.deleteRows(tableView.selectedRowIndexes)
        }
    }
}

/// Cell with an inset label and a state-coloured background.
final class GridCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    var state: GridCellState = .normal {
        didSet { if state != oldValue { needsDisplay = true } }
    }
    /// Set for foreign key values: shows a → after the value that opens the referenced row in a new tab.
    var onFollow: (() -> Void)? {
        didSet {
            let shown = onFollow != nil
            guard shown == arrow.isHidden else { return }
            arrow.isHidden = !shown
            labelToEdge.isActive = !shown
            labelToArrow.isActive = shown
        }
    }
    private let arrow = NSButton()
    private var labelToEdge: NSLayoutConstraint!
    private var labelToArrow: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)

        arrow.isBordered = false
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "Open referenced row")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.toolTip = "Open the referenced row in a new tab"
        arrow.setAccessibilityLabel("Open referenced row")
        arrow.target = self
        arrow.action = #selector(follow)
        arrow.isHidden = true
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.setContentHuggingPriority(.required, for: .horizontal)
        arrow.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(arrow)

        labelToEdge = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        labelToArrow = label.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -2)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            labelToEdge,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    @objc private func follow() {
        onFollow?()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor? =
            switch state {
            case .normal: nil
            case .edited: NSColor.systemOrange.withAlphaComponent(0.22)
            case .inserted, .insertedDefault: NSColor.systemGreen.withAlphaComponent(0.16)
            case .deleted: NSColor.systemRed.withAlphaComponent(0.14)
            }
        if let color {
            color.setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
    }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// Adds Edit ▸ Copy and ⌫ support (NSTableView doesn't implement `copy:` itself).
final class GridTableView: NSTableView {
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    var onQuickLook: (() -> Void)?

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {  // delete, forward delete
            onDelete?()
        } else if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onQuickLook?()  // Space, like Finder
        } else {
            super.keyDown(with: event)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) ? !selectedRowIndexes.isEmpty : super.validateUserInterfaceItem(item)
    }
}

#if DEBUG
    #Preview("Grid – sorted") {
        DataGridView(result: PreviewData.orders, sort: ColumnSort(column: "total", ascending: false), sortable: true)
            .frame(width: 800, height: 500)
    }

    #Preview("Grid – foreign key links") {
        DataGridView(
            result: PreviewData.orders, foreignKeyColumns: [1], onFollowForeignKey: { _, _ in }
        )
        .frame(width: 800, height: 500)
    }

    #Preview("Grid – staged edits") {
        let model = TableBrowserModel.preview(withEdits: true)
        return DataGridView(
            result: model.displayResult,
            editing: GridEditing(
                cellState: { model.cellState(row: $0, column: $1) }, editableText: { _, _ in nil },
                setCell: { _, _, _ in }, deleteRows: { _ in }, duplicateRow: { _ in }, addRow: {},
                isInsertedRow: { $0 >= model.pageRowCount }, choices: { _ in nil }, editRequest: nil),
            revision: model.gridRevision
        )
        .frame(width: 800, height: 500)
    }
#endif
