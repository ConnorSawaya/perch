// Wire.swift — the message format between the hook helper and the app.
//
// This file is compiled into BOTH the tiny `perch-hook` helper and the app, so it must stay
// Foundation-only and self-contained.
//
// How it fits together:
//   coding agent (claude, codex, ...) runs a hook
//     -> `perch-hook --agent claude [--wait]` reads the event from stdin
//     -> sends ONE line of JSON (a HookEnvelope) over a Unix socket to the app
//     -> if `--wait` was given, reads ONE line of JSON back (a HookReply), prints its
//        `stdout` text and exits with its `exitCode`
// If the app is not running the helper exits 0 immediately and prints nothing, so the agent
// carries on exactly as if Perch were not installed.

import Foundation

/// Where Perch keeps its files. Everything lives in one folder so it is easy to find and remove.
enum PerchPaths {
    static let appName = "Perch"
    static let bundleID = "local.perch.app"
    static let helperName = "perch-hook"

    /// `~/Library/Application Support/Perch`, or `$PERCH_HOME` when set (tests use this).
    static var supportDir: URL {
        if let override = ProcessInfo.processInfo.environment["PERCH_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Perch", isDirectory: true)
    }

    static var socketURL: URL { supportDir.appendingPathComponent("perch.sock") }
    /// The helper is copied here on launch so hook commands have a stable path that survives app moves.
    static var helperURL: URL { supportDir.appendingPathComponent("bin/\(helperName)") }
    static var backupsDir: URL { supportDir.appendingPathComponent("backups", isDirectory: true) }
    static var dataDir: URL { supportDir.appendingPathComponent("data", isDirectory: true) }
    static var logsDir: URL { supportDir.appendingPathComponent("logs", isDirectory: true) }
}

/// One event sent from the helper to the app. Encoded as a single line of JSON.
struct HookEnvelope: Codable, Equatable {
    /// Protocol version. Bump only for incompatible changes.
    var v: Int = 1
    /// Which coding agent ran the hook: "claude", "codex", "antigravity", "gemini".
    var agent: String
    /// "hook" (an agent hook event), "statusline" (status line data), "notify" (a notify program), "ping".
    var channel: String = "hook"
    /// Event name when the hook command passes one with `--event`; most agents put it in the payload instead.
    var event: String?
    /// Raw text the agent wrote to the helper's stdin (normally a JSON object). Not parsed by the helper.
    var payload: String = ""
    /// Extra command-line arguments after `--` (Codex `notify` passes its JSON this way).
    var args: [String] = []
    /// A small whitelist of environment variables (see `forwardedEnvKeys`) used to find the terminal.
    var env: [String: String] = [:]
    /// Process ID of the agent that ran the hook (best effort; 0 if unknown).
    var pid: Int32 = 0
    /// Terminal device of the agent process, e.g. "/dev/ttys003" (nil when there is none).
    var tty: String?
    /// Working directory of the helper process.
    var cwd: String = ""
    /// True when the helper is waiting for a HookReply (`--wait`).
    var wantsReply: Bool = false
    /// Seconds since 1970 when the helper sent this.
    var sentAt: Double = 0

    /// Environment variables the helper copies into `env` when present.
    static let forwardedEnvKeys: [String] = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "__CFBundleIdentifier",
        "TMUX", "TMUX_PANE", "KITTY_WINDOW_ID", "WEZTERM_PANE", "GHOSTTY_RESOURCES_DIR", "WARP_IS_LOCAL_SHELL_SESSION",
        "VSCODE_PID", "VSCODE_INJECTION", "VSCODE_GIT_IPC_HANDLE", "ZED_TERM", "SSH_CONNECTION",
        "CLAUDE_PID", "CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CONFIG_DIR",
        "CODEX_HOME", "GEMINI_CLI", "ANTIGRAVITY_AGENT",
    ]
}

/// The app's answer to a waiting helper. Encoded as a single line of JSON.
struct HookReply: Codable, Equatable {
    /// Text the helper prints to stdout verbatim (the agent-specific decision JSON). Empty = print nothing.
    var stdout: String = ""
    /// Exit status for the helper. 0 unless an agent's protocol needs otherwise.
    var exitCode: Int32 = 0

    /// "No opinion": the helper prints nothing and exits 0, so the agent shows its normal prompt.
    static let passthrough = HookReply(stdout: "", exitCode: 0)
}
