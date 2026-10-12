// ClaudeInstaller.swift — installs, checks and removes Perch's part of Claude Code's settings.json.
//
// Installing does two things to the file, and nothing else:
//   1. "hooks": adds one entry per event that runs `perch-hook` (see ClaudeHookPlan);
//   2. "statusLine": points it at Perch's small script, which forwards the status line data and
//      then runs the user's own status line command (see ClaudeStatusLineScript).
// Uninstalling takes exactly those out again and puts the user's status line back.
//
// Safety rules followed here (ARCHITECTURE.md §3 rule 2, docs/research/oss-lessons.md §5):
//   - a file that is not valid JSON is never written to; the user gets a clear error instead;
//   - only the two values are changed, in place; every other byte of the file stays;
//   - the previous contents are backed up before every write, and the write is atomic;
//   - running install twice changes nothing the second time;
//   - if the user changes their status line after installing, Perch leaves it alone.

import Foundation

struct ClaudeInstaller {
    /// Claude Code's settings file, `<config dir>/settings.json`.
    let settings: ClaudeSettingsFile
    /// Where the hook helper lives. Hook commands point at it; the status line script sits next to it.
    let helperURL: URL

    var scriptURL: URL { helperURL.deletingLastPathComponent().appendingPathComponent(ClaudeStatusLineScript.fileName) }
    var recordURL: URL { helperURL.deletingLastPathComponent().appendingPathComponent(ClaudeInstallRecord.fileName) }
    private var statusLineCommand: String { ClaudeStatusLineScript.command(scriptPath: scriptURL.path) }

    // MARK: - Checking (for the Agents screen)

    enum HooksState: Equatable {
        case notInstalled
        case installed
        /// Our entries are there but stale, incomplete, or point at another helper path.
        case needsUpdate
    }

    enum StatusLineState: Equatable {
        /// settings.json runs our script and the script is in place and current.
        case connected
        /// Never set up (or set up by an older Perch): installing again will connect it.
        case notSetUp
        /// Our script is referenced but missing or out of date: installing again repairs it.
        case needsRepair
        /// Perch set it up once and the user has since changed or removed it. Left alone on purpose.
        case changedByUser
        /// The user's status line is not a plain command, so Perch did not chain onto it.
        case unsupported
    }

    struct Inspection: Equatable {
        var hooks: HooksState
        var statusLine: StatusLineState
        /// True when Claude Code is told to ignore all hooks ("disableAllHooks").
        var hooksDisabledByUser: Bool
    }

    func inspect(version: ClaudeVersion?) throws -> Inspection {
        let document = try settings.read().document
        let wanted = ClaudeHookPlan.hooks(for: version)
        let found = ClaudeHooksEditor.inspect(hooks: document.node("hooks"), wanted: wanted, helperPath: helperURL.path)
        let hooks: HooksState = found.perchEntries == 0 ? .notInstalled : (found.isComplete ? .installed : .needsUpdate)
        let disabled = document.node("disableAllHooks")?.jsonValue.boolValue ?? false
        return Inspection(hooks: hooks, statusLine: statusLineState(document), hooksDisabledByUser: disabled)
    }

    private func statusLineState(_ document: ClaudeSettingsDocument) -> StatusLineState {
        let current = document.node("statusLine")
        let record = currentRecord()
        if let command = current?["command"]?.stringValue, ClaudeStatusLineScript.isPerchCommand(command) {
            guard command == statusLineCommand, let script = try? String(contentsOf: scriptURL, encoding: .utf8) else { return .needsRepair }
            return script == expectedScript(originalSetting: ClaudeStatusLineScript.originalSetting(inScript: script)) ? .connected : .needsRepair
        }
        guard let record else { return current == nil || isPlainCommand(current) ? .notSetUp : .unsupported }
        return record.managesStatusLine ? .changedByUser : .unsupported
    }

    // MARK: - Install

