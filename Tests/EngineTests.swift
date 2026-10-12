// EngineTests.swift — tests for the session engine (Sources/Core/Engine).
//
// Run with: scripts/test.sh Engine Sources/Core/Engine
//
// The tests come in two layers, like the engine itself:
//   - reducer tests feed SessionReducer events and look at the state and effects it returns;
//   - engine tests drive SessionEngine with fake helpers (reply handles), a fake adapter and fake
//     sounds / terminal / usage / notifications, and look at the store and at what the fakes saw.
// Nothing real is touched: settings live in memory, time is a variable, "is this process alive"
// is a dictionary, and PERCH_HOME points Perch's own folder at a temporary directory.

import Foundation

// MARK: - Fakes

/// Preferences that live only in memory, so nothing is written to ~/Library/Preferences.
private final class EngineTestDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

/// Stands in for a waiting `perch-hook` process and records what the engine did with it.
private final class FakeReplyHandle: ReplyHandle {
    let id = UUID()
    var onDisconnect: (() -> Void)?
    private(set) var replies: [HookReply] = []
    private(set) var closeCount = 0

    func reply(_ reply: HookReply) { replies.append(reply); onDisconnect = nil }
    func close() { closeCount += 1; onDisconnect = nil }

    /// What the real server does when the helper process goes away.
    func simulateDisconnect() { onDisconnect?() }

    var isOpen: Bool { replies.isEmpty && closeCount == 0 }
    var wasClosedWithoutReply: Bool { replies.isEmpty && closeCount == 1 }
    var onlyReply: HookReply? { replies.count == 1 && closeCount == 0 ? replies[0] : nil }
}

/// Encodes decisions as readable text so tests can see exactly which decision was sent.
private final class FakeAdapter: AgentAdapter {
    let kind: AgentKind
    var capabilities = AgentCapabilities(liveEvents: true, approvals: true, questions: true, planReview: true)
    private(set) var encoded: [(Decision, PendingRequest)] = []

    init(_ kind: AgentKind = .claude) { self.kind = kind }

    func status() -> AgentStatus {
        AgentStatus(agent: kind, detected: true, version: nil, configPath: nil, hookStatus: .installed,
                    capabilities: capabilities, detail: "fake")
    }
    func installHooks() throws -> String { "installed" }
    func uninstallHooks() throws -> String { "removed" }
    func normalize(_ envelope: HookEnvelope) -> [NormalizedEvent] { [] }
    func encode(_ decision: Decision, for request: PendingRequest) -> HookReply {
        encoded.append((decision, request))
        return HookReply(stdout: "\(kind.rawValue):\(Self.text(decision))", exitCode: 0)
    }

    static func text(_ decision: Decision) -> String {
        switch decision {
        case .allow: return "allow"
        case .allowAlways(let id): return "always(\(id))"
        case .deny(let message): return "deny(\(message ?? ""))"
        case .answer(let answers): return "answer(" + answers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&") + ")"
        case .approvePlan(let acceptEdits): return "approve(\(acceptEdits))"
        case .rejectPlan(let feedback): return "reject(\(feedback))"
        case .passToTerminal: return "terminal"
        }
    }
}

private final class FakeSounds: SoundPlaying {
    private(set) var played: [SoundCue] = []
    func play(_ cue: SoundCue) { played.append(cue) }
    func preview(_ cue: SoundCue) {}
    func count(_ cue: SoundCue) -> Int { played.filter { $0 == cue }.count }
}

private final class FakeJumper: TerminalJumping {
    /// `Session.id`s whose terminal tab is "in front".
    var frontmost: Set<String> = []
    private(set) var questions = 0
    func jump(to session: Session) -> JumpResult { .focused }
    func isFrontmost(_ session: Session) -> Bool { questions += 1; return frontmost.contains(session.id) }
}

private final class FakeUsage: UsageEngineProtocol {
    private(set) var observed: [NormalizedEvent] = []
    private(set) var decisions: [(Decision, PendingRequest)] = []
    func start() {}
    func stop() {}
    func refreshNow() {}
    func observe(_ event: NormalizedEvent) { observed.append(event) }
    func recordDecision(_ decision: Decision, for request: PendingRequest) { decisions.append((decision, request)) }
    func clearSavedStats() {}
}

private final class FakeNotifier: SystemNotifying {
    private(set) var posted: [(title: String, body: String, sessionID: String?)] = []
    func notify(title: String, body: String, sessionID: String?) { posted.append((title, body, sessionID)) }
}

// MARK: - Building events

/// A fixed starting time; tests add seconds to it.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let terminalEnv = ["TERM_PROGRAM": "Apple_Terminal", "TERM_SESSION_ID": "w0t0p0"]
private let demoFolder = "/Users/dev/projects/demo"

private func context(at seconds: TimeInterval = 0, pid: Int32? = 500, tty: String? = "/dev/ttys001",
                     cwd: String? = demoFolder, env: [String: String] = terminalEnv) -> EventContext {
    EventContext(pid: pid, tty: tty, cwd: cwd, env: env, transcriptPath: "/Users/dev/.claude/projects/demo/s1.jsonl",
                 receivedAt: t0.addingTimeInterval(seconds))
}

private func event(_ event: AgentEvent, at seconds: TimeInterval = 0, sid: String = "s1", agent: AgentKind = .claude,
                   raw: JSONValue = .null, name: String = "Test", context custom: EventContext? = nil) -> NormalizedEvent {
    NormalizedEvent(agent: agent, sessionID: sid, event: event, context: custom ?? context(at: seconds),
                    rawEventName: name, raw: raw)
}

private func tool(_ id: String, _ name: String = "Bash", _ summary: String = "npm test", at seconds: TimeInterval = 0) -> ToolCall {
    ToolCall(id: id, name: name, summary: summary, startedAt: t0.addingTimeInterval(seconds))
}

/// A payload shaped like Claude's tool hooks: enough for the engine's correlation hints.
private func toolRaw(_ name: String = "Bash", _ command: String = "npm test", id: String? = nil, subagent: String? = nil) -> JSONValue {
    var fields: [String: JSONValue] = ["tool_name": .string(name), "tool_input": ["command": .string(command)]]
    if let id { fields["tool_use_id"] = .string(id) }
    if let subagent { fields["agent_id"] = .string(subagent) }
    return .object(fields)
}

private func permission(_ toolName: String = "Bash", _ detail: String = "npm test", dangerous: Bool = false,
                        suggestions: [PermissionSuggestion] = []) -> PermissionRequest {
    PermissionRequest(toolName: toolName, summary: "Run a shell command", detail: detail, diff: nil,
                      suggestions: suggestions, isDangerous: dangerous)
}

private let colourQuestion = QuestionRequest(questions: [
    Question(id: 0, text: "Which color?", header: "Color",
             options: [QuestionOption(id: 0, label: "Red", detail: nil), QuestionOption(id: 1, label: "Blue", detail: nil)],
             multiSelect: false),
])
private let samplePlan = PlanRequest(markdown: "# Plan\n1. Add the engine\n2. Test it", filePath: "/tmp/plan.md")

private let s1 = Session.makeID(.claude, "s1")

// MARK: - A complete engine with fakes around it

private final class Rig {
    let store = SessionStore()
    let settings = AppSettings(defaults: EngineTestDefaults())
    let claude = FakeAdapter(.claude)
    let codex = FakeAdapter(.codex)
    let sounds = FakeSounds()
    let jumper = FakeJumper()
    let usage = FakeUsage()
    let notifier = FakeNotifier()
    let engine: SessionEngine
    /// Seconds after `t0` that the engine's clock shows.
    var time: TimeInterval = 0
    /// The processes that "exist". 500 is the default pid of test events.
    var processes: [Int32: ProcessLiveness.Identity] = [500: ProcessLiveness.Identity(startedAt: 100)]

    init(adapters: Bool = true) {
        engine = SessionEngine(store: store, settings: settings, adapters: adapters ? [.claude: claude, .codex: codex] : [:],
                               sounds: sounds, jumper: jumper, usage: usage, notifier: notifier)
        engine.clock = { [unowned self] in t0.addingTimeInterval(self.time) }
        engine.processIdentity = { [unowned self] pid in self.processes[pid] }
    }

    /// Sends one event at `seconds`; with `blocking` a fake helper waits for the answer and is returned.
    @discardableResult
    func send(_ agentEvent: AgentEvent, at seconds: TimeInterval? = nil, sid: String = "s1", agent: AgentKind = .claude,
              raw: JSONValue = .null, name: String = "Test", blocking: Bool = false, context custom: EventContext? = nil) -> FakeReplyHandle? {
        if let seconds { time = seconds }
        let handle = blocking ? FakeReplyHandle() : nil
        let one = NormalizedEvent(agent: agent, sessionID: sid, event: agentEvent, context: custom ?? context(at: time),
                                  rawEventName: name, raw: raw)
        engine.ingest([one], reply: handle)
        return handle
    }

    func tick(at seconds: TimeInterval) {
        time = seconds
        engine.tick(now: t0.addingTimeInterval(seconds))
    }

    var session: Session? { store.session(id: s1) }
    var state: SessionState? { session?.state }
    func session(_ sid: String, _ agent: AgentKind = .claude) -> Session? { store.session(id: Session.makeID(agent, sid)) }

    /// Starts a session, sends a prompt and a Bash "tool started" (id "t1"), then a blocking permission request for it.
    func openApproval(at seconds: TimeInterval = 0) -> FakeReplyHandle? {
        send(.sessionStarted(title: nil, model: "opus", source: "startup"), at: seconds)
        send(.promptSubmitted(text: "Run the tests"), at: seconds)
        send(.toolStarted(tool("t1", at: seconds)), at: seconds, raw: toolRaw(id: "t1"))
        return send(.permissionRequested(permission()), at: seconds, raw: toolRaw(), blocking: true)
    }
}

/// Runs the reducer over events with default settings and returns the final state and all effects.
private func reduceAll(_ events: [NormalizedEvent], config: EngineConfig = EngineConfig(),
                       from start: EngineState = EngineState()) -> (state: EngineState, effects: [EngineEffect]) {
    var state = start
    var effects: [EngineEffect] = []
    for one in events { effects += SessionReducer.reduce(&state, one, offersReply: false, config: config) }
    return (state, effects)
}

private func pulses(_ effects: [EngineEffect]) -> [Pulse.Kind] {
    effects.compactMap { if case .pulse(let kind, _) = $0 { return kind } else { return nil } }
}

private func cues(_ effects: [EngineEffect]) -> [SoundCue] {
    effects.compactMap { if case .sound(let cue, _) = $0 { return cue } else { return nil } }
}

// MARK: - Tests

func runEngineTests(_ t: TestRunner) {
    // Perch's own folder (logs) goes to a temporary directory for the whole run.
    let home = TestRunner.tempDir("perch-engine")
    setenv("PERCH_HOME", home.path, 1)
    defer { try? FileManager.default.removeItem(at: home) }

    runHelperTests(t)
    runReducerTableTests(t)
    runRequestLifecycleTests(t)
    runCorrelationTests(t)
    runIdentityTests(t)
    runVisibilityTests(t)
    runSideEffectTests(t)
    runHousekeepingTests(t)
    runActivityLogTests(t)
    runReplayTests(t)
    runTimerAndEdgeTests(t)
    runIdlePromptTests(t)
}

// MARK: Helpers and wording

private func runHelperTests(_ t: TestRunner) {
    t.test("titles: first prompt line, single-spaced, capped at about 80 characters") {
        t.expectEqual(EngineText.title(fromPrompt: "  Fix   the\tlogin bug  \nand more"), "Fix the login bug")
        t.expectEqual(EngineText.title(fromPrompt: "\n\n  second line first  "), "second line first")
        t.expectNil(EngineText.title(fromPrompt: "   \n\t "))
        t.expectNil(EngineText.title(fromPrompt: "/compact"), "a slash command is not a title")
        let long = String(repeating: "word ", count: 40)
        let title = try t.unwrap(EngineText.title(fromPrompt: long))
        t.expectEqual(title.count, 80)
        t.expect(title.hasSuffix("…"))
        t.expectEqual(EngineText.folderTitle(cwd: "/Users/dev/projects/demo", agent: .claude), "demo")
        t.expectEqual(EngineText.folderTitle(cwd: "", agent: .codex), "Codex")
        t.expectEqual(EngineText.clip("short", to: 80), "short")
    }

    t.test("raw payloads are cut to about 4 KB without splitting a character") {
        let big = String(repeating: "é", count: 5000)   // 2 bytes each
        let cut = EngineText.clipBytes(big, to: 4096)
        t.expect(cut.hasPrefix(String(repeating: "é", count: 2048)))
        t.expect(cut.contains("10000 bytes"))
        t.expect(cut.utf8.count < 4200)
        t.expectEqual(EngineText.clipBytes("small"), "small")
        t.expectEqual(ActivitySummary.rawText(.null), "")
        t.expectEqual(ActivitySummary.rawText(["a": 1]), "{\"a\":1}")
    }

    t.test("read-only tools: one list, case-insensitive, never when flagged dangerous") {
        for name in ["Read", "read", "Glob", "Grep", "LS", "read_file", "view_file", "list_directory"] {
            t.expect(ReadOnlyTools.contains(name), name)
        }
        for name in ["Bash", "Write", "Edit", "WebFetch", "run_command", "apply_patch", ""] {
            t.expect(!ReadOnlyTools.contains(name), name)
        }
        t.expect(ReadOnlyTools.mayAutoAllow(permission("Read", "/tmp/a.txt")))
        t.expect(!ReadOnlyTools.mayAutoAllow(permission("Read", "/etc/passwd", dangerous: true)))
        t.expect(!ReadOnlyTools.mayAutoAllow(permission("Bash", "ls")))
    }

    t.test("raw hints: subagent scope, input fingerprint and tool name") {
        t.expectEqual(RawHints.scope(.null), "")
        t.expectEqual(RawHints.scope(["agent_id": "a1"]), "a1")
        t.expectEqual(RawHints.scope(["agent_id": ""]), "")
        t.expectNil(RawHints.inputKey(.null))
        t.expectNil(RawHints.inputKey(["tool_name": "Bash"]))
        let pre = RawHints.inputKey(toolRaw("Bash", "npm test", id: "t1"))
        let request = RawHints.inputKey(toolRaw("Bash", "npm test"))
        t.expect(pre != nil && pre == request, "the same input gives the same fingerprint, with or without an id")
        t.expect(pre != RawHints.inputKey(toolRaw("Bash", "npm run build")))
        t.expect(RawHints.inputKey(["toolCall": ["name": "run_command", "args": ["CommandLine": "ls"]]]) != nil, "Antigravity's nested shape")
        t.expectEqual(RawHints.toolName(["tool_name": "AskUserQuestion"]), "AskUserQuestion")
        t.expectEqual(RawHints.toolName(["toolCall": ["name": "run_command"]]), "run_command")
        t.expectNil(RawHints.toolName(["x": 1]))
    }

    t.test("activity wording reads like plain English") {
        func line(_ e: AgentEvent, agent: AgentKind = .claude) -> String { ActivitySummary.describe(event(e, agent: agent)) }
        t.expectEqual(line(.sessionStarted(title: nil, model: nil, source: "startup")), "Claude started a session in demo")
        t.expectEqual(line(.sessionStarted(title: nil, model: nil, source: "resume")), "Claude picked up an earlier session in demo")
        t.expectEqual(line(.sessionStarted(title: nil, model: nil, source: "clear")), "Claude started a fresh conversation in demo")
        t.expectEqual(line(.sessionEnded(reason: "prompt_input_exit")), "The Claude session was closed")
        t.expectEqual(line(.sessionEnded(reason: "other")), "The Claude session ended")
        t.expectEqual(line(.promptSubmitted(text: "Fix the\nbug")), "You asked Claude: \u{201C}Fix the\u{201D}")
        t.expectEqual(line(.toolStarted(tool("t1"))), "Claude is using Bash: npm test")
        t.expectEqual(line(.toolStarted(tool("t1", "Read", ""))), "Claude is using Read")
        t.expectEqual(line(.toolFinished(id: "t1", name: "Bash", succeeded: true)), "Bash finished")
        t.expectEqual(line(.toolFinished(id: "t1", name: "Bash", succeeded: false)), "Bash did not succeed")
        t.expectEqual(line(.permissionRequested(permission())), "Claude wants to run a shell command: `npm test`")
        t.expectEqual(line(.permissionRequested(permission("Bash", "rm -rf /", dangerous: true)), agent: .codex),
                      "Codex wants to run a shell command: `rm -rf /` (worth a second look)")
        t.expectEqual(line(.permissionRequested(PermissionRequest(toolName: "mcp__db__query", summary: "", detail: ""))),
                      "Claude wants to use mcp__db__query")
        t.expectEqual(line(.questionAsked(colourQuestion)), "Claude asks: \u{201C}Which color?\u{201D}")
        t.expect(line(.planProposed(samplePlan)).contains("plan"))
        t.expectEqual(line(.notification(kind: "permission_prompt", message: "Claude needs your permission")),
                      "Claude is still waiting for your permission")
        t.expectEqual(line(.notification(kind: "auth_success", message: "Signed in")), "Claude says: Signed in")
        t.expectEqual(line(.turnFinished(lastMessage: "All tests pass.\nDetails follow", backgroundWork: false)), "Finished: All tests pass.")
        t.expectEqual(line(.turnFinished(lastMessage: nil, backgroundWork: false)), "Finished its turn")
        t.expect(line(.turnFinished(lastMessage: "x", backgroundWork: true)).contains("background"))
        t.expectEqual(line(.turnFailed(error: "Rate limit reached")), "Stopped with an error: Rate limit reached")
        t.expectEqual(line(.subagentStarted(id: "a1", type: "Explore")), "Claude started a helper agent (Explore)")
        t.expectEqual(line(.subagentStopped(id: "a1")), "A helper agent finished")
        t.expect(line(.compactionStarted).contains("tidying"))
        t.expect(line(.compactionFinished).contains("finished"))
        let window = RateWindow(id: "5h", label: "5-hour limit", usedPercent: 12.4, resetsAt: nil)
        t.expectEqual(line(.usageUpdated(contextPercent: 41.6, windows: [window], model: nil, costUSD: nil)),
                      "Usage update: memory 42% full, 5-hour limit 12% used")
        t.expectEqual(line(.metadata(title: nil, model: "opus", gitBranch: "main", permissionMode: "plan")),
                      "Session details: model opus, branch main, mode plan")
    }

    t.test("decision wording says what the user did") {
        let suggestion = PermissionSuggestion(id: 3, label: "Always allow npm test", raw: .null)
        let request = PendingRequest(sessionID: s1, agent: .claude, kind: .permission(permission(suggestions: [suggestion])),
                                     createdAt: t0, raw: .null)
        t.expectEqual(ActivitySummary.describe(.allow, for: request), "You allowed it")
        t.expectEqual(ActivitySummary.describe(.allowAlways(suggestionID: 3), for: request),
                      "You allowed it and chose \u{201C}Always allow npm test\u{201D}")
        t.expectEqual(ActivitySummary.describe(.allowAlways(suggestionID: 9), for: request), "You allowed it and asked not to be asked again")
        t.expectEqual(ActivitySummary.describe(.deny(message: nil), for: request), "You denied it")
        t.expectEqual(ActivitySummary.describe(.deny(message: "not now"), for: request), "You denied it: \u{201C}not now\u{201D}")
        t.expectEqual(ActivitySummary.describe(.answer(["Which color?": "Red"]), for: request), "You answered: Which color? → Red")
        t.expectEqual(ActivitySummary.describe(.approvePlan(acceptEdits: false), for: request), "You approved the plan")
        t.expect(ActivitySummary.describe(.approvePlan(acceptEdits: true), for: request).contains("without asking"))
        t.expectEqual(ActivitySummary.describe(.rejectPlan(feedback: "split step 2"), for: request),
                      "You sent the plan back: \u{201C}split step 2\u{201D}")
        t.expectEqual(ActivitySummary.describe(.passToTerminal, for: request), "You chose to answer in the terminal")
    }

    t.test("store merge keeps other people's entries where they are") {
        func merge(_ current: [String], _ mine: [String], _ published: Set<String>) -> [String] {
            SessionEngine.merge(current: current, mine: mine, published: published) { $0 }
        }
        t.expectEqual(merge([], ["a", "b"], []), ["a", "b"])
        t.expectEqual(merge(["a", "demo", "b"], ["a", "b", "c"], ["a", "b"]), ["a", "demo", "b", "c"])
        t.expectEqual(merge(["a", "demo", "b"], ["b"], ["a", "b"]), ["b", "demo"], "a removed entry gives up its slot")
        t.expectEqual(merge(["a", "demo"], ["z"], ["a"]), ["z", "demo"], "a replacement takes the old slot")
        t.expectEqual(merge(["demo1", "demo2"], [], []), ["demo1", "demo2"])
    }
}

