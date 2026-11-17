import SwiftUI
import TableRoadCore

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

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

    /// A colour that switches with the appearance (light / dark mode).
    public init(light: UInt32, dark: UInt32) {
        #if canImport(AppKit)
            self.init(
                nsColor: NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    return NSColor(Color(hex: isDark ? dark : light))
                })
        #elseif canImport(UIKit)
            self.init(
                uiColor: UIColor { traits in
                    UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
                })
        #else
            self.init(hex: light)
        #endif
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

extension StatusColor {
    /// Soft fill for swatches and the connection pill.
    public var swatch: Color? {
        switch self {
        case .none: nil
        // Pastel in light mode; deep, muted tints in dark mode so light text stays readable.
        case .green: Color(light: 0xD6EBC4, dark: 0x2F4A27)
        case .gray: Color(light: 0xC4C4C4, dark: 0x48484C)
        case .blue: Color(light: 0xC4CFF4, dark: 0x2C3A63)
        case .yellow: Color(light: 0xF5F0BE, dark: 0x4D4520)
        case .red: Color(light: 0xF5D0CC, dark: 0x5C2C2A)
        }
    }

    /// Stronger shade for thin accents (window stripe, list dot).
    public var accent: Color? {
        switch self {
        case .none: nil
        case .green: Color(hex: 0x5BAA3C)
        case .gray: Color(hex: 0x8E8E93)
        case .blue: Color(hex: 0x4F6FD9)
        case .yellow: Color(hex: 0xD9B91F)
        case .red: Color(hex: 0xE5484D)
        }
    }

    public var label: String {
        switch self {
        case .none: "None"
        case .green: "Green"
        case .gray: "Gray"
        case .blue: "Blue"
        case .yellow: "Yellow"
        case .red: "Red"
        }
    }
}

extension ConnectionProfile {
    /// The colour shown for this connection: the explicit status colour, else the tag's colour.
    public var displayAccent: Color? { statusColor.accent ?? tag.color }
}
