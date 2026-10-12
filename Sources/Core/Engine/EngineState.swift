// EngineState.swift — everything the session engine remembers, as plain values.
//
// The engine is split in two (see SessionEngine.swift):
//   - SessionReducer: pure functions that take an EngineState plus one event and change the state.
//   - SessionEngine:  the thin coordinator that owns reply handles, the timer and side effects.
// This file holds the state the reducer works on, the settings snapshot it reads, and the few
// numbers that tune its behaviour. Nothing here does any work.

import Foundation

/// The numbers that tune the engine, in one place.
enum EngineTuning {
    /// How often housekeeping runs while the engine is started.
    static let tickInterval: TimeInterval = 3
    /// A tool that starts within this many seconds of a request is assumed to belong to the same
    /// batch of parallel tool calls; a later one proves the agent moved on (see RequestCorrelation).
    static let parallelWindow: TimeInterval = 3
    /// Requests that arrive this close together in one session share a single sound.
    static let attentionBurst: TimeInterval = 1.5
    /// A "needs your permission" notification this soon after a request was settled is about that
    /// request (the two crossed on the way), not about a new one.
    static let echoWindow: TimeInterval = 2
    /// How long an ended card stays on screen before it is removed.
    static let endedCardLifetime: TimeInterval = 4
    /// How long late events for an ended session are ignored, so they cannot bring the card back.
    static let tombstoneLifetime: TimeInterval = 30
    /// A session that says "working" with no tool, no request and no events for this long is put
    /// back to idle. This is the safety net for interrupts (Esc), which fire no hook at all.
    static let stuckWorkingSeconds: TimeInterval = 600
    /// Reminders never repeat faster than this, whatever the setting says.
    static let minReminderSeconds: TimeInterval = 15
    static let recentToolsCap = 24
    static let activityCap = 300
    /// Raw JSON kept per activity-log line, in bytes.
    static let rawLogLimit = 4096
    static let titleLimit = 80
    /// Prompts and final messages are kept for display only; cap them so a pasted log cannot bloat memory.
    static let textLimit = 4000
}

/// The settings the reducer needs, copied out of AppSettings so the reducer stays a pure function.
struct EngineConfig: Equatable {
    var enabledAgents: Set<AgentKind> = Set(AgentKind.allCases)
    var showHeadlessSessions = false
    var showDesktopAppSessions = true
    var approvalsInNotch = true
    var questionsInNotch = true
    var planReviewInNotch = true
    var autoAllowReadOnly = false
    /// 0 (or less) means "never clean up".
    var idleCleanupMinutes = 120.0
    var reminderEnabled = false
    var reminderSeconds = 120.0

    init() {}

    init(settings: AppSettings) {
        enabledAgents = Set(AgentKind.allCases.filter { settings.isEnabled($0) })
        showHeadlessSessions = settings.showHeadlessSessions
        showDesktopAppSessions = settings.showDesktopAppSessions
        approvalsInNotch = settings.approvalsInNotch
        questionsInNotch = settings.questionsInNotch
        planReviewInNotch = settings.planReviewInNotch
        autoAllowReadOnly = settings.autoAllowReadOnly
        idleCleanupMinutes = settings.idleCleanupMinutes
        reminderEnabled = settings.reminderEnabled
        reminderSeconds = settings.reminderSeconds
    }
}

/// A tool call that has started and not finished yet. Used to match requests to tool calls.
struct OpenTool: Equatable {
    /// The agent's tool-use id, or the id the adapter generated.
    var id: String
    var name: String
    /// Which subagent ran it ("" = the main conversation).
    var scope: String
    /// Fingerprint of the tool's input, when the payload had one.
    var inputKey: Int?
    var startedAt: Date
}

/// A request the engine is tracking, with the extra facts the frozen `PendingRequest` has no room for.
struct TrackedRequest: Equatable {
    var request: PendingRequest
    /// True when a helper is waiting for the answer, so the request is shown as a card with buttons.
    /// False for display-only requests: the session shows that it needs the user, but the answer
    /// has to be given in the terminal, so no card is published.
    var isBlocking: Bool
    /// Which subagent asked ("" = the main conversation).
    var scope: String
    /// The tool the request is about; nil when unknown (a bare "needs permission" notification).
    var toolName: String?
    /// Id of the `OpenTool` this request was matched to, if any.
    var toolUseID: String?
    /// When the user was last alerted about it (creation, or the latest reminder).
    var lastNudgeAt: Date

