// CodexAdapter.swift — everything Perch knows about OpenAI's Codex CLI, behind the AgentAdapter protocol.
//
// How Perch works with Codex (docs/research/codex.md):
//   - Live events and approvals come through Codex's lifecycle hooks, installed into
//     `$CODEX_HOME/hooks.json` (CodexHooksInstaller). The user has to approve new hooks once
//     inside Codex before they run.
//   - Allow / Deny from the notch uses the documented PermissionRequest reply. There is no
//     "always allow", and questions and plans can be seen but not answered.
//   - Usage, rate limits and turns that ended with an error are read from the session files
//     Codex writes (CodexRolloutParser, followed by a SessionFileWatcher).
//
// Codex is not installed on the machine this was written on. Every format here follows the
// documentation and source of Codex 0.162.1; nothing was observed live.

import Foundation

final class CodexAdapter: AgentAdapter {
    let kind = AgentKind.codex

    /// What the research confirms for Codex. Questions and plan review stay in the terminal.
    let capabilities = AgentCapabilities(liveEvents: true, approvals: true, questions: false, planReview: false, usage: true, jump: true)

    private let paths: CodexPaths
    private let installer: CodexHooksInstaller
    private let config: CodexConfig
    private let watcherTuning: SessionFileWatcher.Tuning
    private let watcherQueue = DispatchQueue(label: "local.perch.codex.rollouts", qos: .utility)
    private var watcher: SessionFileWatcher?
    /// Parsers by file path. Touched only on `watcherQueue`.
    private var parsers: [String: CodexRolloutParser] = [:]
    /// Sessions Perch has heard from through hooks. Touched only on the main thread.
    private var sessionsSeenThroughHooks: Set<String> = []

    /// The legacy `notify` program, an optional extra that `installHooks()` does not use.
    let notifyInstaller: CodexNotifyInstaller

    convenience init() {
        let environment = AdapterEnvironment.live
        self.init(paths: CodexPaths(environment: environment), helperPath: environment.helperPath, backupsDir: environment.backupsDir)
    }

    /// For tests: a Codex home in a temporary folder, and nothing looked up on the real system.
    convenience init(codexHome: URL, helperPath: String, backupsDir: URL, binaryCandidates: [String] = [],
                     watcherTuning: SessionFileWatcher.Tuning = SessionFileWatcher.Tuning()) {
        self.init(paths: CodexPaths(home: codexHome, binaryCandidates: binaryCandidates), helperPath: helperPath,
                  backupsDir: backupsDir, watcherTuning: watcherTuning)
    }

    private init(paths: CodexPaths, helperPath: String, backupsDir: URL,
                 watcherTuning: SessionFileWatcher.Tuning = SessionFileWatcher.Tuning()) {
        self.paths = paths
        self.watcherTuning = watcherTuning
        installer = CodexHooksInstaller(hooksFile: paths.hooksFile, helperPath: helperPath, backupsDir: backupsDir)
        config = CodexConfig(configFile: paths.configFile)
        notifyInstaller = CodexNotifyInstaller(configFile: paths.configFile, helperPath: helperPath, backupsDir: backupsDir)
    }

    // MARK: Status

    static let limitsSentence = "Questions and plans can be seen but must be answered in the terminal, and Codex has no \"always allow\" for other apps."

    func status() -> AgentStatus {
        func make(_ hookStatus: HookStatus, _ detail: String, detected: Bool = true) -> AgentStatus {
            AgentStatus(agent: .codex, detected: detected, version: detected ? paths.versionFromRecentSession() : nil,
                        configPath: detected ? paths.hooksFile.path : nil, hookStatus: hookStatus,
                        capabilities: capabilities, detail: detail)
        }
        guard paths.isDetected else {
            return make(.notDetected, "Codex was not found on this Mac.", detected: false)
        }
        switch installer.inspect() {
        case .unreadable(let reason):
            return make(.error, "Perch cannot read Codex's hooks file (\(reason)), so it will not change it.")
        case .noFile, .notInstalled:
            return make(.notInstalled, "Codex is installed but Perch's hooks are not. Without them Perch can only show sessions and usage read from Codex's session files. "
                        + CodexAdapter.limitsSentence)
        case .needsUpdate(let missing, let stale):
            let what = stale.isEmpty ? "\(missing.count) events are missing" : "some entries point at an older copy of Perch"
            return make(.needsUpdate, "Perch's Codex hooks need an update (\(what)). Install again, then approve the hooks in Codex.")
        case .installed:
            if config.hooksDisabled {
                return make(.installed, "Perch's hooks are installed, but hooks are switched off in Codex's config.toml ([features] hooks = false), so only sessions and usage from files are shown.")
            }
            let trust = config.trust(forKeySuffixes: installer.trustKeySuffixes())
            if trust.trusted == 0 {
                return make(.installed, "Perch's hooks are installed. If sessions do not appear live, open Codex and choose \"Trust all and continue\" (or run /hooks): Codex ignores hooks until you approve them. "
                            + CodexAdapter.limitsSentence)
            }
            return make(.installed, "Sessions, usage and Allow / Deny from the notch work. " + CodexAdapter.limitsSentence)
        }
    }

