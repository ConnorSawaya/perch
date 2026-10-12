// GeminiSessionParser.swift — reads the lines Gemini CLI appends to a chat session file.
//
// Hooks tell Perch what a Gemini CLI session is doing, but three things only exist in the session
// file (`~/.gemini/tmp/<project>/chats/session-*.jsonl`): which model answered, how many tokens it
// used, and error records (there is no hook for a failed turn). This parser picks out just those.
// The file's layout is taken from Gemini CLI's source and has not been seen live, so every field
// is optional and unknown lines are skipped.

import Foundation

final class GeminiSessionParser {
    let fileURL: URL
    private var sessionID: String?
    private var model: String?
    private var title: String?
    private var lastTokenTotals: [String: Double] = [:]   // message id → total, to skip rewrites of the same record

    /// - Parameter sessionID: the id the hook gave for this file, used until the file's own header is read.
    init(fileURL: URL, sessionID: String?) {
        self.fileURL = fileURL
        self.sessionID = sessionID
    }

    func parse(lines: [String]) -> [NormalizedEvent] {
        var out: [NormalizedEvent] = []
        for line in lines {
            guard let record = JSONValue.parse(line), record.objectValue != nil else { continue }
            if let id = EnvelopeReading.nonEmpty(record["sessionId"].stringValue) { sessionID = id }
            // `{"$set": {"summary": ...}}` records carry the title Gemini CLI gave the conversation.
            if let summary = EnvelopeReading.nonEmpty(record["$set"]["summary"].stringValue), summary != title {
                title = summary
                out += event(.metadata(title: summary, model: nil, gitBranch: nil, permissionMode: nil), "summary")
            }
            switch record["type"].stringValue {
            case "gemini":
                out += usage(record)
            case "error":
                let text = ToolDescriptions.text(record["content"]) ?? "Gemini CLI reported an error."
                out += event(.turnFailed(error: ToolDescriptions.clip(ToolDescriptions.oneLine(text, limit: 300), limit: 300)), "error")
            default:
                break
            }
        }
        return out
    }

    private func usage(_ record: JSONValue) -> [NormalizedEvent] {
        let tokens = record["tokens"]
        guard let total = tokens["total"].doubleValue else { return [] }
        let id = record["id"].stringValue ?? UUID().uuidString
        guard lastTokenTotals[id] != total else { return [] }
        if lastTokenTotals.count > 512 { lastTokenTotals.removeAll() }
        lastTokenTotals[id] = total
        model = EnvelopeReading.nonEmpty(record["model"].stringValue) ?? model
        // Gemini CLI has no limits or context figures to report without credentials. The token counts
        // ride along in `raw` for anything that wants to total them.
        return event(.usageUpdated(contextPercent: nil, windows: [], model: model, costUSD: nil), "tokens",
                     raw: ["id": .string(id), "model": model.map(JSONValue.string) ?? .null, "tokens": tokens])
    }

    private func event(_ agentEvent: AgentEvent, _ rawName: String, raw: JSONValue = .null) -> [NormalizedEvent] {
        guard let sessionID else { return [] }
        let context = EventContext(pid: nil, tty: nil, cwd: nil, env: [:], transcriptPath: fileURL.path, receivedAt: Date())
        return [NormalizedEvent(agent: .gemini, sessionID: sessionID, event: agentEvent, context: context, rawEventName: rawName, raw: raw)]
    }
}
