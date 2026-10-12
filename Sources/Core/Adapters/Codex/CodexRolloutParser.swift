// CodexRolloutParser.swift — reads one Codex session file ("rollout") line by line.
//
// Codex appends a JSON line to `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl` for most things
// that happen in a session. This parser turns those lines into Perch events. It is what makes
// usage and rate limits work (they only exist in these files), reports turns that ended with an
// error (hooks have no event for that), and stands in for hooks entirely when hooks are missing,
// switched off or not yet trusted.
//
// Codex calls this format "not a stable interface", and there are two layouts in the wild
// ("legacy" and "paginated"). So every field is optional here, unknown lines are skipped, and
// nothing in this file can fail. Approval prompts and questions are never written to these
// files; only hooks can see those.
//
// One parser follows one file and is used from one queue.

import Foundation

/// An event read from a rollout file.
struct CodexRolloutEvent: Equatable {
    var event: NormalizedEvent
    /// False for events that hooks also report (prompts, tools, normal turn ends). The adapter drops
    /// those for sessions it is already hearing from through hooks, so nothing is counted twice.
    var neededEvenWithHooks: Bool
}

final class CodexRolloutParser {
    let fileURL: URL
    /// The id shared by a session and its subagents; what hooks call `session_id`.
    private(set) var sessionID: String?
    private(set) var cwd: String?
    private(set) var model: String?
    private(set) var gitBranch: String?
    /// "user" or "auto_review": who answers approval prompts in the current turn.
    private(set) var approvalsReviewer: String?
    /// True when this file belongs to a subagent thread rather than the session the user started.
    private(set) var isSubagentThread = false
    private var title: String?
    private var contextWindow: Double?
    private var announcedSession = false
    private var toolNamesByCallID: [String: String] = [:]
    private var lastUsageFingerprint: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: Starting on a file that already has content

    /// Reads the header (and the recent tail) of a file whose earlier lines will not be replayed, so
    /// that later lines can be attributed correctly. With `announce` (the file was active moments
    /// ago) it also returns a "session exists" event and the latest usage numbers.
    func prime(announce: Bool, threadNames: [String: String] = [:]) -> [CodexRolloutEvent] {
        if let header = JSONLinesTailer.firstLine(of: fileURL).flatMap(JSONValue.parse), header["type"].stringValue == "session_meta" {
            readSessionMeta(header["payload"])
        }
        if let id = sessionID, let name = threadNames[id] { title = name }
        var latestUsage: CodexRolloutEvent?
        for line in JSONLinesTailer.tailLines(of: fileURL) {
            guard let value = JSONValue.parse(line) else { continue }
            let payload = value["payload"]
            switch (value["type"].stringValue, payload["type"].stringValue) {
            case ("turn_context", _): readTurnContext(payload)
            case ("event_msg", "task_started"), ("event_msg", "turn_started"): readTaskStarted(payload)
            case ("event_msg", "token_count"):
                lastUsageFingerprint = nil
                latestUsage = usageEvent(payload, at: lineDate(value)) ?? latestUsage
            default: break
            }
        }
        guard announce, sessionID != nil else { return [] }
        return sessionStartIfNeeded(at: Date(), source: "resume") + [latestUsage].compactMap { $0 }
    }

    // MARK: New lines

    func parse(lines: [String]) -> [CodexRolloutEvent] {
        var out: [CodexRolloutEvent] = []
        for line in lines {
            guard let value = JSONValue.parse(line), value.objectValue != nil else { continue }
            out.append(contentsOf: parse(value))
        }
        return out
    }

