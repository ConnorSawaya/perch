// GeminiHooksInstaller.swift — adds Perch's hooks to Gemini CLI's `~/.gemini/settings.json`, and removes them.
//
// Gemini CLI reads hooks from the `hooks` object of its settings file. Perch appends one entry per
// event, each with a handler named "perch". Two details come straight from reading Gemini CLI's
// source (docs/research/antigravity.md §10.2 and §10.5):
//
//   - A hook whose command fails with non-JSON output can be read as "deny", which would block
//     the user's prompts. So every command ends in `>/dev/null 2>&1; echo '{}'`: whatever happens
//     to the helper (crashed, deleted, slow), Gemini CLI gets `{}` and exit status 0.
//   - Timeouts are in milliseconds here (Antigravity uses seconds; do not mix them up).
//
// `BeforeTool` is deliberately not installed: it adds little and is the one event that could do
// harm if another runtime treated it as a gate.

import Foundation

struct GeminiHooksInstaller {
    let settingsFile: URL
    let helperPath: String
    let backupsDir: URL

    /// Events Perch observes. `matchesTools` entries need a matcher; "*" means every tool.
    static let events: [(name: String, matchesTools: Bool)] = [
        ("SessionStart", false), ("SessionEnd", false), ("BeforeAgent", false), ("AfterAgent", false),
        ("AfterTool", true), ("Notification", false),
    ]
    static let handlerName = "perch"
    static let timeoutMilliseconds = 5000
    static let backupLabel = "gemini"

    /// Gemini CLI runs hook commands through `bash -c`, so shell syntax is safe here.
    func command(for event: String) -> String {
        "\(ShellQuote.single(helperPath)) --agent gemini --event \(event) >/dev/null 2>&1; echo '{}'"
    }

    /// True for a handler Perch wrote, now or in an earlier version.
    static func isPerchHandler(_ handler: OrderedJSON) -> Bool {
        if handler["name"]?.stringValue == handlerName { return true }
        guard let command = handler["command"]?.stringValue else { return false }
        return command.contains("perch-hook") && command.contains("--agent gemini")
    }

    // MARK: Inspecting

    enum State: Equatable {
        case noFile
        case notInstalled
        case installed
        case needsUpdate
        case unreadable(String)
    }

    struct Inspection: Equatable {
        var state: State
        /// True when the user switched all hooks off, or disabled the one named "perch".
        var disabledByUser = false
    }

    func inspect() -> Inspection {
        let root: OrderedJSON
        do {
            guard let text = try SafeConfigFile.read(settingsFile) else { return Inspection(state: .noFile) }
            root = try OrderedJSON.parse(text)
        } catch {
            return Inspection(state: .unreadable("settings.json is not plain JSON"))
        }
        guard root.isObject else { return Inspection(state: .unreadable("settings.json is not a JSON object")) }
        var current = 0, stale = 0
        for event in GeminiHooksInstaller.events {
            let handlers = (root["hooks"]?[event.name]?.arrayValue ?? []).flatMap { $0["hooks"]?.arrayValue ?? [] }
            if handlers.contains(where: { $0["command"]?.stringValue == command(for: event.name) }) {
                current += 1
            } else if handlers.contains(where: GeminiHooksInstaller.isPerchHandler) {
                stale += 1
            }
        }
        let hooksConfig = root["hooksConfig"]
        let disabledNames = (hooksConfig?["disabled"]?.arrayValue ?? []).compactMap(\.stringValue)
        let disabled = hooksConfig?["enabled"]?.boolValue == false || disabledNames.contains(GeminiHooksInstaller.handlerName)
        let state: State
        if current == GeminiHooksInstaller.events.count { state = .installed }
        else if current == 0 && stale == 0 { state = .notInstalled }
        else { state = .needsUpdate }
        return Inspection(state: state, disabledByUser: disabled)
    }

    // MARK: Installing

