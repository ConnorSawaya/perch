// TerminalKind.swift — works out what sort of app a session lives in, and cleans up the facts
// we will use to find its tab.
//
// Each terminal needs a different trick to bring one tab forward, so the first step of a jump is
// to sort the session into a kind. The app's bundle id is trusted over TERM_PROGRAM, because
// several apps borrow each other's TERM_PROGRAM value.
//
// Everything a hook sent us (TTY, pane ids, session ids) is checked against a strict shape here.
// Values that do not look right are dropped, so nothing odd can reach a script or a command line.

import Foundation

enum TerminalKind: Equatable {
    case appleTerminal   // Terminal.app: tab found by TTY through AppleScript
    case iTerm           // iTerm2: session found by id or TTY through AppleScript
    case ghostty         // Ghostty: terminal found by folder through its AppleScript support
    case kitty           // kitty: window focused through its remote-control command
    case wezTerm         // WezTerm: pane focused through `wezterm cli`
    case warp            // Warp: no scripting; only the app can be raised
    case editor          // VS Code family and Zed: reopen the folder to raise the right window
    case claudeDesktop   // the Claude desktop app
    case otherApp        // some other app we know the bundle id of: raise it
    case unknown         // nothing known yet; the process tree may still tell us

    /// Sorts a bundle identifier into a kind.
    static func classify(bundleID: String) -> TerminalKind {
        let id = bundleID.lowercased()
        if let exact = exactKinds[id] { return exact }
        if id.hasPrefix("dev.warp.") { return .warp }
        if editorPrefixes.contains(where: { id.hasPrefix($0) }) { return .editor }
        return id.isEmpty ? .unknown : .otherApp
    }

    /// Sorts a session's terminal facts into a kind, and names the bundle id that goes with it.
    static func classify(_ info: TerminalInfo) -> (kind: TerminalKind, bundleID: String?) {
        if let id = info.bundleID?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            return (classify(bundleID: id), id)
        }
        // No bundle id: fall back to TERM_PROGRAM, then to the variables only one terminal sets.
        if let id = TerminalInfo.bundleID(termProgram: info.termProgram, cfBundleID: nil) {
            return (classify(bundleID: id), id)
        }
        if TerminalFacts.iTermSessionGUID(info.itermSessionID) != nil { return (.iTerm, BundleIDs.iTerm) }
        if TerminalFacts.number(info.kittyWindowID) != nil { return (.kitty, BundleIDs.kitty) }
        if TerminalFacts.number(info.weztermPane) != nil { return (.wezTerm, BundleIDs.wezTerm) }
        return (.unknown, nil)
    }

    /// A name for messages, e.g. "Terminal" or "iTerm2". Nil when we have no better name than the app's own.
    static func displayName(bundleID: String) -> String? {
        displayNames[bundleID.lowercased()]
    }

    enum BundleIDs {
        static let appleTerminal = "com.apple.Terminal"
        static let iTerm = "com.googlecode.iterm2"
        static let ghostty = "com.mitchellh.ghostty"
        static let kitty = "net.kovidgoyal.kitty"
        static let wezTerm = "com.github.wez.wezterm"
        static let claudeDesktop = "com.anthropic.claudefordesktop"
    }

    private static let exactKinds: [String: TerminalKind] = [
        BundleIDs.appleTerminal.lowercased(): .appleTerminal,
        BundleIDs.iTerm: .iTerm,
        BundleIDs.ghostty: .ghostty,
        BundleIDs.kitty: .kitty,
        BundleIDs.wezTerm: .wezTerm,
        BundleIDs.claudeDesktop: .claudeDesktop,
    ]

    /// Editors with a built-in terminal: VS Code (and Insiders), VSCodium, Cursor, Windsurf,
    /// Antigravity and Zed (and its preview build). Lower-case, matched as prefixes.
    private static let editorPrefixes = [
        "com.microsoft.vscode", "com.vscodium", "com.visualstudio.code", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "com.google.antigravity", "dev.zed.zed",
    ]

    private static let displayNames: [String: String] = [
        BundleIDs.appleTerminal.lowercased(): "Terminal",
        BundleIDs.iTerm: "iTerm2",
        BundleIDs.ghostty: "Ghostty",
        BundleIDs.kitty: "kitty",
        BundleIDs.wezTerm: "WezTerm",
        BundleIDs.claudeDesktop: "Claude",
        "dev.warp.warp-stable": "Warp",
        "com.microsoft.vscode": "Visual Studio Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "com.google.antigravity": "Antigravity",
        "dev.zed.zed": "Zed",
    ]
}

/// Checks and tidies the identifiers hooks give us. Each returns nil for anything unexpected.
enum TerminalFacts {

    /// "/dev/ttys003" from "/dev/ttys003" or "ttys003". Nil for "??", empty or odd-looking values.
    static func ttyPath(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.hasPrefix("/dev/") { name.removeFirst("/dev/".count) }
        guard !name.isEmpty, name.count <= 32, name.unicodeScalars.allSatisfy(isASCIILetterOrDigit) else { return nil }
        return "/dev/" + name
    }

    /// The session's unique id from ITERM_SESSION_ID, which looks like "w0t1p0:6C5A…-…". The part
    /// after the colon is what iTerm2's scripting calls `unique ID`.
    static func iTermSessionGUID(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let guid = raw.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? raw
        guard !guid.isEmpty, guid.count <= 64,
              guid.unicodeScalars.allSatisfy({ isASCIILetterOrDigit($0) || $0 == "-" }) else { return nil }
        return guid
    }

    /// A tmux pane id such as "%12".
    static func tmuxPane(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.hasPrefix("%"),
              let digits = number(String(raw.dropFirst())) else { return nil }
        return "%" + digits
    }

    /// A plain non-negative whole number (kitty window ids, WezTerm pane ids), as text.
    static func number(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.count <= 12,
              raw.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else { return nil }
        return raw
    }

    private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122: return true
        default: return false
        }
    }
}

/// Everything the jumper needs to know about one session, already checked and tidied.
struct JumpTarget: Equatable {
    var kind: TerminalKind
    var bundleID: String?
    /// The terminal device of the agent, e.g. "/dev/ttys003". Inside tmux this is tmux's inner
    /// device, which no terminal tab will ever report.
    var tty: String?
    var iTermSessionGUID: String?
    var tmuxPane: String?
    var kittyWindowID: String?
    var weztermPane: String?
    /// The session's working folder (used by Ghostty and the editors).
    var folder: String
    var pid: Int32?

    init(session: Session) {
        let sorted = TerminalKind.classify(session.terminal)
        kind = sorted.kind
        bundleID = sorted.bundleID
        tty = TerminalFacts.ttyPath(session.terminal.tty)
        iTermSessionGUID = TerminalFacts.iTermSessionGUID(session.terminal.itermSessionID)
        tmuxPane = TerminalFacts.tmuxPane(session.terminal.tmuxPane)
        kittyWindowID = TerminalFacts.number(session.terminal.kittyWindowID)
        weztermPane = TerminalFacts.number(session.terminal.weztermPane)
        folder = session.cwd
        pid = session.pid.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Points the target at a different app (used when the process tree knows better).
    mutating func setApp(bundleID newID: String) {
        bundleID = newID
        kind = TerminalKind.classify(bundleID: newID)
    }
}
