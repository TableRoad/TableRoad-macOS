import Foundation

/// A single value in a result set, normalised across engines.
public enum CellValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    /// Exact numerics kept as text to avoid precision loss.
    case decimal(String)
    case text(String)
    case bytes(Data)
    case date(Date)
    /// DATE/TIME/DATETIME/TIMESTAMP/YEAR kept as the server's exact text, avoiding time-zone and precision loss.
    case temporal(String)
    case json(String)
    case uuid(UUID)
    case array([CellValue])
    /// A type we don't decode yet; shown as the server's text representation.
    case unsupported(typeName: String, raw: String)

    public var isNull: Bool { self == .null }
}

extension CellValue {
    /// Text shown in the grid. `nil` for NULL so the UI can render its own NULL placeholder.
    public var displayText: String? {
        switch self {
        case .null: nil
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .uint(let value): String(value)
        case .double(let value): String(value)
        case .decimal(let value), .text(let value), .json(let value), .temporal(let value): value
        case .bytes(let data): Self.hexPreview(data)
        case .date(let date): date.formatted(.iso8601)
        case .uuid(let uuid): uuid.uuidString.lowercased()
        case .array(let values): "{" + values.map { $0.displayText ?? "NULL" }.joined(separator: ",") + "}"
        case .unsupported(_, let raw): raw
        }
    }

    /// Whether the grid should right-align the value.
    public var isNumeric: Bool {
        switch self {
        case .int, .uint, .double, .decimal: true
        default: false
        }
    }

    static func hexPreview(_ data: Data, limit: Int = 32) -> String {
        let hex = data.prefix(limit).map { String(format: "%02X", $0) }.joined()
        return "0x" + hex + (data.count > limit ? "… (\(data.count) bytes)" : "")
    }
}
