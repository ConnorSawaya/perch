// SessionReducer+Events.swift — what each kind of event does to a session.
//
// This is the table from ARCHITECTURE.md §6, one small function per row. Two ideas run through
// all of it:
//   - While a request is waiting, the session keeps showing "needs you" (setState refuses to
//     overwrite it); events only take the request away when they prove it is over.
//   - The end of a turn is latched: a "tool finished" that arrives late does not make a finished
//     session look busy again. Only a new prompt or a newly started tool does.

import Foundation

extension SessionReducer {
    /// - Parameter previousPID: the session's process id before this event (nil for a new card).
    static func apply(_ state: inout EngineState, _ index: Int, _ event: NormalizedEvent, arrival: Arrival,
                      previousPID: Int32?, offersReply: Bool, config: EngineConfig) -> [EngineEffect] {
        let now = event.context.receivedAt
        switch event.event {
        case .sessionStarted(let title, let model, let source):
            return sessionStarted(&state, index, title: title, model: model, source: source, event: event,
                                  arrival: arrival, previousPID: previousPID)
        case .sessionEnded:
            return sessionEnded(&state, index, now: now)
        case .promptSubmitted(let text):
            return promptSubmitted(&state, index, text: text, now: now)
        case .toolStarted(let call):
            return toolStarted(&state, index, call: call, event: event)
        case .toolFinished(let id, let name, let succeeded):
            return toolFinished(&state, index, id: id, name: name, succeeded: succeeded, event: event)
        case .permissionRequested(let request):
            return addRequest(&state, index, kind: .permission(request), event: event, offersReply: offersReply, config: config)
        case .questionAsked(let request):
            return addRequest(&state, index, kind: .question(request), event: event, offersReply: offersReply, config: config)
        case .planProposed(let request):
            return addRequest(&state, index, kind: .plan(request), event: event, offersReply: offersReply, config: config)
        case .notification(let kind, let message):
            return notification(&state, index, kind: kind, message: message, event: event)
        case .turnFinished(let lastMessage, let backgroundWork):
            return turnFinished(&state, index, lastMessage: lastMessage, backgroundWork: backgroundWork, event: event)
        case .turnFailed(let error):
            return turnFailed(&state, index, error: error, event: event)
        case .subagentStarted(let id, _):
            state.sessions[index].activeSubagents += 1
            if let id, !id.isEmpty { state.tracking[state.sessions[index].id, default: SessionTracking()].liveSubagents.insert(id) }
            return []
        case .subagentStopped(let id):
            return subagentStopped(&state, index, id: id, now: now)
        case .compactionStarted:
            let session = state.sessions[index]
            if session.state != .compacting {
                state.tracking[session.id, default: SessionTracking()].stateBeforeCompaction = session.state
            }
            setState(&state, index, .compacting, now: now)
            return []
        case .compactionFinished:
            return compactionFinished(&state, index, now: now)
        case .usageUpdated(let contextPercent, _, let model, let costUSD):
            // Rate-limit windows belong to the usage engine, which sees every event too.
            if let contextPercent { state.sessions[index].contextPercent = min(max(contextPercent, 0), 100) }
            if let model, !model.isEmpty { state.sessions[index].model = model }
            if let costUSD { state.sessions[index].estimatedCostUSD = costUSD }
            return []
        case .metadata(let title, let model, let gitBranch, let permissionMode):
            setAgentTitle(&state, index, title)
            if let model, !model.isEmpty { state.sessions[index].model = model }
            if let gitBranch { state.sessions[index].gitBranch = gitBranch.isEmpty ? nil : gitBranch }
            if let permissionMode, !permissionMode.isEmpty { state.sessions[index].permissionMode = permissionMode }
            return []
        }
    }

    // MARK: - Session start and end

