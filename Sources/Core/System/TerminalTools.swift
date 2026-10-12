// TerminalTools.swift — the command lines for tmux, kitty and WezTerm, and how to read their answers.
//
// These terminals are not scriptable through AppleScript; each ships a small control command
// instead. This file only builds argument lists and parses output (pure functions, unit-tested).
// Actually running the tools is the jumper's job. Arguments are passed as an array, never through
// a shell, so no value can be misread as extra commands.

import Foundation

// MARK: - tmux

/// Where a tmux pane is and whether anyone is looking at it.
struct TmuxPaneState: Equatable {
    /// tmux's id for the session the pane belongs to, e.g. "$3".
    var sessionID: String
    /// True when the pane is the selected pane of the selected window of its session.
    var isActive: Bool
}

/// One terminal attached to a tmux session.
struct TmuxClient: Equatable {
    /// The terminal device the client runs in, e.g. "/dev/ttys004". This — not the pane's own
    /// device — is what the hosting terminal's tabs report.
    var tty: String
    var pid: Int32?
    /// Seconds since 1970 of the client's last activity; the most recent client is the one in use.
    var lastActivity: Int
}

enum TmuxCommands {
    private static let separator = "\t"

    /// Asks which session a pane belongs to and whether it is the active one.
    static func describePane(_ pane: String) -> [String] {
        ["display-message", "-p", "-t", pane, ["#{session_id}", "#{window_active}", "#{pane_active}"].joined(separator: separator)]
    }

    static func parsePaneState(_ output: String) -> TmuxPaneState? {
        let fields = firstLine(output).components(separatedBy: separator)
        guard fields.count == 3, fields[0].hasPrefix("$"), TerminalFacts.number(String(fields[0].dropFirst())) != nil else { return nil }
        return TmuxPaneState(sessionID: fields[0], isActive: fields[1] == "1" && fields[2] == "1")
    }

    /// Lists the terminals attached to one session, or to any session when `session` is nil.
    static func listClients(session: String?) -> [String] {
        let format = ["#{client_tty}", "#{client_pid}", "#{client_activity}"].joined(separator: separator)
        if let session { return ["list-clients", "-t", session, "-F", format] }
        return ["list-clients", "-F", format]
    }

    /// Clients with a usable terminal device, most recently active first.
    static func parseClients(_ output: String) -> [TmuxClient] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> TmuxClient? in
            let fields = line.components(separatedBy: separator)
            guard let tty = TerminalFacts.ttyPath(fields.first) else { return nil }
            let pid = fields.count > 1 ? Int32(fields[1]).flatMap { $0 > 0 ? $0 : nil } : nil
            let activity = fields.count > 2 ? Int(fields[2]) ?? 0 : 0
            return TmuxClient(tty: tty, pid: pid, lastActivity: activity)
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Makes the pane the selected pane of the selected window (two tmux commands in one run).
    static func selectPane(_ pane: String) -> [String] {
        ["select-window", "-t", pane, ";", "select-pane", "-t", pane]
    }

    /// Points one attached terminal at the pane's session.
    static func switchClient(tty: String, toPane pane: String) -> [String] {
        ["switch-client", "-c", tty, "-t", pane]
    }

    /// Places tmux is usually installed (Homebrew on Apple silicon and Intel, MacPorts, Nix).
    static let usualPaths = [
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/run/current-system/sw/bin/tmux",
    ]

    private static func firstLine(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

// MARK: - kitty

enum KittyCommands {
    /// Focuses one kitty window (what kitty calls a pane) through its remote-control socket.
    static func focusWindow(id: String, socketPath: String) -> [String] {
        ["@", "--to", "unix:" + socketPath, "focus-window", "--match", "id:" + id]
    }

    /// Picks likely remote-control sockets out of a folder listing. kitty's `listen_on` setting
    /// names the socket, and kitty usually adds "-<its pid>" to that name, so names ending in the
    /// pid come first, followed by anything else that mentions kitty.
    static func socketCandidates(fileNames: [String], kittyPID: Int32?) -> [String] {
        let suffix = kittyPID.map { "-\($0)" }
        let exact = fileNames.filter { name in suffix.map { name.hasSuffix($0) } ?? false }
        let loose = fileNames.filter { $0.lowercased().contains("kitty") && !exact.contains($0) }
        return exact.sorted() + loose.sorted()
    }

    /// The control tool inside the app bundle, then the usual install locations.
    static func toolPaths(appBundlePath: String?) -> [String] {
        (appBundlePath.map { [$0 + "/Contents/MacOS/kitten"] } ?? [])
            + ["/Applications/kitty.app/Contents/MacOS/kitten", "/opt/homebrew/bin/kitten", "/usr/local/bin/kitten"]
    }
}

// MARK: - WezTerm

/// One pane as reported by `wezterm cli list --format json`.
struct WezTermPane: Equatable {
    var paneID: Int
    var tabID: Int?
    var tty: String?
}

enum WezTermCommands {
    static let listPanes = ["cli", "list", "--format", "json"]

    static func activateTab(_ tabID: Int) -> [String] { ["cli", "activate-tab", "--tab-id", String(tabID)] }
    static func activatePane(_ paneID: Int) -> [String] { ["cli", "activate-pane", "--pane-id", String(paneID)] }

    /// Reads the pane list. Unknown fields are ignored and entries without a pane id are skipped,
    /// so a newer WezTerm cannot break this.
    static func parsePanes(_ json: String) -> [WezTermPane] {
        guard let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let paneID = row["pane_id"] as? Int else { return nil }
            return WezTermPane(paneID: paneID, tabID: row["tab_id"] as? Int, tty: TerminalFacts.ttyPath(row["tty_name"] as? String))
        }
    }

    /// The pane to focus: the one with the known id if it still exists, otherwise the one on the TTY.
    static func findPane(in panes: [WezTermPane], paneID: String?, tty: String?) -> WezTermPane? {
        if let wanted = paneID.flatMap(Int.init), let pane = panes.first(where: { $0.paneID == wanted }) { return pane }
        if let tty, let pane = panes.first(where: { $0.tty == tty }) { return pane }
        return nil
    }

    static func toolPaths(appBundlePath: String?) -> [String] {
        (appBundlePath.map { [$0 + "/Contents/MacOS/wezterm"] } ?? [])
            + ["/Applications/WezTerm.app/Contents/MacOS/wezterm", "/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"]
    }
}
