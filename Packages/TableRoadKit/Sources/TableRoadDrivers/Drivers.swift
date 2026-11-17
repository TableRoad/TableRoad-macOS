import Foundation
import TableRoadCore
import TableRoadMySQL
import TableRoadPostgres
import TableRoadSQL
import TableRoadSQLite

/// Picks the driver for a connection's engine. The app only talks to `any SQLClient`.
public enum Drivers {
    /// Engines with a working driver in this build.
    public static func isAvailable(_ kind: DatabaseKind) -> Bool {
        switch kind.family {
        case .mysql, .sqlite, .postgres: true
        default: false
        }
    }

    /// How scripts are split into statements for an engine.
    public static func statementSyntax(_ kind: DatabaseKind) -> StatementSplitter.Syntax {
        kind.family == .mysql ? .mysql : .postgres
    }

    /// Opens a connection for a saved profile.
    public static func connect(_ profile: ConnectionProfile, password: String?) async throws -> any SQLClient {
        guard profile.ssh == nil else {
            throw DatabaseError(
                .unsupported,
                "Connecting over SSH arrives in Phase 3. The SSH settings are saved and will be used then.")
        }
        switch profile.kind.family {
        case .mysql:
            return try await MySQLSession.connect(MySQLConnectConfig(profile: profile, password: password))
        case .postgres:
            return try await PostgresSession.connect(PostgresConnectConfig(profile: profile, password: password))
        case .sqlite:
            // File-based: the path is kept in `host`. Read-only connections open the file read-only.
            return try await SQLiteSession.open(path: profile.host, readOnly: profile.safeMode == .readOnly)
        default:
            throw DatabaseError(.unsupported, "\(profile.kind.displayName) isn't supported yet.")
        }
    }
}
