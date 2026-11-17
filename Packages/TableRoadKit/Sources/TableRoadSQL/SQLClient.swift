import Foundation
import TableRoadCore

/// Everything the workspace needs from a SQL engine's connection. Each driver (MySQL/MariaDB, PostgreSQL, SQLite…)
/// implements it, so the app never depends on a concrete driver.
public protocol SQLClient: TransactionalSession, ProcessAdminSession {
    /// SQL spelling for this engine (and server settings like MySQL's sql_mode).
    nonisolated var sqlDialect: any SQLDialect { get }
    nonisolated var processID: UInt64 { get }
    nonisolated var isEncrypted: Bool { get }
    nonisolated var tlsCipher: String? { get }
    nonisolated var capabilities: ClientCapabilities { get }

    /// Runs a statement and discards any result (bulk work such as importing a dump).
    func run(_ sql: String) async throws

    func tableStatus(of table: String, in database: String) async throws -> TableStatus
    func indexes(of table: String, in database: String) async throws -> [IndexDetail]
    func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail]
    /// The table's (or view's) CREATE statement.
    func createStatement(of table: String, in database: String) async throws -> String
    /// Character sets for CREATE DATABASE (empty when the engine has none).
    func characterSets() async throws -> [CharacterSetInfo]
}

/// What a connection can do (the UI hides what isn't supported).
public struct ClientCapabilities: Sendable, Hashable {
    /// Server process list and KILL.
    public var processList: Bool
    /// CREATE / DROP DATABASE (MySQL databases, PostgreSQL schemas). SQLite: no.
    public var createDatabases: Bool
    /// What the UI calls a "database" (PostgreSQL lists schemas).
    public var databaseNoun: String
    /// Cancel a running statement from another connection.
    public var cancel: Bool

    public init(processList: Bool, createDatabases: Bool, databaseNoun: String = "database", cancel: Bool = true) {
        self.processList = processList
        self.createDatabases = createDatabases
        self.databaseNoun = databaseNoun
        self.cancel = cancel
    }
}
