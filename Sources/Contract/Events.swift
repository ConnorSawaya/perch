// Events.swift — the common language adapters translate every agent into.
//
// Each agent has its own event names and payloads. An adapter turns a raw HookEnvelope into
// zero or more NormalizedEvents, and the SessionEngine only ever sees these. Supporting a new
// agent means writing an adapter; nothing else has to change.

import Foundation

/// Facts about the process that produced an event, used to find its terminal and check it is alive.
struct EventContext: Equatable {
    var pid: Int32?
    var tty: String?
    var cwd: String?
    var env: [String: String] = [:]
    var transcriptPath: String?
    var receivedAt: Date
}

enum AgentEvent: Equatable {
    /// A session began or was resumed. `source` is the agent's reason ("startup", "resume", "clear"...).
    case sessionStarted(title: String?, model: String?, source: String?)
    case sessionEnded(reason: String?)
    case promptSubmitted(text: String)
    case toolStarted(ToolCall)
    case toolFinished(id: String?, name: String, succeeded: Bool)
    /// The agent is blocked on a permission prompt. Needs a Decision if a reply handle came with it.
    case permissionRequested(PermissionRequest)
    case questionAsked(QuestionRequest)
    case planProposed(PlanRequest)
    /// A message from the agent that is not tied to a tool. `kind` examples: "permission_prompt", "idle_prompt".
    case notification(kind: String, message: String)
    /// The turn finished. `backgroundWork` is true when the agent is still waiting on background tasks.
    case turnFinished(lastMessage: String?, backgroundWork: Bool)
    case turnFailed(error: String)
    case subagentStarted(id: String?, type: String?)
    case subagentStopped(id: String?)
    case compactionStarted
    case compactionFinished
    /// Fresh usage numbers for this session (from a status line or a session file).
    case usageUpdated(contextPercent: Double?, windows: [RateWindow], model: String?, costUSD: Double?)
    /// Details learned along the way. Nil fields mean "no change".
    case metadata(title: String?, model: String?, gitBranch: String?, permissionMode: String?)
}

struct NormalizedEvent: Equatable {
    var agent: AgentKind
    /// The agent's own session id (not the combined `Session.id`).
    var sessionID: String
    var event: AgentEvent
    var context: EventContext
    /// The agent's original event name, kept for the activity log.
    var rawEventName: String
    /// The original payload. Blocking requests keep it so the adapter can build the reply.
    var raw: JSONValue = .null
}
