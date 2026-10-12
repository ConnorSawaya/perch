// ClaudeEventNormalizer.swift — translates what Claude Code sends into Perch's common events.
//
// Claude Code runs the `perch-hook` helper for every hook event and for every status line
// refresh. The helper forwards the JSON untouched inside a HookEnvelope; this file reads it and
// produces NormalizedEvents, the only thing the rest of the app understands.
//
// The mapping follows the payloads captured from Claude Code 2.1.296 (Fixtures/claude/hooks and
// docs/research/claude-hooks-live.md). Payloads change between versions, so every field is
// treated as optional: a missing field gives a poorer event, never a crash, and an event name we
// do not know gives no events at all.
//
// Call it on the main thread only: it remembers, per session, the details it has already
// reported (permission mode, model, title, git branch) so they are sent again only when they
// change instead of with every tool call.

import Foundation

final class ClaudeEventNormalizer {
    /// The clock. Tests replace it to get fixed timestamps.
    var now: () -> Date = { Date() }
    /// Looks up the git branch of a folder. Tests replace it so they do not depend on real repositories.
    var gitBranch: (String) -> String? = { ClaudeGitBranch.current(in: $0) }
    /// The Claude Code version most recently reported by a status line payload (hook payloads carry none).
    private(set) var lastSeenVersion: String?

    /// Details that ride along with events and are worth reporting only when they change.
    private struct Details: Equatable {
        var title: String?
        var model: String?
        var gitBranch: String?
        var permissionMode: String?
    }

    private var reported: [String: Details] = [:]
    /// Sessions come and go; this stops the memory of them from growing without limit.
    private static let maxRememberedSessions = 200

    // MARK: - Entry point

    func events(for envelope: HookEnvelope) -> [NormalizedEvent] {
        guard let payload = JSONValue.parse(envelope.payload), payload.objectValue != nil else { return [] }
        switch envelope.channel {
        case "hook": return hookEvents(envelope, payload)
        case "statusline": return statusLineEvents(envelope, payload)
        default: return []
        }
    }

    // MARK: - Hook events

    private func hookEvents(_ envelope: HookEnvelope, _ payload: JSONValue) -> [NormalizedEvent] {
        guard let name = text(payload["hook_event_name"]) ?? nonEmpty(envelope.event),
              let sessionID = text(payload["session_id"]) ?? nonEmpty(envelope.env["CLAUDE_CODE_SESSION_ID"]) else { return [] }
        let context = EventContext(pid: envelope.pid > 0 ? envelope.pid : nil, tty: nonEmpty(envelope.tty),
                                   cwd: text(payload["cwd"]) ?? nonEmpty(envelope.cwd), env: envelope.env,
                                   transcriptPath: text(payload["transcript_path"]), receivedAt: now())
        let tool = text(payload["tool_name"])
        let input = payload["tool_input"]
        var details = Details(permissionMode: text(payload["permission_mode"]))
        // A new prompt is a good moment to repeat the details, in case the card was created late.
        var repeatDetails = false
        var reportDetails = true
        let event: AgentEvent

        switch name {
        case "SessionStart":
            // Sent at startup and again (same session id) after /compact, /clear or a resume.
            let model = modelName(payload["model"])
            reported[sessionID] = Details(model: model)
            details.gitBranch = context.cwd.flatMap(gitBranch)
            event = .sessionStarted(title: nil, model: model, source: text(payload["source"]))
        case "SessionEnd":
            reported[sessionID] = nil
            return [wrap(.sessionEnded(reason: text(payload["reason"])), name, sessionID, context, payload)]
        case "UserPromptSubmit":
            details.gitBranch = context.cwd.flatMap(gitBranch)
            repeatDetails = true
            event = .promptSubmitted(text: payload["prompt"].stringValue ?? "")
        case "PreToolUse":
            guard let tool else { return [] }
            let call = ToolCall(id: text(payload["tool_use_id"]) ?? UUID().uuidString, name: tool,
                                summary: ClaudeToolDescriber.summary(tool: tool, input: input, cwd: context.cwd),
                                startedAt: context.receivedAt)
            event = .toolStarted(call)
        case "PostToolUse", "PostToolUseFailure":
            guard let tool else { return [] }
            event = .toolFinished(id: text(payload["tool_use_id"]), name: tool, succeeded: name == "PostToolUse")
        case "PermissionRequest":
            // One event for three things: a permission prompt, a question, or a plan to approve.
            // It is also the one event a helper is waiting on, so it travels alone: exactly one
            // event for the engine to pair with the reply handle. (Its permission mode was just
            // reported by the PreToolUse that always comes right before it.)
            guard let tool else { return [] }
            reportDetails = false
            event = ClaudeRequestBuilder.event(tool: tool, input: input, suggestions: payload["permission_suggestions"],
                                               cwd: context.cwd)
        case "Notification":
            event = .notification(kind: payload["notification_type"].stringValue ?? "",
                                  message: payload["message"].stringValue ?? payload["title"].stringValue ?? "")
        case "Stop":
            let stillRunning = !(payload["background_tasks"].arrayValue ?? []).isEmpty
            event = .turnFinished(lastMessage: text(payload["last_assistant_message"]), backgroundWork: stillRunning)
        case "StopFailure":
            event = .turnFailed(error: Self.failureText(payload))
        case "SubagentStart":
            event = .subagentStarted(id: text(payload["agent_id"]), type: text(payload["agent_type"]))
        case "SubagentStop":
            // Claude Code also runs unnamed internal helper agents (after a turn, during /compact).
            // They stop without ever having started, with an empty type: not something to show.
            guard text(payload["agent_type"]) != nil else { return [] }
            event = .subagentStopped(id: text(payload["agent_id"]))
        case "PreCompact":
            event = .compactionStarted
        case "PostCompact":
            event = .compactionFinished
        default:
            return []
        }

        var events = [wrap(event, name, sessionID, context, payload)]
        if reportDetails, let change = detailsChange(for: sessionID, details, repeatAll: repeatDetails) {
            events.append(wrap(change, name, sessionID, context, payload))
        }
        return events
    }