// MARK: Reducer: one row of the table at a time

private func runReducerTableTests(_ t: TestRunner) {
    let started = event(.sessionStarted(title: nil, model: "opus", source: "startup"), name: "SessionStart")
    let prompt = event(.promptSubmitted(text: "Run the tests please"), at: 1, name: "UserPromptSubmit")

    t.test("sessionStarted creates an idle card titled after the folder") {
        let (state, effects) = reduceAll([started])
        let session = try t.unwrap(state.sessions.first)
        t.expectEqual(state.sessions.count, 1)
        t.expectEqual(session.id, "claude:s1")
        t.expectEqual(session.agent, .claude)
        t.expectEqual(session.sessionID, "s1")
        t.expectEqual(session.state, .idle)
        t.expectEqual(session.title, "demo")
        t.expectEqual(session.cwd, demoFolder)
        t.expectEqual(session.model, "opus")
        t.expectEqual(session.pid, 500)
        t.expectEqual(session.terminal.tty, "/dev/ttys001")
        t.expectEqual(session.terminal.bundleID, "com.apple.Terminal")
        t.expectEqual(session.terminal.terminalSessionID, "w0t0p0")
        t.expectEqual(session.transcriptPath, "/Users/dev/.claude/projects/demo/s1.jsonl")
        t.expectEqual(session.startedAt, t0)
        t.expectEqual(session.stateSince, t0)
        t.expectEqual(session.lastEventAt, t0)
        t.expect(!session.isHeadless)
        t.expectEqual(pulses(effects), [.started])
        t.expectEqual(cues(effects), [.sessionStart])
    }

    t.test("promptSubmitted: working, first prompt becomes the title, turn counted, old results cleared") {
        var (state, _) = reduceAll([started, prompt])
        var session = try t.unwrap(state.sessions.first)
        t.expectEqual(session.state, .working)
        t.expectEqual(session.title, "Run the tests please")
        t.expectEqual(session.lastPrompt, "Run the tests please")
        t.expectEqual(session.turnCount, 1)
        t.expectEqual(session.stateSince, t0.addingTimeInterval(1))
        t.expectEqual(session.lastEventAt, t0.addingTimeInterval(1))

        // A finished turn, then a failure, then a second prompt.
        _ = SessionReducer.reduce(&state, event(.turnFailed(error: "boom"), at: 2), offersReply: false, config: EngineConfig())
        _ = SessionReducer.reduce(&state, event(.promptSubmitted(text: "Try again"), at: 3), offersReply: false, config: EngineConfig())
        session = try t.unwrap(state.sessions.first)
        t.expectEqual(session.title, "Run the tests please", "only the first prompt names the session")
        t.expectEqual(session.lastPrompt, "Try again")
        t.expectEqual(session.turnCount, 2)
        t.expectNil(session.errorText)
        t.expectNil(session.lastMessage)
        t.expectEqual(session.state, .working)
    }

    t.test("toolStarted / toolFinished: runningTool with the tool, then working with it marked done") {
        var (state, _) = reduceAll([started, prompt, event(.toolStarted(tool("t1", at: 2)), at: 2, raw: toolRaw(id: "t1"))])
        var session = try t.unwrap(state.sessions.first)
        t.expectEqual(session.state, .runningTool)
        t.expectEqual(session.currentTool?.id, "t1")
        t.expectEqual(session.recentTools.map { $0.id }, ["t1"])
        t.expectEqual(session.toolCount, 1)
        t.expectNil(session.recentTools.first?.finishedAt)

        _ = SessionReducer.reduce(&state, event(.toolFinished(id: "t1", name: "Bash", succeeded: true), at: 5, raw: toolRaw(id: "t1")),
                                  offersReply: false, config: EngineConfig())
        session = try t.unwrap(state.sessions.first)
        t.expectEqual(session.state, .working)
        t.expectNil(session.currentTool)
        t.expectEqual(session.recentTools.first?.finishedAt, t0.addingTimeInterval(5))
        t.expectEqual(session.recentTools.first?.succeeded, true)
        t.expectEqual(session.toolCount, 1)
        t.expectEqual(state.tracking[s1]?.openTools.count, 0)

        // A failing tool is marked as such.
        _ = SessionReducer.reduce(&state, event(.toolStarted(tool("t2", "Read", "missing.txt", at: 6)), at: 6), offersReply: false, config: EngineConfig())
        _ = SessionReducer.reduce(&state, event(.toolFinished(id: "t2", name: "Read", succeeded: false), at: 7), offersReply: false, config: EngineConfig())
        session = try t.unwrap(state.sessions.first)
        t.expectEqual(session.recentTools.last?.succeeded, false)
        t.expectEqual(session.toolCount, 2)
    }

    t.test("recentTools keeps the latest 24, oldest first") {
        var events = [started, prompt]
        for n in 0..<30 {
            events.append(event(.toolStarted(tool("t\(n)", at: Double(n))), at: Double(10 + n)))
            events.append(event(.toolFinished(id: "t\(n)", name: "Bash", succeeded: true), at: Double(10 + n)))
        }
        let (state, _) = reduceAll(events)
        let session = try t.unwrap(state.sessions.first)
        t.expectEqual(session.recentTools.count, 24)
        t.expectEqual(session.recentTools.first?.id, "t6")
        t.expectEqual(session.recentTools.last?.id, "t29")
        t.expectEqual(session.toolCount, 30)
    }

    t.test("two tools in parallel: the card keeps showing a tool until both are done") {
        var (state, _) = reduceAll([started, prompt, event(.toolStarted(tool("a")), at: 2), event(.toolStarted(tool("b", "Grep", "TODO")), at: 2)])
        t.expectEqual(state.sessions.first?.currentTool?.id, "b")
        _ = SessionReducer.reduce(&state, event(.toolFinished(id: "a", name: "Bash", succeeded: true), at: 3), offersReply: false, config: EngineConfig())
        t.expectEqual(state.sessions.first?.state, .runningTool, "b is still running")
        _ = SessionReducer.reduce(&state, event(.toolFinished(id: "b", name: "Grep", succeeded: true), at: 4), offersReply: false, config: EngineConfig())
        t.expectEqual(state.sessions.first?.state, .working)
    }

    t.test("turnFinished: done with the last message; with background work it keeps working") {
        let (state, effects) = reduceAll([started, prompt, event(.turnFinished(lastMessage: "  All tests pass.  ", backgroundWork: false), at: 9)])
        let session = try t.unwrap(state.sessions.first)
        t.expectEqual(session.state, .done)
        t.expectEqual(session.lastMessage, "All tests pass.")
        t.expectEqual(session.stateSince, t0.addingTimeInterval(9))
        t.expectEqual(pulses(effects), [.started, .done])
        t.expectEqual(cues(effects), [.sessionStart, .done])
        t.expect(effects.contains { if case .notify(let title, let body, _) = $0 { return title.contains("Claude finished") && body == "Finished: All tests pass." } else { return false } })

        let (background, backgroundEffects) = reduceAll([started, prompt, event(.turnFinished(lastMessage: "Started the server", backgroundWork: true), at: 9)])
        t.expectEqual(background.sessions.first?.state, .working)
        t.expectEqual(background.sessions.first?.lastMessage, "Started the server")
        t.expectEqual(pulses(backgroundEffects), [.started], "no 'done' while background work continues")
    }

    t.test("a turn reported finished twice is announced once") {
        let (state, effects) = reduceAll([started, prompt,
                                          event(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 9),
                                          event(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 9.2)])
        t.expectEqual(state.sessions.first?.state, .done)
        t.expectEqual(cues(effects).filter { $0 == .done }.count, 1)
        t.expectEqual(state.sessions.first?.stateSince, t0.addingTimeInterval(9))
    }

    t.test("the end of a turn is latched: a late 'tool finished' does not revive it") {
        var (state, _) = reduceAll([started, prompt, event(.toolStarted(tool("t1")), at: 2),
                                    event(.turnFinished(lastMessage: "done", backgroundWork: false), at: 3)])
        _ = SessionReducer.reduce(&state, event(.toolFinished(id: "t1", name: "Bash", succeeded: true), at: 4), offersReply: false, config: EngineConfig())
        t.expectEqual(state.sessions.first?.state, .done)
        t.expectNil(state.sessions.first?.currentTool)
        // A newly started tool, on the other hand, is a real sign of work.
        _ = SessionReducer.reduce(&state, event(.toolStarted(tool("t2")), at: 20), offersReply: false, config: EngineConfig())
        t.expectEqual(state.sessions.first?.state, .runningTool)
    }

    t.test("turnFailed: failed with the error text, announced once") {
        let (state, effects) = reduceAll([started, prompt, event(.turnFailed(error: "Rate limit reached"), at: 4),
                                          event(.turnFailed(error: "Rate limit reached"), at: 5)])
        let session = try t.unwrap(state.sessions.first)
        t.expectEqual(session.state, .failed)
        t.expectEqual(session.errorText, "Rate limit reached")
        t.expectEqual(pulses(effects), [.started, .failed])
        t.expectEqual(cues(effects), [.sessionStart, .failed])
        t.expectEqual(session.stateSince, t0.addingTimeInterval(4))
    }

    t.test("subagents are counted, never below zero, and unknown ones are ignored") {
        var (state, _) = reduceAll([started, prompt,
                                    event(.subagentStarted(id: "a1", type: "Explore"), at: 2),
                                    event(.subagentStarted(id: "a2", type: "Explore"), at: 2)])
        t.expectEqual(state.sessions.first?.activeSubagents, 2)
        let config = EngineConfig()
        _ = SessionReducer.reduce(&state, event(.subagentStopped(id: "internal"), at: 3), offersReply: false, config: config)
        t.expectEqual(state.sessions.first?.activeSubagents, 2, "a helper that never started is not counted down")
        _ = SessionReducer.reduce(&state, event(.subagentStopped(id: "a1"), at: 3), offersReply: false, config: config)
        _ = SessionReducer.reduce(&state, event(.subagentStopped(id: "a1"), at: 3), offersReply: false, config: config)
        t.expectEqual(state.sessions.first?.activeSubagents, 1, "a repeated stop counts once")
        _ = SessionReducer.reduce(&state, event(.subagentStopped(id: "a2"), at: 4), offersReply: false, config: config)
        _ = SessionReducer.reduce(&state, event(.subagentStopped(id: nil), at: 4), offersReply: false, config: config)
        t.expectEqual(state.sessions.first?.activeSubagents, 0)
        t.expectEqual(state.sessions.first?.state, .working, "subagent events do not change the state")
        // The end of the turn resets the count even if a stop was missed.
        _ = SessionReducer.reduce(&state, event(.subagentStarted(id: "a3", type: nil), at: 5), offersReply: false, config: config)
        _ = SessionReducer.reduce(&state, event(.turnFinished(lastMessage: nil, backgroundWork: false), at: 6), offersReply: false, config: config)
        t.expectEqual(state.sessions.first?.activeSubagents, 0)
    }

    t.test("compaction: compacting, then back to what the session was doing") {
        var (state, _) = reduceAll([started, prompt, event(.compactionStarted, at: 2)])
        t.expectEqual(state.sessions.first?.state, .compacting)
        _ = SessionReducer.reduce(&state, event(.compactionFinished, at: 3), offersReply: false, config: EngineConfig())
        t.expectEqual(state.sessions.first?.state, .working, "mid-turn compaction returns to working")

        // /compact typed while the session was resting: Claude sends PreCompact, SessionStart(compact), PostCompact.
        var (resting, _) = reduceAll([started, prompt, event(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 2),
                                      event(.compactionStarted, at: 10),
                                      event(.sessionStarted(title: nil, model: "opus", source: "compact"), at: 11)])
        t.expectEqual(resting.sessions.first?.state, .compacting, "the mid-compaction 'session started' changes nothing")
        t.expectEqual(resting.sessions.count, 1)
        _ = SessionReducer.reduce(&resting, event(.compactionFinished, at: 12), offersReply: false, config: EngineConfig())
        t.expectEqual(resting.sessions.first?.state, .done)
        t.expectEqual(resting.sessions.first?.title, "Run the tests please")
        t.expectEqual(resting.sessions.first?.turnCount, 1)
        // A stray "finished" without a "started" does nothing.
        _ = SessionReducer.reduce(&resting, event(.compactionFinished, at: 13), offersReply: false, config: EngineConfig())
        t.expectEqual(resting.sessions.first?.state, .done)
    }

    t.test("usageUpdated and metadata only fill in fields") {
        let window = RateWindow(id: "5h", label: "5-hour limit", usedPercent: 12, resetsAt: nil)
        let (state, effects) = reduceAll([started, prompt,
                                          event(.usageUpdated(contextPercent: 142, windows: [window], model: "sonnet", costUSD: 1.25), at: 2),
                                          event(.metadata(title: nil, model: nil, gitBranch: "feature/x", permissionMode: "plan"), at: 3)])
        let session = try t.unwrap(state.sessions.first)
        t.expectEqual(session.contextPercent, 100, "clamped to 0...100")
        t.expectEqual(session.model, "sonnet")
        t.expectEqual(session.estimatedCostUSD, 1.25)
        t.expectEqual(session.gitBranch, "feature/x")
        t.expectEqual(session.permissionMode, "plan")
        t.expectEqual(session.state, .working)
        t.expectEqual(session.title, "Run the tests please")
        t.expectEqual(pulses(effects), [.started])

        var later = state
        _ = SessionReducer.reduce(&later, event(.metadata(title: "  Login fix  ", model: nil, gitBranch: nil, permissionMode: nil), at: 4),
                                  offersReply: false, config: EngineConfig())
        t.expectEqual(later.sessions.first?.title, "Login fix", "a title from the agent wins")
        t.expectEqual(later.sessions.first?.gitBranch, "feature/x", "nil means no change")
        _ = SessionReducer.reduce(&later, event(.promptSubmitted(text: "Something else"), at: 5), offersReply: false, config: EngineConfig())
        t.expectEqual(later.sessions.first?.title, "Login fix")
    }

    t.test("sessionEnded: ended, tools and subagents cleared, late events ignored") {
        var (state, effects) = reduceAll([started, prompt, event(.toolStarted(tool("t1")), at: 2),
                                          event(.subagentStarted(id: "a1", type: nil), at: 2),
                                          event(.sessionEnded(reason: "prompt_input_exit"), at: 3)])
        let session = try t.unwrap(state.sessions.first)
        t.expectEqual(session.state, .ended)
        t.expectNil(session.currentTool)
        t.expectEqual(session.activeSubagents, 0)
        t.expectEqual(pulses(effects), [.started], "no fanfare for an ending")
        for late in [AgentEvent.toolFinished(id: "t1", name: "Bash", succeeded: true), .turnFinished(lastMessage: "x", backgroundWork: false),
                     .toolStarted(tool("t9")), .notification(kind: "idle_prompt", message: "")] {
            _ = SessionReducer.reduce(&state, event(late, at: 3.5), offersReply: false, config: EngineConfig())
        }
        t.expectEqual(state.sessions.first?.state, .ended)
        t.expectEqual(state.sessions.first?.lastEventAt, t0.addingTimeInterval(3))
    }

    t.test("an event for an unknown session creates it first — but passive updates do not") {
        let creating: [(AgentEvent, SessionState)] = [
            (.promptSubmitted(text: "hi"), .working),
            (.toolStarted(tool("t1")), .runningTool),
            (.toolFinished(id: "t1", name: "Bash", succeeded: true), .working),
            (.turnFinished(lastMessage: "ok", backgroundWork: false), .done),
            (.turnFailed(error: "x"), .failed),
            (.subagentStarted(id: "a", type: nil), .working),
            (.compactionStarted, .compacting),
            (.compactionFinished, .working),
            (.permissionRequested(permission()), .needsApproval),
            (.questionAsked(colourQuestion), .needsAnswer),
            (.planProposed(samplePlan), .planReview),
            (.notification(kind: "permission_prompt", message: "Claude needs your permission"), .needsApproval),
        ]
        for (agentEvent, expected) in creating {
            let (state, effects) = reduceAll([event(agentEvent)])
            t.expectEqual(state.sessions.first?.state, expected, "\(agentEvent)")
            t.expectEqual(state.sessions.first?.cwd, demoFolder)
            t.expect(!pulses(effects).contains(.started), "a card that appears mid-session is not announced as started")
        }
        let passive: [AgentEvent] = [
            .usageUpdated(contextPercent: 10, windows: [], model: nil, costUSD: nil),
            .metadata(title: "x", model: nil, gitBranch: nil, permissionMode: nil),
            .notification(kind: "auth_success", message: "Signed in"),
            .notification(kind: "idle_prompt", message: ""),
            .subagentStopped(id: "a"),
            .sessionEnded(reason: "other"),
        ]
        for agentEvent in passive {
            let (state, effects) = reduceAll([event(agentEvent)])
            t.expect(state.sessions.isEmpty, "\(agentEvent)")
            t.expect(effects.isEmpty)
        }
    }

    t.test("idle_prompt puts a card that still says busy to rest, quietly") {
        let (state, effects) = reduceAll([started, prompt, event(.toolStarted(tool("t1")), at: 2),
                                          event(.notification(kind: "idle_prompt", message: "Claude is waiting"), at: 70)])
        t.expectEqual(state.sessions.first?.state, .idle)
        t.expectNil(state.sessions.first?.currentTool)
        t.expectEqual(cues(effects), [.sessionStart])
        // It never touches a finished card.
        let (done, _) = reduceAll([started, prompt, event(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 2),
                                   event(.notification(kind: "idle_prompt", message: ""), at: 70)])
        t.expectEqual(done.sessions.first?.state, .done)
    }

    t.test("every state accepts every event without breaking the rules") {
        // A coarse sweep: from each state, apply each event and check the invariants that must always hold.
        let setups: [SessionState: [NormalizedEvent]] = [
            .idle: [started],
            .working: [started, prompt],
            .runningTool: [started, prompt, event(.toolStarted(tool("t1")), at: 2, raw: toolRaw(id: "t1"))],
            .needsApproval: [started, prompt, event(.permissionRequested(permission()), at: 2)],
            .needsAnswer: [started, prompt, event(.questionAsked(colourQuestion), at: 2)],
            .planReview: [started, prompt, event(.planProposed(samplePlan), at: 2)],
            .compacting: [started, prompt, event(.compactionStarted, at: 2)],
            .done: [started, prompt, event(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 2)],
            .failed: [started, prompt, event(.turnFailed(error: "x"), at: 2)],
            .ended: [started, prompt, event(.sessionEnded(reason: "other"), at: 2)],
        ]
        let all: [AgentEvent] = [
            .sessionStarted(title: nil, model: nil, source: "resume"), .sessionEnded(reason: nil), .promptSubmitted(text: "next"),
            .toolStarted(tool("t7", "Edit", "a.swift")), .toolFinished(id: "t1", name: "Bash", succeeded: true),
            .permissionRequested(permission("Write", "b.txt")), .questionAsked(colourQuestion), .planProposed(samplePlan),
            .notification(kind: "permission_prompt", message: "m"), .notification(kind: "idle_prompt", message: "m"),
            .turnFinished(lastMessage: "ok", backgroundWork: false), .turnFinished(lastMessage: nil, backgroundWork: true),
            .turnFailed(error: "e"), .subagentStarted(id: "a", type: nil), .subagentStopped(id: "a"),
            .compactionStarted, .compactionFinished,
            .usageUpdated(contextPercent: 5, windows: [], model: nil, costUSD: nil),
            .metadata(title: nil, model: "m", gitBranch: nil, permissionMode: nil),
        ]
        for expected in SessionState.allCases {
            let (base, _) = reduceAll(setups[expected] ?? [])
            t.expectEqual(base.sessions.first?.state, expected, "setup for \(expected)")
            for agentEvent in all {
                var state = base
                _ = SessionReducer.reduce(&state, event(agentEvent, at: 30), offersReply: false, config: EngineConfig())
                guard let session = state.sessions.first else { t.expect(false, "\(expected) + \(agentEvent): card vanished"); continue }
                let waiting = state.requests.filter { $0.sessionID == session.id }
                var ok = state.sessions.count == 1 && session.activeSubagents >= 0 && session.stateSince <= session.lastEventAt
                // The state says "needs you" exactly when a request is waiting, and it is the oldest one's kind.
                if session.state != .ended { ok = ok && session.state.needsAttention == !waiting.isEmpty }
                if let head = waiting.first, session.state != .ended { ok = ok && session.state == head.attentionState }
                if session.state == .ended { ok = ok && waiting.isEmpty }
                if session.state == .runningTool { ok = ok && session.currentTool != nil }
                t.expect(ok, "\(expected) + \(agentEvent) -> \(session.state), \(waiting.count) waiting")
            }
        }
    }
}

