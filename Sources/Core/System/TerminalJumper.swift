// TerminalJumper.swift — "take me to that session": brings the right terminal tab to the front.
//
// How a jump works:
//   1. Sort the session into a kind of app (TerminalKind) and tidy its identifiers (JumpTarget).
//   2. If the session runs inside tmux, select its pane first and find out which terminal tab is
//      showing that tmux session.
//   3. Ask the terminal to select the tab, each in its own way: AppleScript for Terminal, iTerm2
//      and Ghostty; the control commands of kitty and WezTerm. Editors (VS Code and friends) are
//      asked to reopen the session's folder, which raises the window that has it. Everything
//      else is simply brought to the front.
//   4. Report honestly: `.focused` only when the exact tab was selected, `.activatedApp` when
//      only the app came forward, `.failed` with a plain-English reason otherwise.
//
// Scripts and tools can be slow (or wait on a permission question), so they run on a background
// queue while the main thread waits a bounded time. Bringing apps forward is AppKit work and
// stays on the main thread. `isFrontmost` lives in TerminalJumper+Frontmost.swift.

import Foundation

final class TerminalJumper: TerminalJumping {

    /// Time limits, in seconds. Tests shorten them.
    struct Timing {
        /// How long `jump` keeps the main thread waiting for scripts and tools.
        var jumpWait: TimeInterval = 2.5
        /// Hard limit for a jump script. Generous, because the first run may be waiting for the
        /// user to answer the system's "allow Perch to control …" question.
        var scriptTimeout: TimeInterval = 20
        /// Hard limit for one tmux / kitty / WezTerm command.
        var toolTimeout: TimeInterval = 3
        /// Hard limit for the "which tab is in front" script.
        var frontScriptTimeout: TimeInterval = 1.5
        /// See BriefCache: how long a "which tab is in front" answer is fresh / usable, and the
        /// longest `isFrontmost` may keep the main thread waiting.
        var frontFreshFor: TimeInterval = 1
        var frontUsableFor: TimeInterval = 4
        var frontWait: TimeInterval = 0.3
    }

    let system: TerminalSystem
    let timing: Timing
    let frontTabs: BriefCache<String, FrontTab>
    let tmuxPanes: BriefCache<String, PaneVisibility>
    private var hostCache: [Int32: (bundleID: String?, at: Date)] = [:]
    private let workQueue = DispatchQueue(label: "local.perch.jump", qos: .userInitiated, attributes: .concurrent)

    convenience init() {
        self.init(system: LiveTerminalSystem())
    }

    /// For tests: a fake `system` and short time limits.
    init(system: TerminalSystem, timing: Timing = Timing()) {
        self.system = system
        self.timing = timing
        frontTabs = BriefCache(freshFor: timing.frontFreshFor, usableFor: timing.frontUsableFor, waitLimit: timing.frontWait)
        tmuxPanes = BriefCache(freshFor: timing.frontFreshFor, usableFor: timing.frontUsableFor, waitLimit: timing.frontWait)
    }

    // MARK: Jump

    func jump(to session: Session) -> JumpResult {
        if session.isDemo { return .failed("This is a demo session, so there is no terminal to show.") }
        let target = resolveTarget(for: session)
        // Inside tmux the recorded app may be out of date (tmux can be re-attached from another
        // terminal), so the checks below wait until tmux has told us where it is showing.
        if target.tmuxPane == nil {
            guard let bundleID = target.bundleID else { return .failed(Self.unknownAppMessage) }
            guard system.runningApp(bundleID: bundleID) != nil else { return .failed(notOpenMessage(bundleID)) }
            guard needsTools(target) else { return raise(bundleID, folder: target.folder) }
        }
        // We are about to change what is in front, so earlier answers are out of date.
        frontTabs.removeAll()
        tmuxPanes.removeAll()

        guard let outcome = waitBriefly(timing.jumpWait, { self.runTools(for: target) }) else {
            let name = target.bundleID.map(appName) ?? "The terminal"
            return .failed("\(name) did not answer in time. If macOS is asking whether Perch may control it, choose Allow and try again.")
        }
        switch outcome {
        case .focused:
            return .focused
        case .tabSelected(let app):
            return system.activate(bundleID: app) ? .focused : .failed("Could not bring \(appName(app)) to the front.")
        case .appAlreadyForward:
            return .activatedApp
        case .appOnly(let app):
            return raise(app, folder: target.folder)
        case .denied(let app):
            _ = system.activate(bundleID: app)
            return .failed(Self.automationHelp(appName: appName(app)))
        case .noApp(let recorded):
            return .failed(recorded.map(notOpenMessage) ?? Self.unknownAppMessage)
        }
    }

    static let unknownAppMessage = "Perch could not tell which app this session is running in."

    private func notOpenMessage(_ bundleID: String) -> String {
        "\(appName(bundleID)) is not open any more."
    }