    var id: UUID { request.id }
    var sessionID: String { request.sessionID }

    /// The state a session shows while this request is at the head of its queue.
    var attentionState: SessionState {
        switch request.kind {
        case .permission: return .needsApproval
        case .question: return .needsAnswer
        case .plan: return .planReview
        }
    }
}

/// Book-keeping per session that does not belong in the shared `Session` type.
struct SessionTracking: Equatable {
    /// Where a session's title came from: the folder name, then the first prompt, unless the
    /// agent supplies a title of its own.
    enum TitleSource: Equatable { case folder, prompt, agent }

    var titleSource = TitleSource.folder
    var openTools: [OpenTool] = []
    /// Ids of subagents that were seen starting; a "stopped" for any other id is ignored.
    var liveSubagents: Set<String> = []
    /// The state to return to when compaction finishes.
    var stateBeforeCompaction: SessionState?
    var lastAttentionSoundAt: Date?
    /// When a request of this session was last answered or withdrawn.
    var lastRequestSettledAt: Date?
    var endedAt: Date?
    /// The process the session's pid referred to when it was first checked.
    var process: ProcessLiveness.Identity?
    var processPID: Int32?
}

/// All engine state. `sessions` and the blocking entries of `requests` are what the store shows.
struct EngineState: Equatable {
    /// In arrival order (a card that replaces another one takes its place).
    var sessions: [Session] = []
    /// Oldest first.
    var requests: [TrackedRequest] = []
    /// Keyed by `Session.id`.
    var tracking: [String: SessionTracking] = [:]
    /// `Session.id` of sessions that ended recently, and when. Late events for them are ignored.
    var tombstones: [String: Date] = [:]

    func index(of sessionID: String) -> Int? { sessions.firstIndex { $0.id == sessionID } }
    func session(_ sessionID: String) -> Session? { sessions.first { $0.id == sessionID } }
    func requests(for sessionID: String) -> [TrackedRequest] { requests.filter { $0.sessionID == sessionID } }

    /// The requests the panel shows as cards.
    var visibleRequests: [PendingRequest] { requests.filter { $0.isBlocking }.map { $0.request } }
}

/// What to do with the reply handle that arrived together with a request event.
enum IncomingReply: Equatable {
    /// Keep the helper waiting; it now belongs to this request.
    case hold(requestID: UUID)
    /// The same request was delivered again: let the old helper go and keep this one for the same card.
    case replace(requestID: UUID)
    /// Answer "no opinion" at once so the agent shows its own prompt.
    case passthrough
    /// Answer "allow" at once (read-only tool and the user asked for that).
    case autoAllow(PendingRequest)
}

/// Something the reducer wants done. The coordinator carries these out; tests just compare them.
enum EngineEffect: Equatable {
    case pulse(Pulse.Kind, sessionID: String)
    case sound(SoundCue, sessionID: String)
    case notify(title: String, body: String, sessionID: String)
    case incomingReply(IncomingReply)
    /// Let the helper of a withdrawn request go without an answer.
    case closeReply(requestID: UUID)
    /// Encode the user's decision with the agent's adapter and send it to the waiting helper.
    case sendDecision(Decision, PendingRequest)
    /// Add a line to the activity log explaining something the engine decided by itself.
    case note(event: String, summary: String, agent: AgentKind, sessionID: String?)
}

/// Small questions about the shared types, kept here (rather than as extensions on those types)
/// so they cannot clash with helpers other modules add.
enum EngineFacts {
    /// True for the three events that may need the user's decision.
    static func isRequest(_ event: AgentEvent) -> Bool {
        switch event {
        case .permissionRequested, .questionAsked, .planProposed: return true
        default: return false
        }
    }

    static func isSessionStart(_ event: AgentEvent) -> Bool {
        if case .sessionStarted = event { return true }
        return false
    }

    /// True for answers that let the agent go ahead; false for refusals.
    static func isApproval(_ decision: Decision) -> Bool {
        switch decision {
        case .allow, .allowAlways, .answer, .approvePlan: return true
        case .deny, .rejectPlan, .passToTerminal: return false
        }
    }

    /// The name used in sentences: "Claude wants to run…".
    static func name(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini"
        }
    }

    /// A usable process id, or nil. 0 means "unknown" and 1 is launchd (what a helper sees as its
    /// parent after the agent has died), so neither identifies a session.
    static func validPID(_ pid: Int32?) -> Int32? {
        guard let pid, pid > 1 else { return nil }
        return pid
    }
}
