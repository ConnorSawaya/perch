// AgentBadge.swift — the small square that says which coding agent a session belongs to.
//
// When the agent's desktop app is installed, the badge shows that app's own icon, fetched from
// macOS at run time by AgentIconProvider (Perch itself contains no vendor artwork). Otherwise it
// shows a monogram drawn here in code, in the agent's colour (when "agent colours" is on):
// simple geometric letterforms of Perch's own design, deliberately not any vendor's logo.
//   Claude Code  → an open "C" with a cursor dot
//   Codex        → an "X" made of two facing angle brackets
//   Antigravity  → an "A" whose crossbar floats free as a dot
//   Gemini CLI   → a "G"
// Pass `state` to add the session's StateDot to the corner.

import SwiftUI

struct AgentBadge: View {
    private let agent: AgentKind
    private let size: CGFloat
    private let state: SessionState?
    private let backdrop: Color?

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - size: Side of the square in points.
    ///   - state: When given, a StateDot is shown on the bottom-right corner.
    ///   - backdrop: Colour behind the badge, used to "cut out" the dot. Defaults to the card colour.
    init(_ agent: AgentKind, size: CGFloat = 28, state: SessionState? = nil, backdrop: Color? = nil) {
        self.agent = agent
        self.size = size
        self.state = state
        self.backdrop = backdrop
    }

    var body: some View {
        let theme = Theme.current(settings)
        let tint = theme.accent(for: agent, settings: settings)
        let glow = theme.accentGlow(for: agent, settings: settings)
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        let gradient = LinearGradient(colors: [glow, tint], startPoint: .topLeading, endPoint: .bottomTrailing)

        ZStack {
            shape.fill(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.1)], startPoint: .top, endPoint: .bottom))
            if let icon = AgentIconProvider.shared.icon(for: agent) {
                Image(decorative: icon, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                AgentGlyph(agent: agent)
                    .stroke(gradient, style: StrokeStyle(lineWidth: max(1.5, size * 0.1), lineCap: .round, lineJoin: .round))
                    .padding(size * 0.06)
            }
            shape.strokeBorder(tint.opacity(0.38), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let state {
                let dot = max(7, size * 0.3)
                StateDot(state, size: dot)
                    .padding(2)
                    .background(Circle().fill(backdrop ?? theme.surface))
                    .offset(x: dot * 0.32, y: dot * 0.32)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(agent.displayName)
    }
}

/// The monogram for one agent as a stroked path. Coordinates are fractions of the badge side.
struct AgentGlyph: Shape {
    let agent: AgentKind

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * side, y: origin.y + y * side) }
        // A dot is a tiny line; the round line caps turn it into a circle as wide as the stroke.
        func dot(_ path: inout Path, _ x: CGFloat, _ y: CGFloat) {
            path.move(to: point(x - 0.005, y))
            path.addLine(to: point(x + 0.005, y))
        }

        var path = Path()
        switch agent {
        case .claude:
            path.addArc(center: point(0.5, 0.5), radius: side * 0.27, startAngle: .degrees(48), endAngle: .degrees(312), clockwise: false)
            dot(&path, 0.56, 0.5)
        case .codex:
            path.move(to: point(0.25, 0.26))
            path.addLine(to: point(0.44, 0.5))
            path.addLine(to: point(0.25, 0.74))
            path.move(to: point(0.75, 0.26))
            path.addLine(to: point(0.56, 0.5))
            path.addLine(to: point(0.75, 0.74))
        case .antigravity:
            path.move(to: point(0.24, 0.76))
            path.addLine(to: point(0.5, 0.24))
            path.addLine(to: point(0.76, 0.76))
            dot(&path, 0.5, 0.66)
        case .gemini:
            path.move(to: point(0.53, 0.52))
            path.addLine(to: point(0.77, 0.52))
            path.addArc(center: point(0.5, 0.5), radius: side * 0.27, startAngle: .degrees(4), endAngle: .degrees(312), clockwise: false)
        }
        return path
    }
}