    /// A readable sentence for a turn that ended in an API error.
    static func failureText(_ payload: JSONValue) -> String {
        let code = payload["error"].stringValue ?? payload["error"]["type"].stringValue ?? ""
        let known: [String: String] = [
            "rate_limit": "Claude hit a usage limit.",
            "authentication_failed": "Claude Code is not signed in, or the sign-in has expired.",
            "billing_error": "There is a billing problem with the account.",
            "invalid_request": "The request was rejected as invalid.",
            "server_error": "Anthropic's servers returned an error.",
            "max_output_tokens": "The reply was cut off because it reached the output limit.",
            "unknown": "The turn ended with an error.",
        ]
        // An unknown value may already be a sentence (the field is free text in some versions).
        var sentence = known[code] ?? (code.isEmpty ? "The turn ended with an error." : code)
        let extra = payload["error_details"].stringValue ?? payload["error"]["message"].stringValue ?? ""
        if !extra.isEmpty, extra != code {
            sentence += " " + ClaudeToolDescriber.oneLine(extra, limit: 300)
        }
        return sentence
    }

    // MARK: - Status line

    private func statusLineEvents(_ envelope: HookEnvelope, _ payload: JSONValue) -> [NormalizedEvent] {
        guard let sessionID = text(payload["session_id"]) else { return [] }
        if let version = text(payload["version"]) { lastSeenVersion = version }

        // The helper runs in the background of the status line script, so its parent process is
        // not Claude Code. Only a process id Claude Code named itself can be trusted here.
        let claudePID = envelope.env["CLAUDE_PID"].flatMap { Int32($0) }
        let trusted = claudePID != nil && claudePID == envelope.pid
        let context = EventContext(pid: trusted ? claudePID : nil, tty: trusted ? nonEmpty(envelope.tty) : nil,
                                   cwd: text(payload["cwd"]) ?? text(payload["workspace"]["current_dir"]) ?? nonEmpty(envelope.cwd),
                                   env: envelope.env, transcriptPath: text(payload["transcript_path"]), receivedAt: now())
        let reading = ClaudeStatusLineReader.read(payload)
        var events = [wrap(.usageUpdated(contextPercent: reading.contextPercent, windows: reading.windows,
                                         model: reading.modelID, costUSD: reading.costUSD),
                           "StatusLine", sessionID, context, payload)]
        let details = Details(title: reading.sessionName,
                              model: reading.modelDisplayName ?? reading.modelID.map(ClaudeToolDescriber.modelDisplayName))
        if let change = detailsChange(for: sessionID, details, repeatAll: false) {
            events.append(wrap(change, "StatusLine", sessionID, context, payload))
        }
        return events
    }

    // MARK: - Helpers

    /// Returns a `.metadata` event holding the details that are new or changed (all of the known
    /// ones when `repeatAll` is set), or nil when there is nothing to say.
    private func detailsChange(for sessionID: String, _ fresh: Details, repeatAll: Bool) -> AgentEvent? {
        if reported[sessionID] == nil, reported.count >= Self.maxRememberedSessions { reported.removeAll() }
        var before = reported[sessionID] ?? Details()
        func changed(_ new: String?, _ old: String?) -> String? {
            guard let new else { return nil }
            return repeatAll || new != old ? new : nil
        }
        let change = Details(title: changed(fresh.title, before.title), model: changed(fresh.model, before.model),
                             gitBranch: changed(fresh.gitBranch, before.gitBranch),
                             permissionMode: changed(fresh.permissionMode, before.permissionMode))
        before.title = fresh.title ?? before.title
        before.model = fresh.model ?? before.model
        before.gitBranch = fresh.gitBranch ?? before.gitBranch
        before.permissionMode = fresh.permissionMode ?? before.permissionMode
        reported[sessionID] = before
        guard change != Details() else { return nil }
        return .metadata(title: change.title, model: change.model, gitBranch: change.gitBranch,
                         permissionMode: change.permissionMode)
    }

    /// SessionStart gives the model as an id ("claude-haiku-5-5"); cards show "Haiku 5.5".
    private func modelName(_ value: JSONValue) -> String? {
        if let name = text(value["display_name"]) { return name }
        return (text(value) ?? text(value["id"])).map(ClaudeToolDescriber.modelDisplayName)
    }

    private func wrap(_ event: AgentEvent, _ name: String, _ sessionID: String, _ context: EventContext,
                      _ payload: JSONValue) -> NormalizedEvent {
        NormalizedEvent(agent: .claude, sessionID: sessionID, event: event, context: context, rawEventName: name, raw: payload)
    }

    /// A string field that is present and not empty.
    private func text(_ value: JSONValue) -> String? { nonEmpty(value.stringValue) }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
