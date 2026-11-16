import SwiftUI
import TableRoadCore

/// TermRoad-family brand tokens (see docs/PLAN.md §8).
/// Source: Bowyer Digital/TermRoad/TermRoad-logo-D.
public enum Brand {
    public static let teal = Color(hex: 0x10302F)
    public static let amber = Color(hex: 0xF2A33A)
    public static let cream = Color(hex: 0xF4EFE6)
    public static let ink = Color(hex: 0x141414)

    /// The app-wide accent colour.
    public static let accent = amber
}

extension Color {
    /// Creates an sRGB colour from a 0xRRGGBB literal.
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension ConnectionTag {
    /// Colour used for the tag dot, window stripe and welcome list badge.
    public var color: Color? {
        switch self {
        case .none: nil
        case .local: Color(hex: 0x8E8E93)
        case .development: Color(hex: 0x34A853)
        case .testing: Color(hex: 0x4A90D9)
        case .staging: Brand.amber
        case .production: Color(hex: 0xE5484D)
        }
    }

    public var label: String {
        switch self {
        case .none: "None"
        case .local: "Local"
        case .development: "Development"
        case .testing: "Testing"
        case .staging: "Staging"
        case .production: "Production"
        }
    }
}
