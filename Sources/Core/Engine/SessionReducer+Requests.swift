// SessionReducer+Requests.swift — the life of a request that waits for the user.
//
// A request is born when an agent asks for permission, asks a question or proposes a plan.
//   - With a waiting helper ("blocking") it becomes a card with buttons; the helper is kept
//     until the user decides, the request is withdrawn, or the helper goes away.
//   - Without one ("display-only") the session shows that it needs the user, but there is
//     nothing Perch could answer, so no card with buttons is published.
// It ends in one of three ways: the user decides (`resolve`), the helper disconnects
// (`replyDisconnected`), or later events prove it was settled elsewhere (`withdraw`, called from
// the rules in SessionReducer+Events.swift; see RequestCorrelation.swift for the reasoning).

import Foundation

extension SessionReducer {
    // MARK: - A request arrives

    static func addRequest(_ state: inout EngineState, _ index: Int, kind: RequestKind, event: NormalizedEvent,
                           offersReply: Bool, config: EngineConfig) -> [EngineEffect] {
        let now = event.context.receivedAt
        let session = state.sessions[index]
        let scope = RawHints.scope(event.raw)
        let toolName = requestToolName(kind, raw: event.raw)
        let inNotch = handlesInNotch(kind, config)
        let request = PendingRequest(sessionID: session.id, agent: session.agent, kind: kind, createdAt: now, raw: event.raw)
        var effects: [EngineEffect] = []

        if offersReply && !inNotch {
            // The user wants this kind of prompt in the terminal. Perch still shows that the session is waiting.
            effects += stepAside(event, sessionID: session.id, because: "\(settingName(kind)) in the notch is turned off in Settings")
        }
        let isBlocking = offersReply && inNotch

        if isBlocking, config.autoAllowReadOnly, case .permission(let permission) = kind, ReadOnlyTools.mayAutoAllow(permission) {
            effects.append(.incomingReply(.autoAllow(request)))
            effects.append(.note(event: "Allowed automatically",
                                 summary: "Perch allowed \(permission.toolName) without asking, because it only reads files "
                                    + "and you turned that on in Settings.",
                                 agent: session.agent, sessionID: session.id))
            return effects
        }

        let mine = state.requests(for: session.id)
        let openTools = state.tracking[session.id]?.openTools ?? []
        var isQuiet = false

        if let twin = RequestCorrelation.replayedRequest(kind: kind, toolName: toolName, scope: scope, openTools: openTools, requests: mine) {
            if !isBlocking { return effects }                       // already showing it
            if twin.isBlocking {
                effects.append(.incomingReply(.replace(requestID: twin.id)))
                return effects
            }
            // The waiting helper for something that was display-only so far: make it a real card, quietly.
            state.requests.removeAll { $0.id == twin.id }
            isQuiet = true
        }
        // A bare "needs your permission" marker (from a notification) is replaced by the real request.
        if case .permission = kind, let marker = mine.first(where: { isPermissionMarker($0) && $0.scope == scope }) {
            state.requests.removeAll { $0.id == marker.id }
            isQuiet = true
        }

        let remaining = state.requests(for: session.id)
        let linked = RequestCorrelation.link(toolName: toolName, inputKey: RawHints.inputKey(event.raw), scope: scope,
                                             openTools: openTools, requests: remaining)
        state.requests.append(TrackedRequest(request: request, isBlocking: isBlocking, scope: scope, toolName: toolName,
                                             toolUseID: linked?.id, lastNudgeAt: now))
        if isBlocking { effects.append(.incomingReply(.hold(requestID: request.id))) }
        refreshAttention(&state, sessionID: session.id, now: now)
        if !isQuiet { effects += alert(&state, for: request, session: session, now: now) }
        return effects
    }

    /// The fallback for agents (or setups) without a blocking hook: a "permission_prompt"
    /// notification means the agent is waiting in the terminal. Claude also sends it six seconds
    /// into every prompt, so when the session already has a request it is only an echo.
    static func permissionPromptNotification(_ state: inout EngineState, _ index: Int, message: String,
                                             event: NormalizedEvent) -> [EngineEffect] {
        let now = event.context.receivedAt
        let session = state.sessions[index]
        guard !state.requests.contains(where: { $0.sessionID == session.id }) else { return [] }
        if let settled = state.tracking[session.id]?.lastRequestSettledAt, now.timeIntervalSince(settled) < EngineTuning.echoWindow {
            return []
        }

        let scope = RawHints.scope(event.raw)
        let linked = RequestCorrelation.link(toolName: nil, inputKey: nil, scope: scope,
                                             openTools: state.tracking[session.id]?.openTools ?? [], requests: [])
        let summary = EngineText.tidy(message, limit: 200) ?? "Waiting for your permission in the terminal"
        let permission = PermissionRequest(toolName: linked?.name ?? "", summary: summary, detail: session.currentTool?.summary ?? "")
        let request = PendingRequest(sessionID: session.id, agent: session.agent, kind: .permission(permission), createdAt: now, raw: event.raw)
        // `toolName` stays nil: this marker stands for "whatever the agent is asking about".
        state.requests.append(TrackedRequest(request: request, isBlocking: false, scope: scope, toolName: nil,
                                             toolUseID: linked?.id, lastNudgeAt: now))
        refreshAttention(&state, sessionID: session.id, now: now)
        return alert(&state, for: request, session: session, now: now)
    }

