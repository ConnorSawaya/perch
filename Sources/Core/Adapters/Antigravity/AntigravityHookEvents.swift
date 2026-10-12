// AntigravityHookEvents.swift — translates Antigravity's hook payloads (and its CLI status feed) into Perch events.
//
// Antigravity differs from the other agents in ways this file has to absorb
// (docs/research/antigravity.md §4 and §9.4):
//
//   - The payload does not say which event it is. The name comes from the hook's command line
//     (the helper's `--event`), never from guessing by which keys are present.
//   - There is no "session started", "prompt submitted" or "session ended" event. A session is
//     announced the first time its conversation id is seen, and a turn is considered started at
//     the first model call after the previous turn stopped.
//   - The prompt and the final reply are not in any payload. They are read, when possible, from
//     the transcript file the payload points to (whose format is not documented, so that is
//     strictly best effort).
//   - Fields with empty or zero values may be missing altogether.
//
// Nothing here can answer Antigravity: its hooks can veto a tool but cannot approve one, so every
// request Perch shows for Antigravity is display-only.

import Foundation

/// Remembers, per conversation, the little that the payloads do not say. Used on the main thread only.
final class AntigravitySessionMemory {
    private(set) var knownSessions: Set<String> = []
    private var turnOpen: Set<String> = []
    private var confirmationPending: Set<String> = []
    private var lastStatus: [String: String] = [:]

    /// True the first time a conversation id is seen.
    func isNew(_ session: String) -> Bool {
        if knownSessions.count > 256 {
            knownSessions.removeAll(); turnOpen.removeAll(); confirmationPending.removeAll(); lastStatus.removeAll()
        }
        return knownSessions.insert(session).inserted
    }

    /// Marks the turn as running. Returns true when it was not running before.
    func openTurn(_ session: String) -> Bool { turnOpen.insert(session).inserted }
    func closeTurn(_ session: String) { turnOpen.remove(session) }

    /// True when the status feed's numbers differ from the last ones seen for this session.
    func statusChanged(_ fingerprint: String, session: String) -> Bool {
        if lastStatus[session] == fingerprint { return false }
        lastStatus[session] = fingerprint
        return true
    }

    /// Records the status feed's "waiting for confirmation" flag. Returns true when it just turned on.
    func setConfirmationPending(_ pending: Bool, session: String) -> Bool {
        if pending { return confirmationPending.insert(session).inserted }
        confirmationPending.remove(session)
        return false
    }
}

enum AntigravityHookEvents {

