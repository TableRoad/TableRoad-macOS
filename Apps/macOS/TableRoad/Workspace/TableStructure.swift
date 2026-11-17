import TableRoadCore

/// A table's definition, as shown in the Structure / Indexes / DDL panes.
struct TableStructure: Hashable {
    var columns: [ColumnDetail]
    var indexes: [IndexDetail]
    var foreignKeys: [ForeignKeyDetail]
    var ddl: String

    var primaryKey: [String] { columns.filter(\.isPrimaryKey).map(\.name) }

    /// "customers(id)" for a column that's part of a foreign key.
    func reference(for column: String, in database: String) -> String? {
        for key in foreignKeys {
            guard let position = key.columns.firstIndex(of: column), position < key.referencedColumns.count else {
                continue
            }
            let table =
                key.referencedDatabase == database || key.referencedDatabase.isEmpty
                ? key.referencedTable : "\(key.referencedDatabase).\(key.referencedTable)"
            return "\(table)(\(key.referencedColumns[position]))"
        }
        return nil
    }

    /// Structure as grid rows (read-only).
    func columnsResult(database: String, matching search: String) -> ResultSet {
        let names = [
            "column_name", "data_type", "character_set", "collation", "is_nullable", "default", "extra",
            "foreign_key", "comment",
        ]
        // No "#" column: the grid's row numbers already give the position (search keeps the original order).
        let rows = columns.compactMap { column -> [CellValue]? in
            guard search.isEmpty || column.name.localizedCaseInsensitiveContains(search) else { return nil }
            return [
                .text(column.name), .text(column.type), text(column.characterSet),
                text(column.collation), .text(column.isNullable ? "YES" : "NO"), text(column.defaultValue),
                text(column.extra), text(reference(for: column.name, in: database)), text(column.comment),
            ]
        }
        return ResultSet(
            columns: names.map { ResultColumn(name: $0, typeName: "TEXT") }, rows: rows)
    }

    func indexesResult(matching search: String) -> ResultSet {
        let names = ["index_name", "algorithm", "is_unique", "column_name", "cardinality", "comment"]
        let rows = indexes.compactMap { index -> [CellValue]? in
            guard
                search.isEmpty || index.name.localizedCaseInsensitiveContains(search)
                    || index.columns.contains(where: { $0.localizedCaseInsensitiveContains(search) })
            else { return nil }
            return [
                .text(index.name), .text(index.algorithm), .text(index.isUnique ? "TRUE" : "FALSE"),
                .text(index.columns.joined(separator: ", ")), index.cardinality.map { .int(Int64($0)) } ?? .null,
                text(index.comment),
            ]
        }
        return ResultSet(
            columns: names.map { ResultColumn(name: $0, typeName: $0 == "cardinality" ? "BIGINT" : "TEXT") },
            rows: rows)
    }

    func foreignKeysResult(database: String) -> ResultSet {
        let names = ["constraint_name", "column_name", "references", "on_update", "on_delete"]
        let rows: [[CellValue]] = foreignKeys.map { key in
            let table =
                key.referencedDatabase == database
                ? key.referencedTable : "\(key.referencedDatabase).\(key.referencedTable)"
            return [
                .text(key.name), .text(key.columns.joined(separator: ", ")),
                .text("\(table)(\(key.referencedColumns.joined(separator: ", ")))"), .text(key.onUpdate),
                .text(key.onDelete),
            ]
        }
        return ResultSet(columns: names.map { ResultColumn(name: $0, typeName: "TEXT") }, rows: rows)
    }

    private func text(_ value: String?) -> CellValue { value.map { .text($0) } ?? .null }
}
