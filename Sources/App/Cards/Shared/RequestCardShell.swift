// RequestCardShell.swift — the frame all three request cards (approval, question, plan) share.
//
//   ┌────────────────────────────────────────────────────────────────┐
//   │ [C]  ✋ Run a shell command                        [Bash]   20s │  what is being asked · tag · waiting time
//   │      sightsense · Clean up the build folder and rerun tests    │  where it comes from
//   │                                                                │
//   │      ...the card's own content and buttons...                  │
//   └────────────────────────────────────────────────────────────────┘
//
// It also enforces the one rule every card must follow: an answer is sent ONCE. The content gets
// a `send` function; calling it hands the decision to AppActions and locks the card's controls,
// so a double click cannot answer twice. The card normally disappears a moment later (the engine
// removes the request). If it is somehow still there after a few seconds the controls unlock
// again, so the user is never stuck with a dead card.

import SwiftUI

/// A small label at the top right of a request card: the tool's name, or "2 of 3".
struct RequestCardTag {
    var text: String
    var systemImage: String?
    var monospaced = false
}

struct RequestCardShell<Content: View>: View {
    private let request: PendingRequest
    private let session: Session?
    private let symbol: String
    private let title: String
    private let tint: Color
    private let tag: RequestCardTag?
    private let content: (_ send: @escaping (Decision) -> Void) -> Content

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @Environment(\.perchActions) private var actions
    /// When the answer was sent. Non-nil locks the controls.
    @State private var sentAt: Date?

    /// - Parameters:
    ///   - symbol: SF Symbol shown before the title.
    ///   - tint: The card's colour: warning for approvals, the "ask" colour for questions and plans.
    ///   - content: The card's body. It receives `send`, the only way to answer the request.
    init(request: PendingRequest, session: Session?, symbol: String, title: String, tint: Color, tag: RequestCardTag? = nil,
         @ViewBuilder content: @escaping (_ send: @escaping (Decision) -> Void) -> Content) {
        self.request = request
        self.session = session
        self.symbol = symbol
        self.title = title
        self.tint = tint
        self.tag = tag
        self.content = content
    }

    /// How long a sent answer keeps the card locked before the controls come back.
    private static var unlockDelay: UInt64 { 3_000_000_000 }

    var body: some View {
        let theme = Theme.current(settings)
        VStack(alignment: .leading, spacing: 10) {
            header(theme)
            content(send)
                .disabled(sentAt != nil)
                .opacity(sentAt == nil ? 1 : 0.55)
                .environment(\.cardsHintsDimmed, ui.focusedRequestID != request.id)
        }
        .perchCard(tint: tint)
        // The rotating glow marks the card keyboard shortcuts act on (the one under the pointer).
        .overlay(GlowBorder(cornerRadius: Theme.Radius.card, isActive: ui.focusedRequestID == request.id))
        .task(id: sentAt) {
            guard sentAt != nil else { return }
            try? await Task.sleep(nanoseconds: Self.unlockDelay)
            if !Task.isCancelled { sentAt = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.agent.displayName): \(title)")
    }

    /// Badge, title and origin on the left; the tag and the waiting time on the right.
    /// When the title, tag and time do not fit on one line (a narrow panel, large text, a long
    /// file name) the tag moves down next to the origin line instead of squeezing the title.
    private func header(_ theme: Theme) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AgentBadge(request.agent, size: theme.scaled(28))
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        titleLine(theme, lines: 1).fixedSize()
                        Spacer(minLength: Theme.Spacing.m)
                        tagChip
                        waitingTime(theme)
                    }
                    origin(theme)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        titleLine(theme, lines: 2)
                        Spacer(minLength: Theme.Spacing.m)
                        waitingTime(theme)
                    }
                    HStack(spacing: Theme.Spacing.s) {
                        origin(theme)
                        tagChip
                    }
                }
            }
        }
    }

    private func titleLine(_ theme: Theme, lines: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(theme.font(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(theme.font(.headline))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(lines)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where the request comes from. It takes whatever width is left and never asks for more,
    /// so a long session title cannot push the header's other parts around.
    private func origin(_ theme: Theme) -> some View {
        Text(CardsWording.origin(of: request, session: session, fullPath: settings.showProjectPath))
            .font(theme.font(.caption))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var tagChip: some View {
        if let tag {
            Chip(tag.text, systemImage: tag.systemImage, style: .plain, monospaced: tag.monospaced)
        }
    }

    @ViewBuilder
    private func waitingTime(_ theme: Theme) -> some View {
        if settings.showElapsedTime {
            PerchElapsedText(since: request.createdAt)
                .font(theme.font(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .fixedSize()
                .help("How long this has been waiting for you")
        }
    }

    private func send(_ decision: Decision) {
        guard sentAt == nil else { return }
        sentAt = Date()
        actions.resolve(request, decision)
    }
}
