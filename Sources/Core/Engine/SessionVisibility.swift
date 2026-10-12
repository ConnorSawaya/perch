// SessionVisibility.swift — decides where a session is running and whether it gets a card.
//
// Two settings hide sessions: "show headless sessions" (runs with no terminal, e.g. `claude -p`
// in a script) and "show sessions started from desktop apps" (sessions that live inside an editor
// or a desktop app instead of a terminal window). A hidden session gets no card, and its
// permission prompts are handed straight back to the agent.
//
// The rule, in order:
//   1. Hosted by the Claude desktop app                        -> desktop app
//   2. Has a terminal device (tty), now or earlier             -> terminal
//   3. No tty, hosted by an app that is not a terminal program -> desktop app (editor, IDE...)
//   4. No tty, but a process id (so a hook helper ran for it)  -> headless
//   5. No facts at all (the event came from a watched file)    -> unknown; shown, never "headless"
// A tty is the strongest evidence and sticks: one event that failed to report it does not turn a
// terminal session into a headless one.

import Foundation

enum SessionVisibility {
    enum Host: Equatable {
        case terminal, desktopApp, headless, unknown
    }

    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// Bundle ids of terminal programs. A session with no tty inside one of these is a headless
    /// run started from a shell, not a "desktop app" session.
    static let terminalBundleIDs: Set<String> = Set(TerminalInfo.knownTermPrograms.values).union([
        "com.apple.Terminal", "dev.warp.Warp", "dev.warp.Warp-Preview", "io.alacritty", "com.raphaelamorim.rio",
    ])

    /// Works out the host from one event's context, taking what is already known about the session into account.
    static func host(context: EventContext, known: Session?) -> Host {
        let fresh = TerminalInfo(context: context)
        let bundleID = nonEmpty(fresh.bundleID) ?? nonEmpty(known?.terminal.bundleID)
        if bundleID == claudeDesktopBundleID { return .desktopApp }
        if nonEmpty(fresh.tty) != nil || nonEmpty(known?.terminal.tty) != nil { return .terminal }
        if let bundleID, !terminalBundleIDs.contains(bundleID) { return .desktopApp }
        let hasProcess = EngineFacts.validPID(context.pid) != nil || EngineFacts.validPID(known?.pid) != nil
        if hasProcess { return .headless }
        // A bundle id of a terminal without any process facts still says nothing about a tty.
        return known?.isHeadless == true ? .headless : .unknown
    }

    /// The host of a session that already has a card (used by housekeeping when settings change).
    static func host(of session: Session) -> Host {
        let bundleID = nonEmpty(session.terminal.bundleID)
        if bundleID == claudeDesktopBundleID { return .desktopApp }
        if nonEmpty(session.terminal.tty) != nil { return .terminal }
        if let bundleID, !terminalBundleIDs.contains(bundleID) { return .desktopApp }
        return session.isHeadless ? .headless : .unknown
    }

    static func isVisible(_ host: Host, _ config: EngineConfig) -> Bool {
        switch host {
        case .terminal, .unknown: return true
        case .desktopApp: return config.showDesktopAppSessions
        case .headless: return config.showHeadlessSessions
        }
    }

    /// Plain-English reason a session is hidden, for the activity log.
    static func hiddenReason(_ host: Host) -> String {
        switch host {
        case .desktopApp: return "sessions started from desktop apps are hidden in Settings"
        case .headless: return "sessions without a terminal are hidden in Settings"
        case .terminal, .unknown: return "the session is hidden"
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
