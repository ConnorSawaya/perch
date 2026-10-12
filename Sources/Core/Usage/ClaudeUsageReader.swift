// ClaudeUsageReader.swift — turns lines of Claude Code transcripts into usage records.
//
// Claude Code writes every conversation to ~/.claude/projects/<project>/<session>.jsonl (and
// subagents to <session>/subagents/…). An "assistant" line carries the token usage of the API
// response it belongs to. This file knows which files are transcripts, which session a file
// belongs to, and how to read one line. It follows docs/research/claude-usage.md section 4.3
// step by step; the step numbers in the comments refer to that list. The de-duplication itself
// (steps 6 to 9) happens in UsageLedger.upsert.
//
// Nothing here reads prompt or reply text: only ids, token counts, the model and the folder.

import Foundation

struct ClaudeUsageReader: UsageFileReader {
    let agent = AgentKind.claude
    /// Folders that hold `<project>/<session>.jsonl`, normally just ~/.claude/projects.
    var projectsDirs: [URL]

    // MARK: Finding files

    func files() -> [UsageSourceFile] {
        var found: [UsageSourceFile] = []
        for root in projectsDirs {
            let rootPath = root.standardizedFileURL.path
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: UsageSourceFile.walkKeys,
                                                              options: [], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walker {
                let name = url.lastPathComponent
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // Tool output dumps can be huge and never hold transcripts.
                    if name == "tool-results" { walker.skipDescendants() }
                    continue
                }
                guard Self.isTranscriptName(name) else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                let parts = path.dropFirst(rootPath.count + 1).split(separator: "/").map(String.init)
                guard let place = Self.place(ofRelativePath: parts) else { continue }
                found.append(UsageSourceFile(path: path, modified: UsageSourceFile.modificationDate(of: url),
                                             context: ["projectDir": place.projectDir, "session": place.session ?? ""]))
            }
        }
        return found
    }

    /// Live transcripts and subagent files end in ".jsonl". Claude Code also sets older transcripts
    /// of a session aside as "<session>.orphaned-<time>-<suffix>.jsonl" and "<session>.jsonl.superseded-<time>".
    /// "journal.jsonl" (workflow bookkeeping) is not a transcript.
    static func isTranscriptName(_ name: String) -> Bool {
        if name == "journal.jsonl" { return false }
        return name.hasSuffix(".jsonl") || setAsideSession(in: name) != nil
    }

    /// Step 4: the project folder and the session a file belongs to, from its path below the
    /// projects folder. The session is nil when the path holds no session id (the line's own
    /// `sessionId` is used then). A whole file name that is not a UUID is never taken as a session.
    static func place(ofRelativePath parts: [String]) -> (projectDir: String, session: String?)? {
        guard parts.count >= 2 else { return nil }
        if parts.count == 2, let session = setAsideSession(in: parts[1]) { return (parts[0], session) }
        let stem = parts[1].hasSuffix(".jsonl") ? String(parts[1].dropLast(6)) : parts[1]
        return (parts[0], isUUID(stem) ? stem : nil)
    }

    /// The leading session id of a set-aside transcript name, or nil for any other name.
    static func setAsideSession(in name: String) -> String? {
        guard name.count > 36 else { return nil }
        let id = String(name.prefix(36))
        let rest = name.dropFirst(36)
        guard isUUID(id) else { return nil }
        let orphaned = rest.hasPrefix(".orphaned-") && rest.hasSuffix(".jsonl") && rest.count > ".orphaned-.jsonl".count
        let superseded = rest.hasPrefix(".jsonl.superseded-") && rest.count > ".jsonl.superseded-".count
        return orphaned || superseded ? id : nil
    }

    static func isUUID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 8 || index == 13 || index == 18 || index == 23 {
                if byte != UInt8(ascii: "-") { return false }
            } else if !(byte >= 48 && byte <= 57) && !(byte >= 97 && byte <= 102) && !(byte >= 65 && byte <= 70) {
                return false
            }
        }
        return true
    }

    // MARK: Reading a line

    /// Reads the new lines of one transcript. Claude lines stand on their own, so nothing is
    /// carried from one line to the next (the `carry` text stays empty).
    func read(_ tail: JSONLTail, file: UsageSourceFile, carry: inout String, emit: (UsageFinding) throws -> Void) throws {
        let projectDir = file.context["projectDir"] ?? ""
        let pathSession = file.context["session"].flatMap { $0.isEmpty ? nil : $0 }
        try tail.forEachLine { line in
            for record in Self.records(fromLine: line, projectDir: projectDir, pathSession: pathSession) { try emit(.record(record)) }
        }
    }

    /// The usage in one transcript line: usually nothing (most lines are not responses), one
    /// record for an assistant line, plus one per advisor call the response made.
    static func records(fromLine line: UnsafeRawBufferPointer, projectDir: String, pathSession: String?) -> [UsageRecord] {
        // Cheap test first: only lines with a usage object are worth parsing. Claude Code writes
        // compact JSON; the spaced form is accepted in case that ever changes.
        guard LineBytes.contains(line, "\"usage\":{") || LineBytes.contains(line, "\"usage\": {") else { return [] }
        // Steps 1 and 2: valid JSON, an assistant line, with a usage object.
        guard let object = LineBytes.object(line), object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return [] }
        // Step 3: "<synthetic>" marks messages Claude Code made up locally (errors); they are not API responses.
        guard let model = LineBytes.text(message["model"]), model != "<synthetic>", !LineBytes.isTrue(object["isApiErrorMessage"]),
              let timestampMs = LineBytes.timestampMs(object["timestamp"]) else { return [] }

        let session = pathSession ?? LineBytes.text(object["sessionId"]) ?? "unknown"
        let messageID = LineBytes.text(message["id"]) ?? "uuid:" + (LineBytes.text(object["uuid"]) ?? "none")
        let requestID = LineBytes.text(object["requestId"])
        // Step 5: the key. With a request id it is global, so a fork's copies of earlier
        // responses are recognised in any session. Without one it is tied to the session, and
        // for ids that are not Anthropic's ("msg_…") also to the time, because gateways reuse ids.
        let key: String
        if let requestID {
            key = "claude|\(messageID)|\(requestID)"
        } else if messageID.hasPrefix("msg_") {
            key = "claude|\(messageID)||\(session)"
        } else {
            key = "claude|\(messageID)||\(session)|\(timestampMs)"
        }

        let project = ClaudeProjectName.name(cwd: LineBytes.text(object["cwd"]), projectDir: projectDir)
        let isSidechain = LineBytes.isTrue(object["isSidechain"])
        // Only a finished response has `speed` / `iterations` or a stop reason; a line written
        // while streaming has a placeholder output count.
        let stopReason = message["stop_reason"]
        let isFinal = usage["speed"] != nil || usage["iterations"] != nil || (stopReason != nil && !(stopReason is NSNull))

        var tokens = Self.tokens(from: usage)
        tokens.webSearches = LineBytes.count((usage["server_tool_use"] as? [String: Any])?["web_search_requests"])
        tokens.isFast = usage["speed"] as? String == "fast"
        tokens.isGeoUS = usage["inference_geo"] as? String == "us"

        var records = [UsageRecord(key: key, agent: .claude, session: session, messageID: messageID, project: project,
                                   timestampMs: timestampMs, model: UsagePricing.normalizedModelID(model), tokens: tokens,
                                   isSidechain: isSidechain, isFinal: isFinal)]

        // Advisor calls are listed inside `iterations` and are NOT part of the numbers above;
        // they are billed at the advisor model's prices, so each becomes its own record.
        if let iterations = usage["iterations"] as? [Any] {
            for (index, item) in iterations.enumerated() {
                guard let iteration = item as? [String: Any], iteration["type"] as? String == "advisor_message",
                      let advisorModel = LineBytes.text(iteration["model"]) else { continue }
                records.append(UsageRecord(key: "\(key):advisor:\(index)", agent: .claude, session: session,
                                           messageID: "\(messageID):advisor:\(index)", project: project, timestampMs: timestampMs,
                                           model: UsagePricing.normalizedModelID(advisorModel), tokens: Self.tokens(from: iteration),
                                           isSidechain: isSidechain, isFinal: isFinal))
            }
        }
        return records
    }

    /// The four token counts of a usage object (or of one `iterations` entry, which uses the same names).
    static func tokens(from usage: [String: Any]) -> PricedTokens {
        var tokens = PricedTokens()
        tokens.input = LineBytes.count(usage["input_tokens"])
        tokens.output = LineBytes.count(usage["output_tokens"])
        tokens.cacheRead = LineBytes.count(usage["cache_read_input_tokens"])
        let cacheTotal = LineBytes.count(usage["cache_creation_input_tokens"])
        if let split = usage["cache_creation"] as? [String: Any] {
            tokens.cacheWrite5m = LineBytes.count(split["ephemeral_5m_input_tokens"])
            tokens.cacheWrite1h = LineBytes.count(split["ephemeral_1h_input_tokens"])
            // Anything the split does not explain is priced as a 5-minute write. When the total
            // is SMALLER than the split (0 on old versions), the split is the truth.
            tokens.cacheWrite5m += max(0, cacheTotal - tokens.cacheWrite5m - tokens.cacheWrite1h)
        } else {
            tokens.cacheWrite5m = cacheTotal            // old transcripts have no split
        }
        return tokens
    }
}