// MARK: Requests: from the card appearing to the answer going back

private func runRequestLifecycleTests(_ t: TestRunner) {
    t.test("a blocking permission request becomes a card and keeps its helper waiting") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        let request = try t.unwrap(rig.store.pending.first)
        t.expectEqual(rig.store.pending.count, 1)
        t.expectEqual(request.sessionID, s1)
        t.expectEqual(request.agent, .claude)
        t.expectEqual(request.kind, .permission(permission()))
        t.expectEqual(request.raw, toolRaw(), "the original payload is kept for the adapter")
        t.expectEqual(request.createdAt, t0)
        t.expectEqual(rig.state, .needsApproval)
        t.expect(handle.isOpen, "the helper is neither answered nor let go")
        t.expect(handle.onDisconnect != nil, "the engine listens for the helper going away")
        t.expectEqual(rig.engine.waitingHelperCount, 1)
        t.expectEqual(rig.store.pulse?.kind, .attention)
        t.expectEqual(rig.store.pulse?.sessionID, s1)
        t.expectEqual(rig.sounds.played, [.sessionStart, .needsApproval])
        t.expectEqual(rig.notifier.posted.count, 1)
        t.expectEqual(rig.notifier.posted.first?.title, "Claude needs your approval")
        t.expectEqual(rig.notifier.posted.first?.body, "demo: npm test")
        t.expectEqual(rig.notifier.posted.first?.sessionID, s1)
        t.expectEqual(rig.session?.currentTool?.id, "t1", "the tool it is about stays visible")
    }

    t.test("allow: the adapter encodes it, the helper gets the reply, the session goes back to working") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        let request = try t.unwrap(rig.store.pending.first)
        rig.time = 4
        rig.engine.resolve(request.id, with: .allow)
        t.expectEqual(handle.onlyReply, HookReply(stdout: "claude:allow", exitCode: 0))
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(rig.state, .working)
        t.expectEqual(rig.session?.stateSince, t0.addingTimeInterval(4))
        t.expectEqual(rig.store.pulse?.kind, .approved)
        t.expectEqual(rig.sounds.played.last, .approved)
        t.expectEqual(rig.claude.encoded.count, 1)
        t.expectEqual(rig.claude.encoded.first?.1.id, request.id)
        t.expectEqual(rig.usage.decisions.count, 1)
        t.expectEqual(rig.usage.decisions.first?.0, .allow)
        t.expectEqual(rig.engine.waitingHelperCount, 0)
        t.expectEqual(rig.session?.currentTool?.id, "t1", "an allowed tool is about to run")
        // The tool then runs and finishes; nothing is left to withdraw.
        rig.send(.toolFinished(id: "t1", name: "Bash", succeeded: true), at: 9, raw: toolRaw(id: "t1"))
        t.expectEqual(rig.state, .working)
        t.expectEqual(handle.replies.count, 1)
        t.expectEqual(handle.closeCount, 0)
    }

    t.test("every kind of decision reaches the helper through the adapter") {
        let suggestion = PermissionSuggestion(id: 2, label: "Always allow npm test", raw: ["type": "addRules"])
        let cases: [(AgentEvent, Decision, String, Pulse.Kind, SoundCue)] = [
            (.permissionRequested(permission(suggestions: [suggestion])), .allowAlways(suggestionID: 2), "claude:always(2)", .approved, .approved),
            (.permissionRequested(permission()), .deny(message: "not now"), "claude:deny(not now)", .denied, .denied),
            (.permissionRequested(permission()), .deny(message: nil), "claude:deny()", .denied, .denied),
            (.questionAsked(colourQuestion), .answer(["Which color?": "Red"]), "claude:answer(Which color?=Red)", .approved, .approved),
            (.planProposed(samplePlan), .approvePlan(acceptEdits: true), "claude:approve(true)", .approved, .approved),
            (.planProposed(samplePlan), .approvePlan(acceptEdits: false), "claude:approve(false)", .approved, .approved),
            (.planProposed(samplePlan), .rejectPlan(feedback: "split step 2"), "claude:reject(split step 2)", .denied, .denied),
        ]
        for (agentEvent, decision, expected, pulse, cue) in cases {
            let rig = Rig()
            rig.send(.promptSubmitted(text: "go"))
            let handle = try t.unwrap(rig.send(agentEvent, at: 1, blocking: true))
            let request = try t.unwrap(rig.store.pending.first)
            rig.engine.resolve(request.id, with: decision)
            t.expectEqual(handle.onlyReply?.stdout, expected, "\(decision)")
            t.expectEqual(rig.state, .working, "\(decision)")
            t.expectEqual(rig.store.pulse?.kind, pulse, "\(decision)")
            t.expectEqual(rig.sounds.played.last, cue, "\(decision)")
            t.expect(rig.store.pending.isEmpty)
            t.expectEqual(rig.usage.decisions.count, 1)
        }
    }

    t.test("the three request kinds show three states and two sounds") {
        let cases: [(AgentEvent, SessionState, SoundCue, String)] = [
            (.permissionRequested(permission()), .needsApproval, .needsApproval, "Claude needs your approval"),
            (.questionAsked(colourQuestion), .needsAnswer, .needsAnswer, "Claude has a question"),
            (.planProposed(samplePlan), .planReview, .needsApproval, "Claude has a plan to review"),
        ]
        for (agentEvent, state, cue, title) in cases {
            let rig = Rig()
            rig.send(.promptSubmitted(text: "go"))
            let handle = rig.send(agentEvent, at: 1, blocking: true)
            t.expectEqual(rig.state, state)
            t.expectEqual(rig.sounds.played, [cue])
            t.expectEqual(rig.notifier.posted.first?.title, title)
            t.expectEqual(rig.store.pulse?.kind, .attention)
            t.expect(handle?.isOpen ?? false)
        }
    }

    t.test("passToTerminal: the helper gets 'no opinion', the card goes, the session still shows it is waiting") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        let request = try t.unwrap(rig.store.pending.first)
        rig.engine.resolve(request.id, with: .passToTerminal)
        t.expectEqual(handle.onlyReply, HookReply.passthrough)
        t.expect(rig.claude.encoded.isEmpty, "nothing to encode")
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(rig.state, .needsApproval, "the agent is still waiting, now in the terminal")
        t.expect(rig.usage.decisions.isEmpty, "stepping aside is not an answer")
        t.expect(!rig.sounds.played.contains(.approved) && !rig.sounds.played.contains(.denied))
        // Answered in the terminal: the tool runs and the session moves on.
        rig.send(.toolFinished(id: "t1", name: "Bash", succeeded: true), at: 8, raw: toolRaw(id: "t1"))
        t.expectEqual(rig.state, .working)
        t.expectEqual(handle.replies.count, 1)
    }

    t.test("a denied tool is closed, because it will never report that it finished") {
        let rig = Rig()
        _ = rig.openApproval()
        let request = try t.unwrap(rig.store.pending.first)
        rig.time = 3
        rig.engine.resolve(request.id, with: .deny(message: nil))
        t.expectNil(rig.session?.currentTool)
        t.expectEqual(rig.session?.recentTools.last?.succeeded, false)
        t.expectEqual(rig.session?.recentTools.last?.finishedAt, t0.addingTimeInterval(3))
        t.expectEqual(rig.engine.state.tracking[s1]?.openTools.count, 0)
    }

    t.test("a click on a card that is already gone does nothing") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        let request = try t.unwrap(rig.store.pending.first)
        rig.engine.resolve(request.id, with: .allow)
        let soundsBefore = rig.sounds.played
        rig.engine.resolve(request.id, with: .deny(message: nil))
        rig.engine.resolve(UUID(), with: .allow)
        t.expectEqual(handle.replies.count, 1)
        t.expectEqual(handle.onlyReply?.stdout, "claude:allow")
        t.expectEqual(rig.sounds.played, soundsBefore)
        t.expectEqual(rig.usage.decisions.count, 1)
        t.expectEqual(rig.state, .working)
    }

    t.test("the helper disconnects before a decision: the card goes and the session is working again") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        rig.time = 3
        handle.simulateDisconnect()
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(rig.state, .working)
        t.expect(handle.replies.isEmpty, "never answered")
        t.expectEqual(rig.engine.waitingHelperCount, 0)
        t.expect(!rig.sounds.played.contains(.approved) && !rig.sounds.played.contains(.denied))
        t.expect(rig.usage.decisions.isEmpty)
        handle.simulateDisconnect()   // a second report is harmless
        t.expectEqual(rig.state, .working)
    }

    t.test("a helper that came with nothing to decide is answered 'no opinion' at once") {
        let rig = Rig()
        let unknown = try t.unwrap(rig.send(.toolStarted(tool("t1")), blocking: true))
        t.expectEqual(unknown.onlyReply, HookReply.passthrough)
        let notice = try t.unwrap(rig.send(.notification(kind: "auth_success", message: "hi"), blocking: true))
        t.expectEqual(notice.onlyReply, HookReply.passthrough)
        let empty = FakeReplyHandle()
        rig.engine.ingest([], reply: empty)
        t.expectEqual(empty.onlyReply, HookReply.passthrough, "an envelope that normalizes to nothing")
        t.expectEqual(rig.engine.waitingHelperCount, 0)
        t.expect(rig.store.pending.isEmpty)
    }

    t.test("a request without a helper is display-only: the state shows it, no card pretends to have buttons") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.send(.permissionRequested(permission()), at: 1)
        t.expectEqual(rig.state, .needsApproval)
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(rig.engine.state.requests.count, 1)
        t.expectEqual(rig.sounds.played, [.needsApproval])
        t.expectEqual(rig.store.pulse?.kind, .attention)
        // The same thing announced again changes nothing.
        rig.send(.permissionRequested(permission()), at: 2)
        t.expectEqual(rig.engine.state.requests.count, 1)
        t.expectEqual(rig.sounds.played, [.needsApproval])
        rig.send(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 9)
        t.expectEqual(rig.state, .done)
        t.expect(rig.engine.state.requests.isEmpty)
    }

    t.test("approvals / questions / plan review turned off: Perch steps aside for that kind only") {
        let kinds: [(AgentEvent, SessionState, (AppSettings) -> Void)] = [
            (.permissionRequested(permission()), .needsApproval, { $0.approvalsInNotch = false }),
            (.questionAsked(colourQuestion), .needsAnswer, { $0.questionsInNotch = false }),
            (.planProposed(samplePlan), .planReview, { $0.planReviewInNotch = false }),
        ]
        for (offIndex, off) in kinds.enumerated() {
            for (index, kind) in kinds.enumerated() {
                let rig = Rig()
                off.2(rig.settings)
                rig.send(.promptSubmitted(text: "go"))
                let handle = try t.unwrap(rig.send(kind.0, at: 1, blocking: true))
                t.expectEqual(rig.state, kind.1, "the session still shows that it is waiting")
                if index == offIndex {
                    t.expectEqual(handle.onlyReply, HookReply.passthrough, "handed straight back")
                    t.expect(rig.store.pending.isEmpty, "no card")
                    t.expect(rig.claude.encoded.isEmpty)
                } else {
                    t.expect(handle.isOpen)
                    t.expectEqual(rig.store.pending.count, 1)
                }
            }
        }
    }

    t.test("requests from an agent that is switched off are handed straight back, with no card") {
        let rig = Rig()
        rig.settings.codexEnabled = false
        let handle = try t.unwrap(rig.send(.permissionRequested(permission()), sid: "c1", agent: .codex, blocking: true))
        t.expectEqual(handle.onlyReply, HookReply.passthrough)
        t.expect(rig.store.sessions.isEmpty)
        t.expect(rig.store.pending.isEmpty)
        t.expect(rig.sounds.played.isEmpty)
        rig.send(.promptSubmitted(text: "hi"), sid: "c1", agent: .codex)
        t.expect(rig.store.sessions.isEmpty)
        // Claude is unaffected.
        rig.send(.promptSubmitted(text: "hi"))
        t.expectEqual(rig.store.sessions.count, 1)
    }

    t.test("auto-allow read-only tools: allowed at once through the adapter, no card, no noise") {
        let rig = Rig()
        rig.settings.autoAllowReadOnly = true
        rig.send(.promptSubmitted(text: "go"))
        rig.send(.toolStarted(tool("r1", "Read", "notes.txt")), at: 1)
        let read = try t.unwrap(rig.send(.permissionRequested(permission("Read", "/tmp/notes.txt")), at: 1, blocking: true))
        t.expectEqual(read.onlyReply?.stdout, "claude:allow")
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(rig.state, .runningTool, "the session never showed 'needs approval'")
        t.expect(rig.sounds.played.isEmpty)
        t.expect(rig.notifier.posted.isEmpty)
        t.expect(rig.usage.decisions.isEmpty, "the user did not decide anything")
        t.expect(rig.store.activity.contains { $0.direction == .note && $0.summary.contains("without asking") })
        t.expect(rig.store.activity.contains { $0.direction == .outgoing && $0.raw == "claude:allow" })

        let bash = try t.unwrap(rig.send(.permissionRequested(permission("Bash", "cat notes.txt")), at: 2, blocking: true))
        t.expect(bash.isOpen, "anything else still asks")
        let risky = try t.unwrap(rig.send(.permissionRequested(permission("Read", "~/.ssh/id_rsa", dangerous: true)), at: 3, blocking: true))
        t.expect(risky.isOpen, "a flagged request always asks")
        t.expectEqual(rig.store.pending.count, 2)
    }

    t.test("auto-allow is off by default, and never applies when approvals are left to the terminal") {
        let off = Rig()
        let asked = try t.unwrap(off.send(.permissionRequested(permission("Read", "a.txt")), blocking: true))
        t.expect(asked.isOpen)
        t.expectEqual(off.store.pending.count, 1)

        let aside = Rig()
        aside.settings.autoAllowReadOnly = true
        aside.settings.approvalsInNotch = false
        let handle = try t.unwrap(aside.send(.permissionRequested(permission("Read", "a.txt")), blocking: true))
        t.expectEqual(handle.onlyReply, HookReply.passthrough)
        t.expect(aside.claude.encoded.isEmpty)

        let displayOnly = Rig()
        displayOnly.settings.autoAllowReadOnly = true
        displayOnly.send(.permissionRequested(permission("Read", "a.txt")))
        t.expectEqual(displayOnly.state, .needsApproval, "without a helper there is nothing to allow")
    }

    t.test("several requests in one session: the oldest decides the state, each answer goes to its own helper") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        let first = try t.unwrap(rig.send(.permissionRequested(permission("Bash", "one")), at: 1, raw: toolRaw("Bash", "one"), blocking: true))
        let second = try t.unwrap(rig.send(.questionAsked(colourQuestion), at: 1.2, blocking: true))
        t.expectEqual(rig.store.pending.count, 2)
        t.expectEqual(rig.state, .needsApproval)
        t.expectEqual(rig.session?.stateSince, t0.addingTimeInterval(1), "a second request does not restart the clock")
        t.expectEqual(rig.sounds.played, [.needsApproval], "requests that arrive together share one sound")
        let ids = rig.store.pending.map { $0.id }
        rig.time = 5
        rig.engine.resolve(ids[0], with: .allow)
        t.expectEqual(rig.state, .needsAnswer, "the next request takes over")
        t.expectEqual(first.onlyReply?.stdout, "claude:allow")
        t.expect(second.isOpen)
        rig.engine.resolve(ids[1], with: .answer(["Which color?": "Blue"]))
        t.expectEqual(second.onlyReply?.stdout, "claude:answer(Which color?=Blue)")
        t.expectEqual(rig.state, .working)
    }

    t.test("answering the newer request first leaves the older one in charge") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        let first = try t.unwrap(rig.send(.permissionRequested(permission("Bash", "one")), at: 1, blocking: true))
        _ = rig.send(.planProposed(samplePlan), at: 5, blocking: true)
        t.expectEqual(rig.sounds.count(.needsApproval), 2, "requests seconds apart each get their sound")
        rig.engine.resolve(rig.store.pending[1].id, with: .approvePlan(acceptEdits: false))
        t.expectEqual(rig.state, .needsApproval)
        t.expect(first.isOpen)
    }

    t.test("two requests in one envelope: the helper belongs to the first") {
        let rig = Rig()
        let handle = FakeReplyHandle()
        rig.engine.ingest([event(.permissionRequested(permission("Bash", "one")), raw: toolRaw("Bash", "one")),
                           event(.questionAsked(colourQuestion))], reply: handle)
        t.expect(handle.isOpen)
        t.expectEqual(rig.store.pending.count, 1)
        t.expectEqual(rig.engine.state.requests.count, 2)
        t.expectEqual(rig.engine.waitingHelperCount, 1)
    }

    t.test("stopping the engine lets every waiting helper go") {
        let rig = Rig()
        rig.engine.start()
        t.expect(rig.engine.isRunning)
        rig.engine.start()   // twice is harmless
        let first = try t.unwrap(rig.openApproval())
        let second = try t.unwrap(rig.send(.questionAsked(colourQuestion), at: 1, sid: "s2", blocking: true,
                                           context: context(at: 1, pid: 501, tty: "/dev/ttys002")))
        rig.processes[501] = ProcessLiveness.Identity(startedAt: 5)
        rig.engine.stop()
        t.expect(!rig.engine.isRunning)
        t.expect(first.wasClosedWithoutReply)
        t.expect(second.wasClosedWithoutReply)
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(rig.engine.waitingHelperCount, 0)
        t.expectEqual(rig.state, .working)
        t.expectEqual(rig.store.sessions.count, 2, "the cards stay")
        rig.engine.stop()    // twice is harmless
        t.expectEqual(first.closeCount, 1)
    }

    t.test("dismissing a card lets its helper go and removes only that card") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        rig.send(.promptSubmitted(text: "other"), sid: "s2", context: context(pid: 501, tty: "/dev/ttys002"))
        rig.engine.dismiss(sessionID: s1)
        t.expect(handle.wasClosedWithoutReply)
        t.expectEqual(rig.store.sessions.map { $0.id }, ["claude:s2"])
        t.expect(rig.store.pending.isEmpty)
        rig.engine.dismiss(sessionID: "claude:nope")
        t.expectEqual(rig.store.sessions.count, 1)
        // Real activity brings a dismissed card back; a usage update does not.
        rig.send(.usageUpdated(contextPercent: 5, windows: [], model: nil, costUSD: nil), at: 2)
        t.expectNil(rig.session)
        rig.send(.toolStarted(tool("t5")), at: 3)
        t.expectEqual(rig.state, .runningTool)
    }

    t.test("without an adapter for the agent the helper gets 'no opinion' instead of a wrong answer") {
        let rig = Rig(adapters: false)
        let handle = try t.unwrap(rig.openApproval())
        let request = try t.unwrap(rig.store.pending.first)
        rig.engine.resolve(request.id, with: .allow)
        t.expectEqual(handle.onlyReply, HookReply.passthrough)
        t.expectEqual(rig.state, .working)
    }
}

