// CodexHookEvents.swift — translates what Codex sends to a hook into Perch's normalized events.
//
// Codex's hook payloads look like Claude Code's: one JSON object on stdin with `session_id`,
// `hook_event_name`, and fields that depend on the event. The mapping below follows the table in
// docs/research/codex.md §5.3. Two things are worth knowing:
//
//   - Events fired inside a subagent carry the *parent* session's id plus an `agent_id`. They are
//     shown on the parent's card; a subagent's own prompt is not treated as the user's prompt.
//   - `request_user_input` (Codex asking a question) can be seen but not answered through hooks,
//     so it becomes a question the notch displays without answer buttons.
//
// The legacy `notify` program is also understood (its JSON arrives as a command-line argument),
// although Perch does not install it by default.

import Foundation

enum CodexHookEvents {

    /// Normalizes one envelope from the "hook" or "notify" channel.
    static func normalize(_ envelope: HookEnvelope) -> [NormalizedEvent] {
        if envelope.channel == "notify" { return normalizeNotify(envelope) }
        guard envelope.channel == "hook", let payload = EnvelopeReading.payloadObject(envelope) else { return [] }
        guard let sessionID = EnvelopeReading.nonEmpty(payload["session_id"].stringValue),
              let name = EnvelopeReading.nonEmpty(payload["hook_event_name"].stringValue) ?? EnvelopeReading.nonEmpty(envelope.event) else {
            return []
        }
        let context = EnvelopeReading.context(envelope, cwd: payload["cwd"].stringValue,
                                              transcriptPath: payload["transcript_path"].stringValue)
        let model = EnvelopeReading.nonEmpty(payload["model"].stringValue)
        let insideSubagent = EnvelopeReading.nonEmpty(payload["agent_id"].stringValue) != nil
        func event(_ agentEvent: AgentEvent, keepRaw: Bool = false) -> NormalizedEvent {
            NormalizedEvent(agent: .codex, sessionID: sessionID, event: agentEvent, context: context,
                            rawEventName: name, raw: keepRaw ? payload : .null)
        }

        switch name {
        case "SessionStart":
            let source = payload["source"].stringValue
            // After a compaction Codex re-runs SessionStart; that is not a new session.
            if source == "compact" {
                return [event(.metadata(title: nil, model: model, gitBranch: nil, permissionMode: payload["permission_mode"].stringValue))]
            }
            return [event(.sessionStarted(title: nil, model: model, source: source))]

        case "UserPromptSubmit":
            guard !insideSubagent, let prompt = EnvelopeReading.nonEmpty(payload["prompt"].stringValue) else { return [] }
            return [event(.promptSubmitted(text: prompt))]

        case "PreToolUse":
            let toolName = payload["tool_name"].stringValue ?? "tool"
            let input = payload["tool_input"]
            if toolName == "request_user_input", let request = questionRequest(from: input) {
                return [event(.questionAsked(request), keepRaw: true)]
            }
            let call = ToolCall(id: payload["tool_use_id"].stringValue ?? UUID().uuidString, name: toolName,
                                summary: toolSummary(name: toolName, input: input), startedAt: context.receivedAt)
            return [event(.toolStarted(call))]

        case "PostToolUse":
            let toolName = payload["tool_name"].stringValue ?? "tool"
            return [event(.toolFinished(id: payload["tool_use_id"].stringValue, name: toolName,
                                        succeeded: toolSucceeded(response: payload["tool_response"])))]

        case "PermissionRequest":
            let toolName = payload["tool_name"].stringValue ?? "tool"
            return [event(.permissionRequested(permissionRequest(toolName: toolName, input: payload["tool_input"])), keepRaw: true)]

        case "Stop":
            return [event(.turnFinished(lastMessage: EnvelopeReading.nonEmpty(payload["last_assistant_message"].stringValue),
                                        backgroundWork: false))]

        case "Interrupt":
            return [event(.turnFailed(error: "Interrupted"))]

        case "SessionEnd":
            return [event(.sessionEnded(reason: payload["reason"].stringValue))]

        case "SubagentStart":
            return [event(.subagentStarted(id: payload["agent_id"].stringValue, type: payload["agent_type"].stringValue))]

        case "SubagentStop":
            return [event(.subagentStopped(id: payload["agent_id"].stringValue))]

        case "PreCompact":
            return [event(.compactionStarted)]

        case "PostCompact":
            return [event(.compactionFinished)]

        default:
            return []   // an event from a newer Codex that Perch does not know yet
        }
    }

