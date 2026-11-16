import SwiftUI

/// "Table" + "Road" wordmark, matching the TermRoad lockup.
public struct Wordmark: View {
    var size: CGFloat
    var onDark: Bool

    public init(size: CGFloat = 32, onDark: Bool = true) {
        self.size = size
        self.onDark = onDark
    }

    public var body: some View {
        (Text("Table").foregroundStyle(onDark ? Brand.cream : Brand.ink)
            + Text("Road").foregroundStyle(Brand.amber))
            .font(BrandFont.display(size: size))
            .tracking(-size / 58)
            .accessibilityLabel("TableRoad")
    }
}

/// Brand typeface helper. Space Grotesk is used for the wordmark and display headings only;
/// UI text stays on the system font.
public enum BrandFont {
    public static func display(size: CGFloat) -> Font {
        .custom("Space Grotesk", size: size, relativeTo: .largeTitle).weight(.semibold)
    }
}
