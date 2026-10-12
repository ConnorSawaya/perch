// UsageStackChart.swift — one bar per day, each bar split by model: the history of one agent
// or of all of them together.
//
//   LAST 30 DAYS                                     152M tokens · about $198
//   ▂▅▇▃▁▆▂▅▇▃▁▆▂▅▇▃▁▆▂▅▇▃▁▆▂▅▇▃▁█      ← each bar is stacked, biggest model at the bottom
//   Sep 13              busiest day 9.6M                         Today
//
// Drawn with Canvas. Bars grow from one baseline; days with no record show a small tick so a
// gap is not mistaken for missing days. With the "Today" range the earlier days are drawn
// faintly, for context. Moving the pointer over the chart replaces the summary on the right
// with that day's numbers. The colours are explained by the "by model" list under the chart.

import SwiftUI

struct UsageStackChart: View {
    let combined: UsageCombined
    let range: UsageTabRange
    /// One per entry of `combined.series`.
    let colours: [Color]

    @EnvironmentObject private var settings: AppSettings
    /// Position of the day under the pointer.
    @State private var hovered: Int?

    var body: some View {
        let theme = Theme.current(settings)
        let days = combined.days
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader("Last \(days.count) days") {
                Text(readout)
                    .font(theme.font(.caption))
                    .monospacedDigit()
                    .foregroundStyle(hovered == nil ? theme.textSecondary : theme.textPrimary)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                bars(theme)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let slot = geometry.size.width / CGFloat(max(days.count, 1))
                            let index = Int(point.x / max(slot, 1))
                            hovered = days.indices.contains(index) ? index : nil
                        case .ended:
                            hovered = nil
                        }
                    }
            }
            .frame(height: theme.scaled(60))
            HStack(spacing: Theme.Spacing.m) {
                Text(days.first.map { UsageTabCalendar.shortLabel($0.day) } ?? "")
                Spacer(minLength: 0)
                if let busiest = days.map(\.stacked).max(), busiest > 0 {
                    Text("busiest day \(PerchFormat.count(busiest))")
                    Spacer(minLength: 0)
                }
                Text("Today")
            }
            .font(theme.font(size: 9.5, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens per day for the last \(days.count) days, split by model. \(summary)")
    }

    /// The hovered day's numbers, or the summary when the pointer is elsewhere.
    private var readout: String {
        guard let hovered, combined.days.indices.contains(hovered) else { return summary }
        let day = combined.days[hovered]
        let label = hovered == combined.days.count - 1 ? "Today" : UsageTabCalendar.shortLabel(day.day)
        guard day.hasData else { return "\(label) · nothing recorded" }
        return "\(label) · \(amount(day.totals))"
    }

    /// The chosen range in one line: "152M tokens · about $198".
    private var summary: String {
        guard combined.range.total > 0 else { return "nothing recorded \(range.phrase)" }
        return (range == .today ? "Today · " : "") + amount(combined.range)
    }

    private func amount(_ totals: TokenTotals) -> String {
        let tokens = "\(PerchFormat.count(totals.total)) tokens"
        return settings.showCostEstimates && totals.costUSD > 0 ? "\(tokens) · about \(PerchFormat.cost(totals.costUSD))" : tokens
    }

    private func bars(_ theme: Theme) -> some View {
        let days = combined.days
        let colours = self.colours
        let hovered = self.hovered
        let baseline = theme.stroke
        return Canvas { context, size in
            guard !days.isEmpty else { return }
            let slot = size.width / CGFloat(days.count)
            // A bar never fills its slot, and never gets fat when there are only a few days.
            let barWidth = min(22, max(2, slot * 0.6))
            let peak = max(Double(days.map(\.stacked).max() ?? 0), 1)
            let floor = size.height - 1

            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height - 0.5))
            line.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(line, with: .color(baseline), lineWidth: 1)

            for (index, day) in days.enumerated() {
                let x = CGFloat(index) * slot + (slot - barWidth) / 2
                let lit = hovered == index
                guard day.stacked > 0 else {
                    let tick = CGRect(x: x, y: floor - 1.5, width: barWidth, height: 1.5)
                    context.opacity = 1
                    context.fill(Path(tick), with: .color(Color.white.opacity(lit ? 0.4 : 0.14)))
                    continue
                }
                context.opacity = hovered == nil ? (day.inRange ? 1 : 0.3) : (lit ? 1 : 0.35)
                let height = max(2, CGFloat(Double(day.stacked) / peak) * (floor - 2))
                let shown = day.parts.enumerated().filter { $0.element > 0 }
                var top = floor
                for (position, part) in shown.enumerated() {
                    let partHeight = height * CGFloat(part.element) / CGFloat(day.stacked)
                    let isLast = position == shown.count - 1
                    // A hairline of card colour between parts, when the part can spare it.
                    let gap: CGFloat = !isLast && partHeight > 3 && barWidth >= 3 ? 1 : 0
                    let rect = CGRect(x: x, y: top - partHeight + gap, width: barWidth, height: partHeight - gap)
                    // Rounded at the data end only, square where parts meet and on the baseline.
                    let radius = isLast ? min(3, barWidth / 2, rect.height) : 0
                    let shape = Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: radius, topTrailing: radius))
                    context.fill(shape, with: .color(colours.indices.contains(part.offset) ? colours[part.offset] : theme.textTertiary))
                    top -= partHeight
                }
            }
        }
    }
}
