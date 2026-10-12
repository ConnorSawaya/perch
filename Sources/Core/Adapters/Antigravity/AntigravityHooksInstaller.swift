// AntigravityHooksInstaller.swift — adds Perch's block to Antigravity's `~/.gemini/config/hooks.json`, and removes it.
//
// Antigravity's hooks file is an object of *named* hooks. Everything Perch adds sits under one
// name, "perch", plus one script (AntigravityShim) in `~/.gemini/config/perch/`. The rules that
// shape this file come from docs/research/antigravity.md §4 and §9:
//
//   - The command line contains no shell syntax and no spaces inside paths, because one Antigravity
//     runtime splits it on spaces and runs it without a shell. All logic is in the script.
//   - The event name is passed on the command line, because the payload does not contain it.
//   - Tool events and model events use two different entry shapes, and the wrong shape fails
//     silently (it may even make Antigravity ignore the whole file). What is written is checked.
//   - No "before tool" hook by default: that is the hook which, if it ever misbehaved, would make
//     Antigravity refuse tool calls. It is an explicit opt-in.

import Foundation

struct AntigravityHooksInstaller {
    /// `~/.gemini/config`.
    let configDir: URL
    let helperPath: String
    let backupsDir: URL

    static let blockName = "perch"
    static let backupLabel = "antigravity"
    /// Events with the "handler directly in the list" shape.
    static let modelEvents = ["PreInvocation", "PostInvocation", "Stop"]
    /// Events with the "matcher + hooks" shape.
    static let toolEvents = ["PreToolUse", "PostToolUse"]
    /// Seconds. The script itself never takes more than about two.
    static let observerTimeout = 5
    static let preToolUseTimeout = 30

    var hooksFile: URL { configDir.appendingPathComponent("hooks.json") }
    var shimDir: URL { configDir.appendingPathComponent("perch", isDirectory: true) }
    var shimFile: URL { shimDir.appendingPathComponent("hook.sh") }

    func command(for event: String) -> String { "/bin/sh \(shimFile.path) \(event)" }

    // MARK: The block

    /// Perch's named hook. `enabled` is carried over from an existing block so a pause survives a reinstall.
    func block(includePreToolUse: Bool, enabled: OrderedJSON? = nil) -> OrderedJSON {
        func handler(_ event: String, timeout: Int) -> OrderedJSON {
            .object(["type": .string("command"), "command": .string(command(for: event)), "timeout": .int(timeout)])
        }
        func toolEntry(_ event: String, timeout: Int) -> OrderedJSON {
            .array([.object(["matcher": .string("*"), "hooks": .array([handler(event, timeout: timeout)])])])
        }
        let observe = AntigravityHooksInstaller.observerTimeout
        var members: [OrderedJSON.Member] = []
        if let enabled { members.append(.init(key: "enabled", value: enabled)) }
        members.append(.init(key: "PreInvocation", value: .array([handler("PreInvocation", timeout: observe)])))
        members.append(.init(key: "PostInvocation", value: .array([handler("PostInvocation", timeout: observe)])))
        if includePreToolUse {
            members.append(.init(key: "PreToolUse", value: toolEntry("PreToolUse", timeout: AntigravityHooksInstaller.preToolUseTimeout)))
        }
        members.append(.init(key: "PostToolUse", value: toolEntry("PostToolUse", timeout: observe)))
        members.append(.init(key: "Stop", value: .array([handler("Stop", timeout: observe)])))
        return .object(members)
    }

    /// Checks one named hook against the documented shapes. Returns a description of the first
    /// problem, or nil when it looks runnable.
    static func shapeProblem(in namedHook: OrderedJSON) -> String? {
        guard let members = namedHook.members else { return "it is not an object" }
        for member in members where member.key != "enabled" {
            guard let entries = member.value.arrayValue else { return "\(member.key) is not a list" }
            for entry in entries {
                if toolEvents.contains(member.key) {
                    guard let handlers = entry["hooks"]?.arrayValue, !handlers.isEmpty,
                          handlers.allSatisfy({ $0["command"]?.stringValue?.isEmpty == false }) else {
                        return "\(member.key) entries need \"matcher\" and \"hooks\""
                    }
                } else if modelEvents.contains(member.key) {
                    // The classic mistake: wrapping a model event in `hooks: [...]` like a tool event.
                    guard entry["command"]?.stringValue?.isEmpty == false else { return "\(member.key) entries need \"command\" at the top level" }
                }
            }
        }
        return nil
    }

    // MARK: Inspecting

    enum State: Equatable {
        case notInstalled
        case installed(includesPreToolUse: Bool, paused: Bool)
        case needsUpdate
        case unreadable(String)
    }

    func inspect() -> State {
        let root: OrderedJSON
        do {
            guard let text = try SafeConfigFile.read(hooksFile) else { return .notInstalled }
            root = try OrderedJSON.parse(text)
        } catch {
            return .unreadable("hooks.json is not valid JSON")
        }
        guard root.isObject else { return .unreadable("hooks.json is not a JSON object") }
        guard var existing = root[AntigravityHooksInstaller.blockName] else { return .notInstalled }
        let paused = existing["enabled"]?.boolValue == false
        existing["enabled"] = nil
        let shimIsCurrent = (try? SafeConfigFile.read(shimFile)) == AntigravityShim.script(helperPath: helperPath)
        for includesPreToolUse in [false, true] where existing == block(includePreToolUse: includesPreToolUse) && shimIsCurrent {
            return .installed(includesPreToolUse: includesPreToolUse, paused: paused)
        }
        return .needsUpdate
    }