    /// True for the stand-in created from a bare "needs your permission" notification.
    private static func isPermissionMarker(_ request: TrackedRequest) -> Bool {
        request.toolName == nil && !request.isBlocking && request.attentionState == .needsApproval
    }

    /// Pulse, sound and notification for a request that just appeared.
    private static func alert(_ state: inout EngineState, for request: PendingRequest, session: Session, now: Date) -> [EngineEffect] {
        var effects: [EngineEffect] = [.pulse(.attention, sessionID: session.id)]
        // Several requests arriving together (parallel tool calls) share one sound.
        let last = state.tracking[session.id]?.lastAttentionSoundAt
        if last.map({ now.timeIntervalSince($0) >= EngineTuning.attentionBurst }) ?? true {
            let cue: SoundCue
            if case .question = request.kind { cue = .needsAnswer } else { cue = .needsApproval }
            effects.append(.sound(cue, sessionID: session.id))
            state.tracking[session.id, default: SessionTracking()].lastAttentionSoundAt = now
        }
        effects.append(.notify(title: ActivitySummary.attentionTitle(request.kind, agent: session.agent),
                               body: ActivitySummary.attentionBody(request.kind, session: session), sessionID: session.id))
        return effects
    }

    // MARK: - The user decides

    /// Removes the request and asks for the decision to be sent. Unknown ids (a click on a card
    /// that was withdrawn a moment ago) do nothing.
    static func resolve(_ state: inout EngineState, requestID: UUID, decision: Decision, now: Date) -> [EngineEffect] {
        guard let position = state.requests.firstIndex(where: { $0.id == requestID }) else { return [] }
        let tracked = state.requests[position]
        var effects: [EngineEffect] = []
        if tracked.isBlocking { effects.append(.sendDecision(decision, tracked.request)) }

        if decision == .passToTerminal {
            // Perch steps aside, but the agent is still waiting — now in the terminal. Keep showing
            // that, without a card, until events show it was answered.
            state.requests[position].isBlocking = false
            state.requests[position].lastNudgeAt = now
            return effects
        }

        state.requests.remove(at: position)
        state.tracking[tracked.sessionID]?.lastRequestSettledAt = now
        if let index = state.index(of: tracked.sessionID) {
            // A refused tool never reports "finished", so close it here.
            if !EngineFacts.isApproval(decision), let toolID = tracked.toolUseID {
                finishTool(&state, index, toolID: toolID, succeeded: false, now: now)
            }
            refreshAttention(&state, sessionID: tracked.sessionID, now: now)
        }
        effects.append(.pulse(EngineFacts.isApproval(decision) ? .approved : .denied, sessionID: tracked.sessionID))
        effects.append(.sound(EngineFacts.isApproval(decision) ? .approved : .denied, sessionID: tracked.sessionID))
        return effects
    }

    /// The helper went away before a decision: the user answered (or pressed Esc) in the terminal,
    /// the hook timed out, or the agent quit.
    static func replyDisconnected(_ state: inout EngineState, requestID: UUID, now: Date) -> [EngineEffect] {
        withdraw(&state, [requestID],
                 reason: "The agent stopped waiting (answered or cancelled in the terminal), so Perch removed its card.", now: now)
    }

    // MARK: - Withdrawing

    /// Removes requests without answering them. Their helpers are let go with "no opinion", which
    /// is harmless even if the agent turns out to be still waiting: its own prompt simply stands.
    static func withdraw(_ state: inout EngineState, _ ids: [UUID], reason: String, now: Date) -> [EngineEffect] {
        var effects: [EngineEffect] = []
        var touched: [String] = []
        for id in ids {
            guard let position = state.requests.firstIndex(where: { $0.id == id }) else { continue }
            let tracked = state.requests.remove(at: position)
            state.tracking[tracked.sessionID]?.lastRequestSettledAt = now
            if !touched.contains(tracked.sessionID) { touched.append(tracked.sessionID) }
            if tracked.isBlocking { effects.append(.closeReply(requestID: tracked.id)) }
            effects.append(.note(event: "Request withdrawn", summary: reason, agent: tracked.request.agent, sessionID: tracked.sessionID))
        }
        for sessionID in touched { refreshAttention(&state, sessionID: sessionID, now: now) }
        return effects
    }

    /// The user removed a card by hand. The agent is not affected; its prompts stay in the terminal.
    static func dismiss(_ state: inout EngineState, sessionID: String, now: Date) -> [EngineEffect] {
        removeSession(&state, id: sessionID, now: now, tombstone: false, reason: "You dismissed the session's card; answer in the terminal.")
    }

    /// The engine is stopping: nothing may be left waiting on it.
    static func shutDown(_ state: inout EngineState, now: Date) -> [EngineEffect] {
        withdraw(&state, state.requests.map { $0.id }, reason: "Perch stopped listening; answer in the terminal.", now: now)
    }

    // MARK: - Small lookups

    static func handlesInNotch(_ kind: RequestKind, _ config: EngineConfig) -> Bool {
        switch kind {
        case .permission: return config.approvalsInNotch
        case .question: return config.questionsInNotch
        case .plan: return config.planReviewInNotch
        }
    }

    private static func settingName(_ kind: RequestKind) -> String {
        switch kind {
        case .permission: return "approving"
        case .question: return "answering questions"
        case .plan: return "plan review"
        }
    }

    private static func requestToolName(_ kind: RequestKind, raw: JSONValue) -> String? {
        if case .permission(let permission) = kind, !permission.toolName.isEmpty { return permission.toolName }
        return RawHints.toolName(raw)
    }
}
