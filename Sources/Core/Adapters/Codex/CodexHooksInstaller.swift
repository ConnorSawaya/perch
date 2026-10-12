// CodexHooksInstaller.swift — adds Perch's entries to Codex's `hooks.json`, and takes them out again.
//
// Codex runs a command for each lifecycle event listed in `$CODEX_HOME/hooks.json`. Perch adds one
// entry per event that runs the `perch-hook` helper. Three facts about Codex shape this file
// (docs/research/codex.md §2.1 and §5):
//
//   1. Trust is pinned to the exact text. Codex only runs a hook after the user has reviewed it,
//      and remembers a hash of the command, timeout and status message. So an entry that is
//      already there is never "tidied up": changing a byte would silently switch the hook off.
//   2. Trust is also pinned to the position in the list. New entries are therefore appended at the
//      end and nothing the user wrote is ever reordered.
//   3. The top level of the file may only contain `hooks` (and `description`). Perch adds no
//      marker of its own there; its entries are recognised by their command text.
//
// `config.toml` is never written here. In particular Perch does not write Codex's trust records:
// those are the user's consent, given inside Codex.

import Foundation

struct CodexHooksInstaller {
    let hooksFile: URL
    let helperPath: String
    let backupsDir: URL

    struct EventSpec: Equatable {
        var name: String
        /// Seconds Codex waits for the hook. Short for events Perch only observes.
        var timeout: Int
        /// True for the one event where the helper waits for the user's decision.
        var waitsForDecision = false
    }

    /// All twelve events, installed together so the user reviews Perch's hooks once. Codex versions
    /// that do not know an event simply ignore it.
    static let events: [EventSpec] = [
        EventSpec(name: "SessionStart", timeout: 5),
        EventSpec(name: "UserPromptSubmit", timeout: 5),
        EventSpec(name: "PreToolUse", timeout: 5),
        EventSpec(name: "PostToolUse", timeout: 5),
        // A day: the hook stays open for as long as the user takes to decide.
        EventSpec(name: "PermissionRequest", timeout: 86_400, waitsForDecision: true),
        EventSpec(name: "Stop", timeout: 5),
        EventSpec(name: "Interrupt", timeout: 2),
        EventSpec(name: "SessionEnd", timeout: 2),
        EventSpec(name: "SubagentStart", timeout: 5),
        EventSpec(name: "SubagentStop", timeout: 5),
        EventSpec(name: "PreCompact", timeout: 5),
        EventSpec(name: "PostCompact", timeout: 5),
    ]

    /// Shown in the Codex terminal while it waits for an answer from the notch.
    static let waitingStatusMessage = "Waiting for a decision in Perch (notch)"
    static let backupLabel = "codex"

    /// The command line for one event. The path is single-quoted because Codex always passes the
    /// string to a shell, and Perch's support folder has a space in its name.
    func command(for event: EventSpec) -> String {
        ShellQuote.single(helperPath) + " --agent codex" + (event.waitsForDecision ? " --wait" : "")
    }

    /// True for any Perch command, including one written by an older Perch at another path.
    static func isPerchCommand(_ command: String) -> Bool {
        command.contains("perch-hook") && command.contains("--agent codex")
    }

    // MARK: Inspecting

    enum State: Equatable {
        case noFile
        case notInstalled
        /// Every event has an up-to-date Perch entry.
        case installed
        /// Some events are missing, or entries point at an old helper path.
        case needsUpdate(missing: [String], stale: [String])
        case unreadable(String)
    }

    func inspect() -> State {
        let root: OrderedJSON
        do {
            guard let text = try SafeConfigFile.read(hooksFile) else { return .noFile }
            root = try OrderedJSON.parse(text)
        } catch {
            return .unreadable("hooks.json is not valid JSON")
        }
        guard root.isObject else { return .unreadable("hooks.json is not a JSON object") }
        var missing: [String] = []
        var stale: [String] = []
        var found = 0
        for event in CodexHooksInstaller.events {
            let commands = handlerCommands(in: root["hooks"]?[event.name])
            if commands.contains(command(for: event)) {
                found += 1
            } else if commands.contains(where: CodexHooksInstaller.isPerchCommand) {
                stale.append(event.name)
            } else {
                missing.append(event.name)
            }
        }
        if found == CodexHooksInstaller.events.count { return .installed }
        if found == 0 && stale.isEmpty { return .notInstalled }
        return .needsUpdate(missing: missing, stale: stale)
    }

