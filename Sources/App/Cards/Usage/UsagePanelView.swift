// UsagePanelView.swift — the Usage tab of the panel.
//
//   [ All ] [▣ Claude Code] [▣ Codex]          5h 37% · 7d 82%
//   ▢▢▣▣▢▣■■▢▣▣■▣     one square per day, a column per week, like GitHub's contribution graph:
//   ▢▣▣■▢▣■■▣▣■■▣     the more tokens that day, the brighter the square
//   Oct 12 · 5.9M tokens · about $7.85
//   claude-opus-5-5    ▬▬▬▬▬▬   4.1M        the day you clicked, split by model
//
// "All" adds every agent together; the other buttons show one agent. Clicking a square picks
// that day; today is picked to start with. The view only reads UsageStore.

import SwiftUI

struct UsagePanelView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var usage: UsageStore
    @Environment(\.perchActions) private var actions
    /// The button the user pressed, if any. Nil shows the tab's starting view.
    @State private var picked: UsageTabScope?
    /// The day whose breakdown is showing ("yyyy-MM-dd"). Nil means today.
    @State private var pickedDay: String?

    /// - Parameters:
    ///   - initialRange, unfoldAll: No effect; kept so earlier callers still compile.
    ///   - initialAgent: Start on this agent instead of "All". Only for snapshots.
    ///   - initialDay: Start with this day clicked ("yyyy-MM-dd"). Only for snapshots.
    init(initialRange: UsageTabRange = .week, unfoldAll: Bool = false, initialAgent: AgentKind? = nil, initialDay: String? = nil) {
        self._picked = State(initialValue: initialAgent.map { .agent($0) })
        self._pickedDay = State(initialValue: initialDay)
    }

    var body: some View {
        let theme = Theme.current(settings)
        let now = Date()
        // A fixed agent order, so the buttons never swap places between refreshes.
        let agents = AgentKind.allCases.compactMap { usage.usage[$0] }.filter(UsageTabMath.hasData)
        let scope = UsageCombine.scope(picked: picked, agents: agents.map(\.agent))

        if agents.isEmpty {
            PerchEmptyState(title: "No usage yet", message: "Numbers appear after your first session.",
                            systemImage: "square.grid.3x3.fill") {
                Button("Check now") { actions.refreshUsage() }.buttonStyle(.perch(.secondary, size: .small))
            }
        } else {
            let shown = agents.filter { scope == .all || scope == .agent($0.agent) }
            let days = UsageHeat.merge(shown, now: now)
            let grid = UsageHeat.grid(days: days, weeks: UsageHeat.weeks, now: now)
            let today = UsageTabCalendar.dayString(now)
            let selected = pickedDay ?? today

            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                HStack(spacing: Theme.Spacing.xs) {
                    if agents.count > 1 {
                        UsageScopeButton(agent: nil, isSelected: scope == .all) { picked = .all }
                        ForEach(agents.map(\.agent)) { agent in
                            UsageScopeButton(agent: agent, isSelected: scope == .agent(agent)) { picked = .agent(agent) }
                        }
                    }
                    Spacer(minLength: Theme.Spacing.m)
                    Text(UsageHeat.limitsLine(shown, settings: settings))
                        .font(theme.font(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
                UsageHeatGrid(grid: grid, selected: selected, today: today,
                              bubble: pickedDay.map { UsageHeat.bubbleText(day: $0, usage: days[$0], showCost: settings.showCostEstimates) }) { day in
                    pickedDay = (pickedDay == day) ? nil : day
                }
                UsageDayDetail(day: selected, usage: days[selected], isToday: selected == today)
            }
            .padding(.horizontal, Theme.Spacing.xs)
        }
    }
}

// MARK: - The numbers behind the grid

enum UsageHeat {
    /// How many week columns the grid shows (13 weeks ≈ the 90 days Perch keeps).
    static let weeks = 13

    /// One square of the grid. `day` is nil for the days still to come this week (drawn as dim grey squares).
    struct Cell: Identifiable, Equatable {
        var id: String
        var day: String?
        var tokens: Int
        /// 0 (nothing) … 4 (the busiest days).
        var level: Int
    }

    /// Adds the given agents' days together, day by day and model by model.
    static func merge(_ usages: [AgentUsage], now: Date) -> [String: DayUsage] {
        var merged: [String: DayUsage] = [:]
        for usage in usages {
            for (day, record) in UsageCombine.days(usage, now: now) {
                var sum = merged[day] ?? DayUsage(day: day)
                sum.totals += record.totals
                for (model, totals) in record.byModel { sum.byModel[model, default: TokenTotals()] += totals }
                merged[day] = sum
            }
        }
        return merged
    }

    /// Week columns, oldest first; each column runs Sunday to Saturday (the calendar's own week).
    static func grid(days: [String: DayUsage], weeks: Int, now: Date) -> [[Cell]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let weekdayIndex = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        guard let lastWeekStart = calendar.date(byAdding: .day, value: -weekdayIndex, to: today) else { return [] }
        let busiest = days.values.map { $0.totals.total }.max() ?? 0
        return (0..<weeks).map { column in
            (0..<7).map { row in
                let offset = (column - (weeks - 1)) * 7 + row
                guard let date = calendar.date(byAdding: .day, value: offset, to: lastWeekStart), date <= today else {
                    return Cell(id: "blank-\(column)-\(row)", day: nil, tokens: 0, level: 0)
                }
                let day = UsageTabCalendar.dayString(date)
                let tokens = days[day]?.totals.total ?? 0
                return Cell(id: day, day: day, tokens: tokens, level: level(tokens, busiest: busiest))
            }
        }
    }

    /// "Oct 11 · 379M tokens · about $180.04" for the bubble beside a clicked day.
    static func bubbleText(day: String, usage: DayUsage?, showCost: Bool) -> String {
        let totals = usage?.totals ?? TokenTotals()
        var text = "\(UsageTabCalendar.shortLabel(day)) · \(totals.total > 0 ? PerchFormat.count(totals.total) + " tokens" : "nothing used")"
        if showCost, totals.costUSD > 0 { text += " · about \(PerchFormat.cost(totals.costUSD))" }
        if totals.messages > 0 { text += " · \(totals.messages) replies" }
        return text
    }

    /// Four brightness steps above zero, by share of the busiest day.
    static func level(_ tokens: Int, busiest: Int) -> Int {
        guard tokens > 0, busiest > 0 else { return 0 }
        let share = Double(tokens) / Double(busiest)
        return share > 0.75 ? 4 : share > 0.5 ? 3 : share > 0.25 ? 2 : 1
    }

    /// "5h 37% · 7d 82%" for the agents on show (prefixed with the agent when there are several).
    static func limitsLine(_ usages: [AgentUsage], settings: AppSettings) -> String {
        let several = usages.filter { !$0.windows.isEmpty }.count > 1
        return usages.flatMap { usage in
            usage.windows.prefix(2).map { window -> String in
                let value = settings.usageShowRemaining ? 100 - window.usedPercent : window.usedPercent
                let percent = value.isFinite ? "\(Int(min(max(value, 0), 100).rounded()))%" : "–"
                // Codex calls its two windows "primary" and "secondary"; they are its 5-hour and weekly limits.
                let name = window.isShortWindow ? "5h" : "7d"
                return "\(several ? usage.agent.monogram + " " : "")\(name) \(percent)"
            }
        }.joined(separator: " · ")
    }
}

// MARK: - The grid

private struct UsageHeatGrid: View {
    let grid: [[UsageHeat.Cell]]
    let selected: String
    let today: String
    /// Text for the small bubble beside the picked day; nil shows no bubble.
    var bubble: String?
    let pick: (String) -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let gap: CGFloat = 3
        GeometryReader { proxy in
            let columns = max(grid.count, 1)
            let side = max(4, min(18, (proxy.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)))
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: gap) {
                        ForEach(week) { cell in
                            square(cell, side: side, theme)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if let bubble, let spot = position(of: selected) {
                    let step = side + gap
                    let x = CGFloat(spot.column) * step + side / 2
                    let above = spot.row > 0
                    // A zero-size anchor at the square's centre; the bubble is centred on it.
                    // Kept at least 120 pt from either edge so it stays inside the panel.
                    Color.clear.frame(width: 0, height: 0)
                        .overlay {
                            Text(bubble)
                                .font(theme.font(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.surfaceHover))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.strokeStrong, lineWidth: 1))
                        }
                        .offset(x: min(max(x, 120), max(proxy.size.width - 120, 120)),
                                y: above ? CGFloat(spot.row) * step - 15 : side + 15)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .frame(height: 7 * 18 + 6 * gap)
    }

    /// Which column and row a day sits in.
    private func position(of day: String) -> (column: Int, row: Int)? {
        for (column, week) in grid.enumerated() {
            if let row = week.firstIndex(where: { $0.day == day }) { return (column, row) }
        }
        return nil
    }

    @ViewBuilder
    private func square(_ cell: UsageHeat.Cell, side: CGFloat, _ theme: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        if let day = cell.day {
            shape.fill(colour(cell.level, theme))
                .overlay(shape.strokeBorder(day == selected ? theme.textPrimary : Color.clear, lineWidth: 1.5))
                .frame(width: side, height: side)
                .contentShape(shape)
                .onTapGesture { pick(day) }
                .help("\(UsageTabCalendar.shortLabel(day)): \(PerchFormat.count(cell.tokens)) tokens")
                .accessibilityLabel("\(UsageTabCalendar.shortLabel(day)), \(PerchFormat.count(cell.tokens)) tokens")
                .accessibilityAddTraits(day == selected ? [.isButton, .isSelected] : .isButton)
        } else {
            // A day that has not happened yet: a dim grey square you cannot click.
            shape.fill(Color.white.opacity(0.02))
                .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        }
    }

    private func colour(_ level: Int, _ theme: Theme) -> Color {
        switch level {
        case 0: return Color.white.opacity(0.06)
        case 1: return theme.success.opacity(0.3)
        case 2: return theme.success.opacity(0.5)
        case 3: return theme.success.opacity(0.75)
        default: return theme.success
        }
    }
}

// MARK: - The picked day

private struct UsageDayDetail: View {
    let day: String
    let usage: DayUsage?
    let isToday: Bool

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let totals = usage?.totals ?? TokenTotals()
        let models = (usage?.byModel ?? [:]).filter { $0.value.total > 0 }.sorted { $0.value.total > $1.value.total }
        let busiest = models.first?.value.total ?? 0

        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(isToday ? "Today" : UsageTabCalendar.shortLabel(day))
                    .font(theme.font(.label))
                    .foregroundStyle(theme.textPrimary)
                Text(headline(totals))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            ForEach(models.prefix(6), id: \.key) { model, modelTotals in
                HStack(spacing: Theme.Spacing.m) {
                    Text(UsageTabMath.displayName(model))
                        .font(theme.font(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GeometryReader { proxy in
                        let share = busiest > 0 ? CGFloat(modelTotals.total) / CGFloat(busiest) : 0
                        Capsule().fill(theme.success.opacity(0.7))
                            .frame(width: max(2, proxy.size.width * share), height: 4)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(width: 90, height: 10)
                    Text(PerchFormat.count(modelTotals.total))
                        .font(theme.font(size: 11, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
        }
    }

    private func headline(_ totals: TokenTotals) -> String {
        guard totals.total > 0 else { return "nothing used" }
        var text = "\(PerchFormat.count(totals.total)) tokens"
        if settings.showCostEstimates, totals.costUSD > 0 { text += " · about \(PerchFormat.cost(totals.costUSD))" }
        return text
    }
}

/// "All", or one agent's badge and name. The button of the view that is showing looks pressed in.
private struct UsageScopeButton: View {
    /// Nil is the "All" button.
    let agent: AgentKind?
    let isSelected: Bool
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        Button(action: action) {
            HStack(spacing: 5) {
                if let agent { AgentBadge(agent, size: theme.scaled(15)) }
                Text(agent?.displayName ?? "All")
            }
            .fixedSize()
        }
        .buttonStyle(.perch(isSelected ? .secondary : .ghost, size: .small))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
