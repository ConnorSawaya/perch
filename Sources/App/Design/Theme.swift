// Theme.swift — the colours, fonts, spacing and corner radii every Perch view shares.
//
// How to use it: a view reads `@EnvironmentObject var settings: AppSettings`, asks for
// `Theme.current(settings)` and then uses `theme.surface`, `theme.font(.body)` and so on.
// Nothing is cached in views, so changing the theme or the text size in Settings repaints
// everything at once. The six colour sets themselves live in ThemePalettes.swift.

import SwiftUI

struct Theme {
    let id: ThemeID
    /// Multiplier applied to every font size (AppSettings.textScale, kept inside 0.85...1.3).
    var scale: CGFloat = 1

    // MARK: Backgrounds and lines

    /// The island itself. Always true black so it melts into the physical notch.
    let island: Color
    /// Cards and rows sitting on the island.
    let surface: Color
    /// The same card under the pointer, or a control that should look raised.
    let surfaceHover: Color
    /// Wells that sit lower than a card: code, diffs, text fields.
    let surfaceSunken: Color
    /// Hairlines and card outlines.
    let stroke: Color
    /// Outlines that need to be noticed (focused or selected things).
    let strokeStrong: Color

    // MARK: Text

    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    /// Text drawn on top of the accent gradient (primary buttons, solid chips).
    let textOnAccent: Color

    // MARK: Accent

    let accent: Color
    /// Second stop of the accent gradient.
    let accentAlt: Color

    // MARK: Meaning

    let success: Color
    let warning: Color
    let danger: Color
    let info: Color
    /// "The agent is asking you something" (questions and plans). Approvals use `warning`.
    let ask: Color

    // MARK: Effects

    /// Colours of the rotating glow shown when something needs the user (see GlowBorder).
    let glowColors: [Color]
    /// Colours of the soft moving light behind the panel header (see AuroraHeader).
    let auroraColors: [Color]

    // MARK: Agents

    /// One colour pair per agent, used when AppSettings.useAgentColors is on.
    let agentTints: [AgentKind: AgentTint]

    /// A two-stop colour: `base` for text and icons, `glow` as the gradient partner.
    struct AgentTint {
        let base: Color
        let glow: Color
    }
}

// MARK: - Picking the theme

extension Theme {
    /// The theme chosen in Settings, with the user's text size applied.
    static func current(_ settings: AppSettings) -> Theme {
        var theme = palette(settings.theme)
        theme.scale = CGFloat(min(max(settings.textScale, 0.85), 1.3))
        return theme
    }
}

// MARK: - Derived colours

extension Theme {
    /// The accent gradient used for primary buttons, rings and selected things.
    var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The colour that stands for a session state everywhere in the app.
    func color(for state: SessionState) -> Color {
        switch state {
        case .idle, .ended: return textTertiary
        case .working: return accent
        case .runningTool, .compacting: return info
        case .needsApproval: return warning
        case .needsAnswer, .planReview: return ask
        case .done: return success
        case .failed: return danger
        }
    }

    /// The agent's own colour when "agent colours" is on, otherwise the theme accent.
    func accent(for agent: AgentKind, settings: AppSettings) -> Color {
        guard settings.useAgentColors, let tint = agentTints[agent] else { return accent }
        return tint.base
    }

    /// Gradient partner of `accent(for:settings:)`.
    func accentGlow(for agent: AgentKind, settings: AppSettings) -> Color {
        guard settings.useAgentColors, let tint = agentTints[agent] else { return accentAlt }
        return tint.glow
    }

    /// Colour for a "how full is it" reading (0...100): calm, then warning, then danger.
    func color(forPercent percent: Double, warnAt: Double = 80, calm: Color? = nil) -> Color {
        if percent >= 95 { return danger }
        if percent >= warnAt { return warning }
        return calm ?? accent
    }
}

// MARK: - Fonts

extension Theme {
    /// The named text sizes used across the app. Sizes are in points before `scale` is applied.
    enum TextStyle {
        /// Big numbers and screen titles.
        case display
        /// Card and window titles.
        case title
        /// The main line of a row.
        case headline
        case body
        /// Body text with a little more weight, for labels and buttons.
        case label
        case caption
        /// The smallest readable text: badges, counts, section headers.
        case micro
        /// Code, commands and file paths.
        case mono
        case monoSmall
    }

    func font(_ style: TextStyle) -> Font {
        switch style {
        case .display: return font(size: 22, weight: .semibold, design: .rounded)
        case .title: return font(size: 15, weight: .semibold)
        case .headline: return font(size: 13, weight: .semibold)
        case .body: return font(size: 12.5)
        case .label: return font(size: 12, weight: .medium)
        case .caption: return font(size: 11)
        case .micro: return font(size: 10, weight: .semibold)
        case .mono: return font(size: 11.5, design: .monospaced)
        case .monoSmall: return font(size: 10.5, design: .monospaced)
        }
    }

    /// Any size, with the user's text scale applied. Prefer the named styles above.
    func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: scaled(size), weight: weight, design: design)
    }

    /// Scales a measurement that should grow with the text (icon sizes, row heights).
    func scaled(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.toNearestOrAwayFromZero) }
}

// MARK: - Spacing and corner radii

extension Theme {
    /// Gaps between things. Use these instead of loose numbers so the app keeps one rhythm.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
    }

    enum Radius {
        /// Chips, key caps and other tiny things.
        static let small: CGFloat = 6
        /// Buttons and text fields.
        static let control: CGFloat = 7
        /// Cards and rows.
        static let card: CGFloat = 10
        /// Bottom corners of the collapsed pill (matches the real notch).
        static let pill: CGFloat = 11
        /// Bottom corners of the open panel.
        static let panel: CGFloat = 20
        /// The small outward curve where the island meets the top of the screen.
        static let notchEar: CGFloat = 7
    }
}
