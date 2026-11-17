import Foundation
import TableRoadCore
import TableRoadSQL

/// PostgreSQL spelling (also Redshift, CockroachDB, Greenplum). TableRoad's "databases" are schemas here.
public struct PostgresDialect: SQLDialect {
    public var family: SQLFamily { .postgres }
    public init() {}

    public func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// standard_conforming_strings is on (the default since 9.1): only quotes need doubling.
    public func stringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public func placeholder(_ index: Int) -> String { "$\(index)" }

    public func bytesLiteral(_ data: Data) -> String {
        "'\\x" + data.map { String(format: "%02x", $0) }.joined() + "'::bytea"
    }

    /// The schema list is what the database picker shows, so "databases" are created as schemas.
    public func createDatabaseSQL(_ name: String, characterSet: String?, collation: String?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw DDLError.emptyName }
        guard trimmed.utf8.count <= 63 else { throw DDLError.nameTooLong }
        return "CREATE SCHEMA \(quoteIdentifier(trimmed))"
    }

    /// Like dropping a MySQL database: everything in the schema goes.
    public func dropDatabaseSQL(_ name: String) -> String { "DROP SCHEMA \(quoteIdentifier(name)) CASCADE" }

    public func useDatabaseSQL(_ name: String) -> String? { "SET search_path TO \(quoteIdentifier(name))" }

    public var dumpPreamble: [String] {
        ["SET client_encoding = 'UTF8'", "SET standard_conforming_strings = on", "SET TIME ZONE 'UTC'"]
    }

    public var exportSessionSetup: [String] { ["SET TIME ZONE 'UTC'"] }

    /// LIKE on numbers or dates needs a text cast in PostgreSQL.
    public func likeOperand(_ quotedColumn: String) -> String { "\(quotedColumn)::text" }

    /// After loading rows into a serial column, move its sequence past the largest value.
    public func resetSequenceSQL(table: String, column: String) -> String? {
        "SELECT setval(pg_get_serial_sequence(\(stringLiteral(quoteIdentifier(table))), \(stringLiteral(column))), "
            + "COALESCE(MAX(\(quoteIdentifier(column))), 1)) FROM \(quoteIdentifier(table))"
    }
}
