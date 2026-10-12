// DemoTests.swift — checks demo mode: the pretend story in Sources/App/Demo.
//
// Run:  scripts/test.sh Demo Sources/App/Demo
//
// Most tests build a DemoDirector with `autoAdvance: false` and walk through the story by hand
// with `advance()`, so nothing depends on timing. One test lets the real timer run (sped up).
// What is checked: the opening scene, every kind of moment the story promises (tools, a
// permission, a question, a plan, a finish, a failure, usage ticking up), the user's answers,
// that the stores always stay consistent, and above all that stopping the demo leaves real
// sessions, requests, activity and usage exactly as they were.

import Foundation

// MARK: - Fixtures

/// Preferences kept in memory only, so tests never write preference files.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

private func emptyEnv() -> AppEnv {
    AppEnv(settings: AppSettings(defaults: MemoryDefaults()))
}

/// A "real" session, request, activity line and usage reading, as if an agent were running.
private struct RealWorld {
    let session: Session
    let request: PendingRequest
    let entry: ActivityEntry
    let usage: [AgentKind: AgentUsage]
    let days: [DailyActivity]
    let refreshed: Date

    init() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var session = Session(id: Session.makeID(.claude, "real-1"), agent: .claude, sessionID: "real-1", cwd: "/Users/me/work/app",
                              title: "Fix the login bug", model: "Opus 5.5", state: .needsApproval, stateSince: start,
                              startedAt: start, lastEventAt: start)
        session.pid = 777
        self.session = session
        request = PendingRequest(sessionID: session.id, agent: .claude,
                                 kind: .permission(PermissionRequest(toolName: "Bash", summary: "Run a shell command", detail: "make test")),
                                 createdAt: start, raw: ["tool_name": "Bash"])
        entry = ActivityEntry(at: start, direction: .incoming, agent: "claude", event: "PermissionRequest",
                              sessionID: session.id, summary: "Claude wants to run `make test`", raw: "{}")
        usage = [.claude: AgentUsage(agent: .claude, windows: [RateWindow(id: "5h", label: "5-hour limit", usedPercent: 9, resetsAt: start)],
                                     planName: "Pro", today: TokenTotals(input: 5, output: 6), updatedAt: start, note: "real")]
        days = [DailyActivity(day: "2026-10-10", activeSeconds: 60, toolCalls: 3)]
        refreshed = start
    }

    func install(in env: AppEnv) {
        env.sessions.sessions = [session]
        env.sessions.pending = [request]
        env.sessions.activity = [entry]
        env.usage.usage = usage
        env.usage.activityDays = days
        env.usage.lastRefresh = refreshed
    }
}

private func demoSessions(_ env: AppEnv) -> [Session] { env.sessions.sessions.filter { $0.isDemo } }

private func demoSession(_ env: AppEnv, _ role: DemoRole) -> Session? { env.sessions.session(id: DemoCast.id(role)) }

private func demoRequest(_ env: AppEnv, _ role: DemoRole) -> PendingRequest? {
    env.sessions.pending.first { $0.sessionID == DemoCast.id(role) }
}

/// Advances until the step with this name has happened. Returns false if it never comes.
@discardableResult
private func advance(_ director: DemoDirector, through name: String) -> Bool {
    for _ in 0..<(director.steps.count + 1) {
        guard let step = director.advance() else { return false }
        if step.name == name { return true }
    }
    return false
}

private func stepName(containing text: String) -> String {
    DemoScript.steps.first { $0.name.contains(text) }?.name ?? "missing step: \(text)"
}

