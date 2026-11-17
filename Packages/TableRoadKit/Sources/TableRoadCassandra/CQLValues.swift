import Foundation
import NIOCore
import TableRoadCore

/// Decodes CQL values into TableRoad values. Collections, tuples, UDTs and vectors become JSON text.
enum CQLValues {
    static func cell(_ value: ByteBuffer, _ type: CQLType) -> CellValue {
        var buffer = value
        if buffer.readableBytes == 0 {
            switch type {
            case .ascii, .varchar: return .text("")
            case .blob: return .bytes(Data())
            default: return .text("")  // an "empty" value, legal for most types
            }
        }
        switch type {
        case .ascii, .varchar: return .text(buffer.readString(length: buffer.readableBytes) ?? "")
        case .bigint, .counter, .int, .smallint, .tinyint:
            return integer(buffer).map(CellValue.int) ?? raw(buffer, type)
        case .blob: return .bytes(Data(buffer.readableBytesView))
        case .boolean: return .bool(buffer.readInteger(as: UInt8.self) != 0)
        case .double:
            guard let bits = buffer.readInteger(as: UInt64.self) else { return raw(value, type) }
            return .double(Double(bitPattern: bits))
        case .float:
            guard let bits = buffer.readInteger(as: UInt32.self) else { return raw(value, type) }
            let float = Float(bitPattern: bits)
            // Through its shortest text form, so 1.1f shows as 1.1 rather than 1.100000023841858.
            return .double(Double(String(float)) ?? Double(float))
        case .decimal:
            guard let scale = buffer.readInteger(as: Int32.self) else { return raw(value, type) }
            return .decimal(decimalText(unscaled: varintText(Array(buffer.readableBytesView)), scale: Int(scale)))
        case .varint: return .decimal(varintText(Array(buffer.readableBytesView)))
        case .uuid, .timeuuid:
            guard buffer.readableBytes == 16, let bytes = buffer.readBytes(length: 16) else { return raw(value, type) }
            return .uuid(
                UUID(
                    uuid: (
                        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
                        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
                    )))
        case .timestamp:
            guard let millis = buffer.readInteger(as: Int64.self) else { return raw(value, type) }
            return .temporal(timestampText(millis))
        case .date:
            guard let days = buffer.readInteger(as: UInt32.self) else { return raw(value, type) }
            return .temporal(dateText(Int64(days) - (1 << 31)))
        case .time:
            guard let nanos = buffer.readInteger(as: Int64.self) else { return raw(value, type) }
            return .temporal(timeText(nanos))
        case .inet: return inetText(Array(buffer.readableBytesView)).map(CellValue.text) ?? raw(value, type)
        case .duration: return durationText(&buffer).map(CellValue.text) ?? raw(value, type)
        case .list, .set, .map, .udt, .tuple, .vector:
            return json(&buffer, type).map(CellValue.json) ?? raw(value, type)
        case .custom: return raw(value, type)
        }
    }

    private static func raw(_ value: ByteBuffer, _ type: CQLType) -> CellValue {
        .unsupported(
            typeName: type.name, raw: "0x" + value.readableBytesView.map { String(format: "%02x", $0) }.joined())
    }

    private static func integer(_ buffer: ByteBuffer) -> Int64? {
        let bytes = Array(buffer.readableBytesView)
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        var value: Int64 = bytes[0] & 0x80 != 0 ? -1 : 0
        for byte in bytes { value = value << 8 | Int64(byte) }
        return value
    }

    // MARK: JSON for structured types

    /// The value as a JSON fragment (nil if the bytes don't match the type).
    static func json(_ buffer: inout ByteBuffer, _ type: CQLType) -> String? {
        switch type {
        case .list(let element), .set(let element):
            guard let count = buffer.readInteger(as: Int32.self), count >= 0 else { return nil }
            var items: [String] = []
            for _ in 0..<count {
                guard let item = readElement(&buffer, element) else { return nil }
                items.append(item)
            }
            return "[" + items.joined(separator: ",") + "]"
        case .map(let keyType, let valueType):
            guard let count = buffer.readInteger(as: Int32.self), count >= 0 else { return nil }
            var pairs: [String] = []
            for _ in 0..<count {
                guard let key = readElement(&buffer, keyType), let value = readElement(&buffer, valueType) else {
                    return nil
                }
                // JSON keys are strings: quote numbers and other non-string keys.
                pairs.append((key.hasPrefix("\"") ? key : quote(key)) + ":" + value)
            }
            return "{" + pairs.joined(separator: ",") + "}"
        case .tuple(let types):
            var items: [String] = []
            for type in types {
                if buffer.readableBytes == 0 {
                    items.append("null")
                } else {
                    guard let item = readElement(&buffer, type) else { return nil }
                    items.append(item)
                }
            }
            return "[" + items.joined(separator: ",") + "]"
        case .udt(_, _, let fields):
            var pairs: [String] = []
            for field in fields {
                // Fields added after the value was written are missing at the end.
                let value = buffer.readableBytes == 0 ? "null" : readElement(&buffer, field.type)
                guard let value else { return nil }
                pairs.append(quote(field.name) + ":" + value)
            }
            return "{" + pairs.joined(separator: ",") + "}"
        case .vector(let element, let size):
            guard let width = fixedWidth(element) else { return nil }
            var items: [String] = []
            for _ in 0..<size {
                guard let slice = buffer.readSlice(length: width) else { return nil }
                items.append(fragment(cell(slice, element)))
            }
            return "[" + items.joined(separator: ",") + "]"
        default:
            return fragment(cell(buffer, type))
        }
    }

