// SessionListView.swift — the Sessions tab: things waiting for you on top, then every session.
//
//   NEEDS YOU  2
//     [approval card]  [question card]      ← from the cards module, chosen by request kind
//   SESSIONS  8                 (sort ▾)
//     [session card] ...                    ← ordered by SessionSorting
//
// With no sessions at all it shows a friendly explanation of how to start one.

import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var ui: UIState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let pending = sessions.pending
        let groups = SessionSorting.grouped(sessions.sessions, by: settings.sortMode)
        let calm = settings.prefersCalm(systemReduceMotion)

        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if !pending.isEmpty {
                ForEach(pending) { request in
                    requestCard(request)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }

            if sessions.sessions.isEmpty {
                if pending.isEmpty { NoSessionsView() }
            } else {
                ForEach(groups) { group in
                    if let title = group.title {
                        ProjectGroupLabel(title: title, count: group.sessions.count)
                    }
                    ForEach(group.sessions) { session in
                        SessionCardView(session: session)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                }
            }
        }
        .animation(PerchMotion.quick(reduce: calm), value: pending.map(\.id))
        .animation(PerchMotion.quick(reduce: calm), value: groups.flatMap { $0.sessions.map(\.id) })
        .onChange(of: pending.map(\.id), initial: true) { _, ids in keepFocusValid(ids) }
    }

    /// The card view for a request, picked by what kind of request it is.
    @ViewBuilder
    private func requestCard(_ request: PendingRequest) -> some View {
        let session = sessions.session(id: request.sessionID)
        Group {
            switch request.kind {
            case .permission: ApprovalCardView(request: request, session: session)
            case .question: QuestionCardView(request: request, session: session)
            case .plan: PlanCardView(request: request, session: session)
            }
        }
        // Keyboard shortcuts act on the focused request: the one under the pointer.
        .onHover { inside in
            if inside { ui.focusedRequestID = request.id }
        }
    }

    /// Makes sure `focusedRequestID` always points at a request that still exists (the oldest by default).
    private func keepFocusValid(_ ids: [UUID]) {
        if let focused = ui.focusedRequestID, ids.contains(focused) { return }
        if ui.focusedRequestID != ids.first { ui.focusedRequestID = ids.first }
    }
}

/// The small button in the "Sessions" header that steps through the sort orders.
private struct SortButton: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(settings)
        Button {
            settings.sortMode = SessionSorting.next(after: settings.sortMode)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(theme.font(size: 8.5, weight: .semibold))
                Text(SessionSorting.label(for: settings.sortMode))
                    .font(theme.font(size: 10.5, weight: .medium))
            }
            // Quieter than a normal button: it sits inside a section header.
            .foregroundStyle(hovering ? theme.textPrimary : theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Change the order of the sessions")
        .accessibilityLabel("Sort: \(SessionSorting.label(for: settings.sortMode))")
    }
}

/// The folder name above each group when sorting by project.
private struct ProjectGroupLabel: View {
    let title: String
    let count: Int

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(theme.font(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text(title)
                .font(theme.font(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            if count > 1 {
                Text("\(count)")
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.top, Theme.Spacing.xs)
    }
}

/// Shown when there are no sessions: how to start one, plus a way to see Perch in action.
private struct NoSessionsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var agents: AgentsStore
    @Environment(\.perchActions) private var actions

    /// True when Perch has looked for agents and none of them is connected yet.
    private var needsSetup: Bool {
        !agents.statuses.isEmpty && !agents.statuses.contains { $0.hookStatus == .installed || $0.hookStatus == .needsUpdate }
    }

    var body: some View {
        let theme = Theme.current(settings)
        if needsSetup {
            PerchEmptyState(title: "Connect an agent to begin",
                            message: "Perch listens to your coding agents through small hooks. Add them once in Settings and every new session shows up here.",
                            systemImage: "powerplug.fill") {
                HStack(spacing: Theme.Spacing.m) {
                    Button("Connect agents…") { actions.openSettings(.agents) }.buttonStyle(.perch(.primary))
                    Button("Try demo mode") { actions.setDemo(true) }.buttonStyle(.perch(.secondary))
                }
            }
        } else {
            PerchEmptyState(title: "No sessions yet",
                            message: "Start a coding agent in any terminal and it appears here by itself. For example:",
                            systemImage: "terminal.fill") {
                VStack(spacing: Theme.Spacing.l) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text("$").foregroundStyle(theme.textTertiary)
                        Text("claude").foregroundStyle(theme.textPrimary)
                    }
                    .font(theme.font(.mono))
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.s)
                    .background(CardBackground(isSunken: true, cornerRadius: Theme.Radius.control))
                    HStack(spacing: Theme.Spacing.m) {
                        Button("Try demo mode") { actions.setDemo(true) }.buttonStyle(.perch(.primary))
                        Button("How it works") { actions.openSettings(.howItWorks) }.buttonStyle(.perch(.ghost))
                    }
                }
            }
        }
    }
}
