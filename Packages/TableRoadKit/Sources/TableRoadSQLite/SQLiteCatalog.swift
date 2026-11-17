import Foundation
import TableRoadCore
import TableRoadSQL

/// SQLite's catalog (PRAGMAs and sqlite_master), shared by local files and LibSQL/Turso over HTTP.
struct SQLiteCatalog: Sendable {
    /// Runs a statement and returns every value as text.
    let textRows: @Sendable (String) async throws -> [[String?]]

    func databases() async throws -> [String] {
        try await textRows("PRAGMA database_list").compactMap { $0.count > 1 ? $0[1] : nil }
    }

    func tables(in database: String) async throws -> [TableInfo] {
        let q = SQLiteDialect()
        let rows = try await textRows(
            "SELECT name, type FROM \(q.quoteIdentifier(database)).sqlite_master "
                + "WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name")
        return rows.map { TableInfo(name: $0[0] ?? "", kind: $0[1] == "view" ? .view : .table) }
    }

    func columns(of table: String, in database: String) async throws -> [ColumnDetail] {
        let q = SQLiteDialect()
        // table_xinfo includes generated columns (hidden 2/3).
        let rows = try await textRows(
            "PRAGMA \(q.quoteIdentifier(database)).table_xinfo(\(q.stringLiteral(table)))")
        return rows.compactMap { row in
            guard row.count >= 7, let name = row[1] else { return nil }
            let hidden = Int(row[6] ?? "0") ?? 0
            guard hidden != 1 else { return nil }  // hidden virtual-table columns
            return ColumnDetail(
                name: name, type: (row[2] ?? "").lowercased(), isNullable: row[3] == "0",
                isPrimaryKey: (Int(row[5] ?? "0") ?? 0) > 0, defaultValue: row[4],
                extra: hidden >= 2 ? (hidden == 2 ? "VIRTUAL GENERATED" : "STORED GENERATED") : nil)
        }
    }

    func tableStatus(of table: String, in database: String) async throws -> TableStatus {
        // SQLite keeps no row estimate; the page count gives the file size.
        let pages = try await textRows("PRAGMA page_count").first.flatMap { $0.first ?? nil }.flatMap { Int($0) }
        let size = try await textRows("PRAGMA page_size").first.flatMap { $0.first ?? nil }.flatMap { Int($0) }
        let sql =
            try await textRows(
                "SELECT sql FROM \(SQLiteDialect().quoteIdentifier(database)).sqlite_master WHERE name = "
                    + SQLiteDialect().stringLiteral(table)
            ).first?.first ?? nil
        guard sql != nil else { throw DatabaseError(.query, "Table \(table) not found.") }
        return TableStatus(
            dataBytes: nil, indexBytes: nil, freeBytes: nil, engine: "SQLite",
            comment: pages.flatMap { pages in size.map { "Database file: \(pages * $0) bytes" } })
    }

    func indexes(of table: String, in database: String) async throws -> [IndexDetail] {
        let q = SQLiteDialect()
        var result: [IndexDetail] = []
        let primary = try await columns(of: table, in: database).filter(\.isPrimaryKey).map(\.name)
        if !primary.isEmpty {
            result.append(IndexDetail(name: "PRIMARY", algorithm: "BTREE", isUnique: true, columns: primary))
        }
        for row in try await textRows("PRAGMA \(q.quoteIdentifier(database)).index_list(\(q.stringLiteral(table)))") {
            guard row.count >= 4, let name = row[1], row[3] != "pk" else { continue }
            let columns = try await textRows(
                "PRAGMA \(q.quoteIdentifier(database)).index_info(\(q.stringLiteral(name)))"
            )
            .map { $0.count > 2 ? ($0[2] ?? "(expression)") : "?" }
            result.append(IndexDetail(name: name, algorithm: "BTREE", isUnique: row[2] == "1", columns: columns))
        }
        return result
    }

    func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail] {
        let q = SQLiteDialect()
        var keys: [String: ForeignKeyDetail] = [:]
        var order: [String] = []
        for row in try await textRows(
            "PRAGMA \(q.quoteIdentifier(database)).foreign_key_list(\(q.stringLiteral(table)))")
        where row.count >= 7 {
            let id = row[0] ?? "0"
            if keys[id] == nil {
                order.append(id)
                keys[id] = ForeignKeyDetail(
                    name: "fk_\(table)_\(id)", columns: [], referencedDatabase: database,
                    referencedTable: row[2] ?? "", referencedColumns: [], onUpdate: row[5] ?? "NO ACTION",
                    onDelete: row[6] ?? "NO ACTION")
            }
            keys[id]?.columns.append(row[3] ?? "")
            keys[id]?.referencedColumns.append(row[4] ?? "")
        }
        return order.compactMap { keys[$0] }
    }

    func createStatement(of table: String, in database: String) async throws -> String {
        let q = SQLiteDialect()
        let rows = try await textRows(
            "SELECT sql FROM \(q.quoteIdentifier(database)).sqlite_master WHERE name = \(q.stringLiteral(table))")
        guard let sql = rows.first?.first ?? nil else {
            throw DatabaseError(.query, "No CREATE statement for \(table).")
        }
        return sql
    }

}
