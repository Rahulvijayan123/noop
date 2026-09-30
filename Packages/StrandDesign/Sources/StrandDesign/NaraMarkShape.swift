import SwiftUI

/// The Nara mark as a single fillable shape (the "N" plus the node cross), fitted to the largest square
/// inside `rect` and centred.
public struct NaraMarkShape: Shape {
    public init() {}

    /// Master artwork grid. All coordinates below are in these units.
    static let grid: CGFloat = 153

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let s = side / Self.grid
        let ox = rect.minX + (rect.width - side) / 2
        let oy = rect.minY + (rect.height - side) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGRect {
            CGRect(x: ox + (cx - r) * s, y: oy + (cy - r) * s, width: 2 * r * s, height: 2 * r * s)
        }

        var path = Path()

        // The "N": stem, diagonal band and foot as one outline.
        path.addLines([
            p(2.5, 28), p(18.5, 28), p(119.5, 129), p(125.5, 129), p(125.5, 153),
            p(103.5, 153), p(9.5, 59), p(9.5, 153), p(2.5, 153),
        ])
        path.closeSubpath()

        // The node cross: hairline arms, four end nodes, one hub.
        let arm: CGFloat = 2.8
        let hub = CGPoint(x: 120, y: 31)
        path.addRect(CGRect(x: ox + (hub.x - arm / 2) * s, y: oy + 5.5 * s, width: arm * s, height: 93.5 * s))
        path.addRect(CGRect(x: ox + 60 * s, y: oy + (hub.y - arm / 2) * s, width: 85.5 * s, height: arm * s))
        for (cx, cy) in [(hub.x, 5.5), (hub.x, 99), (60, hub.y), (145.5, hub.y)] as [(CGFloat, CGFloat)] {
            path.addEllipse(in: dot(cx, cy, 5.5))
        }
        path.addEllipse(in: dot(hub.x, hub.y, 11))
        return path
    }
}
