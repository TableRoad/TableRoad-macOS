import Foundation

/// Oracle NUMBER: an exponent byte (base 100, excess 65, bits inverted for negatives) followed by base-100 mantissa
/// digits (stored +1, or 101-d for negatives, which also end with a 102 terminator when shorter than 20 bytes).
public enum OracleNumber {
    /// Decimal text for the wire bytes, e.g. `-12.5`, `0.001`, `1e126` style values written out in full.
    public static func decode(_ bytes: some Collection<UInt8>) -> String? {
        let b = Array(bytes)
        guard let first = b.first else { return nil }
        let positive = first & 0x80 != 0
        let exponentByte = positive ? first : ~first
        // Value of the first mantissa digit pair, in powers of 100.
        let exponent = Int(exponentByte & 0x7f) - 65
        var mantissa = b.dropFirst()
        if mantissa.isEmpty { return positive ? "0" : "-1e126" }
        if !positive, mantissa.last == 102 { mantissa = mantissa.dropLast() }

        var digits: [UInt8] = []
        for byte in mantissa {
            let pair = positive ? Int(byte) - 1 : 101 - Int(byte)
            guard (0...99).contains(pair) else { return nil }
            digits.append(UInt8(pair / 10))
            digits.append(UInt8(pair % 10))
        }
        // Decimal point position in `digits` (each pair is two decimal digits).
        var point = (exponent + 1) * 2
        while digits.first == 0 {
            digits.removeFirst()
            point -= 1
        }
        while digits.last == 0 { digits.removeLast() }
        if digits.isEmpty { return "0" }

        var text = positive ? "" : "-"
        if point <= 0 {
            text += "0." + String(repeating: "0", count: -point) + digits.map(String.init).joined()
        } else if point >= digits.count {
            text += digits.map(String.init).joined() + String(repeating: "0", count: point - digits.count)
        } else {
            text += digits[..<point].map(String.init).joined() + "." + digits[point...].map(String.init).joined()
        }
        return text
    }

    /// Wire bytes for decimal text (`-1.5`, `12e3`); nil when the text isn't a number Oracle can store.
    public static func encode(_ text: String) -> [UInt8]? {
        var chars = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        guard !chars.isEmpty else { return nil }
        var negative = false
        if chars.first == UInt8(ascii: "-") {
            negative = true
            chars.removeFirst()
        } else if chars.first == UInt8(ascii: "+") {
            chars.removeFirst()
        }
        var digits: [UInt8] = []
        var point = 0
        var seenPoint = false
        var index = 0
        var sawDigit = false
        while index < chars.count {
            let c = chars[index]
            if c == UInt8(ascii: ".") {
                guard !seenPoint else { return nil }
                seenPoint = true
            } else if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
                sawDigit = true
                let digit = c - UInt8(ascii: "0")
                if digit == 0 && digits.isEmpty {
                    if seenPoint { point -= 1 }  // leading zeros after the point move it left
                } else {
                    digits.append(digit)
                    if !seenPoint { point += 1 }
                }
            } else if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                break
            } else {
                return nil
            }
            index += 1
        }
        guard sawDigit else { return nil }
        if index < chars.count {
            guard let exponent = Int(String(decoding: chars[(index + 1)...], as: UTF8.self)) else { return nil }
            point += exponent
        }
        while digits.last == 0 { digits.removeLast() }
        if digits.isEmpty { return [0x80] }
        guard digits.count <= 40, point <= 126, point >= -129 else { return nil }

        // Align to base-100 pairs: an odd point position gets a leading zero digit.
        if point % 2 != 0 {
            digits.insert(0, at: 0)
            point += 1
        }
        if digits.count % 2 != 0 { digits.append(0) }
        let pairs = stride(from: 0, to: digits.count, by: 2).map { Int(digits[$0]) * 10 + Int(digits[$0 + 1]) }
        let exponentByte = UInt8(truncatingIfNeeded: point / 2 + 192)
        var result: [UInt8] = [negative ? ~exponentByte : exponentByte]
        for pair in pairs { result.append(UInt8(negative ? 101 - pair : pair + 1)) }
        if negative && pairs.count < 20 { result.append(102) }
        return result
    }
}

/// Dates, timestamps, intervals, floats and rowids in Oracle's wire formats, rendered as text the session's NLS
/// formats accept back (so edited values round-trip).
enum OracleValues {
    /// DATE (7 bytes), TIMESTAMP (11) and TIMESTAMP WITH TIME ZONE (13): century+100, year+100, month, day,
    /// hour+1, minute+1, second+1, nanoseconds (big-endian), tz hour+20, tz minute+60.
    static func timestamp(_ b: [UInt8], withZone: Bool, showFraction: Bool) -> String? {
        guard b.count >= 7 else { return nil }
        var year = (Int(b[0]) - 100) * 100 + Int(b[1]) - 100
        var month = Int(b[2])
        var day = Int(b[3])
        var hour = Int(b[4]) - 1
        var minute = Int(b[5]) - 1
        let second = Int(b[6]) - 1
        let nanos = b.count >= 11 ? b[7..<11].reduce(0) { $0 << 8 | Int($1) } : 0
        var zone = ""
        if withZone, b.count >= 13 {
            if b[11] & 0x80 != 0 {
                // A named region; without the server's time zone file only the UTC instant is known.
                zone = " UTC"
            } else {
                let offsetHours = Int(b[11]) - 20
                let offsetMinutes = Int(b[12]) - 60
                let offset = offsetHours * 60 + offsetMinutes
                // Stored in UTC: shift to the value's own offset.
                (year, month, day, hour, minute) = shift(
                    year: year, month: month, day: day, hour: hour, minute: minute, byMinutes: offset)
                let sign = offset < 0 ? "-" : "+"
                zone = " \(sign)\(pad(abs(offset) / 60, 2)):\(pad(abs(offset) % 60, 2))"
            }
        }
        var text = "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2)) \(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))"
        if showFraction && nanos > 0 { text += "." + fraction(nanos) }
        return text + zone
    }

