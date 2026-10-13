// Layout.swift — the few measurements the window shell and the views must agree on,
// plus the rule for working out which app a session is running in.

import Foundation
import CoreGraphics

/// Geometry of the "island". The window itself never resizes: it is a fixed, transparent,
/// click-through rectangle pinned to the top-centre of the screen, and the views draw the island
/// (pill or open panel) at its top-centre. The shell uses these sizes to know where the island is
/// so it can accept clicks there and let every other click pass through.
enum IslandMetrics {
    /// Largest values the size settings allow.
    static let maxPanelWidth: CGFloat = 760
    static let maxPanelHeight: CGFloat = 720
    static let minPanelWidth: CGFloat = 320
    static let minPanelHeight: CGFloat = 320
    /// Transparent room around the island for glow and shadow.
    static let margin: CGFloat = 40

    /// Fixed window size: big enough for the largest panel plus the margin on the sides and bottom.
    static let windowSize = CGSize(width: maxPanelWidth + margin * 2, height: maxPanelHeight + margin)

    /// Width of the pill on each side of the notch.
    static func wing(_ settings: AppSettings) -> CGFloat { settings.pillStyle == .detailed ? 84 : 44 }

    /// Size of the collapsed pill (it includes the notch itself in the middle).
    static func pillSize(ui: UIState, settings: AppSettings) -> CGSize {
        CGSize(width: ui.notchSize.width + wing(settings) * 2, height: ui.notchSize.height)
    }

    /// Size of the open panel, measured from the top of the screen (so it includes the notch height).
    static func panelSize(ui: UIState, settings: AppSettings) -> CGSize {
        let width = min(max(CGFloat(settings.panelWidth), minPanelWidth), maxPanelWidth)
        let limit = min(max(CGFloat(settings.panelMaxHeight), minPanelHeight), maxPanelHeight)
        let wanted = ui.desiredPanelHeight > 0 ? ui.desiredPanelHeight : 220
        return CGSize(width: width, height: min(max(wanted, ui.notchSize.height + 60), limit))
    }

    /// Size of whatever is showing right now.
    static func islandSize(ui: UIState, settings: AppSettings) -> CGSize {
        ui.isExpanded ? panelSize(ui: ui, settings: settings) : pillSize(ui: ui, settings: settings)
    }

    /// The island's rectangle inside the window, in a top-left-origin coordinate space.
    static func islandRect(ui: UIState, settings: AppSettings) -> CGRect {
        let size = islandSize(ui: ui, settings: settings)
        return CGRect(x: (windowSize.width - size.width) / 2, y: 0, width: size.width, height: size.height)
    }
}

extension TerminalInfo {
    /// Works out where a session is running from the facts the hook helper collected.
    init(context: EventContext) {
        self.init()
        let env = context.env
        tty = context.tty
        termProgram = env["TERM_PROGRAM"]
        itermSessionID = env["ITERM_SESSION_ID"]
        terminalSessionID = env["TERM_SESSION_ID"]
        tmuxPane = env["TMUX_PANE"]
        kittyWindowID = env["KITTY_WINDOW_ID"]
        weztermPane = env["WEZTERM_PANE"]
        bundleID = TerminalInfo.bundleID(termProgram: termProgram, cfBundleID: env["__CFBundleIdentifier"])
    }

    /// Bundle identifiers for the terminals and editors Perch knows by their TERM_PROGRAM value.
    static let knownTermPrograms: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "WezTerm": "com.github.wez.wezterm",
        "kitty": "net.kovidgoyal.kitty",
        "Alacritty": "org.alacritty",
        "Hyper": "co.zeit.hyper",
        "zed": "dev.zed.Zed",
    ]

    /// The app's own bundle id wins when the system provided it (it tells VS Code, Cursor, Windsurf
    /// and Antigravity apart, which all report TERM_PROGRAM=vscode); otherwise fall back to TERM_PROGRAM.
    static func bundleID(termProgram: String?, cfBundleID: String?) -> String? {
        if let id = cfBundleID, !id.isEmpty { return id }
        guard let program = termProgram, !program.isEmpty else { return nil }
        if let known = knownTermPrograms[program] { return known }
        return program == "vscode" ? "com.microsoft.VSCode" : nil
    }
}