/// Works out a project's display name: the folder name of the directory the session was started in.
///
/// A line's `cwd` can be a subfolder (the agent changed directory), while the project folder under
/// ~/.claude/projects is named after the starting directory with every non-alphanumeric character
/// replaced by "-". So the starting directory is the nearest parent of `cwd` whose encoded form
/// equals the project folder's name. If none matches (custom folder names, very long paths), the
/// folder name of `cwd` is used; without a `cwd`, the project folder's name.
enum ClaudeProjectName {
    static func name(cwd: String?, projectDir: String) -> String {
        guard let cwd, !cwd.isEmpty else { return projectDir.isEmpty ? "unknown" : projectDir }
        var candidate = cwd
        while candidate.count > 1 {
            if encoded(candidate) == projectDir { return folderName(candidate) }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty { break }
            candidate = parent
        }
        return folderName(cwd)
    }

    /// Claude Code's project folder name for a path: every character that is not a letter or digit becomes "-".
    static func encoded(_ path: String) -> String {
        // Per UTF-16 unit, like the JavaScript replace Claude Code uses.
        String(String.UnicodeScalarView(path.utf16.map { unit -> Unicode.Scalar in
            let isPlain = (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
            return isPlain ? (Unicode.Scalar(unit) ?? "-") : "-"
        }))
    }

    private static func folderName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }
}
