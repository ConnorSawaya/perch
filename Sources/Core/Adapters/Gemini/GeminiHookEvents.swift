// GeminiHookEvents.swift — translates Gemini CLI hook payloads into Perch's normalized events.
//
// Gemini CLI's hooks resemble Claude Code's: JSON on stdin with `session_id`, `hook_event_name`,
// `cwd`, `transcript_path`. The mapping follows docs/research/antigravity.md §10.2.
//
// The interesting one is `Notification` with type "ToolPermission": Gemini CLI fires it just before
// showing its own confirmation prompt. Perch shows what is being asked, but no hook can answer
// for the user, so the request is display-only.

import Foundation

enum GeminiHookEvents {

    static func normalize(_ envelope: HookEnvelope, toolMemory: ToolStartMemory) -> [NormalizedEvent] {
        guard envelope.channel == "hook", let payload = EnvelopeReading.payloadObject(envelope),
              let sessionID = EnvelopeReading.nonEmpty(payload["session_id"].stringValue),
              let name = EnvelopeReading.nonEmpty(payload["hook_event_name"].stringValue) ?? EnvelopeReading.nonEmpty(envelope.event) else {
            return []
        }
        let context = EnvelopeReading.context(envelope, cwd: payload["cwd"].stringValue, transcriptPath: payload["transcript_path"].stringValue)
        func event(_ agentEvent: AgentEvent, raw: JSONValue = .null) -> NormalizedEvent {
            NormalizedEvent(agent: .gemini, sessionID: sessionID, event: agentEvent, context: context, rawEventName: name, raw: raw)
        }

        switch name {
        case "SessionStart":
            return [event(.sessionStarted(title: nil, model: nil, source: payload["source"].stringValue))]
        case "SessionEnd":
            toolMemory.forget(session: sessionID)
            return [event(.sessionEnded(reason: payload["reason"].stringValue))]
        case "BeforeAgent":
            guard let prompt = EnvelopeReading.nonEmpty(payload["prompt"].stringValue) else { return [] }
            return [event(.promptSubmitted(text: prompt))]
        case "AfterAgent":
            return [event(.turnFinished(lastMessage: EnvelopeReading.nonEmpty(payload["prompt_response"].stringValue), backgroundWork: false))]
        case "BeforeTool":
            let call = toolCall(payload, at: context.receivedAt)
            toolMemory.noteStarted(session: sessionID, tool: call.name, callID: call.id)
            return [event(.toolStarted(call))]
        case "AfterTool":
            let toolName = payload["tool_name"].stringValue ?? "tool"
            let succeeded = payload["tool_response"]["error"].isNull
            if let startedID = toolMemory.takeStarted(session: sessionID, tool: toolName) {
                return [event(.toolFinished(id: startedID, name: toolName, succeeded: succeeded))]
            }
            // No "before" hook is installed by default: report the call as started and finished at once.
            let call = toolCall(payload, at: context.receivedAt)
            return [event(.toolStarted(call)), event(.toolFinished(id: call.id, name: toolName, succeeded: succeeded))]
        case "Notification":
            let type = payload["notification_type"].stringValue ?? "notification"
            let message = payload["message"].stringValue ?? ""
            guard type == "ToolPermission" else { return [event(.notification(kind: type, message: message))] }
            // The details can hold whole files (before and after an edit); they are not kept.
            return [event(.permissionRequested(permissionRequest(details: payload["details"], message: message)))]
        case "PreCompress":
            return [event(.compactionStarted)]
        default:
            return []   // BeforeModel, AfterModel, BeforeToolSelection and anything newer: nothing to show
        }
    }

    private static func toolCall(_ payload: JSONValue, at date: Date) -> ToolCall {
        let name = payload["tool_name"].stringValue ?? "tool"
        return ToolCall(id: UUID().uuidString, name: name, summary: toolSummary(name: name, input: payload["tool_input"]), startedAt: date)
    }

    static func toolSummary(name: String, input: JSONValue) -> String {
        let path = input["file_path"].stringValue ?? input["absolute_path"].stringValue ?? input["path"].stringValue
        switch name {
        case "run_shell_command":
            return input["command"].stringValue.map { ToolDescriptions.oneLine($0) } ?? "Run a shell command"
        case "write_file":
            return path.map { "Write \(ToolDescriptions.fileName($0))" } ?? "Write a file"
        case "replace", "edit":
            return path.map { "Edit \(ToolDescriptions.fileName($0))" } ?? "Edit a file"
        case "read_file", "read_many_files":
            return path.map { "Read \(ToolDescriptions.fileName($0))" } ?? "Read files"
        default:
            if let mcp = ToolDescriptions.splitMCPToolName(name) { return "\(mcp.server) · \(mcp.tool)" }
            return ToolDescriptions.keyArgument(input).map { "\(name): \($0)" } ?? name
        }
    }

    /// `details.type` is "exec", "edit", "mcp" or "info".
    static func permissionRequest(details: JSONValue, message: String) -> PermissionRequest {
        let title = EnvelopeReading.nonEmpty(details["title"].stringValue)
        switch details["type"].stringValue {
        case "exec":
            let command = details["command"].stringValue ?? details["rootCommand"].stringValue ?? ""
            return PermissionRequest(toolName: "run_shell_command", summary: title ?? "Run a shell command",
                                     detail: ToolDescriptions.clip(command, limit: ToolDescriptions.detailLimit),
                                     isDangerous: ToolDescriptions.isDangerousCommand(command))
        case "edit":
            let path = details["filePath"].stringValue ?? details["fileName"].stringValue
            let diff = details["fileDiff"].stringValue.map { ToolDescriptions.parseUnifiedDiff($0, filePath: path) }
            return PermissionRequest(toolName: "edit", summary: title ?? "Edit a file", detail: path ?? "",
                                     diff: (diff?.lines.isEmpty ?? true) ? nil : diff)
        case "mcp":
            let server = details["serverName"].stringValue ?? "a server"
            let tool = details["toolName"].stringValue ?? details["toolDisplayName"].stringValue ?? "a tool"
            return PermissionRequest(toolName: tool, summary: title ?? "Use \(tool) from \(server)", detail: "\(server) · \(tool)")
        default:
            return PermissionRequest(toolName: "tool", summary: title ?? "Gemini CLI is asking for confirmation",
                                     detail: ToolDescriptions.clip(details["prompt"].stringValue ?? message, limit: ToolDescriptions.detailLimit))
        }
    }
}
