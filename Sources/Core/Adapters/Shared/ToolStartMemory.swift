// ToolStartMemory.swift — remembers which tool calls were already announced as "started".
//
// Antigravity and Gemini CLI are set up, by default, without a "before the tool runs" hook (that
// hook is the risky one in both). Perch then only hears about a tool when it has finished. So that
// the tool still shows up in a session's activity, the adapters report such a call as "started and
// finished" in one go. When a "before" hook *is* installed, this memory stops the start from being
// reported twice.

import Foundation

final class ToolStartMemory {
    /// session → tool name → ids of calls that started and have not finished, oldest first.
    private var startedIDs: [String: [String: [String]]] = [:]
    private let maxSessions = 64
    private let maxPerSession = 32

    /// Records that a call of `tool` was announced with `callID`.
    func noteStarted(session: String, tool: String, callID: String) {
        if startedIDs.count >= maxSessions, startedIDs[session] == nil { startedIDs.removeAll() }
        var calls = startedIDs[session] ?? [:]
        // Starts whose finish never arrives (denied or aborted calls) must not pile up.
        if calls.values.reduce(0, { $0 + $1.count }) >= maxPerSession { calls.removeAll() }
        calls[tool, default: []].append(callID)
        startedIDs[session] = calls
    }

    /// The id of the oldest unfinished call of `tool`, forgetting it. Nil when no start was reported.
    /// (Agents do not give a call id that links "before" to "after", so calls of the same tool are
    /// matched in the order they started.)
    func takeStarted(session: String, tool: String) -> String? {
        guard var ids = startedIDs[session]?[tool], !ids.isEmpty else { return nil }
        let id = ids.removeFirst()
        startedIDs[session]?[tool] = ids.isEmpty ? nil : ids
        return id
    }

    func forget(session: String) {
        startedIDs[session] = nil
    }
}