    static func normalize(_ envelope: HookEnvelope, home: URL, memory: AntigravitySessionMemory, toolMemory: ToolStartMemory) -> [NormalizedEvent] {
        guard let payload = EnvelopeReading.payloadObject(envelope) else { return [] }
        if envelope.channel == "statusline" { return normalizeStatusFeed(envelope, payload: payload, memory: memory) }
        guard envelope.channel == "hook",
              let sessionID = EnvelopeReading.nonEmpty(payload["conversationId"].stringValue),
              let name = EnvelopeReading.nonEmpty(envelope.event) else { return [] }

        let transcriptPath = payload["transcriptPath"].stringValue.map { EnvelopeReading.expandTilde($0, home: home) }
        // The helper's own folder is Antigravity's config folder, never the project: only the payload's workspace counts.
        var context = EnvelopeReading.context(envelope, cwd: nil, transcriptPath: transcriptPath)
        context.cwd = EnvelopeReading.nonEmpty(payload["workspacePaths"][0].stringValue)
        let model = EnvelopeReading.nonEmpty(payload["modelName"].stringValue)
        func event(_ agentEvent: AgentEvent, raw: JSONValue = .null) -> NormalizedEvent {
            NormalizedEvent(agent: .antigravity, sessionID: sessionID, event: agentEvent, context: context, rawEventName: name, raw: raw)
        }

        var events: [NormalizedEvent] = []
        if memory.isNew(sessionID) {
            events.append(event(.sessionStarted(title: nil, model: model, source: surface(transcriptPath: transcriptPath, env: envelope.env))))
        }
        let call = payload["toolCall"]
        let toolName = call["name"].stringValue ?? "tool"

        switch name {
        case "PreInvocation":
            // The first model call after a stop is the start of a turn (Antigravity has no prompt event).
            if memory.openTurn(sessionID) {
                let prompt = transcriptPath.flatMap { AntigravityTranscript.lastUserRequest(at: $0) } ?? ""
                events.append(event(.promptSubmitted(text: prompt)))
            }
        case "PostInvocation":
            break   // the model call ended; a tool or a stop follows
        case "PreToolUse":
            _ = memory.openTurn(sessionID)
            let started = ToolCall(id: UUID().uuidString, name: toolName, summary: toolSummary(name: toolName, args: call["args"]), startedAt: context.receivedAt)
            toolMemory.noteStarted(session: sessionID, tool: toolName, callID: started.id)
            events.append(event(.toolStarted(started)))
            if toolName == "ask_question", let request = questionRequest(from: call["args"]) {
                events.append(event(.questionAsked(request)))
            } else if toolName == "ask_permission" {
                events.append(event(.permissionRequested(permissionRequest(from: call["args"]))))
            }
        case "PostToolUse":
            let succeeded = (payload["error"].stringValue ?? "").isEmpty
            if let startedID = toolMemory.takeStarted(session: sessionID, tool: toolName) {
                events.append(event(.toolFinished(id: startedID, name: toolName, succeeded: succeeded)))
            } else {
                // The default install has no "before tool" hook: report the call as started and finished at once.
                let started = ToolCall(id: UUID().uuidString, name: toolName, summary: toolSummary(name: toolName, args: call["args"]), startedAt: context.receivedAt)
                events.append(event(.toolStarted(started)))
                events.append(event(.toolFinished(id: started.id, name: toolName, succeeded: succeeded)))
            }
            if toolName == "write_to_file", call["args"]["IsArtifact"].boolValue == true, succeeded,
               let path = call["args"]["TargetFile"].stringValue {
                events.append(event(.notification(kind: "plan_ready", message: "Antigravity wrote \(ToolDescriptions.fileName(path)). Review it in Antigravity.")))
            }
        case "Stop":
            memory.closeTurn(sessionID)
            toolMemory.forget(session: sessionID)   // anything still "started" was denied or abandoned
            let reason = payload["terminationReason"].stringValue ?? ""
            let error = payload["error"].stringValue ?? ""
            if reason == "error" || !error.isEmpty {
                events.append(event(.turnFailed(error: error.isEmpty ? "The turn ended with an error." : ToolDescriptions.clip(error, limit: 500))))
            } else {
                var message = transcriptPath.flatMap { AntigravityTranscript.lastReply(at: $0) }
                if reason == "max_steps_exceeded" { message = "Stopped after reaching the step limit." }
                // `fullyIdle: false` means background commands are still running. A missing value means unknown.
                events.append(event(.turnFinished(lastMessage: message, backgroundWork: payload["fullyIdle"].boolValue == false)))
            }
        default:
            break   // an event name this version of Perch does not install
        }
        return events
    }

    // MARK: Which Antigravity is this?

    /// "cli", "app" or "ide", for display. The transcript's folder is the main clue; the host app's
    /// bundle id, when the hook inherited it, settles the IDE and the app.
    static func surface(transcriptPath: String?, env: [String: String]) -> String? {
        switch env["__CFBundleIdentifier"] {
        case "com.google.antigravity-ide": return "ide"
        case "com.google.antigravity": return "app"
        default: break
        }
        guard let path = transcriptPath else { return nil }
        if path.contains("/antigravity-cli/") { return "cli" }
        if path.contains("/antigravity-ide/") { return "ide" }
        if path.contains("/antigravity/") { return "app" }
        return nil
    }

    // MARK: Describing tools

