// AppController.swift — builds every part of Perch and connects them to each other.
//
// Nothing in this file knows how any part works inside; it only knows who needs whom:
//
//   coding agent ─► perch-hook ─► HookServer ─► EnvelopeRouter ─► AgentAdapter ─► SessionEngine
//                                                                                     │
//        notch window, menu-bar icon, Settings window  ◄── stores (AppEnv) ◄──────────┘
//                       │
//                       └─► AppActions (AppController+Actions.swift) ─► engine, adapters, usage, …
//
// What happens at launch (applicationDidFinishLaunching), in order:
//   1. start the socket server — if another Perch already owns the socket, quit quietly;
//   2. copy the hook helper to its fixed place (PerchPaths.helperURL);
//   3. start the engine, the usage scanner and the adapters' file watchers;
//   4. put the island, the menu-bar icon and the keyboard shortcuts on screen;
//   5. look for installed agents; on the very first run, open Settings (the welcome shows).
// Quitting undoes it in reverse and lets every waiting helper go, so no agent is left hanging.
//
// The AppActions methods (what buttons do) are in AppController+Actions.swift.
// Main thread only.

import AppKit
import SwiftUI
import Combine

final class AppController: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    let env: AppEnv
    let launchedAt = Date()

    // The working parts (ARCHITECTURE.md §2 fixes these names).
    let server: HookServer
    let adapters: [AgentKind: AgentAdapter]
    let usage: UsageEngine
    let jumper: TerminalJumper
    let sounds: SoundEngine
    let notifier: SystemNotifier
    let engine: SessionEngine
    let router: EnvelopeRouter
    let demo: DemoDirector
    let toast = ToastPresenter()

    // What is on screen. Built once the app has finished launching.
    private(set) var notchWindow: NotchWindowController?
    private(set) var settingsWindow: SettingsWindowController?
    private var statusItem: StatusItemController?
    private var shortcuts: ShortcutMonitor?

    private var autoResolver: AutoResolver?
    /// Keeps "open at login" in step with its setting for as long as it is held.
    private var loginItemFollower: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []
    /// Agents whose session files are being watched right now.
    private var monitoredAgents: Set<AgentKind> = []
    private(set) var isShutDown = false

    init(options: LaunchOptions = .current) {
        self.options = options
        let settings = AppSettings(defaults: FileDefaults.forLaunch(options))
        Log.debugEnabled = settings.debugLogging
        env = AppEnv(settings: settings)

        server = HookServer()
        // Created this early on purpose: macOS only hands over the click on a notification that
        // opened the app if the handler already exists.
        notifier = SystemNotifier(settings: settings)
        adapters = [.claude: ClaudeAdapter(), .codex: CodexAdapter(), .antigravity: AntigravityAdapter(), .gemini: GeminiAdapter()]
        usage = UsageEngine(store: env.usage, settings: settings)
        jumper = TerminalJumper()
        sounds = SoundEngine(settings: settings)
        engine = SessionEngine(store: env.sessions, settings: settings, adapters: adapters, sounds: sounds, jumper: jumper,
                               usage: usage, notifier: notifier)
        router = EnvelopeRouter(adapters: adapters, settings: settings, engine: engine)
        demo = DemoDirector(env: env)
        super.init()
        env.actions = self
    }

    /// The adapters in the order agents are listed everywhere.
    var orderedAdapters: [AgentAdapter] { AgentKind.allCases.compactMap { adapters[$0] } }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Perch \(Self.appVersion) starting (process \(ProcessInfo.processInfo.processIdentifier), files in \(PerchPaths.supportDir.path))")
        guard startServer() else {
            // Another Perch is already running and serving the agents. Leave everything to it.
            Self.letTheLogFinish()
            exit(0)
        }
        installHelper()
        connectParts()
        engine.start()
        usage.start()
        buildInterface()
        watchSettings()
        watchForSignals()
        refreshAgents()

        if let mode = options.autoResolve {
            Log.info("TEST MODE: every request is answered automatically with \"\(mode.rawValue)\" after \(options.autoResolveDelay) s")
            autoResolver = AutoResolver(mode: mode, delay: options.autoResolveDelay, store: env.sessions) { [weak self] request, decision in
                self?.resolve(request, decision)
            }
        }
        if options.startInDemo { setDemo(true) }
        if !env.settings.hasCompletedOnboarding { openSettings(nil) }
    }

    /// Starts listening for hook helpers. Returns false only when another Perch already is; any
    /// other failure is logged and shown in Settings → Agents, and the app carries on without events.
    private func startServer() -> Bool {
        // Set before `start()`, as the server asks. Messages are delivered on the main thread, so
        // none can arrive before the rest of launch has finished.
        server.onEnvelope = { [weak self] envelope, handle in
            guard let self, !self.isShutDown else {
                handle?.reply(.passthrough)
                return
            }
            self.router.route(envelope, handle)
        }
        do {
            try server.start()
        } catch HookServerError.alreadyRunning {
            Log.info("another Perch is already running; this one is quitting")
            return false
        } catch {
            Log.error("could not start listening for agents: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
        env.agents.serverRunning = server.isRunning
        return true
    }

    /// Puts the hook helper at the fixed path agents' settings point to.
    func installHelper() {
        do {
            try HelperInstaller.install(from: HelperInstaller.bundledHelperURL)
        } catch {
            Log.error("could not install the hook helper: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
        env.agents.helperInstalled = HelperInstaller.isInstalled
    }

    /// The connections between parts that are not already made through their initialisers.
    private func connectParts() {
        router.debugReport = { [weak self] in self.map { DebugReport.json($0.snapshot()) } ?? "{}" }
        demo.onCue = { [weak self] cue in self?.sounds.play(cue) }
        notifier.onOpenSession = { [weak self] sessionID in
            guard let self, let session = self.env.sessions.session(id: sessionID) else { return }
            self.jump(to: session)
        }
        usage.onLimitWarning = { [weak self] agent, window in self?.warnAboutLimit(agent, window) }
        env.sessions.$pulse.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] pulse in self?.react(to: pulse) }
            .store(in: &subscriptions)
    }

    private func buildInterface() {
        let notch = NotchWindowController(env: env, content: AnyView(IslandRootView().perchEnvironment(env)))
        notchWindow = notch
        settingsWindow = SettingsWindowController(env: env, content: AnyView(SettingsRootView().perchEnvironment(env)))
        statusItem = StatusItemController(env: env)
        let shortcuts = ShortcutMonitor(env: env)
        shortcuts.start()
        self.shortcuts = shortcuts
        notch.show()
    }

    // MARK: - Reacting to settings and events

    private func watchSettings() {
        let settings = env.settings
        settings.$debugLogging.removeDuplicates()
            .sink { Log.debugEnabled = $0 }
            .store(in: &subscriptions)

        // An agent's files are only watched while that agent is switched on. (@Published reports a
        // change just before it happens, so the new values are taken from the publisher itself.)
        Publishers.CombineLatest4(settings.$claudeEnabled, settings.$codexEnabled, settings.$antigravityEnabled, settings.$geminiEnabled)
            .sink { [weak self] claude, codex, antigravity, gemini in
                let enabled: [AgentKind: Bool] = [.claude: claude, .codex: codex, .antigravity: antigravity, .gemini: gemini]
                self?.updateMonitoring(enabled: Set(enabled.filter(\.value).keys))
            }
            .store(in: &subscriptions)

        if options.skipLoginItem {
            Log.info("login item handling is switched off for this run (PERCH_NO_LOGIN_ITEM)")
        } else {
            loginItemFollower = LoginItem.follow(settings)
        }
    }

    private func updateMonitoring(enabled: Set<AgentKind>) {
        guard !isShutDown else { return }
        for adapter in orderedAdapters {
            let kind = adapter.kind
            if enabled.contains(kind), !monitoredAgents.contains(kind) {
                monitoredAgents.insert(kind)
                adapter.startMonitoring { [weak self] events in self?.router.ingestWatched(events) }
            } else if !enabled.contains(kind), monitoredAgents.contains(kind) {
                monitoredAgents.remove(kind)
                adapter.stopMonitoring()
            }
        }
    }

    /// Opens the panel by itself when something happens that the user asked to be shown.
    private func react(to pulse: Pulse) {
        let settings = env.settings
        let wanted: Bool
        switch pulse.kind {
        case .attention: wanted = settings.autoExpandOnAttention
        case .done, .failed: wanted = settings.autoExpandOnDone
        case .approved, .denied, .started: wanted = false
        }
        guard wanted, !env.ui.isExpanded else { return }
        // The session list is where the request card or the result is.
        env.ui.panelTab = .sessions
        setExpanded(true)
    }

    private func warnAboutLimit(_ agent: AgentKind, _ window: RateWindow) {
        let message = "\(agent.displayName): \(window.label) is at \(Int(window.usedPercent.rounded()))%."
        Log.info("usage warning: \(message)")
        sounds.play(.reminder)
        notifier.notify(title: "Usage limit warning", body: message, sessionID: nil)
        showToast(message, systemImage: "gauge.with.dots.needle.67percent", isProblem: true)
    }

    // MARK: - Small helpers shared with the actions

    /// Shows a short message under the island.
    func showToast(_ message: String, systemImage: String, isProblem: Bool) {
        var anchor: CGRect?
        if let panel = notchWindow?.panel, panel.isVisible {
            let island = IslandMetrics.islandSize(ui: env.ui, settings: env.settings)
            anchor = CGRect(x: panel.frame.midX - island.width / 2, y: panel.frame.maxY - island.height,
                            width: island.width, height: island.height)
        }
        toast.show(message, systemImage: systemImage, isProblem: isProblem, settings: env.settings, under: anchor)
    }

    /// Adds a line to the activity log (the Activity tab), if the log is switched on.
    func note(_ event: String, _ summary: String, agent: AgentKind? = nil, sessionID: String? = nil) {
        guard env.settings.activityLogEnabled else { return }
        var activity = env.sessions.activity
        activity.insert(ActivityEntry(at: Date(), direction: .note, agent: agent?.rawValue ?? "perch", event: event,
                                      sessionID: sessionID, summary: summary, raw: ""), at: 0)
        if activity.count > 300 { activity.removeLast(activity.count - 300) }
        env.sessions.activity = activity
    }

    /// Everything the debug channel and "Copy diagnostics" report.
    func snapshot() -> AppSnapshot {
        AppSnapshot(version: Self.appVersion, processID: ProcessInfo.processInfo.processIdentifier, launchedAt: launchedAt,
                    takenAt: Date(), options: options, supportDir: PerchPaths.supportDir.path,
                    socketPath: PerchPaths.socketURL.path, serverRunning: server.isRunning,
                    connections: server.connectionCount, waitingHelpers: engine.waitingHelperCount,
                    helperInstalled: HelperInstaller.isInstalled, isDemo: env.ui.isDemo, isExpanded: env.ui.isExpanded,
                    sessions: env.sessions.sessions, engineSessionCount: engine.state.sessions.count,
                    pending: env.sessions.pending, trackedRequestCount: engine.state.requests.count,
                    statuses: env.agents.statuses, enabledAgents: AgentKind.allCases.filter { env.settings.isEnabled($0) },
                    counts: router.counts, activityCount: env.sessions.activity.count,
                    recentActivity: Array(env.sessions.activity.prefix(60)))
    }

    // MARK: - Quitting

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening Perch again while it is running (from Finder or Spotlight) shows Settings, since a
    /// menu-bar app has no other window to bring forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutDown()
        Self.letTheLogFinish()
    }

    /// Log lines are written a moment after they are asked for, on the log's own queue. Just
    /// before the process ends, wait that moment so the last lines are not lost.
    private static func letTheLogFinish() {
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Stops everything, in an order that leaves no helper waiting: the server first (which hangs
    /// up on every helper, so their agents fall back to their own prompts), then the engine, the
    /// usage scanner, the file watchers and demo mode. Safe to call twice.
    func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true
        subscriptions.removeAll()
        loginItemFollower = nil
        autoResolver = nil
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        shortcuts?.stop()
        toast.hide()
        server.stop()
        env.agents.serverRunning = false
        engine.stop()
        demo.stop()
        usage.stop()
        for adapter in orderedAdapters where monitoredAgents.contains(adapter.kind) { adapter.stopMonitoring() }
        monitoredAgents.removeAll()
        notchWindow?.hide()
        Log.info("Perch stopped")
    }

    /// `kill <pid>` and Ctrl-C quit Perch the same tidy way as the Quit command, so the socket
    /// file is removed and waiting helpers are let go.
    private func watchForSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
