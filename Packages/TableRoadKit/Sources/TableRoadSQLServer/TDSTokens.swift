import CoreFoundation
import Foundation
import NIOCore
import TableRoadCore

/// A column's type as described in COLMETADATA.
struct TDSColumn {
    var name: String
    var type: UInt8
    /// Declared length (bytes), or 0xFFFF for PLP (max) types.
    var maxLength: Int = 0
    var precision: Int = 0
    var scale: Int = 0
    /// Code page of char/varchar/text data (from the collation).
    var encoding: String.Encoding = .windowsCP1252
    var udtName: String?

    /// The name shown in the column header tooltip, e.g. `nvarchar(50)`.
    var typeName: String {
        switch type {
        case 0x30: "tinyint"
        case 0x32, 0x68: "bit"
        case 0x34: "smallint"
        case 0x38: "int"
        case 0x7F: "bigint"
        case 0x26: maxLength == 8 ? "bigint" : maxLength == 4 ? "int" : maxLength == 2 ? "smallint" : "tinyint"
        case 0x3B: "real"
        case 0x3E: "float"
        case 0x6D: maxLength == 4 ? "real" : "float"
        case 0x3C, 0x7A, 0x6E: maxLength == 4 || type == 0x7A ? "smallmoney" : "money"
        case 0x3A: "smalldatetime"
        case 0x3D: "datetime"
        case 0x6F: maxLength == 4 ? "smalldatetime" : "datetime"
        case 0x6A, 0x37: "decimal(\(precision),\(scale))"
        case 0x6C, 0x3F: "numeric(\(precision),\(scale))"
        case 0x24: "uniqueidentifier"
        case 0x28: "date"
        case 0x29: "time(\(scale))"
        case 0x2A: "datetime2(\(scale))"
        case 0x2B: "datetimeoffset(\(scale))"
        case 0xA7: "varchar(\(maxLength == 0xFFFF ? "max" : String(maxLength)))"
        case 0xAF: "char(\(maxLength))"
        case 0xE7: "nvarchar(\(maxLength == 0xFFFF ? "max" : String(maxLength / 2)))"
        case 0xEF: "nchar(\(maxLength / 2))"
        case 0xA5: "varbinary(\(maxLength == 0xFFFF ? "max" : String(maxLength)))"
        case 0xAD: "binary(\(maxLength))"
        case 0x23: "text"
        case 0x63: "ntext"
        case 0x22: "image"
        case 0xF1: "xml"
        case 0x62: "sql_variant"
        case 0xF0: udtName ?? "udt"
        case 0x1F: "null"
        default: String(format: "type 0x%02X", type)
        }
    }

    var isPLP: Bool {
        (type == 0xA5 || type == 0xA7 || type == 0xE7) && maxLength == 0xFFFF || type == 0xF1 || type == 0xF0
    }
}

/// One result set of a batch.
struct TDSResult {
    var columns: [TDSColumn]
    var rows: [[CellValue]] = []
}

/// Everything a response message said.
struct TDSResponse {
    var results: [TDSResult] = []
    /// Rows affected, summed over the statements that reported a count.
    var rowCount: UInt64 = 0
    var hasRowCount = false
    var errors: [TDSServerMessage] = []
    var infos: [TDSServerMessage] = []
    var loginAck: (tdsVersion: UInt32, program: String, version: String)?
    var database: String?
    var packetSize: Int?
    var transaction: UInt64?
    var attentionAcknowledged = false
}

struct TDSServerMessage {
    var number: Int
    var state: Int
    var severity: Int
    var message: String
    var line: Int
}

struct TDSParseError: Error {
    var message: String
}

/// Reads a whole response message's token stream.
struct TDSTokenParser {
    var buffer: ByteBuffer
    private var columns: [TDSColumn] = []

    init(_ buffer: ByteBuffer) {
        self.buffer = buffer
    }

