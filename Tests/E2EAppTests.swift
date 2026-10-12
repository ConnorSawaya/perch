// E2EAppTests.swift — checks on the parts that join the modules together (Sources/App/Main), run
// inside one process with the real adapters and the real session engine.
//
// Run with: scripts/test-all.sh E2EApp
// (it is compiled with all of Sources/Core and Sources/App except PerchApp.swift, the entry point)
//
// What is covered here:
//   1. launch options and the file-backed preferences used by test runs;
//   2. the envelope router: a whole Claude Code turn from the captured payloads, a waiting
//      helper answered through the adapter, unknown and switched-off agents, the debug channel;
//   3. the automatic answers used by the end-to-end tests, the uninstall steps, the diagnostics;
//   4. click tests in a real (never visible) window for the "outline swallows clicks" fixes, and
//      the click-mode rule for the usage button in the panel's top strip.
//
// The same plumbing is exercised again from the outside, through the real helper and the built
// app, by scripts/e2e.sh.

import AppKit
import SwiftUI

func runE2EAppTests(_ t: TestRunner) {
    // Nothing real is touched: PERCH_HOME points Perch's own folder (and so its log file) at a
    // temporary folder for the whole run, as the other suites do.
    let home = TestRunner.tempDir("perch-e2eapp-home")
    setenv("PERCH_HOME", home.path, 1)
    defer {
        Thread.sleep(forTimeInterval: 0.2)   // let the last log lines land before the folder goes
        try? FileManager.default.removeItem(at: home)
    }
    _ = NSApplication.shared
    launchOptionTests(t)
    preferencesTests(t)
    routerTests(t)
    supportTests(t)
    MainActor.assumeIsolated {
        clickTests(t)
        stripButtonTests(t)
    }
}

// MARK: - Helpers

/// A waiting helper that only records what it was told.
private final class FakeHandle: ReplyHandle {
    let id = UUID()
    var replies: [HookReply] = []
    var closed = false
    var onDisconnect: (() -> Void)?
    func reply(_ reply: HookReply) { replies.append(reply) }
    func close() { closed = true }
}

private func memorySettings() -> AppSettings {
    let settings = AppSettings(defaults: FileDefaults.inMemory())
    settings.soundsEnabled = false
    return settings
}

/// The real adapters, pointed at empty temporary folders so nothing on this Mac is read.
private func sandboxAdapters(_ root: URL) -> [AgentKind: AgentAdapter] {
    let helper = root.appendingPathComponent("bin/perch-hook")
    let backups = root.appendingPathComponent("backups")
    return [
        .claude: ClaudeAdapter(configDir: root.appendingPathComponent("claude"), helperURL: helper, backupsDir: backups,
                               locator: ClaudeLocator(home: root, systemFolders: [], searchPath: nil)),
        .codex: CodexAdapter(codexHome: root.appendingPathComponent("codex"), helperPath: helper.path, backupsDir: backups),
        .antigravity: AntigravityAdapter(geminiDir: root.appendingPathComponent("gemini"), helperPath: helper.path, backupsDir: backups),
        .gemini: GeminiAdapter(geminiDir: root.appendingPathComponent("gemini"), helperPath: helper.path, backupsDir: backups),
    ]
}

/// Engine + router wired the way AppController wires them, without windows or a socket.
private final class Wiring {
    let root = TestRunner.tempDir("perch-e2eapp")
    let settings = memorySettings()
    let store = SessionStore()
    let adapters: [AgentKind: AgentAdapter]
    let engine: SessionEngine
    let router: EnvelopeRouter

