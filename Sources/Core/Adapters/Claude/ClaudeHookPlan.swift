// ClaudeHookPlan.swift — the list of hooks Perch asks Claude Code to run, and what each looks like.
//
// This is the one place that decides which Claude Code events Perch listens to, which of them
// waits for an answer, and the exact command written into settings.json. The choices come from
// the live experiments in docs/research/claude-hooks-live.md:
//
//   - Exactly one hook waits: PermissionRequest. It covers permission prompts, questions
//     (AskUserQuestion) and plan approval (ExitPlanMode), and Claude Code keeps its own terminal
//     dialog usable while the hook waits. A waiting PreToolUse hook would hide that dialog, so
//     PreToolUse only reports.
//   - Every other hook just reports and returns. They are ordinary (synchronous) hooks rather
//     than `"async": true` ones on purpose: a reporting helper costs about 10 ms, and running in
//     order is what lets Perch pair a PreToolUse with the PermissionRequest that follows it and
//     notice the PostToolUse that settles it (§6 and §9.11 of the research). A short timeout
//     makes sure a stuck helper can never hold Claude Code up.
//   - An event name that a Claude Code version does not know makes it ignore the WHOLE settings
//     file, permissions included. So newer events are only registered when the installed version
//     is known to have them; with no known version only the long-standing ones are used.

import Foundation

/// A Claude Code version number such as 2.1.296.
struct ClaudeVersion: Comparable, Equatable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads "2.1.296" (also with text around it, as in "2.1.296 (Claude Code)").
    init?(_ text: String) {
        let pattern = #"(\d{1,4})\.(\d{1,4})\.(\d{1,6})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let parts = (1...3).compactMap { Range(match.range(at: $0), in: text).flatMap { Int(text[$0]) } }
        guard parts.count == 3 else { return nil }
        self.init(parts[0], parts[1], parts[2])
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (a: ClaudeVersion, b: ClaudeVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

enum ClaudeHookPlan {
    struct Hook: Equatable {
        /// Claude Code's event name, e.g. "PreToolUse".
        var event: String
        /// True for the one hook that waits for the user's decision.
        var waits = false
        /// "*" for events that are filtered by tool name; nil where a matcher means something else.
        var matcher: String?
        /// Seconds Claude Code lets the hook run. Nil keeps Claude Code's default.
        var timeout: Int?
        /// The first Claude Code version that knows this event. Nil = old enough to always register.
        var minimumVersion: ClaudeVersion?
    }

    /// A day. Claude Code's default of ten minutes would silently cancel a prompt the user has not
    /// got to yet; the card should stay answerable for as long as the terminal prompt is.
    static let waitingTimeout = 86_400
    /// Plenty for a helper that normally takes milliseconds; a bound in case it ever hangs.
    static let reportingTimeout = 5

    /// Every hook Perch uses, in the order they are written to the file.
    /// Minimum versions are from docs/research/oss-lessons.md §3.3; where two sources disagree
    /// (PostToolUseFailure) the later version is used, because registering too early is the
    /// dangerous direction. PermissionRequest is not in that table; it is gated at 2.0.45, the
    /// release that introduced it according to Claude Code's changelog (not re-checked by the
    /// research), rather than assumed to have always existed.
    static let all: [Hook] = [
        Hook(event: "SessionStart", timeout: reportingTimeout),
        // SessionEnd hooks share a 1.5 s budget, and naming a timeout would RAISE it. Leave it.
        Hook(event: "SessionEnd"),
        Hook(event: "UserPromptSubmit", timeout: reportingTimeout),
        Hook(event: "PreToolUse", matcher: "*", timeout: reportingTimeout),
        Hook(event: "PermissionRequest", waits: true, matcher: "*", timeout: waitingTimeout, minimumVersion: ClaudeVersion(2, 0, 45)),
        Hook(event: "PostToolUse", matcher: "*", timeout: reportingTimeout),
        Hook(event: "PostToolUseFailure", matcher: "*", timeout: reportingTimeout, minimumVersion: ClaudeVersion(2, 1, 89)),
        Hook(event: "Notification", timeout: reportingTimeout),
        Hook(event: "Stop", timeout: reportingTimeout),
        Hook(event: "StopFailure", timeout: reportingTimeout, minimumVersion: ClaudeVersion(2, 1, 78)),
        Hook(event: "SubagentStart", timeout: reportingTimeout, minimumVersion: ClaudeVersion(2, 0, 43)),
        Hook(event: "SubagentStop", timeout: reportingTimeout),
        Hook(event: "PreCompact", timeout: reportingTimeout),
        Hook(event: "PostCompact", timeout: reportingTimeout, minimumVersion: ClaudeVersion(2, 1, 76)),
    ]

    /// The hooks that are safe to register for a Claude Code version (nil = version unknown).
    static func hooks(for version: ClaudeVersion?) -> [Hook] {
        all.filter { hook in
            guard let minimum = hook.minimumVersion else { return true }
            guard let version else { return false }
            return version >= minimum
        }
    }

    // MARK: - What gets written into settings.json

    /// Our entries are recognised by the helper's file name in the command. Nothing else is ever
    /// treated as ours, so other tools' hooks are never touched.
    static func isPerchCommand(_ command: String) -> Bool { command.contains(PerchPaths.helperName) }

    /// The shell command for one hook.
    /// - The path is quoted because Perch's support folder has a space in it.
    /// - If the helper is gone (Perch was deleted without uninstalling) the hook exits quietly
    ///   instead of showing "command not found" on every event.
    /// - `exec` makes the helper the hook process itself, so Claude Code's signals (Esc sends
    ///   SIGTERM) reach it directly and its parent process is Claude Code.
    static func command(for hook: Hook, helperPath: String) -> String {
        let helper = shellQuote(helperPath)
        return "[ -x \(helper) ] || exit 0; exec \(helper) --agent claude --event \(hook.event)" + (hook.waits ? " --wait" : "")
    }

    /// One matcher group for an event's array: {"matcher": "*", "hooks": [{type, command, timeout}]}.
    static func group(for hook: Hook, helperPath: String) -> ClaudeJSONNode {
        var entry = [ClaudeJSONMember("type", .text("command")), ClaudeJSONMember("command", .text(command(for: hook, helperPath: helperPath)))]
        if let timeout = hook.timeout { entry.append(ClaudeJSONMember("timeout", .integer(timeout))) }
        var group: [ClaudeJSONMember] = []
        if let matcher = hook.matcher { group.append(ClaudeJSONMember("matcher", .text(matcher))) }
        group.append(ClaudeJSONMember("hooks", .array([.object(entry)])))
        return .object(group)
    }

    /// Wraps text in single quotes for a POSIX shell: nothing inside single quotes is special,
    /// and a single quote itself is written as '\''.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
