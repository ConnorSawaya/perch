// Models.swift — the plain data types every part of Perch shares.
//
// Nothing in here does any work; these are just the "nouns" of the app:
// a Session (one running agent conversation), a PendingRequest (something waiting for the
// user's answer), usage numbers, and so on.

import Foundation

// MARK: - Agents

/// The coding agents Perch knows how to talk to. Each one has an adapter in Sources/Core/Adapters.
enum AgentKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case claude, codex, antigravity, gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini CLI"
        }
    }

    /// One or two letters used in badges when there is no room for the name.
    var monogram: String {
        switch self {
        case .claude: return "C"
        case .codex: return "X"
        case .antigravity: return "A"
        case .gemini: return "G"
        }
    }
}

/// What Perch can do with an agent. Shown in Settings so it is clear what works where.
struct AgentCapabilities: Codable, Equatable {
    var liveEvents = false   // sessions appear and update in real time
    var approvals = false    // Allow / Deny from the notch
    var questions = false    // answer the agent's multiple-choice questions
    var planReview = false   // approve or reject a proposed plan
    var usage = false        // tokens / limits / cost
    var jump = false         // focus the terminal or editor window
}

enum HookStatus: String, Codable {
    case notDetected   // the agent is not installed on this Mac
    case notInstalled  // agent found, Perch hooks not set up
    case installed
    case needsUpdate   // hooks are present but point at an old helper or miss events
    case error
}

/// One row in Settings → Agents.
struct AgentStatus: Identifiable, Equatable {
    var agent: AgentKind
    var detected: Bool
    var version: String?
    var configPath: String?
    var hookStatus: HookStatus
    var capabilities: AgentCapabilities
    /// One plain-English sentence explaining the current state or the last error.
    var detail: String

    var id: String { agent.rawValue }
}

// MARK: - Sessions

enum SessionState: String, Codable, CaseIterable {
    case idle           // open, nothing happening
    case working        // thinking / generating
    case runningTool    // executing a tool (see Session.currentTool)
    case needsApproval  // blocked on a permission prompt
    case needsAnswer    // blocked on a question for the user
    case planReview     // blocked on plan approval
    case compacting     // summarizing its context
    case done           // finished the turn; waiting for the next prompt
    case failed         // the turn ended with an error (rate limit, API error...)
    case ended          // the session was closed; the card is about to disappear

    /// True when the user has to do something before the agent can continue.
    var needsAttention: Bool { self == .needsApproval || self == .needsAnswer || self == .planReview }
    /// True while the agent is busy on its own.
    var isBusy: Bool { self == .working || self == .runningTool || self == .compacting }
}

struct ToolCall: Codable, Identifiable, Equatable {
    /// The agent's tool-use id when it gives one, otherwise a generated UUID string.
    var id: String
    var name: String
    /// Short human description, e.g. "npm test" or "Edit Sources/App/main.swift".
    var summary: String
    var startedAt: Date
    var finishedAt: Date?
    var succeeded: Bool?
}

/// Everything known about where a session is running, used to jump back to it.
struct TerminalInfo: Codable, Equatable {
    /// Bundle id of the hosting app (e.g. "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode").
    var bundleID: String?
    var termProgram: String?
    var tty: String?
    var itermSessionID: String?
    var terminalSessionID: String?
    var tmuxPane: String?
    var kittyWindowID: String?
    var weztermPane: String?
}

struct Session: Identifiable, Equatable, Codable {
    /// Unique across agents: "\(agent.rawValue):\(sessionID)". Build it with `Session.makeID`.
    var id: String
    var agent: AgentKind
    /// The agent's own session identifier.
    var sessionID: String
    var cwd: String
    /// Human title: the first prompt, trimmed, or the folder name until a prompt arrives.
    var title: String
    var model: String?
    var state: SessionState
    var stateSince: Date
    var startedAt: Date
    var lastEventAt: Date
    var currentTool: ToolCall?
    /// Most recent tool calls, oldest first, capped at 24. Drives the activity sparkline.
    var recentTools: [ToolCall] = []
    var lastPrompt: String?
    /// The agent's final message of the last finished turn.
    var lastMessage: String?
    var errorText: String?
    var pid: Int32?
    var terminal = TerminalInfo()
    var transcriptPath: String?
    var gitBranch: String?
    var permissionMode: String?
    var activeSubagents = 0
    var turnCount = 0
    var toolCount = 0
    /// 0...100, share of the context window in use (nil when unknown).
    var contextPercent: Double?
    var tokensUsed: Int?
    var estimatedCostUSD: Double?
    /// True for sessions with no terminal (headless runs, desktop-app sessions).
    var isHeadless = false
    /// True for sessions created by demo mode.
    var isDemo = false

