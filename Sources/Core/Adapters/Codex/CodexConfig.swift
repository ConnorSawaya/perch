// CodexConfig.swift — what Perch reads from (and, for one optional feature, writes to) Codex's config.toml.
//
// Reading: are hooks switched off, has the user trusted Perch's hooks, who reviews approvals.
// These are hints for the Settings screen; the only proof that hooks work is an event arriving.
//
// Writing: only the optional legacy `notify` program (see `CodexNotifyInstaller` below). Hooks are
// installed through hooks.json and never touch this file.

import Foundation

struct CodexConfig {
    let configFile: URL

    private func load() -> TOMLSnippetEditor? {
        guard let text = try? SafeConfigFile.read(configFile) else { return nil }
        return TOMLSnippetEditor(text: text)
    }

    /// True when the user turned hooks off (`[features] hooks = false`, or the older `codex_hooks`).
    var hooksDisabled: Bool {
        guard let toml = load() else { return false }
        return toml.bool(at: ["features", "hooks"]) == false || toml.bool(at: ["features", "codex_hooks"]) == false
    }

    /// `approvals_reviewer` from the config: "user", "auto_review", or nil when not set.
    var approvalsReviewer: String? {
        load()?.string(at: ["approvals_reviewer"])
    }

    struct TrustSummary: Equatable {
        var trusted = 0
        var disabled = 0
    }

    /// Counts Perch's hooks that Codex's trust table lists. Keys end in
    /// "hooks.json:<event_label>:<group>:<handler>"; only that ending is compared because Codex may
    /// spell the folder differently (resolved symlinks) than Perch would.
    func trust(forKeySuffixes suffixes: [String]) -> TrustSummary {
        guard let toml = load() else { return TrustSummary() }
        var summary = TrustSummary()
        for path in toml.tablePaths(under: ["hooks", "state"]) where path.count == 3 {
            guard suffixes.contains(where: { path[2].hasSuffix($0) }) else { continue }
            if toml.bool(at: path + ["enabled"]) == false {
                summary.disabled += 1
            } else if toml.string(at: path + ["trusted_hash"]) != nil {
                summary.trusted += 1
            }
        }
        return summary
    }
}

/// Decides whether a permission request should be left to Codex's own automatic reviewer.
enum CodexApprovalReviewer {
    static let automaticNames: Set<String> = ["auto_review", "guardian_subagent"]

    /// True when the session's current turn is set to automatic review. Answering from the notch
    /// would then interrupt the person for something Codex was going to decide by itself.
    /// The latest `turn_context` line of the session file is the source of truth; the config file
    /// is the fallback.
    static func usesAutomaticReview(transcriptPath: String?, config: CodexConfig) -> Bool {
        if let path = transcriptPath {
            for line in JSONLinesTailer.tailLines(of: URL(fileURLWithPath: path)).reversed() where line.contains("\"turn_context\"") {
                guard let value = JSONValue.parse(line), value["type"].stringValue == "turn_context" else { continue }
                if let reviewer = value["payload"]["approvals_reviewer"].stringValue { return automaticNames.contains(reviewer) }
                break
            }
        }
        return config.approvalsReviewer.map(automaticNames.contains) ?? false
    }
}

/// Optional and off by default: registers `perch-hook` as Codex's legacy `notify` program.
///
/// Hooks are the recommended integration (docs/research/codex.md §2.2 advises against `notify`), so
/// `CodexAdapter.installHooks()` never calls this. It exists for Codex versions older than 0.124,
/// which have no usable hooks: there `notify` is the only way to hear that a turn finished without
/// waiting for the session file to be polled. `notify` is a single slot, so a program the user
/// already configured is never replaced.
struct CodexNotifyInstaller {
    let configFile: URL
    let helperPath: String
    let backupsDir: URL

    /// Codex appends the event JSON as one more argument, which lands after the "--".
    var command: [String] { [helperPath, "--agent", "codex", "--channel", "notify", "--"] }

    var isInstalled: Bool {
        guard let text = try? SafeConfigFile.read(configFile) else { return false }
        return TOMLSnippetEditor(text: text).stringArray(at: ["notify"]) == command
    }

    func install() throws -> String {
        var toml = TOMLSnippetEditor(text: try SafeConfigFile.read(configFile) ?? "")
        if let existing = toml.rawValue(at: ["notify"]) {
            if toml.stringArray(at: ["notify"]) == command { return "Perch was already Codex's notify program. Nothing was changed." }
            throw AdapterConfigError.unsafeToEdit(path: configFile.path,
                                                  reason: "it already has a notify program (\(ToolDescriptions.oneLine(existing, limit: 80))), and Codex allows only one.")
        }
        do {
            try toml.setTopLevel(key: "notify", rawValue: TOMLSnippetEditor.quoteArray(command))
        } catch {
            throw AdapterConfigError.unsafeToEdit(path: configFile.path, reason: error.localizedDescription)
        }
        try SafeConfigFile.update(configFile, to: toml.text, label: CodexHooksInstaller.backupLabel, backupsDir: backupsDir)
        return "Added Perch as Codex's notify program in \(configFile.path)."
    }

    func uninstall() throws -> String {
        guard let text = try SafeConfigFile.read(configFile) else { return "Perch was not Codex's notify program. Nothing was changed." }
        var toml = TOMLSnippetEditor(text: text)
        // Only our exact line is removed; a notify program the user set is theirs.
        guard toml.stringArray(at: ["notify"]) == command else { return "Perch was not Codex's notify program. Nothing was changed." }
        do {
            try toml.removeTopLevel(key: "notify")
        } catch {
            throw AdapterConfigError.unsafeToEdit(path: configFile.path, reason: error.localizedDescription)
        }
        try SafeConfigFile.update(configFile, to: toml.text, label: CodexHooksInstaller.backupLabel, backupsDir: backupsDir)
        return "Removed Perch as Codex's notify program."
    }
}