    // MARK: Install / uninstall

    func installHooks() throws -> String {
        guard paths.isDetected else { throw AdapterConfigError.agentNotDetected("Codex") }
        return try installer.install()
    }

    func uninstallHooks() throws -> String {
        var summary = try installer.uninstall()
        // The optional notify program is Perch's too; "remove only what Perch added" includes it.
        if notifyInstaller.isInstalled { summary += " " + (try notifyInstaller.uninstall()) }
        return summary
    }

    // MARK: Events and decisions

    func normalize(_ envelope: HookEnvelope) -> [NormalizedEvent] {
        var events = CodexHookEvents.normalize(envelope)
        guard envelope.channel == "hook" else { return events }
        // Bounded: if it is ever cleared, the next hook event of each live session puts it back.
        if sessionsSeenThroughHooks.count > 1024 { sessionsSeenThroughHooks.removeAll() }
        for event in events { sessionsSeenThroughHooks.insert(event.sessionID) }

        // With Codex's shared background server, hooks are started by that server and not by the
        // Codex in the user's terminal. The pid, tty and terminal variables then describe the
        // server (or whichever terminal started it), so they are dropped rather than trusted.
        if envelope.pid > 0, envelope.pid == paths.daemonPid() {
            events = events.map { event in
                var copy = event
                copy.context.pid = nil
                copy.context.tty = nil
                copy.context.env = [:]
                return copy
            }
        }
        // A request Codex is going to review automatically is left to Codex: no card in the notch.
        // Returning no event tells the engine there is nothing to decide (it must then let the
        // waiting helper go, which makes Codex carry on with its own flow).
        if events.contains(where: { if case .permissionRequested = $0.event { return true } else { return false } }),
           CodexApprovalReviewer.usesAutomaticReview(transcriptPath: events.first?.context.transcriptPath, config: config) {
            return []
        }
        return events
    }

    func encode(_ decision: Decision, for request: PendingRequest) -> HookReply {
        CodexHookEvents.encode(decision, for: request)
    }

    // MARK: Session files

    func startMonitoring(emit: @escaping ([NormalizedEvent]) -> Void) {
        stopMonitoring()
        let paths = self.paths
        let watcher = SessionFileWatcher(tuning: watcherTuning, queue: watcherQueue,
                                         listFiles: { paths.recentRolloutFiles() },
                                         onChange: { [weak self] change in self?.handle(change, emit: emit) })
        self.watcher = watcher
        watcher.start()
    }

    func stopMonitoring() {
        watcher?.stop()
        watcher = nil
        watcherQueue.async { [weak self] in self?.parsers.removeAll() }
    }

    /// A session file counts as "live" when it was written to this recently before Perch noticed it.
    static let recentlyActiveWindow: TimeInterval = 10 * 60

    /// Runs on `watcherQueue`.
    private func handle(_ change: SessionFileWatcher.Change, emit: @escaping ([NormalizedEvent]) -> Void) {
        var produced: [CodexRolloutEvent] = []
        switch change {
        case .discovered(let url, let existedAtStart, let modifiedAt):
            let parser = CodexRolloutParser(fileURL: url)
            parsers[url.path] = parser
            // A file that was already there is not replayed. Only its header and latest numbers are
            // read, and a card is shown only if it was active moments ago.
            if existedAtStart {
                let live = Date().timeIntervalSince(modifiedAt) <= CodexAdapter.recentlyActiveWindow
                produced = parser.prime(announce: live, threadNames: live ? threadNames() : [:])
            }
        case .lines(let url, let lines):
            guard let parser = parsers[url.path] else { return }
            produced = parser.parse(lines: lines)
        case .dropped(let url):
            parsers[url.path] = nil
        }
        guard !produced.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let events = produced.filter { $0.neededEvenWithHooks || !self.sessionsSeenThroughHooks.contains($0.event.sessionID) }
                .map(\.event)
            if !events.isEmpty { emit(events) }
        }
    }

    /// Thread names Codex recorded (`session_index.jsonl`), newest entry per session winning.
    private func threadNames() -> [String: String] {
        var names: [String: String] = [:]
        for line in JSONLinesTailer.tailLines(of: paths.sessionIndexFile, maxBytes: 128 * 1024) {
            guard let entry = JSONValue.parse(line), let id = entry["id"].stringValue,
                  let name = EnvelopeReading.nonEmpty(entry["thread_name"].stringValue) else { continue }
            names[id] = name
        }
        return names
    }
}