// MARK: Requests settled somewhere else (the terminal race)

private func runCorrelationTests(_ t: TestRunner) {
    t.test("accepted in the terminal: the tool finishing withdraws the card and lets the helper go") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        t.expectEqual(rig.engine.state.requests.first?.toolUseID, "t1", "the request was matched to its tool call")
        rig.send(.toolFinished(id: "t1", name: "Bash", succeeded: true), at: 8, raw: toolRaw(id: "t1"))
        t.expect(handle.wasClosedWithoutReply, "never answered: Perch has no opinion on what the user did elsewhere")
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(rig.state, .working)
        t.expectEqual(rig.session?.recentTools.last?.succeeded, true)
        t.expect(!rig.sounds.played.contains(.approved))
        t.expect(rig.claude.encoded.isEmpty)
        t.expect(rig.usage.decisions.isEmpty)
        t.expectEqual(rig.engine.waitingHelperCount, 0)
        t.expect(rig.store.activity.contains { $0.direction == .note && $0.event == "Request withdrawn" })
    }

    t.test("a parallel sibling that needed no permission does not withdraw the card") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.send(.toolStarted(tool("t1")), at: 1, raw: toolRaw("Bash", "npm test", id: "t1"))
        rig.send(.toolStarted(tool("t2", "Grep", "TODO")), at: 1, raw: toolRaw("Grep", "TODO", id: "t2"))
        let handle = try t.unwrap(rig.send(.permissionRequested(permission()), at: 1.1, raw: toolRaw(), blocking: true))
        rig.send(.toolFinished(id: "t2", name: "Grep", succeeded: true), at: 1.5, raw: toolRaw("Grep", "TODO", id: "t2"))
        t.expect(handle.isOpen)
        t.expectEqual(rig.store.pending.count, 1)
        t.expectEqual(rig.state, .needsApproval)
        // A sibling of the same tool name, started alongside, is also not the request's own call.
        rig.send(.toolStarted(tool("t3", "Bash", "ls")), at: 1.6, raw: toolRaw("Bash", "ls", id: "t3"))
        rig.send(.toolFinished(id: "t3", name: "Bash", succeeded: true), at: 1.9, raw: toolRaw("Bash", "ls", id: "t3"))
        t.expect(handle.isOpen, "matched by input, not just by name")
        rig.send(.toolFinished(id: "t1", name: "Bash", succeeded: true), at: 20, raw: toolRaw(id: "t1"))
        t.expect(handle.wasClosedWithoutReply)
    }

    t.test("parallel tool calls that each need permission get a card each, matched by their input") {
        for reversed in [false, true] {
            let rig = Rig()
            rig.send(.promptSubmitted(text: "go"))
            rig.send(.toolStarted(tool("a", "Bash", "make a")), at: 1, raw: toolRaw("Bash", "make a", id: "a"))
            rig.send(.toolStarted(tool("b", "Bash", "make b")), at: 1, raw: toolRaw("Bash", "make b", id: "b"))
            let order = reversed ? ["make b", "make a"] : ["make a", "make b"]
            let first = try t.unwrap(rig.send(.permissionRequested(permission("Bash", order[0])), at: 1.1, raw: toolRaw("Bash", order[0]), blocking: true))
            let second = try t.unwrap(rig.send(.permissionRequested(permission("Bash", order[1])), at: 1.2, raw: toolRaw("Bash", order[1]), blocking: true))
            let handleA = reversed ? second : first, handleB = reversed ? first : second
            t.expectEqual(rig.store.pending.count, 2)
            t.expectEqual(rig.sounds.count(.needsApproval), 1, "one sound for the burst")
            let links = Dictionary(uniqueKeysWithValues: rig.engine.state.requests.map { ($0.toolUseID ?? "?", $0.request.kind) })
            t.expectEqual(links["a"], .permission(permission("Bash", "make a")))
            t.expectEqual(links["b"], .permission(permission("Bash", "make b")))
            // "b" is accepted in the terminal and runs; only its card goes.
            rig.send(.toolFinished(id: "b", name: "Bash", succeeded: true), at: 6, raw: toolRaw("Bash", "make b", id: "b"))
            t.expect(handleB.wasClosedWithoutReply)
            t.expect(handleA.isOpen)
            t.expectEqual(rig.store.pending.count, 1)
            t.expectEqual(rig.state, .needsApproval)
            rig.engine.resolve(rig.store.pending[0].id, with: .allow)
            t.expectEqual(handleA.onlyReply?.stdout, "claude:allow")
            t.expectEqual(rig.claude.encoded.first?.1.kind, .permission(permission("Bash", "make a")))
        }
    }

    t.test("a denied tool followed by a retry of the same command gets a fresh card") {
        let rig = Rig()
        let firstHandle = try t.unwrap(rig.openApproval())
        let first = try t.unwrap(rig.store.pending.first)
        rig.engine.resolve(first.id, with: .deny(message: "no"))
        // The model tries exactly the same command again two seconds later.
        rig.send(.toolStarted(tool("t2", at: 2)), at: 2, raw: toolRaw(id: "t2"))
        let secondHandle = try t.unwrap(rig.send(.permissionRequested(permission()), at: 2.1, raw: toolRaw(), blocking: true))
        let second = try t.unwrap(rig.store.pending.first)
        t.expect(second.id != first.id)
        t.expectEqual(rig.store.pending.count, 1)
        t.expectEqual(rig.engine.state.requests.first?.toolUseID, "t2")
        t.expectEqual(firstHandle.onlyReply?.stdout, "claude:deny(no)")
        t.expect(secondHandle.isOpen)
        t.expectEqual(rig.sounds.count(.needsApproval), 2)
        t.expectEqual(rig.state, .needsApproval)
    }

    t.test("refused in the terminal: nothing reports it, but the next tool proves the agent moved on") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        // Ten seconds later the model does something else. A refused tool never "finishes".
        rig.send(.toolStarted(tool("t2", "Read", "README.md", at: 10)), at: 10, raw: toolRaw("Read", "README.md", id: "t2"))
        t.expect(handle.wasClosedWithoutReply)
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(rig.state, .runningTool)
        t.expectEqual(rig.session?.currentTool?.id, "t2")
        t.expectEqual(rig.session?.recentTools.first?.succeeded, false, "the abandoned call is closed")
        t.expectEqual(rig.engine.state.tracking[s1]?.openTools.map { $0.id }, ["t2"])
    }

    t.test("another tool starting moments after the request is a parallel call, not proof of anything") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        rig.send(.toolStarted(tool("t2", "Read", "README.md")), at: EngineTuning.parallelWindow - 0.5, raw: toolRaw("Read", "README.md", id: "t2"))
        t.expect(handle.isOpen)
        t.expectEqual(rig.store.pending.count, 1)
        t.expectEqual(rig.state, .needsApproval, "activity never hides a waiting request")
        t.expectEqual(rig.session?.stateSince, t0)
        // The request's own tool being announced again (by a second source) proves nothing either.
        rig.send(.toolStarted(tool("t1")), at: 30, raw: toolRaw(id: "t1"))
        t.expect(handle.isOpen)
        t.expectEqual(rig.session?.toolCount, 2, "and it is not counted twice")
    }

    t.test("Esc in the terminal: the helper is killed, the card goes; the missed end of turn is caught later") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        rig.time = 3
        handle.simulateDisconnect()
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(rig.state, .working)
        // No Stop hook fires after an interrupt. A minute later Claude says it is waiting for input.
        rig.send(.notification(kind: "idle_prompt", message: "Claude is waiting for your input"), at: 63)
        t.expectEqual(rig.state, .idle)
        t.expectNil(rig.session?.currentTool)
    }

    t.test("a new prompt, the end of the turn, a failure or the end of the session all withdraw waiting requests") {
        let enders: [(AgentEvent, SessionState)] = [
            (.promptSubmitted(text: "never mind, do this instead"), .working),
            (.turnFinished(lastMessage: "ok", backgroundWork: false), .done),
            (.turnFailed(error: "API error"), .failed),
            (.sessionEnded(reason: "other"), .ended),
        ]
        for (ender, expected) in enders {
            let rig = Rig()
            let handle = try t.unwrap(rig.openApproval())
            let question = try t.unwrap(rig.send(.questionAsked(colourQuestion), at: 1, blocking: true))
            rig.send(ender, at: 12)
            t.expect(handle.wasClosedWithoutReply, "\(ender)")
            t.expect(question.wasClosedWithoutReply, "\(ender)")
            t.expect(rig.store.pending.isEmpty)
            t.expectEqual(rig.state, expected, "\(ender)")
            t.expectEqual(rig.engine.waitingHelperCount, 0)
        }
    }

    t.test("subagents share the session id: only events from the same subagent count") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.send(.subagentStarted(id: "sub1", type: "Explore"), at: 1, raw: ["agent_id": "sub1"])
        rig.send(.toolStarted(tool("s1t", "Bash", "ls")), at: 2, raw: toolRaw("Bash", "ls", id: "s1t", subagent: "sub1"))
        let handle = try t.unwrap(rig.send(.permissionRequested(permission("Bash", "ls")), at: 2, raw: toolRaw("Bash", "ls", subagent: "sub1"), blocking: true))
        t.expectEqual(rig.engine.state.requests.first?.scope, "sub1")
        t.expectEqual(rig.engine.state.requests.first?.toolUseID, "s1t")
        // The main conversation carries on: none of this is about the subagent's request.
        rig.send(.toolStarted(tool("m1", "Read", "a.txt")), at: 20, raw: toolRaw("Read", "a.txt", id: "m1"))
        rig.send(.toolFinished(id: "m1", name: "Read", succeeded: true), at: 21, raw: toolRaw("Read", "a.txt", id: "m1"))
        rig.send(.toolFinished(id: "unknown", name: "Bash", succeeded: true), at: 22, raw: toolRaw("Bash", "pwd", id: "unknown"))
        rig.send(.turnFinished(lastMessage: "waiting on the helper", backgroundWork: true), at: 23)
        t.expect(handle.isOpen)
        t.expectEqual(rig.state, .needsApproval)
        // Another subagent's activity does not count either.
        rig.send(.toolStarted(tool("o1", "Bash", "pwd")), at: 30, raw: toolRaw("Bash", "pwd", id: "o1", subagent: "sub2"))
        t.expect(handle.isOpen)
        // Its own subagent stopping does.
        rig.send(.subagentStopped(id: "sub1"), at: 40, raw: ["agent_id": "sub1"])
        t.expect(handle.wasClosedWithoutReply)
        t.expectEqual(rig.session?.activeSubagents, 0)
    }

    t.test("a main-conversation request is not withdrawn by a subagent's tools") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        rig.send(.toolStarted(tool("x1", "Bash", "ls")), at: 15, raw: toolRaw("Bash", "ls", id: "x1", subagent: "sub1"))
        rig.send(.toolFinished(id: "x1", name: "Bash", succeeded: true), at: 16, raw: toolRaw("Bash", "ls", id: "x1", subagent: "sub1"))
        t.expect(handle.isOpen)
        t.expectEqual(rig.state, .needsApproval)
    }

    t.test("when nothing is running in the background, the end of the turn ends subagent requests too") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        let handle = try t.unwrap(rig.send(.permissionRequested(permission()), at: 1, raw: toolRaw(subagent: "sub1"), blocking: true))
        rig.send(.turnFinished(lastMessage: "done", backgroundWork: false), at: 9)
        t.expect(handle.wasClosedWithoutReply)
        t.expectEqual(rig.state, .done)
    }

    t.test("a request whose tool call Perch never saw start is settled by that tool finishing") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        let handle = try t.unwrap(rig.send(.permissionRequested(permission()), at: 1, raw: toolRaw(), blocking: true))
        t.expectNil(rig.engine.state.requests.first?.toolUseID)
        rig.send(.toolFinished(id: "early", name: "Read", succeeded: true), at: 2)
        t.expect(handle.isOpen, "a different tool")
        rig.send(.toolFinished(id: "mine", name: "bash", succeeded: true), at: 3)
        t.expect(handle.wasClosedWithoutReply)
        t.expectEqual(rig.state, .working)
    }

    t.test("agents without tool ids: a call that is not waiting finishes before one that is") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"), agent: .codex)
        rig.send(.toolStarted(tool("gen-1", "shell", "ls")), at: 1, agent: .codex)
        rig.send(.toolStarted(tool("gen-2", "shell", "rm x")), at: 1, agent: .codex)
        let handle = try t.unwrap(rig.send(.permissionRequested(permission("shell", "rm x")), at: 1.1, agent: .codex, blocking: true))
        let codexID = Session.makeID(.codex, "s1")
        t.expectEqual(rig.engine.state.requests.first?.toolUseID, "gen-2", "with no input to compare, the newest call")
        rig.send(.toolFinished(id: nil, name: "shell", succeeded: true), at: 2, agent: .codex)
        t.expect(handle.isOpen, "the unclaimed call finished")
        t.expectEqual(rig.engine.state.tracking[codexID]?.openTools.map { $0.id }, ["gen-2"])
        rig.send(.toolFinished(id: nil, name: "shell", succeeded: true), at: 9, agent: .codex)
        t.expect(handle.wasClosedWithoutReply)
        t.expectEqual(rig.store.session(id: codexID)?.state, .working)
    }

    t.test("the same request delivered twice keeps one card and the newer helper") {
        let rig = Rig()
        let first = try t.unwrap(rig.openApproval())
        let cardID = try t.unwrap(rig.store.pending.first?.id)
        let second = try t.unwrap(rig.send(.permissionRequested(permission()), at: 0.05, raw: toolRaw(), blocking: true))
        t.expectEqual(rig.store.pending.count, 1)
        t.expectEqual(rig.store.pending.first?.id, cardID, "the card does not change")
        t.expect(first.wasClosedWithoutReply)
        t.expect(second.isOpen)
        t.expectEqual(rig.sounds.count(.needsApproval), 1)
        t.expectEqual(rig.engine.waitingHelperCount, 1)
        rig.engine.resolve(cardID, with: .allow)
        t.expectEqual(second.onlyReply?.stdout, "claude:allow")
        t.expect(first.replies.isEmpty)
    }

    t.test("the 'needs your permission' notification six seconds into a prompt is only an echo") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        let soundsBefore = rig.sounds.played
        rig.send(.notification(kind: "permission_prompt", message: "Claude needs your permission"), at: 6)
        t.expectEqual(rig.store.pending.count, 1)
        t.expectEqual(rig.engine.state.requests.count, 1)
        t.expectEqual(rig.sounds.played, soundsBefore, "no second sound")
        t.expectEqual(rig.notifier.posted.count, 1)
        t.expect(handle.isOpen)
        t.expectEqual(rig.session?.stateSince, t0)
    }

    t.test("without a blocking hook, the notification is the signal: a display-only 'needs approval'") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.send(.toolStarted(tool("t1")), at: 1, raw: toolRaw(id: "t1"))
        rig.send(.notification(kind: "permission_prompt", message: "Claude needs your permission to use Bash"), at: 7)
        t.expectEqual(rig.state, .needsApproval)
        t.expect(rig.store.pending.isEmpty, "nothing Perch could answer, so no card with buttons")
        t.expectEqual(rig.sounds.played, [.needsApproval])
        t.expectEqual(rig.store.pulse?.kind, .attention)
        rig.send(.notification(kind: "permission_prompt", message: "Claude needs your permission to use Bash"), at: 8)
        t.expectEqual(rig.sounds.played, [.needsApproval], "a repeat is ignored")
        // A sibling finishing is not it; the waiting tool finishing is.
        rig.send(.toolFinished(id: "t1", name: "Bash", succeeded: true), at: 12, raw: toolRaw(id: "t1"))
        t.expectEqual(rig.state, .working)
        t.expect(rig.engine.state.requests.isEmpty)
    }

    t.test("a real request replaces the notification's placeholder quietly") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.send(.notification(kind: "permission_prompt", message: "Claude needs your permission"), at: 1)
        let handle = try t.unwrap(rig.send(.permissionRequested(permission()), at: 1.5, raw: toolRaw(), blocking: true))
        t.expectEqual(rig.engine.state.requests.count, 1)
        t.expectEqual(rig.store.pending.count, 1)
        t.expectEqual(rig.sounds.played, [.needsApproval])
        t.expect(handle.isOpen)
    }

    t.test("correlation rules, directly") {
        let open = [OpenTool(id: "a", name: "Bash", scope: "", inputKey: 1, startedAt: t0),
                    OpenTool(id: "b", name: "Bash", scope: "", inputKey: 2, startedAt: t0),
                    OpenTool(id: "c", name: "Read", scope: "sub", inputKey: 3, startedAt: t0)]
        func link(_ name: String?, _ key: Int?, _ scope: String = "", _ requests: [TrackedRequest] = []) -> String? {
            RequestCorrelation.link(toolName: name, inputKey: key, scope: scope, openTools: open, requests: requests)?.id
        }
        t.expectEqual(link("Bash", 1), "a", "exact input wins")
        t.expectEqual(link("bash", 2), "b", "names compare without case")
        t.expectEqual(link("Bash", 99), "b", "otherwise the newest of that name")
        t.expectEqual(link("Bash", nil), "b")
        t.expectNil(link("Write", 77), "another tool with other input")
        t.expectEqual(link("Write", 1), "a", "identical input is enough, whatever the name")
        t.expectNil(link("Read", 3), "a tool in another scope is not a candidate")
        t.expectEqual(link("Read", 3, "sub"), "c")
        t.expectEqual(link(nil, nil), "b", "an unnamed request takes the newest call in its scope")
        func tracked(_ toolID: String?, _ name: String? = "Bash", scope: String = "", age: TimeInterval = 0) -> TrackedRequest {
            TrackedRequest(request: PendingRequest(sessionID: s1, agent: .claude, kind: .permission(permission()),
                                                   createdAt: t0.addingTimeInterval(-age), raw: .null),
                           isBlocking: true, scope: scope, toolName: name, toolUseID: toolID, lastNudgeAt: t0)
        }
        let claimedB = tracked("b")
        t.expectEqual(link("Bash", 2, "", [claimedB]), "a", "a claimed call cannot be claimed again")
        typealias Finished = RequestCorrelation.Finished
        func finished(_ id: String?, _ name: String, _ scope: String = "", _ requests: [TrackedRequest]) -> Finished {
            RequestCorrelation.toolFinished(id: id, name: name, scope: scope, openTools: open, requests: requests)
        }
        t.expectEqual(finished("b", "Bash", "", [claimedB]), Finished(openToolID: "b", withdrawRequestID: claimedB.id))
        t.expectEqual(finished("a", "Bash", "", [claimedB]), Finished(openToolID: "a", withdrawRequestID: nil))
        let unlinked = tracked(nil)
        t.expectEqual(finished("zzz", "Bash", "", [claimedB, unlinked]), Finished(openToolID: nil, withdrawRequestID: unlinked.id))
        t.expectEqual(finished("zzz", "Write", "", [unlinked]), Finished(openToolID: nil, withdrawRequestID: nil))
        t.expectEqual(finished("zzz", "Bash", "sub", [unlinked]), Finished(openToolID: nil, withdrawRequestID: nil))
        t.expectEqual(finished(nil, "Bash", "", [claimedB]), Finished(openToolID: "a", withdrawRequestID: nil))
        let claimedA = tracked("a")
        t.expectEqual(finished(nil, "Bash", "", [claimedA, claimedB]), Finished(openToolID: "a", withdrawRequestID: claimedA.id))

        let newTool = OpenTool(id: "n", name: "Edit", scope: "", inputKey: nil, startedAt: t0)
        let old = tracked("a", age: 10), fresh = tracked("b", age: 1), other = tracked(nil, scope: "sub", age: 10)
        t.expectEqual(RequestCorrelation.superseded(by: newTool, at: t0, requests: [old, fresh, other]), [old.id])
        let same = OpenTool(id: "a", name: "Bash", scope: "", inputKey: 1, startedAt: t0)
        t.expectEqual(RequestCorrelation.superseded(by: same, at: t0, requests: [old]), [])
    }
}

