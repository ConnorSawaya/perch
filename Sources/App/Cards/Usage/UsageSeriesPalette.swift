// UsageSeriesPalette.swift — the colour of each entry in the stacked chart and its legend.
//
// A colour family is two related colours (an agent's colour and its lighter partner, or the
// theme's two accent colours) at falling strengths: full, full, medium, medium, faint, faint.
// With several agents and "agent colours" on, an entry takes the next step of its own agent's
// family: orange and amber are both Claude, teal and green both Codex. When agents cannot be
// told apart that way (one agent only, or agent colours off) every entry takes the next step of
// one family, biggest first. The grey theme has no second colour to lean on, so there it is one
// grey at evenly falling strengths. The legend names every entry, so nothing depends on colour alone.

import SwiftUI

enum UsageSeriesPalette {
    /// Strengths of a two-colour family, by step.
    private static let pairSteps: [Double] = [1, 0.95, 0.58, 0.54, 0.3, 0.28]
    /// Strengths of a single colour, by step.
    private static let soloSteps: [Double] = [1, 0.7, 0.48, 0.32, 0.2, 0.12]

    /// One colour per entry of `series`, in the same order.
    static func colours(_ series: [UsageSeries], theme: Theme, settings: AppSettings) -> [Color] {
        let agents = Set(series.compactMap(\.agent))
        func family(_ agent: AgentKind?) -> (Color, Color) {
            guard let agent else { return (theme.accent, theme.accentAlt) }
            return (theme.accent(for: agent, settings: settings), theme.accentGlow(for: agent, settings: settings))
        }
        func step(_ index: Int, of family: (Color, Color)) -> Color {
            let index = min(index, pairSteps.count - 1)
            if theme.id == .mono { return family.0.opacity(soloSteps[index]) }
            return (index % 2 == 0 ? family.0 : family.1).opacity(pairSteps[index])
        }
        if agents.count > 1, settings.useAgentColors, theme.id != .mono {
            return series.map { entry in
                entry.agent.map { step(entry.shade, of: family($0)) } ?? theme.textTertiary.opacity(0.75)
            }
        }
        let shared = family(agents.count == 1 ? agents.first : nil)
        return series.indices.map { step($0, of: shared) }
    }
}
