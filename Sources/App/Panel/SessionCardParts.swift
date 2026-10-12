// SessionCardParts.swift — the small pieces a session card is built from.
//
//   SessionMetaLabel       "▪ perch", "⑂ main" — an icon and a fact in quiet grey
//   ContextMeter           a short bar and "42%": how full the agent's context window is
//   SessionStatusLineView  the bottom line: what the session is doing or last said
//   ToolSparkline          one bar per recent tool call; taller = took longer, red = failed

import SwiftUI

struct SessionMetaLabel: View {
    let symbol: String
    let text: String
    var truncation: Text.TruncationMode = .tail

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(theme.font(size: 8.5, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text(text)
                .font(theme.font(.caption))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(truncation)
        }
    }
}

struct ContextMeter: View {
    /// 0...100.
    let percent: Double

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        // Context filling up matters sooner than a usage limit: warn from 70%.
        let tint = theme.color(forPercent: percent, warnAt: 70, calm: theme.textSecondary)
        HStack(spacing: 5) {
            PerchMeter(value: percent / 100, tint: tint, height: 3.5)
                .frame(width: 30)
            Text(PerchFormat.percent(percent))
                .font(theme.font(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(percent >= 70 ? tint : theme.textTertiary)
                .frame(minWidth: theme.scaled(24), alignment: .trailing)
        }
        .fixedSize()
        .help("Context window \(PerchFormat.percent(percent)) full")
        .accessibilityElement()
        .accessibilityLabel("Context window \(PerchFormat.percent(percent)) full")
    }
}

struct SessionStatusLineView: View {
    let line: SessionWording.StatusLine
    let stateColour: Color

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: line.symbol)
                .font(theme.font(size: 9, weight: .semibold))
                .foregroundStyle(iconColour(theme))
                .frame(width: theme.scaled(12))
            Text(line.text)
                .font(line.isCode ? theme.font(.monoSmall) : theme.font(.caption))
                .foregroundStyle(textColour(theme))
                .lineLimit(line.lines)
                .truncationMode(line.isCode ? .middle : .tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .perchShimmer(isActive: line.isLive)
        }
    }

    private func iconColour(_ theme: Theme) -> Color {
        switch line.tone {
        case .quiet: return theme.textTertiary
        case .normal, .success, .danger, .attention: return stateColour
        }
    }

    private func textColour(_ theme: Theme) -> Color {
        switch line.tone {
        case .quiet: return theme.textTertiary
        case .danger: return theme.danger
        case .attention: return theme.textPrimary.opacity(0.9)
        case .normal, .success: return theme.textSecondary
        }
    }
}

struct ToolSparkline: View {
    let tools: [ToolCall]
    let tint: Color

    @EnvironmentObject private var settings: AppSettings

    /// Enough history to show a rhythm without crowding the card.
    private static let maxBars = 16

    var body: some View {
        let theme = Theme.current(settings)
        let recent = Array(tools.suffix(Self.maxBars))
        let now = Date()
        // Squeeze the range hard, so a 30-second build does not flatten every 2-second edit next to it.
        let heights = recent.map { tool -> Double in
            let seconds = max(0.5, (tool.finishedAt ?? now).timeIntervalSince(tool.startedAt))
            return pow(seconds, 0.35)
        }
        let colours = recent.map { tool -> Color? in
            if tool.finishedAt == nil { return theme.info }
            if tool.succeeded == false { return theme.danger }
            return tint.opacity(0.75)
        }
        Sparkline(values: heights, tint: tint, colors: colours, barWidth: 2.5, spacing: 1.5)
            .help(summary(recent))
    }

    private func summary(_ recent: [ToolCall]) -> String {
        let failed = recent.filter { $0.succeeded == false }.count
        let base = recent.count == 1 ? "Last tool call" : "Last \(recent.count) tool calls"
        return failed == 0 ? base : "\(base) · \(failed) failed"
    }
}
