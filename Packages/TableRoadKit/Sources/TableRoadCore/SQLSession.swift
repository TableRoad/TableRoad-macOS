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
    public var characterSet: String?
    public var collation: String?
    public var id: String { name }

    public init(
        name: String, type: String, isNullable: Bool, isPrimaryKey: Bool,
        defaultValue: String? = nil, extra: String? = nil, comment: String? = nil,
        characterSet: String? = nil, collation: String? = nil
    ) {
        self.name = name
        self.type = type
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
        self.extra = extra
        self.comment = comment
        self.characterSet = characterSet
        self.collation = collation
    }
}

/// Storage statistics and metadata for one table (`information_schema.TABLES`). Engine figures are estimates.
public struct TableStatus: Sendable, Hashable {
    public var estimatedRows: Int?
    public var dataBytes: Int?
    public var indexBytes: Int?
    public var freeBytes: Int?
    public var autoIncrement: Int?
    public var engine: String?
    public var collation: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var comment: String?

    public var totalBytes: Int? {
        guard dataBytes != nil || indexBytes != nil else { return nil }
        return (dataBytes ?? 0) + (indexBytes ?? 0)
    }

    public init(
        estimatedRows: Int? = nil, dataBytes: Int? = nil, indexBytes: Int? = nil, freeBytes: Int? = nil,
        autoIncrement: Int? = nil, engine: String? = nil, collation: String? = nil, createdAt: String? = nil,
        updatedAt: String? = nil, comment: String? = nil
    ) {
        self.estimatedRows = estimatedRows
        self.dataBytes = dataBytes
        self.indexBytes = indexBytes
        self.freeBytes = freeBytes
        self.autoIncrement = autoIncrement
        self.engine = engine
        self.collation = collation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.comment = comment
    }
}

/// One index (all its columns, in order).
public struct IndexDetail: Sendable, Hashable, Identifiable {
    public var name: String
    /// e.g. `BTREE`, `HASH`, `FULLTEXT`, `SPATIAL`.
    public var algorithm: String
    public var isUnique: Bool
    /// Column names in index order; prefix lengths as `name(10)`, functional parts as `(expression)`.
    public var columns: [String]
    public var cardinality: Int?
    public var comment: String?
    public var id: String { name }
    public var isPrimary: Bool { name == "PRIMARY" }

    public init(
        name: String, algorithm: String, isUnique: Bool, columns: [String], cardinality: Int? = nil,
        comment: String? = nil
    ) {
        self.name = name
        self.algorithm = algorithm
        self.isUnique = isUnique
        self.columns = columns
        self.cardinality = cardinality
        self.comment = comment
    }
}

/// A character set and its collations (for CREATE DATABASE).
public struct CharacterSetInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var defaultCollation: String?
    public var collations: [String]
    public var id: String { name }

    public init(name: String, defaultCollation: String? = nil, collations: [String] = []) {
        self.name = name
        self.defaultCollation = defaultCollation
        self.collations = collations
    }
}

/// A foreign key constraint from this table to another.
public struct ForeignKeyDetail: Sendable, Hashable, Identifiable {
    public var name: String
    public var columns: [String]
    public var referencedDatabase: String
    public var referencedTable: String
    public var referencedColumns: [String]
    public var onUpdate: String
    public var onDelete: String
    public var id: String { name }