    init() {
        adapters = sandboxAdapters(root)
        (adapters[.claude] as? ClaudeAdapter)?.setGitBranchLookup { _ in nil }
        engine = SessionEngine(store: store, settings: settings, adapters: adapters, sounds: nil, jumper: nil, usage: nil, notifier: nil)
        router = EnvelopeRouter(adapters: adapters, settings: settings, engine: engine)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func envelope(_ agent: String, fixture: String? = nil, payload: String = "", event: String? = nil,
                  channel: String = "hook", wait: Bool = false) -> HookEnvelope {
        var envelope = HookEnvelope(agent: agent)
        envelope.channel = channel
        envelope.event = event
        envelope.payload = fixture.map { TestRunner.fixtureText($0) } ?? payload
        envelope.wantsReply = wait
        envelope.sentAt = Date().timeIntervalSince1970
        return envelope
    }

    @discardableResult
    func send(_ agent: String, _ fixture: String, wait: Bool = false) -> FakeHandle? {
        let handle = wait ? FakeHandle() : nil
        router.route(envelope(agent, fixture: fixture, wait: wait), handle)
        return handle
    }

    var only: Session? { store.sessions.count == 1 ? store.sessions.first : nil }
}

// MARK: - 1. Launch options and preferences

private func launchOptionTests(_ t: TestRunner) {
    t.test("a plain launch has every test switch off") {
        let options = LaunchOptions(arguments: [], environment: ["PATH": "/usr/bin"])
        t.expectEqual(options, LaunchOptions())
        t.expectNil(options.autoResolve, "automatic answers are never on by default")
        t.expect(!options.skipLoginItem && !options.startInDemo && !options.usesPrivateHome && options.snapshotDir == nil)
    }

    t.test("options are read from arguments and from the environment") {
        let fromArguments = LaunchOptions(arguments: ["--snapshot", "/tmp/shots", "--demo", "--no-login-item", "--test-autoresolve", "deny"],
                                          environment: [:])
        t.expectEqual(fromArguments.snapshotDir?.path, "/tmp/shots")
        t.expect(fromArguments.startInDemo && fromArguments.skipLoginItem)
        t.expectEqual(fromArguments.autoResolve, .deny)

        let fromEnvironment = LaunchOptions(arguments: [], environment: [
            "PERCH_NO_LOGIN_ITEM": "1", "PERCH_TEST_AUTORESOLVE": "allow", "PERCH_TEST_AUTORESOLVE_DELAY": "1.5", "PERCH_HOME": "/tmp/x",
        ])
        t.expect(fromEnvironment.skipLoginItem && fromEnvironment.usesPrivateHome)
        t.expect(!fromEnvironment.mayChangeAgentSettings, "a PERCH_HOME run never changes an agent's settings")
        t.expect(LaunchOptions().mayChangeAgentSettings, "a normal launch may")
        t.expectEqual(fromEnvironment.autoResolve, .allow)
        t.expectEqual(fromEnvironment.autoResolveDelay, 1.5)
    }

    t.test("nonsense values switch nothing on") {
        let options = LaunchOptions(arguments: ["--snapshot"], environment: [
            "PERCH_NO_LOGIN_ITEM": "0", "PERCH_TEST_AUTORESOLVE": "maybe", "PERCH_TEST_AUTORESOLVE_DELAY": "-3", "PERCH_HOME": " ",
        ])
        t.expectNil(options.snapshotDir, "--snapshot without a folder is ignored")
        t.expect(!options.skipLoginItem, "PERCH_NO_LOGIN_ITEM=0 means no")
        t.expectNil(options.autoResolve)
        t.expectEqual(options.autoResolveDelay, 0.4)
        t.expect(!options.usesPrivateHome)
    }
}

private func preferencesTests(_ t: TestRunner) {
    t.test("file-backed preferences survive a restart and can be seeded by a test") {
        let folder = TestRunner.tempDir("perch-prefs")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("nested/preferences.plist")

        let first = AppSettings(defaults: FileDefaults.file(file))
        t.expect(!first.showHeadlessSessions && first.theme == .midnight, "a missing file means defaults")
        first.showHeadlessSessions = true
        first.theme = .ember
        first.diffMaxLines = 77
        first.panelWidth = 600
        t.expect(FileManager.default.fileExists(atPath: file.path), "the file (and its folder) is created on the first change")

        let second = AppSettings(defaults: FileDefaults.file(file))
        t.expect(second.showHeadlessSessions)
        t.expectEqual(second.theme, .ember)
        t.expectEqual(second.diffMaxLines, 77)
        t.expectEqual(second.panelWidth, 600)

        // The way scripts/e2e.sh seeds settings: a hand-written property list.
        let seeded = folder.appendingPathComponent("seeded.plist")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>perch.hasCompletedOnboarding</key><true/>
          <key>perch.showHeadlessSessions</key><true/>
          <key>perch.soundsEnabled</key><false/>
        </dict></plist>
        """
        try xml.write(to: seeded, atomically: true, encoding: .utf8)
        let third = AppSettings(defaults: FileDefaults.file(seeded))
        t.expect(third.hasCompletedOnboarding && third.showHeadlessSessions && !third.soundsEnabled)

        second.resetToDefaults()
        t.expect(!AppSettings(defaults: FileDefaults.file(file)).showHeadlessSessions, "reset reaches the file too")
    }

    t.test("in-memory preferences write no file") {
        let settings = AppSettings(defaults: FileDefaults.inMemory())
        settings.theme = .mono
        t.expectEqual(settings.theme, .mono)
    }
}

// MARK: - 2. The router

private func routerTests(_ t: TestRunner) {
    t.test("a whole Claude Code turn from captured payloads moves the session through its states") {
        let w = Wiring()
        w.send("claude", "claude/hooks/SessionStart.startup.headless.json")
        t.expectEqual(w.only?.state, .idle)
        t.expectEqual(w.only?.title, "demo", "until a prompt arrives the title is the folder name")
        t.expectEqual(w.only?.agent, .claude)

        w.send("claude", "claude/hooks/UserPromptSubmit.json")
        t.expectEqual(w.only?.state, .working)
        t.expect(w.only?.title.hasPrefix("Do exactly two tool calls") == true, "the first prompt becomes the title")
        t.expectEqual(w.only?.turnCount, 1)

        w.send("claude", "claude/hooks/PreToolUse.Bash.json")
        t.expectEqual(w.only?.state, .runningTool)
        t.expectEqual(w.only?.currentTool?.name, "Bash")
        w.send("claude", "claude/hooks/PostToolUse.Bash.json")
        t.expectEqual(w.only?.state, .working)
        t.expectNil(w.only?.currentTool)

        w.send("claude", "claude/hooks/PreToolUse.Read.json")
        t.expectEqual(w.only?.currentTool?.name, "Read")
        w.send("claude", "claude/hooks/PostToolUseFailure.Read.json")
        t.expectEqual(w.only?.state, .working)
        t.expectEqual(w.only?.toolCount, 2)
        t.expectEqual(w.only?.recentTools.last?.succeeded, false, "the failed Read is recorded as failed")

        w.send("claude", "claude/hooks/Stop.json")
        t.expectEqual(w.only?.state, .done)
        t.expectEqual(w.only?.lastMessage, "done")

        w.send("claude", "claude/hooks/SessionEnd.other.json")
        t.expectEqual(w.only?.state, .ended)
        t.expectEqual(w.router.counts.received, 8)
        t.expectEqual(w.router.counts.turnedAway, 0)
    }

    t.test("a waiting helper gets the adapter's encoding of the user's decision") {
        let w = Wiring()
        w.send("claude", "claude/hooks/PreToolUse.Write.json")
        let handle = try t.unwrap(w.send("claude", "claude/hooks/PermissionRequest.Write.json", wait: true))
        t.expectEqual(handle.replies.count, 0, "the helper is kept waiting")
        t.expectEqual(w.store.pending.count, 1)
        t.expectEqual(w.only?.state, .needsApproval)
        t.expectEqual(w.engine.waitingHelperCount, 1)

        let request = try t.unwrap(w.store.pending.first)
        w.engine.resolve(request.id, with: .allow)
        t.expectEqual(handle.replies.count, 1)
        let decision = JSONValue.parse(handle.replies.first?.stdout ?? "")?["hookSpecificOutput"]
        t.expectEqual(decision?["hookEventName"].stringValue, "PermissionRequest")
        t.expectEqual(decision?["decision"]["behavior"].stringValue, "allow")
        t.expectEqual(w.store.pending.count, 0)
        t.expectEqual(w.only?.state, .working)
    }

    t.test("a helper that goes away clears its request") {
        let w = Wiring()
        let handle = try t.unwrap(w.send("claude", "claude/hooks/PermissionRequest.Bash.session-suggestions.json", wait: true))
        t.expectEqual(w.store.pending.count, 1)
        handle.onDisconnect?()
        t.expectEqual(w.store.pending.count, 0)
        t.expectEqual(w.only?.state, .working)
        t.expectEqual(handle.replies.count, 0, "nothing is sent to a helper that has gone")
    }

    t.test("unknown agents, switched-off agents and unreadable payloads are answered at once with no opinion") {
        let w = Wiring()
        let unknown = FakeHandle()
        w.router.route(w.envelope("nosuchagent", fixture: "claude/hooks/PermissionRequest.Write.json", wait: true), unknown)
        t.expectEqual(unknown.replies, [.passthrough])

        w.settings.claudeEnabled = false
        let disabled = FakeHandle()
        w.router.route(w.envelope("claude", fixture: "claude/hooks/PermissionRequest.Write.json", wait: true), disabled)
        t.expectEqual(disabled.replies, [.passthrough])
        t.expectEqual(w.store.sessions.count, 0, "a switched-off agent gets no card")
        t.expectEqual(w.router.counts.turnedAway, 2)
        w.settings.claudeEnabled = true

        let garbage = FakeHandle()
        w.router.route(w.envelope("claude", payload: "this is not JSON", wait: true), garbage)
        t.expectEqual(garbage.replies, [.passthrough], "the engine lets go of a helper that came with nothing to decide")
        t.expectEqual(w.router.counts.withoutEvents, 1)

        // A hook that is not a request at all (a plain PreToolUse) must not keep a --wait helper either.
        let plain = FakeHandle()
        w.router.route(w.envelope("claude", fixture: "claude/hooks/PreToolUse.Bash.json", wait: true), plain)
        t.expectEqual(plain.replies, [.passthrough])
        t.expectEqual(w.engine.waitingHelperCount, 0)
    }

    t.test("the debug channel answers with the report and counts the query") {
        let w = Wiring()
        w.router.debugReport = { "{\"hello\":true}" }
        let handle = FakeHandle()
        w.router.route(w.envelope("perch", channel: EnvelopeRouter.debugChannel, wait: true), handle)
        t.expectEqual(handle.replies, [HookReply(stdout: "{\"hello\":true}", exitCode: 0)])
        t.expectEqual(w.router.counts.debugQueries, 1)
        t.expectEqual(w.router.counts.turnedAway, 0, "a debug query is not an unknown agent")
        // Without a waiting helper there is nobody to answer; it must simply do nothing.
        w.router.route(w.envelope("perch", channel: EnvelopeRouter.debugChannel), nil)
        t.expectEqual(w.store.sessions.count, 0)
    }

    t.test("events from watched files are dropped for switched-off agents") {
        let w = Wiring()
        let context = EventContext(receivedAt: Date())
        let event = NormalizedEvent(agent: .codex, sessionID: "watched-1", event: .sessionStarted(title: "From a file", model: nil, source: nil),
                                    context: context, rawEventName: "session_meta")
        w.settings.codexEnabled = false
        w.router.ingestWatched([event])
        t.expectEqual(w.store.sessions.count, 0)
        w.settings.codexEnabled = true
        w.router.ingestWatched([event])
        t.expectEqual(w.store.sessions.count, 1)
        t.expectEqual(w.router.counts.fromFileWatchers, 1)
    }

    t.test("Codex and Antigravity payloads go through their own adapters") {
        let w = Wiring()
        w.send("codex", "codex/hooks/SessionStart.startup.json")
        w.send("codex", "codex/hooks/UserPromptSubmit.json")
        let codex = try t.unwrap(w.store.sessions.first { $0.agent == .codex })
        t.expectEqual(codex.state, .working)
        let handle = try t.unwrap(w.send("codex", "codex/hooks/PermissionRequest.Bash.json", wait: true))
        let request = try t.unwrap(w.store.pending.first)
        t.expectEqual(request.agent, .codex)
        w.engine.resolve(request.id, with: .deny(message: nil))
        t.expectEqual(JSONValue.parse(handle.replies.first?.stdout ?? "")?["hookSpecificOutput"]["decision"]["behavior"].stringValue, "deny")

        w.router.route(w.envelope("antigravity", fixture: "antigravity/hooks/PreInvocation.first.synth.json", event: "PreInvocation"), nil)
        let antigravity = try t.unwrap(w.store.sessions.first { $0.agent == .antigravity })
        t.expect(antigravity.state.isBusy, "an Antigravity turn that has begun shows as busy (was \(antigravity.state.rawValue))")
    }
}

// MARK: - 3. Automatic answers, uninstall, diagnostics

private func supportTests(_ t: TestRunner) {
    t.test("automatic answers: what allow and deny mean for each kind of request") {
        t.expectEqual(AutoResolver.decision(for: .permission(SampleData.bashPermission), mode: .allow), .allow)
        t.expectEqual(AutoResolver.decision(for: .permission(SampleData.bashPermission), mode: .deny), .deny(message: AutoResolver.denyMessage))
        t.expectEqual(AutoResolver.decision(for: .question(SampleData.question), mode: .allow),
                      .answer(["Which framework should the dashboard use?": "React",
                               "Which features do you want in the first version?": "Live charts"]))
        t.expectEqual(AutoResolver.decision(for: .plan(SampleData.plan), mode: .allow), .approvePlan(acceptEdits: false))
        t.expectEqual(AutoResolver.decision(for: .plan(SampleData.plan), mode: .deny), .rejectPlan(feedback: AutoResolver.denyMessage))
    }

    t.test("automatic answers wait their delay and skip requests that have gone") {
        let store = SessionStore()
        var answered: [(PendingRequest, Decision)] = []
        let resolver = AutoResolver(mode: .allow, delay: 0.15, store: store) { request, decision in
            answered.append((request, decision))
            store.pending.removeAll { $0.id == request.id }
        }
        let staying = SampleData.pending[0], leaving = SampleData.editPending
        store.pending = [staying, leaving]
        t.expectEqual(answered.count, 0, "nothing is answered straight away")
        store.pending.removeAll { $0.id == leaving.id }   // its helper went away
        t.expect(t.wait(2) { !answered.isEmpty })
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        t.expectEqual(answered.map { $0.0.id }, [staying.id], "only the request that is still waiting is answered, once")
        t.expectEqual(resolver.answered, 1)
    }

    t.test("uninstall: hooks come out of a connected agent and the folder is emptied through the Trash") {
        let root = TestRunner.tempDir("perch-uninstall")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let settingsFile = config.appendingPathComponent("settings.json")
        let original = "{\n  \"permissions\": { \"allow\": [\"Bash(ls)\"] }\n}\n"
        try original.write(to: settingsFile, atomically: true, encoding: .utf8)
        let support = root.appendingPathComponent("support")
        let claude = ClaudeAdapter(configDir: config, helperURL: support.appendingPathComponent("bin/perch-hook"),
                                   backupsDir: support.appendingPathComponent("backups"),
                                   locator: ClaudeLocator(home: root, systemFolders: [], searchPath: nil))
        _ = try claude.installHooks()
        t.expect((try String(contentsOf: settingsFile, encoding: .utf8)).contains("perch-hook"), "connected first")
        t.expectEqual(claude.status().hookStatus == .notInstalled, false)

        let never = AntigravityAdapter(geminiDir: root.appendingPathComponent("gemini"), helperPath: "/nowhere/perch-hook",
                                       backupsDir: support.appendingPathComponent("backups"))
        let problems = Uninstaller.removeHooks(adapters: [claude, never])
        t.expectEqual(problems, [])
        t.expectEqual(try String(contentsOf: settingsFile, encoding: .utf8), original, "the settings file is exactly as it was")

        try "log".write(to: support.appendingPathComponent("perch.log"), atomically: true, encoding: .utf8)
        var trashed: [String] = []
        let leftovers = Uninstaller.emptyFolder(support) { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        t.expectEqual(leftovers, [])
        t.expect(trashed.contains("backups") && trashed.contains("perch.log"), "everything in the folder goes: \(trashed)")
        t.expectEqual((try? FileManager.default.contentsOfDirectory(atPath: support.path))?.count, 0)
        t.expectEqual(Uninstaller.emptyFolder(root.appendingPathComponent("missing")) { _ in }, [], "a folder that is not there is fine")
    }

    t.test("a PERCH_HOME run refuses to connect or disconnect an agent, whoever clicks") {
        // The real controller with the real Claude adapter. Its config folder is pointed at a
        // temporary one first, so that even a failure of this very check could not reach ~/.claude.
        let config = TestRunner.tempDir("perch-locked-claude")
        defer { try? FileManager.default.removeItem(at: config) }
        let file = config.appendingPathComponent("settings.json")
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        setenv("CLAUDE_CONFIG_DIR", config.path, 1)
        defer { unsetenv("CLAUDE_CONFIG_DIR") }

        let locked = AppController(options: LaunchOptions(arguments: [], environment: ["PERCH_HOME": "/tmp/perch-test", "PERCH_NO_LOGIN_ITEM": "1"]))
        locked.installHooks(for: .claude)
        t.expectEqual(locked.env.agents.lastMessage, LaunchOptions.agentSettingsLockedMessage)
        t.expectEqual(try String(contentsOf: file, encoding: .utf8), original, "Connect changed nothing")
        locked.uninstallHooks(for: .claude)
        t.expectEqual(try String(contentsOf: file, encoding: .utf8), original, "Disconnect changed nothing")

        // The same controller without PERCH_HOME does connect (still into the temporary folder),
        // which shows the check above was refused by the lock and not by something else.
        var normal = LaunchOptions()
        normal.skipLoginItem = true
        let open = AppController(options: normal)
        open.installHooks(for: .claude)
        t.expect((try String(contentsOf: file, encoding: .utf8)).contains("perch-hook"), "a normal launch connects")
        open.uninstallHooks(for: .claude)
        t.expect(!(try String(contentsOf: file, encoding: .utf8)).contains("perch-hook"), "and disconnects again")
    }

    t.test("diagnostics say where things are but repeat nothing from a conversation") {
        let sessions = SampleData.sessions
        let snapshot = AppSnapshot(version: "9.9.9", processID: 4321, launchedAt: Date().addingTimeInterval(-60), takenAt: Date(),
                                   options: LaunchOptions(), supportDir: "/Users/you/Library/Application Support/Perch",
                                   socketPath: "/Users/you/Library/Application Support/Perch/perch.sock", serverRunning: true,
                                   connections: 1, waitingHelpers: 1, helperInstalled: true, isDemo: false, isExpanded: false,
                                   sessions: sessions, engineSessionCount: sessions.count, pending: SampleData.pending,
                                   trackedRequestCount: 3, statuses: SampleData.agentStatuses, enabledAgents: AgentKind.allCases,
                                   counts: EnvelopeRouter.Counts(), activityCount: 5)
        let text = Diagnostics.text(snapshot, logTail: ["2026-10-12T08:00:00Z INFO [app] Perch 9.9.9 starting"])
        t.expect(text.contains("Perch 9.9.9") && text.contains("perch.sock") && text.contains("Claude Code"))
        t.expect(text.contains("Perch 9.9.9 starting"), "the end of the log is included")
        for session in sessions {
            t.expect(!text.contains(session.title), "no session title: \(session.title)")
            if let message = session.lastMessage { t.expect(!text.contains(message), "no agent message") }
        }
        t.expect(!text.contains("rm -rf"), "no command from a request")

        // The debug channel, by contrast, is meant to show titles (it only answers on Perch's own socket).
        let report = try t.unwrap(JSONValue.parse(DebugReport.json(snapshot)))
        t.expectEqual(report["sessions"].arrayValue?.count, sessions.count)
        t.expectEqual(report["sessions"][0]["title"].stringValue, sessions[0].title)
        t.expectEqual(report["sessions"][0]["state"].stringValue, "runningTool")
        t.expectEqual(report["pending"].arrayValue?.count, 3)
        t.expectEqual(report["pending"][0]["kind"].stringValue, "permission")
        t.expectEqual(report["pending"][1]["kind"].stringValue, "question")
        t.expectEqual(report["server"]["running"].boolValue, true)
        t.expect(report["app"]["autoResolve"].isNull, "automatic answers show as off")
        t.expectEqual(report["counts"]["needingAttention"].intValue, 3)
    }

    t.test("the end of the log is read without the rest") {
        let folder = TestRunner.tempDir("perch-logtail")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("perch.log")
        try (1...250).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let tail = Diagnostics.logTail(of: file)
        t.expectEqual(tail.count, 100)
        t.expectEqual(tail.first, "line 151")
        t.expectEqual(tail.last, "line 250")
        t.expectEqual(Diagnostics.logTail(of: folder.appendingPathComponent("none.log")), [])
    }
}

// MARK: - 4. Click tests

/// A view in a real window that is never visible (transparent and far off-screen), so mouse
/// clicks can be delivered to it. The real pointer and other apps are not involved.
@MainActor
private final class ClickWindow {
    private let host: NSHostingView<AnyView>
    private let window: NSWindow

    init<Content: View>(_ content: Content, env: AppEnv, size: CGSize) {
        host = NSHostingView(rootView: AnyView(content.frame(width: size.width, height: size.height, alignment: .topLeading)
            .perchEnvironment(env)))
        host.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        wait(0.3)
    }

    func close() { window.orderOut(nil) }

    func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Clicks at a point measured from the window's top-left corner.
    func click(x: CGFloat, y: CGFloat) {
        send(.leftMouseDown, x, y)
        wait(0.05)
        send(.leftMouseUp, x, y)
        wait(0.2)
    }

    private func send(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) {
        let location = NSPoint(x: x, y: host.bounds.height - y)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        window.sendEvent(event)
    }
}

/// The natural size of a view.
@MainActor
private func naturalSize<V: View>(_ view: V, env: AppEnv) -> CGSize {
    let host = NSHostingView(rootView: view.fixedSize().perchEnvironment(env))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
}

/// Three plain buttons in a row under a bare capsule outline, or under one that is excluded from
/// hit-testing. Used to record whether the two behave differently on this macOS.
private struct OutlinedRow: View {
    let swallowing: Bool
    @Binding var picked: Int

    var body: some View {
        let outline = Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Button { picked = index } label: {
                    Text("Choice \(index)").padding(.horizontal, 10).padding(.vertical, 4.5).contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(swallowing ? AnyView(outline) : AnyView(outline.allowsHitTesting(false)))
    }
}

private final class PickBox: ObservableObject { @Published var picked = -1 }

private struct OutlinedRowHost: View {
    let swallowing: Bool
    @ObservedObject var box: PickBox
    var body: some View { OutlinedRow(swallowing: swallowing, picked: $box.picked) }
}

@MainActor
private func clickTests(_ t: TestRunner) {
    let inset: CGFloat = 20

    /// Clicks along the horizontal centre line of a control placed at (inset, inset) and returns
    /// what `read` gives after each click.
    func sweep<V: View, Value>(_ view: V, env: AppEnv, read: () -> Value) -> [Value] {
        let size = naturalSize(view, env: env)
        let window = ClickWindow(view.fixedSize().padding(inset), env: env,
                                 size: CGSize(width: size.width + inset * 2, height: size.height + inset * 2))
        defer { window.close() }
        var seen: [Value] = []
        // The middle of each third of the control, exactly on its centre line.
        let fractions: [CGFloat] = [1.0 / 6.0, 3.0 / 6.0, 5.0 / 6.0]
        for fraction in fractions {
            window.click(x: inset + size.width * fraction, y: inset + size.height / 2)
            seen.append(read())
        }
        return seen
    }

    // Honest note about what the next three tests prove. The module authors reported that a
    // capsule outline laid over a row of buttons swallowed clicks, and asked for
    // `.allowsHitTesting(false)` on the outline. On macOS 26.6 that could NOT be reproduced with
    // clicks delivered this way: the bare outline lets every click through (the first test
    // prints what it saw). So the two tests after it show that the controls work now; they do
    // not show that the fix changed anything, and they passed just the same with it reverted.
    t.test("record: does a bare outline over buttons swallow centre-line clicks on this macOS?") {
        let env = SampleData.env(settings: memorySettings())
        let bare = PickBox()
        let bareSeen = sweep(OutlinedRowHost(swallowing: true, box: bare), env: env) { bare.picked }
        let fixed = PickBox()
        let fixedSeen = sweep(OutlinedRowHost(swallowing: false, box: fixed), env: env) { fixed.picked }
        t.expectEqual(fixedSeen, [0, 1, 2], "with allowsHitTesting(false) every button is reached")
        print("    note: with the bare outline the clicks reached \(bareSeen); [0, 1, 2] means the bug does not reproduce here")
    }

    t.test("the panel's tab bar takes clicks on its centre line") {
        let env = SampleData.env(settings: memorySettings())
        env.ui.panelTab = .activity
        let seen = sweep(PanelTabBar(), env: env) { env.ui.panelTab }
        t.expectEqual(seen, [.sessions, .usage, .activity])
    }

    t.test("the cards' segmented picker takes clicks on its centre line") {
        let env = SampleData.env(settings: memorySettings())
        let box = PickBox()
        let picker = SegmentedHost(box: box)
        let seen = sweep(picker, env: env) { box.picked }
        t.expectEqual(seen, [0, 1, 2])
    }
}

private struct SegmentedHost: View {
    @ObservedObject var box: PickBox
    var body: some View {
        CardsSegmentedPicker([.init(0, "First"), .init(1, "Second"), .init(2, "Third")], selection: $box.picked)
    }
}

// MARK: - The usage button in the open panel's top strip (click mode)

@MainActor
private func stripButtonTests(_ t: TestRunner) {
    t.test("the geometry rule: right of the notch means over the right-hand wing or beyond") {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // A 14-inch MacBook Pro: a 185-point notch in the middle of a 32-point strip.
        let info = ScreenInfo(id: 1, frame: screen, visibleFrame: screen, safeAreaTop: 32,
                              topLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                              topRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32), isBuiltin: true, hasMenuBar: true)
        let placement = IslandPlacement(screen: info, windowSize: IslandMetrics.windowSize)
        let wing: CGFloat = 84
        let pillWidth = 185 + wing * 2
        let pillRect = CGRect(x: (IslandMetrics.windowSize.width - pillWidth) / 2, y: 0, width: pillWidth, height: 32)
        let zones = IslandZones(placement: placement, pillRect: pillRect, islandRect: pillRect)
        let y = zones.pill.midY
        t.expect(!zones.isRightOfNotch(CGPoint(x: zones.pill.minX + 10, y: y), wing: wing), "left wing")
        t.expect(!zones.isRightOfNotch(CGPoint(x: zones.pill.midX, y: y), wing: wing), "the notch itself")
        t.expect(zones.isRightOfNotch(CGPoint(x: zones.pill.maxX - 10, y: y), wing: wing), "right wing")
    }

    t.test("click mode: a click on the strip's usage button no longer closes the panel; elsewhere on the strip still does") {
        let env = SampleData.env(expanded: false, settings: memorySettings())
        env.settings.expandTrigger = .click
        env.settings.keepExpandedWhilePending = false
        env.sessions.pending = []
        env.ui.isDemo = false
        let controller = NotchWindowController(env: env, content: AnyView(IslandRootView().perchEnvironment(env)))
        var pointer = CGPoint(x: -5000, y: -5000)
        controller.pointerSource = PointerSource(location: { pointer }, pressedButtons: { 0 }, isMidInteraction: { false },
                                                 listensToSystemEvents: false)
        controller.show()
        defer { controller.hide() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let placement = controller.placement else {
            print("    note: no display to place the island on; this check was SKIPPED")
            return
        }
        let wing = IslandMetrics.wing(env.settings)
        func pillRect() -> CGRect {
            let size = IslandMetrics.pillSize(ui: env.ui, settings: env.settings)
            let inWindow = CGRect(x: (IslandMetrics.windowSize.width - size.width) / 2, y: 0, width: size.width, height: size.height)
            return placement.screenRect(fromWindowRect: inWindow)
        }
        func click(at point: CGPoint) -> Bool {
            pointer = point
            controller.pointerDidMove()
            let consumed = controller.mouseDidGoDown(isPrimary: true, source: .local)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return consumed
        }
        func open() {
            env.ui.isExpanded = true
            RunLoop.main.run(until: Date().addingTimeInterval(ShellTuning.surpriseClickGuard + 0.3))
        }

        let pill = pillRect()
        let leftWing = CGPoint(x: pill.minX + wing / 2, y: pill.midY)
        let rightWing = CGPoint(x: pill.maxX - wing / 2, y: pill.midY)

        // The sample data has limit readings, so the strip shows its usage button on the right.
        t.expect(env.usage.usage.values.contains { !$0.windows.isEmpty }, "the sample data has limit readings")
        open()
        let consumedOnButton = click(at: rightWing)
        t.expect(env.ui.isExpanded, "the panel stays open when the usage button is clicked")
        t.expect(!consumedOnButton, "and the click is left for the button")

        let consumedOnLeft = click(at: leftWing)
        t.expect(!env.ui.isExpanded, "a click on the left of the strip still closes the panel")
        t.expect(consumedOnLeft, "and that click is used up")

        // With no limit readings nothing is drawn on the right, and the whole strip means "close".
        env.usage.usage = [:]
        open()
        _ = click(at: rightWing)
        t.expect(!env.ui.isExpanded, "with no readings the right-hand side closes the panel as before")

        // Hover mode never closed on a strip click; that must not have changed.
        env.settings.expandTrigger = .hover
        env.usage.usage = SampleData.usage
        open()
        _ = click(at: rightWing)
        _ = click(at: leftWing)
        t.expect(env.ui.isExpanded, "hover mode: clicks on the strip belong to the panel")
    }
}
