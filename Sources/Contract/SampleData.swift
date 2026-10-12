// SampleData.swift — realistic fake data for demo mode, snapshots and tests.
//
// Nothing here touches real sessions. `SampleData.env()` gives a fully populated AppEnv so any
// view can be rendered on its own.

import Foundation

enum SampleData {
    static let now = Date()

    static func tool(_ name: String, _ summary: String, ago: TimeInterval, took: TimeInterval? = 2, ok: Bool? = true) -> ToolCall {
        let start = now.addingTimeInterval(-ago)
        return ToolCall(id: UUID().uuidString, name: name, summary: summary, startedAt: start,
                        finishedAt: took.map { start.addingTimeInterval($0) }, succeeded: took == nil ? nil : ok)
    }

    static func session(_ agent: AgentKind, _ sid: String, title: String, cwd: String, state: SessionState,
                        model: String?, ago: TimeInterval, bundleID: String? = "com.apple.Terminal") -> Session {
        var s = Session(id: Session.makeID(agent, sid), agent: agent, sessionID: sid, cwd: cwd, title: title, model: model,
                        state: state, stateSince: now.addingTimeInterval(-min(ago, 45)), startedAt: now.addingTimeInterval(-ago),
                        lastEventAt: now.addingTimeInterval(-3))
        s.terminal = TerminalInfo(bundleID: bundleID, termProgram: "Apple_Terminal", tty: "/dev/ttys00\(abs(sid.hashValue) % 9)")
        s.pid = 4242
        s.gitBranch = "main"
        s.turnCount = 3
        s.toolCount = 17
        s.recentTools = [
            tool("Read", "Read Package.swift", ago: 300), tool("Grep", "Search for \"NotchPanel\"", ago: 240),
            tool("Edit", "Edit Sources/App/NotchPanel.swift", ago: 200, took: 4), tool("Bash", "swift build", ago: 150, took: 31),
            tool("Bash", "swift test", ago: 100, took: 12, ok: false), tool("Edit", "Edit Tests/PanelTests.swift", ago: 60, took: 3),
        ]
        return s
    }

    static var sessions: [Session] {
        var working = session(.claude, "s-working", title: "Add a settings screen with theme picker", cwd: "/Users/you/code/perch",
                              state: .runningTool, model: "Opus 5.5", ago: 840)
        working.currentTool = tool("Bash", "scripts/build.sh release", ago: 14, took: nil)
        working.contextPercent = 42
        working.activeSubagents = 2
        working.lastPrompt = "Add a settings screen with a theme picker and persist the choice"

        var approval = session(.claude, "s-approval", title: "Clean up the build folder and rerun tests", cwd: "/Users/you/code/sightsense",
                               state: .needsApproval, model: "Sonnet 5.5", ago: 310)
        approval.contextPercent = 71
        approval.gitBranch = "feature/camera-pipeline"

        var question = session(.claude, "s-question", title: "Set up the web dashboard", cwd: "/Users/you/code/dashboard",
                               state: .needsAnswer, model: "Opus 5.5", ago: 95, bundleID: "com.googlecode.iterm2")
        question.contextPercent = 12

        var plan = session(.claude, "s-plan", title: "Refactor the session engine", cwd: "/Users/you/code/perch",
                           state: .planReview, model: "Fable 5.1", ago: 420)
        plan.contextPercent = 33

        var done = session(.codex, "s-done", title: "Write unit tests for the parser", cwd: "/Users/you/code/parser",
                           state: .done, model: "gpt-5.5-codex", ago: 1900)
        done.lastMessage = "All 42 tests pass. I added coverage for nested arrays and malformed input, and fixed an off-by-one in `advance()`."
        done.contextPercent = 58

        var failed = session(.claude, "s-failed", title: "Migrate the database schema", cwd: "/Users/you/code/api",
                             state: .failed, model: "Opus 5.5", ago: 2600)
        failed.errorText = "Rate limit reached. Resets at 3:00 PM."

        var idle = session(.antigravity, "s-idle", title: "Prototype the onboarding flow", cwd: "/Users/you/code/onboarding",
                           state: .idle, model: "Gemini 3 Pro", ago: 5400, bundleID: "com.google.antigravity")
        idle.isHeadless = true

        var thinking = session(.gemini, "s-thinking", title: "Explain the caching layer", cwd: "/Users/you/code/api",
                               state: .working, model: "Gemini 3 Pro", ago: 30)
        thinking.contextPercent = 5

        return [working, approval, question, plan, done, failed, idle, thinking]
    }

    static var bashPermission: PermissionRequest {
        PermissionRequest(toolName: "Bash", summary: "Run a shell command", detail: "rm -rf build && scripts/test.sh Engine Sources/Core/Engine",
                          diff: nil,
                          suggestions: [PermissionSuggestion(id: 0, label: "Always allow scripts/test.sh in this project", raw: .null)],
                          isDangerous: true)
    }

