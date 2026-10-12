// ThemePalettes.swift — the six colour sets a user can pick in Settings → Appearance.
//
// Every palette keeps the island true black (so it merges with the notch) and changes the tint
// of the cards, the text greys, the accent gradient and the glow. To add a theme: add a case to
// ThemeID, write one more `static let` here and list it in `palette(_:)`.

import SwiftUI

extension Theme {
    /// The colour set for a theme id (text scale 1.0).
    static func palette(_ id: ThemeID) -> Theme {
        switch id {
        case .midnight: return midnight
        case .aurora: return aurora
        case .ember: return ember
        case .synthwave: return synthwave
        case .forest: return forest
        case .mono: return mono
        }
    }

    /// Graphite with one calm blue accent. The default.
    private static let midnight = Theme(
        id: .midnight,
        island: .black, surface: Color(hex: 0x151516), surfaceHover: Color(hex: 0x1E1E20), surfaceSunken: Color(hex: 0x0C0C0D),
        stroke: Color.white.opacity(0.07), strokeStrong: Color.white.opacity(0.14),
        textPrimary: Color(hex: 0xF2F2F3), textSecondary: Color(hex: 0xA0A0A6), textTertiary: Color(hex: 0x6C6C72),
        textOnAccent: .white,
        accent: Color(hex: 0x3F8CFF), accentAlt: Color(hex: 0x3F8CFF),
        success: Color(hex: 0x4BBF8A), warning: Color(hex: 0xF0A63A), danger: Color(hex: 0xE5595D),
        info: Color(hex: 0x5AA5E8), ask: Color(hex: 0x7FA8F5),
        glowColors: [Color(hex: 0xF0A63A)],
        auroraColors: [],
        agentTints: colourfulAgents)

    /// Northern lights: mint → sky accent over teal-tinted cards.
    private static let aurora = Theme(
        id: .aurora,
        island: .black, surface: Color(hex: 0x0F181A), surfaceHover: Color(hex: 0x172427), surfaceSunken: Color(hex: 0x080E0F),
        stroke: Color(hex: 0xBFFFF0).opacity(0.09), strokeStrong: Color(hex: 0xBFFFF0).opacity(0.2),
        textPrimary: Color(hex: 0xF0FBF8), textSecondary: Color(hex: 0x9FB9B6), textTertiary: Color(hex: 0x5F7C7A),
        textOnAccent: Color(hex: 0x03201A),
        accent: Color(hex: 0x3EE6B4), accentAlt: Color(hex: 0x3EE6B4),
        success: Color(hex: 0x9BE86B), warning: Color(hex: 0xFFC857), danger: Color(hex: 0xFF7A85),
        info: Color(hex: 0x5CC8FF), ask: Color(hex: 0xC6A0FF),
        glowColors: [Color(hex: 0xFFC857)],
        auroraColors: [],
        agentTints: colourfulAgents)

    /// Warm coals: orange → rose accent over brown-tinted cards.
    private static let ember = Theme(
        id: .ember,
        island: .black, surface: Color(hex: 0x1A1410), surfaceHover: Color(hex: 0x261D17), surfaceSunken: Color(hex: 0x0E0A08),
        stroke: Color(hex: 0xFFE2C8).opacity(0.09), strokeStrong: Color(hex: 0xFFE2C8).opacity(0.2),
        textPrimary: Color(hex: 0xFCF6F0), textSecondary: Color(hex: 0xC0AD9E), textTertiary: Color(hex: 0x806F62),
        textOnAccent: Color(hex: 0x2A0D05),
        accent: Color(hex: 0xFF9454), accentAlt: Color(hex: 0xFF9454),
        success: Color(hex: 0x86D991), warning: Color(hex: 0xFFD166), danger: Color(hex: 0xFF5C5C),
        info: Color(hex: 0x7CC4F0), ask: Color(hex: 0xE5A0FF),
        glowColors: [Color(hex: 0xFFD166)],
        auroraColors: [],
        agentTints: colourfulAgents)

