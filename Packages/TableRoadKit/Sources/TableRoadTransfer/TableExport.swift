import Foundation
import TableRoadCore
import TableRoadMySQL
import TableRoadSQL

/// One table (or view) to export, with what to include.
public struct ExportItem: Sendable, Hashable, Identifiable {
    public var database: String
    public var table: String
    public var isView: Bool
    /// SQL only: CREATE statement, DROP … IF EXISTS, and rows. Other formats only use `data`.
    public var structure: Bool
    public var drop: Bool
    public var data: Bool
    /// Columns to export, in table order; nil = all.
    public var columns: [String]?

    public var id: String { database + "." + table }

    public init(
        database: String, table: String, isView: Bool = false, structure: Bool = true, drop: Bool = true,
        data: Bool = true, columns: [String]? = nil
    ) {
        self.database = database
        self.table = table
        self.isView = isView
        self.structure = structure
        self.drop = drop
        self.data = data
        self.columns = columns
    }
}

public enum ExportKind: Sendable, Hashable {
    case csv(CSVOptions)
    case json
    case sql(gzip: Bool)
    case excel

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .json: "json"
        case .sql(let gzip): gzip ? "sql.gz" : "sql"
        case .excel: "xlsx"
        }
    }

    /// CSV and JSON write one file per table, so several tables go into a folder.
    public func writesFolder(itemCount: Int) -> Bool {
        switch self {
        case .csv, .json: itemCount > 1
        case .sql, .excel: false
        }
    }
}

public struct ExportProgress: Sendable, Hashable {
    public var item: String
    public var itemIndex: Int
    public var itemCount: Int
    public var rows: Int
    public var estimatedRows: Int?

    public init(item: String, itemIndex: Int, itemCount: Int, rows: Int, estimatedRows: Int? = nil) {
        self.item = item
        self.itemIndex = itemIndex
        self.itemCount = itemCount
        self.rows = rows
        self.estimatedRows = estimatedRows
    }
}

public struct ExportResult: Sendable, Hashable {
    public var files: [URL]
    public var rows: Int
}

public enum TableExport {
    public static let batchSize = 2_000