    private func parse(_ line: JSONValue) -> [CodexRolloutEvent] {
        let payload = line["payload"]
        let date = lineDate(line)
        switch line["type"].stringValue {
        case "session_meta":
            readSessionMeta(payload)
            return sessionStartIfNeeded(at: date, source: "startup")
        case "turn_context":
            let before = model
            readTurnContext(payload)
            guard model != before, let model else { return [] }
            return wrap(.metadata(title: nil, model: model, gitBranch: gitBranch, permissionMode: nil), "turn_context", date, always: true)
        case "response_item":
            return parseResponseItem(payload, date)
        case "event_msg":
            return parseEventMessage(payload, date)
        default:
            return []
        }
    }

    private func parseEventMessage(_ payload: JSONValue, _ date: Date) -> [CodexRolloutEvent] {
        let type = payload["type"].stringValue ?? ""
        switch type {
        case "task_started", "turn_started":
            readTaskStarted(payload)
            return []
        case "user_message":                                   // legacy layout
            return prompt(payload["message"].stringValue, type, date)
        case "item_completed":                                 // paginated layout
            let item = payload["item"]
            guard item["type"].stringValue == "UserMessage" else { return [] }
            let text = (item["content"].arrayValue ?? []).compactMap { $0["text"].stringValue }.joined(separator: "\n")
            return prompt(text, type, date)
        case "task_complete", "turn_complete":
            let error = payload["error"]
            if !error.isNull {
                let message = error["message"].stringValue ?? error.stringValue ?? "The turn ended with an error."
                return wrap(.turnFailed(error: ToolDescriptions.clip(message, limit: 500)), type, date, always: true)
            }
            guard !isSubagentThread else { return [] }
            return wrap(.turnFinished(lastMessage: EnvelopeReading.nonEmpty(payload["last_agent_message"].stringValue), backgroundWork: false),
                        type, date, always: false)
        case "turn_aborted":
            let reason = payload["reason"].stringValue ?? "aborted"
            // A user interrupt is also reported by the Interrupt hook; the other reasons are not.
            return wrap(.turnFailed(error: CodexRolloutParser.abortDescription(reason)), type, date, always: reason != "interrupted")
        case "token_count":
            return [usageEvent(payload, at: date)].compactMap { $0 }
        default:
            return []
        }
    }

    private func parseResponseItem(_ payload: JSONValue, _ date: Date) -> [CodexRolloutEvent] {
        let type = payload["type"].stringValue ?? ""
        switch type {
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = payload["name"].stringValue ?? (type == "local_shell_call" ? "shell" : "tool")
            let callID = payload["call_id"].stringValue ?? UUID().uuidString
            // Arguments are a JSON string for function calls and raw text (the patch) for custom tools.
            var input = payload["input"].isNull ? payload["arguments"] : payload["input"]
            if let text = input.stringValue {
                input = JSONValue.parse(text).flatMap { $0.objectValue != nil ? $0 : nil } ?? ["command": .string(text)]
            }
            if type == "local_shell_call" { input = payload["action"] }
            remember(callID: callID, name: name)
            let call = ToolCall(id: callID, name: CodexRolloutParser.displayName(name),
                                summary: CodexHookEvents.toolSummary(name: name, input: input), startedAt: date)
            return wrap(.toolStarted(call), type, date, always: false)
        case "function_call_output", "custom_tool_call_output":
            guard let callID = payload["call_id"].stringValue else { return [] }
            let name = toolNamesByCallID.removeValue(forKey: callID) ?? "tool"
            let output = payload["output"]
            return wrap(.toolFinished(id: callID, name: CodexRolloutParser.displayName(name),
                                      succeeded: CodexHookEvents.toolSucceeded(response: output)), type, date, always: false)
        default:
            return []
        }
    }

    // MARK: Pieces