    /// One length-prefixed collection element as JSON.
    private static func readElement(_ buffer: inout ByteBuffer, _ type: CQLType) -> String? {
        guard let length = buffer.readInteger(as: Int32.self) else { return nil }
        if length < 0 { return "null" }
        guard var slice = buffer.readSlice(length: Int(length)) else { return nil }
        switch type {
        case .list, .set, .map, .tuple, .udt, .vector: return json(&slice, type)
        default: return fragment(cell(slice, type))
        }
    }

    private static func fixedWidth(_ type: CQLType) -> Int? {
        switch type {
        case .float, .int: 4
        case .double, .bigint, .timestamp: 8
        case .uuid, .timeuuid: 16
        case .boolean, .tinyint: 1
        case .smallint: 2
        default: nil
        }
    }

    static func fragment(_ value: CellValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .uint(let number): return String(number)
        case .double(let number): return number.isFinite ? String(number) : quote(String(number))
        case .decimal(let text): return text
        case .json(let text): return text
        case .bytes(let data): return quote("0x" + data.map { String(format: "%02x", $0) }.joined())
        default: return quote(value.displayText ?? "")
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: Numbers

    /// Two's-complement big-endian integer of any size, as decimal text.
    static func varintText(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "0" }
        let negative = bytes[0] & 0x80 != 0
        var magnitude = bytes
        if negative {
            // Negate: invert and add one.
            magnitude = magnitude.map { ~$0 }
            var index = magnitude.count - 1
            while index >= 0 {
                let (sum, overflow) = magnitude[index].addingReportingOverflow(1)
                magnitude[index] = sum
                if !overflow { break }
                index -= 1
            }
        }
        var digits: [Character] = []
        while magnitude.contains(where: { $0 != 0 }) {
            var remainder = 0
            for index in magnitude.indices {
                let current = remainder << 8 | Int(magnitude[index])
                magnitude[index] = UInt8(current / 10)
                remainder = current % 10
            }
            digits.append(Character(String(remainder)))
        }
        let text = digits.isEmpty ? "0" : String(digits.reversed())
        return negative && text != "0" ? "-" + text : text
    }

