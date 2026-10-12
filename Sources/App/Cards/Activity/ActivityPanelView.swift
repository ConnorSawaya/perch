// ActivityPanelView.swift — the Activity tab: a live log of what passes between agents and Perch.
//
//   [ All | In | Out | Notes ]   [ All | Claude | Codex ]                     Clear
//   ┌────────────────────────────────────────────────────────────────────────────┐
//   │ (↙) Claude wants to run `rm -rf build …`                      9:41:07 AM ⌄ │
//   │     [C] Claude · PermissionRequest                                         │
//   │ (↗) You allowed Edit on NotchPanel.swift                      9:41:00 AM ⌄ │
//   └────────────────────────────────────────────────────────────────────────────┘
//   7 events · newest first
//
// It reads SessionStore.activity (newest first, kept short by the engine) and never changes it;
// "Clear" asks the app to empty the log (AppActions.clearActivityLog()). Clicking a line opens
// the raw message. The panel scrolls this view as a whole, so it has no scroll view of its own.

import SwiftUI

struct ActivityPanelView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: SessionStore
    @Environment(\.perchActions) private var actions

    @State private var filter = ActivityTabFilter()
    /// Entries whose raw message is showing.
    @State private var expanded: Set<UUID> = []
    /// Rows (by position) drawn expanded from the start; only snapshots use this.
    @State private var previewRows: Set<Int>
    /// How many entries are drawn. The log can hold hundreds; drawing them all at once is wasteful.
    @State private var shownLimit = ActivityPanelView.pageSize

    private static let pageSize = 50

    /// - Parameter preview: Draws some rows already expanded. Only for snapshots; the app leaves it out.
    init(preview: CardsPreview = CardsPreview()) {
        self._previewRows = State(initialValue: preview.expandedRows)
    }

    var body: some View {
        let theme = Theme.current(settings)
        let all = sessions.activity
        if all.isEmpty {
            emptyLog
        } else {
            let matching = filter.apply(to: all)
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                controls(all, theme)
                if matching.isEmpty {
                    PerchEmptyState(title: "Nothing matches", message: "No event in the log fits this filter.",
                                    systemImage: "line.3.horizontal.decrease.circle") {
                        Button("Show everything") { filter = ActivityTabFilter() }.buttonStyle(.perch(.secondary))
                    }
                } else {
                    rows(Array(matching.prefix(shownLimit)), theme)
                    footer(shown: min(shownLimit, matching.count), of: matching.count, theme)
                }
            }
        }
    }

    // MARK: Filters and Clear

    private func controls(_ all: [ActivityEntry], _ theme: Theme) -> some View {
        let agents = ActivityTabFilter.agents(in: all)
        return HStack(alignment: .top, spacing: Theme.Spacing.m) {
            CardsFlow(spacing: Theme.Spacing.m, lineSpacing: Theme.Spacing.s) {
                CardsSegmentedPicker([
                    .init(nil, "All", help: "Every kind of event"),
                    .init(ActivityEntry.Direction.incoming, "In", help: "Messages that came in from an agent"),
                    .init(ActivityEntry.Direction.outgoing, "Out", help: "Answers Perch sent back"),
                    .init(ActivityEntry.Direction.note, "Notes", help: "Notes Perch wrote for itself"),
                ], selection: $filter.direction)
                // Filtering by agent only makes sense when more than one agent has been seen.
                if agents.count > 1 {
                    CardsSegmentedPicker([.init(nil, "All agents", help: "Events from every agent")]
                                         + agents.map { .init(Optional($0), ActivityTabFilter.label(for: $0, in: all),
                                                              help: "Only \(CardsWording.agentName($0))") },
                                         selection: $filter.agent)
                }
            }
            Spacer(minLength: 0)
            Button {
                expanded = []
                previewRows = []
                actions.clearActivityLog()
            } label: {
                CardsButtonLabel("Clear", systemImage: "trash")
            }
            .buttonStyle(.perch(.ghost, size: .small))
            .padding(.trailing, -Theme.Spacing.s)
            .help("Empty this log (it does not affect your agents)")
        }
        .padding(.bottom, Theme.Spacing.xxs)
    }

    // MARK: Rows

    private func rows(_ entries: [ActivityEntry], _ theme: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { PerchDivider() }
                ActivityRowView(entry: entry, isExpanded: expanded.contains(entry.id) || previewRows.contains(index)) {
                    if previewRows.remove(index) != nil { return }
                    if expanded.remove(entry.id) == nil { expanded.insert(entry.id) }
                }
            }
        }
        .background(CardBackground())
        .clipShape(shape)
    }

    private func footer(shown: Int, of total: Int, _ theme: Theme) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Text(shown < total
                 ? "Showing the newest \(shown) of \(CardsWording.counted(total, "event"))"
                 : "\(CardsWording.counted(total, "event")) · newest first")
                .font(theme.font(.caption))
                .foregroundStyle(theme.textTertiary)
            Spacer(minLength: 0)
            if shown < total {
                Button("Show \(min(Self.pageSize, total - shown)) more") { shownLimit += Self.pageSize }
                    .buttonStyle(.perch(.ghost, size: .small))
            }
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyLog: some View {
        if settings.activityLogEnabled {
            PerchEmptyState(title: "Nothing has happened yet",
                            message: "This is Perch's logbook. Every message an agent sends through its hooks appears here as it arrives, along with each answer you give. Start a session to see it fill up.",
                            systemImage: "waveform.path.ecg")
        } else {
            PerchEmptyState(title: "The activity log is switched off",
                            message: "Perch is not keeping a record of the messages it exchanges with your agents. You can switch the log back on in Settings.",
                            systemImage: "eye.slash.fill") {
                Button("Open Settings…") { actions.openSettings(.advanced) }.buttonStyle(.perch(.secondary))
            }
        }
    }
}
