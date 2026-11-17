import Foundation

/// JSON that keeps key order and numbers as written (Foundation's parser loses both).
/// Used by the Quick Look editor's tree, Pretty and Minify.
public indirect enum JSONValue: Sendable, Hashable {
    case object([Member])
    case array([JSONValue])
    case string(String)
    /// The number exactly as written (so 1.10 stays 1.10 and big integers keep every digit).
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Sendable, Hashable {
        public var key: String
        public var value: JSONValue
        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public var typeName: String {
        switch self {
        case .object: "object"
        case .array: "array"
        case .string: "string"
        case .number: "number"
        case .bool: "bool"
        case .null: "null"
        }
    }

    /// Children for an outline: object members by key, array items by index.
    public var children: [(label: String, value: JSONValue)]? {
        switch self {
        case .object(let members): members.map { ($0.key, $0.value) }
        case .array(let items): items.enumerated().map { ("[\($0.offset)]", $0.element) }
        default: nil
        }
    }

    /// Short text for a leaf (strings unquoted).
    public var scalarText: String {
        switch self {
        case .object(let members): "{\(members.count)}"
        case .array(let items): "[\(items.count)]"
        case .string(let text): text
        case .number(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .null: "null"
        }
    }

    // MARK: Parsing

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var message: String
        /// UTF-8 offset where parsing failed.
        public var offset: Int
        public var description: String { "\(message) at character \(offset + 1)" }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("Unexpected text after the JSON value") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ message: String) -> ParseError { ParseError(message: message, offset: index) }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw error("Nested too deeply") }
            guard index < bytes.count else { throw error("Unexpected end of JSON") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            default: return try number()
            }
        }

        mutating func literal(_ word: String, _ value: JSONValue) throws -> JSONValue {
            let utf8 = Array(word.utf8)
            guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
                throw error("Unexpected character")
            }
            index += utf8.count
            return value
        }

        mutating func object(depth: Int) throws -> JSONValue {
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected a key") }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected “:”") }
                index += 1
                skipWhitespace()
                members.append(Member(key: key, value: try value(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw error("Unterminated object") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                } else {
                    throw error("Expected “,” or “}”")
                }
            }
        }

        mutating func array(depth: Int) throws -> JSONValue {
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw error("Unterminated array") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                } else {
                    throw error("Expected “,” or “]”")
                }
            }
        }

        mutating func string() throws -> String {
            index += 1  // opening quote
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flush() throws {
                guard !raw.isEmpty else { return }
                guard let text = String(bytes: raw, encoding: .utf8) else { throw error("Invalid UTF-8") }
                scalars.append(contentsOf: text.unicodeScalars)
                raw.removeAll()
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    try flush()
                    return String(scalars)
                }
                if byte < 0x20 { throw error("Control character in string") }
                if byte == UInt8(ascii: "\\") {
                    try flush()
                    index += 1
                    guard index < bytes.count else { break }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count,
                            bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
                        {
                            index += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: throw error("Invalid escape")
                    }
                    continue
                }
                raw.append(byte)
                index += 1
            }
            throw error("Unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
                let code = UInt32(text, radix: 16)
            else { throw error("Invalid \\u escape") }
            index += 4
            return code
        }

        mutating func number() throws -> JSONValue {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            let digitsStart = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > digitsStart else { throw error("Unexpected character") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                let fraction = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                    index += 1
                }
                guard index > fraction else { throw error("Expected digits after “.”") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                let exponent = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                    index += 1
                }
                guard index > exponent else { throw error("Expected exponent digits") }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }
    }

    // MARK: Output

    /// Indented with `indent` spaces per level, keys in their original order.
    public func pretty(indent: Int = 4) -> String {
        var output = ""
        write(to: &output, indent: indent, level: 0)
        return output
    }

    /// No whitespace at all.
    public var minified: String {
        var output = ""
        write(to: &output, indent: nil, level: 0)
        return output
    }

    private func write(to output: inout String, indent: Int?, level: Int) {
        let newline = indent == nil ? "" : "\n"
        func pad(_ level: Int) -> String { indent.map { String(repeating: " ", count: $0 * level) } ?? "" }
        switch self {
        case .object(let members):
            guard !members.isEmpty else { return output += "{}" }
            output += "{" + newline
            for (offset, member) in members.enumerated() {
                output += pad(level + 1) + Self.quote(member.key) + (indent == nil ? ":" : ": ")
                member.value.write(to: &output, indent: indent, level: level + 1)
                output += (offset < members.count - 1 ? "," : "") + newline
            }
            output += pad(level) + "}"
        case .array(let items):
            guard !items.isEmpty else { return output += "[]" }
            output += "[" + newline
            for (offset, item) in items.enumerated() {
                output += pad(level + 1)
                item.write(to: &output, indent: indent, level: level + 1)
                output += (offset < items.count - 1 ? "," : "") + newline
            }
            output += pad(level) + "]"
        case .string(let text): output += Self.quote(text)
        case .number(let text): output += text
        case .bool(let flag): output += flag ? "true" : "false"
        case .null: output += "null"
        }
    }

    static func quote(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }
}