    mutating func parse() throws -> TDSResponse {
        var response = TDSResponse()
        while let token = buffer.readInteger(as: UInt8.self) {
            switch token {
            case 0x81:  // COLMETADATA
                columns = try readColumnMetadata()
                response.results.append(TDSResult(columns: columns))
            case 0xD1:  // ROW
                let row = try columns.map { try readValue($0) }
                if !response.results.isEmpty { response.results[response.results.count - 1].rows.append(row) }
            case 0xD2:  // NBCROW: a null bitmap, then the non-null values
                let bitmap = try bytes((columns.count + 7) / 8)
                var row: [CellValue] = []
                row.reserveCapacity(columns.count)
                for (index, column) in columns.enumerated() {
                    row.append(bitmap[index / 8] & (1 << (index % 8)) != 0 ? .null : try readValue(column))
                }
                if !response.results.isEmpty { response.results[response.results.count - 1].rows.append(row) }
            case 0xFD, 0xFE, 0xFF:  // DONE, DONEPROC, DONEINPROC
                let status = try u16()
                _ = try u16()  // current command
                let count = try u64()
                if status & 0x0010 != 0 {
                    response.rowCount &+= count
                    response.hasRowCount = true
                }
                if status & 0x0020 != 0 { response.attentionAcknowledged = true }
            case 0xAA, 0xAB:  // ERROR, INFO
                _ = try u16()
                let message = TDSServerMessage(
                    number: Int(try u32()), state: Int(try u8()), severity: Int(try u8()), message: try usVarchar(),
                    line: 0)
                _ = try bVarchar()  // server name
                _ = try bVarchar()  // procedure name
                var full = message
                full.line = Int(try u32())
                if token == 0xAA { response.errors.append(full) } else { response.infos.append(full) }
            case 0xAD:  // LOGINACK
                _ = try u16()
                _ = try u8()  // interface
                let tdsVersion = try u32BigEndian()
                let program = try bVarchar()
                let v = try bytes(4)
                response.loginAck = (tdsVersion, program, "\(v[0]).\(v[1]).\(Int(v[2]) << 8 | Int(v[3]))")
            case 0xE3:  // ENVCHANGE
                let length = Int(try u16())
                guard var change = buffer.readSlice(length: length) else { throw truncated }
                let kind = change.readInteger(as: UInt8.self)
                var sub = TDSTokenParser(change)
                switch kind {
                case 1: response.database = try sub.bVarchar()
                case 4: response.packetSize = Int(try sub.bVarchar())
                case 8:  // begin transaction: new descriptor
                    let size = Int(try sub.u8())
                    if size == 8 { response.transaction = try sub.u64() }
                case 9, 10, 17, 18:  // commit, rollback, transaction ended / reset
                    response.transaction = 0
                default: break
                }
                _ = change
            case 0xA9:  // ORDER
                _ = try bytes(Int(try u16()))
            case 0x79:  // RETURNSTATUS
                _ = try u32()
            case 0xA4, 0xA5, 0xED:  // TABNAME, COLINFO, SSPI
                _ = try bytes(Int(try u16()))
            case 0xE4:  // SESSIONSTATE
                _ = try bytes(Int(try u32()))
            case 0xAE:  // FEATUREEXTACK
                while let feature = buffer.readInteger(as: UInt8.self), feature != 0xFF {
                    _ = try bytes(Int(try u32()))
                }
            case 0xAC:  // RETURNVALUE (RPC output parameters; not used, but skip cleanly)
                _ = try u16()  // ordinal
                _ = try bVarchar()
                _ = try u8()  // status
                var column = try readTypeInfo(name: "")
                column.name = ""
                _ = try readValue(column)
            default:
                throw TDSParseError(message: String(format: "Unknown TDS token 0x%02X", token))
            }
        }
        return response
    }

    // MARK: Metadata

    private mutating func readColumnMetadata() throws -> [TDSColumn] {
        let count = try u16()
        guard count != 0xFFFF else { return [] }
        var result: [TDSColumn] = []
        for _ in 0..<count {
            _ = try u32()  // user type
            _ = try u16()  // flags
            var column = try readTypeInfo(name: "")
            if column.type == 0x22 || column.type == 0x23 || column.type == 0x63 {  // table name for text/ntext/image
                let parts = Int(try u8())
                for _ in 0..<parts { _ = try usVarchar() }
            }
            column.name = try bVarchar()
            result.append(column)
        }
        return result
    }