    func install() throws -> String {
        let existingText = try SafeConfigFile.read(settingsFile)
        var root = try parse(existingText)
        var hooks = root["hooks"] ?? .object([])
        guard hooks.isObject else {
            throw AdapterConfigError.unsafeToEdit(path: settingsFile.path, reason: "its \"hooks\" entry is not a JSON object.")
        }
        var changed = 0
        for event in GeminiHooksInstaller.events {
            var groups: [OrderedJSON]
            switch hooks[event.name] {
            case .none: groups = []
            case .some(.array(let existing)): groups = existing
            case .some:
                throw AdapterConfigError.unsafeToEdit(path: settingsFile.path, reason: "its \"\(event.name)\" hooks entry is not a list.")
            }
            let wanted = handler(for: event.name)
            let allHandlers = groups.flatMap { $0["hooks"]?.arrayValue ?? [] }
            if allHandlers.contains(wanted) { continue }
            if let (g, h) = firstPerchHandler(in: groups), var handlers = groups[g]["hooks"]?.arrayValue {
                handlers[h] = wanted                                    // refresh an older entry in place
                groups[g]["hooks"] = .array(handlers)
            } else {
                var members: [OrderedJSON.Member] = []
                if event.matchesTools { members.append(.init(key: "matcher", value: .string("*"))) }
                members.append(.init(key: "hooks", value: .array([wanted])))
                groups.append(.object(members))                         // appended: the user's entries stay first
            }
            hooks[event.name] = .array(groups)
            changed += 1
        }
        guard changed > 0 else { return "Perch's Gemini CLI hooks were already installed. Nothing was changed." }
        root["hooks"] = hooks
        try SafeConfigFile.update(settingsFile, to: root.serialized(), label: GeminiHooksInstaller.backupLabel, backupsDir: backupsDir)
        if existingText == nil {
            SafeConfigFile.markCreatedByPerch(settingsFile, label: GeminiHooksInstaller.backupLabel, backupsDir: backupsDir)
        }
        return "Added Perch's hooks for \(changed) Gemini CLI events to \(settingsFile.path). Restart Gemini CLI sessions that are already open."
    }

    func uninstall() throws -> String {
        let nothing = "Perch's Gemini CLI hooks were not installed. Nothing was changed."
        guard let existingText = try SafeConfigFile.read(settingsFile) else { return nothing }
        var root = try parse(existingText)
        guard var hooks = root["hooks"], let eventMembers = hooks.members else { return nothing }
        var removed = 0
        for member in eventMembers {
            guard let groups = member.value.arrayValue else { continue }
            let removedBefore = removed
            var keptGroups: [OrderedJSON] = []
            for group in groups {
                guard let handlers = group["hooks"]?.arrayValue else { keptGroups.append(group); continue }
                let kept = handlers.filter { !GeminiHooksInstaller.isPerchHandler($0) }
                removed += handlers.count - kept.count
                if kept.count == handlers.count {
                    keptGroups.append(group)
                } else if !kept.isEmpty {
                    var trimmed = group
                    trimmed["hooks"] = .array(kept)
                    keptGroups.append(trimmed)
                }
            }
            if removed != removedBefore { hooks[member.key] = keptGroups.isEmpty ? nil : .array(keptGroups) }
        }
        guard removed > 0 else { return nothing }
        // A `hooks` object left empty by the removal goes too; one the user had empty anyway never gets here.
        root["hooks"] = (hooks.members?.isEmpty ?? true) ? nil : hooks

        let label = GeminiHooksInstaller.backupLabel
        if (root.members?.isEmpty ?? true), SafeConfigFile.wasCreatedByPerch(settingsFile, label: label, backupsDir: backupsDir) {
            try SafeConfigFile.remove(settingsFile, label: label, backupsDir: backupsDir)
        } else {
            try SafeConfigFile.update(settingsFile, to: root.serialized(), label: label, backupsDir: backupsDir)
        }
        SafeConfigFile.clearCreatedMark(settingsFile, label: label, backupsDir: backupsDir)
        return "Removed Perch's \(removed) Gemini CLI hook entries. Your other settings were left as they were."
    }

    // MARK: Pieces

    private func parse(_ text: String?) throws -> OrderedJSON {
        guard let text else { return .object([]) }
        let root: OrderedJSON
        do { root = try OrderedJSON.parse(text) } catch {
            // Gemini CLI tolerates comments in this file; Perch cannot keep them, so it does not edit such a file.
            throw AdapterConfigError.unsafeToEdit(path: settingsFile.path,
                                                  reason: "it is not plain JSON (comments or a syntax error). Perch only edits files it can read exactly.")
        }
        guard root.isObject else {
            throw AdapterConfigError.unsafeToEdit(path: settingsFile.path, reason: "its top level is not a JSON object.")
        }
        return root
    }

    private func handler(for event: String) -> OrderedJSON {
        .object([
            "name": .string(GeminiHooksInstaller.handlerName),
            "type": .string("command"),
            "command": .string(command(for: event)),
            "timeout": .int(GeminiHooksInstaller.timeoutMilliseconds),
        ])
    }

    private func firstPerchHandler(in groups: [OrderedJSON]) -> (Int, Int)? {
        for (g, group) in groups.enumerated() {
            for (h, handler) in (group["hooks"]?.arrayValue ?? []).enumerated() where GeminiHooksInstaller.isPerchHandler(handler) {
                return (g, h)
            }
        }
        return nil
    }
}
