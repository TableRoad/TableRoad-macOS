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
    /// Changes whenever staged edits change, so cell colours refresh.
    var revision: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.onCopy = { [weak coordinator = context.coordinator] in coordinator?.copySelection() }
        tableView.onDelete = { [weak coordinator = context.coordinator] in coordinator?.deleteSelection() }
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
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
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
            // Reloading mid-edit would throw away what the user is typing.
            if tableView.editedRow < 0 {
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
            } else if let text = value.displayText {
                // Single line: newlines would break row height.
                cell.stringValue = text.count > 500 ? String(text.prefix(500)) + "…" : text
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
            return cellView
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
            guard let tableView else { return }
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
            guard let tableView, let editing = parent?.editing else {
                menu.addItem(withTitle: "Copy", action: #selector(copyItem), keyEquivalent: "").target = self
                return
            }
            let row = tableView.clickedRow
            let tableColumnIndex = tableView.clickedColumn
            if row >= 0 && !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let column = tableColumnIndex >= 0 ? dataColumn(tableView.tableColumns[tableColumnIndex]) : nil

            func item(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
                let menuItem = ClosureMenuItem(title: title, action: action)
                menuItem.isEnabled = enabled
                menu.addItem(menuItem)
            }
            menu.autoenablesItems = false
            if row >= 0, let column {
                item("Edit Cell", enabled: editing.editableText(row, column) != nil) { [weak self] in
                    self?.beginEditing(row: row, tableColumnIndex: tableColumnIndex)
                }
                let rows = tableView.selectedRowIndexes
                if let choices = editing.choices(column), editing.editableText(row, column) != nil {
                    let submenu = NSMenu()
                    for choice in choices {
                        submenu.addItem(
                            ClosureMenuItem(title: choice.isEmpty ? "(empty)" : choice) {
                                rows.forEach { editing.setCell($0, column, .text(choice)) }
                            })
                    }
                    let setValue = NSMenuItem(title: "Set Value", action: nil, keyEquivalent: "")
                    setValue.submenu = submenu
                    menu.addItem(setValue)
                }
                item("Set to NULL", enabled: editing.editableText(row, column) != nil) {
                    rows.forEach { editing.setCell($0, column, .null) }
                }
                if editing.isInsertedRow(row) {
                    item("Set to DEFAULT") { rows.forEach { editing.setCell($0, column, .defaultValue) } }
                }
                menu.addItem(.separator())
            }
            item("Add Row") { editing.addRow() }
            if row >= 0 {
                item("Duplicate Row") { editing.duplicateRow(row) }
                let rows = tableView.selectedRowIndexes
                item(rows.count > 1 ? "Delete \(rows.count) Rows" : "Delete Row") { editing.deleteRows(rows) }
                menu.addItem(.separator())
                menu.addItem(withTitle: "Copy", action: #selector(copyItem), keyEquivalent: "").target = self
            }
        }

        @objc private func copyItem() { copySelection() }

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

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {  // delete, forward delete
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) ? !selectedRowIndexes.isEmpty : super.validateUserInterfaceItem(item)
    }
}