    public init(
        name: String, columns: [String], referencedDatabase: String, referencedTable: String,
        referencedColumns: [String], onUpdate: String = "RESTRICT", onDelete: String = "RESTRICT"
    ) {
        self.name = name
        self.columns = columns
        self.referencedDatabase = referencedDatabase
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

extension ColumnDetail {
    /// Allowed values for `enum('a','b')` / `set(...)` columns, or nil for other types.
    public var choices: [String]? {
        let lower = type.lowercased()
        guard lower.hasPrefix("enum(") || lower.hasPrefix("set("), type.hasSuffix(")"),
            let open = type.firstIndex(of: "(")
        else { return nil }
        let body = type[type.index(after: open)..<type.index(before: type.endIndex)]
        var values: [String] = []
        var current = ""
        var inQuote = false
        var iterator = body.makeIterator()
        var pending: Character? = nil
        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuote {
                if character == "'" {
                    if let next = iterator.next(), next == "'" {
                        current.append("'")  // doubled quote inside a value
                    } else {
                        inQuote = false
                        values.append(current)
                        current = ""
                        continue
                    }
                } else {
                    current.append(character)
                }
            } else if character == "'" {
                inQuote = true
            }
        }
        return values
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
    /// Size and row estimate. Cheap: never scans the table.
    func tableStatus(of table: String, in database: String) async throws -> TableStatus
    func indexes(of table: String, in database: String) async throws -> [IndexDetail]
    func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail]
    /// The table's (or view's) CREATE statement.
    func createStatement(of table: String, in database: String) async throws -> String
}

/// A value bound to a `?` placeholder. Text is coerced by the server to the column's type.
public enum SQLParameter: Sendable, Hashable {
    case text(String)
    case null
}

/// A statement with `?` placeholders and its bound values.
public struct ParameterizedStatement: Sendable, Hashable {
    public var sql: String
    public var parameters: [SQLParameter]

    public init(sql: String, parameters: [SQLParameter] = []) {
        self.sql = sql
        self.parameters = parameters
    }
}

/// Raised when a transaction fails; says which statement failed so the UI can point at it.
public struct TransactionError: Error, LocalizedError, Sendable {
    /// Index of the failing statement; equals the statement count when COMMIT itself failed.
    public var statementIndex: Int
    public var underlying: DatabaseError
    /// The connection dropped during COMMIT, so the server may or may not have applied the changes.
    public var commitOutcomeUnknown: Bool

    public init(statementIndex: Int, underlying: DatabaseError, commitOutcomeUnknown: Bool = false) {
        self.statementIndex = statementIndex
        self.underlying = underlying
        self.commitOutcomeUnknown = commitOutcomeUnknown
    }

    public var errorDescription: String? {
        if commitOutcomeUnknown {
            return "The connection dropped while saving, so it's unknown whether the server applied your changes. "
                + "Reload the table to check before trying again."
        }
        return "Change \(statementIndex + 1) failed, so nothing was saved: \(underlying.localizedDescription)"
    }

    /// Whether the failure was the connection going away (the session should reconnect).
    public var isConnectionLoss: Bool { underlying.category == .connection }
}

/// Sessions that can apply edits atomically.
public protocol TransactionalSession: SQLSession {
    /// Runs all statements in one transaction (rolled back on any failure) and returns rows affected per statement.
    /// No other statement on the session can interleave.
    func executeTransaction(_ statements: [ParameterizedStatement]) async throws -> [UInt64]
}

/// A connection on the server, as listed by `SHOW FULL PROCESSLIST`.
public struct ServerProcess: Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var user: String
    public var host: String
    public var database: String?
    /// e.g. `Query`, `Sleep`, `Binlog Dump`.
    public var command: String
    /// Seconds in the current state.
    public var seconds: Int
    public var state: String?
    /// Full SQL text of the running statement, if any.
    public var info: String?

    public init(
        id: UInt64, user: String, host: String, database: String?, command: String, seconds: Int, state: String?,
        info: String?
    ) {
        self.id = id
        self.user = user
        self.host = host
        self.database = database
        self.command = command
        self.seconds = seconds
        self.state = state
        self.info = info
    }

    /// Idle connections waiting for a client.
    public var isIdle: Bool { command == "Sleep" }
}

/// Sessions that can list and kill server processes.
public protocol ProcessAdminSession: SQLSession {
    /// This session's own server-side id (so the UI can mark and protect it).
    var processID: UInt64 { get }
    func processList() async throws -> [ServerProcess]
    /// `KILL QUERY id` (statement only) or `KILL id` (whole connection).
    func kill(processID: UInt64, connection: Bool) async throws
}
