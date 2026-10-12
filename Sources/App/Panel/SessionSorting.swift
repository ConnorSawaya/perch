// SessionSorting.swift — the order session cards appear in (Settings → Behavior → Sort).
//
//   attention  what needs you first, then failures, then busy, finished and idle sessions
//   recent     whatever had an event most recently first
//   project    grouped by folder name, A–Z, each group in "attention" order
//
// Ties are broken by when a session entered its current state — not by its latest event — so
// two busy cards do not swap places every time one of them runs a tool.

import Foundation

/// A run of cards shown together. Only the "project" order gives groups a title.
struct SessionGroup: Identifiable, Equatable {
    var title: String?
    var sessions: [Session]

    var id: String { title ?? "all" }
}

enum SessionSorting {
    static func sorted(_ sessions: [Session], by mode: SortMode) -> [Session] {
        switch mode {
        case .attention:
            return sessions.sorted(by: urgencyOrder)
        case .recent:
            return sessions.sorted { a, b in
                a.lastEventAt != b.lastEventAt ? a.lastEventAt > b.lastEventAt : a.id < b.id
            }
        case .project:
            return sessions.sorted { a, b in
                let left = a.projectName.lowercased(), right = b.projectName.lowercased()
                return left != right ? left < right : urgencyOrder(a, b)
            }
        }
    }

    /// The same order, cut into titled groups when sorting by project.
    static func grouped(_ sessions: [Session], by mode: SortMode) -> [SessionGroup] {
        let ordered = sorted(sessions, by: mode)
        guard mode == .project else { return ordered.isEmpty ? [] : [SessionGroup(title: nil, sessions: ordered)] }
        var groups: [SessionGroup] = []
        for session in ordered {
            if let last = groups.last, last.title?.lowercased() == session.projectName.lowercased() {
                groups[groups.count - 1].sessions.append(session)
            } else {
                groups.append(SessionGroup(title: session.projectName, sessions: [session]))
            }
        }
        return groups
    }

    /// Lower = nearer the top in the "attention" order.
    static func urgency(_ state: SessionState) -> Int {
        switch state {
        case .needsApproval, .needsAnswer, .planReview: return 0
        case .failed: return 1
        case .working, .runningTool, .compacting: return 2
        case .done: return 3
        case .idle: return 4
        case .ended: return 5
        }
    }

    private static func urgencyOrder(_ a: Session, _ b: Session) -> Bool {
        let left = urgency(a.state), right = urgency(b.state)
        if left != right { return left < right }
        if a.stateSince != b.stateSince {
            // Among sessions waiting for you, the one that has waited longest comes first;
            // everywhere else the most recent change comes first.
            return left == 0 ? a.stateSince < b.stateSince : a.stateSince > b.stateSince
        }
        return a.id < b.id
    }

    /// The words shown on the sort button.
    static func label(for mode: SortMode) -> String {
        switch mode {
        case .attention: return "Needs you first"
        case .recent: return "Most recent"
        case .project: return "By project"
        }
    }

    /// The order the sort button steps through.
    static func next(after mode: SortMode) -> SortMode {
        switch mode {
        case .attention: return .recent
        case .recent: return .project
        case .project: return .attention
        }
    }
}
