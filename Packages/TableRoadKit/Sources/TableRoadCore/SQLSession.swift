import Foundation

/// A column in a result set.
public struct ResultColumn: Sendable, Hashable {
    public var name: String
    /// Source table, when the server reports one (lets the grid know a result is editable).
    public var table: String?
    /// Engine-specific type name, e.g. `VARCHAR`, `JSON`, `DECIMAL`.
    public var typeName: String

    public init(name: String, table: String? = nil, typeName: String) {
        self.name = name
        self.table = table
        self.typeName = typeName
    }
}

/// Rows returned by a statement.
public struct ResultSet: Sendable, Hashable {
    public var columns: [ResultColumn]
    public var rows: [[CellValue]]

    public init(columns: [ResultColumn], rows: [[CellValue]]) {
        self.columns = columns
        self.rows = rows
    }

    public static let empty = ResultSet(columns: [], rows: [])
}

/// What a single statement produced.
public enum QueryOutcome: Sendable, Hashable {
    case rows(ResultSet)
    case affected(rowCount: UInt64)
}

/// A schema object listed in the sidebar.
public struct TableInfo: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case table, view, systemView }

    public var name: String
    public var kind: Kind
    /// Engine estimate (InnoDB's is approximate); `nil` for views.
    public var estimatedRowCount: Int?
    public var id: String { name }

    public init(name: String, kind: Kind, estimatedRowCount: Int? = nil) {
        self.name = name
        self.kind = kind
        self.estimatedRowCount = estimatedRowCount
    }
}

/// A column as described by the schema (not by a result set).
public struct ColumnDetail: Sendable, Hashable, Identifiable {
    public var name: String
    /// Full type, e.g. `varchar(255)` or `enum('a','b')`.
    public var type: String
    public var isNullable: Bool
    public var isPrimaryKey: Bool
    public var defaultValue: String?
    /// e.g. `auto_increment`, `on update CURRENT_TIMESTAMP`.
    public var extra: String?
    public var comment: String?
    public var id: String { name }

    public init(
        name: String, type: String, isNullable: Bool, isPrimaryKey: Bool,
        defaultValue: String? = nil, extra: String? = nil, comment: String? = nil
    ) {
        self.name = name
        self.type = type
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
        self.extra = extra
        self.comment = comment
    }
}

/// Errors surfaced to the UI, normalised across engines.
public struct DatabaseError: Error, Sendable, Hashable, LocalizedError {
    public enum Category: Sendable, Hashable {
        case connection, authentication, tls, query, cancelled, unsupported
    }

    public var category: Category
    public var message: String
    /// Engine error code, e.g. MySQL `1146`.
    public var code: Int?

    public init(_ category: Category, _ message: String, code: Int? = nil) {
        self.category = category
        self.message = message
        self.code = code
    }

    public var errorDescription: String? {
        code.map { "\(message) (\($0))" } ?? message
    }
}

/// An open connection to a database server.
public protocol DatabaseSession: Actor {
    var kind: DatabaseKind { get }
    /// Server version string, e.g. `8.4.3` or `11.8.2-MariaDB`.
    var serverVersion: String { get }
    func close() async
}

/// A connection to a SQL engine. Implementations serialise statements internally, so callers
/// may issue requests from several tasks; `cancelCurrentQuery()` is never queued.
public protocol SQLSession: DatabaseSession {
    /// Runs a single statement. Use `StatementSplitter` for scripts.
    func execute(_ sql: String) async throws -> QueryOutcome
    /// Asks the server to abort the running statement.
    func cancelCurrentQuery() async throws

    /// The database the session is currently using, if any.
    var currentDatabase: String? { get }
    func useDatabase(_ name: String) async throws

    func databases() async throws -> [String]
    func tables(in database: String) async throws -> [TableInfo]
    func columns(of table: String, in database: String) async throws -> [ColumnDetail]
}