    private static func sessionStarted(_ state: inout EngineState, _ index: Int, title: String?, model: String?, source: String?,
                                       event: NormalizedEvent, arrival: Arrival, previousPID: Int32?) -> [EngineEffect] {
        let now = event.context.receivedAt
        let id = state.sessions[index].id
        let source = (source ?? "").lowercased()
        var effects: [EngineEffect] = []

        // For a card that is already there, "started" only means a restart when something says so:
        // it was ended, the agent says resume/clear, or a different process now owns the session.
        // Claude also sends "started" (source "compact") in the middle of compacting, and a file
        // watcher may announce a session a hook already announced; neither may reset the card.
        if arrival == .existing || arrival == .revived {
            let newPID = EngineFacts.validPID(event.context.pid)
            let processChanged = newPID != nil && previousPID != nil && newPID != previousPID
            let isRestart = arrival == .revived || processChanged || source == "resume" || source == "clear"
            if isRestart {
                let waiting = state.requests(for: id).map { $0.id }
                effects += withdraw(&state, waiting, reason: "The session restarted, so the request is no longer waiting.", now: now)
                var fresh = state.tracking[id] ?? SessionTracking()
                fresh.openTools = []
                fresh.liveSubagents = []
                fresh.stateBeforeCompaction = nil
                fresh.endedAt = nil
                fresh.process = nil
                fresh.processPID = nil
                state.sessions[index].currentTool = nil
                state.sessions[index].activeSubagents = 0
                state.sessions[index].errorText = nil
                if source == "clear" {
                    // The conversation is new: the next prompt names it.
                    fresh.titleSource = .folder
                    state.sessions[index].title = EngineText.folderTitle(cwd: state.sessions[index].cwd, agent: state.sessions[index].agent)
                    state.sessions[index].lastPrompt = nil
                    state.sessions[index].lastMessage = nil
                }
                state.tracking[id] = fresh
                state.tombstones[id] = nil
                // Not through setState: a restart ends even the `ended` state.
                if state.sessions[index].state != .idle {
                    state.sessions[index].state = .idle
                    state.sessions[index].stateSince = now
                }
            }
        }

        setAgentTitle(&state, index, title)
        if let model, !model.isEmpty { state.sessions[index].model = model }

        // Announce a card that is new to the user; a card that merely continues in the same tab is not.
        if arrival == .created || arrival == .revived {
            effects.append(.pulse(.started, sessionID: id))
            effects.append(.sound(.sessionStart, sessionID: id))
        }
        return effects
    }

    private static func sessionEnded(_ state: inout EngineState, _ index: Int, now: Date) -> [EngineEffect] {
        let id = state.sessions[index].id
        let waiting = state.requests(for: id).map { $0.id }
        let effects = withdraw(&state, waiting, reason: "The session ended, so the request is no longer waiting.", now: now)
        closeOpenTools(&state, index, scope: nil)
        state.sessions[index].activeSubagents = 0
        state.tracking[id, default: SessionTracking()].liveSubagents = []
        state.tracking[id, default: SessionTracking()].endedAt = now
        state.tombstones[id] = now
        setState(&state, index, .ended, now: now)
        return effects
    }

    // MARK: - Prompts and tools

    private static func promptSubmitted(_ state: inout EngineState, _ index: Int, text: String, now: Date) -> [EngineEffect] {
        let id = state.sessions[index].id
        // Rule 2: nobody can type a prompt while a dialog is open, so every request is over.
        let waiting = state.requests(for: id).map { $0.id }
        let effects = withdraw(&state, waiting, reason: "A new prompt was sent, so the request was already settled in the terminal.", now: now)
        closeOpenTools(&state, index, scope: nil)

        state.sessions[index].turnCount += 1
        state.sessions[index].errorText = nil
        state.sessions[index].lastMessage = nil
        if let prompt = EngineText.tidy(text) { state.sessions[index].lastPrompt = prompt }
        if state.tracking[id]?.titleSource == .folder, let title = EngineText.title(fromPrompt: text) {
            state.sessions[index].title = title
            state.tracking[id, default: SessionTracking()].titleSource = .prompt
        }
        state.tracking[id, default: SessionTracking()].stateBeforeCompaction = nil
        setState(&state, index, .working, now: now)
        return effects
    }