    private func readSessionMeta(_ payload: JSONValue) {
        let threadID = payload["id"].stringValue
        // Older files have no `session_id`; the thread id is then the session id (Codex does the same).
        sessionID = EnvelopeReading.nonEmpty(payload["session_id"].stringValue) ?? EnvelopeReading.nonEmpty(threadID) ?? sessionID
        cwd = EnvelopeReading.nonEmpty(payload["cwd"].stringValue) ?? cwd
        gitBranch = EnvelopeReading.nonEmpty(payload["git"]["branch"].stringValue) ?? gitBranch
        let hasParent = EnvelopeReading.nonEmpty(payload["parent_thread_id"].stringValue) != nil
        let differsFromRoot = threadID != nil && sessionID != nil && threadID != sessionID
        isSubagentThread = hasParent || differsFromRoot || payload["source"]["subagent"].isNull == false
    }

    private func readTurnContext(_ payload: JSONValue) {
        model = EnvelopeReading.nonEmpty(payload["model"].stringValue) ?? model
        cwd = EnvelopeReading.nonEmpty(payload["cwd"].stringValue) ?? cwd
        approvalsReviewer = EnvelopeReading.nonEmpty(payload["approvals_reviewer"].stringValue) ?? approvalsReviewer
    }

    private func readTaskStarted(_ payload: JSONValue) {
        if let window = payload["model_context_window"].doubleValue, window > 0 { contextWindow = window }
    }

    private func prompt(_ text: String?, _ rawName: String, _ date: Date) -> [CodexRolloutEvent] {
        guard !isSubagentThread, let text = EnvelopeReading.nonEmpty(text) else { return [] }
        return wrap(.promptSubmitted(text: text), rawName, date, always: false)
    }

    /// The first event of a session Perch has not announced yet is preceded by `sessionStarted`.
    private func sessionStartIfNeeded(at date: Date, source: String) -> [CodexRolloutEvent] {
        guard !announcedSession, !isSubagentThread, let sessionID else { return [] }
        announcedSession = true
        let start = NormalizedEvent(agent: .codex, sessionID: sessionID,
                                    event: .sessionStarted(title: title, model: model, source: source),
                                    context: context(at: date), rawEventName: "session_meta")
        var events = [CodexRolloutEvent(event: start, neededEvenWithHooks: false)]
        if let gitBranch {
            let meta = NormalizedEvent(agent: .codex, sessionID: sessionID,
                                       event: .metadata(title: nil, model: nil, gitBranch: gitBranch, permissionMode: nil),
                                       context: context(at: date), rawEventName: "session_meta")
            events.append(CodexRolloutEvent(event: meta, neededEvenWithHooks: true))
        }
        return events
    }

    private func wrap(_ agentEvent: AgentEvent, _ rawName: String, _ date: Date, always: Bool) -> [CodexRolloutEvent] {
        guard let sessionID else { return [] }
        let event = NormalizedEvent(agent: .codex, sessionID: sessionID, event: agentEvent, context: context(at: date), rawEventName: rawName)
        return sessionStartIfNeeded(at: date, source: "startup") + [CodexRolloutEvent(event: event, neededEvenWithHooks: always)]
    }

    private func context(at date: Date) -> EventContext {
        // No pid or terminal: a file cannot say which process wrote it.
        EventContext(pid: nil, tty: nil, cwd: cwd, env: [:], transcriptPath: fileURL.path, receivedAt: date)
    }

    private func remember(callID: String, name: String) {
        // A call whose result never arrives must not be remembered forever.
        if toolNamesByCallID.count > 256 { toolNamesByCallID.removeAll() }
        toolNamesByCallID[callID] = name
    }

    /// Hooks call the shell tool "Bash"; rollouts use its internal names. Show one name for both.
    private static func displayName(_ name: String) -> String {
        ["exec_command", "shell", "shell_command", "local_shell"].contains(name) ? "Bash" : name
    }

    private static func abortDescription(_ reason: String) -> String {
        switch reason {
        case "interrupted": return "Interrupted"
        case "replaced": return "The turn was replaced by a newer one."
        case "review_ended": return "The review ended."
        case "budget_limited": return "Stopped: the usage budget was reached."
        default: return "The turn was stopped (\(reason))."
        }
    }

    // MARK: Usage