    private func handlerCommands(in eventArray: OrderedJSON?) -> [String] {
        (eventArray?.arrayValue ?? []).flatMap { group in
            (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
        }
    }

    /// Where each of Perch's handlers sits, as Codex's trust table names it: "<event_label>:<group>:<handler>".
    func trustKeySuffixes() -> [String] {
        guard let text = try? SafeConfigFile.read(hooksFile), let root = try? OrderedJSON.parse(text) else { return [] }
        var suffixes: [String] = []
        for event in CodexHooksInstaller.events {
            for (groupIndex, group) in (root["hooks"]?[event.name]?.arrayValue ?? []).enumerated() {
                for (handlerIndex, handler) in (group["hooks"]?.arrayValue ?? []).enumerated()
                where handler["command"]?.stringValue == command(for: event) {
                    suffixes.append("hooks.json:\(CodexHooksInstaller.snakeCase(event.name)):\(groupIndex):\(handlerIndex)")
                }
            }
        }
        return suffixes
    }

    /// "PermissionRequest" → "permission_request", the label Codex uses in trust keys.
    static func snakeCase(_ name: String) -> String {
        var out = ""
        for c in name {
            if c.isUppercase, !out.isEmpty { out.append("_") }
            out.append(contentsOf: c.lowercased())
        }
        return out
    }

    // MARK: Installing

    func install() throws -> String {
        let existingText = try SafeConfigFile.read(hooksFile)
        var root: OrderedJSON = .object([])
        if let existingText {
            do { root = try OrderedJSON.parse(existingText) } catch {
                throw AdapterConfigError.unsafeToEdit(path: hooksFile.path, reason: "it is not valid JSON. Fix or remove it, then try again.")
            }
            guard root.isObject else {
                throw AdapterConfigError.unsafeToEdit(path: hooksFile.path, reason: "its top level is not a JSON object.")
            }
        }
        var hooks = root["hooks"] ?? .object([])
        guard hooks.isObject else {
            throw AdapterConfigError.unsafeToEdit(path: hooksFile.path, reason: "its \"hooks\" entry is not a JSON object.")
        }

        var added = 0, repaired = 0
        for event in CodexHooksInstaller.events {
            var groups: [OrderedJSON]
            switch hooks[event.name] {
            case .none: groups = []
            case .some(.array(let existing)): groups = existing
            case .some:
                throw AdapterConfigError.unsafeToEdit(path: hooksFile.path, reason: "its \"\(event.name)\" entry is not a list.")
            }
            let wanted = command(for: event)
            if handlerCommands(in: .array(groups)).contains(wanted) { continue }   // already there: do not touch (trust!)

            if let (g, h) = firstPerchHandler(in: groups) {
                // An entry from an older Perch: point it at the current helper, in place, so the
                // position of every other entry stays the same.
                guard var handlers = groups[g]["hooks"]?.arrayValue else { continue }
                handlers[h] = handler(for: event)
                groups[g]["hooks"] = .array(handlers)
                repaired += 1
            } else {
                groups.append(.object(["hooks": .array([handler(for: event)])]))
                added += 1
            }
            hooks[event.name] = .array(groups)
        }
        guard added + repaired > 0 else {
            return "Perch's Codex hooks were already installed. Nothing was changed."
        }
        root["hooks"] = hooks
        try SafeConfigFile.update(hooksFile, to: root.serialized(), label: CodexHooksInstaller.backupLabel, backupsDir: backupsDir)
        if existingText == nil {
            SafeConfigFile.markCreatedByPerch(hooksFile, label: CodexHooksInstaller.backupLabel, backupsDir: backupsDir)
        }
        let what = existingText == nil ? "Created \(hooksFile.path) with" : "Added"
        let repairedNote = repaired > 0 ? " (\(repaired) updated from an older Perch)" : ""
        return "\(what) Perch's hooks for \(added + repaired) Codex events\(repairedNote). "
            + "Codex only runs new hooks after you approve them: open Codex and choose \"Trust all and continue\", or run /hooks."
    }

    private func handler(for event: EventSpec) -> OrderedJSON {
        var members: [OrderedJSON.Member] = [
            .init(key: "type", value: .string("command")),
            .init(key: "command", value: .string(command(for: event))),
            .init(key: "timeout", value: .int(event.timeout)),
        ]
        if event.waitsForDecision {
            members.append(.init(key: "statusMessage", value: .string(CodexHooksInstaller.waitingStatusMessage)))
        }
        return .object(members)
    }

    private func firstPerchHandler(in groups: [OrderedJSON]) -> (group: Int, handler: Int)? {
        for (g, group) in groups.enumerated() {
            for (h, handler) in (group["hooks"]?.arrayValue ?? []).enumerated() {
                if let command = handler["command"]?.stringValue, CodexHooksInstaller.isPerchCommand(command) { return (g, h) }
            }
        }
        return nil
    }

    // MARK: Uninstalling

    func uninstall() throws -> String {
        guard let existingText = try SafeConfigFile.read(hooksFile) else {
            return "Perch's Codex hooks were not installed. Nothing was changed."
        }
        var root: OrderedJSON
        do { root = try OrderedJSON.parse(existingText) } catch {
            throw AdapterConfigError.unsafeToEdit(path: hooksFile.path, reason: "it is not valid JSON, so Perch's entries could not be removed safely.")
        }
        guard var hooks = root["hooks"], let eventMembers = hooks.members else {
            return "Perch's Codex hooks were not installed. Nothing was changed."
        }

        var removed = 0
        var shiftedUserGroups = false
        // Every event is checked, not just the twelve Perch installs today, so entries written by an
        // older or newer Perch are cleaned up too.
        for member in eventMembers {
            guard let groups = member.value.arrayValue else { continue }
            var keptGroups: [OrderedJSON] = []
            var removedAGroup = false
            let removedBefore = removed
            for group in groups {
                guard let handlers = group["hooks"]?.arrayValue else { keptGroups.append(group); continue }
                let kept = handlers.filter { !(($0["command"]?.stringValue).map(CodexHooksInstaller.isPerchCommand) ?? false) }
                removed += handlers.count - kept.count
                if kept.count == handlers.count {
                    keptGroups.append(group)
                    if removedAGroup { shiftedUserGroups = true }   // a user group moved up one place
                } else if kept.isEmpty {
                    removedAGroup = true                             // the whole group was ours
                } else {
                    var trimmed = group
                    trimmed["hooks"] = .array(kept)
                    keptGroups.append(trimmed)
                }
            }
            // Events Perch had nothing in are left exactly as they were.
            if removed != removedBefore { hooks[member.key] = keptGroups.isEmpty ? nil : .array(keptGroups) }
        }
        guard removed > 0 else { return "Perch's Codex hooks were not installed. Nothing was changed." }
        root["hooks"] = hooks

        let label = CodexHooksInstaller.backupLabel
        let nothingLeft = (hooks.members?.isEmpty ?? true) && (root.members?.count ?? 0) == 1
        if nothingLeft, SafeConfigFile.wasCreatedByPerch(hooksFile, label: label, backupsDir: backupsDir) {
            try SafeConfigFile.remove(hooksFile, label: label, backupsDir: backupsDir)
        } else {
            try SafeConfigFile.update(hooksFile, to: root.serialized(), label: label, backupsDir: backupsDir)
        }
        SafeConfigFile.clearCreatedMark(hooksFile, label: label, backupsDir: backupsDir)
        var summary = "Removed Perch's \(removed) Codex hook entries. Your other hooks were left as they were."
        if shiftedUserGroups {
            summary += " Some of your own hooks moved up one place in their lists, so Codex may ask you to review them again."
        }
        return summary
    }
}
