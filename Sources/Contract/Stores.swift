// Stores.swift — the app's live state, as plain observable containers.
//
// Stores hold data and nothing else. Services (the engine, usage scanner, adapters) write to
// them on the main thread; views read them and redraw automatically. Views never change a store
// directly — they call an AppActions method (see Services.swift) instead.

import Foundation
import Combine
import CoreGraphics

/// A short-lived "this just happened" marker views use to trigger one-off effects (confetti, a bounce).
struct Pulse: Equatable {
    enum Kind: String { case done, failed, attention, approved, denied, started }
    var id = UUID()
    var kind: Kind
    /// `Session.id`.
    var sessionID: String
    var at: Date
}

/// Sessions and the requests waiting on the user. Written by SessionEngine.
final class SessionStore: ObservableObject {
    /// All known sessions in arrival order. Views sort them according to AppSettings.sortMode.
    @Published var sessions: [Session] = []
    /// Requests waiting for an answer, oldest first.
    @Published var pending: [PendingRequest] = []
    /// Recent events, newest first, capped at 300. Feeds the activity inspector.
    @Published var activity: [ActivityEntry] = []
    /// The most recent notable moment. Views watch this to play one-off animations.
    @Published var pulse: Pulse?

    func session(id: String) -> Session? { sessions.first { $0.id == id } }
    func pending(for sessionID: String) -> [PendingRequest] { pending.filter { $0.sessionID == sessionID } }

    var attentionCount: Int { sessions.filter { $0.state.needsAttention }.count }
    var busyCount: Int { sessions.filter { $0.state.isBusy }.count }
    /// The session most deserving of the pill's single status slot: attention first, then busy, then newest.
    var headline: Session? {
        sessions.first { $0.state.needsAttention }
            ?? sessions.filter { $0.state.isBusy }.max { $0.lastEventAt < $1.lastEventAt }
            ?? sessions.max { $0.lastEventAt < $1.lastEventAt }
    }
}

/// Usage numbers per agent plus Perch's own daily activity tally. Written by UsageEngine.
final class UsageStore: ObservableObject {
    @Published var usage: [AgentKind: AgentUsage] = [:]
    /// Recent days, oldest first (up to 90).
    @Published var activityDays: [DailyActivity] = []
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?

    /// The busiest rate-limit window across agents, for the pill.
    func window(_ id: String, agent: AgentKind = .claude) -> RateWindow? {
        usage[agent]?.windows.first { $0.id == id }
    }
}

/// Which agents are installed and whether their hooks are set up. Written by the app controller.
final class AgentsStore: ObservableObject {
    @Published var statuses: [AgentStatus] = []
    /// True while the socket server is listening.
    @Published var serverRunning = false
    /// True when the helper binary is in place at PerchPaths.helperURL.
    @Published var helperInstalled = false
    /// Result of the last install / uninstall action, in plain English.
    @Published var lastMessage: String?

    func status(_ agent: AgentKind) -> AgentStatus? { statuses.first { $0.agent == agent } }
}

enum PanelTab: String, CaseIterable, Identifiable { case sessions, usage, activity; var id: String { rawValue } }

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, behavior, sounds, approvals, agents, usage, howItWorks, advanced
    var id: String { rawValue }
}

/// Transient interface state shared between the window shell and the views.
final class UIState: ObservableObject {
    /// True while the panel is open; false shows only the pill.
    @Published var isExpanded = false
    @Published var panelTab = PanelTab.sessions
    /// The request card that has keyboard focus (shortcuts act on it).
    @Published var focusedRequestID: UUID?
    /// `Session.id` of the card the user is looking at, if they picked one.
    @Published var selectedSessionID: String?
    /// Which Settings tab is showing (the shell sets this when asked to open a specific tab).
    @Published var settingsTab = SettingsTab.general
    /// True while a text field in the panel needs typing; the window shell makes the panel key.
    @Published var needsKeyboard = false
    @Published var isDemo = false
    /// False on displays without a notch, where the pill floats under the menu bar.
    @Published var screenHasNotch = true
    /// Size of the physical notch (or the stand-in pill) in points.
    @Published var notchSize = CGSize(width: 185, height: 32)
    /// Height the views want for the expanded panel; the shell resizes the window to fit.
    @Published var desiredPanelHeight: CGFloat = 0
}

/// Bundles the stores so they can be handed around (and injected into SwiftUI) as one thing.
final class AppEnv {
    let settings: AppSettings
    let sessions: SessionStore
    let usage: UsageStore
    let agents: AgentsStore
    let ui: UIState
    /// Set once by the app controller at launch. Views reach it through `@Environment(\.perchActions)`.
    var actions: AppActions = NoopActions()

    init(settings: AppSettings = AppSettings(), sessions: SessionStore = SessionStore(), usage: UsageStore = UsageStore(),
         agents: AgentsStore = AgentsStore(), ui: UIState = UIState()) {
        self.settings = settings
        self.sessions = sessions
        self.usage = usage
        self.agents = agents
        self.ui = ui
    }
}