    static var editPermission: PermissionRequest {
        let lines: [DiffLine] = [
            DiffLine(kind: .header, text: "@@ -12,7 +12,9 @@ final class NotchPanel: NSPanel {"),
            DiffLine(kind: .context, text: "        isFloatingPanel = true"),
            DiffLine(kind: .removed, text: "        level = .statusBar"),
            DiffLine(kind: .added, text: "        level = .mainMenu + 3"),
            DiffLine(kind: .added, text: "        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]"),
            DiffLine(kind: .context, text: "        hasShadow = false"),
            DiffLine(kind: .context, text: "    }"),
        ]
        return PermissionRequest(toolName: "Edit", summary: "Edit a file", detail: "Sources/App/Shell/NotchPanel.swift",
                                 diff: DiffPreview(filePath: "Sources/App/Shell/NotchPanel.swift", lines: lines, added: 2, removed: 1, truncated: false),
                                 suggestions: [PermissionSuggestion(id: 0, label: "Always allow edits in this session", raw: .null)])
    }

    static var question: QuestionRequest {
        QuestionRequest(questions: [
            Question(id: 0, text: "Which framework should the dashboard use?", header: "Framework", options: [
                QuestionOption(id: 0, label: "React", detail: "Largest ecosystem, most examples"),
                QuestionOption(id: 1, label: "Svelte", detail: "Smaller bundles, less boilerplate"),
                QuestionOption(id: 2, label: "Plain HTML", detail: "No build step at all"),
            ], multiSelect: false),
            Question(id: 1, text: "Which features do you want in the first version?", header: "Scope", options: [
                QuestionOption(id: 0, label: "Live charts", detail: nil),
                QuestionOption(id: 1, label: "Dark mode", detail: nil),
                QuestionOption(id: 2, label: "CSV export", detail: nil),
            ], multiSelect: true),
        ])
    }

    static var plan: PlanRequest {
        PlanRequest(markdown: """
        # Refactor the session engine

        ## Goal
        Split the 600-line `SessionEngine` into a pure reducer and a thin coordinator so state changes are testable.

        ## Steps
        1. Extract `SessionReducer.reduce(_:event:)` with **no side effects**.
        2. Move timers and liveness checks into `SessionHousekeeper`.
        3. Add tests replaying captured hook payloads from `Fixtures/claude/hooks`.

        ## Risks
        - Pending requests must survive the move; cover with a round-trip test.
        - `resolve` ordering when two requests arrive at once.

        ```swift
        static func reduce(_ session: inout Session, _ event: AgentEvent, at date: Date)
        ```
        """, filePath: "/Users/you/.claude/plans/refactor-engine.md")
    }

    static var pending: [PendingRequest] {
        [
            PendingRequest(sessionID: Session.makeID(.claude, "s-approval"), agent: .claude, kind: .permission(bashPermission),
                           createdAt: now.addingTimeInterval(-20), raw: .null),
            PendingRequest(sessionID: Session.makeID(.claude, "s-question"), agent: .claude, kind: .question(question),
                           createdAt: now.addingTimeInterval(-8), raw: .null),
            PendingRequest(sessionID: Session.makeID(.claude, "s-plan"), agent: .claude, kind: .plan(plan),
                           createdAt: now.addingTimeInterval(-4), raw: .null),
        ]
    }

    static var editPending: PendingRequest {
        PendingRequest(sessionID: Session.makeID(.claude, "s-approval"), agent: .claude, kind: .permission(editPermission),
                       createdAt: now.addingTimeInterval(-5), raw: .null)
    }

    static func totals(_ scale: Double) -> TokenTotals {
        TokenTotals(input: Int(180_000 * scale), output: Int(64_000 * scale), cacheWrite: Int(420_000 * scale),
                    cacheRead: Int(5_200_000 * scale), costUSD: 7.85 * scale, messages: Int(310 * scale))
    }