    private static func toolStarted(_ state: inout EngineState, _ index: Int, call: ToolCall, event: NormalizedEvent) -> [EngineEffect] {
        let now = event.context.receivedAt
        let id = state.sessions[index].id
        let open = OpenTool(id: call.id, name: call.name, scope: RawHints.scope(event.raw),
                            inputKey: RawHints.inputKey(event.raw), startedAt: now)

        // Rule 5: a tool that starts well after a request proves the agent got its answer elsewhere.
        let over = RequestCorrelation.superseded(by: open, at: now, requests: state.requests(for: id))
        let abandoned = Set(state.requests.filter { over.contains($0.id) }.compactMap { $0.toolUseID })
        let effects = withdraw(&state, over, reason: "The agent moved on to another tool, so the request was already settled in the terminal.",
                               now: now)
        for toolID in abandoned { finishTool(&state, index, toolID: toolID, succeeded: false, now: now) }

        var tracked = state.tracking[id] ?? SessionTracking()
        let alreadyKnown = tracked.openTools.contains { $0.id == open.id }
        tracked.openTools.removeAll { $0.id == open.id }
        tracked.openTools.append(open)
        // A refused tool never reports "finished"; do not let such leftovers pile up without bound.
        if tracked.openTools.count > 64 { tracked.openTools.removeFirst(tracked.openTools.count - 64) }
        state.tracking[id] = tracked

        var session = state.sessions[index]
        session.currentTool = call
        if let known = session.recentTools.firstIndex(where: { $0.id == call.id }) {
            session.recentTools[known] = call
        } else {
            session.recentTools.append(call)
        }
        if session.recentTools.count > EngineTuning.recentToolsCap {
            session.recentTools.removeFirst(session.recentTools.count - EngineTuning.recentToolsCap)
        }
        if !alreadyKnown { session.toolCount += 1 }
        state.sessions[index] = session
        setState(&state, index, .runningTool, now: now)
        return effects
    }

    private static func toolFinished(_ state: inout EngineState, _ index: Int, id toolID: String?, name: String, succeeded: Bool,
                                     event: NormalizedEvent) -> [EngineEffect] {
        let now = event.context.receivedAt
        let id = state.sessions[index].id
        let outcome = RequestCorrelation.toolFinished(id: toolID, name: name, scope: RawHints.scope(event.raw),
                                                      openTools: state.tracking[id]?.openTools ?? [],
                                                      requests: state.requests(for: id))
        var effects: [EngineEffect] = []
        if let requestID = outcome.withdrawRequestID {
            // Rule 1: the tool ran, so somebody answered — and it was not Perch, or the request would be gone.
            effects = withdraw(&state, [requestID], reason: "The tool ran, so the request was already answered in the terminal.", now: now)
        }

        if let finished = outcome.openToolID ?? toolID {
            finishTool(&state, index, toolID: finished, succeeded: succeeded, now: now)
        } else if let current = state.sessions[index].currentTool, RequestCorrelation.sameTool(current.name, name) {
            // No id anywhere: the best match is the tool the card is showing.
            finishTool(&state, index, toolID: current.id, succeeded: succeeded, now: now)
        }

        // Latched: only a session that is visibly in the middle of a turn changes state here.
        let current = state.sessions[index].state
        if current == .runningTool || current == .working {
            setState(&state, index, state.sessions[index].currentTool == nil ? .working : .runningTool, now: now)
        }
        return effects
    }