// MARK: Session identity: resume, clear, compaction, tabs

private func runIdentityTests(_ t: TestRunner) {
    t.test("the same session id under two agents is two cards") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "one"))
        rig.send(.promptSubmitted(text: "two"), agent: .codex, context: context(pid: 600, tty: "/dev/ttys009"))
        t.expectEqual(rig.store.sessions.map { $0.id }, ["claude:s1", "codex:s1"])
    }

    t.test("/clear: the old session ends and the new one takes its card's place, without fanfare") {
        let rig = Rig()
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"))
        rig.send(.promptSubmitted(text: "First conversation"), at: 1)
        rig.send(.promptSubmitted(text: "other tab"), at: 1, sid: "other", context: context(at: 1, pid: 700, tty: "/dev/ttys005"))
        rig.send(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 2)
        let soundsBefore = rig.sounds.played
        rig.send(.sessionEnded(reason: "clear"), at: 10)
        t.expectEqual(rig.state, .ended)
        rig.send(.sessionStarted(title: nil, model: nil, source: "clear"), at: 10.1, sid: "s2")
        t.expectEqual(rig.store.sessions.map { $0.id }, ["claude:s2", "claude:other"], "same slot, no extra card")
        t.expectEqual(rig.session("s2")?.state, .idle)
        t.expectEqual(rig.session("s2")?.title, "demo", "a new conversation gets a new title")
        t.expectEqual(rig.session("s2")?.turnCount, 0)
        t.expectEqual(rig.sounds.played, soundsBefore, "no 'session started' chime for a card that carries on")
        // A straggler from the old session does not bring it back.
        rig.send(.toolFinished(id: "x", name: "Bash", succeeded: true), at: 10.5)
        rig.send(.turnFinished(lastMessage: "late", backgroundWork: false), at: 11)
        t.expectEqual(rig.store.sessions.count, 2)
        t.expectNil(rig.session)
    }

    t.test("a new session in the tab of a finished one replaces it; a busy one is left alone") {
        for (finisher, replaced) in [(AgentEvent.turnFinished(lastMessage: "ok", backgroundWork: false), true),
                                     (.turnFailed(error: "x"), true),
                                     (.toolStarted(tool("t1")), false)] {
            let rig = Rig()
            rig.send(.sessionStarted(title: nil, model: nil, source: "startup"))
            rig.send(.promptSubmitted(text: "old"), at: 1)
            rig.send(finisher, at: 2)
            rig.send(.sessionStarted(title: nil, model: nil, source: "startup"), at: 60, sid: "s2",
                     context: context(at: 60, pid: 555, tty: "/dev/ttys001"))
            t.expectEqual(rig.store.sessions.count, replaced ? 1 : 2, "\(finisher)")
            t.expectEqual(rig.session("s2")?.state, .idle)
            t.expectEqual(rig.session("s2")?.pid, 555)
            t.expectEqual(rig.session != nil, !replaced)
        }
    }

    t.test("a session in another tab, or with no tty at all, replaces nothing") {
        let rig = Rig()
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"))
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"), at: 5, sid: "s2", context: context(at: 5, pid: 501, tty: "/dev/ttys002"))
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"), at: 6, sid: "s3", agent: .codex,
                 context: context(at: 6, pid: nil, tty: nil, env: [:]))
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"), at: 7, sid: "s4", agent: .codex,
                 context: context(at: 7, pid: nil, tty: nil, env: [:]))
        t.expectEqual(rig.store.sessions.count, 4)
        t.expectEqual(rig.sounds.count(.sessionStart), 4)
    }

    t.test("resume of an ended session revives its card and keeps what it knew") {
        let rig = Rig()
        rig.send(.sessionStarted(title: nil, model: "opus", source: "startup"))
        rig.send(.promptSubmitted(text: "Build the engine"), at: 1)
        rig.send(.toolStarted(tool("t1")), at: 2)
        rig.send(.sessionEnded(reason: "other"), at: 3)
        rig.send(.sessionStarted(title: nil, model: nil, source: "resume"), at: 4, context: context(at: 4, pid: 900, tty: "/dev/ttys004"))
        let session = try t.unwrap(rig.session)
        t.expectEqual(rig.store.sessions.count, 1)
        t.expectEqual(session.state, .idle)
        t.expectEqual(session.title, "Build the engine")
        t.expectEqual(session.turnCount, 1)
        t.expectEqual(session.toolCount, 1)
        t.expectEqual(session.model, "opus")
        t.expectEqual(session.pid, 900)
        t.expectEqual(session.terminal.tty, "/dev/ttys004")
        t.expectEqual(session.startedAt, t0)
        t.expectEqual(rig.store.pulse?.kind, .started)
        t.expectEqual(rig.sounds.count(.sessionStart), 2)
        rig.processes[900] = ProcessLiveness.Identity(startedAt: 9)
        rig.tick(at: 30)
        t.expectEqual(rig.state, .idle, "a revived card is not swept away as 'ended'")
    }

    t.test("resume withdraws requests of the earlier run; a duplicate 'started' resets nothing") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        // The same session announced again by a second source while it is busy.
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"), at: 1)
        t.expectEqual(rig.state, .needsApproval)
        t.expect(handle.isOpen)
        t.expectEqual(rig.session?.turnCount, 1)
        t.expectEqual(rig.sounds.count(.sessionStart), 1)
        // A real restart.
        rig.send(.sessionStarted(title: nil, model: nil, source: "resume"), at: 5)
        t.expect(handle.wasClosedWithoutReply)
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(rig.state, .idle)
        t.expectNil(rig.session?.currentTool)
        t.expectEqual(rig.session?.title, "Run the tests")
        t.expectEqual(rig.sounds.count(.sessionStart), 1, "it was never gone, so it is not announced again")
    }

    t.test("'started' from a different process means the session was restarted") {
        let rig = Rig()
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"))
        rig.send(.promptSubmitted(text: "go"), at: 1)
        rig.send(.toolStarted(tool("t1")), at: 2)
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"), at: 9, context: context(at: 9, pid: 812))
        t.expectEqual(rig.state, .idle)
        t.expectNil(rig.session?.currentTool)
        t.expectEqual(rig.session?.pid, 812)
    }

    t.test("/clear that keeps the session id starts the title over") {
        let rig = Rig()
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"), agent: .codex)
        rig.send(.promptSubmitted(text: "Old topic"), at: 1, agent: .codex)
        rig.send(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 2, agent: .codex)
        rig.send(.sessionStarted(title: nil, model: nil, source: "clear"), at: 3, agent: .codex)
        let cleared = try t.unwrap(rig.session("s1", .codex))
        t.expectEqual(cleared.title, "demo")
        t.expectNil(cleared.lastPrompt)
        t.expectNil(cleared.lastMessage)
        t.expectEqual(cleared.state, .idle)
        rig.send(.promptSubmitted(text: "New topic"), at: 4, agent: .codex)
        t.expectEqual(rig.session("s1", .codex)?.title, "New topic")
    }

    t.test("late events after a session is gone are ignored; a prompt brings it back") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.send(.sessionEnded(reason: "other"), at: 1)
        rig.tick(at: 2)
        t.expectEqual(rig.state, .ended, "an ended card lingers for a moment")
        rig.tick(at: 6)
        t.expectNil(rig.session, "then it is removed")
        for late in [AgentEvent.toolFinished(id: "t", name: "Bash", succeeded: true), .toolStarted(tool("t")),
                     .turnFinished(lastMessage: "x", backgroundWork: false), .subagentStarted(id: "a", type: nil)] {
            rig.send(late, at: 7)
        }
        t.expect(rig.store.sessions.isEmpty)
        rig.send(.promptSubmitted(text: "back again"), at: 8)
        t.expectEqual(rig.state, .working)
        // Long after the end, any activity counts again.
        let other = Rig()
        other.send(.sessionEnded(reason: "other"))
        other.send(.toolStarted(tool("t")), at: EngineTuning.tombstoneLifetime + 1)
        t.expectEqual(other.state, .runningTool)
    }

    t.test("terminal facts: later events add to them, a missing tty never erases one, a new tty replaces the lot") {
        let rig = Rig()
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"),
                 context: context(env: ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:ABC"]))
        rig.send(.promptSubmitted(text: "go"), at: 1, context: context(at: 1, pid: nil, tty: nil, cwd: "/Users/dev/projects/demo/sub", env: [:]))
        var session = try t.unwrap(rig.session)
        t.expectEqual(session.terminal.tty, "/dev/ttys001")
        t.expectEqual(session.terminal.bundleID, "com.googlecode.iterm2")
        t.expectEqual(session.terminal.itermSessionID, "w0t1p0:ABC")
        t.expectEqual(session.pid, 500)
        t.expectEqual(session.cwd, demoFolder, "the first folder is the project")
        t.expect(!session.isHeadless)
        rig.send(.toolStarted(tool("t")), at: 2, context: context(at: 2, env: ["TERM_PROGRAM": "iTerm.app", "TMUX_PANE": "%3"]))
        t.expectEqual(rig.session?.terminal.tmuxPane, "%3")
        t.expectEqual(rig.session?.terminal.itermSessionID, "w0t1p0:ABC")
        rig.send(.toolStarted(tool("u")), at: 3, context: context(at: 3, tty: "/dev/ttys042", env: ["TERM_PROGRAM": "Apple_Terminal"]))
        session = try t.unwrap(rig.session)
        t.expectEqual(session.terminal.tty, "/dev/ttys042")
        t.expectEqual(session.terminal.bundleID, "com.apple.Terminal")
        t.expectNil(session.terminal.itermSessionID, "facts about the old tab are dropped")
        t.expectNil(session.terminal.tmuxPane)
    }

    t.test("a folder that only becomes known later still names the card") {
        let rig = Rig()
        rig.send(.toolStarted(tool("t")), agent: .gemini, context: context(pid: nil, tty: nil, cwd: nil, env: [:]))
        t.expectEqual(rig.session("s1", .gemini)?.title, "Gemini CLI")
        rig.send(.toolFinished(id: "t", name: "Bash", succeeded: true), at: 1, agent: .gemini,
                 context: context(at: 1, pid: nil, tty: nil, cwd: "/Users/dev/code/api", env: [:]))
        t.expectEqual(rig.session("s1", .gemini)?.title, "api")
        t.expectEqual(rig.session("s1", .gemini)?.cwd, "/Users/dev/code/api")
        t.expectEqual(rig.session("s1", .gemini)?.projectName, "api")
    }

    t.test("pid 0 and pid 1 are not process ids worth remembering") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"), context: context(pid: 0))
        t.expectNil(rig.session?.pid)
        rig.send(.toolStarted(tool("t")), at: 1, context: context(at: 1, pid: 1))
        t.expectNil(rig.session?.pid)
        rig.tick(at: 10)
        t.expect(rig.session != nil, "no pid, no liveness check")
    }
}

