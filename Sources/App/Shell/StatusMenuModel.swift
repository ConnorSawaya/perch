// StatusMenuModel.swift — the words and ticks shown in the menu-bar icon's menu (pure).
//
// StatusItemController builds one of these from the stores and copies it into the real menu.
// Keeping the wording here, away from AppKit, lets it be unit-tested.

import Foundation

struct StatusMenuModel: Equatable {
    /// First line of the menu, e.g. "3 sessions, 1 needs you".
    var statusLine: String
    /// True when at least one session is waiting for the user; the icon shows a dot.
    var needsAttention: Bool
    /// "Open Panel" or "Close Panel".
    var panelItemTitle: String
    /// Tick beside "Mute Sounds".
    var isMuted: Bool
    /// Tick beside "Demo Mode".
    var isDemo: Bool

    init(sessionCount: Int, needingYou: Int, isExpanded: Bool, soundsEnabled: Bool, isDemo: Bool) {
        statusLine = StatusMenuModel.statusLine(sessionCount: sessionCount, needingYou: needingYou)
        needsAttention = needingYou > 0
        panelItemTitle = isExpanded ? "Close Panel" : "Open Panel"
        isMuted = !soundsEnabled
        self.isDemo = isDemo
    }

    init(env: AppEnv) {
        self.init(sessionCount: env.sessions.sessions.count,
                  needingYou: StatusMenuModel.needingYou(sessions: env.sessions.sessions, pending: env.sessions.pending),
                  isExpanded: env.ui.isExpanded, soundsEnabled: env.settings.soundsEnabled, isDemo: env.ui.isDemo)
    }

    /// How many sessions are waiting for the user. A session counts if its state says so or if
    /// one of its requests is still in the queue, so the number is right even mid-update.
    static func needingYou(sessions: [Session], pending: [PendingRequest]) -> Int {
        var waiting = Set(sessions.filter { $0.state.needsAttention }.map(\.id))
        waiting.formUnion(pending.map(\.sessionID))
        return waiting.count
    }

    static func statusLine(sessionCount: Int, needingYou: Int) -> String {
        let waiting = max(0, needingYou)
        // A session that is waiting is certainly a session, whatever the other count says.
        let count = max(sessionCount, waiting)
        guard count > 0 else { return "No sessions running" }
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        switch waiting {
        case 0: return sessions
        case 1: return "\(sessions), 1 needs you"
        default: return "\(sessions), \(waiting) need you"
        }
    }
}
