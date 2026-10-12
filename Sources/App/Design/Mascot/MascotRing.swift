// MascotRing.swift — the "ring" mascot: arcs orbiting a centre, like a tiny instrument dial.
//
// How each mood looks:
//   idle       one thin, dim ring with a dot — nothing moving
//   busy       two arcs circling in opposite directions around a dot
//   attention  two short arcs spinning quickly around an "!"
//   done       a complete ring around a check mark
//   failed     a broken (dashed) ring around a cross

import SwiftUI

struct MascotRing: View {
    let mood: MascotMood
    let colors: MascotColors

    var body: some View {
        PerchClock(fps: 30, isRunning: mood.isAnimated) { time in
            Canvas { context, size in
                draw(&context, size: size, time: time)
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let line = max(1.5, radius * 0.2)
        let outer = radius - line / 2 - radius * 0.06
        let inner = outer * 0.56
        let round = StrokeStyle(lineWidth: line, lineCap: .round)

        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
        }
        func arc(_ r: CGFloat, from start: Double, sweep: Double) -> Path {
            var path = Path()
            path.addArc(center: centre, radius: r, startAngle: .radians(start), endAngle: .radians(start + sweep), clockwise: false)
            return path
        }
        func markBox(_ scale: CGFloat) -> CGRect {
            let side = outer * scale
            return CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        }

        switch mood {
        case .idle:
            context.stroke(circle(outer), with: .color(colors.primary.opacity(0.55)), lineWidth: line * 0.7)
            context.fill(circle(radius * 0.16), with: .color(colors.primary))

        case .busy:
            context.stroke(circle(outer), with: .color(colors.primary.opacity(0.18)), lineWidth: line)
            // Start angles are offset so the frozen frame is not symmetrical.
            context.stroke(arc(outer, from: time * 3.2 - 0.6, sweep: 2.0), with: .color(colors.primary), style: round)
            context.stroke(arc(inner, from: -time * 4.4 + 2.2, sweep: 1.5), with: .color(colors.secondary), style: round)
            context.fill(circle(radius * 0.13), with: .color(colors.primary))

        case .attention:
            context.stroke(circle(outer), with: .color(colors.primary.opacity(0.2)), lineWidth: line)
            let spin = time * 5.5 + 0.5
            context.stroke(arc(outer, from: spin, sweep: 1.1), with: .color(colors.primary), style: round)
            context.stroke(arc(outer, from: spin + .pi, sweep: 1.1), with: .color(colors.secondary), style: round)
            context.stroke(MascotMark.bang(in: markBox(0.95)), with: .color(colors.primary), style: round)

        case .done:
            context.stroke(circle(outer), with: .color(colors.primary), lineWidth: line)
            context.stroke(MascotMark.check(in: markBox(0.8)), with: .color(colors.primary),
                           style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))

        case .failed:
            let dash = outer * 0.62
            context.stroke(circle(outer), with: .color(colors.primary.opacity(0.75)),
                           style: StrokeStyle(lineWidth: line, lineCap: .round, dash: [dash, dash * 0.75]))
            context.stroke(MascotMark.cross(in: markBox(0.72)), with: .color(colors.primary), style: round)
        }
    }
}
