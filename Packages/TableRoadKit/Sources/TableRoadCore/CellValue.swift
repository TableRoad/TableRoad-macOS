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
    case json(String)
    case uuid(UUID)
    case array([CellValue])
    /// A type we don't decode yet; shown as the server's text representation.
    case unsupported(typeName: String, raw: String)

    public var isNull: Bool { self == .null }
}