    private mutating func readTypeInfo(name: String) throws -> TDSColumn {
        var column = TDSColumn(name: name, type: try u8())
        switch column.type {
        case 0x1F, 0x30, 0x32, 0x34, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x7A, 0x7F, 0x28:
            break  // fixed length (and DATEN)
        case 0x24, 0x26, 0x68, 0x6D, 0x6E, 0x6F:
            column.maxLength = Int(try u8())
        case 0x6A, 0x6C, 0x37, 0x3F:
            column.maxLength = Int(try u8())
            column.precision = Int(try u8())
            column.scale = Int(try u8())
        case 0x29, 0x2A, 0x2B:
            column.scale = Int(try u8())
        case 0xA5, 0xAD:
            column.maxLength = Int(try u16())
        case 0xA7, 0xAF, 0xE7, 0xEF:
            column.maxLength = Int(try u16())
            column.encoding = try collation()
        case 0x23, 0x63:
            column.maxLength = Int(try u32())
            column.encoding = try collation()
        case 0x22:
            column.maxLength = Int(try u32())
        case 0x62:
            column.maxLength = Int(try u32())
        case 0xF1:  // XML: optional schema collection
            if try u8() != 0 {
                _ = try bVarchar()
                _ = try bVarchar()
                _ = try usVarchar()
            }
        case 0xF0:  // UDT
            column.maxLength = Int(try u16())
            _ = try bVarchar()
            _ = try bVarchar()
            column.udtName = try bVarchar()
            _ = try usVarchar()
        default:
            throw TDSParseError(message: String(format: "Unsupported SQL Server type 0x%02X", column.type))
        }
        return column
    }

    /// Code page of a 5-byte collation: UTF-8 collations (SQL Server 2019+), a SQL sort order, or the LCID's
    /// Windows code page.
    private mutating func collation() throws -> String.Encoding {
        let raw = try bytes(5)
        let info = UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
        let sortID = raw[4]
        if info & (1 << 26) != 0 { return .utf8 }  // fUTF8
        if sortID != 0, let page = Self.sortOrderCodePages[sortID] { return Self.encoding(codePage: page) }
        return Self.encoding(codePage: Self.codePage(lcid: info & 0xFFFFF))
    }

    // MARK: Values

    mutating func readValue(_ column: TDSColumn) throws -> CellValue {
        switch column.type {
        case 0x1F: return .null
        case 0x30: return .int(Int64(try u8()))
        case 0x32: return .bool(try u8() != 0)
        case 0x34: return .int(Int64(Int16(bitPattern: try u16())))
        case 0x38: return .int(Int64(Int32(bitPattern: try u32())))
        case 0x7F: return .int(Int64(bitPattern: try u64()))
        case 0x3B: return .double(Double(Float(bitPattern: try u32())))
        case 0x3E: return .double(Double(bitPattern: try u64()))
        case 0x3C: return .decimal(Self.money(try bytes(8)))
        case 0x7A: return .decimal(Self.money(try bytes(4)))
        case 0x3D: return .temporal(Self.dateTime(try bytes(8)))
        case 0x3A: return .temporal(Self.smallDateTime(try bytes(4)))
        default: break
        }
        if column.isPLP {
            guard let data = try plp() else { return .null }
            switch column.type {
            case 0xE7, 0xF1:
                let text = Self.utf16(data)
                return column.type == 0xF1 ? .text(text) : .text(text)
            case 0xA7: return .text(String(data: data, encoding: column.encoding) ?? Self.utf16(data))
            default: return .bytes(data)
            }
        }
        switch column.type {
        case 0x22, 0x23, 0x63:  // text/ntext/image: text pointer, timestamp, then the data
            let pointer = Int(try u8())
            guard pointer > 0 else { return .null }
            _ = try bytes(pointer + 8)
            let data = Data(try bytes(Int(try u32())))
            if column.type == 0x22 { return .bytes(data) }
            return .text(column.type == 0x63 ? Self.utf16(data) : String(data: data, encoding: column.encoding) ?? "")
        case 0x62:
            let length = Int(try u32())
            guard length > 0 else { return .null }
            return try variant(length: length)
        case 0xA5, 0xAD, 0xA7, 0xAF, 0xE7, 0xEF:
            let length = try u16()
            guard length != 0xFFFF else { return .null }
            let data = Data(try bytes(Int(length)))
            switch column.type {
            case 0xA5, 0xAD: return .bytes(data)
            case 0xE7, 0xEF: return .text(Self.utf16(data))
            default: return .text(String(data: data, encoding: column.encoding) ?? Self.utf16(data))
            }
        default:
            // Nullable fixed types: a 1-byte length (0 = NULL), then the value.
            let length = Int(try u8())
            guard length > 0 else { return .null }
            let raw = try bytes(length)
            return try Self.decode(type: column.type, raw: raw, precision: column.precision, scale: column.scale)
        }
    }

