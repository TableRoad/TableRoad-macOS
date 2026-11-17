import Foundation
import TableRoadCore
import TableRoadSQL

public enum TransferError: Error, Equatable, CustomStringConvertible {
    case fileTooLarge
    case excelRowLimit(String)
    case cancelled
    case statementTooLarge
    case notUTF8

    public var description: String {
        switch self {
        case .fileTooLarge: "The Excel file would be over 4 GB, which this exporter can't write. Use CSV instead."
        case .excelRowLimit(let sheet):
            "“\(sheet)” has more than 1,048,576 rows, Excel's limit for a sheet. Use CSV for this table."
        case .cancelled: "Cancelled."
        case .statementTooLarge: "A statement in the file is larger than 512 MB, so it can't be imported."
        case .notUTF8: "The file isn't UTF-8 text."
        }
    }
}

/// CSV options, as in TablePlus's export sheet.
public struct CSVOptions: Sendable, Hashable, Codable {
    public enum Quoting: String, Sendable, Hashable, Codable, CaseIterable {
        case ifNeeded = "Quote if needed"
        case always = "Always quote"
        case never = "Never quote"
    }

    public var nullAsEmpty = true
    public var lineBreaksToSpace = false
    public var header = true
    public var delimiter = ","
    public var quoting = Quoting.ifNeeded
    public var lineBreak = "\n"
    public var decimalSeparator = "."

    public init() {}

    /// One CSV line (without the line break).
    public func line(_ values: [CellValue]) -> String {
        values.map(field).joined(separator: delimiter)
    }

    public func headerLine(_ names: [String]) -> String {
        names.map { quote($0) }.joined(separator: delimiter)
    }

    func field(_ value: CellValue) -> String {
        guard var text = value.displayText else { return nullAsEmpty ? "" : "NULL" }
        if decimalSeparator != ".", value.isNumeric {
            text = text.replacingOccurrences(of: ".", with: decimalSeparator)
        }
        if lineBreaksToSpace {
            text = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        return quote(text)
    }

    func quote(_ text: String) -> String {
        switch quoting {
        case .never: return text
        case .always: return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .ifNeeded:
            let needs =
                text.contains(delimiter) || text.contains(where: { $0 == "\"" || $0 == "\n" || $0 == "\r" })
            return needs ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
    }
}

/// JSON row objects with keys in column order; JSON columns are embedded as JSON, binary as base64.
enum JSONRows {
    static func object(columns: [String], values: [CellValue]) -> JSONValue {
        .object(
            zip(columns, values).map { name, value in
                JSONValue.Member(key: name, value: json(value))
            })
    }

    static func json(_ value: CellValue) -> JSONValue {
        switch value {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .int, .uint, .decimal: .number(value.displayText ?? "0")
        case .double(let number): number.isFinite ? .number(String(number)) : .string(String(number))
        case .json(let text): (try? JSONValue.parse(text)) ?? .string(text)
        case .bytes(let data): .string(data.base64EncodedString())
        default: .string(value.displayText ?? "")
        }
    }

    /// An array element: the object pretty-printed with 2 spaces, indented one level.
    static func element(columns: [String], values: [CellValue]) -> String {
        "  " + object(columns: columns, values: values).pretty(indent: 2).replacingOccurrences(of: "\n", with: "\n  ")
    }
}

/// mysqldump-style SQL: header/footer settings, DROP/CREATE, and multi-row INSERTs, in the engine's dialect.
public struct SQLDumpFormat: Sendable {
    let dialect: any SQLDialect
    let literal: ResultExporter
    /// Rows per INSERT, and a size cap so statements stay well under max_allowed_packet.
    public var rowsPerInsert = 200
    public var bytesPerInsert = 512 * 1024

    /// MySQL literals always use backslash escapes: the dump sets a SQL_MODE without NO_BACKSLASH_ESCAPES.
    public init(dialect: any SQLDialect) {
        if let mysql = dialect as? MySQLDialect {
            self.dialect = MySQLDialect(flavor: mysql.flavor, backslashEscapes: true)
        } else {
            self.dialect = dialect
        }
        literal = ResultExporter(columns: [], rows: [], dialect: self.dialect)
    }

    public init(flavor: MySQLDialect.Flavor) {
        self.init(dialect: MySQLDialect(flavor: flavor))
    }

    public func header(server: String, databases: [String], date: Date = .now) -> String {
        var text = """
            -- TableRoad SQL dump
            -- Server: \(server)
            -- Database: \(databases.joined(separator: ", "))
            -- Generated: \(date.formatted(.iso8601))


            """
        text += dialect.dumpPreamble.map { $0 + ";\n" }.joined()
        return text + "\n\n"
    }

    public var footer: String {
        "\n" + dialect.dumpPostamble.map { $0 + ";\n" }.joined()
    }

    public func use(_ database: String) -> String {
        dialect.useDatabaseSQL(database).map { $0 + ";\n\n" } ?? ""
    }

    public func drop(_ table: String, isView: Bool) -> String {
        "DROP \(isView ? "VIEW" : "TABLE") IF EXISTS \(dialect.quoteIdentifier(table));\n"
    }

    /// CREATE statement with `DEFINER=…` removed from views (it often names a user the target server lacks).
    public func create(_ ddl: String, isView: Bool) -> String {
        var statement = ddl
        if isView, let range = statement.range(of: #"DEFINER=\S+\s+"#, options: .regularExpression) {
            statement.removeSubrange(range)
        }
        return statement + ";\n\n"
    }

    public func comment(_ text: String) -> String {
        "--\n-- \(text)\n--\n\n"
    }

    /// INSERT statements for a batch of rows (several statements if the batch is large).
    public func inserts(table: String, columns: [String], rows: [[CellValue]]) -> String {
        guard !rows.isEmpty else { return "" }
        let prefix =
            "INSERT INTO \(dialect.quoteIdentifier(table)) ("
            + columns.map(dialect.quoteIdentifier).joined(separator: ", ") + ") VALUES\n"
        var output = ""
        var tuples: [String] = []
        var size = 0
        func flush() {
            guard !tuples.isEmpty else { return }
            output += prefix + tuples.joined(separator: ",\n") + ";\n"
            tuples.removeAll()
            size = 0
        }
        for row in rows {
            let tuple = "(" + row.map(literal.sqlLiteral).joined(separator: ", ") + ")"
            tuples.append(tuple)
            size += tuple.utf8.count
            if tuples.count >= rowsPerInsert || size >= bytesPerInsert { flush() }
        }
        flush()
        return output
    }
}
