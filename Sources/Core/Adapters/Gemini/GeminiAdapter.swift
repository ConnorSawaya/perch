// GeminiAdapter.swift — everything Perch knows about Google's Gemini CLI, behind the AgentAdapter protocol.
//
// What works (docs/research/antigravity.md §10): sessions, prompts, finished tools and turn ends
// through hooks in `~/.gemini/settings.json`, and an exact "Gemini is asking for confirmation"
// signal. What does not: answering that confirmation. Gemini CLI offers no way for another app to
// approve a tool, so the notch shows the request and the answer is given in the terminal.
//
// Gemini CLI is not installed on the machine this was written on; formats follow its documentation
// and source (v0.63 / main) and were not observed live.

import Foundation

final class GeminiAdapter: AgentAdapter {
    let kind = AgentKind.gemini

    /// Hooks give live events and a terminal to jump to. Nothing can be answered from outside, and
    /// limits need credentials Perch never touches.
    let capabilities = AgentCapabilities(liveEvents: true, approvals: false, questions: false, planReview: false, usage: false, jump: true)

    /// `~/.gemini` (or `$GEMINI_CLI_HOME/.gemini`).
    private let geminiDir: URL
    private let binaryCandidates: [String]
    private let installer: GeminiHooksInstaller
    private let toolMemory = ToolStartMemory()
    private let watcherTuning: SessionFileWatcher.Tuning
    private let watcherQueue = DispatchQueue(label: "local.perch.gemini.sessions", qos: .utility)
    private var watcher: SessionFileWatcher?
    private var parsers: [String: GeminiSessionParser] = [:]          // watcherQueue only
    /// Session files learned from hooks (path → session id). Shared between threads, hence the lock.
    private var sessionFiles: [String: String] = [:]
    private let sessionFilesLock = NSLock()