// MARK: Hidden sessions

private func runVisibilityTests(_ t: TestRunner) {
    let desktopEnv = ["__CFBundleIdentifier": "com.anthropic.claudefordesktop"]

    t.test("where a session runs is worked out from the event's facts") {
        func host(pid: Int32? = 500, tty: String? = nil, env: [String: String] = [:], known: Session? = nil) -> SessionVisibility.Host {
            SessionVisibility.host(context: context(pid: pid, tty: tty, env: env), known: known)
        }
        t.expectEqual(host(tty: "/dev/ttys001", env: terminalEnv), .terminal)
        t.expectEqual(host(tty: "/dev/ttys001"), .terminal)
        t.expectEqual(host(env: terminalEnv), .headless, "claude -p from a shell: a process but no tty")
        t.expectEqual(host(), .headless)
        t.expectEqual(host(env: desktopEnv), .desktopApp)
        t.expectEqual(host(tty: "/dev/ttys001", env: desktopEnv), .desktopApp, "the Claude desktop app, whatever else is set")
        t.expectEqual(host(env: ["__CFBundleIdentifier": "com.google.antigravity"]), .desktopApp, "an app that is not a terminal")
        t.expectEqual(host(env: ["TERM_PROGRAM": "vscode"]), .desktopApp)
        t.expectEqual(host(tty: "/dev/ttys003", env: ["TERM_PROGRAM": "vscode"]), .terminal, "an editor's built-in terminal is a terminal")
        t.expectEqual(host(env: ["TERM_PROGRAM": "iTerm.app"]), .headless)
        t.expectEqual(host(pid: nil), .unknown, "no facts at all: a watched file, not a hook")
        t.expectEqual(host(pid: 0), .unknown)

        var known = Session(id: s1, agent: .claude, sessionID: "s1", cwd: "", title: "", model: nil, state: .idle,
                            stateSince: t0, startedAt: t0, lastEventAt: t0)
        known.terminal.tty = "/dev/ttys001"
        t.expectEqual(host(known: known), .terminal, "a tty seen earlier sticks")
        t.expectEqual(host(pid: nil, known: known), .terminal)
        known.terminal.tty = nil
        known.pid = 44
        t.expectEqual(host(pid: nil, known: known), .headless)
        t.expectEqual(SessionVisibility.host(of: known), .unknown)
        known.isHeadless = true
        t.expectEqual(SessionVisibility.host(of: known), .headless)
        known.terminal.bundleID = "com.google.antigravity"
        t.expectEqual(SessionVisibility.host(of: known), .desktopApp)

        var config = EngineConfig()
        t.expect(SessionVisibility.isVisible(.terminal, config) && SessionVisibility.isVisible(.unknown, config))
        t.expect(!SessionVisibility.isVisible(.headless, config), "hidden by default")
        t.expect(SessionVisibility.isVisible(.desktopApp, config), "shown by default")
        config.showHeadlessSessions = true
        config.showDesktopAppSessions = false
        t.expect(SessionVisibility.isVisible(.headless, config))
        t.expect(!SessionVisibility.isVisible(.desktopApp, config))
    }

    t.test("headless sessions are hidden by default: no card, and their prompts go straight back") {
        let rig = Rig()
        let headless = context(tty: nil)
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"), context: headless)
        rig.send(.promptSubmitted(text: "scripted run"), context: headless)
        let handle = try t.unwrap(rig.send(.permissionRequested(permission()), raw: toolRaw(), blocking: true, context: headless))
        t.expect(rig.store.sessions.isEmpty)
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(handle.onlyReply, HookReply.passthrough)
        t.expect(rig.sounds.played.isEmpty)
        t.expect(rig.notifier.posted.isEmpty)
        t.expectNil(rig.store.pulse)
        t.expectEqual(rig.usage.observed.count, 3, "usage still sees every event")
        t.expectEqual(rig.store.activity.filter { $0.direction == .incoming }.count, 3, "and the log still shows what arrived")
        t.expect(rig.store.activity.contains { $0.direction == .note && $0.summary.contains("without a terminal") })
    }

    t.test("with 'show headless sessions' on they get a card, marked as headless") {
        let rig = Rig()
        rig.settings.showHeadlessSessions = true
        let handle = try t.unwrap(rig.send(.permissionRequested(permission()), blocking: true, context: context(tty: nil)))
        t.expectEqual(rig.session?.isHeadless, true)
        t.expectEqual(rig.state, .needsApproval)
        t.expect(handle.isOpen)
        // Turning the setting off hides the card at the next housekeeping round and frees the helper.
        rig.settings.showHeadlessSessions = false
        rig.tick(at: 3)
        t.expectNil(rig.session)
        t.expect(handle.wasClosedWithoutReply)
        t.expect(rig.store.pending.isEmpty)
    }

    t.test("desktop-app sessions are shown by default and hidden by their own setting") {
        let desktop = context(tty: nil, env: desktopEnv)
        let rig = Rig()
        let handle = try t.unwrap(rig.send(.permissionRequested(permission()), blocking: true, context: desktop))
        t.expectEqual(rig.session?.isHeadless, true, "no terminal to jump to")
        t.expectEqual(rig.session?.terminal.bundleID, "com.anthropic.claudefordesktop")
        t.expect(handle.isOpen)
        t.expectEqual(rig.store.pending.count, 1)

        let hidden = Rig()
        hidden.settings.showDesktopAppSessions = false
        hidden.settings.showHeadlessSessions = true
        let aside = try t.unwrap(hidden.send(.permissionRequested(permission()), blocking: true, context: desktop))
        t.expectEqual(aside.onlyReply, HookReply.passthrough)
        t.expect(hidden.store.sessions.isEmpty)
        hidden.send(.promptSubmitted(text: "x"), context: context(tty: nil, env: ["__CFBundleIdentifier": "com.google.antigravity"]))
        t.expect(hidden.store.sessions.isEmpty, "other apps that are not terminals count as desktop apps too")
        hidden.send(.promptSubmitted(text: "x"), sid: "plain", context: context(tty: nil))
        t.expectEqual(hidden.store.sessions.count, 1, "a plain headless run is the other setting")
    }

    t.test("events from a watched file (no process facts) are shown, and one tty-less event does not hide a terminal session") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "from a rollout file"), sid: "file", agent: .codex, context: context(pid: nil, tty: nil, env: [:]))
        t.expectEqual(rig.session("file", .codex)?.isHeadless, false)
        rig.send(.promptSubmitted(text: "in a terminal"))
        rig.send(.toolStarted(tool("t")), at: 1, context: context(at: 1, tty: nil))
        t.expectEqual(rig.state, .runningTool)
        t.expectEqual(rig.session?.isHeadless, false)
        // Later proof that the file-watched session has a process but no terminal hides it.
        rig.send(.toolStarted(tool("t")), at: 2, sid: "file", agent: .codex, context: context(at: 2, pid: 77, tty: nil, env: [:]))
        t.expectNil(rig.session("file", .codex))
    }

    t.test("switching an agent off removes its cards at the next round and frees its helpers") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        rig.send(.promptSubmitted(text: "codex work"), sid: "c1", agent: .codex, context: context(pid: 600, tty: "/dev/ttys007"))
        rig.processes[600] = ProcessLiveness.Identity(startedAt: 3)
        rig.settings.claudeEnabled = false
        rig.tick(at: 3)
        t.expectEqual(rig.store.sessions.map { $0.id }, ["codex:c1"])
        t.expect(handle.wasClosedWithoutReply)
        t.expect(rig.store.pending.isEmpty)
    }
}

// MARK: Sounds, pulses, notifications, usage, the shared store

private func runSideEffectTests(_ t: TestRunner) {
    t.test("no chime or notification about a session whose tab is already in front") {
        let rig = Rig()
        rig.jumper.frontmost = [s1]
        _ = rig.openApproval()
        t.expectEqual(rig.sounds.played, [.sessionStart], "the attention sound is skipped")
        t.expect(rig.notifier.posted.isEmpty)
        t.expectEqual(rig.store.pulse?.kind, .attention, "the card still pulses")
        t.expectEqual(rig.jumper.questions, 1, "asked once for the sound and the notification together")
        rig.engine.resolve(try t.unwrap(rig.store.pending.first).id, with: .allow)
        t.expectEqual(rig.sounds.played.last, .approved, "feedback for the user's own click still plays")
        rig.send(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 5)
        t.expect(!rig.sounds.played.contains(.done))
        t.expect(rig.notifier.posted.isEmpty)
        t.expectEqual(rig.store.pulse?.kind, .done)
        rig.send(.promptSubmitted(text: "again"), at: 6)
        rig.send(.turnFailed(error: "x"), at: 7)
        t.expect(!rig.sounds.played.contains(.failed))

        rig.jumper.frontmost = []
        rig.send(.promptSubmitted(text: "again"), at: 8)
        rig.send(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 9)
        t.expectEqual(rig.sounds.played.last, .done)
        t.expectEqual(rig.notifier.posted.count, 1)
    }

    t.test("with 'mute when the terminal is focused' off, sounds play regardless") {
        let rig = Rig()
        rig.settings.muteWhenTerminalFocused = false
        rig.jumper.frontmost = [s1]
        _ = rig.openApproval()
        t.expectEqual(rig.sounds.played, [.sessionStart, .needsApproval])
        t.expectEqual(rig.notifier.posted.count, 1)
        t.expectEqual(rig.jumper.questions, 0, "the terminal is not even asked")
    }

    t.test("every notable moment sets the store's pulse") {
        let rig = Rig()
        var seen: [Pulse.Kind] = []
        func note() { if let kind = rig.store.pulse?.kind { seen.append(kind) } }
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup")); note()
        rig.send(.promptSubmitted(text: "go"), at: 1)
        _ = rig.send(.permissionRequested(permission()), at: 2, blocking: true); note()
        rig.engine.resolve(rig.store.pending[0].id, with: .allow); note()
        _ = rig.send(.permissionRequested(permission("Write", "a.txt")), at: 10, blocking: true)
        rig.engine.resolve(rig.store.pending[0].id, with: .deny(message: nil)); note()
        rig.send(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 20); note()
        rig.send(.promptSubmitted(text: "more"), at: 21)
        rig.time = 22
        rig.send(.turnFailed(error: "overloaded")); note()
        t.expectEqual(seen, [.started, .attention, .approved, .denied, .done, .failed])
        t.expectEqual(rig.store.pulse?.sessionID, s1)
        t.expectEqual(rig.store.pulse?.at, t0.addingTimeInterval(22))
        t.expectEqual(rig.notifier.posted.map { $0.title },
                      ["Claude needs your approval", "Claude needs your approval", "Claude finished — go", "Claude stopped with an error — go"])
        t.expectEqual(rig.notifier.posted.last?.body, "overloaded")
    }

    t.test("usage sees every event, and every answer the user gives") {
        let rig = Rig()
        rig.settings.geminiEnabled = false
        _ = rig.openApproval()
        rig.send(.usageUpdated(contextPercent: 10, windows: [], model: nil, costUSD: nil), at: 1)
        rig.send(.promptSubmitted(text: "ignored agent"), sid: "g", agent: .gemini)
        t.expectEqual(rig.usage.observed.count, 6)
        t.expectEqual(rig.usage.observed.last?.agent, .gemini)
        rig.engine.resolve(rig.store.pending[0].id, with: .allowAlways(suggestionID: 0))
        t.expectEqual(rig.usage.decisions.count, 1)
        t.expectEqual(rig.usage.decisions.first?.0, .allowAlways(suggestionID: 0))
        t.expectEqual(rig.usage.decisions.first?.1.sessionID, s1)
    }

    t.test("the engine works with no sounds, terminal, usage or notifications at all") {
        let store = SessionStore()
        let engine = SessionEngine(store: store, settings: AppSettings(defaults: EngineTestDefaults()), adapters: [:],
                                   sounds: nil, jumper: nil, usage: nil, notifier: nil)
        let handle = FakeReplyHandle()
        engine.ingest([event(.promptSubmitted(text: "go")), event(.permissionRequested(permission()), at: 1)], reply: handle)
        t.expectEqual(store.sessions.first?.state, .needsApproval)
        engine.resolve(try t.unwrap(store.pending.first).id, with: .deny(message: nil))
        t.expectEqual(handle.onlyReply, HookReply.passthrough)
        engine.ingest([event(.turnFinished(lastMessage: "ok", backgroundWork: false), at: 2)], reply: nil)
        t.expectEqual(store.sessions.first?.state, .done)
        t.expectEqual(store.pulse?.kind, .done)
    }

    t.test("sessions and requests somebody else put in the store (demo mode) are never touched") {
        let rig = Rig()
        var demo = SampleData.session(.claude, "demo-1", title: "Demo", cwd: "/demo", state: .working, model: nil, ago: 10)
        demo.isDemo = true
        demo.isHeadless = true
        let demoRequest = PendingRequest(sessionID: demo.id, agent: .claude, kind: .permission(permission()), createdAt: t0, raw: .null)
        rig.store.sessions = [demo]
        rig.store.pending = [demoRequest]
        _ = rig.openApproval()
        t.expectEqual(rig.store.sessions.map { $0.id }, [demo.id, s1])
        t.expectEqual(rig.store.pending.count, 2)
        t.expectEqual(rig.store.pending.first?.id, demoRequest.id)
        rig.engine.resolve(demoRequest.id, with: .allow)
        t.expectEqual(rig.store.pending.count, 2, "not the engine's request, so not the engine's to answer")
        rig.tick(at: 5)
        rig.send(.sessionEnded(reason: "other"), at: 6)
        rig.tick(at: 20)
        rig.engine.dismiss(sessionID: demo.id)
        rig.engine.stop()
        t.expectEqual(rig.store.sessions, [demo], "the demo card is exactly as it was")
        t.expectEqual(rig.store.pending, [demoRequest])
    }
}