    /// What to tell the user when macOS will not let Perch script a terminal.
    static func automationHelp(appName: String) -> String {
        "Perch brought \(appName) forward but is not allowed to pick the tab. To allow it, open System Settings → Privacy & Security → Automation and turn on \(appName) under Perch."
    }

    // MARK: Working out the target

    /// The session's target, with the app corrected from the process tree when the recorded one
    /// is missing or not running (several editors share TERM_PROGRAM=vscode, for example).
    func resolveTarget(for session: Session) -> JumpTarget {
        var target = JumpTarget(session: session)
        let recordedAppIsRunning = target.bundleID.map { system.runningApp(bundleID: $0) != nil } ?? false
        if !recordedAppIsRunning, let pid = target.pid, let host = hostBundleID(of: pid) {
            target.setApp(bundleID: host)
        }
        return target
    }

    /// Process-tree lookups, remembered for a minute (a process does not move between apps).
    private func hostBundleID(of pid: Int32) -> String? {
        let now = Date()
        if let cached = hostCache[pid], now.timeIntervalSince(cached.at) < 60 { return cached.bundleID }
        if hostCache.count > 128 { hostCache.removeAll() }
        let found = system.hostBundleID(of: pid)
        hostCache[pid] = (found, now)
        return found
    }

    func appName(_ bundleID: String) -> String {
        TerminalKind.displayName(bundleID: bundleID) ?? system.runningApp(bundleID: bundleID)?.name ?? "The app"
    }

    // MARK: Main-thread part: bringing apps forward

    /// Brings the app forward without picking a tab. Editors get the folder reopened instead,
    /// which raises the window that already shows it.
    private func raise(_ bundleID: String, folder: String) -> JumpResult {
        if TerminalKind.classify(bundleID: bundleID) == .editor, !folder.isEmpty, system.isDirectory(folder),
           system.openFolder(folder, inApp: bundleID) {
            return .activatedApp
        }
        return system.activate(bundleID: bundleID) ? .activatedApp : .failed("Could not bring \(appName(bundleID)) to the front.")
    }

    // MARK: Background part: scripts and tools

    /// What the background work achieved, and what is left for the main thread to do.
    private enum ToolOutcome {
        /// The exact tab is in front. Nothing left to do.
        case focused
        /// The exact pane is selected; its app still has to be brought forward.
        case tabSelected(app: String)
        /// A tab was brought forward but we cannot be sure it is the right one.
        case appAlreadyForward
        /// The tab could not be picked; bring the app forward.
        case appOnly(app: String)
        /// macOS refused to let us script the app.
        case denied(app: String)
        /// No running app could be found for the session. `recorded` is the one we expected, if any.
        case noApp(recorded: String?)
    }

    /// True when there is something a script or tool could do for this target.
    private func needsTools(_ target: JumpTarget) -> Bool {
        if target.tmuxPane != nil { return true }
        switch target.kind {
        case .appleTerminal: return target.tty != nil
        case .iTerm: return target.iTermSessionGUID != nil || target.tty != nil
        case .ghostty: return !target.folder.isEmpty
        case .kitty: return target.kittyWindowID != nil
        case .wezTerm: return target.weztermPane != nil || target.tty != nil
        case .warp, .editor, .claudeDesktop, .otherApp, .unknown: return false
        }
    }

    private func runTools(for original: JumpTarget) -> ToolOutcome {
        var target = original

        if let pane = target.tmuxPane {
            // Identifiers inherited from the terminal date from when the tmux server started and
            // may point at a tab that no longer shows this session, so they are not used. The
            // session's own TTY is tmux's inner one, which no terminal tab will ever report.
            target.iTermSessionGUID = nil
            target.kittyWindowID = nil
            target.weztermPane = nil
            target.tty = nil
            if let client = selectTmuxPane(pane, sessionPID: target.pid) {
                target.tty = client.tty
                // The terminal showing tmux now may not be the one tmux was started from.
                if let pid = client.pid, let host = system.hostBundleID(of: pid) { target.setApp(bundleID: host) }
            }
        }

        guard let app = target.bundleID, system.runningApp(bundleID: app) != nil else { return .noApp(recorded: target.bundleID) }
        // tmux could not tell us which terminal tab shows the session: only the app can be raised.
        if target.tmuxPane != nil, target.tty == nil { return .appOnly(app: app) }

        switch target.kind {
        case .appleTerminal:
            guard let tty = target.tty else { return .appOnly(app: app) }
            return scriptOutcome(TerminalScripts.terminalJump(tty: tty, bundleID: app), app: app)
        case .iTerm:
            guard target.iTermSessionGUID != nil || target.tty != nil else { return .appOnly(app: app) }
            return scriptOutcome(TerminalScripts.iTermJump(sessionGUID: target.iTermSessionGUID, tty: target.tty, bundleID: app), app: app)
        case .ghostty:
            // Inside tmux the folder Ghostty knows is the one tmux was attached from, not the session's.
            guard target.tmuxPane == nil, !target.folder.isEmpty else { return .appOnly(app: app) }
            return scriptOutcome(TerminalScripts.ghosttyJump(folder: target.folder, bundleID: app), app: app)
        case .kitty:
            guard let window = target.kittyWindowID, focusKittyWindow(window, app: app) else { return .appOnly(app: app) }
            return .tabSelected(app: app)
        case .wezTerm:
            return focusWezTermPane(paneID: target.weztermPane, tty: target.tty, app: app) ? .tabSelected(app: app) : .appOnly(app: app)
        case .warp, .editor, .claudeDesktop, .otherApp, .unknown:
            return .appOnly(app: app)
        }
    }