    static func decode(type: UInt8, raw: [UInt8], precision: Int, scale: Int) throws -> CellValue {
        func int(_ bytes: ArraySlice<UInt8>) -> UInt64 {
            bytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case 0x26:
            let value = int(raw[...])
            switch raw.count {
            case 1: return .int(Int64(value))
            case 2: return .int(Int64(Int16(truncatingIfNeeded: value)))
            case 4: return .int(Int64(Int32(truncatingIfNeeded: value)))
            default: return .int(Int64(bitPattern: value))
            }
        case 0x68: return .bool(raw[0] != 0)
        case 0x6D:
            return raw.count == 4
                ? .double(Double(Float(bitPattern: UInt32(int(raw[...]))))) : .double(Double(bitPattern: int(raw[...])))
        case 0x6E: return .decimal(money(raw))
        case 0x6F: return .temporal(raw.count == 4 ? smallDateTime(raw) : dateTime(raw))
        case 0x6A, 0x6C, 0x37, 0x3F: return .decimal(decimal(raw, scale: scale))
        case 0x24: return .uuid(guid(raw))
        case 0x28: return .temporal(date(days: Int(int(raw[0..<3]))))
        case 0x29: return .temporal(time(raw[...], scale: scale))
        case 0x2A:
            let timeBytes = raw.count - 3
            return .temporal(
                date(days: Int(int(raw[timeBytes...]))) + " " + time(raw[0..<timeBytes], scale: scale))
        case 0x2B:
            // Stored in UTC with the offset in minutes; shown in the value's own offset.
            let timeBytes = raw.count - 5
            let offset = Int(Int16(truncatingIfNeeded: int(raw[(raw.count - 2)...])))
            let days = Int(int(raw[timeBytes..<(timeBytes + 3)]))
            let units = int(raw[0..<timeBytes])
            let perSecond = pow10(scale)
            var seconds = Int(units / perSecond) + offset * 60
            var dayShift = 0
            while seconds < 0 {
                seconds += 86_400
                dayShift -= 1
            }
            while seconds >= 86_400 {
                seconds -= 86_400
                dayShift += 1
            }
            let local = UInt64(seconds) * perSecond + units % perSecond
            let sign = offset < 0 ? "-" : "+"
            return .temporal(
                date(days: days + dayShift) + " " + time(local, scale: scale)
                    + String(format: " %@%02d:%02d", sign, abs(offset) / 60, abs(offset) % 60))
        default:
            throw TDSParseError(message: String(format: "Can't decode SQL Server type 0x%02X", type))
        }
    }

    private mutating func variant(length: Int) throws -> CellValue {
        let base = try u8()
        let propertyLength = Int(try u8())
        let properties = try bytes(propertyLength)
        let data = try bytes(length - 2 - propertyLength)
        switch base {
        case 0x30: return .int(Int64(data[0]))
        case 0x32: return .bool(data[0] != 0)
        case 0x34, 0x38, 0x7F:
            return try Self.decode(type: 0x26, raw: data, precision: 0, scale: 0)
        case 0x3B, 0x3E: return try Self.decode(type: 0x6D, raw: data, precision: 0, scale: 0)
        case 0x3C, 0x7A: return .decimal(Self.money(data))
        case 0x3D: return .temporal(Self.dateTime(data))
        case 0x3A: return .temporal(Self.smallDateTime(data))
        case 0x6A, 0x6C:
            return .decimal(Self.decimal(data, scale: properties.count > 1 ? Int(properties[1]) : 0))
        case 0x24, 0x28: return try Self.decode(type: base, raw: data, precision: 0, scale: 0)
        case 0x29, 0x2A, 0x2B:
            return try Self.decode(type: base, raw: data, precision: 0, scale: properties.first.map(Int.init) ?? 7)
        case 0xE7, 0xEF: return .text(Self.utf16(Data(data)))
        case 0xA7, 0xAF: return .text(String(decoding: data, as: UTF8.self))
        default: return .bytes(Data(data))
        }
    }

    /// Partially length-prefixed data: total length (or unknown), then chunks until a zero-length one.
    private mutating func plp() throws -> Data? {
        let total = try u64()
        if total == 0xFFFF_FFFF_FFFF_FFFF { return nil }
        var data = Data()
        if total != 0xFFFF_FFFF_FFFF_FFFE { data.reserveCapacity(Int(min(total, 64 << 20))) }
        while true {
            let chunk = Int(try u32())
            if chunk == 0 { break }
            data.append(contentsOf: try bytes(chunk))
        }
        return data
    }

    // MARK: Formatting

