// GeminiUsageReader.swift — reads token usage from Gemini CLI session files.
//
// Gemini CLI records each chat in ~/.gemini/tmp/<project id>/chats/session-<time>-<id>.jsonl
// (subagent chats in a subfolder). The first line describes the session; every reply of the
// model is a line of type "gemini" with a `tokens` object. See docs/research/antigravity.md
// section 10.4. There is no rate-limit information in these files (that needs Google's private
// API and a login, which Perch never touches), so only token counts come from here.
//
// Antigravity itself has no documented, credential-free usage files; its numbers can only arrive
// through live events (see UsageEngine.observe).

import Foundation

struct GeminiUsageReader: UsageFileReader {
    let agent = AgentKind.gemini
    /// The Gemini home folder, normally ~/.gemini.
    var home: URL

    func files() -> [UsageSourceFile] {
        let root = home.appendingPathComponent("tmp", isDirectory: true)
        let rootPath = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: UsageSourceFile.walkKeys,
                                                          options: [], errorHandler: { _, _ in true }) else { return [] }
        var found: [UsageSourceFile] = []
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasSuffix(".jsonl"), path.hasPrefix(rootPath + "/") else { continue }
            let parts = path.dropFirst(rootPath.count + 1).split(separator: "/").map(String.init)
            // <project id>/chats/…/<file>.jsonl
            guard parts.count >= 3, parts[1] == "chats" else { continue }
            found.append(UsageSourceFile(path: path, modified: UsageSourceFile.modificationDate(of: url),
                                         context: ["project": Self.projectName(parts[0])]))
        }
        return found
    }

    /// Gemini names project folders by a readable id or by a long hash; a hash is shortened so it fits a label.
    static func projectName(_ folder: String) -> String {
        let isHash = folder.count == 64 && folder.allSatisfy { $0.isASCII && $0.isHexDigit }
        return isHash ? String(folder.prefix(8)) : folder
    }

    func read(_ tail: JSONLTail, file: UsageSourceFile, carry: inout String, emit: (UsageFinding) throws -> Void) throws {
        // The only thing remembered per file is the session id from its first line.
        var session = carry
        let project = file.context["project"] ?? "unknown"
        let fallbackSession = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        try tail.forEachLine { line in
            if let record = Self.record(fromLine: line, session: &session, fallbackSession: fallbackSession, project: project) {
                try emit(.record(record))
            }
        }
        carry = session
    }

    static func record(fromLine line: UnsafeRawBufferPointer, session: inout String, fallbackSession: String, project: String) -> UsageRecord? {
        guard LineBytes.contains(line, "\"tokens\"") || LineBytes.contains(line, "\"sessionId\"") else { return nil }
        guard let object = LineBytes.object(line) else { return nil }
        if let id = LineBytes.text(object["sessionId"]) { session = id }
        guard object["type"] as? String == "gemini", let tokens = object["tokens"] as? [String: Any],
              let id = LineBytes.text(object["id"]), let timestampMs = LineBytes.timestampMs(object["timestamp"]) else { return nil }
        let input = LineBytes.count(tokens["input"])
        let cached = min(LineBytes.count(tokens["cached"]), input)
        var counted = PricedTokens()
        // `input` includes the cached part; tool-result tokens are prompt tokens too.
        counted.input = input - cached + LineBytes.count(tokens["tool"])
        counted.cacheRead = cached
        // Thinking tokens are output the model produced, as they are for the other agents.
        counted.output = LineBytes.count(tokens["output"]) + LineBytes.count(tokens["thoughts"])
        guard counted.total > 0 else { return nil }
        let owner = session.isEmpty ? fallbackSession : session
        // A reply can be written again under the same id; the ledger keeps the larger copy.
        return UsageRecord(key: "gemini|\(owner)|\(id)", agent: .gemini, session: owner, project: project, timestampMs: timestampMs,
                           model: (LineBytes.text(object["model"]) ?? "unknown").lowercased(), tokens: counted)
    }
}