    static var usage: [AgentKind: AgentUsage] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let days: [DayUsage] = (0..<30).reversed().map { back in
            let scale = 0.25 + Double((back * 37) % 11) / 8.0
            let day = formatter.string(from: now.addingTimeInterval(TimeInterval(-86_400 * back)))
            return DayUsage(day: day, totals: totals(scale),
                            byModel: ["claude-opus-5-5": totals(scale * 0.7), "claude-sonnet-5-5": totals(scale * 0.3)],
                            byProject: ["perch": totals(scale * 0.6), "sightsense": totals(scale * 0.4)])
        }
        let claude = AgentUsage(agent: .claude, windows: [
            RateWindow(id: "5h", label: "5-hour limit", usedPercent: 37, resetsAt: now.addingTimeInterval(2.4 * 3600)),
            RateWindow(id: "7d", label: "Weekly limit", usedPercent: 82, resetsAt: now.addingTimeInterval(3.2 * 86_400)),
        ], planName: "Max", today: totals(1), days: days, allTime: totals(140), updatedAt: now.addingTimeInterval(-40),
           note: "Limits update whenever a Claude Code session is active.")
        let codex = AgentUsage(agent: .codex, windows: [
            RateWindow(id: "primary", label: "5-hour limit", usedPercent: 12, resetsAt: now.addingTimeInterval(4.1 * 3600)),
        ], planName: nil, today: totals(0.2), days: Array(days.suffix(7)), allTime: totals(9), updatedAt: now.addingTimeInterval(-900), note: nil)
        return [.claude: claude, .codex: codex]
    }

    static var activityDays: [DailyActivity] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<14).reversed().map { back in
            let k = (back * 53) % 9
            return DailyActivity(day: formatter.string(from: now.addingTimeInterval(TimeInterval(-86_400 * back))),
                                 activeSeconds: 1800 + k * 1500, sessionsStarted: 2 + k % 5, turnsFinished: 6 + k * 2,
                                 toolCalls: 40 + k * 23, approvalsHandled: 3 + k, questionsAnswered: k % 3,
                                 longestTaskSeconds: 240 + k * 130, peakConcurrent: 1 + k % 4)
        }
    }

    static var activity: [ActivityEntry] {
        let rows: [(ActivityEntry.Direction, String, String, String)] = [
            (.incoming, "PermissionRequest", "Claude wants to run `rm -rf build && scripts/test.sh`", #"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#),
            (.incoming, "PreToolUse", "Claude is about to run Bash", #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#),
            (.outgoing, "Decision", "You allowed Edit on NotchPanel.swift", #"{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}"#),
            (.incoming, "PostToolUse", "Edit finished", #"{"hook_event_name":"PostToolUse","tool_name":"Edit"}"#),
            (.incoming, "UserPromptSubmit", "You sent a prompt", #"{"hook_event_name":"UserPromptSubmit"}"#),
            (.note, "Hooks installed", "Perch added its hooks to ~/.claude/settings.json", ""),
            (.incoming, "SessionStart", "A Claude Code session started in perch", #"{"hook_event_name":"SessionStart","source":"startup"}"#),
        ]
        return rows.enumerated().map { i, r in
            ActivityEntry(at: now.addingTimeInterval(TimeInterval(-i * 7)), direction: r.0, agent: "claude", event: r.1,
                          sessionID: Session.makeID(.claude, "s-approval"), summary: r.2, raw: r.3)
        }
    }

    static var agentStatuses: [AgentStatus] {
        [
            AgentStatus(agent: .claude, detected: true, version: "2.1.296", configPath: "~/.claude/settings.json", hookStatus: .installed,
                        capabilities: AgentCapabilities(liveEvents: true, approvals: true, questions: true, planReview: true, usage: true, jump: true),
                        detail: "Connected. 12 hooks installed."),
            AgentStatus(agent: .codex, detected: true, version: "0.130.0", configPath: "~/.codex/config.toml", hookStatus: .notInstalled,
                        capabilities: AgentCapabilities(liveEvents: true, approvals: false, questions: false, planReview: false, usage: true, jump: true),
                        detail: "Found. Click Connect to add Perch's hooks."),
            AgentStatus(agent: .antigravity, detected: false, version: nil, configPath: nil, hookStatus: .notDetected,
                        capabilities: AgentCapabilities(liveEvents: true, usage: false, jump: true),
                        detail: "Not installed on this Mac."),
            AgentStatus(agent: .gemini, detected: false, version: nil, configPath: nil, hookStatus: .notDetected,
                        capabilities: AgentCapabilities(liveEvents: true, usage: false, jump: true),
                        detail: "Not installed on this Mac."),
        ]
    }

    /// A fully populated environment. `expanded` chooses pill or open panel.
    static func env(expanded: Bool = true, sessions chosen: [Session]? = nil, pending chosenPending: [PendingRequest]? = nil,
                    settings: AppSettings? = nil) -> AppEnv {
        let defaults = UserDefaults(suiteName: "local.perch.sample.\(UUID().uuidString)") ?? .standard
        let env = AppEnv(settings: settings ?? AppSettings(defaults: defaults))
        env.sessions.sessions = chosen ?? sessions
        let ids = Set(env.sessions.sessions.map { $0.id })
        env.sessions.pending = (chosenPending ?? pending).filter { ids.contains($0.sessionID) }
        env.sessions.activity = activity
        env.usage.usage = usage
        env.usage.activityDays = activityDays
        env.usage.lastRefresh = now.addingTimeInterval(-40)
        env.agents.statuses = agentStatuses
        env.agents.serverRunning = true
        env.agents.helperInstalled = true
        env.ui.isExpanded = expanded
        env.ui.isDemo = true
        return env
    }
}
