// IslandShape.swift — the outline of the island: a notch that can grow into a panel.
//
// The shape hangs from the top edge of the screen. Its top corners curve OUTWARD (like the real
// MacBook notch, where black flows into the screen edge) and its bottom corners are rounded.
// The body fills the rectangle it is given; the two little outward curves ("ears") stick out
// past the left and right edges by `topRadius`.
//
// Both radii are animatable, and the size animates with the view's frame, so the same shape
// morphs smoothly between the small pill and the open panel.

import SwiftUI

struct IslandShape: Shape {
    /// Radius of the outward curve where the island meets the top of the screen.
    var topRadius: CGFloat
    /// Radius of the two rounded bottom corners.
    var bottomRadius: CGFloat
    /// False leaves the top edge open — use that for strokes and glows so no line is drawn
    /// along the top of the screen.
    var closed = true

    init(topRadius: CGFloat = Theme.Radius.notchEar, bottomRadius: CGFloat = Theme.Radius.pill, closed: Bool = true) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.closed = closed
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Keep the radii sane for any size, so a tiny or mid-animation frame never breaks the path.
        let ear = max(0, min(topRadius, rect.height / 2, rect.width / 2))
        let corner = max(0, min(bottomRadius, rect.height - ear, rect.width / 2))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX - ear, y: rect.minY))
        // Left ear: curve from the screen edge down into the left side.
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY + ear), radius: ear)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - corner))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + corner, y: rect.maxY), radius: corner)
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - corner), radius: corner)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + ear))
        // Right ear: curve from the right side back out to the screen edge.
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX + ear, y: rect.minY), radius: ear)
        if closed { path.closeSubpath() }
        return path
    }
}