    /// Nanoseconds as fractional digits without trailing zeros.
    static func fraction(_ nanos: Int) -> String {
        var digits = pad(nanos, 9)
        while digits.hasSuffix("0") { digits.removeLast() }
        return digits
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(abs(value))
        return (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - text.count)) + text
    }

    static func shift(year: Int, month: Int, day: Int, hour: Int, minute: Int, byMinutes offset: Int) -> (
        Int, Int, Int, Int, Int
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard
            let date = calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)),
            let shifted = calendar.date(byAdding: .minute, value: offset, to: date)
        else { return (year, month, day, hour, minute) }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: shifted)
        return (c.year ?? year, c.month ?? month, c.day ?? day, c.hour ?? hour, c.minute ?? minute)
    }

    /// INTERVAL YEAR TO MONTH: years (u32, excess 2^31) and months (+60). Rendered `+1-02`.
    static func intervalYM(_ b: [UInt8]) -> String? {
        guard b.count >= 5 else { return nil }
        let years = Int(b[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) - 0x8000_0000
        let months = Int(b[4]) - 60
        let negative = years < 0 || months < 0
        return (negative ? "-" : "+") + "\(abs(years))-\(pad(abs(months), 2))"
    }

    /// INTERVAL DAY TO SECOND: days (u32, excess 2^31), hours, minutes, seconds (+60), nanoseconds (u32, excess
    /// 2^31). Rendered `+2 03:04:05.5`.
    static func intervalDS(_ b: [UInt8]) -> String? {
        guard b.count >= 11 else { return nil }
        let days = Int(b[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) - 0x8000_0000
        let hours = Int(b[4]) - 60
        let minutes = Int(b[5]) - 60
        let seconds = Int(b[6]) - 60
        let nanos = Int(b[7..<11].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) - 0x8000_0000
        let negative = days < 0 || hours < 0 || minutes < 0 || seconds < 0 || nanos < 0
        var text =
            (negative ? "-" : "+")
            + "\(abs(days)) \(pad(abs(hours), 2)):\(pad(abs(minutes), 2)):\(pad(abs(seconds), 2))"
        if nanos != 0 { text += "." + fraction(abs(nanos)) }
        return text
    }

    /// BINARY_DOUBLE: IEEE bits with the sign bit flipped for positives and all bits inverted for negatives
    /// (so the bytes sort like the numbers).
    static func binaryDouble(_ b: [UInt8]) -> Double? {
        guard b.count == 8 else { return nil }
        var bytes = b
        if bytes[0] & 0x80 != 0 {
            bytes[0] &= 0x7f
        } else {
            bytes = bytes.map { ~$0 }
        }
        return Double(bitPattern: bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    }

    static func binaryFloat(_ b: [UInt8]) -> Float? {
        guard b.count == 4 else { return nil }
        var bytes = b
        if bytes[0] & 0x80 != 0 {
            bytes[0] &= 0x7f
        } else {
            bytes = bytes.map { ~$0 }
        }
        return Float(bitPattern: bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    static let base64: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// The 18-character extended rowid: object (6), file (3), block (6), row (3), each in Oracle's base 64.
    static func rowid(rba: UInt32, partition: UInt16, block: UInt32, slot: UInt16) -> String? {
        guard rba != 0 || partition != 0 || block != 0 || slot != 0 else { return nil }
        func encode(_ value: UInt64, _ size: Int) -> [UInt8] {
            (0..<size).reversed().map { base64[Int((value >> (6 * UInt64($0))) & 0x3f)] }
        }
        let bytes =
            encode(UInt64(rba), 6) + encode(UInt64(partition), 3) + encode(UInt64(block), 6) + encode(UInt64(slot), 3)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A universal rowid: physical ones decode like ROWID; logical ones (index-organized tables) are base64 with a
    /// leading `*`.
    static func urowid(_ b: [UInt8]) -> String? {
        guard let kind = b.first else { return nil }
        if kind == 1, b.count >= 13 {
            func u32(_ i: Int) -> UInt32 { b[i..<(i + 4)].reduce(0) { $0 << 8 | UInt32($1) } }
            func u16(_ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
            return rowid(rba: u32(1), partition: u16(5), block: u32(7), slot: u16(11))
        }
        var output: [UInt8] = [UInt8(ascii: "*")]
        var bits = 0
        var buffer = 0
        for byte in b.dropFirst() {
            buffer = buffer << 8 | Int(byte)
            bits += 8
            while bits >= 6 {
                bits -= 6
                output.append(base64[(buffer >> bits) & 0x3f])
            }
        }
        if bits > 0 { output.append(base64[(buffer << (6 - bits)) & 0x3f]) }
        return String(decoding: output, as: UTF8.self)
    }
}
