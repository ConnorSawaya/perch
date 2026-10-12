// ActivityRowView.swift — one line of the activity log.
//
//   (↙)  Claude wants to run `rm -rf build && scripts/test.sh`        9:41:07 AM  ⌄
//        [C] Claude · PermissionRequest
//        { "hook_event_name": "PermissionRequest", … }                 ← only when expanded
//
// The arrow says which way the message went: in from the agent, out from Perch, or a note Perch
// wrote for itself. Clicking the line shows what was actually sent, as indented JSON that can
// be selected and copied.

import SwiftUI

struct ActivityRowView: View {
    let entry: ActivityEntry
    let isExpanded: Bool
    let toggle: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(settings)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Button(action: toggle) { summaryLine(theme) }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide the details" : "Show exactly what was sent")
                .accessibilityLabel("\(ActivityTabWording.meaning(entry.direction)): \(entry.summary)")
                .accessibilityHint(isExpanded ? "Hides the raw message" : "Shows the raw message")
            if isExpanded {
                detail(theme)
                    .padding(.leading, theme.scaled(22) + 9)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.Spacing.m)
        .background(Color.white.opacity(isExpanded ? 0.035 : (hovering ? 0.045 : 0)))
        .onHover { hovering = $0 }
    }

    // MARK: The always-visible line

    private func summaryLine(_ theme: Theme) -> some View {
        HStack(alignment: .top, spacing: 9) {
            directionMark(theme)
            VStack(alignment: .leading, spacing: 3) {
                Text(CardsInline.codeSpans(CardsWording.tidy(entry.summary) ?? entry.event, theme: theme,
                                           style: .init(size: 12.5, color: theme.textPrimary)))
                    .lineLimit(isExpanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                source(theme)
            }
            Spacer(minLength: Theme.Spacing.m)
            HStack(spacing: Theme.Spacing.s) {
                Text(ActivityTabWording.time(entry.at))
                    .font(theme.font(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.textTertiary)
                Image(systemName: "chevron.down")
                    .font(theme.font(size: 8, weight: .bold))
                    .foregroundStyle(hovering || isExpanded ? theme.textSecondary : theme.textTertiary.opacity(0.7))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .fixedSize()
            .padding(.top, 2)
        }
        .contentShape(Rectangle())
    }

    private func directionMark(_ theme: Theme) -> some View {
        let colour = colour(theme)
        let side = theme.scaled(22)
        return Image(systemName: ActivityTabWording.symbol(entry.direction))
            .font(.system(size: side * 0.42, weight: .bold))
            .foregroundStyle(colour)
            .frame(width: side, height: side)
            .background(Circle().fill(colour.opacity(0.14)))
            .help(ActivityTabWording.meaning(entry.direction))
    }

    /// Which agent, and the event's own name.
    private func source(_ theme: Theme) -> some View {
        let agentKey = ActivityTabFilter.key(entry.agent)
        return HStack(spacing: 5) {
            if let agent = AgentKind(rawValue: agentKey) {
                AgentBadge(agent, size: theme.scaled(14))
            }
            if !agentKey.isEmpty {
                Text(ActivityTabWording.shortAgentName(entry.agent))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textSecondary)
                Text("·").font(theme.font(.caption)).foregroundStyle(theme.textTertiary)
            }
            Text(CardsWording.tidy(entry.event) ?? "Event")
                .font(theme.font(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
        }
        .lineLimit(1)
    }

    private func colour(_ theme: Theme) -> Color {
        switch entry.direction {
        case .incoming: return theme.info
        case .outgoing: return theme.accent
        case .note: return theme.textSecondary
        }
    }

    // MARK: Details

    @ViewBuilder
    private func detail(_ theme: Theme) -> some View {
        if let raw = ActivityTabWording.prettyRaw(entry.raw) {
            CardsCodeBox(raw, maxHeight: 190, smallText: true)
        } else {
            Text(entry.direction == .note
                 ? "Nothing was sent or received here — this is a note Perch wrote for itself."
                 : "No raw message was kept for this event.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