    convenience init() {
        let environment = AdapterEnvironment.live
        var dir = environment.home.appendingPathComponent(".gemini", isDirectory: true)
        // GEMINI_CLI_HOME replaces the home folder for Gemini CLI.
        if let override = environment.variables["GEMINI_CLI_HOME"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent(".gemini", isDirectory: true)
        }
        let home = environment.home
        self.init(geminiDir: dir, helperPath: environment.helperPath, backupsDir: environment.backupsDir,
                  binaryCandidates: ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", home.appendingPathComponent(".local/bin/gemini").path,
                                     home.appendingPathComponent(".volta/bin/gemini").path, home.appendingPathComponent(".bun/bin/gemini").path])
    }

    /// For tests (and the shared initialiser): explicit folders, nothing looked up on the real system.
    init(geminiDir: URL, helperPath: String, backupsDir: URL, binaryCandidates: [String] = [],
         watcherTuning: SessionFileWatcher.Tuning = SessionFileWatcher.Tuning()) {
        self.geminiDir = geminiDir
        self.binaryCandidates = binaryCandidates
        self.watcherTuning = watcherTuning
        installer = GeminiHooksInstaller(settingsFile: geminiDir.appendingPathComponent("settings.json"), helperPath: helperPath, backupsDir: backupsDir)
    }

    // MARK: Status

    /// `~/.gemini` alone proves nothing: Antigravity uses the same folder. Gemini CLI is present when
    /// its binary is found, or its settings file sits next to its `tmp` folder.
    var isDetected: Bool {
        let fm = FileManager.default
        if binaryCandidates.contains(where: { fm.isExecutableFile(atPath: $0) }) { return true }
        return fm.fileExists(atPath: installer.settingsFile.path) && fm.fileExists(atPath: geminiDir.appendingPathComponent("tmp").path)
    }

    static let limitsSentence = "Gemini CLI gives other apps no way to approve tools or answer questions, so those stay in the terminal, and its limits are not available without your Google login."

    func status() -> AgentStatus {
        func make(_ hookStatus: HookStatus, _ detail: String, detected: Bool = true) -> AgentStatus {
            AgentStatus(agent: .gemini, detected: detected, version: nil, configPath: detected ? installer.settingsFile.path : nil,
                        hookStatus: hookStatus, capabilities: capabilities, detail: detail)
        }
        guard isDetected else { return make(.notDetected, "Gemini CLI was not found on this Mac.", detected: false) }
        let inspection = installer.inspect()
        switch inspection.state {
        case .unreadable(let reason):
            return make(.error, "Perch cannot safely edit Gemini CLI's settings (\(reason)), so it will not change them.")
        case .noFile, .notInstalled:
            return make(.notInstalled, "Gemini CLI is installed but Perch's hooks are not, so its sessions are not shown. " + GeminiAdapter.limitsSentence)
        case .needsUpdate:
            return make(.needsUpdate, "Perch's Gemini CLI hooks are incomplete or point at an older copy of Perch. Install again to repair them.")
        case .installed:
            if inspection.disabledByUser {
                return make(.installed, "Perch's hooks are installed, but hooks are switched off in Gemini CLI's settings (hooksConfig), so nothing is shown.")
            }
            return make(.installed, "Sessions are shown live, including when Gemini CLI is waiting for your confirmation. " + GeminiAdapter.limitsSentence)
        }
    }

    // MARK: Install / uninstall

    func installHooks() throws -> String {
        guard isDetected else { throw AdapterConfigError.agentNotDetected("Gemini CLI") }
        return try installer.install()
    }

    func uninstallHooks() throws -> String {
        try installer.uninstall()
    }

    // MARK: Events and decisions

    func normalize(_ envelope: HookEnvelope) -> [NormalizedEvent] {
        let events = GeminiHookEvents.normalize(envelope, toolMemory: toolMemory)
        if let first = events.first, let path = first.context.transcriptPath {
            sessionFilesLock.lock()
            let isNew = sessionFiles[path] == nil
            if sessionFiles.count > 64 { sessionFiles.removeAll() }
            sessionFiles[path] = first.sessionID
            sessionFilesLock.unlock()
            if isNew { watcher?.pollSoon() }
        }
        return events
    }

    /// Gemini CLI has no decision protocol for other apps: Perch always steps aside.
    func encode(_ decision: Decision, for request: PendingRequest) -> HookReply {
        .passthrough
    }

    // MARK: Session files

    /// Follows only the session files hooks have pointed at, so nothing is scanned (and nothing is
    /// read at all) until a Gemini CLI session with Perch's hooks is actually running.
    func startMonitoring(emit: @escaping ([NormalizedEvent]) -> Void) {
        stopMonitoring()
        var tuning = watcherTuning
        // A session file may hold old conversations (resumed sessions); only what is added from now on matters.
        tuning.readNewFilesFromStart = false
        let watcher = SessionFileWatcher(tuning: tuning, queue: watcherQueue, listFiles: { [weak self] in
            guard let self else { return nil }
            let known = self.knownSessionFiles()
            return known.isEmpty ? nil : known.keys.map { URL(fileURLWithPath: $0) }
        }, onChange: { [weak self] change in
            guard let self else { return }
            switch change {
            case .discovered(let url, _, _):
                self.parsers[url.path] = GeminiSessionParser(fileURL: url, sessionID: self.knownSessionFiles()[url.path])
            case .lines(let url, let lines):
                guard let events = self.parsers[url.path]?.parse(lines: lines), !events.isEmpty else { return }
                DispatchQueue.main.async { emit(events) }
            case .dropped(let url):
                self.parsers[url.path] = nil
                self.sessionFilesLock.lock()
                self.sessionFiles[url.path] = nil
                self.sessionFilesLock.unlock()
            }
        })
        self.watcher = watcher
        watcher.start()
    }

    func stopMonitoring() {
        watcher?.stop()
        watcher = nil
        watcherQueue.async { [weak self] in self?.parsers.removeAll() }
    }

    private func knownSessionFiles() -> [String: String] {
        sessionFilesLock.lock()
        defer { sessionFilesLock.unlock() }
        return sessionFiles
    }
}
