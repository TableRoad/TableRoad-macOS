import Foundation
import MySQLNIO
import NIOCore
import TableRoadCore

/// Decodes text-protocol values into `CellValue`s. The text protocol is used for all reads because
/// mysql-nio's binary protocol can't decode JSON/DECIMAL (Phase 0 spike).
enum MySQLValueDecoder {
    typealias Column = MySQLProtocol.ColumnDefinition41

    static func decode(_ buffer: ByteBuffer?, column: Column) -> CellValue {
        guard var buffer else { return .null }
        let type = column.columnType
        let isBinaryCharset = column.characterSet == .binary

        if isBinaryCharset && (isBlobLike(type) || type == .bit || type == .geometry) {
            return .bytes(Data(buffer.readableBytesView))
        }
        guard let text = buffer.readString(length: buffer.readableBytes) else {
            return .bytes(Data(buffer.readableBytesView))
        }

        switch type {
        case .tiny, .short, .long, .int24, .longlong:
            if column.flags.contains(.COLUMN_UNSIGNED) {
                return UInt64(text).map(CellValue.uint) ?? .text(text)
            }
            return Int64(text).map(CellValue.int) ?? .text(text)
        case .year:
            return .temporal(text)
        case .float, .double:
            return Double(text).map(CellValue.double) ?? .text(text)
        case .decimal, .newdecimal:
            return .decimal(text)
        case .date, .newdate, .time, .time2, .datetime, .datetime2, .timestamp, .timestamp2:
            return .temporal(text)
        case .json:
            return .json(text)
        default:
            return .text(text)
        }
    }

    static func isBlobLike(_ type: MySQLProtocol.DataType) -> Bool {
        [.tinyBlob, .mediumBlob, .longBlob, .blob, .varString, .string, .varchar].contains(type)
    }

    /// Human-readable type name for result headers.
    static func typeName(_ column: Column) -> String {
        let type = column.columnType
        let binary = column.characterSet == .binary
        let unsigned = column.flags.contains(.COLUMN_UNSIGNED) ? " UNSIGNED" : ""
        switch type {
        case .tiny: return "TINYINT" + unsigned
        case .short: return "SMALLINT" + unsigned
        case .int24: return "MEDIUMINT" + unsigned
        case .long: return "INT" + unsigned
        case .longlong: return "BIGINT" + unsigned
        case .float: return "FLOAT"
        case .double: return "DOUBLE"
        case .decimal, .newdecimal: return "DECIMAL"
        case .date, .newdate: return "DATE"
        case .time, .time2: return "TIME"
        case .datetime, .datetime2: return "DATETIME"
        case .timestamp, .timestamp2: return "TIMESTAMP"
        case .year: return "YEAR"
        case .json: return "JSON"
        case .bit: return "BIT"
        case .geometry: return "GEOMETRY"
        case .enum: return "ENUM"
        case .set: return "SET"
        case .varchar, .varString: return binary ? "VARBINARY" : "VARCHAR"
        case .string: return binary ? "BINARY" : "CHAR"
        case .tinyBlob, .mediumBlob, .longBlob, .blob: return binary ? "BLOB" : "TEXT"
        case .null: return "NULL"
        default: return "UNKNOWN"
        }
    }
}
