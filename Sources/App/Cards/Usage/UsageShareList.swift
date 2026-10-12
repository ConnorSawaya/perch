// UsageShareList.swift — a short ranked list: which models, or which projects, the tokens went to.
//
//   BY MODEL                                                    costs are estimates
//   ■ ▣ gpt-5.5-codex        ▬▬▬▬▬▬▬▬▬▬▬▬      25.2M · $33.76   37%
//   ■ ▣ claude-opus-5-5      ▬▬▬▬▬▬▬▬▬▬▬▬      25.1M · $33.66   37%
//
// One line per row. In the "by model" list the square is the row's colour in the chart above,
// so the list is also the chart's legend; with several agents a small agent badge says whose
// model it is. The list fits itself to its width: two columns when both fit side by side,
// otherwise one column, which drops first the little bar and then the cost (still in the
// tooltip) rather than cutting names short.

import SwiftUI

/// One row of a UsageShareList.
struct UsageShareRow: Identifiable {
    var id: String
    var name: String
    /// The full name, for the tooltip.
    var help: String
    var totals: TokenTotals
    var fraction: Double
    /// Colour of the bar behind the row.
    var tint: Color
    /// The row's colour in the chart, when it has one.
    var swatch: Color?
    var agent: AgentKind?
}

extension UsageShareRow {
    /// Rows for the "by model" list: every entry that used anything in the range.
    static func models(_ series: [UsageSeries], colours: [Color], showAgents: Bool, theme: Theme, settings: AppSettings) -> [UsageShareRow] {
        series.enumerated().compactMap { index, entry in
            guard entry.totals.total > 0 else { return nil }
            let agentName = entry.agent.map { " (\($0.displayName))" } ?? ""
            let help = entry.agent == nil
                ? (entry.folded > 0 ? "\(CardsWording.counted(entry.folded, "smaller model")) added together" : "Tokens the agent's files do not put under a model")
                : entry.model + agentName
            return UsageShareRow(id: entry.id, name: UsageTabMath.displayName(entry.model), help: help, totals: entry.totals, fraction: entry.fraction,
                                 tint: entry.agent.map { theme.accent(for: $0, settings: settings) } ?? theme.textSecondary,
                                 swatch: colours.indices.contains(index) ? colours[index] : nil,
                                 agent: showAgents ? entry.agent : nil)
        }
    }

    static func projects(_ shares: [UsageTabShare], tint: Color) -> [UsageShareRow] {
        shares.map {
            UsageShareRow(id: $0.id, name: UsageTabMath.displayName($0.name), help: $0.name, totals: $0.totals, fraction: $0.fraction, tint: tint)
        }
    }
}

struct UsageShareList: View {
    let title: String
    let rows: [UsageShareRow]
    /// Let the rows flow into two columns when the list is wide enough.
    var twoColumns = false
    /// Say "costs are estimates" beside the heading when the rows show costs. Two lists side by
    /// side say it once.
    var notesCosts = true

    @EnvironmentObject private var settings: AppSettings

    /// How much of a row is drawn, roomiest first.
    private enum Detail: CaseIterable { case meter, amounts, tokensOnly }

    var body: some View {
        let theme = Theme.current(settings)
        let showCosts = settings.showCostEstimates && rows.contains { $0.totals.costUSD > 0 }
        // Each choice carries the heading too, because the note in it depends on what the rows show.
        ViewThatFits(in: .horizontal) {
            if twoColumns, rows.count > 2 {
                let half = (rows.count + 1) / 2
                titled(noted: showCosts, theme) {
                    HStack(alignment: .top, spacing: Theme.Spacing.xxl) {
                        column(Array(rows.prefix(half)), .amounts, showCosts, theme)
                        column(Array(rows.dropFirst(half)), .amounts, showCosts, theme)
                    }
                }
            }
            ForEach(Detail.allCases, id: \.self) { detail in
                titled(noted: showCosts && detail != .tokensOnly, theme) { column(rows, detail, showCosts, theme) }
            }
        }
    }

    private func titled<Content: View>(noted: Bool, _ theme: Theme, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title) {
                if noted, notesCosts {
                    Text("costs are estimates")
                        .font(theme.font(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            content()
        }
    }

    private func column(_ rows: [UsageShareRow], _ detail: Detail, _ showCosts: Bool, _ theme: Theme) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            ForEach(rows) { row in line(row, detail, showCosts, theme) }
        }
        .frame(maxWidth: .infinity)
    }

    private func line(_ row: UsageShareRow, _ detail: Detail, _ showCosts: Bool, _ theme: Theme) -> some View {
        let tokens = PerchFormat.count(row.totals.total)
        let cost = showCosts && row.totals.costUSD > 0 ? PerchFormat.cost(row.totals.costUSD) : nil
        let amount = cost.map { "\(tokens) · \($0)" } ?? tokens
        let percent = PerchFormat.percent(row.fraction * 100)
        return HStack(spacing: Theme.Spacing.s) {
            if let swatch = row.swatch {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(swatch)
                    .frame(width: theme.scaled(9), height: theme.scaled(9))
            }
            if let agent = row.agent {
                AgentBadge(agent, size: theme.scaled(14))
            } else if rows.contains(where: { $0.agent != nil }) {
                // "Other" has no agent; keep its name in line with the names above it.
                Color.clear.frame(width: theme.scaled(14), height: theme.scaled(14))
            }
            Text(row.name)
                .font(theme.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.xs)
            if detail == .meter {
                PerchMeter(value: row.fraction, tint: row.tint, height: 4)
                    .frame(width: theme.scaled(64))
                    .accessibilityHidden(true)
            }
            Text(detail == .tokensOnly ? tokens : amount)
                .font(theme.font(.caption))
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                // One width for every row, so the bars before the numbers start in one line.
                .frame(minWidth: detail == .meter ? theme.scaled(showCosts ? 98 : 40) : nil, alignment: .trailing)
            Text(percent)
                .font(theme.font(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: theme.scaled(28), alignment: .trailing)
        }
        .help(cost.map { "\(row.help) · about \($0)" } ?? row.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name): \(percent), \(amount)")
    }
}