    // MARK: notify

    /// The legacy `notify` program gets one JSON argument; the helper forwards it in `args`.
    private static func normalizeNotify(_ envelope: HookEnvelope) -> [NormalizedEvent] {
        // The JSON is the last argument; fall back to the payload in case a wrapper piped it instead.
        let candidates = envelope.args.reversed() + [envelope.payload]
        guard let payload = candidates.lazy.compactMap({ JSONValue.parse($0) }).first(where: { $0.objectValue != nil }),
              payload["type"].stringValue == "agent-turn-complete",
              let sessionID = EnvelopeReading.nonEmpty(payload["thread-id"].stringValue) else { return [] }
        let context = EnvelopeReading.context(envelope, cwd: payload["cwd"].stringValue, transcriptPath: nil)
        let message = EnvelopeReading.nonEmpty(payload["last-assistant-message"].stringValue)
        return [NormalizedEvent(agent: .codex, sessionID: sessionID, event: .turnFinished(lastMessage: message, backgroundWork: false),
                                context: context, rawEventName: "agent-turn-complete")]
    }

    // MARK: Describing tools

    /// One line for the session card: the command, the file being patched, the MCP tool...
    static func toolSummary(name: String, input: JSONValue) -> String {
        switch name {
        case "Bash", "exec_command", "shell", "shell_command", "local_shell":
            let command = ToolDescriptions.commandText(input["command"]) ?? ToolDescriptions.commandText(input["cmd"])
            return command.map { ToolDescriptions.oneLine($0) } ?? "Run a shell command"
        case "apply_patch":
            let patch = input["command"].stringValue ?? input["input"].stringValue ?? input["patch"].stringValue ?? ""
            return ToolDescriptions.parseApplyPatch(patch).summary
        case "update_plan":
            return planSummary(input)
        case "request_user_input":
            return "Ask you a question"
        case "spawn_agent":
            return ToolDescriptions.keyArgument(input).map { "Start a helper agent: \($0)" } ?? "Start a helper agent"
        case "write_stdin":
            return "Send input to a running command"
        case "request_permissions":
            return input["reason"].stringValue.map { ToolDescriptions.oneLine($0) } ?? "Ask for more permissions"
        default:
            if let mcp = ToolDescriptions.splitMCPToolName(name) {
                let argument = ToolDescriptions.keyArgument(input).map { ": \($0)" } ?? ""
                return ToolDescriptions.clip("\(mcp.server) · \(mcp.tool)\(argument)", limit: ToolDescriptions.summaryLimit)
            }
            return ToolDescriptions.keyArgument(input).map { "\(name): \($0)" } ?? name
        }
    }

    /// "Plan: 1 of 3 done · Update it to 1.4.2".
    private static func planSummary(_ input: JSONValue) -> String {
        let steps = input["plan"].arrayValue ?? []
        guard !steps.isEmpty else { return "Update the plan" }
        let done = steps.filter { $0["status"].stringValue == "completed" }.count
        let current = steps.first(where: { $0["status"].stringValue == "in_progress" })?["step"].stringValue
        let tail = current.map { " · " + ToolDescriptions.oneLine($0, limit: 80) } ?? ""
        return "Plan: \(done) of \(steps.count) done\(tail)"
    }

