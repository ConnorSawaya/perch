// UsageLimitsView.swift — the rate-limit rings, in two sizes.
//
// UsageLimitsView, for one agent's view: a roomy tile per limit.
//
//   (◔ 37%)  5-hour limit              (◕ 82%)  Weekly limit ⚠
//            Used · resets in 2h 24m            Used · resets in 3d 4h
//
// UsageLimitsStrip, for the "All" view: every agent's limits side by side in one compact row,
// each group headed by its agent. It wraps onto more lines only when the row runs out of room.
//
//   ▣ Claude Code                                      ▣ Codex
//   (37%) 5-hour limit         (82%) Weekly limit ⚠    (12%) 5-hour limit
//         Used · resets 2h 24m       Used · resets 3d 4h     Used · resets 4h 5m
//
// Settings honoured here: "Show remaining" flips the ring and the number to what is left;
// "Usage warnings" + "Warn at" turn a ring amber (with a warning mark) past the threshold and
// red when the limit is nearly gone.

import SwiftUI

struct UsageLimitsView: View {
    let agent: AgentKind
    let windows: [RateWindow]

    var body: some View {
        // Roomy tiles side by side when there is room; on a narrow panel the compact rings in
        // one row; and if even those do not fit, the tiles one under the other.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.m) { tiles(minWidth: 172) }
            UsageLimitMinis(agent: agent, windows: windows)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: Theme.Spacing.m) { tiles(minWidth: 0) }
        }
    }

    private func tiles(minWidth: CGFloat) -> some View {
        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
            UsageLimitTile(agent: agent, window: window)
                .frame(minWidth: minWidth, maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct UsageLimitTile: View {
    let agent: AgentKind
    let window: RateWindow

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let reading = UsageTabMath.reading(window, showRemaining: settings.usageShowRemaining,
                                        warnings: settings.usageWarnings, warnAt: settings.warnAtPercent)
        let colour = reading.colour(calm: theme.accent(for: agent, settings: settings), theme)
        let ringSide = theme.scaled(42)
        HStack(spacing: 10) {
            ProgressRing(value: reading.shown / 100, size: ringSide, lineWidth: 4.5, tint: colour,
                         secondaryTint: reading.level == .calm ? theme.accentGlow(for: agent, settings: settings) : colour)
                .overlay {
                    Text(PerchFormat.percent(reading.shown))
                        .font(theme.font(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(CardsWording.tidy(window.label) ?? "Limit")
                        .font(theme.font(.label))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if reading.level != .calm {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(theme.font(size: 9.5, weight: .semibold))
                            .foregroundStyle(colour)
                            .help(reading.warning(warnAt: settings.warnAtPercent))
                    }
                }
                UsageLimitCaption(reading: reading, resetsAt: window.resetsAt)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.Spacing.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(theme.stroke, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label): \(PerchFormat.percent(reading.shown)) \(reading.showsRemaining ? "left" : "used")"
                            + (reading.level == .calm ? "" : ". " + reading.warning(warnAt: settings.warnAtPercent)))
    }
}

/// Every agent's limits in one row, for the "All" view.
struct UsageLimitsStrip: View {
    /// Agents that have at least one limit.
    let agents: [AgentUsage]

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        CardsFlow(spacing: Theme.Spacing.xl, lineSpacing: Theme.Spacing.m) {
            ForEach(agents, id: \.agent) { usage in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        AgentBadge(usage.agent, size: theme.scaled(15))
                        Text(usage.agent.displayName)
                            .font(theme.font(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    UsageLimitMinis(agent: usage.agent, windows: usage.windows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One agent's limits as compact rings in a row. A ring is never squeezed; when the row is too
/// narrow for all of them, the rest move to the next line.
private struct UsageLimitMinis: View {
    let agent: AgentKind
    let windows: [RateWindow]

    var body: some View {
        CardsFlow(spacing: 10, lineSpacing: Theme.Spacing.m) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                UsageLimitMini(agent: agent, window: window)
                    .fixedSize()
            }
        }
    }
}

/// One limit in the strip: a small ring with the number in it, the limit's name and its reset.
private struct UsageLimitMini: View {
    let agent: AgentKind
    let window: RateWindow

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let reading = UsageTabMath.reading(window, showRemaining: settings.usageShowRemaining,
                                        warnings: settings.usageWarnings, warnAt: settings.warnAtPercent)
        let tint = theme.accent(for: agent, settings: settings)
        let colour = reading.colour(calm: tint, theme)
        let ringSide = theme.scaled(32)
        HStack(spacing: 6) {
            ProgressRing(value: reading.shown / 100, size: ringSide, lineWidth: 3.5, tint: colour,
                         secondaryTint: reading.level == .calm ? theme.accentGlow(for: agent, settings: settings) : colour)
                .overlay {
                    Text(PerchFormat.percent(reading.shown))
                        .font(theme.font(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize()
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(CardsWording.tidy(window.label) ?? "Limit")
                        .font(theme.font(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if reading.level != .calm {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(theme.font(size: 8.5, weight: .semibold))
                            .foregroundStyle(colour)
                    }
                }
                UsageLimitCaption(reading: reading, resetsAt: window.resetsAt, compact: true)
            }
            // A limit with a very long name must not push its neighbours off the row.
            .frame(maxWidth: theme.scaled(132), alignment: .leading)
        }
        .help(reading.level == .calm ? window.label : reading.warning(warnAt: settings.warnAtPercent))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.displayName), \(window.label): \(PerchFormat.percent(reading.shown)) \(reading.showsRemaining ? "left" : "used")"
                            + (reading.level == .calm ? "" : ". " + reading.warning(warnAt: settings.warnAtPercent)))
    }
}

private extension UsageLimitReading {
    /// The ring's colour: the agent's own while calm, then the theme's warning and danger colours.
    func colour(calm: Color, _ theme: Theme) -> Color {
        switch level {
        case .calm: return calm
        case .warning: return theme.warning
        case .danger: return theme.danger
        }
    }

    func warning(warnAt: Double) -> String {
        level == .danger
            ? "Almost used up: \(PerchFormat.percent(used)) of this limit is gone."
            : "Getting close: past your \(PerchFormat.percent(warnAt)) warning level."
    }
}

/// "Used · resets in 2h 24m" ("Used · resets 2h 24m" when compact). The countdown keeps itself up to date.
private struct UsageLimitCaption: View {
    let reading: UsageLimitReading
    let resetsAt: Date?
    var compact = false

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        TimelineView(.periodic(from: Date(), by: 30)) { timeline in
            Text(text(now: timeline.date))
                .font(compact ? theme.font(size: 10.5) : theme.font(.caption))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        // In the compact strip the line is measured before it is placed; it must report its full width.
        .fixedSize(horizontal: compact, vertical: false)
    }

    private func text(now: Date) -> String {
        let state = reading.showsRemaining ? "Left" : "Used"
        guard let resetsAt else { return state }
        let seconds = resetsAt.timeIntervalSince(now)
        if seconds < 1 { return "\(state) · resets \(compact ? "now" : "any moment")" }
        return "\(state) · resets \(compact ? PerchFormat.remaining(seconds) : PerchFormat.until(resetsAt, now: now))"
    }
}
