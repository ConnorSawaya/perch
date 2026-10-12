// RequestCorrelation.swift — the rules for matching a request to a tool call, and for noticing
// that a request was settled somewhere else.
//
// WHY THIS IS NEEDED
// While a permission hook waits for Perch, the agent shows its own prompt in the terminal too,
// and whichever answers first wins. Live experiments with Claude Code showed:
//   - the user ACCEPTS in the terminal: the hook is left running and gets no signal at all;
//   - the user presses Esc: the hook is killed (Perch sees the helper disconnect);
//   - the request payload carries no tool-use id, so it cannot simply be looked up.
// So a card must also go away when later events prove the agent has moved on. The engine never
// answers allow or deny because of such a conclusion: it only closes the helper's connection,
// which means "no opinion" and is harmless even when the conclusion was wrong.
//
// THE RULES (each one only looks at requests of the same session)
//   Linking. When a request arrives it is linked to a tool call that has started and not
//     finished, in the same subagent scope, with the same tool name, that no other request has
//     claimed. A call with exactly the same input is preferred (that alone is enough, even if
//     the name is spelled differently); otherwise the newest one of that name (a request always
//     follows its own "tool started" directly).
//   1. Tool finished. If the finished call is the one a request is linked to, the request is
//      withdrawn (the tool ran, so somebody allowed it). A finished call that is known and NOT
//      linked to any request is a parallel sibling that needed no permission: nothing happens.
//      A finished call Perch never saw start withdraws the oldest unlinked request for that tool.
//   2. A new prompt withdraws every request of the session (no prompt can be typed while a
//      dialog is open).
//   3. Turn finished / failed withdraws the requests of that scope.
//   4. Session ended, restarted or its process died: every request is withdrawn.
//   5. Another tool started in the same scope. Parallel tool calls announce themselves together,
//      within moments of each other, so a tool that starts within `EngineTuning.parallelWindow`
//      seconds of the request changes nothing. One that starts later can only mean the model got
//      an answer and went on (this is how a "No" typed in the terminal shows up: a refused tool
//      never reports "finished"), so the requests of that scope are withdrawn.
//   6. Subagent stopped: its requests are withdrawn.
//   7. "Waiting for your next prompt" (the idle notification) withdraws display-only requests,
//      which have no helper connection to tell them the turn is over.
// Events from another subagent scope never withdraw anything: subagents run side by side and
// share the parent's session id.

import Foundation

enum RequestCorrelation {
    /// The open tool call a new request is about, or nil when none fits.
    static func link(toolName: String?, inputKey: Int?, scope: String,
                     openTools: [OpenTool], requests: [TrackedRequest]) -> OpenTool? {
        let claimed = Set(requests.compactMap { $0.toolUseID })
        let free = openTools.filter { $0.scope == scope && !claimed.contains($0.id) }
        let sameName = free.filter { toolName == nil || sameTool($0.name, toolName) }
        if let inputKey {
            if let exact = sameName.last(where: { $0.inputKey == inputKey }) { return exact }
            // Identical input identifies the call even when the two events spell the tool's name differently.
            if let exact = free.last(where: { $0.inputKey == inputKey }) { return exact }
        }
        return sameName.last
    }

    /// The outcome of a "tool finished" event: which open call it closes and which request (if any) it settles.
    struct Finished: Equatable {
        var openToolID: String?
        var withdrawRequestID: UUID?
    }

    /// Rule 1. `requests` and `openTools` belong to the session the event is for.
    static func toolFinished(id: String?, name: String, scope: String,
                             openTools: [OpenTool], requests: [TrackedRequest]) -> Finished {
        if let id {
            if let request = requests.first(where: { $0.toolUseID == id }) {
                return Finished(openToolID: id, withdrawRequestID: request.id)
            }
            if openTools.contains(where: { $0.id == id }) {
                return Finished(openToolID: id, withdrawRequestID: nil)
            }
            return Finished(openToolID: nil, withdrawRequestID: unlinkedRequest(for: name, scope: scope, in: requests)?.id)
        }
        // No id to go by: use the name. A call that is waiting on a request cannot finish before
        // one that is not, so prefer an unclaimed call.
        let claimed = Set(requests.compactMap { $0.toolUseID })
        let candidates = openTools.filter { $0.scope == scope && sameTool($0.name, name) }
        if let free = candidates.first(where: { !claimed.contains($0.id) }) {
            return Finished(openToolID: free.id, withdrawRequestID: nil)
        }
        if let waiting = candidates.first {
            return Finished(openToolID: waiting.id, withdrawRequestID: requests.first { $0.toolUseID == waiting.id }?.id)
        }
        return Finished(openToolID: nil, withdrawRequestID: unlinkedRequest(for: name, scope: scope, in: requests)?.id)
    }

    /// Rule 5: the requests a newly started tool proves to be over.
    static func superseded(by tool: OpenTool, at now: Date, requests: [TrackedRequest]) -> [UUID] {
        requests.filter { request in
            request.scope == tool.scope
                && request.toolUseID != tool.id
                && now.timeIntervalSince(request.request.createdAt) >= EngineTuning.parallelWindow
        }.map { $0.id }
    }

    /// A request that is the same call delivered twice (for example because the hook is installed
    /// in two settings files), or nil when it is a new one. A separate call with identical content
    /// would have announced itself with its own "tool started", leaving an unclaimed open tool.
    static func replayedRequest(kind: RequestKind, toolName: String?, scope: String,
                                openTools: [OpenTool], requests: [TrackedRequest]) -> TrackedRequest? {
        guard let twin = requests.first(where: { $0.scope == scope && $0.request.kind == kind }) else { return nil }
        let claimed = Set(requests.compactMap { $0.toolUseID })
        let hasUnclaimedCall = openTools.contains { tool in
            tool.scope == scope && !claimed.contains(tool.id) && (toolName == nil || sameTool(tool.name, toolName))
        }
        return hasUnclaimedCall ? nil : twin
    }

    static func sameTool(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    private static func unlinkedRequest(for name: String, scope: String, in requests: [TrackedRequest]) -> TrackedRequest? {
        requests.first { request in
            request.scope == scope && request.toolUseID == nil
                && (request.toolName == nil || sameTool(name, request.toolName))
        }
    }
}