    static func makeID(_ agent: AgentKind, _ sessionID: String) -> String { "\(agent.rawValue):\(sessionID)" }

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

// MARK: - Requests that wait for the user

/// A ready-made "always allow" rule the agent offered. `raw` is echoed back unchanged if chosen.
struct PermissionSuggestion: Codable, Equatable, Identifiable {
    var id: Int
    /// Plain-English label, e.g. "Always allow `npm test` in this project".
    var label: String
    var raw: JSONValue
}

struct DiffLine: Codable, Equatable {
    enum Kind: String, Codable { case context, added, removed, header }
    var kind: Kind
    var text: String
}

struct DiffPreview: Codable, Equatable {
    var filePath: String?
    var lines: [DiffLine]
    var added: Int
    var removed: Int
    /// True when lines were cut to fit the preview limit.
    var truncated: Bool
}

struct PermissionRequest: Codable, Equatable {
    var toolName: String
    /// One line: what the tool wants to do, e.g. "Run a shell command".
    var summary: String
    /// The thing itself: the command, the file path, the URL...
    var detail: String
    var diff: DiffPreview?
    var suggestions: [PermissionSuggestion] = []
    /// True for commands worth a second look (rm -rf, sudo, force push, curl | sh...).
    var isDangerous = false
}

struct QuestionOption: Codable, Equatable, Identifiable {
    var id: Int
    var label: String
    var detail: String?
}

struct Question: Codable, Equatable, Identifiable {
    var id: Int
    /// Full question text. Also the key used when sending answers back.
    var text: String
    /// Short tag shown above the question, e.g. "Framework".
    var header: String?
    var options: [QuestionOption]
    var multiSelect: Bool
}

struct QuestionRequest: Codable, Equatable {
    var questions: [Question]
}

struct PlanRequest: Codable, Equatable {
    var markdown: String
    var filePath: String?
}

enum RequestKind: Codable, Equatable {
    case permission(PermissionRequest)
    case question(QuestionRequest)
    case plan(PlanRequest)
}

/// Something a session is blocked on. Lives in SessionStore.pending until answered or withdrawn.
struct PendingRequest: Identifiable, Equatable {
    var id = UUID()
    /// `Session.id` of the session that asked.
    var sessionID: String
    var agent: AgentKind
    var kind: RequestKind
    var createdAt: Date
    /// The agent's original payload. The adapter needs it to build the reply (e.g. to echo tool input).
    var raw: JSONValue
}

/// The user's answer to a PendingRequest.
enum Decision: Equatable {
    case allow
    /// Allow and remember, using `PermissionRequest.suggestions[id]`.
    case allowAlways(suggestionID: Int)
    case deny(message: String?)
    /// Answers keyed by `Question.text`. Multi-select answers are labels joined with ", ".
    case answer([String: String])
    case approvePlan(acceptEdits: Bool)
    case rejectPlan(feedback: String)
    /// "Let me answer in the terminal": Perch steps aside and the agent shows its own prompt.
    case passToTerminal
}

// MARK: - Usage

/// One rate-limit window, e.g. Claude's 5-hour or weekly limit.
struct RateWindow: Codable, Equatable, Identifiable {
    /// Short stable key: "5h", "7d", "primary", "secondary"...
    var id: String
    /// Label for display: "5-hour limit", "Weekly limit".
    var label: String
    /// 0...100.
    var usedPercent: Double
    var resetsAt: Date?
}

struct TokenTotals: Codable, Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    /// Estimated at list prices. Not a bill.
    var costUSD = 0.0
    var messages = 0

    var total: Int { input + output + cacheWrite + cacheRead }

    static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
                    cacheRead: a.cacheRead + b.cacheRead, costUSD: a.costUSD + b.costUSD, messages: a.messages + b.messages)
    }

    static func += (a: inout TokenTotals, b: TokenTotals) { a = a + b }
}

struct DayUsage: Codable, Equatable, Identifiable {
    /// Local calendar day, "yyyy-MM-dd".
    var day: String
    var totals = TokenTotals()
    var byModel: [String: TokenTotals] = [:]
    var byProject: [String: TokenTotals] = [:]

    var id: String { day }
}

struct AgentUsage: Codable, Equatable {
    var agent: AgentKind
    var windows: [RateWindow] = []
    var planName: String?
    var today = TokenTotals()
    /// Recent days, oldest first (up to 90).
    var days: [DayUsage] = []
    var allTime = TokenTotals()
    var updatedAt: Date?
    /// Plain-English caveat shown under the numbers, e.g. where the limits come from.
    var note: String?
}

/// Perch's own tally of how you worked each day (nothing leaves the Mac).
struct DailyActivity: Codable, Equatable, Identifiable {
    var day: String
    var activeSeconds = 0
    var sessionsStarted = 0
    var turnsFinished = 0
    var toolCalls = 0
    var approvalsHandled = 0
    var questionsAnswered = 0
    var longestTaskSeconds = 0
    var peakConcurrent = 0

    var id: String { day }
}

// MARK: - Activity inspector

/// One line in the "what just happened" log that makes Perch's plumbing visible.
struct ActivityEntry: Identifiable, Equatable {
    enum Direction: String { case incoming, outgoing, note }
    var id = UUID()
    var at: Date
    var direction: Direction
    var agent: String
    /// Raw event name ("PreToolUse") or a short note title.
    var event: String
    var sessionID: String?
    /// One plain-English line: "Claude wants to run `npm test`".
    var summary: String
    /// The raw JSON (truncated) for people who want to see exactly what was sent.
    var raw: String
}