// MARK: Housekeeping (stepped by hand; nothing here sleeps)

private func runHousekeepingTests(_ t: TestRunner) {
    t.test("a session whose process is gone is removed, with its requests") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        rig.tick(at: 3)
        t.expectEqual(rig.state, .needsApproval, "alive: nothing happens")
        rig.processes[500] = nil
        rig.tick(at: 6)
        t.expectNil(rig.session)
        t.expect(rig.store.pending.isEmpty)
        t.expect(handle.wasClosedWithoutReply)
        rig.send(.toolFinished(id: "t1", name: "Bash", succeeded: true), at: 7)
        t.expectNil(rig.session, "a straggler does not bring the card back")
    }

    t.test("a recycled process id is not mistaken for the agent") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.tick(at: 3)
        t.expectEqual(rig.engine.state.tracking[s1]?.process, ProcessLiveness.Identity(startedAt: 100))
        rig.processes[500] = ProcessLiveness.Identity(startedAt: 2222)   // same number, different process
        rig.tick(at: 6)
        t.expectNil(rig.session)
    }

    t.test("a process the system will not describe still counts as alive") {
        let rig = Rig()
        rig.processes[500] = ProcessLiveness.Identity(startedAt: nil)
        rig.send(.promptSubmitted(text: "go"))
        rig.tick(at: 3)
        rig.tick(at: 6)
        t.expectEqual(rig.state, .working)
        rig.processes[500] = ProcessLiveness.Identity(startedAt: 50)     // now it can be read: remembered from here on
        rig.tick(at: 9)
        t.expectEqual(rig.state, .working)
        rig.processes[500] = ProcessLiveness.Identity(startedAt: 51)
        rig.tick(at: 12)
        t.expectNil(rig.session)
    }

    t.test("a session that moves to another process is checked against the new one") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.tick(at: 3)
        rig.processes[500] = nil
        rig.processes[640] = ProcessLiveness.Identity(startedAt: 7)
        rig.send(.toolStarted(tool("t")), at: 4, context: context(at: 4, pid: 640))
        rig.tick(at: 6)
        t.expectEqual(rig.state, .runningTool)
        t.expectEqual(rig.engine.state.tracking[s1]?.processPID, 640)
    }

    t.test("real processes: this one is alive, a finished one is gone, launchd is not ours to ask about") {
        let me = ProcessInfo.processInfo.processIdentifier
        t.expect(ProcessLiveness.isAlive(me))
        let identity = try t.unwrap(ProcessLiveness.identity(of: me))
        let started = try t.unwrap(identity.startedAt)
        t.expect(started > 1_000_000_000 && started <= Date().timeIntervalSince1970 + 1, "a believable start time")
        t.expectEqual(ProcessLiveness.identity(of: me), identity, "stable from call to call")
        t.expect(!ProcessLiveness.isAlive(0))
        t.expect(!ProcessLiveness.isAlive(-5))
        t.expect(ProcessLiveness.isAlive(1), "'not permitted' still means it exists")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        t.expectNil(ProcessLiveness.identity(of: child.processIdentifier), "a process that has exited")
    }

    t.test("ended cards go after a few seconds") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.send(.sessionEnded(reason: "prompt_input_exit"), at: 10)
        rig.tick(at: 10 + EngineTuning.endedCardLifetime - 1)
        t.expectEqual(rig.state, .ended)
        rig.tick(at: 10 + EngineTuning.endedCardLifetime)
        t.expectNil(rig.session)
    }

    t.test("resting cards are cleared after the idle time; busy and waiting ones never are") {
        let rig = Rig()
        rig.settings.idleCleanupMinutes = 30
        func add(_ sid: String, _ pid: Int32, _ events: [AgentEvent]) {
            rig.processes[pid] = ProcessLiveness.Identity(startedAt: Double(pid))
            for one in events { rig.send(one, at: 0, sid: sid, context: context(pid: pid, tty: "/dev/ttys\(pid)")) }
        }
        add("idle", 601, [.sessionStarted(title: nil, model: nil, source: "startup")])
        add("done", 602, [.promptSubmitted(text: "x"), .turnFinished(lastMessage: "ok", backgroundWork: false)])
        add("failed", 603, [.promptSubmitted(text: "x"), .turnFailed(error: "e")])
        add("tool", 604, [.promptSubmitted(text: "x"), .toolStarted(tool("t"))])
        add("asking", 605, [.promptSubmitted(text: "x"), .permissionRequested(permission())])
        rig.tick(at: 29 * 60)
        t.expectEqual(rig.store.sessions.count, 5)
        rig.tick(at: 30 * 60)
        t.expectEqual(Set(rig.store.sessions.map { $0.sessionID }), ["tool", "asking"])

        let never = Rig()
        never.settings.idleCleanupMinutes = 0
        never.send(.sessionStarted(title: nil, model: nil, source: "startup"))
        never.tick(at: 100 * 3600)
        t.expect(never.session != nil, "0 means never")
    }

    t.test("activity resets the idle clock") {
        let rig = Rig()
        rig.settings.idleCleanupMinutes = 10
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"))
        rig.send(.usageUpdated(contextPercent: 3, windows: [], model: nil, costUSD: nil), at: 9 * 60)
        rig.tick(at: 12 * 60)
        t.expect(rig.session != nil)
        rig.tick(at: 19 * 60 + 1)
        t.expectNil(rig.session)
    }

    t.test("reminders: once per interval per waiting request, only when switched on") {
        let rig = Rig()
        rig.settings.reminderEnabled = true
        rig.settings.reminderSeconds = 60
        _ = rig.openApproval()
        rig.tick(at: 59)
        t.expectEqual(rig.sounds.count(.reminder), 0)
        rig.tick(at: 61)
        t.expectEqual(rig.sounds.count(.reminder), 1)
        rig.tick(at: 64)
        rig.tick(at: 100)
        t.expectEqual(rig.sounds.count(.reminder), 1, "not again within the interval")
        rig.tick(at: 122)
        t.expectEqual(rig.sounds.count(.reminder), 2)
        rig.jumper.frontmost = [s1]
        rig.tick(at: 190)
        t.expectEqual(rig.sounds.count(.reminder), 2, "not while the user is looking at that tab")
        rig.jumper.frontmost = []
        rig.engine.resolve(rig.store.pending[0].id, with: .allow)
        rig.tick(at: 400)
        t.expectEqual(rig.sounds.count(.reminder), 2, "nothing waiting, nothing to remind about")

        let off = Rig()
        _ = off.openApproval()
        off.tick(at: 1000)
        t.expectEqual(off.sounds.count(.reminder), 0, "off by default")
    }

    t.test("reminders: two requests in one session share a sound, and the interval has a floor") {
        let rig = Rig()
        rig.settings.reminderEnabled = true
        rig.settings.reminderSeconds = 1
        _ = rig.openApproval()
        _ = rig.send(.questionAsked(colourQuestion), at: 0.5, blocking: true)
        rig.tick(at: 3)
        t.expectEqual(rig.sounds.count(.reminder), 0, "never more often than the floor")
        rig.tick(at: EngineTuning.minReminderSeconds + 1)
        t.expectEqual(rig.sounds.count(.reminder), 1)
    }

    t.test("a card that says 'working' with nothing happening for ten minutes is put to rest") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.send(.toolStarted(tool("t")), at: 1, sid: "long", context: context(at: 1, pid: 606, tty: "/dev/ttys006"))
        rig.processes[606] = ProcessLiveness.Identity(startedAt: 6)
        rig.tick(at: EngineTuning.stuckWorkingSeconds - 1)
        t.expectEqual(rig.state, .working)
        rig.tick(at: EngineTuning.stuckWorkingSeconds + 1)
        t.expectEqual(rig.state, .idle)
        t.expectEqual(rig.session("long")?.state, .runningTool, "a long-running tool is not 'stuck'")
        t.expect(rig.sounds.played.isEmpty)
    }

    t.test("housekeeping with nothing to do changes nothing") {
        let rig = Rig()
        _ = rig.openApproval()
        let before = rig.engine.state
        let sessions = rig.store.sessions
        rig.tick(at: 1)
        rig.tick(at: 2)
        t.expectEqual(rig.store.sessions, sessions)
        t.expectEqual(rig.engine.state.requests, before.requests)
    }
}

// MARK: The activity log

private func runActivityLogTests(_ t: TestRunner) {
    t.test("every incoming event and every decision is logged, newest first") {
        let rig = Rig()
        rig.send(.sessionStarted(title: nil, model: nil, source: "startup"), name: "SessionStart", context: context(at: 0))
        rig.send(.promptSubmitted(text: "Run the tests"), at: 1, name: "UserPromptSubmit")
        rig.send(.toolStarted(tool("t1")), at: 2, raw: toolRaw(id: "t1"), name: "PreToolUse")
        _ = rig.send(.permissionRequested(permission()), at: 2, raw: toolRaw(), name: "PermissionRequest", blocking: true)
        rig.time = 5
        rig.engine.resolve(rig.store.pending[0].id, with: .allow)
        rig.send(.toolFinished(id: "t1", name: "Bash", succeeded: true), at: 6, raw: toolRaw(id: "t1"), name: "PostToolUse")
        rig.send(.turnFinished(lastMessage: "All tests pass", backgroundWork: false), at: 7, name: "Stop")

        let log = rig.store.activity
        t.expectEqual(log.map { $0.event }, ["Stop", "PostToolUse", "Decision", "PermissionRequest", "PreToolUse", "UserPromptSubmit", "SessionStart"])
        t.expectEqual(log.map { $0.summary }, [
            "Finished: All tests pass", "Bash finished", "You allowed it", "Claude wants to run a shell command: `npm test`",
            "Claude is using Bash: npm test", "You asked Claude: \u{201C}Run the tests\u{201D}", "Claude started a session in demo",
        ])
        t.expectEqual(log.map { $0.direction }, [.incoming, .incoming, .outgoing, .incoming, .incoming, .incoming, .incoming])
        t.expect(log.allSatisfy { $0.agent == "claude" && $0.sessionID == s1 })
        t.expectEqual(log[2].raw, "claude:allow", "an outgoing line shows exactly what was sent to the agent")
        t.expectEqual(log[2].at, t0.addingTimeInterval(5))
        t.expectEqual(log[3].raw, toolRaw().serialized())
        t.expectEqual(log[3].at, t0.addingTimeInterval(2))
        t.expectEqual(log.last?.raw, "", "no payload, nothing to show")
        t.expectEqual(Set(log.map { $0.id }).count, log.count)
    }

    t.test("the log explains what Perch concluded by itself") {
        let rig = Rig()
        let handle = try t.unwrap(rig.openApproval())
        handle.simulateDisconnect()
        let note = try t.unwrap(rig.store.activity.first)
        t.expectEqual(note.direction, .note)
        t.expectEqual(note.event, "Request withdrawn")
        t.expect(note.summary.contains("terminal"))
        t.expectEqual(note.sessionID, s1)

        let aside = Rig()
        aside.settings.questionsInNotch = false
        _ = aside.send(.questionAsked(colourQuestion), blocking: true)
        t.expect(aside.store.activity.contains { $0.direction == .note && $0.event == "Stepped aside" && $0.summary.contains("answering questions") })
    }

    t.test("the log holds at most 300 lines") {
        let rig = Rig()
        for n in 0..<320 { rig.send(.toolStarted(tool("t\(n)", "Bash", "step \(n)")), at: Double(n)) }
        t.expectEqual(rig.store.activity.count, 300)
        t.expectEqual(rig.store.activity.first?.summary, "Claude is using Bash: step 319")
        t.expectEqual(rig.store.activity.last?.summary, "Claude is using Bash: step 20")
    }

    t.test("large payloads are cut to about 4 KB in the log, but kept whole for the adapter") {
        let rig = Rig()
        let big: JSONValue = ["tool_name": "Write", "tool_input": ["content": .string(String(repeating: "x", count: 50_000))]]
        _ = rig.send(.permissionRequested(permission("Write", "big.txt")), raw: big, blocking: true)
        let line = try t.unwrap(rig.store.activity.first { $0.direction == .incoming })
        t.expect(line.raw.utf8.count <= EngineTuning.rawLogLimit + 80, "\(line.raw.utf8.count) bytes")
        t.expect(line.raw.contains("cut short"))
        t.expectEqual(rig.store.pending.first?.raw, big)
    }

    t.test("with the log switched off nothing is recorded") {
        let rig = Rig()
        rig.settings.activityLogEnabled = false
        let handle = try t.unwrap(rig.openApproval())
        rig.engine.resolve(rig.store.pending[0].id, with: .allow)
        t.expect(rig.store.activity.isEmpty)
        t.expectEqual(handle.onlyReply?.stdout, "claude:allow", "everything else works as usual")
    }

    t.test("a run of usage updates takes one line, not the whole log") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"), name: "UserPromptSubmit")
        for n in 1...5 {
            rig.send(.usageUpdated(contextPercent: Double(n), windows: [], model: nil, costUSD: nil), at: Double(n), name: "statusline")
        }
        t.expectEqual(rig.store.activity.count, 2)
        t.expectEqual(rig.store.activity.first?.summary, "Usage update: memory 5% full")
        rig.send(.toolStarted(tool("t")), at: 6, name: "PreToolUse")
        rig.send(.usageUpdated(contextPercent: 6, windows: [], model: nil, costUSD: nil), at: 7, name: "statusline")
        t.expectEqual(rig.store.activity.count, 4)
        t.expectEqual(rig.usage.observed.count, 8, "usage itself still sees every one")
    }

    t.test("lines other parts of the app added share the same cap and are kept in order") {
        let rig = Rig()
        rig.store.activity = (0..<299).map { ActivityEntry(at: t0, direction: .note, agent: "perch", event: "Demo", sessionID: nil, summary: "demo \($0)", raw: "") }
        rig.send(.promptSubmitted(text: "a"), name: "UserPromptSubmit")
        rig.send(.toolStarted(tool("t")), at: 1, name: "PreToolUse")
        t.expectEqual(rig.store.activity.count, 300)
        t.expectEqual(rig.store.activity[0].event, "PreToolUse")
        t.expectEqual(rig.store.activity[2].summary, "demo 0")
        t.expectEqual(rig.store.activity.last?.summary, "demo 297")
    }
}

// MARK: A whole session, replayed from the captured Claude Code payloads

/// A deliberately small stand-in for the Claude adapter (which lives in another module): it turns
/// one captured hook payload from Fixtures/claude/hooks into a normalized event, keeping the real
/// payload as `raw`. Only the engine is under test here, so the translation is the bare minimum.
private func replayEvent(_ fixture: String, at seconds: TimeInterval, edit: ((inout [String: JSONValue]) -> Void)? = nil) -> NormalizedEvent? {
    guard var fields = JSONValue.parse(TestRunner.fixtureText("claude/hooks/\(fixture).json"))?.objectValue else { return nil }
    fields["session_id"] = "replay"            // the fixtures come from several runs; make them one session
    edit?(&fields)
    let raw = JSONValue.object(fields)
    let name = raw["hook_event_name"].stringValue ?? ""
    let toolName = raw["tool_name"].stringValue ?? ""
    let input = raw["tool_input"]
    let agentEvent: AgentEvent
    switch name {
    case "SessionStart": agentEvent = .sessionStarted(title: nil, model: raw["model"].stringValue, source: raw["source"].stringValue)
    case "SessionEnd": agentEvent = .sessionEnded(reason: raw["reason"].stringValue)
    case "UserPromptSubmit": agentEvent = .promptSubmitted(text: raw["prompt"].stringValue ?? "")
    case "PreToolUse":
        let summary = input["command"].stringValue ?? input["file_path"].stringValue ?? input["description"].stringValue ?? toolName
        agentEvent = .toolStarted(ToolCall(id: raw["tool_use_id"].stringValue ?? UUID().uuidString, name: toolName, summary: summary,
                                           startedAt: t0.addingTimeInterval(seconds)))
    case "PostToolUse": agentEvent = .toolFinished(id: raw["tool_use_id"].stringValue, name: toolName, succeeded: true)
    case "PostToolUseFailure": agentEvent = .toolFinished(id: raw["tool_use_id"].stringValue, name: toolName, succeeded: false)
    case "PermissionRequest":
        switch toolName {
        case "AskUserQuestion":
            let questions = (input["questions"].arrayValue ?? []).enumerated().map { index, question in
                Question(id: index, text: question["question"].stringValue ?? "", header: question["header"].stringValue,
                         options: (question["options"].arrayValue ?? []).enumerated().map {
                             QuestionOption(id: $0.offset, label: $0.element["label"].stringValue ?? "", detail: $0.element["description"].stringValue)
                         },
                         multiSelect: question["multiSelect"].boolValue ?? false)
            }
            agentEvent = .questionAsked(QuestionRequest(questions: questions))
        case "ExitPlanMode":
            agentEvent = .planProposed(PlanRequest(markdown: input["plan"].stringValue ?? "", filePath: input["planFilePath"].stringValue))
        default:
            let suggestions = (raw["permission_suggestions"].arrayValue ?? []).enumerated().map {
                PermissionSuggestion(id: $0.offset, label: "Always allow", raw: $0.element)
            }
            agentEvent = .permissionRequested(PermissionRequest(toolName: toolName, summary: "Use \(toolName)",
                                                                detail: input["command"].stringValue ?? input["file_path"].stringValue ?? "",
                                                                suggestions: suggestions))
        }
    case "Notification": agentEvent = .notification(kind: raw["notification_type"].stringValue ?? "", message: raw["message"].stringValue ?? "")
    case "Stop":
        agentEvent = .turnFinished(lastMessage: raw["last_assistant_message"].stringValue,
                                   backgroundWork: !(raw["background_tasks"].arrayValue ?? []).isEmpty)
    case "SubagentStart": agentEvent = .subagentStarted(id: raw["agent_id"].stringValue, type: raw["agent_type"].stringValue)
    case "SubagentStop": agentEvent = .subagentStopped(id: raw["agent_id"].stringValue)
    case "PreCompact": agentEvent = .compactionStarted
    case "PostCompact": agentEvent = .compactionFinished
    default: return nil
    }
    let environment = ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w1t0p0:REPLAY", "CLAUDE_PID": "4242"]
    let context = EventContext(pid: 4242, tty: "/dev/ttys012", cwd: raw["cwd"].stringValue, env: environment,
                               transcriptPath: raw["transcript_path"].stringValue, receivedAt: t0.addingTimeInterval(seconds))
    return NormalizedEvent(agent: .claude, sessionID: "replay", event: agentEvent, context: context, rawEventName: name, raw: raw)
}

