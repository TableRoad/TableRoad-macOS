import Foundation

/// Formatting helpers for the row inspector.
public enum ValueFormatting {
    /// Pretty-printed JSON with sorted keys (stable and readable), or nil if `text` isn't valid JSON.
    public static func prettyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    /// Why `text` isn't valid JSON, or nil if it is.
    public static func jsonError(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return "Not UTF-8" }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return nil
        } catch {
            let message = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            return message ?? "Invalid JSON"
        }
    }

    /// Classic hex dump: offset, 16 hex bytes, ASCII. Stops after `limit` bytes.
    public static func hexDump(_ data: Data, limit: Int = 4096) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data.prefix(limit))
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = String(chunk.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08X", offset) + "  " + padded + "  " + ascii)
        }
        if data.count > limit {
            lines.append("… \(data.count - limit) more bytes")
        }
        return lines.joined(separator: "\n")
    }

    /// "12 KB" style size.
    public static func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