    static func money(_ raw: [UInt8]) -> String {
        let value: Int64
        if raw.count == 4 {
            value = Int64(
                Int32(bitPattern: UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24))
        } else {
            let high = UInt64(UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24)
            let low = UInt64(UInt32(raw[4]) | UInt32(raw[5]) << 8 | UInt32(raw[6]) << 16 | UInt32(raw[7]) << 24)
            value = Int64(bitPattern: high << 32 | low)
        }
        let magnitude = value.magnitude
        return (value < 0 ? "-" : "") + "\(magnitude / 10_000)." + String(format: "%04d", Int(magnitude % 10_000))
    }

    /// Sign byte (1 = positive), then a little-endian integer of up to 128 bits, with `scale` decimals.
    static func decimal(_ raw: [UInt8], scale: Int) -> String {
        guard let sign = raw.first else { return "0" }
        // Little-endian 32-bit words, divided by 10 repeatedly to get the digits.
        var words: [UInt32] = stride(from: 1, to: raw.count, by: 4).map { start in
            (0..<4).reduce(UInt32(0)) { word, index in
                start + index < raw.count ? word | UInt32(raw[start + index]) << (8 * index) : word
            }
        }
        var digits: [Character] = []
        while words.contains(where: { $0 != 0 }) {
            var remainder: UInt64 = 0
            for index in words.indices.reversed() {
                let value = remainder << 32 | UInt64(words[index])
                words[index] = UInt32(value / 10)
                remainder = value % 10
            }
            digits.append(Character(String(remainder)))
        }
        while digits.count <= scale { digits.append("0") }
        var text = String(digits.reversed())
        if scale > 0 { text.insert(".", at: text.index(text.endIndex, offsetBy: -scale)) }
        return (sign == 0 && text.contains(where: { $0 != "0" && $0 != "." }) ? "-" : "") + text
    }

    static func guid(_ raw: [UInt8]) -> UUID {
        // The first three groups are little-endian.
        let ordered = [raw[3], raw[2], raw[1], raw[0], raw[5], raw[4], raw[7], raw[6]] + raw[8..<16]
        return UUID(
            uuid: (
                ordered[0], ordered[1], ordered[2], ordered[3], ordered[4], ordered[5], ordered[6], ordered[7],
                ordered[8], ordered[9], ordered[10], ordered[11], ordered[12], ordered[13], ordered[14], ordered[15]
            ))
    }

    /// datetime: days since 1900-01-01 and 1/300 s since midnight.
    static func dateTime(_ raw: [UInt8]) -> String {
        let days = Int(
            Int32(bitPattern: UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24))
        let ticks = Int(UInt32(raw[4]) | UInt32(raw[5]) << 8 | UInt32(raw[6]) << 16 | UInt32(raw[7]) << 24)
        let milliseconds = (ticks * 10 + 1) / 3  // round 1/300 s to ms
        return date(days: days + 693_595) + " " + clock(milliseconds / 1000)
            + String(format: ".%03d", milliseconds % 1000)
    }

    /// smalldatetime: days since 1900-01-01 and minutes since midnight.
    static func smallDateTime(_ raw: [UInt8]) -> String {
        let days = Int(UInt16(raw[0]) | UInt16(raw[1]) << 8)
        let minutes = Int(UInt16(raw[2]) | UInt16(raw[3]) << 8)
        return date(days: days + 693_595) + " " + clock(minutes * 60)
    }

    /// Days since 0001-01-01 (proleptic Gregorian) as yyyy-MM-dd.
    static func date(days: Int) -> String {
        // Howard Hinnant's civil_from_days, shifted from 1970-01-01 (day 719162).
        let z = days - 719_162 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func time(_ raw: ArraySlice<UInt8>, scale: Int) -> String {
        time(raw.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }, scale: scale)
    }

