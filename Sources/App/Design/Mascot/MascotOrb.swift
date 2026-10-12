// MascotOrb.swift — the "orb" mascot: a living blob of gradient light.
//
// How each mood looks:
//   idle       small, grey, perfectly still
//   busy       wobbles and swirls in the accent (or agent) colour
//   attention  wobbles faster in the warning colour, sends out rings and shows "!"
//   done       calm round ball in the success colour with a check mark
//   failed     lopsided, in the danger colour, with a cross
// Everything is drawn in one small Canvas; only that canvas redraws while it animates.

import SwiftUI

struct MascotOrb: View {
    let mood: MascotMood
    let colors: MascotColors

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let glow = settings.showGlow
        PerchClock(fps: 24, isRunning: mood.isAnimated) { time in
            Canvas { context, size in
                draw(&context, size: size, time: time, glow: glow)
            }
        }
    }

    /// How lively each mood is: body size (fraction of the radius), wobble depth and speed.
    private var shape: (body: CGFloat, wobble: CGFloat, speed: Double) {
        switch mood {
        case .idle: return (0.52, 0.0, 0)
        case .busy: return (0.7, 0.1, 2.6)
        case .attention: return (0.64, 0.13, 4.2)
        case .done: return (0.7, 0.0, 0)
        case .failed: return (0.66, 0.09, 0)
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: TimeInterval, glow: Bool) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let bodyRadius = radius * shape.body
        // Offset the clock so the frozen frame (time 0) is a pleasant asymmetric pose.
        let clock = time * shape.speed + 0.9

        if glow && mood != .idle {
            let halo = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            context.fill(halo, with: .radialGradient(
                Gradient(colors: [colors.primary.opacity(0.5), colors.primary.opacity(0)]),
                center: centre, startRadius: bodyRadius * 0.7, endRadius: radius))
        }

        if mood == .attention {
            // A ring that keeps leaving the orb: "over here".
            let progress = CGFloat((time / 1.2 + 0.45).truncatingRemainder(dividingBy: 1))
            let ringRadius = bodyRadius + (radius - bodyRadius) * progress
            let ring = Path(ellipseIn: CGRect(x: centre.x - ringRadius, y: centre.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
            context.stroke(ring, with: .color(colors.primary.opacity(0.8 * Double(1 - progress))), lineWidth: max(1, radius * 0.1))
        }

        let blob = blobPath(centre: centre, radius: bodyRadius, clock: clock)
        let tilt = clock * 0.35
        let reach = CGPoint(x: CGFloat(cos(tilt)) * bodyRadius, y: CGFloat(sin(tilt)) * bodyRadius)
        context.fill(blob, with: .linearGradient(
            Gradient(colors: [colors.secondary, colors.primary]),
            startPoint: CGPoint(x: centre.x - reach.x, y: centre.y - reach.y),
            endPoint: CGPoint(x: centre.x + reach.x, y: centre.y + reach.y)))

        if mood != .idle {
            // Soft light moving around inside the body makes it look liquid.
            context.drawLayer { layer in
                layer.clip(to: blob)
                layer.addFilter(.blur(radius: bodyRadius * 0.3))
                let orbit = bodyRadius * 0.38
                let spot = CGPoint(x: centre.x + CGFloat(cos(clock * 1.3)) * orbit, y: centre.y + CGFloat(sin(clock * 1.3)) * orbit)
                let spotRadius = bodyRadius * 0.45
                layer.fill(Path(ellipseIn: CGRect(x: spot.x - spotRadius, y: spot.y - spotRadius, width: spotRadius * 2, height: spotRadius * 2)),
                           with: .color(.white.opacity(0.42)))
            }
        }

        // A fixed glint at the top-left, as if lit from above.
        let glint = CGRect(x: centre.x - bodyRadius * 0.55, y: centre.y - bodyRadius * 0.62, width: bodyRadius * 0.5, height: bodyRadius * 0.34)
        context.fill(Path(ellipseIn: glint), with: .color(.white.opacity(mood == .idle ? 0.25 : 0.5)))

        drawMark(&context, centre: centre, bodyRadius: bodyRadius)
    }

    private func drawMark(_ context: inout GraphicsContext, centre: CGPoint, bodyRadius: CGFloat) {
        let side = bodyRadius * 0.95
        let box = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        let mark: Path
        switch mood {
        case .done: mark = MascotMark.check(in: box)
        case .failed: mark = MascotMark.cross(in: box)
        case .attention: mark = MascotMark.bang(in: box)
        case .idle, .busy: return
        }
        context.stroke(mark, with: .color(colors.ink.opacity(0.85)),
                       style: StrokeStyle(lineWidth: max(1.2, bodyRadius * 0.24), lineCap: .round, lineJoin: .round))
    }

    /// A closed, smooth, slightly irregular outline. Each of the seven control points moves in
    /// and out on its own rhythm, which is what makes the orb look alive.
    private func blobPath(centre: CGPoint, radius: CGFloat, clock: Double) -> Path {
        let count = 7
        let points: [CGPoint] = (0..<count).map { index in
            let angle = Double(index) / Double(count) * 2 * .pi + clock * 0.25
            let reach = radius * (1 + shape.wobble * CGFloat(sin(clock + Double(index) * 2.4)))
            return CGPoint(x: centre.x + CGFloat(cos(angle)) * reach, y: centre.y + CGFloat(sin(angle)) * reach)
        }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

        // Curve from midpoint to midpoint using each point as the control: always smooth.
        // The control points sit outside the curve, so push them out a little to keep the size.
        let swollen = points.map { CGPoint(x: centre.x + ($0.x - centre.x) * 1.12, y: centre.y + ($0.y - centre.y) * 1.12) }
        var path = Path()
        path.move(to: midpoint(swollen[count - 1], swollen[0]))
        for index in 0..<count {
            path.addQuadCurve(to: midpoint(swollen[index], swollen[(index + 1) % count]), control: swollen[index])
        }
        path.closeSubpath()
        return path
    }
}
