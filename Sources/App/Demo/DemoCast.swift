// DemoCast.swift — the pretend sessions that demo mode puts in the notch.
//
// Demo mode is a little play. This file is the cast list: eight made-up sessions ("roles"), each
// built from the sample data in Sources/Contract/SampleData.swift and marked `isDemo = true` so
// they can always be told apart from real sessions and removed again.
//
// Five roles are on stage when the demo starts; the other three walk on later (see DemoScript).

import Foundation

/// One pretend session. The name says what it is busy with in the story.
enum DemoRole: String, CaseIterable {
    /// Claude Code, building a feature: runs tools all the time, later asks to edit a file.
    case builder
    /// Claude Code, waiting for permission to run a risky shell command.
    case cleaner
    /// Claude Code, asks a multiple-choice question.
    case dashboard
    /// Claude Code in plan mode, proposes a plan.
    case planner
    /// Codex, finishes its task early on (confetti).
    case tester
    /// Gemini CLI, thinking and reading files.
    case explainer
    /// Claude Code, runs into a rate limit and fails.
    case migrator
    /// Antigravity, idle until late in the story.
    case prototype
}

enum DemoCast {
    /// Roles already present when the demo starts. The others join through `.startSession` steps.
    static let openingRoles: [DemoRole] = [.builder, .cleaner, .tester, .explainer, .prototype]

    /// The agent's own session id for a role, e.g. "demo-builder".
    static func agentSessionID(_ role: DemoRole) -> String { "demo-" + role.rawValue }

    /// `Session.id` for a role, e.g. "claude:demo-builder".
    static func id(_ role: DemoRole) -> String { Session.makeID(agent(role), agentSessionID(role)) }

    static func agent(_ role: DemoRole) -> AgentKind {
        switch role {
        case .builder, .cleaner, .dashboard, .planner, .migrator: return .claude
        case .tester: return .codex
        case .explainer: return .gemini
        case .prototype: return .antigravity
        }
    }

    /// The role a session plays, or nil for a real session.
    static func role(of session: Session) -> DemoRole? {
        guard session.isDemo else { return nil }
        return DemoRole.allCases.first { id($0) == session.id }
    }

    /// The sessions on stage at the start, in the state the story begins with.
    static func openingSessions(now: Date) -> [Session] {
        openingRoles.map { session($0, now: now) }
    }

    /// A fresh session for one role, as it looks the moment it enters.
    static func session(_ role: DemoRole, now: Date) -> Session {
        var session = template(role, now: now)
        session.id = id(role)
        session.sessionID = agentSessionID(role)
        session.isDemo = true
        // Sample sessions are "headless" in places; demo cards must never be hidden by that setting.
        session.isHeadless = false
        session.pid = nil
        session.lastMessage = nil
        session.errorText = nil
        session.currentTool = nil
        session.activeSubagents = 0
        session.lastEventAt = now

        switch role {
        case .builder:
            run(&session, tool: "Bash", summary: "scripts/build.sh release", now: now, ago: 14)
            session.contextPercent = 42
            session.activeSubagents = 2
        case .cleaner:
            // The opening permission request is added by the script, which also sets the state.
            enter(&session, .working, now: now, ago: 20)
            session.contextPercent = 71
        case .tester:
            run(&session, tool: "shell", summary: "cargo test parser::", now: now, ago: 9)
            session.contextPercent = 58
        case .explainer:
            enter(&session, .working, now: now, ago: 30)
            session.contextPercent = 5
        case .prototype:
            enter(&session, .idle, now: now, ago: 600)
            session.contextPercent = 18
        case .dashboard:
            enter(&session, .idle, now: now, ago: 0)
            session.contextPercent = 3
            session.turnCount = 0
            session.toolCount = 0
            session.recentTools = []
        case .planner:
            enter(&session, .idle, now: now, ago: 0)
            session.contextPercent = 8
            session.permissionMode = "plan"
            session.turnCount = 0
            session.toolCount = 0
            session.recentTools = []
        case .migrator:
            enter(&session, .idle, now: now, ago: 0)
            session.contextPercent = 64
            session.turnCount = 0
            session.toolCount = 0
            session.recentTools = []
        }
        return session
    }

    // MARK: Building blocks

    /// The sample session a role is based on, with its clock moved to `now`.
    /// (SampleData measures every time from the moment the app launched, which may be hours ago.)
    private static func template(_ role: DemoRole, now: Date) -> Session {
        let sampleID = Session.makeID(agent(role), sampleSessionID(role))
        if var sample = SampleData.sessions.first(where: { $0.id == sampleID }) {
            shift(&sample, by: now.timeIntervalSince(SampleData.now))
            return sample
        }
        // SampleData changed under us: fall back to a plain session rather than failing.
        return Session(id: id(role), agent: agent(role), sessionID: agentSessionID(role), cwd: "/Users/you/code/project",
                       title: "Example task", model: nil, state: .idle, stateSince: now, startedAt: now, lastEventAt: now)
    }

    private static func sampleSessionID(_ role: DemoRole) -> String {
        switch role {
        case .builder: return "s-working"
        case .cleaner: return "s-approval"
        case .dashboard: return "s-question"
        case .planner: return "s-plan"
        case .tester: return "s-done"
        case .explainer: return "s-thinking"
        case .migrator: return "s-failed"
        case .prototype: return "s-idle"
        }
    }

    private static func enter(_ session: inout Session, _ state: SessionState, now: Date, ago: TimeInterval) {
        session.state = state
        session.stateSince = now.addingTimeInterval(-ago)
    }

    /// Puts a session in the middle of running a tool that started `ago` seconds back.
    private static func run(_ session: inout Session, tool name: String, summary: String, now: Date, ago: TimeInterval) {
        enter(&session, .runningTool, now: now, ago: ago)
        let call = ToolCall(id: UUID().uuidString, name: name, summary: summary, startedAt: now.addingTimeInterval(-ago),
                            finishedAt: nil, succeeded: nil)
        session.currentTool = call
        session.recentTools.append(call)
        session.toolCount += 1
    }

    /// Moves every date in a session by the same amount.
    private static func shift(_ session: inout Session, by offset: TimeInterval) {
        session.startedAt.addTimeInterval(offset)
        session.stateSince.addTimeInterval(offset)
        session.lastEventAt.addTimeInterval(offset)
        session.recentTools = session.recentTools.map { tool in
            var moved = tool
            moved.startedAt.addTimeInterval(offset)
            moved.finishedAt = tool.finishedAt?.addingTimeInterval(offset)
            return moved
        }
    }
}