    /// Exports `items` to `destination` (a file, or a folder when `kind.writesFolder`), streaming rows in batches on
    /// a connection of its own. Cancel the task to stop; partial files are left for the caller to remove.
    public static func run(
        items: [ExportItem], kind: ExportKind, destination: URL,
        connect: @Sendable () async throws -> any SQLClient,
        progress: @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws -> ExportResult {
        let session = try await connect()
        defer { Task { await session.close() } }
        // Tables before views (views may select from them), each database's items together.
        let ordered = items.sorted { ($0.database, $0.isView ? 1 : 0) < ($1.database, $1.isView ? 1 : 0) }
        let databases = Array(Set(ordered.map(\.database))).sorted()
        let qualify = databases.count > 1
        var total = 0

        func report(_ index: Int, _ item: ExportItem, _ rows: Int, _ estimate: Int?) {
            progress(
                ExportProgress(
                    item: item.table, itemIndex: index, itemCount: ordered.count, rows: rows, estimatedRows: estimate))
        }

        switch kind {
        case .sql(let gzip):
            let format = SQLDumpFormat(dialect: session.sqlDialect)
            for statement in session.sqlDialect.exportSessionSetup { try await session.run(statement) }
            let sink = try FileSink(url: destination, gzip: gzip)
            try sink.write(format.header(server: await session.serverVersion, databases: databases))
            var currentDatabase: String?
            for (index, item) in ordered.enumerated() {
                try Task.checkCancellation()
                if qualify && item.database != currentDatabase {
                    try sink.write(format.use(item.database))
                    currentDatabase = item.database
                }
                if item.drop || item.structure {
                    try sink.write(format.comment("\(item.isView ? "View" : "Table") structure for `\(item.table)`"))
                }
                if item.drop { try sink.write(format.drop(item.table, isView: item.isView)) }
                if item.structure {
                    let ddl = try await session.createStatement(of: item.table, in: item.database)
                    try sink.write(format.create(ddl, isView: item.isView))
                }
                // A view's rows come from its tables; inserting them into the view would fail.
                guard item.data && !item.isView else { continue }
                var reader = try await TableReader(session: session, item: item, excludeGenerated: true)
                try sink.write(format.comment("Data for `\(item.table)`"))
                report(index, item, 0, reader.estimatedRows)
                var rows = 0
                while let batch = try await reader.next() {
                    try Task.checkCancellation()
                    try sink.write(format.inserts(table: item.table, columns: reader.columnNames, rows: batch))
                    rows += batch.count
                    report(index, item, rows, reader.estimatedRows)
                }
                try sink.write("\n")
                total += rows
            }
            try sink.write(format.footer)
            try sink.close()
            return ExportResult(files: [destination], rows: total)

        case .excel:
            let writer = try XLSXWriter(url: destination)
            for (index, item) in ordered.enumerated() where item.data {
                try Task.checkCancellation()
                var reader = try await TableReader(session: session, item: item, excludeGenerated: false)
                try writer.beginSheet(
                    qualify ? "\(item.database).\(item.table)" : item.table, header: reader.columnNames)
                report(index, item, 0, reader.estimatedRows)
                var rows = 0
                while let batch = try await reader.next() {
                    try Task.checkCancellation()
                    for row in batch { try writer.addRow(row) }
                    rows += batch.count
                    report(index, item, rows, reader.estimatedRows)
                }
                try writer.endSheet()
                total += rows
            }
            try writer.finish()
            return ExportResult(files: [destination], rows: total)

        case .csv, .json:
            let folder = kind.writesFolder(itemCount: ordered.count)
            if folder { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
            var files: [URL] = []
            for (index, item) in ordered.enumerated() where item.data {
                try Task.checkCancellation()
                let name = (qualify ? "\(item.database).\(item.table)" : item.table) + "." + kind.fileExtension
                let url = folder ? destination.appending(path: safeFileName(name)) : destination
                let sink = try FileSink(url: url)
                var reader = try await TableReader(session: session, item: item, excludeGenerated: false)
                report(index, item, 0, reader.estimatedRows)
                var rows = 0
                if case .csv(let options) = kind {
                    if options.header {
                        try sink.write(options.headerLine(reader.columnNames) + options.lineBreak)
                    }
                    while let batch = try await reader.next() {
                        try Task.checkCancellation()
                        try sink.write(batch.map { options.line($0) + options.lineBreak }.joined())
                        rows += batch.count
                        report(index, item, rows, reader.estimatedRows)
                    }
                } else {
                    try sink.write("[")
                    while let batch = try await reader.next() {
                        try Task.checkCancellation()
                        let elements = batch.map { JSONRows.element(columns: reader.columnNames, values: $0) }
                        try sink.write((rows == 0 ? "\n" : ",\n") + elements.joined(separator: ",\n"))
                        rows += batch.count
                        report(index, item, rows, reader.estimatedRows)
                    }
                    try sink.write(rows == 0 ? "]\n" : "\n]\n")
                }
                try sink.close()
                files.append(url)
                total += rows
            }
            return ExportResult(files: files, rows: total)
        }
    }

    static func safeFileName(_ name: String) -> String {
        String(name.map { "/:\\".contains($0) ? "_" : $0 })
    }
}

/// Reads a table in batches: by primary key (`WHERE (pk) > (last) ORDER BY pk LIMIT n`) so every batch is an
/// index range scan, or by LIMIT/OFFSET when there's no key (views, keyless tables).
struct TableReader {
    let session: any SQLClient
    let item: ExportItem
    /// Exported columns, in table order.
    let columnNames: [String]
    let estimatedRows: Int?
    private let selectList: [String]
    private let keyIndexes: [Int]
    private var lastKey: [CellValue]?
    private var offset = 0
    private var done = false
    private let literal: ResultExporter

    init(session: any SQLClient, item: ExportItem, excludeGenerated: Bool) async throws {
        self.session = session
        self.item = item
        let details = try await session.columns(of: item.table, in: item.database)
        var chosen = details.filter { column in
            (item.columns?.contains(column.name) ?? true)
                && !(excludeGenerated && Self.isGenerated(column))
        }
        if chosen.isEmpty { chosen = details }
        let names = chosen.map(\.name)
        let key = item.isView ? [] : details.filter(\.isPrimaryKey).map(\.name)
        // Key columns are fetched even when not exported, to page by them.
        let select = names + key.filter { !names.contains($0) }
        columnNames = names
        selectList = select
        keyIndexes = key.compactMap { select.firstIndex(of: $0) }
        estimatedRows = try? await session.tableStatus(of: item.table, in: item.database).estimatedRows
        literal = ResultExporter(columns: [], rows: [], dialect: session.sqlDialect)
    }

    /// Generated columns can't be inserted into. Not MySQL 8's `DEFAULT_GENERATED` (a DEFAULT CURRENT_TIMESTAMP).
    static func isGenerated(_ column: ColumnDetail) -> Bool {
        (column.extra ?? "").range(
            of: #"\b(VIRTUAL|STORED|PERSISTENT) GENERATED\b"#, options: [.regularExpression, .caseInsensitive])
            != nil
    }

    /// The next batch (only the exported columns), or nil when finished.
    mutating func next() async throws -> [[CellValue]]? {
        guard !done else { return nil }
        let dialect = session.sqlDialect
        let keys = keyIndexes.map { selectList[$0] }.map(dialect.quoteIdentifier)
        var sql =
            "SELECT " + selectList.map(dialect.quoteIdentifier).joined(separator: ", ") + " FROM "
            + dialect.qualified(item.database, item.table)
        if keys.isEmpty {
            sql += " LIMIT \(TableExport.batchSize) OFFSET \(offset)"
        } else {
            if let lastKey {
                let values = lastKey.map(literal.sqlLiteral)
                sql +=
                    keys.count == 1
                    ? " WHERE \(keys[0]) > \(values[0])"
                    : " WHERE (\(keys.joined(separator: ", "))) > (\(values.joined(separator: ", ")))"
            }
            sql += " ORDER BY \(keys.joined(separator: ", ")) LIMIT \(TableExport.batchSize)"
        }
        guard case .rows(let result) = try await session.execute(sql) else { return nil }
        let rows = result.rows
        if rows.count < TableExport.batchSize { done = true }
        if rows.isEmpty { return nil }
        offset += rows.count
        if let last = rows.last { lastKey = keyIndexes.map { last[$0] } }
        let width = columnNames.count
        return width == selectList.count ? rows : rows.map { Array($0.prefix(width)) }
    }
}
