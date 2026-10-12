// MascotView.swift — Perch's little status character. It is what you see in the pill all day.
//
//   MascotView(mood: MascotMood(session.state), size: 18)
//
// There are three styles (Settings → Appearance → Mascot), each drawn in its own file:
//   orb    a living blob of gradient light      (MascotOrb.swift)
//   pixel  a tiny pixel-art bird                (MascotPixel.swift)
//   ring   arcs orbiting a dot                  (MascotRing.swift)
// Every style shows the same five moods through colour, shape and movement, so the state is
// readable at a glance and without relying on colour alone.

import SwiftUI

/// What the mascot should express. Many session states collapse into these five.
enum MascotMood: Equatable, CaseIterable {
    /// Nothing is happening.
    case idle
    /// The agent is thinking or running a tool.
    case busy
    /// The agent is waiting for the user.
    case attention
    /// The last turn finished.
    case done
    /// The last turn ended with an error.
    case failed

    /// The mood for a session state (nil = no session at all).
    init(_ state: SessionState?) {
        switch state {
        case .none, .idle, .ended: self = .idle
        case .working, .runningTool, .compacting: self = .busy
        case .needsApproval, .needsAnswer, .planReview: self = .attention
        case .done: self = .done
        case .failed: self = .failed
        }
    }

    /// Whether this mood is drawn with continuous movement. Calm moods cost nothing to show.
    var isAnimated: Bool { self == .busy || self == .attention }
}

struct MascotView: View {
    private let mood: MascotMood
    private let size: CGFloat
    private let style: MascotStyle?
    private let tint: Color?
    private let tintGlow: Color?

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - size: Width and height in points.
    ///   - style: Forces a style (the Settings preview shows all three). Nil uses the user's choice.
    ///   - tint: Colour for the busy mood, e.g. the agent's colour. Other moods use state colours.
    ///   - tintGlow: Gradient partner of `tint` (e.g. `Theme.accentGlow(for:settings:)`).
    init(mood: MascotMood, size: CGFloat = 18, style: MascotStyle? = nil, tint: Color? = nil, tintGlow: Color? = nil) {
        self.mood = mood
        self.size = size
        self.style = style
        self.tint = tint
        self.tintGlow = tintGlow
    }

    var body: some View {
        let colors = MascotColors(mood: mood, theme: Theme.current(settings), tint: tint, tintGlow: tintGlow)
        Group {
            switch style ?? settings.mascotStyle {
            case .orb: MascotOrb(mood: mood, colors: colors)
            case .pixel: MascotPixel(mood: mood, colors: colors)
            case .ring: MascotRing(mood: mood, colors: colors)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The colours one mood is drawn with, worked out once and shared by the three styles.
struct MascotColors {
    /// Main body colour.
    let primary: Color
    /// Gradient partner / highlights.
    let secondary: Color
    /// Small details drawn on top of the body (eyes, check mark).
    let ink: Color

    init(mood: MascotMood, theme: Theme, tint: Color? = nil, tintGlow: Color? = nil) {
        ink = theme.island
        switch mood {
        case .idle:
            primary = theme.textTertiary
            secondary = theme.textSecondary
        case .busy:
            primary = tint ?? theme.accent
            secondary = tintGlow ?? (tint == nil ? theme.accentAlt : theme.info)
        case .attention:
            primary = theme.warning
            secondary = theme.ask
        case .done:
            primary = theme.success
            secondary = theme.info
        case .failed:
            primary = theme.danger
            secondary = theme.warning
        }
    }
}

/// Tiny symbols the orb and ring styles draw in their centre. `rect` is the box to fit into.
enum MascotMark {
    static func check(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.86))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.16))
        return path
    }

    static func cross(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.14))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.maxY - rect.height * 0.14))
        path.move(to: CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.minY + rect.height * 0.14))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.maxY - rect.height * 0.14))
        return path
    }

    /// An exclamation mark: a bar and a dot (the dot is a tiny line; round caps make it round).
    static func bang(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.06))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.56))
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.93))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.94))
        return path
    }
}