    static func permissionRequest(toolName: String, input: JSONValue) -> PermissionRequest {
        let justification = EnvelopeReading.nonEmpty(input["description"].stringValue)
        switch toolName {
        case "Bash", "write_stdin":
            let command = ToolDescriptions.commandText(input["command"]) ?? input["chars"].stringValue ?? ""
            var summary = justification.map { ToolDescriptions.oneLine($0) } ?? "Run a shell command"
            // Network approvals arrive as a Bash request whose description is "network-access <target>".
            if let justification, justification.hasPrefix("network-access ") {
                summary = "Allow network access to " + justification.dropFirst("network-access ".count)
            }
            return PermissionRequest(toolName: toolName, summary: summary,
                                     detail: ToolDescriptions.clip(command, limit: ToolDescriptions.detailLimit),
                                     isDangerous: ToolDescriptions.isDangerousCommand(command))
        case "apply_patch":
            let patch = ToolDescriptions.parseApplyPatch(input["command"].stringValue ?? "")
            let paths = patch.files.map(\.path).joined(separator: "\n")
            return PermissionRequest(toolName: toolName, summary: justification.map { ToolDescriptions.oneLine($0) } ?? patch.summary,
                                     detail: paths.isEmpty ? "Apply a patch" : paths, diff: patch.diff.lines.isEmpty ? nil : patch.diff)
        case "request_permissions":
            return PermissionRequest(toolName: toolName,
                                     summary: input["reason"].stringValue.map { ToolDescriptions.oneLine($0) } ?? "Codex asks for more permissions",
                                     detail: ToolDescriptions.clip(input["permissions"].serialized(pretty: true), limit: ToolDescriptions.detailLimit))
        default:
            let summary: String
            if let mcp = ToolDescriptions.splitMCPToolName(toolName) {
                summary = "Use \(mcp.tool) from \(mcp.server)"
            } else {
                summary = justification.map { ToolDescriptions.oneLine($0) } ?? "Use \(toolName)"
            }
            let detail = input.isNull ? "" : input.serialized(pretty: true)
            return PermissionRequest(toolName: toolName, summary: summary, detail: ToolDescriptions.clip(detail, limit: ToolDescriptions.detailLimit))
        }
    }

    /// `{questions:[{id, header, question, options:[{label, description}]}]}` → QuestionRequest.
    static func questionRequest(from input: JSONValue) -> QuestionRequest? {
        let questions: [Question] = (input["questions"].arrayValue ?? []).enumerated().compactMap { index, q in
            guard let text = EnvelopeReading.nonEmpty(q["question"].stringValue) else { return nil }
            let options = (q["options"].arrayValue ?? []).enumerated().compactMap { optionIndex, option -> QuestionOption? in
                guard let label = EnvelopeReading.nonEmpty(option["label"].stringValue) else { return nil }
                return QuestionOption(id: optionIndex, label: label, detail: EnvelopeReading.nonEmpty(option["description"].stringValue))
            }
            return Question(id: index, text: text, header: EnvelopeReading.nonEmpty(q["header"].stringValue), options: options, multiSelect: false)
        }
        return questions.isEmpty ? nil : QuestionRequest(questions: questions)
    }

    /// Codex only fires PostToolUse when the tool handler itself worked, but a shell command may
    /// still have failed. Its output then starts with "Exit code: N".
    static func toolSucceeded(response: JSONValue) -> Bool {
        guard let text = response.stringValue ?? response["output"].stringValue, text.hasPrefix("Exit code: ") else { return true }
        let code = text.dropFirst("Exit code: ".count).prefix(while: { $0.isNumber || $0 == "-" })
        return Int(code).map { $0 == 0 } ?? true
    }

    // MARK: Decisions

    /// The exact stdout Codex expects from a PermissionRequest hook (docs/research/codex.md §2.1).
    /// Codex has no "always allow" through hooks, so that choice allows this one call.
    static func encode(_ decision: Decision, for request: PendingRequest) -> HookReply {
        guard case .permission = request.kind else { return .passthrough }
        var behavior: [String: JSONValue]
        switch decision {
        case .allow, .allowAlways:
            behavior = ["behavior": "allow"]
        case .deny(let message):
            behavior = ["behavior": "deny"]
            if let message = EnvelopeReading.nonEmpty(message) { behavior["message"] = .string(message) }
        case .answer, .approvePlan, .rejectPlan, .passToTerminal:
            return .passthrough
        }
        let output: JSONValue = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": .object(behavior)]]
        return HookReply(stdout: output.serialized(), exitCode: 0)
    }
}
