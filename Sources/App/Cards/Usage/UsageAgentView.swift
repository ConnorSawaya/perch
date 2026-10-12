// UsageAgentView.swift — one agent's view of the Usage tab: everything Perch knows about its
// usage, on one card.
//
// Top to bottom: who it is and when the numbers were last updated → the rate-limit rings →
// today's tokens and estimated cost → its history, each day's bar split by model → where the
// tokens went, by model and by project, for the range picked at the top of the tab → all-time
// totals and the agent's note. Each part appears only when there is data for it.

import SwiftUI

struct UsageAgentView: View {
    let usage: AgentUsage
    let range: UsageTabRange
    /// Used for "updated … ago" when the agent's own numbers carry no time.
    let fallbackUpdated: Date?

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let tint = theme.accent(for: usage.agent, settings: settings)
        let combined = UsageCombine.combine([usage], range: range, now: Date(), byCost: settings.showCostEstimates)
        let colours = UsageSeriesPalette.colours(combined.series, theme: theme, settings: settings)
        let hasHistory = combined.days.contains { $0.stacked > 0 }

        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            header(theme)
            if !usage.windows.isEmpty {
                UsageLimitsView(agent: usage.agent, windows: usage.windows)
            }
            if combined.today.total > 0 || hasHistory {
                UsageTokenSplit(totals: combined.today, tint: tint)
            }
            if hasHistory {
                PerchDivider()
                UsageStackChart(combined: combined, range: range, colours: colours)
                UsageModelBreakdown(combined: combined, colours: colours, range: range, showAgents: false, showsProjects: true)
            }
            footer(theme)
        }
        .perchCard()
    }

    private func header(_ theme: Theme) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            AgentBadge(usage.agent, size: theme.scaled(26))
            Text(usage.agent.displayName)
                .font(theme.font(.headline))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            if let plan = CardsWording.tidy(usage.planName) {
                Chip("\(plan) plan", style: .plain)
            }
            Spacer(minLength: Theme.Spacing.m)
            if let updated = usage.updatedAt ?? fallbackUpdated {
                HStack(spacing: 3) {
                    Text("Updated")
                    PerchElapsedText(since: updated, style: .ago)
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.textTertiary)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func footer(_ theme: Theme) -> some View {
        let note = CardsWording.tidy(usage.note)
        if usage.allTime.total > 0 || note != nil {
            PerchDivider()
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if usage.allTime.total > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Text("All time")
                            .font(theme.font(.label))
                            .foregroundStyle(theme.textSecondary)
                        Text(allTime)
                            .font(theme.font(.caption))
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note {
                    Label(note, systemImage: "info.circle")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var allTime: String {
        var parts = ["\(PerchFormat.count(usage.allTime.total)) tokens"]
        if usage.allTime.messages > 0 { parts.append("\(PerchFormat.count(usage.allTime.messages)) messages") }
        if settings.showCostEstimates, usage.allTime.costUSD > 0 { parts.append("about \(PerchFormat.cost(usage.allTime.costUSD))") }
        return parts.joined(separator: " · ")
    }
}
