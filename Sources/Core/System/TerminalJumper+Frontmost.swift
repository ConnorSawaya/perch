// TerminalJumper+Frontmost.swift — "is the user already looking at this session?"
//
// Used to stay quiet (no sound, no pop-open) when the session's own tab is in front. Two levels:
//   - App level, always: is the frontmost app the one that hosts the session? One cheap lookup.
//   - Tab level, where it can be known cheaply: Terminal and iTerm2 can tell us the TTY of the tab
//     in front, and tmux can tell us whether the pane is the active one. These answers come from
//     a script or a tool, so they are fetched in the background and remembered for a moment
//     (see BriefCache).
//
// This is called often and without the user asking for anything, so it must never make macOS show
// a permission question. The tab-level script therefore only runs when Perch has already been
// allowed to control the terminal; until then the app-level answer is used.
// When an answer should be knowable but did not arrive in time, we say "not in front": better an
// unneeded sound than a missed one.

import Foundation

/// What the terminal says about the tab the user is looking at.
enum FrontTab: Equatable {
    /// The TTY of the tab in front (nil when the app has no window open).
    case device(String?)
    /// We cannot ask (no Automation permission yet, or the script failed).
    case unknowable
}

/// Whether a tmux pane is on screen in some terminal.
enum PaneVisibility: Equatable {
    /// The pane is the active one, shown by the terminals on these TTYs.
    case shownOn([String])
    /// Another pane or window is selected, or no terminal is attached.
    case hidden
    /// tmux could not be reached.
    case unknowable
}

extension TerminalJumper {

    func isFrontmost(_ session: Session) -> Bool {
        guard !session.isDemo, let front = system.frontmostBundleID() else { return false }

        var target = JumpTarget(session: session)
        if !Self.sameApp(target.bundleID, front) {
            // The recorded app may be missing or wrong; the process tree gets a second opinion.
            target = resolveTarget(for: session)
            guard Self.sameApp(target.bundleID, front) else { return false }
        }

        // From here on the right app is in front. Narrow it down to the tab where we can.
        var devices = target.tty.map { [$0] } ?? []
        if let pane = target.tmuxPane {
            let pid = target.pid
            let visibility = tmuxPanes.value(for: pane) { [weak self] in
                self?.paneVisibility(pane, sessionPID: pid) ?? .unknowable
            }
            switch visibility {
            case .none, .hidden: return false
            case .unknowable: return true
            case .shownOn(let clientDevices): devices = clientDevices
            }
        }

        let kind = target.kind
        guard kind == .appleTerminal || kind == .iTerm, !devices.isEmpty else { return true }
        let tab = frontTabs.value(for: front) { [weak self] in
            self?.frontTab(kind: kind, bundleID: front) ?? .unknowable
        }
        switch tab {
        case .none: return false
        case .unknowable: return true
        case .device(let device): return device.map(devices.contains) ?? false
        }
    }

    private static func sameApp(_ bundleID: String?, _ other: String) -> Bool {
        bundleID?.caseInsensitiveCompare(other) == .orderedSame
    }

    /// Asks the terminal which TTY its front tab is on. Runs on a background queue.
    private func frontTab(kind: TerminalKind, bundleID: String) -> FrontTab {
        guard system.automationPermission(for: bundleID) == .granted else { return .unknowable }
        let source = kind == .iTerm ? TerminalScripts.iTermFrontTTY(bundleID: bundleID)
                                    : TerminalScripts.terminalFrontTTY(bundleID: bundleID)
        guard case .output(let text) = system.runAppleScript(source, timeout: timing.frontScriptTimeout) else { return .unknowable }
        return .device(TerminalFacts.ttyPath(text))
    }

    /// Asks tmux whether the pane is the active one and which terminals show it. Background queue.
    private func paneVisibility(_ pane: String, sessionPID: Int32?) -> PaneVisibility {
        guard let tmux = tmuxPath(sessionPID: sessionPID) else { return .unknowable }
        let described = system.runTool(tmux, TmuxCommands.describePane(pane), timeout: timing.toolTimeout)
        guard described.succeeded, let state = TmuxCommands.parsePaneState(described.stdout) else { return .unknowable }
        guard state.isActive else { return .hidden }
        let clients = system.runTool(tmux, TmuxCommands.listClients(session: state.sessionID), timeout: timing.toolTimeout)
        guard clients.succeeded else { return .unknowable }
        let devices = TmuxCommands.parseClients(clients.stdout).map(\.tty)
        return devices.isEmpty ? .hidden : .shownOn(devices)
    }
}
