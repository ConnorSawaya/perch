// ToolDescriptions.swift — turns raw tool calls into short text and diff previews people can read.
//
// The Codex, Antigravity and Gemini adapters all receive tool calls as "a name plus some JSON".
// The helpers here produce what the notch shows: a one-line summary ("npm test", "Edit
// src/main.swift"), a diff preview for patches, and a flag for commands worth a second look.
// They never fail: unexpected input simply produces a plainer description.

import Foundation
import AppKit

enum ToolDescriptions {

    /// Longest summary line. Longer text is cut with an ellipsis.
    static let summaryLimit = 140
    /// Longest "detail" text kept for a permission card.
    static let detailLimit = 4000
    /// Most diff lines kept in a preview (the cards apply their own, smaller, display limit).
    static let diffLineLimit = 400

    // MARK: Text

    /// First non-empty line of `text`, whitespace collapsed, cut to `limit` characters.
    static func oneLine(_ text: String, limit: Int = summaryLimit) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }).map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return clip(collapsed, limit: limit)
    }

    static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// The last path component, for "Edit main.swift"-style summaries.
    static func fileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// A value from a JSON object as display text: strings as they are, anything else as compact JSON.
    static func text(_ value: JSONValue) -> String? {
        switch value {
        case .null: return nil
        case .string(let s): return s
        default: return value.serialized()
        }
    }

    /// A command given either as one string or as an argv array (`["/bin/zsh", "-lc", "npm test"]`).
    /// For the usual "shell -c script" wrapper only the script is returned.
    static func commandText(_ value: JSONValue) -> String? {
        if let s = value.stringValue { return s }
        guard let parts = value.arrayValue?.compactMap(\.stringValue), !parts.isEmpty else { return nil }
        if parts.count >= 3, ["-c", "-lc", "-ic"].contains(parts[1]),
           ["sh", "bash", "zsh", "dash", "fish"].contains(fileName(parts[0])) {
            return parts[2...].joined(separator: " ")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Risk

    /// True for commands that deserve a second look before approving. A plain-text heuristic: it is
    /// there to draw the eye, not to be a security boundary.
    static func isDangerousCommand(_ command: String) -> Bool {
        let c = " " + command.lowercased() + " "
        let needles = [
            " sudo ", "rm -rf", "rm -fr", "rm -r ", " mkfs", " dd if=", "chmod -r 777", "chown -r", "git push --force", "git push -f",
            "--force-with-lease", "git reset --hard", "git clean -f", "git clean -xdf", "git clean -fd", ":(){", "> /dev/", "drop table", "drop database",
            "truncate table", " shutdown", " reboot", "killall ", "diskutil erase", "launchctl ", "defaults delete", "--no-preserve-root",
        ]
        if needles.contains(where: { c.contains($0) }) { return true }
        // Piping a download straight into a shell.
        let downloads = c.contains("curl ") || c.contains("wget ")
        let pipesToShell = ["| sh", "|sh", "| bash", "|bash", "| zsh", "|zsh", "| sudo", "|sudo"].contains(where: { c.contains($0) })
        return downloads && pipesToShell
    }

    // MARK: Patches

    struct PatchSummary: Equatable {
        /// Files in the order the patch lists them, each with the verb the patch used.
        var files: [(verb: String, path: String)]
        var diff: DiffPreview

        static func == (a: PatchSummary, b: PatchSummary) -> Bool {
            a.diff == b.diff && a.files.map(\.path) == b.files.map(\.path) && a.files.map(\.verb) == b.files.map(\.verb)
        }

        /// "Edit health.ts", "Add notes.md", "Edit 3 files".
        var summary: String {
            guard let first = files.first else { return "Apply a patch" }
            if files.count == 1 { return "\(first.verb) \(ToolDescriptions.fileName(first.path))" }
            let verbs = Set(files.map(\.verb))
            return "\(verbs.count == 1 ? first.verb : "Change") \(files.count) files"
        }
    }

    /// Reads Codex's "*** Begin Patch" format (`*** Update File:`, `*** Add File:`, `*** Delete File:`,
    /// `*** Move to:`, then lines starting with space, `+` or `-`).
    static func parseApplyPatch(_ patch: String) -> PatchSummary {
        var files: [(verb: String, path: String)] = []
        var lines: [DiffLine] = []
        var added = 0, removed = 0, truncated = false
        func keep(_ line: DiffLine) {
            if lines.count < diffLineLimit { lines.append(line) } else { truncated = true }
        }
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("*** Begin Patch") || line.hasPrefix("*** End Patch") || line.hasPrefix("*** End of File") { continue }
            if let header = patchFileHeader(line) {
                files.append(header)
                keep(DiffLine(kind: .header, text: "\(header.verb) \(header.path)"))
            } else if line.hasPrefix("*** Move to: ") {
                keep(DiffLine(kind: .header, text: "Move to " + line.dropFirst("*** Move to: ".count)))
            } else if line.hasPrefix("@@") {
                keep(DiffLine(kind: .header, text: line))
            } else if line.hasPrefix("+") {
                added += 1
                keep(DiffLine(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                removed += 1
                keep(DiffLine(kind: .removed, text: String(line.dropFirst())))
            } else if !files.isEmpty, !line.isEmpty {
                keep(DiffLine(kind: .context, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line))
            }
        }
        let preview = DiffPreview(filePath: files.count == 1 ? files[0].path : nil, lines: lines, added: added, removed: removed, truncated: truncated)
        return PatchSummary(files: files, diff: preview)
    }

    private static func patchFileHeader(_ line: String) -> (verb: String, path: String)? {
        for (marker, verb) in [("*** Update File: ", "Edit"), ("*** Add File: ", "Add"), ("*** Delete File: ", "Delete")]
        where line.hasPrefix(marker) {
            return (verb, String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Reads a unified diff (`--- a`, `+++ b`, `@@`, then space/`+`/`-` lines), as Gemini CLI sends for edits.
    static func parseUnifiedDiff(_ diff: String, filePath: String?) -> DiffPreview {
        var lines: [DiffLine] = []
        var added = 0, removed = 0, truncated = false
        func keep(_ line: DiffLine) {
            if lines.count < diffLineLimit { lines.append(line) } else { truncated = true }
        }
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") || line.hasPrefix("Index:") || line.hasPrefix("diff ")
                || line.hasPrefix("====") {
                keep(DiffLine(kind: .header, text: line))
            } else if line.hasPrefix("+") {
                added += 1
                keep(DiffLine(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                removed += 1
                keep(DiffLine(kind: .removed, text: String(line.dropFirst())))
            } else if line.hasPrefix("\\") {
                continue   // "\ No newline at end of file"
            } else if !line.isEmpty {
                keep(DiffLine(kind: .context, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line))
            }
        }
        return DiffPreview(filePath: filePath, lines: lines, added: added, removed: removed, truncated: truncated)
    }

    // MARK: MCP

    /// "mcp__github__create_issue" → ("github", "create_issue"). Nil for other tool names.
    static func splitMCPToolName(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst("mcp__".count)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[rest.startIndex..<separator.lowerBound])
        let tool = String(rest[separator.upperBound...])
        return server.isEmpty || tool.isEmpty ? nil : (server, tool)
    }

    /// The most telling argument of an arbitrary tool call, e.g. `title: "Bump version"`.
    static func keyArgument(_ input: JSONValue) -> String? {
        guard let object = input.objectValue, !object.isEmpty else { return text(input).map { oneLine($0, limit: 80) } }
        let preferred = ["title", "query", "url", "path", "file_path", "name", "command", "prompt", "message", "description"]
        let key = preferred.first(where: { object[$0]?.stringValue != nil }) ?? object.keys.sorted().first(where: { object[$0]?.stringValue != nil })
        guard let key, let value = object[key]?.stringValue else { return nil }
        return oneLine(value, limit: 80)
    }
}

/// Small helpers every adapter uses when building NormalizedEvents from an envelope.
enum EnvelopeReading {

    /// The payload as JSON, or nil when it is empty or not a JSON object.
    static func payloadObject(_ envelope: HookEnvelope) -> JSONValue? {
        guard !envelope.payload.isEmpty, envelope.payload.utf8.count <= 8 * 1024 * 1024,
              let value = JSONValue.parse(envelope.payload), value.objectValue != nil else { return nil }
        return value
    }

    /// When the helper sent the envelope (falls back to now for a missing or absurd timestamp).
    static func receivedAt(_ envelope: HookEnvelope) -> Date {
        let now = Date()
        guard envelope.sentAt > 0 else { return now }
        let sent = Date(timeIntervalSince1970: envelope.sentAt)
        return abs(sent.timeIntervalSince(now)) < 3600 ? sent : now
    }

    static func context(_ envelope: HookEnvelope, cwd: String?, transcriptPath: String?) -> EventContext {
        EventContext(pid: envelope.pid > 0 ? envelope.pid : nil,
                     tty: envelope.tty,
                     cwd: nonEmpty(cwd) ?? nonEmpty(envelope.cwd),
                     env: envelope.env,
                     transcriptPath: nonEmpty(transcriptPath),
                     receivedAt: receivedAt(envelope))
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Replaces a leading "~" with the home folder (Antigravity's docs show such paths).
    static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + String(path.dropFirst(1)) }
        return path
    }
}

/// Finds apps through LaunchServices. Kept apart so adapters can be tested without it.
enum LaunchServicesLookup {
    static func url(forBundleID bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}