    /// Marks one tool call as finished everywhere it is remembered.
    static func finishTool(_ state: inout EngineState, _ index: Int, toolID: String, succeeded: Bool, now: Date) {
        let id = state.sessions[index].id
        state.tracking[id]?.openTools.removeAll { $0.id == toolID }
        if let recent = state.sessions[index].recentTools.lastIndex(where: { $0.id == toolID && $0.finishedAt == nil }) {
            state.sessions[index].recentTools[recent].finishedAt = now
            state.sessions[index].recentTools[recent].succeeded = succeeded
        }
        if state.sessions[index].currentTool?.id == toolID { state.sessions[index].currentTool = nil }
    }

    /// Forgets tool calls that can no longer be running (the turn or session is over). They are
    /// left without a result in `recentTools`, because nobody reported one.
    private static func closeOpenTools(_ state: inout EngineState, _ index: Int, scope: String?) {
        let id = state.sessions[index].id
        let closing = (state.tracking[id]?.openTools ?? []).filter { scope == nil || $0.scope == scope }
        state.tracking[id]?.openTools.removeAll { tool in closing.contains { $0.id == tool.id } }
        if let current = state.sessions[index].currentTool, scope == nil || closing.contains(where: { $0.id == current.id }) {
            state.sessions[index].currentTool = nil
        }
    }

    // MARK: - End of a turn

    private static func turnFinished(_ state: inout EngineState, _ index: Int, lastMessage: String?, backgroundWork: Bool,
                                     event: NormalizedEvent) -> [EngineEffect] {
        let now = event.context.receivedAt
        let session = state.sessions[index]
        let scope = RawHints.scope(event.raw)
        // Rule 3. With nothing left running in the background every scope is over; otherwise only
        // the scope that finished (a background subagent may still be waiting for an answer).
        let finishedScope: String? = backgroundWork ? scope : nil
        let waiting = state.requests(for: session.id).filter { finishedScope == nil || $0.scope == finishedScope }.map { $0.id }
        var effects = withdraw(&state, waiting, reason: "The turn finished, so the request is no longer waiting.", now: now)
        closeOpenTools(&state, index, scope: finishedScope)

        let message = EngineText.tidy(lastMessage)
        if let message { state.sessions[index].lastMessage = message }
        if backgroundWork {
            // The reply is done but the agent is still waiting on background tasks: not "done" yet.
            setState(&state, index, .working, now: now)
            return effects
        }
        state.sessions[index].activeSubagents = 0
        state.tracking[session.id, default: SessionTracking()].liveSubagents = []
        state.tracking[session.id, default: SessionTracking()].stateBeforeCompaction = nil

        // Some agents report the end of a turn twice (a hook and a notify program); announce it once.
        let alreadyDone = session.state == .done
        setState(&state, index, .done, now: now)
        if !alreadyDone && state.sessions[index].state == .done {
            effects.append(.pulse(.done, sessionID: session.id))
            effects.append(.sound(.done, sessionID: session.id))
            effects.append(.notify(title: "\(EngineFacts.name(session.agent)) finished — \(state.sessions[index].title)",
                                   body: ActivitySummary.finishedLine(message), sessionID: session.id))
        }
        return effects
    }

    private static func turnFailed(_ state: inout EngineState, _ index: Int, error: String, event: NormalizedEvent) -> [EngineEffect] {
        let now = event.context.receivedAt
        let session = state.sessions[index]
        let scope = RawHints.scope(event.raw)
        let waiting = state.requests(for: session.id).filter { $0.scope == scope }.map { $0.id }
        var effects = withdraw(&state, waiting, reason: "The turn stopped with an error, so the request is no longer waiting.", now: now)
        closeOpenTools(&state, index, scope: scope)

        let text = EngineText.tidy(error) ?? "The turn stopped with an error."
        let repeated = session.state == .failed && session.errorText == text
        state.sessions[index].errorText = text
        state.tracking[session.id, default: SessionTracking()].stateBeforeCompaction = nil
        setState(&state, index, .failed, now: now)
        if !repeated && state.sessions[index].state == .failed {
            effects.append(.pulse(.failed, sessionID: session.id))
            effects.append(.sound(.failed, sessionID: session.id))
            effects.append(.notify(title: "\(EngineFacts.name(session.agent)) stopped with an error — \(session.title)",
                                   body: EngineText.clip(EngineText.firstLine(text) ?? text, to: 160), sessionID: session.id))
        }
        return effects
    }

