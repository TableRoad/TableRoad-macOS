import Foundation
import TableRoadCore

/// Text formats for copying or exporting result rows ("Copy Rows As", "Export current page…").
public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case tsv = "TSV"
    case csv = "CSV"
    case json = "JSON"
    case markdown = "Markdown"
    case sqlInsert = "SQL INSERT"

    public var id: Self { self }

    public var fileExtension: String {
        switch self {
        case .tsv: "tsv"
        case .csv: "csv"
        case .json: "json"
        case .markdown: "md"
        case .sqlInsert: "sql"
        }
    }
}

public struct ResultExporter: Sendable {
    public var columns: [String]
    public var rows: [[CellValue]]
    /// Target of SQL INSERT statements (defaults to `table_name` when unknown, e.g. query results).
    public var table: String?
    public var dialect: any SQLDialect

    public init(columns: [String], rows: [[CellValue]], table: String? = nil, dialect: any SQLDialect) {
        self.columns = columns
        self.rows = rows
        self.table = table
        self.dialect = dialect
    }

    public func render(_ format: ExportFormat, includeHeader: Bool = true) -> String {
        switch format {
        case .tsv: delimited(separator: "\t", includeHeader: includeHeader, quote: tsvField)
        case .csv: delimited(separator: ",", includeHeader: includeHeader, quote: csvField)
        case .json: json()
        case .markdown: markdown()
        case .sqlInsert: sqlInsert()
        }
    }

    // MARK: Formats

    private func delimited(separator: String, includeHeader: Bool, quote: (String) -> String) -> String {
        var lines: [String] = []
        if includeHeader { lines.append(columns.map(quote).joined(separator: separator)) }
        for row in rows {
            lines.append(row.map { $0.displayText.map(quote) ?? "NULL" }.joined(separator: separator))
        }
        return lines.joined(separator: "\n")
    }

    /// TSV can't quote, so tabs and line breaks become spaces (as most tools expect).
    private func tsvField(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// RFC 4180: quote when needed, doubling quotes.
    private func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func json() -> String {
        let objects: [[String: Any]] = rows.map { row in
            var object: [String: Any] = [:]
            for (index, name) in columns.enumerated() where index < row.count {
                object[name] = jsonValue(row[index])
            }
            return object
        }
        // Keys in column order would need a custom encoder; sorted keys at least make output stable.
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    private func jsonValue(_ value: CellValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let flag): flag
        case .int(let number): number
        case .uint(let number): number
        case .double(let number): number.isFinite ? number : (value.displayText ?? "")
        case .bytes(let data): data.base64EncodedString()
        default: value.displayText ?? ""
        }
    }

    private func markdown() -> String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
        }
        var lines = [
            "| " + columns.map(cell).joined(separator: " | ") + " |",
            "|" + columns.map { _ in " --- " }.joined(separator: "|") + "|",
        ]
        for row in rows {
            lines.append("| " + row.map { $0.displayText.map(cell) ?? "NULL" }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private func sqlInsert() -> String {
        let target = dialect.quoteIdentifier(table ?? "table_name")
        let names = columns.map(dialect.quoteIdentifier).joined(separator: ", ")
        return rows.map { row in
            "INSERT INTO \(target) (\(names)) VALUES (" + row.map(sqlLiteral).joined(separator: ", ") + ");"
        }.joined(separator: "\n")
    }

    /// The value as a SQL literal: numbers bare, bytes as hex, everything else as an escaped string.
    public func sqlLiteral(_ value: CellValue) -> String {
        switch value {
        case .null: "NULL"
        case .bool(let flag): dialect.booleanLiteral(flag)
        case .int, .uint, .decimal: value.displayText ?? "NULL"
        case .double(let number): number.isFinite ? String(number) : "NULL"
        case .bytes(let data): dialect.bytesLiteral(data)
        default: dialect.stringLiteral(value.displayText ?? "")
        }
    }
}
