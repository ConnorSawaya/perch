// UsageActivityRow.swift — Perch's own tally of how you worked, as one short line.
//
//   YOUR ACTIVITY   17h 15m active   27 sessions   60 answered   21m longest task
//
// These numbers are counted by Perch itself from the events it sees (UsageStore.activityDays).
// They never leave the Mac. They cover the range picked at the top of the Usage tab; on a
// narrow panel the line wraps instead of cutting anything off.

import SwiftUI

struct UsageActivityRow: View {
    let days: [DailyActivity]
    let range: UsageTabRange

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let summary = UsageTabMath.activity(days, range: range, now: Date())
        let stats: [(value: String, label: String, help: String)] = [
            (UsageTabMath.duration(summary.activeSeconds), "active", "Time at least one agent was working"),
            (UsageTabMath.grouped(summary.sessions), summary.sessions == 1 ? "session" : "sessions", "Agent sessions started"),
            (UsageTabMath.grouped(summary.requestsHandled), "answered", "Permission prompts and questions you answered from the notch"),
            (UsageTabMath.duration(summary.longestTaskSeconds), "longest task", "The longest an agent worked on one prompt"),
        ]
        CardsFlow(spacing: Theme.Spacing.l, lineSpacing: Theme.Spacing.xs) {
            // Written like a SectionHeader, which itself would stretch across the whole line.
            Text("YOUR ACTIVITY")
                .font(theme.font(.micro))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
                .help("Counted by Perch on this Mac, \(range.phrase). " + details(summary))
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(stat.value)
                        .font(theme.font(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary)
                    Text(stat.label)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
                .lineLimit(1)
                .fixedSize()
                .help(stat.help)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func details(_ summary: UsageActivitySummary) -> String {
        var parts = ["\(UsageTabMath.grouped(summary.turns)) \(summary.turns == 1 ? "turn" : "turns") finished",
                     "\(UsageTabMath.grouped(summary.toolCalls)) tool \(summary.toolCalls == 1 ? "call" : "calls")"]
        if summary.peakConcurrent > 1 { parts.append("up to \(summary.peakConcurrent) sessions at once") }
        return parts.joined(separator: ", ") + "."
    }
}