    /// Neon night drive: hot pink → cyan accent over purple-tinted cards.
    private static let synthwave = Theme(
        id: .synthwave,
        island: .black, surface: Color(hex: 0x171124), surfaceHover: Color(hex: 0x221A33), surfaceSunken: Color(hex: 0x0C0815),
        stroke: Color(hex: 0xE9C8FF).opacity(0.1), strokeStrong: Color(hex: 0xE9C8FF).opacity(0.22),
        textPrimary: Color(hex: 0xF9F1FF), textSecondary: Color(hex: 0xB7A5D1), textTertiary: Color(hex: 0x776793),
        textOnAccent: Color(hex: 0x1B0224),
        accent: Color(hex: 0xFF5FDC), accentAlt: Color(hex: 0xFF5FDC),
        success: Color(hex: 0x3DFFB0), warning: Color(hex: 0xFFE45C), danger: Color(hex: 0xFF5C8A),
        info: Color(hex: 0x3DE8FF), ask: Color(hex: 0xB98CFF),
        glowColors: [Color(hex: 0xFFE45C)],
        auroraColors: [],
        agentTints: colourfulAgents)

    /// Moss and pine: leaf green → lime accent over green-tinted cards.
    private static let forest = Theme(
        id: .forest,
        island: .black, surface: Color(hex: 0x111812), surfaceHover: Color(hex: 0x19241B), surfaceSunken: Color(hex: 0x090D0A),
        stroke: Color(hex: 0xD6FFD0).opacity(0.09), strokeStrong: Color(hex: 0xD6FFD0).opacity(0.2),
        textPrimary: Color(hex: 0xF2F8EF), textSecondary: Color(hex: 0xA6BAA2), textTertiary: Color(hex: 0x687C65),
        textOnAccent: Color(hex: 0x0B2010),
        accent: Color(hex: 0x6FD98A), accentAlt: Color(hex: 0x6FD98A),
        success: Color(hex: 0xA5EC6A), warning: Color(hex: 0xF2C14E), danger: Color(hex: 0xF0736A),
        info: Color(hex: 0x6EC3D9), ask: Color(hex: 0xC9A8F5),
        glowColors: [Color(hex: 0xF2C14E)],
        auroraColors: [],
        agentTints: colourfulAgents)

    /// Graphite: no colour at all except soft pastels where meaning needs it.
    private static let mono = Theme(
        id: .mono,
        island: .black, surface: Color(hex: 0x151515), surfaceHover: Color(hex: 0x202020), surfaceSunken: Color(hex: 0x0B0B0B),
        stroke: Color.white.opacity(0.09), strokeStrong: Color.white.opacity(0.22),
        textPrimary: Color(hex: 0xF5F5F5), textSecondary: Color(hex: 0xA8A8A8), textTertiary: Color(hex: 0x6E6E6E),
        textOnAccent: Color(hex: 0x0A0A0A),
        accent: Color(hex: 0xF2F2F2), accentAlt: Color(hex: 0xF2F2F2),
        success: Color(hex: 0xB5E3C3), warning: Color(hex: 0xEBD9A0), danger: Color(hex: 0xF0A3A3),
        info: Color(hex: 0xC9D3E0), ask: Color(hex: 0xD3C6EA),
        glowColors: [Color(hex: 0xEBD9A0)],
        auroraColors: [],
        agentTints: [
            .claude: AgentTint(base: Color(hex: 0xF0F0F0), glow: Color(hex: 0xBDBDBD)),
            .codex: AgentTint(base: Color(hex: 0xCFCFCF), glow: Color(hex: 0x9A9A9A)),
            .antigravity: AgentTint(base: Color(hex: 0xB0B0B0), glow: Color(hex: 0x808080)),
            .gemini: AgentTint(base: Color(hex: 0x959595), glow: Color(hex: 0x6A6A6A)),
        ])

    /// Agent colours shared by every colourful theme, so "the orange one" stays the same agent.
    /// These are Perch's own picks, not vendor brand colours.
    private static let colourfulAgents: [AgentKind: AgentTint] = [
        .claude: AgentTint(base: Color(hex: 0xF0895F), glow: Color(hex: 0xF7B267)),
        .codex: AgentTint(base: Color(hex: 0x35D6B5), glow: Color(hex: 0x86EFAC)),
        .antigravity: AgentTint(base: Color(hex: 0xA590FF), glow: Color(hex: 0xE08CFF)),
        .gemini: AgentTint(base: Color(hex: 0x56A8FF), glow: Color(hex: 0x6FE3FF)),
    ]
}

private extension Color {
    /// 0xRRGGBB → Color. Private to this file: every other file should use Theme colours.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
