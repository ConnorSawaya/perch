// RawHints.swift — the two facts the engine reads straight from an event's original payload.
//
// Normalized events have no field for "which subagent sent this" or "what exactly was the tool's
// input", yet both are needed to match a permission request to its tool call safely (see
// RequestCorrelation.swift). Until the shared event type carries them, the engine looks for them
// in the raw payload under the names the supported agents use. Everything here is best effort:
// a payload without these fields simply gives "main conversation" and "input unknown".

import Foundation

enum RawHints {
    private static let scopeKeys = ["agent_id", "agentId", "subagent_id", "subagentId"]
    private static let inputKeys = ["tool_input", "toolInput", "input", "arguments", "args"]
    private static let toolNameKeys = ["tool_name", "toolName"]

    /// Which subagent an event belongs to; "" means the main conversation.
    static func scope(_ raw: JSONValue) -> String {
        for key in scopeKeys {
            if let id = raw[key].stringValue, !id.isEmpty { return id }
        }
        return ""
    }

    /// A fingerprint of the tool input, or nil when the payload has none. Two payloads describing
    /// the same tool call (a PreToolUse and its PermissionRequest) give the same fingerprint.
    static func inputKey(_ raw: JSONValue) -> Int? {
        for key in inputKeys where !raw[key].isNull { return raw[key].hashValue }
        // Antigravity nests the call: {"toolCall": {"name": ..., "args": {...}}}.
        let nested = raw["toolCall"]["args"]
        return nested.isNull ? nil : nested.hashValue
    }

    /// The tool a question or plan request came from, when the payload names it.
    static func toolName(_ raw: JSONValue) -> String? {
        for key in toolNameKeys {
            if let name = raw[key].stringValue, !name.isEmpty { return name }
        }
        if let name = raw["toolCall"]["name"].stringValue, !name.isEmpty { return name }
        return nil
    }
}
