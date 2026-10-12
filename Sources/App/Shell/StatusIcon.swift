// StatusIcon.swift — the menu-bar icon: a small bird sitting on a perch, drawn in code.
//
// The picture is a "template" image: only its shape matters, and macOS tints it white or black
// to suit the menu bar. It is drawn from paths each time it is needed, so it stays sharp at any
// screen scale and no image file ships with the app.
//
// The orange "a session needs you" dot is NOT part of this picture (a template image cannot
// carry colour). StatusItemController lays a small coloured view over the empty corner above
// the bird's tail; `dotCenter` and `dotRadius` say exactly where.

import AppKit

enum StatusIcon {
    /// Size of the icon in points.
    static let size = CGSize(width: 19, height: 18)
    /// Centre and radius of the attention dot, measured from the icon's bottom-left corner. The
    /// numbers are chosen so the dot lands on whole pixels once the icon is centred in the menu bar.
    static let dotCenter = CGPoint(x: 15.5, y: 14.5)
    static let dotRadius: CGFloat = 2.5

    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Perch"
        return image
    }

    /// Draws the bird in the current graphics context. Points are measured from the bottom-left.
    private static func draw() {
        NSColor.black.set()

        // The perch: a branch across the bottom.
        let perch = NSBezierPath()
        perch.move(to: CGPoint(x: 1.6, y: 3.3))
        perch.line(to: CGPoint(x: 17.4, y: 3.3))
        perch.lineWidth = 1.5
        perch.lineCapStyle = .round
        perch.stroke()

        // Two short legs.
        for x in [8.3, 10.7] as [CGFloat] {
            let leg = NSBezierPath()
            leg.move(to: CGPoint(x: x, y: 5.6))
            leg.line(to: CGPoint(x: x, y: 3.6))
            leg.lineWidth = 1.1
            leg.stroke()
        }

        // Body: an egg shape leaning forward, head end up and to the left.
        let body = NSBezierPath(ovalIn: CGRect(x: -5.2, y: -3.6, width: 10.4, height: 7.2))
        var lean = AffineTransform(translationByX: 9.6, byY: 8.5)
        lean.rotate(byDegrees: -16)
        body.transform(using: lean)
        body.fill()

        // Head.
        NSBezierPath(ovalIn: CGRect(x: 2.7, y: 9.0, width: 5.8, height: 5.8)).fill()

        // Beak, pointing left.
        let beak = NSBezierPath()
        beak.move(to: CGPoint(x: 3.2, y: 13.0))
        beak.line(to: CGPoint(x: 0.5, y: 11.7))
        beak.line(to: CGPoint(x: 3.2, y: 10.7))
        beak.close()
        beak.fill()

        // Tail, sweeping down to the right.
        let tail = NSBezierPath()
        tail.move(to: CGPoint(x: 12.4, y: 9.4))
        tail.line(to: CGPoint(x: 18.2, y: 7.0))
        tail.line(to: CGPoint(x: 17.3, y: 5.2))
        tail.line(to: CGPoint(x: 12.0, y: 6.2))
        tail.close()
        tail.fill()

        // Everything below removes ink instead of adding it.
        NSGraphicsContext.current?.compositingOperation = .destinationOut

        // Eye.
        NSBezierPath(ovalIn: CGRect(x: 4.3, y: 11.6, width: 1.4, height: 1.4)).fill()

        // A sliver of wing, so the body does not read as a plain blob.
        let wing = NSBezierPath()
        wing.move(to: CGPoint(x: 8.0, y: 9.3))
        wing.curve(to: CGPoint(x: 13.4, y: 7.3), controlPoint1: CGPoint(x: 9.8, y: 7.2), controlPoint2: CGPoint(x: 11.8, y: 6.9))
        wing.lineWidth = 0.9
        wing.lineCapStyle = .round
        wing.stroke()
    }
}
