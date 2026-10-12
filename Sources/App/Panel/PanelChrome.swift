// PanelChrome.swift — the fixed parts of the open panel that frame the scrolling content.
//
//   PanelStrip     the row level with the notch: mascot + summary on the left, usage rings on the right
//   PanelHeader    the row under it: the three tabs, then mute, settings and close buttons
//   PanelDemoBar   a thin footer shown only in demo mode, with a way out
//
// None of these scroll. PanelView stacks them around the scrolling area.

import SwiftUI

// MARK: - Strip beside the notch

struct PanelStrip: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var ui: UIState

    var body: some View {
        let theme = Theme.current(settings)
        HStack(spacing: 0) {
            summary(theme)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Leave the notch itself empty; without a notch the two halves simply meet.
            Color.clear.frame(width: ui.screenHasNotch ? ui.notchSize.width : Theme.Spacing.l, height: 1)
            limits(theme)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(height: ui.notchSize.height)
    }

    private func summary(_ theme: Theme) -> some View {
        let words = SessionWording.summary(of: sessions.sessions)
        let headline = sessions.headline
        let colour = headline.map { $0.state.needsAttention ? theme.color(for: $0.state) : theme.textPrimary } ?? theme.textSecondary
        return HStack(spacing: 5) {
            StatusGlyph(session: headline, size: min(20, max(10, ui.notchSize.height - 12)))
            // Drop the second half when the panel is narrow rather than truncating mid-word.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(words.headline).foregroundStyle(colour)
                    if let detail = words.detail {
                        Text(detail).foregroundStyle(theme.textTertiary)
                    }
                }
                Text(words.headline).foregroundStyle(colour)
            }
            .font(theme.font(size: 11, weight: .semibold))
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func limits(_ theme: Theme) -> some View {
        let readouts = UsageReadout.limits(usage: usage.usage)
        if !readouts.isEmpty {
            Button {
                ui.panelTab = .usage
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(readouts, id: \.label) { UsageReadoutView(readout: $0, showsLabel: true, ringSize: 12) }
                    }
                    // Narrow panel: only the limit that is closest to running out.
                    if let fullest = readouts.max(by: { $0.usedPercent < $1.usedPercent }) {
                        UsageReadoutView(readout: fullest, showsLabel: true, ringSize: 12)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the usage tab")
        }
    }
}

// MARK: - Tabs and buttons

struct PanelHeader: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.perchActions) private var actions

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            PanelTabBar()
            Spacer(minLength: Theme.Spacing.m)
            PerchIconButton(systemName: settings.soundsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            help: settings.soundsEnabled ? "Mute sounds" : "Turn sounds back on",
                            tint: settings.soundsEnabled ? nil : Theme.current(settings).warning) {
                actions.toggleMute()
            }
            PerchIconButton(systemName: "gearshape.fill", help: "Open Settings") {
                actions.openSettings(nil)
            }
            PerchIconButton(systemName: "chevron.up", help: "Close the panel") {
                actions.setExpanded(false)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.m)
    }
}

struct PanelTabBar: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var ui: UIState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Namespace private var selection

    var body: some View {
        let theme = Theme.current(settings)
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                tabButton(tab, theme: theme)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        // The outline is decoration drawn over the tabs; it must never take their clicks.
        .overlay(Capsule().strokeBorder(theme.stroke, lineWidth: 1).allowsHitTesting(false))
        .animation(PerchMotion.quick(reduce: settings.prefersCalm(systemReduceMotion)), value: ui.panelTab)
    }

    private func tabButton(_ tab: PanelTab, theme: Theme) -> some View {
        let isSelected = ui.panelTab == tab
        return Button {
            ui.panelTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol(for: tab))
                    .font(theme.font(size: 10, weight: .semibold))
                Text(Self.title(for: tab))
                    .font(theme.font(size: 11.5, weight: .semibold))
                if tab == .sessions, !sessions.sessions.isEmpty {
                    countBubble(theme)
                }
            }
            .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(theme.surfaceHover)
                        .overlay(Capsule().strokeBorder(theme.strokeStrong.opacity(0.6), lineWidth: 1))
                        .matchedGeometryEffect(id: "selected-tab", in: selection)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Sessions waiting for you (in the warning colour), or else the plain number of sessions.
    private func countBubble(_ theme: Theme) -> some View {
        let waiting = sessions.attentionCount
        return Text("\(waiting > 0 ? waiting : sessions.sessions.count)")
            .font(theme.font(size: 9.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(waiting > 0 ? Color.black.opacity(0.85) : theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(waiting > 0 ? theme.warning : Color.white.opacity(0.1)))
            .accessibilityLabel(waiting > 0 ? "\(waiting) waiting for you" : "\(sessions.sessions.count) sessions")
    }

    static func title(for tab: PanelTab) -> String {
        switch tab {
        case .sessions: return "Sessions"
        case .usage: return "Usage"
        case .activity: return "Activity"
        }
    }

    static func symbol(for tab: PanelTab) -> String {
        switch tab {
        case .sessions: return "rectangle.stack.fill"
        case .usage: return "chart.bar.fill"
        case .activity: return "waveform.path.ecg"
        }
    }
}

// MARK: - Demo footer

struct PanelDemoBar: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.perchActions) private var actions

    var body: some View {
        let theme = Theme.current(settings)
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "theatermasks.fill")
                .font(theme.font(size: 10, weight: .semibold))
                .foregroundStyle(theme.ask)
            // Say it in full when there is room, briefly when there is not.
            Text("Demo")
            .font(theme.font(.caption))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            Spacer(minLength: Theme.Spacing.xs)
            Button("Exit demo") { actions.setDemo(false) }
                .buttonStyle(.perch(.secondary, size: .small))
        }
        .padding(.leading, Theme.Spacing.xl)
        .padding(.trailing, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.l)
        .background(alignment: .top) { PerchDivider() }
    }
}
