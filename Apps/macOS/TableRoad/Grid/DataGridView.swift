import AppKit
import SwiftUI
import TableRoadCore
import TableRoadSQL

/// Virtualised result grid backed by `NSTableView` (SwiftUI's `Table` can't handle wide, dynamic, large results).
struct DataGridView: NSViewRepresentable {
    var result: ResultSet
    /// Current sort (data browser only). `nil` disables header-click sorting.
    var sort: ColumnSort?
    var sortable: Bool = false
    var onSort: (ColumnSort?) -> Void = { _ in }
    /// Row-number offset for paging (row 1 of page 2 shows "301").
    var rowNumberOffset: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.onCopy = { [weak coordinator = context.coordinator] in coordinator?.copySelection() }
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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        private var parent: DataGridView?
        private var columnSignature: [String] = []
        private var isApplyingSort = false

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
            tableView.reloadData()
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

        /// Width from the header and the first rows' content, capped so one long value can't take over.
        static func initialWidth(for index: Int, in result: ResultSet) -> CGFloat {
            let sample = result.rows.prefix(50).compactMap { $0[index].displayText?.prefix(80) }
            let longest = max(result.columns[index].name.count + 2, sample.map(\.count).max() ?? 4)
            return min(max(CGFloat(longest) * 7.5 + 16, 60), 360)
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent?.result.rows.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, let tableColumn else { return nil }
            let cellView =
                tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView
                ?? Self.makeCell(identifier: tableColumn.identifier)
            guard let cell = cellView.textField else { return cellView }

            if tableColumn.identifier == Self.rowNumberID {
                cell.stringValue = String(parent.rowNumberOffset + row + 1)
                cell.textColor = .tertiaryLabelColor
                cell.font = Self.cellFont
                cell.alignment = .right
                return cellView
            }
            guard let index = Int(tableColumn.identifier.rawValue), row < parent.result.rows.count else {
                return cellView
            }
            let value = parent.result.rows[row][index]
            if let text = value.displayText {
                // Single line: newlines would break row height.
                cell.stringValue = text.count > 500 ? String(text.prefix(500)) + "…" : text
                cell.textColor = .labelColor
                cell.font = Self.cellFont
            } else {
                cell.stringValue = "NULL"
                cell.textColor = .tertiaryLabelColor
                cell.font = Self.nullFont
            }
            cell.alignment = value.isNumeric ? .right : .left
            return cellView
        }

        /// A label inset 6pt from the column edges, vertically centred.
        static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false

            let cellView = NSTableCellView()
            cellView.identifier = identifier
            cellView.textField = label
            cellView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
            return cellView
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplyingSort, let parent, parent.sortable else { return }
            let sort = tableView.sortDescriptors.first.flatMap { descriptor in
                descriptor.key.map { ColumnSort(column: $0, ascending: descriptor.ascending) }
            }
            parent.onSort(sort)
        }

        /// ⌘C copies selected rows as tab-separated text.
        func copySelection() {
            guard let tableView, let parent else { return }
            let lines = tableView.selectedRowIndexes.map { row in
                parent.result.rows[row].map { $0.displayText ?? "NULL" }.joined(separator: "\t")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
    }
}

/// Adds Edit ▸ Copy support (NSTableView doesn't implement `copy:` itself).
final class GridTableView: NSTableView {
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) ? !selectedRowIndexes.isEmpty : super.validateUserInterfaceItem(item)
    }
}
