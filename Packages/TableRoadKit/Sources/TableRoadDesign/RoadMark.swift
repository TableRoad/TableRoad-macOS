import SwiftUI

/// The TableRoad mark without its icon tile: amber diamond road sign with the fading table glyph.
/// Geometry matches the app icon (100×100 design grid).
public struct RoadMark: View {
    var size: CGFloat

    public init(size: CGFloat = 96) {
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let unit = canvasSize.width / 100
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * unit, y: y * unit, width: w * unit, height: h * unit)
            }

            // Diamond: a 52×52 rounded square rotated 45° about the centre.
            var diamond = context
            diamond.translateBy(x: 50 * unit, y: 50 * unit)
            diamond.rotate(by: .degrees(45))
            diamond.translateBy(x: -50 * unit, y: -50 * unit)
            diamond.stroke(
                Path(roundedRect: rect(24, 24, 52, 52), cornerRadius: 10 * unit),
                with: .color(Brand.amber),
                lineWidth: 6 * unit
            )

            // Table glyph: header bar, then rows fading out like TermRoad's cursor blocks.
            let cream = GraphicsContext.Shading.color(Brand.cream)
            context.fill(Path(roundedRect: rect(35, 37, 30, 6), cornerRadius: 2 * unit), with: cream)
            let rows: [(y: CGFloat, leftX: CGFloat, leftW: CGFloat, rightW: CGFloat, opacity: Double)] = [
                (46, 35, 9, 19, 1), (53, 35, 9, 19, 0.7), (60, 38, 6, 16, 0.4),
            ]
            for row in rows {
                var faded = context
                faded.opacity = row.opacity
                faded.fill(
                    Path(roundedRect: rect(row.leftX, row.y, row.leftW, 4), cornerRadius: 1.5 * unit), with: cream)
                faded.fill(Path(roundedRect: rect(46, row.y, row.rightW, 4), cornerRadius: 1.5 * unit), with: cream)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview("Road mark") {
    HStack(spacing: 20) {
        RoadMark(size: 32)
        RoadMark(size: 96)
        RoadMark(size: 160)
    }
    .padding()
    .background(Brand.teal)
}
