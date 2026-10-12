// SessionCardView.swift — one session in the panel's list.
//
//   ┌──────────────────────────────────────────────────────────────┐
//   │ [C]  Add a settings screen with theme picker   (Running) 14s │  title · state · time in state
//   │  ●   ▪ perch  ⑂ main  ◇ Opus 5.5                 ⚇2  ▬▬ 42% │  folder · branch · model · helpers · context
//   │      ▸ scripts/build.sh release                    ▂▁▅▂▇▃   │  what it is doing · recent tools
//   └──────────────────────────────────────────────────────────────┘
//
// Clicking the card jumps to its terminal. Hovering reveals a dismiss button (where the time
// was); right-clicking offers Jump, Dismiss and Copy folder path. Which details appear is
// controlled by the Appearance and Behavior settings. The small pieces are in SessionCardParts.swift.

import SwiftUI
import AppKit

struct SessionCardView: View {
    let session: Session

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var ui: UIState
    @Environment(\.perchActions) private var actions
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var hovering: Bool

    /// - Parameter previewHover: Draws the card as if the pointer were on it. Only for snapshots
    ///   and previews, which have no pointer; the app leaves it false.
    init(session: Session, previewHover: Bool = false) {
        self.session = session
        self._hovering = State(initialValue: previewHover)
    }

    var body: some View {
        let theme = Theme.current(settings)
        let stateColour = theme.color(for: session.state)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        let detail = detailLine

        HStack(alignment: .center, spacing: 9) {
            AgentBadge(session.agent, size: theme.scaled(22), state: session.state,
                       backdrop: hovering ? theme.surfaceHover : theme.island)
            VStack(alignment: .leading, spacing: 2) {
                titleRow(theme)
                if let detail {
                    Text(detail)
                        .font(theme.font(.caption))
                        .foregroundStyle(session.state.needsAttention || session.state == .failed ? stateColour : theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(shape.fill(hovering ? theme.surfaceHover : Color.clear))
        .overlay { SessionDoneBurst(sessionID: session.id) }
        .contentShape(shape)
        .onTapGesture { actions.jump(to: session) }
        .onHover(perform: hoverChanged)
        // A card that goes away while the pointer is on it never gets its "pointer left" call.
        .onDisappear { if ui.selectedSessionID == session.id { ui.selectedSessionID = nil } }
        .contextMenu { menuItems }
        .animation(PerchMotion.fade(reduce: settings.prefersCalm(systemReduceMotion)), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(session.agent.displayName), \(SessionWording.title(for: session)), \(SessionWording.label(for: session.state)), \(SessionHost(session).label)")
        .accessibilityHint("Jumps to this session")
        .accessibilityAction(named: "Dismiss") { actions.dismiss(session) }
    }

    // MARK: Rows

    /// Title on the left; on the right where it runs (CLI or App) and how long it has been in this state.
    private func titleRow(_ theme: Theme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(SessionWording.title(for: session))
                .font(theme.font(.label))
                .foregroundStyle(session.state == .ended ? theme.textSecondary : theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text(SessionHost(session).label)
                .font(theme.font(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.07)))
                .fixedSize()
            // The time and the dismiss button share one slot, so nothing shifts on hover.
            ZStack(alignment: .trailing) {
                if settings.showElapsedTime {
                    PerchElapsedText(since: session.stateSince)
                        .font(theme.font(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .frame(minWidth: theme.scaled(22), alignment: .trailing)
                        .opacity(hovering ? 0 : 1)
                }
                PerchIconButton(systemName: "xmark", help: "Remove", size: 16) {
                    actions.dismiss(session)
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .fixedSize()
        }
    }

    /// One quiet second line, only when there is something worth saying: what it is waiting for,
    /// what went wrong, or the command it is running. Idle, thinking and finished rows have none.
    private var detailLine: String? {
        switch session.state {
        case .needsApproval: return "Needs approval"
        case .needsAnswer: return "Has a question"
        case .planReview: return "Plan ready"
        case .failed: return SessionWording.meaningful(session.errorText) ?? "Failed"
        case .runningTool: return SessionWording.meaningful(session.currentTool?.summary)
        default: return nil
        }
    }

    // MARK: Actions

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        // Tell the rest of the app which card the pointer is on (keyboard shortcuts act on it).
        if inside {
            ui.selectedSessionID = session.id
        } else if ui.selectedSessionID == session.id {
            ui.selectedSessionID = nil
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Jump to Terminal") { actions.jump(to: session) }
        Button("Dismiss") { actions.dismiss(session) }
        Divider()
        Button("Copy Folder Path") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(session.cwd, forType: .string)
        }
    }
}

/// Confetti over a card when its session finishes a turn. Watches `SessionStore.pulse`.
struct SessionDoneBurst: View {
    /// The session to celebrate, or nil for "any session that is on show" (the pill uses that).
    let sessionID: String?
    var origin: UnitPoint = .center
    var style: ParticleBurst.Style = .radial

    @EnvironmentObject private var sessions: SessionStore

    var body: some View {
        let pulse = matchingPulse
        ParticleBurst(trigger: pulse?.id, triggeredAt: pulse?.at, origin: origin, style: style)
    }

    /// The latest pulse if it is a "done" for our session and that session is still listed.
    private var matchingPulse: Pulse? {
        guard let pulse = sessions.pulse, pulse.kind == .done,
              sessionID == nil || sessionID == pulse.sessionID,
              sessions.session(id: pulse.sessionID) != nil else { return nil }
        return pulse
    }
}
