import TableRoadCore

/// A user's edit of one cell.
public enum CellEdit: Sendable, Hashable {
    case text(String)
    case null
    /// Column default (inserts only).
    case defaultValue
}

public struct ColumnEdit: Sendable, Hashable {
    public var column: String
    public var edit: CellEdit

    public init(column: String, edit: CellEdit) {
        self.column = column
        self.edit = edit
    }
}

/// Identifies a row by its primary-key values (as text, which the server coerces back).
public struct RowKey: Sendable, Hashable {
    public var values: [ColumnEdit]

    public init(_ values: [(String, String)]) {
        self.values = values.map { ColumnEdit(column: $0.0, edit: .text($0.1)) }
    }
}

public enum RowChange: Sendable, Hashable {
    case update(key: RowKey, set: [ColumnEdit])
    case insert([ColumnEdit])
    case delete(key: RowKey)
}

/// Turns staged changes into SQL: parameterised statements to run, and readable SQL to preview.
public struct TableChangeBuilder: Sendable {
    public var database: String
    public var table: String
    public var dialect: any SQLDialect

    public init(database: String, table: String, dialect: any SQLDialect) {
        self.database = database
        self.table = table
        self.dialect = dialect
    }

    private var target: String { dialect.qualified(database, table) }

    public func statement(for change: RowChange) -> ParameterizedStatement {
        var parameters: [SQLParameter] = []
        func placeholder(_ edit: CellEdit) -> String {
            switch edit {
            case .text(let value):
                parameters.append(.text(value))
                return dialect.placeholder(parameters.count)
            case .null:
                return "NULL"
            case .defaultValue:
                return "DEFAULT"
            }
        }
        func whereKey(_ key: RowKey) -> String {
            key.values.map { "\(dialect.quoteIdentifier($0.column)) = \(placeholder($0.edit))" }
                .joined(separator: " AND ")
        }

        switch change {
        case .update(let key, let set):
            let assignments = set.map { "\(dialect.quoteIdentifier($0.column)) = \(placeholder($0.edit))" }
                .joined(separator: ", ")
            let condition = whereKey(key)
            // LIMIT 1: a primary key matches one row, but never risk more.
            return ParameterizedStatement(
                sql: "UPDATE \(target) SET \(assignments) WHERE \(condition)\(limitOne)", parameters: parameters)
        case .insert(let values):
            let provided = values.filter { $0.edit != .defaultValue }
            guard !provided.isEmpty else {
                return ParameterizedStatement(sql: "INSERT INTO \(target) \(dialect.emptyInsertValues)")
            }
            let columns = provided.map { dialect.quoteIdentifier($0.column) }.joined(separator: ", ")
            let valueList = provided.map { placeholder($0.edit) }.joined(separator: ", ")
            return ParameterizedStatement(
                sql: "INSERT INTO \(target) (\(columns)) VALUES (\(valueList))", parameters: parameters)
        case .delete(let key):
            return ParameterizedStatement(
                sql: "DELETE FROM \(target) WHERE \(whereKey(key))\(limitOne)", parameters: parameters)
        }
    }

    static func lastUnquotedQuestionMark(in sql: String) -> Range<String.Index>? {
        var inQuote: Character?
        var found: Range<String.Index>?
        var index = sql.startIndex
        while index < sql.endIndex {
            let character = sql[index]
            if let quote = inQuote {
                if character == quote { inQuote = nil }
            } else if character == "`" || character == "\"" || character == "'" {
                inQuote = character
            } else if character == "?" {
                found = index..<sql.index(after: index)
            }
            index = sql.index(after: index)
        }
        return found
    }

    /// LIMIT 1 on writes keyed by primary key, where the engine allows it (MySQL); a key matches one row anyway.
    private var limitOne: String { dialect.supportsWriteLimit ? " LIMIT 1" : "" }

    /// Human-readable SQL with values inlined as literals (for the preview sheet only; never executed).
    public func previewSQL(for change: RowChange) -> String {
        let statement = statement(for: change)
        var output = statement.sql
        // Last first, so "$1" never matches inside "$10".
        for (offset, parameter) in statement.parameters.enumerated().reversed() {
            let marker = dialect.placeholder(offset + 1)
            let literal: String =
                switch parameter {
                case .text(let value): dialect.stringLiteral(value)
                case .null: "NULL"
                }
            if marker == "?" {
                // "?" markers are positional: replace the last unquoted one.
                if let range = Self.lastUnquotedQuestionMark(in: output) {
                    output.replaceSubrange(range, with: literal)
                }
            } else if let range = output.range(of: marker, options: .backwards) {
                output.replaceSubrange(range, with: literal)
            }
        }
        return output + ";"
    }
}