/// Things that must be true of the stores after every single step.
private func checkConsistency(_ t: TestRunner, _ env: AppEnv, _ label: String) {
    let sessions = env.sessions.sessions
    let ids = sessions.map { $0.id }
    t.expectEqual(Set(ids).count, ids.count, "\(label): no two sessions share an id")
    for request in env.sessions.pending {
        guard let session = env.sessions.session(id: request.sessionID) else {
            t.expect(false, "\(label): request for a session that is not in the store")
            continue
        }
        t.expect(session.state.needsAttention, "\(label): \(session.id) has a request waiting but its state is \(session.state)")
    }
    for session in sessions where session.isDemo {
        if session.state.needsAttention {
            t.expect(!env.sessions.pending(for: session.id).isEmpty, "\(label): \(session.id) is waiting for the user but has no request")
        }
        if session.state == .runningTool {
            t.expect(session.currentTool != nil, "\(label): \(session.id) is running a tool but has none")
        }
        if let tool = session.currentTool {
            t.expect(tool.finishedAt == nil, "\(label): the current tool of \(session.id) is already finished")
            t.expect(session.state == .runningTool, "\(label): \(session.id) has a current tool but state \(session.state)")
        }
        t.expect(session.recentTools.count <= 24, "\(label): recent tools are capped at 24")
        t.expect((session.contextPercent ?? 0) <= 100, "\(label): context stays within 100%")
        t.expect(session.pid == nil, "\(label): demo sessions carry no process id")
        t.expect(!session.isHeadless, "\(label): demo sessions are never headless")
    }
    for usage in env.usage.usage.values {
        for window in usage.windows {
            t.expect(window.usedPercent >= 0 && window.usedPercent <= 100, "\(label): \(window.id) stays within 0...100%")
        }
    }
    t.expect(env.sessions.activity.count <= 300, "\(label): activity log is capped at 300")
}

// MARK: - Tests

