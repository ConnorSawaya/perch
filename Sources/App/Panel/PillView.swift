// PillView.swift — the collapsed island: what you see all day, hugging the notch.
//
//   ┌────────────┬──────────────────┬────────────┐
//   │ ◉ Bash     │  (physical notch) │   ⚑ 2      │
//   └────────────┴──────────────────┴────────────┘
//     left wing        nothing            right wing
//
// Left wing:  the mascot (or a state dot) for the "headline" session — the one that most
//             deserves attention — plus, in the detailed style, one word of status.
// Middle:     hidden behind the notch, so it stays empty. On screens without a notch it shows
//             the headline session's title instead.
// Right wing: how many sessions are waiting for you; otherwise how many are busy and/or the
//             usage ring chosen in Settings.
// With no sessions the pill is almost blank on purpose.

import SwiftUI

struct PillView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var ui: UIState

    private var isDetailed: Bool { settings.pillStyle == .detailed }

    var body: some View {
        let theme = Theme.current(settings)
        let wing = IslandMetrics.wing(settings)
        let headline = sessions.headline
        let edge: CGFloat = isDetailed ? 10 : 0

        HStack(spacing: 0) {
            leftWing(theme, headline: headline)
                .padding(.leading, edge)
                .frame(width: wing, alignment: isDetailed ? .leading : .center)
            middle(theme, headline: headline)
                .frame(width: ui.notchSize.width)
            rightWing(theme, headline: headline)
                .padding(.trailing, edge)
                .frame(width: wing, alignment: isDetailed ? .trailing : .center)
        }
        .frame(height: ui.notchSize.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Left wing

    @ViewBuilder
    private func leftWing(_ theme: Theme, headline: Session?) -> some View {
        let glyph = min(20, max(10, ui.notchSize.height - 12))
        HStack(spacing: 5) {
            StatusGlyph(session: headline, size: glyph)
            if isDetailed, let headline {
                Text(SessionWording.pillWord(for: headline))
                    .font(theme.font(size: 10.5, weight: .semibold))
                    .foregroundStyle(headline.state == .idle ? theme.textTertiary : theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        // Nothing running: stay in the background.
        .opacity(headline == nil ? 0.4 : 1)
    }

    // MARK: Middle

    @ViewBuilder
    private func middle(_ theme: Theme, headline: Session?) -> some View {
        if !ui.screenHasNotch, let headline {
            Text(SessionWording.title(for: headline))
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Theme.Spacing.m)
        } else {
            Color.clear
        }
    }

    // MARK: Right wing

    @ViewBuilder
    private func rightWing(_ theme: Theme, headline: Session?) -> some View {
        let waiting = sessions.attentionCount
        let busy = sessions.busyCount
        let readout = settings.showUsageInPill
            ? UsageReadout.pick(settings.pillMetric, usage: usage.usage, headline: headline)
            : nil

        if waiting > 0 {
            WaitingBadge(count: waiting, state: headline?.state ?? .needsApproval)
        } else if let readout {
            if isDetailed {
                // Show as much as fits: busy count + ring + number, then less.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        if busy > 0 { BusyCount(count: busy) }
                        UsageReadoutView(readout: readout)
                    }
                    UsageReadoutView(readout: readout)
                    UsageReadoutView(readout: readout, showsNumber: false)
                }
                .opacity(headline == nil ? 0.45 : 1)
            } else {
                UsageReadoutView(readout: readout, showsNumber: false, ringSize: 14)
                    .opacity(headline == nil ? 0.45 : 1)
            }
        } else if busy > 0 {
            BusyCount(count: busy)
        }
    }

    private var accessibilitySummary: String {
        let summary = SessionWording.summary(of: sessions.sessions)
        return "Perch: " + [summary.headline, summary.detail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The mascot for a session's state, or a plain state dot when the mascot is turned off.
struct StatusGlyph: View {
    let session: Session?
    var size: CGFloat = 18

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        if settings.showMascot {
            MascotView(mood: MascotMood(session?.state), size: size,
                       tint: session.map { theme.accent(for: $0.agent, settings: settings) },
                       tintGlow: session.map { theme.accentGlow(for: $0.agent, settings: settings) })
        } else {
            StateDot(session?.state ?? .idle, size: max(6, size * 0.5))
                .frame(width: size, height: size)
        }
    }
}

/// "N sessions are waiting for you": a loud little capsule in the state's colour.
private struct WaitingBadge: View {
    let count: Int
    let state: SessionState

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let tint = theme.color(for: state.needsAttention ? state : .needsApproval)
        HStack(spacing: 3) {
            Image(systemName: SessionWording.symbol(for: state.needsAttention ? state : .needsApproval))
                .font(theme.font(size: 8.5, weight: .bold))
            Text("\(count)")
                .font(theme.font(size: 10.5, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        // State colours are bright in every theme, so dark text is always the readable choice.
        .foregroundStyle(Color.black.opacity(0.85))
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Capsule().fill(tint))
        .shadow(color: tint.opacity(settings.showGlow ? 0.55 : 0), radius: 5)
        .fixedSize()
        .help(count == 1 ? "1 session is waiting for you" : "\(count) sessions are waiting for you")
    }
}

/// "N sessions are busy": bouncing bars and a number.
private struct BusyCount: View {
    let count: Int

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        HStack(spacing: 3) {
            PerchActivityBars(tint: theme.info, size: 9)
            Text("\(count)")
                .font(theme.font(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
        }
        .lineLimit(1)
        .fixedSize()
        .help(count == 1 ? "1 session is working" : "\(count) sessions are working")
    }
}