    static func decimalText(unscaled: String, scale: Int) -> String {
        let negative = unscaled.hasPrefix("-")
        var digits = negative ? String(unscaled.dropFirst()) : unscaled
        if scale <= 0 {
            if digits != "0" { digits += String(repeating: "0", count: -scale) }
        } else {
            if digits.count <= scale { digits = String(repeating: "0", count: scale - digits.count + 1) + digits }
            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -scale))
        }
        return negative ? "-" + digits : digits
    }

    // MARK: Dates and times (UTC, independent of Foundation's date range)

    /// Days since 1970-01-01 → (year, month, day). Howard Hinnant's civil_from_days.
    static func civil(_ days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func dateText(_ days: Int64) -> String {
        let (year, month, day) = civil(days)
        let yearText = year < 0 ? "-" + pad(-year, 4) : pad(year, 4)
        return "\(yearText)-\(pad(month, 2))-\(pad(day, 2))"
    }

    /// `2024-01-02 03:04:05.678+0000`, the spelling cqlsh uses and the server parses back.
    static func timestampText(_ millis: Int64) -> String {
        let days = millis >= 0 ? millis / 86_400_000 : (millis - 86_399_999) / 86_400_000
        let rest = millis - days * 86_400_000
        let seconds = rest / 1000
        return dateText(days) + " \(pad(seconds / 3600, 2)):\(pad(seconds / 60 % 60, 2)):\(pad(seconds % 60, 2))"
            + ".\(pad(rest % 1000, 3))+0000"
    }

    static func timeText(_ nanos: Int64) -> String {
        let seconds = nanos / 1_000_000_000
        var text = "\(pad(seconds / 3600, 2)):\(pad(seconds / 60 % 60, 2)):\(pad(seconds % 60, 2))"
        let fraction = nanos % 1_000_000_000
        if fraction != 0 {
            var digits = pad(fraction, 9)
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        return text
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    static func inetText(_ bytes: [UInt8]) -> String? {
        let family: Int32
        switch bytes.count {
        case 4: family = AF_INET
        case 16: family = AF_INET6
        default: return nil
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let result = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &output, socklen_t(output.count)) }
        guard result != nil else { return nil }
        return String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Durations

    /// Months, days and nanoseconds as zig-zag vints → `1y2mo3d4h5m6s7ms8us9ns`.
    static func durationText(_ buffer: inout ByteBuffer) -> String? {
        guard let months = readVInt(&buffer), let days = readVInt(&buffer), let nanos = readVInt(&buffer) else {
            return nil
        }
        if months == 0 && days == 0 && nanos == 0 { return "0s" }
        let negative = months < 0 || days < 0 || nanos < 0
        var text = negative ? "-" : ""
        func append(_ value: Int64, _ unit: String) { if value != 0 { text += "\(value)\(unit)" } }
        append(abs(months) / 12, "y")
        append(abs(months) % 12, "mo")
        append(abs(days), "d")
        var rest = abs(nanos)
        for (size, unit) in [
            (Int64(3_600_000_000_000), "h"), (60_000_000_000, "m"), (1_000_000_000, "s"), (1_000_000, "ms"),
            (1000, "us"), (1, "ns"),
        ] {
            append(rest / size, unit)
            rest %= size
        }
        return text
    }

    /// Cassandra's VInt: leading one bits of the first byte count the extra bytes; values are zig-zag encoded.
    static func readVInt(_ buffer: inout ByteBuffer) -> Int64? {
        guard let first = buffer.readInteger(as: UInt8.self) else { return nil }
        let extra = (~first).leadingZeroBitCount
        var value = UInt64(extra >= 8 ? 0 : first & (0xFF >> extra))
        for _ in 0..<extra {
            guard let byte = buffer.readInteger(as: UInt8.self) else { return nil }
            value = value << 8 | UInt64(byte)
        }
        return Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }
}

/// Renders text typed in the grid as a CQL literal of a given type (CQL doesn't coerce strings to other types).
enum CQLLiteral {
    static func render(_ text: String, as type: CQLType) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func invalid() -> DatabaseError {
            DatabaseError(.query, "\(text.debugDescription) isn't a valid \(type.name) value.")
        }
        switch type {
        case .ascii, .varchar, .inet, .date, .time, .timestamp:
            return quote(text)
        case .bigint, .counter, .int, .smallint, .tinyint, .varint:
            guard trimmed.range(of: #"^[-+]?\d+$"#, options: .regularExpression) != nil else { throw invalid() }
            return trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        case .float, .double, .decimal:
            if type != .decimal, ["NaN", "Infinity", "-Infinity"].contains(trimmed) { return trimmed }
            guard trimmed.range(of: #"^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil
            else { throw invalid() }
            return trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "1": return "true"
            case "false", "0": return "false"
            default: throw invalid()
            }
        case .uuid, .timeuuid:
            guard let uuid = UUID(uuidString: trimmed) else { throw invalid() }
            return uuid.uuidString.lowercased()
        case .blob:
            if trimmed.range(of: #"^0[xX]([0-9a-fA-F]{2})*$"#, options: .regularExpression) != nil { return trimmed }
            return "textAsBlob(\(quote(text)))"
        case .duration:
            guard trimmed.range(of: #"^-?[0-9A-Za-zµ]+$"#, options: .regularExpression) != nil else { throw invalid() }
            return trimmed
        case .list, .set, .map, .tuple, .udt, .vector:
            guard
                let value = try? JSONSerialization.jsonObject(
                    with: Data(text.utf8), options: [.fragmentsAllowed])
            else { throw DatabaseError(.query, "\(type.name) values are edited as JSON: \(text.debugDescription)") }
            return try render(json: value, as: type)
        case .custom:
            return quote(text)
        }
    }

    /// A decoded JSON value as a literal of `type`.
    static func render(json value: Any, as type: CQLType) throws -> String {
        if value is NSNull { return "null" }
        func mismatch() -> DatabaseError {
            DatabaseError(.query, "The JSON doesn't match the column's type \(type.name).")
        }
        switch type {
        case .list(let element), .vector(let element, _):
            guard let items = value as? [Any] else { throw mismatch() }
            return "[" + (try items.map { try render(json: $0, as: element) }).joined(separator: ", ") + "]"
        case .set(let element):
            guard let items = value as? [Any] else { throw mismatch() }
            return "{" + (try items.map { try render(json: $0, as: element) }).joined(separator: ", ") + "}"
        case .map(let keyType, let valueType):
            guard let object = value as? [String: Any] else { throw mismatch() }
            return "{"
                + (try object.sorted { $0.key < $1.key }.map {
                    try render($0.key, as: keyType) + ": " + render(json: $0.value, as: valueType)
                }).joined(separator: ", ") + "}"
        case .tuple(let types):
            guard let items = value as? [Any], items.count <= types.count else { throw mismatch() }
            return "(" + (try zip(items, types).map { try render(json: $0, as: $1) }).joined(separator: ", ") + ")"
        case .udt(_, _, let fields):
            guard let object = value as? [String: Any] else { throw mismatch() }
            return "{"
                + (try fields.compactMap { field in
                    try object[field.name].map {
                        CassandraDialect().quoteIdentifier(field.name) + ": " + (try render(json: $0, as: field.type))
                    }
                }).joined(separator: ", ") + "}"
        default:
            let text: String =
                switch value {
                case let string as String: string
                case let number as NSNumber:
                    CFGetTypeID(number) == CFBooleanGetTypeID()
                        ? (number.boolValue ? "true" : "false") : number.stringValue
                default: "\(value)"
                }
            return try render(text, as: type)
        }
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
}
