// SettingsPageInfo.swift — the four pages of the Settings window: their names, icons, colours
// and one-line descriptions, and which page each `SettingsTab` opens.
//
// `SettingsTab` (in the frozen contract) still has its nine historical cases, and the rest of
// the app keeps asking for them: `actions.openSettings(.howItWorks)`. The window itself has four
// pages, so every tab is routed to the page where its subject now lives:
//
//   general, behavior                     → General
//   appearance                            → Look
//   sounds, approvals                     → Sounds & approvals
//   agents, usage, howItWorks, advanced   → Agents & help
//
// The sidebar and the page header both read from here, so a page is described in one place.

import SwiftUI

enum SettingsPageID: String, CaseIterable, Identifiable {
    case general, look, sounds, agents

    var id: String { rawValue }

    /// The page a tab is shown on.
    init(_ tab: SettingsTab) {
        switch tab {
        case .general, .behavior: self = .general
        case .appearance: self = .look
        case .sounds, .approvals: self = .sounds
        case .agents, .usage, .howItWorks, .advanced: self = .agents
        }
    }

    /// The tab the sidebar selects for this page.
    var tab: SettingsTab {
        switch self {
        case .general: return .general
        case .look: return .appearance
        case .sounds: return .sounds
        case .agents: return .agents
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .look: return "Look"
        case .sounds: return "Sounds & approvals"
        case .agents: return "Agents & help"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .look: return "paintpalette.fill"
        case .sounds: return "speaker.wave.2.fill"
        case .agents: return "terminal.fill"
        }
    }

    /// One sentence under the page title saying what the page is for.
    var blurb: String {
        switch self {
        case .general: return "When Perch starts and how the panel opens."
        case .look: return "Colors, the mascot and how lively the notch is."
        case .sounds: return "What you hear, and what you can answer from the notch."
        case .agents: return "Connect your coding agents, and see how Perch works."
        }
    }

    /// The colour of the page's icon tile, taken from the current theme.
    func tint(_ theme: Theme) -> Color {
        switch self {
        case .general: return theme.accent
        case .look: return theme.ask
        case .sounds: return theme.accentAlt
        case .agents: return theme.success
        }
    }
}