    /// Adds (or refreshes) Perch's hooks and status line script. Returns a plain-English summary.
    func install(version: ClaudeVersion?) throws -> String {
        let contents = try settings.read()
        var document = contents.document
        let path = settings.url.path
        let wanted = ClaudeHookPlan.hooks(for: version)
        var changes: [String] = []

        // 1. Hooks.
        let found = ClaudeHooksEditor.inspect(hooks: document.node("hooks"), wanted: wanted, helperPath: helperURL.path)
        if !found.isComplete {
            let hooks = try ClaudeHooksEditor.installing(into: document.node("hooks"), wanted: wanted, helperPath: helperURL.path, path: path)
            try document.set("hooks", to: hooks)
            changes.append(found.perchEntries == 0 ? "added Perch's hooks for \(wanted.count) Claude Code events"
                                                    : "updated Perch's hooks (\(wanted.count) events)")
        }

        // 2. Status line.
        var record = currentRecord()
        var script: String?
        var statusNote = ""
        let current = document.node("statusLine")
        let currentCommand = current?["command"]?.stringValue

        if let currentCommand, ClaudeStatusLineScript.isPerchCommand(currentCommand) {
            // Already ours: make sure the command and the script are the current ones.
            let original = record?.originalStatusLine
                ?? (try? String(contentsOf: scriptURL, encoding: .utf8)).flatMap(ClaudeStatusLineScript.originalSetting(inScript:))
            script = expectedScript(originalSetting: original)
            if currentCommand != statusLineCommand, let current {
                try document.set("statusLine", to: replacingCommand(in: current, with: statusLineCommand))
                changes.append("pointed the status line at Perch's current script")
            }
            if record == nil {
                record = ClaudeInstallRecord(settingsPath: path, createdSettingsFile: false, originalStatusLine: original,
                                             managesStatusLine: true, installedAt: Date())
            }
        } else if let record {
            // We set this up before and the user has changed it since. Their choice stands.
            statusNote = record.managesStatusLine
                ? " Your status line was changed after Perch was set up, so Perch left it alone (context and limit readings need it; uninstall and install again to reconnect)."
                : " Your status line is not a plain command, so Perch left it alone."
        } else if current == nil {
            script = expectedScript(originalSetting: nil)
            try document.set("statusLine", to: .object([ClaudeJSONMember("type", .text("command")),
                                                         ClaudeJSONMember("command", .text(statusLineCommand))]))
            record = ClaudeInstallRecord(settingsPath: path, createdSettingsFile: contents.original == nil, originalStatusLine: nil,
                                         managesStatusLine: true, installedAt: Date())
            changes.append("added a small status line (model, folder, context) that also feeds Perch")
        } else if let current, isPlainCommand(current) {
            let original = document.rawText("statusLine")
            script = expectedScript(originalSetting: original)
            try document.set("statusLine", to: replacingCommand(in: current, with: statusLineCommand))
            record = ClaudeInstallRecord(settingsPath: path, createdSettingsFile: false, originalStatusLine: original,
                                         managesStatusLine: true, installedAt: Date())
            changes.append("connected the status line (your own status line command still runs, unchanged)")
        } else {
            record = ClaudeInstallRecord(settingsPath: path, createdSettingsFile: contents.original == nil, originalStatusLine: nil,
                                         managesStatusLine: false, installedAt: Date())
            statusNote = " Your status line is not a plain command, so Perch left it alone."
        }

        // 3. Write. The script and the record go first, so settings.json never names a missing file.
        var touchedFiles = false
        do {
            if let script, (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
                try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(script.utf8).write(to: scriptURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
                touchedFiles = true
            }
            if let record, record != currentRecord() { try record.save(to: recordURL) }
        } catch {
            throw ClaudeInstallError.writeFailed(path: scriptURL.path, reason: error.localizedDescription)
        }

        guard document.text != contents.document.text else {
            let refreshed = touchedFiles ? "Perch refreshed its status line script; " : ""
            return "\(refreshed)Perch's hooks in \(displayPath) were already up to date, so the file was not changed.\(statusNote)"
        }
        let backup = try settings.write(document.text, replacing: contents.original)
        var summary = "Perch " + Self.sentence(changes) + " in \(displayPath)."
        if version == nil {
            summary += " Claude Code's version could not be read, so only the long-standing events were added; approvals from the notch need the PermissionRequest hook, which is added once the version is known."
        }
        if let backup { summary += " The previous file was saved as \(backup.lastPathComponent) in Perch's backups folder." }
        Log.info("Installed Claude Code hooks into \(path): \(changes.joined(separator: "; "))", "claude")
        return summary + statusNote
    }

    // MARK: - Uninstall

    /// Removes Perch's hook entries, restores the user's status line, and deletes Perch's script
    /// and record. Returns a plain-English summary.
    func uninstall() throws -> String {
        let contents = try settings.read()
        var document = contents.document
        let path = settings.url.path
        let record = currentRecord()
        var changes: [String] = []

        let result = try ClaudeHooksEditor.removing(from: document.node("hooks"), path: path)
        if result.removed > 0 {
            if let hooks = result.hooks { try document.set("hooks", to: hooks) } else { try document.remove("hooks") }
            changes.append("removed Perch's \(result.removed) hook \(result.removed == 1 ? "entry" : "entries")")
        }

        if let current = document.node("statusLine"), let command = current["command"]?.stringValue,
           ClaudeStatusLineScript.isPerchCommand(command) {
            let original = record?.originalStatusLine
                ?? (try? String(contentsOf: scriptURL, encoding: .utf8)).flatMap(ClaudeStatusLineScript.originalSetting(inScript:))
            if let original, let originalNode = (try? ClaudeJSONParser.parse(Array(original.utf8)))?.root,
               let originalCommand = originalNode["command"]?.stringValue {
                if current.isSame(as: replacingCommand(in: originalNode, with: command)) {
                    // Nothing but the command differs from what the user had: put their text back exactly.
                    try document.setRaw("statusLine", text: original)
                } else {
                    // They adjusted other options (padding...) while Perch was installed: keep those.
                    try document.set("statusLine", to: replacingCommand(in: current, with: originalCommand))
                }
                changes.append("put your own status line back")
            } else {
                try document.remove("statusLine")
                changes.append("removed Perch's status line")
            }
        }

        var summary: String
        if document.text != contents.document.text, contents.original != nil {
            try settings.write(document.text, replacing: contents.original)
            // Perch created this file and nothing else is in it: leave things as they were found.
            if document.isEmpty, record?.createdSettingsFile == true { settings.delete() }
            summary = "Perch " + Self.sentence(changes) + " in \(displayPath). Everything else in the file was left as it was."
            Log.info("Removed Claude Code hooks from \(path): \(changes.joined(separator: "; "))", "claude")
        } else {
            summary = "There was nothing of Perch's to remove from \(displayPath)."
        }
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: recordURL)
        return summary
    }