func runDemoTests(_ t: TestRunner) {
    t.test("the script is well formed") {
        t.expect(DemoScript.steps.count >= 12, "the story has enough steps to be interesting")
        t.expectEqual(Set(DemoScript.steps.map { $0.name }).count, DemoScript.steps.count, "step names are unique")
        for step in DemoScript.steps {
            t.expect(step.wait > 0 && step.wait <= 10, "\(step.name): sensible pause")
            t.expect(!step.actions.isEmpty, "\(step.name): does something")
        }
        let last = try t.unwrap(DemoScript.steps.last)
        if case .restart? = last.actions.last { t.expect(true) } else { t.expect(false, "the last step starts the story over") }
        let total = DemoScript.steps.reduce(0) { $0 + $1.wait }
        t.expect(total > 40 && total < 150, "one loop takes about a minute or two (\(total)s)")
    }

    t.test("the cast is built from sample data and marked as demo") {
        let now = Date()
        for role in DemoRole.allCases {
            let session = DemoCast.session(role, now: now)
            t.expect(session.isDemo, "\(role) is marked isDemo")
            t.expectEqual(session.id, DemoCast.id(role))
            t.expectEqual(session.id, Session.makeID(session.agent, session.sessionID), "\(role): id is built the standard way")
            t.expect(session.sessionID.hasPrefix("demo-"))
            t.expect(!session.title.isEmpty && session.title != "Example task", "\(role) found its sample session")
            t.expect(abs(session.lastEventAt.timeIntervalSince(now)) < 1, "\(role): times are relative to now")
            t.expect(session.startedAt <= now && session.stateSince <= now, "\(role): nothing starts in the future")
            t.expectEqual(DemoCast.role(of: session), role)
        }
        t.expectEqual(Set(DemoRole.allCases.map(DemoCast.id)).count, DemoRole.allCases.count, "every role has its own id")
        t.expectEqual(Set(DemoRole.allCases.map(DemoCast.agent)), Set(AgentKind.allCases), "every agent appears in the demo")
        var real = DemoCast.session(.builder, now: now)
        real.isDemo = false
        t.expectNil(DemoCast.role(of: real), "a real session never counts as a role")
    }

    t.test("start fills the stores with a believable opening scene") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        t.expect(!director.isRunning)
        director.start()
        t.expect(director.isRunning)
        t.expect(env.ui.isDemo, "the demo flag is set")
        t.expectEqual(env.sessions.sessions.count, DemoCast.openingRoles.count)
        t.expect(env.sessions.sessions.allSatisfy { $0.isDemo }, "every session is marked isDemo")
        t.expectEqual(env.sessions.pending.count, 1, "one request is waiting straight away")
        let request = try t.unwrap(env.sessions.pending.first)
        if case .permission = request.kind { t.expect(true) } else { t.expect(false, "the opening request is a permission") }
        t.expectEqual(demoSession(env, .cleaner)?.state, .needsApproval)
        t.expectEqual(env.sessions.pulse?.kind, .attention, "the opening request announces itself")
        t.expectEqual(env.sessions.pulse?.sessionID, DemoCast.id(.cleaner))
        t.expect(env.sessions.sessions.contains { $0.state.isBusy }, "something is working")
        t.expect(!env.sessions.activity.isEmpty, "the activity log has lines")
        t.expect(env.usage.usage[.claude]?.windows.isEmpty == false, "usage numbers are present")
        t.expect(!env.usage.activityDays.isEmpty)
        t.expect(env.usage.usage.values.allSatisfy { $0.note == DemoUsage.note }, "usage is labelled as demo numbers")
        checkConsistency(t, env, "opening")
    }

    t.test("start twice does not duplicate anything; stop twice is harmless") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        director.advance()
        let sessions = env.sessions.sessions
        let index = director.stepIndex
        director.start()
        t.expectEqual(env.sessions.sessions, sessions, "a second start changes nothing")
        t.expectEqual(director.stepIndex, index)
        director.stop()
        director.stop()
        t.expect(env.sessions.sessions.isEmpty && env.sessions.pending.isEmpty && env.sessions.activity.isEmpty)
        t.expect(!env.ui.isDemo)
        t.expectNil(director.advance(), "nothing happens after stop")
        t.expect(env.sessions.sessions.isEmpty)
    }

    t.test("stop before start does nothing") {
        let env = emptyEnv()
        let real = RealWorld()
        real.install(in: env)
        env.ui.isDemo = false
        let director = DemoDirector(env: env, autoAdvance: false)
        director.stop()
        t.expectEqual(env.sessions.sessions, [real.session])
        t.expectEqual(env.usage.usage, real.usage)
        t.expect(!director.handle(real.request, .allow), "an idle director claims no requests")
    }

    t.test("steps can be advanced by hand, in order, and loop") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        t.expectEqual(director.stepIndex, 0)
        var names: [String] = []
        for _ in 0..<director.steps.count {
            let step = try t.unwrap(director.advance())
            names.append(step.name)
        }
        t.expectEqual(names, DemoScript.steps.map { $0.name }, "steps happen in script order")
        t.expectEqual(director.stepIndex, 0, "back at the top")
        t.expectEqual(director.loopCount, 1)
        // After the restart step the stage looks like the opening scene again.
        t.expectEqual(Set(demoSessions(env).map { $0.id }), Set(DemoCast.openingRoles.map(DemoCast.id)))
        t.expectEqual(env.sessions.pending.count, 1)
        t.expectEqual(demoSession(env, .cleaner)?.state, .needsApproval)
        t.expectEqual(demoSession(env, .builder)?.state, .runningTool)
        t.expectEqual(director.advance()?.name, DemoScript.steps.first?.name, "the second loop starts with the first step")
    }

    t.test("every step keeps the stores consistent, for three whole loops") {
        let env = emptyEnv()
        let real = RealWorld()
        real.install(in: env)
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        checkConsistency(t, env, "start")
        var seenStates = Set<SessionState>()
        var seenPulses = Set<Pulse.Kind>()
        var sawQuestion = false, sawPlan = false, sawDiff = false
        for loop in 0..<3 {
            for _ in 0..<director.steps.count {
                let step = try t.unwrap(director.advance())
                checkConsistency(t, env, "loop \(loop), \(step.name)")
                t.expectEqual(env.sessions.session(id: real.session.id), real.session, "\(step.name): the real session is untouched")
                t.expect(env.sessions.pending.contains(real.request), "\(step.name): the real request is untouched")
                t.expect(env.sessions.activity.contains(real.entry), "\(step.name): the real activity line is still there")
                demoSessions(env).forEach { seenStates.insert($0.state) }
                if let pulse = env.sessions.pulse { seenPulses.insert(pulse.kind) }
                for request in env.sessions.pending where request.id != real.request.id {
                    switch request.kind {
                    case .question: sawQuestion = true
                    case .plan: sawPlan = true
                    case .permission(let permission): if permission.diff != nil { sawDiff = true }
                    }
                }
            }
        }
        t.expectEqual(director.loopCount, 3)
        for state in [SessionState.idle, .working, .runningTool, .needsApproval, .needsAnswer, .planReview, .done, .failed] {
            t.expect(seenStates.contains(state), "the story shows the \(state) state")
        }
        for kind in [Pulse.Kind.attention, .done, .failed, .started, .approved] {
            t.expect(seenPulses.contains(kind), "the story sets a \(kind) pulse")
        }
        t.expect(sawQuestion, "a question appears")
        t.expect(sawPlan, "a plan appears")
        t.expect(sawDiff, "a file edit with a diff appears")
        director.stop()
    }

    t.test("tools start and finish") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        let before = try t.unwrap(demoSession(env, .builder))
        let firstTool = try t.unwrap(before.currentTool)
        director.advance()
        let after = try t.unwrap(demoSession(env, .builder))
        let finished = try t.unwrap(after.recentTools.first { $0.id == firstTool.id }, "the first tool is in the history")
        t.expect(finished.finishedAt != nil && finished.succeeded == true, "the first tool finished")
        let second = try t.unwrap(after.currentTool)
        t.expect(second.id != firstTool.id && second.name == "Edit", "a new tool is running")
        t.expectEqual(after.toolCount, before.toolCount + 1)
        t.expectEqual(after.state, .runningTool)
        t.expect((after.contextPercent ?? 0) > (before.contextPercent ?? 0), "context use grows with tool calls")
        t.expect(env.sessions.activity.contains { $0.event == "PreToolUse" && $0.sessionID == after.id }, "tool start is logged")
        t.expect(env.sessions.activity.contains { $0.event == "PostToolUse" && $0.sessionID == after.id }, "tool finish is logged")
        // A failed tool is recorded as failed.
        advance(director, through: stepName(containing: "tests fail"))
        let failed = try t.unwrap(demoSession(env, .builder)?.recentTools.last { $0.summary == "swift test" })
        t.expectEqual(failed.succeeded, false)
    }

    t.test("an unanswered permission request resolves itself") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        let request = try t.unwrap(demoRequest(env, .cleaner))
        let resolving = stepName(containing: "cleaner's permission request resolves itself")
        // Step up to just before the resolving step: the request is still waiting.
        while director.steps[director.stepIndex].name != resolving {
            director.advance()
            t.expect(env.sessions.pending.contains(request), "still waiting before the demo steps in")
        }
        director.advance()
        t.expect(!env.sessions.pending.contains(request), "the request is gone")
        let session = try t.unwrap(demoSession(env, .cleaner))
        t.expectEqual(session.state, .runningTool, "the session carries on with the command")
        t.expect(session.currentTool?.summary.contains("rm -rf build") == true)
        let decision = try t.unwrap(env.sessions.activity.first { $0.direction == .outgoing })
        t.expect(decision.summary.hasPrefix("Nobody answered, so the demo allowed"), "the log says the demo answered: \(decision.summary)")
    }

    t.test("a question and a plan appear and resolve themselves") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        advance(director, through: stepName(containing: "dashboard asks a question"))
        let question = try t.unwrap(demoRequest(env, .dashboard))
        if case .question = question.kind { t.expect(true) } else { t.expect(false, "dashboard's request is a question") }
        t.expectEqual(demoSession(env, .dashboard)?.state, .needsAnswer)
        t.expectEqual(env.sessions.pulse?.kind, .attention)
        advance(director, through: stepName(containing: "question answers itself"))
        t.expectNil(demoRequest(env, .dashboard))
        t.expect(env.sessions.activity.contains { $0.direction == .outgoing && $0.summary.contains("answered: ") }, "the answer is logged")

        advance(director, through: stepName(containing: "planner proposes a plan"))
        let plan = try t.unwrap(demoRequest(env, .planner))
        if case .plan(let proposed) = plan.kind { t.expect(!proposed.markdown.isEmpty) } else { t.expect(false, "planner's request is a plan") }
        t.expectEqual(demoSession(env, .planner)?.state, .planReview)
        advance(director, through: stepName(containing: "plan approves itself"))
        t.expectNil(demoRequest(env, .planner))
        t.expectEqual(demoSession(env, .planner)?.state, .runningTool)
    }

    t.test("a session finishes with a done pulse; another fails") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        var cues: [SoundCue] = []
        director.onCue = { cues.append($0) }
        director.start()
        t.expectEqual(cues, [.needsApproval], "the opening request would make a sound")
        advance(director, through: stepName(containing: "tester finishes"))
        let tester = try t.unwrap(demoSession(env, .tester))
        t.expectEqual(tester.state, .done)
        t.expect(tester.lastMessage?.isEmpty == false, "it leaves a closing message")
        t.expectNil(tester.currentTool)
        t.expectEqual(env.sessions.pulse?.kind, .done)
        t.expectEqual(env.sessions.pulse?.sessionID, tester.id)
        t.expect(cues.contains(.done))

        advance(director, through: stepName(containing: "migrator hits a rate limit"))
        let migrator = try t.unwrap(demoSession(env, .migrator))
        t.expectEqual(migrator.state, .failed)
        t.expect(migrator.errorText?.contains("Rate limit") == true)
        t.expectEqual(env.sessions.pulse?.kind, .failed)
        t.expect(cues.contains(.failed) && cues.contains(.sessionStart))
    }

    t.test("a session that starts mid-story gets a card and leaves at the restart") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        t.expectNil(demoSession(env, .dashboard))
        advance(director, through: stepName(containing: "dashboard session starts"))
        let dashboard = try t.unwrap(demoSession(env, .dashboard))
        t.expectEqual(dashboard.state, .working)
        t.expectEqual(dashboard.turnCount, 1)
        t.expectEqual(dashboard.lastPrompt, "Set up the web dashboard")
        advance(director, through: stepName(containing: "starts over"))
        t.expectNil(demoSession(env, .dashboard), "late arrivals leave when the story starts over")
    }

    t.test("usage numbers tick up and reset with the story") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        let before = try t.unwrap(env.usage.window("5h"))
        let tokensBefore = env.usage.usage[.claude]?.today.total ?? 0
        let toolsBefore = env.usage.activityDays.last?.toolCalls ?? 0
        for _ in 0..<5 { director.advance() }
        let after = try t.unwrap(env.usage.window("5h"))
        t.expect(after.usedPercent > before.usedPercent, "the 5-hour reading grows (\(before.usedPercent) -> \(after.usedPercent))")
        t.expect((env.usage.usage[.claude]?.today.total ?? 0) > tokensBefore, "today's tokens grow")
        t.expect((env.usage.usage[.claude]?.today.costUSD ?? 0) > 0)
        t.expect((env.usage.activityDays.last?.toolCalls ?? 0) > toolsBefore, "today's tool tally grows")
        t.expect(env.usage.lastRefresh != nil)
        t.expect(before.resetsAt.map { $0 > Date() } ?? false, "the reset time is in the future")
        advance(director, through: stepName(containing: "starts over"))
        let reset = try t.unwrap(env.usage.window("5h"))
        t.expect(reset.usedPercent < after.usedPercent + 20 && reset.usedPercent <= 97)
        // Many loops never push a reading past the cap.
        for _ in 0..<(director.steps.count * 4) { director.advance() }
        t.expect(env.usage.usage.values.allSatisfy { $0.windows.allSatisfy { $0.usedPercent <= 97 } })
    }

    t.test("the user can allow a demo request") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        var cues: [SoundCue] = []
        director.onCue = { cues.append($0) }
        director.start()
        let request = try t.unwrap(demoRequest(env, .cleaner))
        let handledBefore = env.usage.activityDays.last?.approvalsHandled ?? 0
        t.expect(director.handle(request, .allow), "the demo takes its own request")
        t.expect(!env.sessions.pending.contains(request))
        t.expectEqual(demoSession(env, .cleaner)?.state, .working)
        t.expectEqual(env.sessions.pulse?.kind, .approved)
        t.expect(cues.contains(.approved))
        let line = try t.unwrap(env.sessions.activity.first)
        t.expectEqual(line.direction, .outgoing)
        t.expect(line.summary.hasPrefix("You allowed `rm -rf build"), line.summary)
        director.advance()
        t.expectEqual(env.usage.activityDays.last?.approvalsHandled, handledBefore + 1, "the tally counts the answer")
        t.expect(director.handle(request, .allow), "answering twice is still 'mine'")
        t.expectEqual(env.sessions.activity.filter { $0.direction == .outgoing }.count, 1, "but nothing happens the second time")
        // The story goes on and the command runs.
        advance(director, through: stepName(containing: "cleaner's permission request resolves itself"))
        t.expect(demoSession(env, .cleaner)?.currentTool?.summary.contains("rm -rf build") == true)
        t.expectEqual(env.sessions.activity.filter { $0.direction == .outgoing }.count, 1, "no second decision is logged")
    }

    t.test("a denied command never runs") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        let request = try t.unwrap(demoRequest(env, .cleaner))
        t.expect(director.handle(request, .deny(message: "Too risky")))
        let denied = try t.unwrap(demoSession(env, .cleaner))
        t.expectEqual(denied.state, .done)
        t.expect(denied.lastMessage?.contains("will not do that") == true)
        t.expectEqual(env.sessions.pulse?.kind, .denied)
        t.expect(env.sessions.activity.first?.summary.hasPrefix("You denied") == true)
        // Play the rest of the loop: the cleaner must not run the command or claim the tests passed.
        while director.steps[director.stepIndex].name != stepName(containing: "starts over") {
            director.advance()
            let cleaner = try t.unwrap(demoSession(env, .cleaner))
            t.expect(!cleaner.recentTools.contains { $0.summary.contains("rm -rf build") }, "the denied command is not run")
            t.expect(cleaner.lastMessage?.contains("128 tests") != true, "no victory message after a denial")
        }
        director.advance()
        t.expectEqual(demoSession(env, .cleaner)?.state, .needsApproval, "after the restart the request comes back")
    }

    t.test("answers, plan decisions and 'answer in terminal'") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        advance(director, through: stepName(containing: "dashboard asks a question"))
        let question = try t.unwrap(demoRequest(env, .dashboard))
        let answersBefore = env.usage.activityDays.last?.questionsAnswered ?? 0
        t.expect(director.handle(question, .answer(["Which framework should the dashboard use?": "Svelte"])))
        t.expectEqual(demoSession(env, .dashboard)?.state, .working)
        t.expect(env.sessions.activity.first?.summary == "You answered: Svelte", env.sessions.activity.first?.summary ?? "")
        director.advance()
        t.expectEqual(env.usage.activityDays.last?.questionsAnswered, answersBefore + 1)

        advance(director, through: stepName(containing: "planner proposes a plan"))
        let plan = try t.unwrap(demoRequest(env, .planner))
        t.expect(director.handle(plan, .rejectPlan(feedback: "Smaller steps please")))
        t.expectEqual(demoSession(env, .planner)?.state, .working, "a rejected plan sends the agent back to thinking")
        t.expectEqual(env.sessions.pulse?.kind, .denied)
        t.expect(env.sessions.activity.first?.summary == "You sent the plan back with feedback")
        advance(director, through: stepName(containing: "planner finishes"))
        t.expect(demoSession(env, .planner)?.state != .done, "the planner does not finish a plan that was rejected")

        advance(director, through: stepName(containing: "starts over"))
        let again = try t.unwrap(demoRequest(env, .cleaner))
        t.expect(director.handle(again, .passToTerminal))
        t.expectEqual(demoSession(env, .cleaner)?.state, .working)
        t.expect(env.sessions.activity.first?.summary == "You chose to answer in the terminal")
        t.expectEqual(env.sessions.pulse?.kind, .approved)
    }

    t.test("requests that are not the demo's are left for the engine") {
        let env = emptyEnv()
        let real = RealWorld()
        real.install(in: env)
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        t.expect(!director.handle(real.request, .allow), "a real request is not the demo's")
        t.expect(env.sessions.pending.contains(real.request), "and it is not touched")
        t.expectEqual(env.sessions.session(id: real.session.id), real.session)
        t.expect(!director.dismiss(real.session), "a real card is not the demo's to dismiss")
        t.expect(env.sessions.sessions.contains(real.session))
    }

    t.test("a dismissed demo card stays away until the story starts over") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        let cleaner = try t.unwrap(demoSession(env, .cleaner))
        t.expect(director.dismiss(cleaner))
        t.expectNil(demoSession(env, .cleaner))
        t.expect(env.sessions.pending.isEmpty, "its request goes with it")
        while director.steps[director.stepIndex].name != stepName(containing: "starts over") {
            director.advance()
            t.expectNil(demoSession(env, .cleaner), "steps for a missing card do nothing")
            t.expectNil(demoRequest(env, .cleaner))
        }
        director.advance()
        t.expect(demoSession(env, .cleaner) != nil, "the card returns with the new loop")
    }

    t.test("a card removed behind the demo's back does not break the story") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        // As if the engine's clean-up had removed everything.
        env.sessions.sessions.removeAll()
        env.sessions.pending.removeAll()
        for _ in 0..<(director.steps.count * 2) {
            let step = try t.unwrap(director.advance())
            checkConsistency(t, env, "after wipe, \(step.name)")
        }
        t.expect(!demoSessions(env).isEmpty, "the cast is back after a restart")
    }

    t.test("stop removes only demo data") {
        let env = emptyEnv()
        let real = RealWorld()
        real.install(in: env)
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        t.expect(env.usage.usage != real.usage, "demo numbers replace the real ones while it runs")
        for _ in 0..<17 { director.advance() }
        env.ui.selectedSessionID = DemoCast.id(.builder)
        env.ui.focusedRequestID = env.sessions.pending.first { $0.id != real.request.id }?.id
        t.expect(env.sessions.sessions.count > 1 && env.sessions.activity.count > 1)
        director.stop()
        t.expect(!director.isRunning)
        t.expect(!env.ui.isDemo)
        t.expectEqual(env.sessions.sessions, [real.session], "only the real session is left")
        t.expectEqual(env.sessions.pending, [real.request], "only the real request is left")
        t.expectEqual(env.sessions.activity, [real.entry], "only the real activity line is left")
        t.expectEqual(env.usage.usage, real.usage, "real usage is back")
        t.expectEqual(env.usage.activityDays, real.days)
        t.expectEqual(env.usage.lastRefresh, real.refreshed)
        t.expectNil(env.sessions.pulse, "a pulse pointing at a demo session is cleared")
        t.expectNil(env.ui.selectedSessionID, "selection of a demo card is cleared")
        t.expectNil(env.ui.focusedRequestID)
    }

    t.test("stop keeps a real pulse and a real selection") {
        let env = emptyEnv()
        let real = RealWorld()
        real.install(in: env)
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        director.advance()
        let pulse = Pulse(kind: .done, sessionID: real.session.id, at: Date())
        env.sessions.pulse = pulse
        env.ui.selectedSessionID = real.session.id
        env.ui.focusedRequestID = real.request.id
        director.stop()
        t.expectEqual(env.sessions.pulse, pulse)
        t.expectEqual(env.ui.selectedSessionID, real.session.id)
        t.expectEqual(env.ui.focusedRequestID, real.request.id)
    }

    t.test("real sessions that arrive during the demo survive it") {
        let env = emptyEnv()
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        director.advance()
        let real = RealWorld()
        env.sessions.sessions.insert(real.session, at: 1)
        env.sessions.pending.insert(real.request, at: 0)
        env.sessions.activity.insert(real.entry, at: 0)
        for _ in 0..<director.steps.count { director.advance() }
        t.expectEqual(env.sessions.session(id: real.session.id), real.session)
        director.stop()
        t.expectEqual(env.sessions.sessions, [real.session])
        t.expectEqual(env.sessions.pending, [real.request])
        t.expectEqual(env.sessions.activity, [real.entry])
    }

    t.test("real usage that refreshes during the demo is what comes back") {
        let env = emptyEnv()
        let real = RealWorld()
        real.install(in: env)
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        director.advance()
        // The real usage scanner writes fresh numbers in the middle of the demo.
        var fresh = real.usage
        fresh[.claude]?.windows[0].usedPercent = 55
        let freshDate = Date(timeIntervalSince1970: 1_790_000_500)
        env.usage.usage = fresh
        env.usage.lastRefresh = freshDate
        director.advance()
        t.expect(env.usage.usage != fresh, "the demo shows its own numbers again")
        director.stop()
        t.expectEqual(env.usage.usage, fresh, "the newest real numbers are restored")
        t.expectEqual(env.usage.lastRefresh, freshDate)

        // And if the scanner writes after the demo's last step, stop leaves that alone.
        director.start()
        director.advance()
        var newest = fresh
        newest[.claude]?.windows[0].usedPercent = 61
        env.usage.usage = newest
        director.stop()
        t.expectEqual(env.usage.usage, newest)
    }

    t.test("the activity log setting is respected and the log stays capped") {
        let env = emptyEnv()
        env.settings.activityLogEnabled = false
        let quiet = DemoDirector(env: env, autoAdvance: false)
        quiet.start()
        for _ in 0..<10 { quiet.advance() }
        t.expect(env.sessions.activity.isEmpty, "nothing is logged when the activity log is off")
        quiet.stop()

        env.settings.activityLogEnabled = true
        let real = RealWorld()
        env.sessions.activity = [real.entry]
        let director = DemoDirector(env: env, autoAdvance: false)
        director.start()
        for _ in 0..<(director.steps.count * 12) { director.advance() }
        t.expectEqual(env.sessions.activity.count, 300, "the log is full but capped")
        t.expect(env.sessions.activity.first?.at ?? .distantPast >= env.sessions.activity.last?.at ?? .distantFuture, "newest first")
        director.stop()
        t.expect(env.sessions.activity.allSatisfy { $0 == real.entry }, "every demo line is removed, however many there were")
    }

    t.test("the clock can be injected") {
        let env = emptyEnv()
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let director = DemoDirector(env: env, autoAdvance: false, now: { fixed })
        director.start()
        director.advance()
        t.expect(env.sessions.sessions.allSatisfy { $0.lastEventAt == fixed }, "every card is stamped with the injected time")
        t.expect(env.sessions.activity.allSatisfy { $0.at == fixed })
        t.expectEqual(env.sessions.pulse?.at, fixed)
        t.expectEqual(env.usage.lastRefresh, fixed)
    }

    t.test("the timer plays the story by itself and stops when told") {
        let env = emptyEnv()
        let director = DemoDirector(env: env)
        director.speed = 100
        director.start()
        t.expectEqual(director.stepIndex, 0, "nothing happens synchronously beyond the opening scene")
        t.expect(t.wait(5) { director.stepIndex >= 4 || director.loopCount > 0 }, "the timer advances the story")
        checkConsistency(t, env, "timer run")
        director.stop()
        let index = director.stepIndex
        let loops = director.loopCount
        t.wait(0.3) { false }
        t.expectEqual(director.stepIndex, index, "no more steps after stop")
        t.expectEqual(director.loopCount, loops)
        t.expect(env.sessions.sessions.isEmpty, "and nothing comes back")
    }

    t.test("a released director leaves no timer behind") {
        let env = emptyEnv()
        var director: DemoDirector? = DemoDirector(env: env)
        director?.speed = 100
        director?.start()
        let count = env.sessions.activity.count
        director = nil
        t.wait(0.3) { false }
        t.expectEqual(env.sessions.activity.count, count, "nothing keeps changing the stores")
    }
}
