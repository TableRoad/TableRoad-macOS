import Foundation
import TableRoadCore

/// Engine-specific SQL spelling. Values are only ever rendered as literals for TableRoad's own
/// introspection/paging queries; user edits use parameterised statements (Phase 4).
public protocol SQLDialect: Sendable {
    func quoteIdentifier(_ name: String) -> String
    /// A string literal that is safe regardless of server SQL mode.
    func stringLiteral(_ value: String) -> String
    /// Bound-parameter marker for the n-th (1-based) parameter: `?` (MySQL, SQLite) or `$n` (PostgreSQL).
    func placeholder(_ index: Int) -> String
    /// Binary data as a literal.
    func bytesLiteral(_ data: Data) -> String
    func booleanLiteral(_ value: Bool) -> String
    func createDatabaseSQL(_ name: String, characterSet: String?, collation: String?) throws -> String
    func dropDatabaseSQL(_ name: String) -> String
    /// Statement that switches the default database/schema for a SQL dump (nil if the engine has none).
    func useDatabaseSQL(_ name: String) -> String?
    /// Session settings at the top of a SQL dump, and their undo at the bottom.
    var dumpPreamble: [String] { get }
    var dumpPostamble: [String] { get }
    /// Run on an export's connection before reading (e.g. read times in UTC to match the dump).
    var exportSessionSetup: [String] { get }
    /// UPDATE/DELETE … LIMIT n is allowed (MySQL).
    var supportsWriteLimit: Bool { get }
    /// What follows `INSERT INTO t` for a row of defaults: `() VALUES ()` (MySQL) or `DEFAULT VALUES`.
    var emptyInsertValues: String { get }
    /// The left side of LIKE for a column (PostgreSQL casts to text so numbers and dates can be searched).
    func likeOperand(_ quotedColumn: String) -> String
    /// SQL to run after a dump's rows are inserted into an auto-numbered column (PostgreSQL sequences).
    func resetSequenceSQL(table: String, column: String) -> String?
    /// Escapes % and _ in LIKE patterns, and the clause naming it (ClickHouse: backslash, no clause).
    var likeEscapeCharacter: String { get }
    var likeEscapeClause: String { get }
    /// A JSON value (arrays, maps) as a literal for this engine (most take JSON text as a string).
    func jsonLiteral(_ json: String) -> String
}

extension SQLDialect {
    /// `db`.`table` style qualified name.
    public func qualified(_ parts: String?...) -> String {
        parts.compactMap { $0 }.map(quoteIdentifier).joined(separator: ".")
    }

    public func placeholder(_ index: Int) -> String { "?" }
    public func bytesLiteral(_ data: Data) -> String {
        data.isEmpty ? "''" : "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
    }
    public func booleanLiteral(_ value: Bool) -> String { value ? "TRUE" : "FALSE" }
    public func createDatabaseSQL(_ name: String, characterSet: String?, collation: String?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw DDLError.emptyName }
        return "CREATE DATABASE \(quoteIdentifier(trimmed))"
    }
    public func dropDatabaseSQL(_ name: String) -> String { "DROP DATABASE \(quoteIdentifier(name))" }
    public func useDatabaseSQL(_ name: String) -> String? { nil }
    public var dumpPreamble: [String] { [] }
    public var dumpPostamble: [String] { [] }
    public var exportSessionSetup: [String] { [] }
    public var supportsWriteLimit: Bool { false }
    public var emptyInsertValues: String { "DEFAULT VALUES" }
    public func likeOperand(_ quotedColumn: String) -> String { quotedColumn }
    public func resetSequenceSQL(table: String, column: String) -> String? { nil }
    public var likeEscapeCharacter: String { "!" }
    public var likeEscapeClause: String { " ESCAPE '!'" }
    public func jsonLiteral(_ json: String) -> String { stringLiteral(json) }
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

    public var supportsWriteLimit: Bool { true }
    public var emptyInsertValues: String { "() VALUES ()" }

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
