import TableRoadCore

/// Engine-specific SQL spelling. Values are only ever rendered as literals for TableRoad's own
/// introspection/paging queries; user edits use parameterised statements (Phase 4).
public protocol SQLDialect: Sendable {
    func quoteIdentifier(_ name: String) -> String
    /// A string literal that is safe regardless of server SQL mode.
    func stringLiteral(_ value: String) -> String
}

extension SQLDialect {
    /// `db`.`table` style qualified name.
    public func qualified(_ parts: String?...) -> String {
        parts.compactMap { $0 }.map(quoteIdentifier).joined(separator: ".")
    }
}

/// MySQL and MariaDB.
public struct MySQLDialect: SQLDialect {
    public enum Flavor: Sendable { case mysql, mariadb }
    public var flavor: Flavor
    /// False when the server's `sql_mode` includes `NO_BACKSLASH_ESCAPES` (read at connect time).
    public var backslashEscapes: Bool

    public init(flavor: Flavor, backslashEscapes: Bool = true) {
        self.flavor = flavor
        self.backslashEscapes = backslashEscapes
    }

    public func quoteIdentifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// A readable quoted literal, escaped for the server's actual `sql_mode`.
    public func stringLiteral(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "'", with: "''")
        if backslashEscapes {
            escaped =
                value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\0", with: "\\0")
                .replacingOccurrences(of: "'", with: "''")
        }
        return "'" + escaped + "'"
    }
}

/// A sort applied to the data browser.
public struct ColumnSort: Sendable, Hashable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// Builds the data browser's page query.
public struct PageQuery: Sendable, Hashable {
    public var database: String
    public var table: String
    public var sort: [ColumnSort]
    public var filters: FilterSet
    public var limit: Int
    public var offset: Int

    public init(
        database: String, table: String, sort: [ColumnSort] = [], filters: FilterSet = FilterSet(),
        limit: Int = 300, offset: Int = 0
    ) {
        self.database = database
        self.table = table
        self.sort = sort
        self.filters = filters
        self.limit = limit
        self.offset = offset
    }

    public func selectSQL(_ dialect: some SQLDialect) -> String {
        var sql = "SELECT * FROM \(dialect.qualified(database, table))" + filters.whereClause(dialect)
        if !sort.isEmpty {
            sql +=
                " ORDER BY "
                + sort.map { "\(dialect.quoteIdentifier($0.column)) \($0.ascending ? "ASC" : "DESC")" }
                .joined(separator: ", ")
        }
        sql += " LIMIT \(max(limit, 0)) OFFSET \(max(offset, 0))"
        return sql
    }

    public func countSQL(_ dialect: some SQLDialect) -> String {
        "SELECT COUNT(*) FROM \(dialect.qualified(database, table))" + filters.whereClause(dialect)
    }
}