    private func scriptOutcome(_ source: String, app: String) -> ToolOutcome {
        switch system.runAppleScript(source, timeout: timing.scriptTimeout) {
        case .output(TerminalScripts.Answer.focused):
            return .focused
        case .output(TerminalScripts.Answer.ambiguous):
            return .appAlreadyForward
        case .permissionDenied:
            return .denied(app: app)
        case .output, .timedOut:
            return .appOnly(app: app)
        case .failed(let message):
            Log.debug("Jump script for \(app) failed: \(message)", "system")
            return .appOnly(app: app)
        }
    }

    // MARK: tmux

    /// The tmux program to talk to: the one the session is running under, else a usual install.
    func tmuxPath(sessionPID: Int32?) -> String? {
        if let pid = sessionPID, let running = system.ancestorExecutable(named: "tmux", of: pid) { return running }
        return system.firstExecutable(TmuxCommands.usualPaths)
    }

    /// Selects the pane and returns the terminal that is (now) showing its tmux session.
    /// Nil when tmux could not be reached or no terminal is attached at all.
    private func selectTmuxPane(_ pane: String, sessionPID: Int32?) -> TmuxClient? {
        guard let tmux = tmuxPath(sessionPID: sessionPID) else { return nil }
        let described = system.runTool(tmux, TmuxCommands.describePane(pane), timeout: timing.toolTimeout)
        guard described.succeeded, let state = TmuxCommands.parsePaneState(described.stdout),
              system.runTool(tmux, TmuxCommands.selectPane(pane), timeout: timing.toolTimeout).succeeded else { return nil }

        let attached = system.runTool(tmux, TmuxCommands.listClients(session: state.sessionID), timeout: timing.toolTimeout)
        if attached.succeeded, let client = TmuxCommands.parseClients(attached.stdout).first { return client }

        // Nobody is looking at that tmux session. If a terminal is attached to a different one,
        // point the most recently used terminal at ours.
        let everyone = system.runTool(tmux, TmuxCommands.listClients(session: nil), timeout: timing.toolTimeout)
        guard everyone.succeeded, let client = TmuxCommands.parseClients(everyone.stdout).first,
              system.runTool(tmux, TmuxCommands.switchClient(tty: client.tty, toPane: pane), timeout: timing.toolTimeout).succeeded
        else { return nil }
        return client
    }

    // MARK: kitty and WezTerm

    private func focusKittyWindow(_ windowID: String, app: String) -> Bool {
        let running = system.runningApp(bundleID: app)
        guard let kitten = system.firstExecutable(KittyCommands.toolPaths(appBundlePath: running?.bundlePath)) else { return false }
        // kitty only listens when the user turned remote control on; its socket then sits in a temp folder.
        for directory in ["/tmp", NSTemporaryDirectory()] {
            let folder = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            let names = KittyCommands.socketCandidates(fileNames: system.fileNames(in: folder), kittyPID: running?.pid)
            for name in names.prefix(4) {
                let arguments = KittyCommands.focusWindow(id: windowID, socketPath: folder + "/" + name)
                if system.runTool(kitten, arguments, timeout: timing.toolTimeout).succeeded { return true }
            }
        }
        return false
    }

    private func focusWezTermPane(paneID: String?, tty: String?, app: String) -> Bool {
        let bundlePath = system.runningApp(bundleID: app)?.bundlePath
        guard let wezterm = system.firstExecutable(WezTermCommands.toolPaths(appBundlePath: bundlePath)) else { return false }
        let listed = system.runTool(wezterm, WezTermCommands.listPanes, timeout: timing.toolTimeout)
        guard listed.succeeded,
              let pane = WezTermCommands.findPane(in: WezTermCommands.parsePanes(listed.stdout), paneID: paneID, tty: tty) else { return false }
        if let tab = pane.tabID {
            _ = system.runTool(wezterm, WezTermCommands.activateTab(tab), timeout: timing.toolTimeout)
        }
        return system.runTool(wezterm, WezTermCommands.activatePane(pane.paneID), timeout: timing.toolTimeout).succeeded
    }

    // MARK: Waiting without freezing

    /// Runs `work` on the background queue and waits up to `limit` seconds for its result.
    private func waitBriefly<T>(_ limit: TimeInterval, _ work: @escaping () -> T) -> T? {
        let result = Guarded<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        workQueue.async {
            result.set(work())
            done.signal()
        }
        return done.wait(timeout: .now() + limit) == .success ? result.get() : nil
    }
}