    private func usageEvent(_ payload: JSONValue, at date: Date) -> CodexRolloutEvent? {
        guard let sessionID else { return nil }
        let info = payload["info"], limits = payload["rate_limits"]
        guard !info.isNull || !limits.isNull else { return nil }
        // Codex repeats identical records; only a change is worth an event.
        let fingerprint = info["total_token_usage"].serialized() + limits.serialized()
        guard fingerprint != lastUsageFingerprint else { return nil }
        lastUsageFingerprint = fingerprint

        if let window = info["model_context_window"].doubleValue, window > 0 { contextWindow = window }
        var contextPercent: Double?
        // The latest response's size against the model's window: an estimate of how full the context is.
        if let window = contextWindow, let used = info["last_token_usage"]["total_tokens"].doubleValue {
            contextPercent = min(100, max(0, used / window * 100))
        }
        let windows = CodexRolloutParser.rateWindows(from: limits, lineDate: date, now: Date())
        let event = NormalizedEvent(agent: .codex, sessionID: sessionID,
                                    event: .usageUpdated(contextPercent: contextPercent, windows: windows, model: model, costUSD: nil),
                                    context: context(at: date), rawEventName: "token_count", raw: payload)
        return CodexRolloutEvent(event: event, neededEvenWithHooks: true)
    }

    /// Turns Codex's rate-limit snapshot into display windows. `used_percent` is "consumed", 0-100.
    static func rateWindows(from limits: JSONValue, lineDate: Date, now: Date) -> [RateWindow] {
        guard limits.objectValue != nil else { return [] }
        let limitID = EnvelopeReading.nonEmpty(limits["limit_id"].stringValue) ?? "codex"
        let limitName = EnvelopeReading.nonEmpty(limits["limit_name"].stringValue)
        return ["primary", "secondary"].compactMap { slot in
            let window = limits[slot]
            guard let used = window["used_percent"].doubleValue else { return nil }
            var resetsAt = window["resets_at"].doubleValue.map { Date(timeIntervalSince1970: $0) }
            // Codex up to 0.47 wrote seconds-from-now instead of a timestamp.
            if resetsAt == nil, let seconds = window["resets_in_seconds"].doubleValue { resetsAt = lineDate.addingTimeInterval(seconds) }
            var usedPercent = min(100, max(0, used))
            // The snapshot is as old as Codex's last reply. Once the reset time has passed the window is empty again.
            if let reset = resetsAt, reset <= now {
                usedPercent = 0
                resetsAt = nil
            }
            var label = windowLabel(minutes: window["window_minutes"].doubleValue, slot: slot)
            if let limitName { label = "\(limitName) · \(label)" }
            // The main limit keeps the short ids; extra metered limits are told apart by their own id.
            let id = limitID == "codex" ? slot : "\(limitID).\(slot)"
            return RateWindow(id: id, label: label, usedPercent: usedPercent, resetsAt: resetsAt)
        }
    }

    static func windowLabel(minutes: Double?, slot: String) -> String {
        guard let minutes, minutes > 0 else { return slot == "primary" ? "Short-term limit" : "Long-term limit" }
        if minutes == 10_080 { return "Weekly limit" }
        if minutes < 60 { return "\(Int(minutes))-minute limit" }
        if minutes < 24 * 60 || minutes.truncatingRemainder(dividingBy: 24 * 60) != 0 {
            let hours = minutes / 60
            return hours == hours.rounded() ? "\(Int(hours))-hour limit" : String(format: "%.1f-hour limit", hours)
        }
        return "\(Int(minutes / (24 * 60)))-day limit"
    }

    // MARK: Time

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    private func lineDate(_ line: JSONValue) -> Date {
        guard let text = line["timestamp"].stringValue else { return Date() }
        return CodexRolloutParser.fractionalFormatter.date(from: text) ?? CodexRolloutParser.plainFormatter.date(from: text) ?? Date()
    }
}