    // MARK: - Subagents and compaction

    private static func subagentStopped(_ state: inout EngineState, _ index: Int, id subagentID: String?, now: Date) -> [EngineEffect] {
        let id = state.sessions[index].id
        guard let subagentID, !subagentID.isEmpty else {
            // No id to check against: just count down, never below zero.
            state.sessions[index].activeSubagents = max(0, state.sessions[index].activeSubagents - 1)
            return []
        }
        // Agents also report internal helpers stopping that never "started"; those must not be counted.
        guard state.tracking[id]?.liveSubagents.remove(subagentID) != nil else { return [] }
        state.sessions[index].activeSubagents = max(0, state.sessions[index].activeSubagents - 1)
        // Rule 6: whatever that subagent was waiting for is over.
        let waiting = state.requests(for: id).filter { $0.scope == subagentID }.map { $0.id }
        let effects = withdraw(&state, waiting, reason: "The helper agent that asked has finished.", now: now)
        closeOpenTools(&state, index, scope: subagentID)
        return effects
    }

    private static func compactionFinished(_ state: inout EngineState, _ index: Int, now: Date) -> [EngineEffect] {
        let id = state.sessions[index].id
        guard state.sessions[index].state == .compacting else { return [] }
        // Compaction in the middle of a turn goes back to working. One the user asked for while
        // the session was resting (/compact) goes back to resting.
        let before = state.tracking[id]?.stateBeforeCompaction
        state.tracking[id]?.stateBeforeCompaction = nil
        let resting: [SessionState] = [.idle, .done, .failed]
        if let before, resting.contains(before) {
            setState(&state, index, before, now: now)
        } else {
            setState(&state, index, .working, now: now)
        }
        return []
    }

    // MARK: - Notifications

    private static func notification(_ state: inout EngineState, _ index: Int, kind: String, message: String,
                                     event: NormalizedEvent) -> [EngineEffect] {
        let now = event.context.receivedAt
        let session = state.sessions[index]
        switch kind {
        case EngineNotificationKind.permissionPrompt:
            return permissionPromptNotification(&state, index, message: message, event: event)
        case EngineNotificationKind.idlePrompt:
            // "Waiting for your input" a minute after the agent went quiet: the turn is over, even
            // if its end was missed (an interrupt fires no hook). Display-only requests have no
            // other way of learning that, so they go. A request with a waiting helper is left
            // alone — its connection is the truth. A card that still says busy is put to rest, quietly.
            let displayOnly = state.requests(for: session.id).filter { !$0.isBlocking }.map { $0.id }
            let effects = withdraw(&state, displayOnly,
                                   reason: "The agent is waiting for a new prompt, so nothing is waiting for an answer any more.", now: now)
            let hasRequests = state.requests.contains { $0.sessionID == session.id }
            if !hasRequests && state.sessions[index].state.isBusy {
                closeOpenTools(&state, index, scope: nil)
                state.tracking[session.id]?.stateBeforeCompaction = nil
                setState(&state, index, .idle, now: now)
            }
            return effects
        default:
            return []
        }
    }

    // MARK: - Titles

    /// A title the agent supplied beats the folder name and the first prompt.
    private static func setAgentTitle(_ state: inout EngineState, _ index: Int, _ title: String?) {
        guard let clean = EngineText.title(fromAgent: title) else { return }
        state.sessions[index].title = clean
        state.tracking[state.sessions[index].id, default: SessionTracking()].titleSource = .agent
    }
}
