// ClaudeDecisionEncoder.swift — writes the answer Claude Code expects from a PermissionRequest hook.
//
// When the user decides in the notch, the waiting `perch-hook` helper must print one line of
// JSON on standard output and exit 0. The exact shapes below were each proven against Claude
// Code 2.1.296 (docs/research/claude-hooks-live.md §3–§5; the captured outputs are in
// Fixtures/claude/decisions). The facts that shape this file:
//
//   - allow:                 {"behavior":"allow"}
//   - deny:                  {"behavior":"deny","message":"..."} — the model reads the message as
//                            the tool's error text, so it states what the user decided and does
//                            not give orders
//   - always allow:          allow + "updatedPermissions": [the chosen suggestion, unchanged]
//   - answer a question:     allow + "updatedInput": the original input plus "answers"
//                            (question text → chosen label; several labels joined with ", ")
//   - approve a plan:        allow + "updatedInput": the original input, unchanged. A bare allow
//                            is silently ignored for plans and questions.
//   - approve + accept edits: the same plus a session-only "setMode acceptEdits"
//   - "no opinion":          print nothing; Claude Code carries on with its own prompt

import Foundation

enum ClaudeDecisionEncoder {
    static let defaultDenyMessage = "The user denied this request in Perch."
    static let defaultPlanRejection = "The user rejected this plan in Perch."
    /// Switches the session to "accept edits" without writing anything to disk.
    static let acceptEditsForSession: JSONValue = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]

    static func reply(for decision: Decision, request: PendingRequest) -> HookReply {
        // Only PermissionRequest hooks wait for an answer. Anything else has no one to tell.
        guard request.raw["hook_event_name"].stringValue == "PermissionRequest" else { return .passthrough }
        let tool = request.raw["tool_name"].stringValue ?? ""
        let input = request.raw["tool_input"]
        // A plan is only approved when its input is sent back; other tools need no echo.
        // (Spelled with .some/.none because a bare `nil` would mean JSON null for this type.)
        let echo: JSONValue? = tool == ClaudeRequestBuilder.planTool ? .some(input) : .none

        switch decision {
        case .passToTerminal:
            return .passthrough

        case .allow:
            // "Allow" cannot answer a question; step aside so the terminal asks it.
            if tool == ClaudeRequestBuilder.questionTool { return .passthrough }
            return allow(echoing: echo)

        case .allowAlways(let suggestionID):
            if tool == ClaudeRequestBuilder.questionTool { return .passthrough }
            guard case .permission(let permission) = request.kind,
                  let chosen = permission.suggestions.first(where: { $0.id == suggestionID }) else {
                return allow(echoing: echo)
            }
            return allow(echoing: echo, permissions: [chosen.raw])

        case .deny(let message):
            return deny(message, fallback: defaultDenyMessage)

        case .answer(let answers):
            guard tool == ClaudeRequestBuilder.questionTool, var updated = input.objectValue, !answers.isEmpty else { return .passthrough }
            // updatedInput replaces the whole input, so the questions go back exactly as they came.
            updated["answers"] = .object(answers.mapValues { JSONValue.string($0) })
            return allow(echoing: .object(updated))

        case .approvePlan(let acceptEdits):
            if tool == ClaudeRequestBuilder.questionTool { return .passthrough }
            return allow(echoing: echo, permissions: acceptEdits ? [acceptEditsForSession] : [])

        case .rejectPlan(let feedback):
            return deny(feedback, fallback: defaultPlanRejection)
        }
    }

    // MARK: - Building the JSON

    private static func allow(echoing input: JSONValue?, permissions: [JSONValue] = []) -> HookReply {
        var decision: [String: JSONValue] = ["behavior": "allow"]
        if let input {
            // A plan can only be approved by sending its input back; without one we cannot approve.
            guard input.objectValue != nil else { return .passthrough }
            decision["updatedInput"] = input
        }
        if !permissions.isEmpty { decision["updatedPermissions"] = .array(permissions) }
        return reply(decision)
    }

    private static func deny(_ message: String?, fallback: String) -> HookReply {
        let trimmed = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return reply(["behavior": "deny", "message": .string(trimmed.isEmpty ? fallback : trimmed)])
    }

    private static func reply(_ decision: [String: JSONValue]) -> HookReply {
        let output: JSONValue = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": .object(decision)]]
        return HookReply(stdout: output.serialized(), exitCode: 0)
    }
}
