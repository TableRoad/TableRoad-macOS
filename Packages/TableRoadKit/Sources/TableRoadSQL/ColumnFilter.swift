import Foundation

/// One row of the table browser's filter bar.
public struct ColumnFilter: Sendable, Hashable, Identifiable {
    public enum Operator: String, Sendable, CaseIterable, Identifiable {
        case equals = "="
        case notEquals = "≠"
        case lessThan = "<"
        case lessThanOrEqual = "≤"
        case greaterThan = ">"
        case greaterThanOrEqual = "≥"
        case contains = "contains"
        case notContains = "does not contain"
        case beginsWith = "begins with"
        case endsWith = "ends with"
        case isIn = "in list"
        case notIn = "not in list"
        case isNull = "is NULL"
        case isNotNull = "is not NULL"
        case isEmpty = "is empty"
        /// Free-form condition typed by the user, used verbatim (column is ignored).
        case rawSQL = "SQL"

        public var id: String { rawValue }

        /// Whether the operator takes a value.
        public var needsValue: Bool {
            switch self {
            case .isNull, .isNotNull, .isEmpty: false
            default: true
            }
        }
    }

    public var id: UUID
    public var column: String
    public var op: Operator
    public var value: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), column: String, op: Operator = .equals, value: String = "", isEnabled: Bool = true) {
        self.id = id
        self.column = column
        self.op = op
        self.value = value
        self.isEnabled = isEnabled
    }

    /// Whether this filter contributes to the WHERE clause.
    public var isActive: Bool {
        guard isEnabled else { return false }
        if op == .rawSQL { return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !column.isEmpty && (!op.needsValue || !value.isEmpty || op == .equals || op == .notEquals)
    }

    /// SQL condition for this filter, or nil when inactive.
    public func condition(_ dialect: some SQLDialect) -> String? {
        guard isActive else { return nil }
        let column = dialect.quoteIdentifier(self.column)
        let literal = { dialect.stringLiteral(self.value) }
        switch op {
        case .equals: return "\(column) = \(literal())"
        case .notEquals: return "\(column) <> \(literal())"
        case .lessThan: return "\(column) < \(literal())"
        case .lessThanOrEqual: return "\(column) <= \(literal())"
        case .greaterThan: return "\(column) > \(literal())"
        case .greaterThanOrEqual: return "\(column) >= \(literal())"
        case .contains:
            return "\(dialect.likeOperand(column)) LIKE \(likePattern(dialect, prefix: "%", suffix: "%")) ESCAPE '!'"
        case .notContains:
            return
                "\(dialect.likeOperand(column)) NOT LIKE \(likePattern(dialect, prefix: "%", suffix: "%")) ESCAPE '!'"
        case .beginsWith:
            return "\(dialect.likeOperand(column)) LIKE \(likePattern(dialect, prefix: "", suffix: "%")) ESCAPE '!'"
        case .endsWith:
            return "\(dialect.likeOperand(column)) LIKE \(likePattern(dialect, prefix: "%", suffix: "")) ESCAPE '!'"
        case .isIn, .notIn:
            let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                !$0.isEmpty
            }
            guard !items.isEmpty else { return nil }
            let list = items.map(dialect.stringLiteral).joined(separator: ", ")
            return "\(column) \(op == .isIn ? "IN" : "NOT IN") (\(list))"
        case .isNull: return "\(column) IS NULL"
        case .isNotNull: return "\(column) IS NOT NULL"
        case .isEmpty: return "\(column) = ''"
        case .rawSQL: return "(\(value))"
        }
    }

    /// LIKE pattern with `%`, `_` and the escape char itself escaped using `!` (avoids backslash-mode differences).
    private func likePattern(_ dialect: some SQLDialect, prefix: String, suffix: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
        return dialect.stringLiteral(prefix + escaped + suffix)
    }
}

/// The whole filter bar: rows plus how they combine.
public struct FilterSet: Sendable, Hashable {
    public var filters: [ColumnFilter]
    /// AND (all) vs OR (any).
    public var matchAll: Bool

    public init(filters: [ColumnFilter] = [], matchAll: Bool = true) {
        self.filters = filters
        self.matchAll = matchAll
    }

    public var activeCount: Int { filters.filter(\.isActive).count }

    /// `WHERE …` clause (with leading space), or "" when nothing is active.
    public func whereClause(_ dialect: some SQLDialect) -> String {
        let conditions = filters.compactMap { $0.condition(dialect) }
        guard !conditions.isEmpty else { return "" }
        return " WHERE " + conditions.joined(separator: matchAll ? " AND " : " OR ")
    }
}