    static func toolSummary(name: String, args: JSONValue) -> String {
        func file(_ key: String) -> String? { args[key].stringValue.map(ToolDescriptions.fileName) }
        switch name {
        case "run_command":
            return args["CommandLine"].stringValue.map { ToolDescriptions.oneLine($0) } ?? "Run a command"
        case "view_file":
            return file("AbsolutePath").map { "Read \($0)" } ?? "Read a file"
        case "write_to_file":
            return file("TargetFile").map { "Write \($0)" } ?? "Write a file"
        case "replace_file_content", "multi_replace_file_content":
            return file("TargetFile").map { "Edit \($0)" } ?? "Edit a file"
        case "list_dir":
            return file("DirectoryPath").map { "List \($0)" } ?? "List a folder"
        case "find_by_name":
            return args["Pattern"].stringValue.map { "Find \($0)" } ?? "Find files"
        case "grep_search":
            return args["Query"].stringValue.map { "Search for \(ToolDescriptions.oneLine($0, limit: 80))" } ?? "Search the code"
        case "search_web":
            return args["query"].stringValue.map { "Web search: \(ToolDescriptions.oneLine($0, limit: 80))" } ?? "Search the web"
        case "read_url_content":
            return args["Url"].stringValue.map { "Fetch \(ToolDescriptions.oneLine($0, limit: 100))" } ?? "Fetch a web page"
        case "ask_question":
            return "Ask you a question"
        case "ask_permission":
            return "Ask for permission"
        case "invoke_subagent":
            return "Start a helper agent"
        default:
            if name.hasPrefix("browser_") { return "Browser: " + name.dropFirst("browser_".count).replacingOccurrences(of: "_", with: " ") }
            return ToolDescriptions.keyArgument(args).map { "\(name): \($0)" } ?? name
        }
    }

    /// `ask_question` arguments: `questions[]` with `question`, `options` (plain strings) and `is_multi_select`.
    static func questionRequest(from args: JSONValue) -> QuestionRequest? {
        let questions: [Question] = (args["questions"].arrayValue ?? []).enumerated().compactMap { index, q in
            guard let text = EnvelopeReading.nonEmpty(q["question"].stringValue) else { return nil }
            let options = (q["options"].arrayValue ?? []).enumerated().compactMap { optionIndex, option -> QuestionOption? in
                guard let label = EnvelopeReading.nonEmpty(option.stringValue ?? option["label"].stringValue) else { return nil }
                return QuestionOption(id: optionIndex, label: label, detail: option["description"].stringValue)
            }
            return Question(id: index, text: text, header: nil, options: options, multiSelect: q["is_multi_select"].boolValue ?? false)
        }
        return questions.isEmpty ? nil : QuestionRequest(questions: questions)
    }

    /// `ask_permission` arguments: `Action`, `Target`, `Reason`.
    static func permissionRequest(from args: JSONValue) -> PermissionRequest {
        let target = args["Target"].stringValue ?? ""
        let action = args["Action"].stringValue
        let summary = EnvelopeReading.nonEmpty(args["Reason"].stringValue).map { ToolDescriptions.oneLine($0) }
            ?? action.map { "Antigravity asks permission for: \($0)" } ?? "Antigravity asks for permission"
        return PermissionRequest(toolName: "ask_permission", summary: summary, detail: ToolDescriptions.clip(target, limit: ToolDescriptions.detailLimit),
                                 isDangerous: action == "command" && ToolDescriptions.isDangerousCommand(target))
    }

    // MARK: Status feed (Antigravity CLI only, opt-in on the user's side)

