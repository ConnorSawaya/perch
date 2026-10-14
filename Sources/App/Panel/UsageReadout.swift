// UsageReadout.swift — picks the usage number shown in the pill and the panel's top strip,
// and draws it as a tiny ring with a percentage.
//
// "Which number?" is a pure function (`UsageReadout.pick`) of the usage store, the sessions and
// the "Pill shows" setting, so it is easy to reason about:
//   5-hour limit  → the fullest 5-hour window of any agent
//   weekly limit  → the fullest weekly window of any agent
//   context       → how full the headline session's context window is
// "Fullest" because that is the limit you will hit first.

import SwiftUI

struct UsageReadout: Equatable {
    /// Very short name: "5h", "Week", "Context".
    var label: String
    /// Plain-English name for tooltips: "5-hour limit".
    var title: String
    /// 0...100.
    var usedPercent: Double
    var resetsAt: Date?
    /// When this reading was taken (nil when unknown). Old readings are drawn dimmed.
    var updatedAt: Date? = nil


    /// The reading for a "Pill shows" choice, or nil when there is no data for it yet.
    static func pick(_ metric: PillMetric, usage: [AgentKind: AgentUsage], headline: Session?) -> UsageReadout? {
        switch metric {
        case .none:
            return nil
        case .fiveHour:
            return fullest(in: usage, short: true).map {
                UsageReadout(label: "5h", title: $0.window.label, usedPercent: $0.window.usedPercent, resetsAt: $0.window.resetsAt, updatedAt: $0.updatedAt)
            }
        case .weekly:
            return fullest(in: usage, short: false).map {
                UsageReadout(label: "Week", title: $0.window.label, usedPercent: $0.window.usedPercent, resetsAt: $0.window.resetsAt, updatedAt: $0.updatedAt)
            }
        case .context:
            guard let percent = headline?.contextPercent, percent.isFinite else { return nil }
            return UsageReadout(label: "Context", title: "Context window", usedPercent: percent, resetsAt: nil)
        }
    }

    /// Both limits, for the panel's top strip (short one first). Empty when nothing is known.
    static func limits(usage: [AgentKind: AgentUsage]) -> [UsageReadout] {
        [PillMetric.fiveHour, .weekly].compactMap { pick($0, usage: usage, headline: nil) }
    }

    private static func fullest(in usage: [AgentKind: AgentUsage], short: Bool) -> (window: RateWindow, updatedAt: Date?)? {
        usage.values
            .flatMap { agent in agent.windows.map { (window: $0, updatedAt: agent.updatedAt) } }
            .filter { isShort($0.window) == short && $0.window.usedPercent.isFinite }
            .max { $0.window.usedPercent < $1.window.usedPercent }
    }

    static func isShort(_ window: RateWindow) -> Bool { window.isShortWindow }

    /// True when the reading is more than an hour old.
    func isStale(now: Date = Date()) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > 3600
    }

    /// The number to print: used, or what is left when "Show remaining" is on.
    func shownPercent(showRemaining: Bool) -> Double {
        let used = min(max(usedPercent, 0), 100)
        return showRemaining ? 100 - used : used
    }

    /// One sentence for the tooltip.
    func explanation(showRemaining: Bool) -> String {
        var text = "\(title): \(PerchFormat.percent(shownPercent(showRemaining: showRemaining))) \(showRemaining ? "left" : "used")"
        if let resetsAt { text += " · resets \(PerchFormat.until(resetsAt))" }
        return text
    }
}

/// A ring and (optionally) its percentage and label, sized for the pill and the top strip.
struct UsageReadoutView: View {
    let readout: UsageReadout
    var showsLabel = false
    var showsNumber = true
    var ringSize: CGFloat = 13

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let shown = readout.shownPercent(showRemaining: settings.usageShowRemaining)
        // Colour always follows how much is USED, so "12% left" is as alarming as "88% used".
        let tint = theme.color(forPercent: readout.usedPercent, warnAt: settings.warnAtPercent, calm: theme.accent)
        HStack(spacing: 4) {
            if showsLabel {
                Text(readout.label)
                    .font(theme.font(size: 9.5, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            ProgressRing(value: shown / 100, size: ringSize, lineWidth: max(2, ringSize * 0.19), tint: tint,
                         secondaryTint: tint == theme.accent ? theme.accentAlt : tint)
            if showsNumber {
                Text(PerchFormat.percent(shown))
                    .font(theme.font(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .help(readout.explanation(showRemaining: settings.usageShowRemaining))
        .accessibilityElement()
        .accessibilityLabel(readout.explanation(showRemaining: settings.usageShowRemaining))
    }
}
