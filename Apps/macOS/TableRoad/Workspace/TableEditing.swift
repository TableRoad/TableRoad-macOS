import Foundation
import TableRoadCore
import TableRoadSQL

/// Visual state of a grid cell while edits are staged.
enum GridCellState: Equatable {
    case normal
    /// Changed but not yet committed.
    case edited
    /// Part of a new row.
    case inserted
    /// New row cell left at the column default.
    case insertedDefault
    /// Row marked for deletion.
    case deleted
}

/// Edits staged against the current page, applied in one transaction on ⌘S.
struct PendingEdits: Hashable {
    /// Page row → column index → new value.
    var updates: [Int: [Int: CellEdit]] = [:]
    /// Page rows marked for deletion.
    var deletes: Set<Int> = []
    /// New rows: column index → value (missing = column default).
    var inserts: [[Int: CellEdit]] = []

    var isEmpty: Bool { updates.isEmpty && deletes.isEmpty && inserts.isEmpty }
    /// Number of rows affected, for the footer.
    var changedRowCount: Int { Set(updates.keys).subtracting(deletes).count + deletes.count + inserts.count }
}

extension CellEdit {
    /// How a staged value is shown in the grid.
    var displayValue: CellValue {
        switch self {
        case .text(let text): .text(text)
        case .null: .null
        case .defaultValue: .unsupported(typeName: "DEFAULT", raw: "DEFAULT")
        }
    }
}

/// A one-shot request for the grid to edit a cell; `id` makes repeated requests distinct.
struct GridEditRequest: Equatable {
    let id = UUID()
    var row: Int
    var column: Int
}
