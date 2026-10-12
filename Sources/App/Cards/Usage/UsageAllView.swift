// UsageAllView.swift — the "All" view of the Usage tab: every agent added together, on one card.
//
// Top to bottom: tokens today and their estimated cost → every agent's limit rings in one row →
// one history chart, each day's bar split by model across all agents → the models ranked for
// the chosen range (this list is also the chart's legend) → Perch's own activity in one line.
// Each part appears only when there is something to show.

import SwiftUI

struct UsageAllView: View {
    /// Agents that have numbers, in a fixed order.
    let agents: [AgentUsage]
    let range: UsageTabRange
    let activityDays: [DailyActivity]

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let combined = UsageCombine.combine(agents, range: range, now: Date(), byCost: settings.showCostEstimates)
        let colours = UsageSeriesPalette.colours(combined.series, theme: theme, settings: settings)
        let limited = agents.filter { !$0.windows.isEmpty }
        let hasHistory = combined.days.contains { $0.stacked > 0 }

        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            if combined.today.total > 0 || hasHistory {
                UsageTokenSplit(totals: combined.today, tint: theme.accent, showsKinds: false)
            }
            if !limited.isEmpty {
                UsageLimitsStrip(agents: limited)
            }
            if hasHistory {
                PerchDivider()
                UsageStackChart(combined: combined, range: range, colours: colours)
                UsageModelBreakdown(combined: combined, colours: colours, range: range, showAgents: true)
            }
            if !activityDays.isEmpty {
                PerchDivider()
                UsageActivityRow(days: activityDays, range: range)
            }
        }
        .perchCard()
    }
}

/// The "by model" list under a chart, or a line saying the range has nothing to list.
struct UsageModelBreakdown: View {
    let combined: UsageCombined
    let colours: [Color]
    let range: UsageTabRange
    /// Mark each model with its agent's badge (the "All" view).
    let showAgents: Bool
    /// Projects are listed beside the models (one agent's view).
    var showsProjects = false

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let models = UsageShareRow.models(combined.series, colours: colours, showAgents: showAgents, theme: theme, settings: settings)
        let projects = showsProjects ? UsageShareRow.projects(combined.byProject, tint: models.first?.tint ?? theme.accent) : []
        if models.isEmpty && projects.isEmpty {
            Text("Nothing recorded \(range.phrase) to break down.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.textTertiary)
        } else if projects.isEmpty {
            UsageShareList(title: "By model", rows: models, twoColumns: true)
        } else if models.isEmpty {
            UsageShareList(title: "By project", rows: projects, twoColumns: true)
        } else {
            // Side by side when there is room, otherwise one under the other.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Spacing.xxl) {
                    UsageShareList(title: "By model", rows: models, notesCosts: false).frame(minWidth: 214, idealWidth: 214, maxWidth: .infinity)
                    UsageShareList(title: "By project", rows: projects).frame(minWidth: 214, idealWidth: 214, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    UsageShareList(title: "By model", rows: models)
                    UsageShareList(title: "By project", rows: projects, notesCosts: false)
                }
            }
        }
    }
}