    // MARK: - Helpers

    /// The record of a previous install, if it is about this settings file.
    private func currentRecord() -> ClaudeInstallRecord? {
        guard let record = ClaudeInstallRecord.load(from: recordURL), record.settingsPath == settings.url.path else { return nil }
        return record
    }

    private func expectedScript(originalSetting: String?) -> String {
        let originalCommand = originalSetting
            .flatMap { try? ClaudeJSONParser.parse(Array($0.utf8)).root }
            .flatMap { $0["command"]?.stringValue }
        return ClaudeStatusLineScript.script(helperPath: helperURL.path, originalCommand: originalCommand,
                                             originalSetting: originalCommand == nil ? nil : originalSetting)
    }

    /// A status line Perch can chain onto: an object whose "command" is text and whose "type",
    /// when given, is "command".
    private func isPlainCommand(_ node: ClaudeJSONNode?) -> Bool {
        guard let node, node.members != nil, let command = node["command"]?.stringValue, !command.isEmpty else { return false }
        let type = node["type"]?.stringValue
        return type == nil || type == "command"
    }

    /// The same "statusLine" object with only its command swapped; other options (padding...) stay.
    private func replacingCommand(in node: ClaudeJSONNode, with command: String) -> ClaudeJSONNode {
        guard case .object(var members) = node else { return node }
        if let index = members.lastIndex(where: { $0.key == "command" }) {
            members[index].value = .text(command)
        } else {
            members.append(ClaudeJSONMember("command", .text(command)))
        }
        return .object(members)
    }

    private var displayPath: String { ClaudeToolDescriber.displayPath(settings.url.path, cwd: nil) }

    /// "a", "a and b", "a, b and c".
    private static func sentence(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "made no changes" }
        return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
    }
}