    /// Names of other people's hooks in the file that do not match the documented shapes. One such
    /// entry may make Antigravity ignore the whole file, Perch's block included.
    func suspiciousOtherHooks() -> [String] {
        guard let text = try? SafeConfigFile.read(hooksFile), let root = try? OrderedJSON.parse(text) else { return [] }
        return (root.members ?? []).filter { $0.key != AntigravityHooksInstaller.blockName && AntigravityHooksInstaller.shapeProblem(in: $0.value) != nil }
            .map(\.key)
    }

    // MARK: Installing

    func install(includePreToolUse: Bool) throws -> String {
        // The command line is split on spaces by one Antigravity runtime, so the script's path must not contain any.
        guard !shimFile.path.contains(where: { $0 == " " || $0 == "\t" }) else {
            throw AdapterConfigError.unsafeToEdit(path: hooksFile.path,
                                                  reason: "the folder path contains a space, which Antigravity's hook runner cannot handle safely.")
        }
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
        let newBlock = block(includePreToolUse: includePreToolUse, enabled: root[AntigravityHooksInstaller.blockName]?["enabled"])
        // Never write a block Antigravity could not run: an invalid entry can cost the user all their hooks.
        if let problem = AntigravityHooksInstaller.shapeProblem(in: newBlock) {
            throw AdapterConfigError.unsafeToEdit(path: hooksFile.path, reason: "Perch's own hook block failed its self-check (\(problem)).")
        }

        // The script goes in first, so there is never a moment when hooks.json points at a missing file.
        let shimText = AntigravityShim.script(helperPath: helperPath)
        let shimChanged = try SafeConfigFile.update(shimFile, to: shimText, label: AntigravityHooksInstaller.backupLabel, backupsDir: backupsDir)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimFile.path)

        root[AntigravityHooksInstaller.blockName] = newBlock
        let fileChanged = try SafeConfigFile.update(hooksFile, to: root.serialized(), label: AntigravityHooksInstaller.backupLabel, backupsDir: backupsDir)
        if existingText == nil {
            SafeConfigFile.markCreatedByPerch(hooksFile, label: AntigravityHooksInstaller.backupLabel, backupsDir: backupsDir)
        }
        guard fileChanged || shimChanged else { return "Perch's Antigravity hooks were already installed. Nothing was changed." }

        var summary = "Added Perch's \"perch\" block to \(hooksFile.path) and its helper script to \(shimDir.path). "
            + "Restart Antigravity sessions that are already running so they load it."
        if includePreToolUse {
            summary += " The \"show the tool before it runs\" hook is on: Antigravity refuses tool calls if that hook fails, and it may ask for approval more often."
        }
        let suspicious = suspiciousOtherHooks()
        if !suspicious.isEmpty {
            summary += " Note: the hook\(suspicious.count == 1 ? "" : "s") named \(suspicious.joined(separator: ", ")) in that file "
                + "do not look valid; Antigravity may ignore the whole file until that is fixed."
        }
        return summary
    }

    // MARK: Uninstalling

    func uninstall() throws -> String {
        var removedBlock = false
        var hadPreToolUse = false
        if let existingText = try SafeConfigFile.read(hooksFile) {
            var root: OrderedJSON
            do { root = try OrderedJSON.parse(existingText) } catch {
                throw AdapterConfigError.unsafeToEdit(path: hooksFile.path, reason: "it is not valid JSON, so Perch's block could not be removed safely.")
            }
            if let existing = root[AntigravityHooksInstaller.blockName] {
                hadPreToolUse = existing["PreToolUse"] != nil
                root[AntigravityHooksInstaller.blockName] = nil
                let label = AntigravityHooksInstaller.backupLabel
                if (root.members?.isEmpty ?? false), SafeConfigFile.wasCreatedByPerch(hooksFile, label: label, backupsDir: backupsDir) {
                    try SafeConfigFile.remove(hooksFile, label: label, backupsDir: backupsDir)
                } else {
                    try SafeConfigFile.update(hooksFile, to: root.serialized(), label: label, backupsDir: backupsDir)
                }
                SafeConfigFile.clearCreatedMark(hooksFile, label: label, backupsDir: backupsDir)
                removedBlock = true
            }
        }
        let shimExists = FileManager.default.fileExists(atPath: shimFile.path)
        guard removedBlock || shimExists else { return "Perch's Antigravity hooks were not installed. Nothing was changed." }

        // Sessions that are still running loaded the old hooks and keep calling the script. With the
        // "before tool" hook that matters: a missing script would make them refuse every tool call.
        // In that one case the script stays (it does nothing without Perch) and the user is told.
        if hadPreToolUse, shimExists {
            return "Removed Perch's block from \(hooksFile.path). The script \(shimFile.path) was left in place on purpose: Antigravity sessions "
                + "that are still running call it before every tool and would refuse tools without it. Delete that folder once those sessions are closed."
        }
        if shimExists { try? FileManager.default.removeItem(at: shimFile) }
        // The folder is removed only if nothing else is in it.
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: shimDir.path), leftovers.isEmpty {
            try? FileManager.default.removeItem(at: shimDir)
        }
        return "Removed Perch's block from \(hooksFile.path) and its helper script. Restart running Antigravity sessions so they stop calling it."
    }
}