    /// The CLI can pipe a JSON snapshot to a status line command. It is the only place Antigravity
    /// says "waiting for your confirmation", and the only credential-free source of quota and cost.
    /// The snapshot also contains the account's email address, which is never copied anywhere.
    private static func normalizeStatusFeed(_ envelope: HookEnvelope, payload: JSONValue, memory: AntigravitySessionMemory) -> [NormalizedEvent] {
        guard let sessionID = EnvelopeReading.nonEmpty(payload["conversation_id"].stringValue) ?? EnvelopeReading.nonEmpty(payload["session_id"].stringValue) else {
            return []
        }
        let cwd = payload["workspace"]["current_dir"].stringValue ?? payload["cwd"].stringValue
        let context = EnvelopeReading.context(envelope, cwd: cwd, transcriptPath: payload["transcript_path"].stringValue)
        func event(_ agentEvent: AgentEvent) -> NormalizedEvent {
            NormalizedEvent(agent: .antigravity, sessionID: sessionID, event: agentEvent, context: context, rawEventName: "StatusLine")
        }
        let model = EnvelopeReading.nonEmpty(payload["model"]["display_name"].stringValue) ?? EnvelopeReading.nonEmpty(payload["model"]["id"].stringValue)
        var events: [NormalizedEvent] = []
        if memory.isNew(sessionID) { events.append(event(.sessionStarted(title: payload["conversation_title"].stringValue, model: model, source: "cli"))) }
        // The feed repeats often with the same numbers; only changes are passed on.
        let title = EnvelopeReading.nonEmpty(payload["conversation_title"].stringValue)
        let branch = EnvelopeReading.nonEmpty(payload["vcs"]["branch"].stringValue)
        let fingerprint = [title ?? "", model ?? "", branch ?? "", payload["context_window"]["used_percentage"].serialized(),
                           payload["quota"].serialized(), payload["cost"].serialized()].joined(separator: "|")
        if memory.statusChanged(fingerprint, session: sessionID) {
            events.append(event(.metadata(title: title, model: model, gitBranch: branch, permissionMode: nil)))
            events.append(event(.usageUpdated(contextPercent: payload["context_window"]["used_percentage"].doubleValue.map { min(100, max(0, $0)) },
                                              windows: quotaWindows(payload["quota"], now: context.receivedAt),
                                              model: model, costUSD: payload["cost"].doubleValue)))
        }
        // Likewise, only the moment the "waiting" flag turns on is an event.
        if memory.setConfirmationPending(payload["tool_confirmation_pending"].boolValue == true, session: sessionID) {
            events.append(event(.notification(kind: "permission_prompt", message: "Antigravity is waiting for your approval in its terminal.")))
        }
        return events
    }

    /// `quota` is a map of bucket name → `{remaining_fraction, reset_time, reset_in_seconds}`.
    static func quotaWindows(_ quota: JSONValue, now: Date) -> [RateWindow] {
        guard let buckets = quota.objectValue else { return [] }
        return buckets.keys.sorted().compactMap { key in
            let bucket = buckets[key] ?? .null
            guard let remaining = bucket["remaining_fraction"].doubleValue else { return nil }   // disabled buckets have none
            var resetsAt = bucket["reset_time"].stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
            if resetsAt == nil, let seconds = bucket["reset_in_seconds"].doubleValue { resetsAt = now.addingTimeInterval(seconds) }
            return RateWindow(id: key, label: quotaLabel(key), usedPercent: min(100, max(0, (1 - remaining) * 100)), resetsAt: resetsAt)
        }
    }

    /// "gemini-weekly" → "Gemini weekly limit", "gemini-5h" → "Gemini 5-hour limit".
    static func quotaLabel(_ key: String) -> String {
        var words = key.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard !words.isEmpty else { return "Limit" }
        if let last = words.last, last.hasSuffix("h"), let hours = Int(last.dropLast()) { words[words.count - 1] = "\(hours)-hour" }
        words[0] = words[0].prefix(1).uppercased() + words[0].dropFirst()
        return words.joined(separator: " ") + " limit"
    }
}

/// Best-effort reader for Antigravity's transcript file. Google documents where the file is but not
/// what is in it; the four keys used here (`type`, `content`, and the `USER_INPUT` /
/// `PLANNER_RESPONSE` type names) are known only from another open-source tool. When anything does
/// not match, the answer is simply nil.
enum AntigravityTranscript {

    static func lastUserRequest(at path: String) -> String? {
        guard let content = lastContent(ofType: "USER_INPUT", at: path) else { return nil }
        // User text is wrapped as <USER_REQUEST>…</USER_REQUEST> followed by metadata blocks.
        if let open = content.range(of: "<USER_REQUEST>"), let close = content.range(of: "</USER_REQUEST>"), open.upperBound <= close.lowerBound {
            return EnvelopeReading.nonEmpty(String(content[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return EnvelopeReading.nonEmpty(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func lastReply(at path: String) -> String? {
        lastContent(ofType: "PLANNER_RESPONSE", at: path).flatMap { EnvelopeReading.nonEmpty($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { ToolDescriptions.clip($0, limit: 2000) }
    }

    private static func lastContent(ofType type: String, at path: String) -> String? {
        for line in JSONLinesTailer.tailLines(of: URL(fileURLWithPath: path)).reversed() where line.contains(type) {
            guard let record = JSONValue.parse(line), record["type"].stringValue == type else { continue }
            return record["content"].stringValue
        }
        return nil
    }
}