private func runReplayTests(_ t: TestRunner) {
    t.test("the fixtures used by the replay are present and translate") {
        for name in ["SessionStart.startup.interactive", "UserPromptSubmit", "PreToolUse.Read", "PostToolUseFailure.Read", "PreToolUse.Bash",
                     "PostToolUse.Bash", "PreToolUse.Write", "PermissionRequest.Write", "PostToolUse.Write", "PreToolUse.Agent", "SubagentStart",
                     "PreToolUse.Bash.in-subagent", "SubagentStop", "PostToolUse.Agent", "PreToolUse.AskUserQuestion",
                     "PermissionRequest.AskUserQuestion", "Notification.permission_prompt", "PostToolUse.AskUserQuestion",
                     "PreToolUse.ExitPlanMode", "PermissionRequest.ExitPlanMode", "PostToolUse.ExitPlanMode",
                     "PermissionRequest.Bash.addRules-suggestion", "PreCompact.manual", "SessionStart.compact",
                     "SubagentStop.internal-empty-agent-type", "PostCompact.manual", "Stop", "SessionEnd.prompt_input_exit"] {
            t.expect(replayEvent(name, at: 0) != nil, name)
        }
    }

    t.test("a realistic Claude Code session, start to finish") {
        let rig = Rig()
        rig.processes[4242] = ProcessLiveness.Identity(startedAt: 42)
        rig.settings.reminderEnabled = true
        let id = Session.makeID(.claude, "replay")
        var clock: TimeInterval = 0
        /// Sends one captured payload a little later than the previous one.
        @discardableResult
        func play(_ fixture: String, after delay: TimeInterval = 0.1, blocking: Bool = false,
                  edit: ((inout [String: JSONValue]) -> Void)? = nil) throws -> FakeReplyHandle? {
            clock += delay
            rig.time = clock
            let one = try t.unwrap(replayEvent(fixture, at: clock, edit: edit), fixture)
            let handle = blocking ? FakeReplyHandle() : nil
            rig.engine.ingest([one], reply: handle)
            return handle
        }
        func session() -> Session? { rig.store.session(id: id) }

        // The session opens and the user asks for something.
        try play("SessionStart.startup.interactive")
        t.expectEqual(session()?.state, .idle)
        t.expectEqual(session()?.title, "demo")
        t.expectEqual(session()?.model, "claude-haiku-5-5")
        t.expectEqual(session()?.terminal.bundleID, "com.googlecode.iterm2")
        t.expectEqual(session()?.transcriptPath?.hasSuffix(".jsonl"), true)
        try play("UserPromptSubmit", after: 5)
        t.expectEqual(session()?.state, .working)
        let title = try t.unwrap(session()?.title)
        t.expect(title != "demo" && title.count <= 80 && !title.contains("\n"), "the prompt became the title: \(title)")

        // A Read that fails, then a Bash that works: no permission needed.
        try play("PreToolUse.Read", after: 2)
        t.expectEqual(session()?.state, .runningTool)
        t.expectEqual(session()?.currentTool?.name, "Read")
        try play("PostToolUseFailure.Read")
        t.expectEqual(session()?.state, .working)
        t.expectEqual(session()?.recentTools.last?.succeeded, false)
        try play("PreToolUse.Bash", after: 1)
        try play("PostToolUse.Bash")
        t.expectEqual(session()?.recentTools.map { $0.succeeded }, [false, true])

        // A Write that needs permission; the user allows it from the notch.
        try play("PreToolUse.Write", after: 1)
        let write = try t.unwrap(try play("PermissionRequest.Write", after: 0.08, blocking: true))
        t.expectEqual(session()?.state, .needsApproval)
        let writeCard = try t.unwrap(rig.store.pending.first)
        t.expectEqual(rig.engine.state.requests.first?.toolUseID, session()?.currentTool?.id, "matched to the Write by its input")
        if case .permission(let request) = writeCard.kind { t.expectEqual(request.suggestions.count, 1) } else { t.expect(false, "a permission card") }
        clock += 3; rig.time = clock
        rig.engine.resolve(writeCard.id, with: .allow)
        t.expectEqual(write.onlyReply?.stdout, "claude:allow")
        t.expectEqual(session()?.state, .working)
        try play("PostToolUse.Write", after: 0.05)
        t.expectEqual(session()?.state, .working)
        t.expectEqual(write.replies.count + write.closeCount, 1, "answered exactly once")

        // A helper agent runs its own tool, under the same session id.
        try play("PreToolUse.Agent", after: 1)
        try play("SubagentStart")
        t.expectEqual(session()?.activeSubagents, 1)
        try play("PreToolUse.Bash.in-subagent", after: 0.5)
        t.expectEqual(session()?.currentTool?.summary.hasPrefix("ls"), true)
        try play("SubagentStop", after: 2)
        t.expectEqual(session()?.activeSubagents, 0)
        try play("PostToolUse.Agent")
        t.expectEqual(session()?.state, .working)

        // A question. The terminal dialog shows too; six seconds in, Claude sends its notification.
        try play("PreToolUse.AskUserQuestion", after: 1)
        let question = try t.unwrap(try play("PermissionRequest.AskUserQuestion", after: 0.07, blocking: true))
        t.expectEqual(session()?.state, .needsAnswer)
        let soundsAtQuestion = rig.sounds.played
        try play("Notification.permission_prompt", after: 6)
        t.expectEqual(rig.store.pending.count, 1)
        t.expectEqual(rig.sounds.played, soundsAtQuestion, "the echo makes no noise")
        rig.engine.resolve(rig.store.pending[0].id, with: .answer(["charlie: which one?": "White"]))
        t.expectEqual(question.onlyReply?.stdout, "claude:answer(charlie: which one?=White)")
        try play("PostToolUse.AskUserQuestion", after: 0.1)
        t.expectEqual(session()?.state, .working)

        // A plan, approved from the notch.
        try play("PreToolUse.ExitPlanMode", after: 3)
        let plan = try t.unwrap(try play("PermissionRequest.ExitPlanMode", after: 0.1, blocking: true))
        t.expectEqual(session()?.state, .planReview)
        if case .plan(let request)? = rig.store.pending.first?.kind { t.expect(!request.markdown.isEmpty) } else { t.expect(false, "a plan card") }
        rig.engine.resolve(rig.store.pending[0].id, with: .approvePlan(acceptEdits: true))
        t.expectEqual(plan.onlyReply?.stdout, "claude:approve(true)")
        try play("PostToolUse.ExitPlanMode", after: 0.2)

        // A Bash command that needs permission; this time the user presses Enter in the terminal.
        // The helper is left running with no signal, so only the tool finishing gives it away.
        let command: JSONValue = ["command": "python3 -c \"print(6*7)\"", "description": "Run python3 command printing 6*7"]
        try play("PreToolUse.Bash", after: 2) { $0["tool_input"] = command; $0["tool_use_id"] = "toolu_replay_python" }
        let python = try t.unwrap(try play("PermissionRequest.Bash.addRules-suggestion", after: 0.06, blocking: true))
        t.expectEqual(session()?.state, .needsApproval)
        t.expectEqual(rig.engine.state.requests.first?.toolUseID, "toolu_replay_python")
        try play("Notification.permission_prompt", after: 6)
        rig.tick(at: clock + 1)
        t.expect(python.isOpen, "housekeeping leaves a live request alone")
        try play("PostToolUse.Bash", after: 2.1) { $0["tool_input"] = command; $0["tool_use_id"] = "toolu_replay_python" }
        t.expect(python.wasClosedWithoutReply)
        t.expect(rig.store.pending.isEmpty)
        t.expectEqual(session()?.state, .working)

        // The turn ends.
        try play("Stop", after: 1)
        t.expectEqual(session()?.state, .done)
        t.expectEqual(session()?.lastMessage, "done")
        t.expectEqual(rig.store.pulse?.kind, .done)
        t.expectEqual(rig.sounds.played.last, .done)

        // /compact while resting: PreCompact, an internal helper stopping, SessionStart(compact), PostCompact.
        try play("PreCompact.manual", after: 30)
        t.expectEqual(session()?.state, .compacting)
        try play("SubagentStop.internal-empty-agent-type", after: 4)
        try play("SessionStart.compact", after: 0.1)
        t.expectEqual(session()?.state, .compacting)
        try play("PostCompact.manual", after: 0.1)
        t.expectEqual(session()?.state, .done)
        t.expectEqual(session()?.activeSubagents, 0)
        t.expectEqual(rig.store.sessions.count, 1, "one card throughout")

        // What the card knows at the end.
        let final = try t.unwrap(session())
        t.expectEqual(final.title, title)
        t.expectEqual(final.turnCount, 1)
        t.expectEqual(final.toolCount, 8)
        t.expectEqual(final.recentTools.count, 8)
        t.expectEqual(final.pid, 4242)
        t.expectEqual(final.terminal.tty, "/dev/ttys012")
        t.expectEqual(final.terminal.itermSessionID, "w1t0p0:REPLAY")
        t.expectEqual(final.startedAt, t0.addingTimeInterval(0.1))
        t.expectEqual(final.lastEventAt, t0.addingTimeInterval(clock))
        t.expectNil(final.currentTool)
        t.expect(!final.isHeadless)

        // What the user heard and what was recorded.
        t.expectEqual(rig.sounds.played, [.sessionStart, .needsApproval, .approved, .needsAnswer, .approved, .needsApproval, .approved,
                                          .needsApproval, .done])
        t.expectEqual(rig.usage.decisions.count, 3)
        t.expectEqual(rig.claude.encoded.count, 3)
        t.expectEqual(rig.engine.waitingHelperCount, 0)
        t.expectEqual(rig.usage.observed.count, 30)
        t.expectEqual(rig.store.activity.filter { $0.direction == .incoming }.count, 30, "every event is in the log")
        t.expectEqual(rig.store.activity.filter { $0.direction == .outgoing }.map { $0.summary },
                      ["You approved the plan and let it edit files without asking", "You answered: charlie: which one? → White", "You allowed it"])
        t.expectEqual(rig.store.activity.filter { $0.direction == .note }.map { $0.event }, ["Request withdrawn"])

        // The user quits; the card says goodbye and goes.
        try play("SessionEnd.prompt_input_exit", after: 60)
        t.expectEqual(session()?.state, .ended)
        rig.tick(at: clock + EngineTuning.endedCardLifetime + 1)
        t.expect(rig.store.sessions.isEmpty)
        t.expect(rig.store.pending.isEmpty)
    }
}

// MARK: The real timer, and a few edges

private func runTimerAndEdgeTests(_ t: TestRunner) {
    t.test("start() runs housekeeping on a timer and stop() ends it") {
        let rig = Rig()
        rig.engine.tickInterval = 0.02
        rig.send(.promptSubmitted(text: "go"))
        rig.processes[500] = nil                    // the agent "dies"
        t.expect(rig.session != nil, "nothing happens until the engine is started")
        rig.engine.start()
        t.expect(t.wait(2) { rig.session == nil }, "the timer noticed the dead process")
        rig.engine.stop()
        rig.time = 100                              // past the time late events are ignored for
        rig.send(.promptSubmitted(text: "again"))
        _ = t.wait(0.15) { false }
        t.expect(rig.session != nil, "no housekeeping after stop()")
    }

    t.test("a 'needs your permission' notification that crosses with the answer is ignored") {
        let rig = Rig()
        _ = rig.openApproval()
        rig.time = 5.9
        rig.engine.resolve(rig.store.pending[0].id, with: .allow)
        let soundsBefore = rig.sounds.played
        rig.send(.notification(kind: "permission_prompt", message: "Claude needs your permission"), at: 6)
        t.expectEqual(rig.state, .working)
        t.expect(rig.engine.state.requests.isEmpty)
        t.expectEqual(rig.sounds.played, soundsBefore)
    }

    t.test("a request is matched to its call by identical input even when the names are spelled differently") {
        let rig = Rig()
        rig.send(.promptSubmitted(text: "go"))
        rig.send(.toolStarted(tool("x1", "shell", "make")), at: 1, raw: toolRaw("shell", "make", id: "x1"))
        rig.send(.toolStarted(tool("x2", "shell", "ls")), at: 1, raw: toolRaw("shell", "ls", id: "x2"))
        let handle = try t.unwrap(rig.send(.permissionRequested(permission("Bash", "make")), at: 1.1, raw: toolRaw("Bash", "make"), blocking: true))
        t.expectEqual(rig.engine.state.requests.first?.toolUseID, "x1")
        rig.send(.toolFinished(id: "x1", name: "shell", succeeded: true), at: 9, raw: toolRaw("shell", "make", id: "x1"))
        t.expect(handle.wasClosedWithoutReply)
    }

    t.test("a title the agent supplies at the start is used, and prompts are kept at a sensible length") {
        let rig = Rig()
        rig.send(.sessionStarted(title: "  Billing   refactor\nsecond line ", model: nil, source: "startup"))
        t.expectEqual(rig.session?.title, "Billing refactor")
        let essay = String(repeating: "lorem ipsum ", count: 2000)
        rig.send(.promptSubmitted(text: essay), at: 1)
        t.expectEqual(rig.session?.title, "Billing refactor")
        t.expectEqual(rig.session?.lastPrompt?.count, EngineTuning.textLimit)
        rig.send(.turnFinished(lastMessage: essay, backgroundWork: false), at: 2)
        t.expectEqual(rig.session?.lastMessage?.count, EngineTuning.textLimit)
        rig.send(.promptSubmitted(text: "   "), at: 3)
        t.expectEqual(rig.session?.turnCount, 2)
        t.expect(rig.session?.lastPrompt?.hasPrefix("lorem") ?? false, "an empty prompt does not wipe the last real one")
    }

    t.test("settings are read fresh for every event") {
        let rig = Rig()
        rig.settings.approvalsInNotch = false
        let first = try t.unwrap(rig.send(.permissionRequested(permission("Bash", "one")), raw: toolRaw("Bash", "one"), blocking: true))
        t.expectEqual(first.onlyReply, HookReply.passthrough)
        rig.send(.promptSubmitted(text: "next"), at: 5)
        rig.settings.approvalsInNotch = true
        let second = try t.unwrap(rig.send(.permissionRequested(permission("Bash", "two")), at: 6, raw: toolRaw("Bash", "two"), blocking: true))
        t.expect(second.isOpen)
        t.expectEqual(rig.store.pending.count, 1)
        let config = EngineConfig(settings: rig.settings)
        t.expectEqual(config.enabledAgents, Set(AgentKind.allCases))
        t.expectEqual(config.idleCleanupMinutes, rig.settings.idleCleanupMinutes)
        t.expectEqual(config.reminderSeconds, rig.settings.reminderSeconds)
        t.expect(config.approvalsInNotch && config.questionsInNotch && config.planReviewInNotch)
        t.expect(!config.autoAllowReadOnly && !config.showHeadlessSessions && config.showDesktopAppSessions && !config.reminderEnabled)
    }
}

// (appended to the edge tests above)
private func runIdlePromptTests(_ t: TestRunner) {
    t.test("idle_prompt ends display-only waiting, but never a request whose helper is still connected") {
        let aside = Rig()
        aside.settings.approvalsInNotch = false
        aside.send(.promptSubmitted(text: "go"))
        _ = aside.send(.permissionRequested(permission()), at: 1, blocking: true)
        t.expectEqual(aside.state, .needsApproval)
        // Esc in the terminal: no hook fires. A minute later Claude reports it is waiting for a prompt.
        aside.send(.notification(kind: "idle_prompt", message: "Claude is waiting for your input"), at: 62)
        t.expectEqual(aside.state, .idle)
        t.expect(aside.engine.state.requests.isEmpty)

        let handed = Rig()
        _ = handed.openApproval()
        handed.engine.resolve(handed.store.pending[0].id, with: .passToTerminal)
        handed.send(.notification(kind: "idle_prompt", message: ""), at: 62)
        t.expectEqual(handed.state, .idle, "handed to the terminal and then cancelled there")

        let blocking = Rig()
        let handle = try t.unwrap(blocking.openApproval())
        blocking.send(.notification(kind: "idle_prompt", message: ""), at: 62)
        t.expect(handle.isOpen)
        t.expectEqual(blocking.state, .needsApproval)
        t.expectEqual(blocking.store.pending.count, 1)
    }
}