    static func time(_ units: UInt64, scale: Int) -> String {
        let perSecond = pow10(scale)
        let text = clock(Int(units / perSecond))
        return scale > 0 ? text + "." + String(format: "%0\(scale)llu", units % perSecond) : text
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private static func pow10(_ n: Int) -> UInt64 {
        (0..<n).reduce(UInt64(1)) { value, _ in value * 10 }
    }

    static func utf16(_ data: Data) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            units.append(UInt16(data[index]) | UInt16(data[index + 1]) << 8)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: Code pages

    static func encoding(codePage: UInt32) -> String.Encoding {
        let cf = CFStringConvertWindowsCodepageToEncoding(codePage)
        guard cf != kCFStringEncodingInvalidId else { return .windowsCP1252 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// SQL Server sort orders (SQL_* collations) with a code page other than the LCID's.
    static let sortOrderCodePages: [UInt8: UInt32] = [
        30: 437, 31: 437, 32: 437, 33: 437, 34: 437, 40: 850, 41: 850, 42: 850, 43: 850, 44: 850, 49: 850, 51: 1252,
        52: 1252, 53: 1252, 54: 1252, 55: 850, 56: 850, 57: 850, 58: 850, 59: 850, 60: 850, 61: 850, 80: 1250,
        81: 1250, 82: 1250, 83: 1250, 84: 1250, 85: 1250, 86: 1250, 87: 1250, 88: 1250, 89: 1250, 90: 1250,
        91: 1250, 92: 1250, 93: 1250, 94: 1250, 95: 1250, 96: 1250, 97: 1250, 98: 1250, 104: 1251, 105: 1251,
        106: 1251, 107: 1251, 108: 1251, 112: 1253, 113: 1253, 114: 1253, 120: 1253, 121: 1253, 124: 1253,
        128: 1254, 129: 1254, 130: 1254, 136: 1255, 137: 1255, 138: 1255, 144: 1256, 145: 1256, 146: 1256,
        152: 1257, 153: 1257, 154: 1257, 155: 1257, 156: 1257, 157: 1257, 158: 1257, 159: 1257, 160: 1257,
        183: 1252, 184: 1252, 185: 1252, 186: 1252, 192: 932, 193: 932, 194: 949, 195: 949, 196: 950, 197: 950,
        198: 936, 199: 936, 200: 932, 201: 949, 202: 950, 203: 936, 204: 874, 205: 874, 206: 874, 210: 1252,
        211: 1252, 212: 1252, 213: 1252, 214: 1252, 215: 1252, 216: 1252, 217: 1252,
    ]

    /// The ANSI code page Windows uses for an LCID (primary language decides it).
    static func codePage(lcid: UInt32) -> UInt32 {
        switch lcid & 0x3FF {
        case 0x04: (lcid == 0x0404 || lcid == 0x0C04 || lcid == 0x1404) ? 950 : 936  // Chinese
        case 0x11: 932  // Japanese
        case 0x12: 949  // Korean
        case 0x1E: 874  // Thai
        case 0x2A: 1258  // Vietnamese
        case 0x05, 0x0E, 0x15, 0x18, 0x1A, 0x1B, 0x24, 0x1C: 1250  // Czech, Hungarian, Polish, Romanian, Croatian…
        case 0x19, 0x22, 0x23, 0x02, 0x2F, 0x3F, 0x40, 0x44, 0x50: 1251  // Russian, Ukrainian, Belarusian, Bulgarian…
        case 0x08: 1253  // Greek
        case 0x1F, 0x2C, 0x43: 1254  // Turkish, Azeri, Uzbek
        case 0x0D: 1255  // Hebrew
        case 0x01, 0x20, 0x29: 1256  // Arabic, Urdu, Farsi
        case 0x25, 0x26, 0x27: 1257  // Estonian, Latvian, Lithuanian
        default: 1252
        }
    }

    // MARK: Primitive reads

    private var truncated: TDSParseError { TDSParseError(message: "The server's response was cut short.") }

    mutating func u8() throws -> UInt8 {
        guard let value = buffer.readInteger(as: UInt8.self) else { throw truncated }
        return value
    }

    mutating func u16() throws -> UInt16 {
        guard let value = buffer.readInteger(endianness: .little, as: UInt16.self) else { throw truncated }
        return value
    }

    mutating func u32() throws -> UInt32 {
        guard let value = buffer.readInteger(endianness: .little, as: UInt32.self) else { throw truncated }
        return value
    }

    mutating func u32BigEndian() throws -> UInt32 {
        guard let value = buffer.readInteger(endianness: .big, as: UInt32.self) else { throw truncated }
        return value
    }

    mutating func u64() throws -> UInt64 {
        guard let value = buffer.readInteger(endianness: .little, as: UInt64.self) else { throw truncated }
        return value
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, let value = buffer.readBytes(length: count) else { throw truncated }
        return value
    }

    /// 1-byte character count, UTF-16.
    mutating func bVarchar() throws -> String {
        Self.utf16(Data(try bytes(Int(try u8()) * 2)))
    }

    /// 2-byte character count, UTF-16.
    mutating func usVarchar() throws -> String {
        Self.utf16(Data(try bytes(Int(try u16()) * 2)))
    }
}
