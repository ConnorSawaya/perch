// SessionReducer.swift — the heart of the engine: one event in, new state out.
//
// Everything here is a pure function. It changes the EngineState it is given and returns a list
// of EngineEffects (play a sound, answer a helper...) for the coordinator to carry out. It never
// touches a store, a timer, a socket or the clock (time comes from the event), so every rule
// can be tested by feeding it events and looking at the result.
//
// This file decides WHETHER an event is acted on (agent switched off? session hidden? session
// already over?) and finds or creates the session. The per-event rules are in
// SessionReducer+Events.swift and the request rules in SessionReducer+Requests.swift.

import Foundation

enum SessionReducer {
    /// Applies one normalized event.
    /// - Parameter offersReply: true when a helper is waiting for an answer to this event. If the
    ///   event is a request, the returned effects then contain exactly one `.incomingReply`.
    static func reduce(_ state: inout EngineState, _ event: NormalizedEvent, offersReply: Bool,
                       config: EngineConfig) -> [EngineEffect] {
        let id = Session.makeID(event.agent, event.sessionID)
        let now = event.context.receivedAt
        let needsAnswer = EngineFacts.isRequest(event.event) && offersReply

        // 1. The user switched this agent off: Perch stays out of its way completely.
        guard config.enabledAgents.contains(event.agent) else {
            let why = "\(event.agent.displayName) is turned off in Settings"
            var effects = removeSession(&state, id: id, now: now, tombstone: false, reason: "Card removed: \(why).")
            if needsAnswer { effects += stepAside(event, sessionID: nil, because: why) }
            return effects
        }

        // 2. Hidden sessions get no card, and their prompts stay in the terminal.
        let host = SessionVisibility.host(context: event.context, known: state.session(id))
        guard SessionVisibility.isVisible(host, config) else {
            let why = SessionVisibility.hiddenReason(host)
            var effects = removeSession(&state, id: id, now: now, tombstone: false, reason: "Card removed: \(why).")
            if needsAnswer { effects += stepAside(event, sessionID: nil, because: why) }
            return effects
        }

        // 3. Find the session, or create it (hooks can arrive in the middle of a session).
        let index: Int
        var arrival = Arrival.existing
        if let existing = state.index(of: id) {
            // An ended card is on its way out; only a real sign of life brings it back.
            if state.sessions[existing].state == .ended {
                guard revives(event.event) else { return [] }
                arrival = .revived
                state.tombstones[id] = nil
                state.tracking[id, default: SessionTracking()].endedAt = nil
                // "Session started" decides for itself what a restart means; anything else that
                // revives a card is the middle of a turn.
                if !EngineFacts.isSessionStart(event.event) {
                    state.sessions[existing].state = .working
                    state.sessions[existing].stateSince = now
                }
            }
            index = existing
        } else {
            if let endedAt = state.tombstones[id], now.timeIntervalSince(endedAt) < EngineTuning.tombstoneLifetime,
               !revives(event.event) {
                return []
            }
            guard createsSession(event.event) else {
                if case .sessionEnded = event.event { state.tombstones[id] = now }
                return []
            }
            state.tombstones[id] = nil
            (index, arrival) = createSession(&state, for: event, now: now)
        }

        let previousPID = arrival == .existing || arrival == .revived ? state.sessions[index].pid : nil
        absorbContext(&state, index, event, host: host)
        return apply(&state, index, event, arrival: arrival, previousPID: previousPID, offersReply: offersReply, config: config)
    }

    /// How the session an event belongs to was found.
    enum Arrival: Equatable {
        case existing
        /// The card was already there in the `ended` state.
        case revived
        /// A new card was added.
        case created
        /// A new card took the place of a finished one in the same terminal tab.
        case replacedNeighbour
    }

    // MARK: - Which events do what to a missing or ended session

    /// Events that prove a session is alive even though Perch thought it had ended.
    static func revives(_ event: AgentEvent) -> Bool {
        switch event {
        case .sessionStarted, .promptSubmitted, .permissionRequested, .questionAsked, .planProposed: return true
        default: return false
        }
    }

    /// Events that create a card for a session Perch has not seen before. Passive updates (usage
    /// numbers, details, account chatter) do not: on their own they would bring back a card the
    /// user just dismissed, or show one for a session that never does anything.
    static func createsSession(_ event: AgentEvent) -> Bool {
        switch event {
        case .sessionEnded, .usageUpdated, .metadata, .subagentStopped: return false
        case .notification(let kind, _): return kind == EngineNotificationKind.permissionPrompt
        default: return true
        }
    }

    // MARK: - Creating and removing sessions

    private static func createSession(_ state: inout EngineState, for event: NormalizedEvent, now: Date) -> (Int, Arrival) {
        let cwd = event.context.cwd ?? ""
        // A card that appears from a "session started" is idle; one that appears from anything
        // else is in the middle of a turn. The event's own rule refines this straight away.
        let initial: SessionState = EngineFacts.isSessionStart(event.event) ? .idle : .working
        let session = Session(id: Session.makeID(event.agent, event.sessionID), agent: event.agent, sessionID: event.sessionID,
                              cwd: cwd, title: EngineText.folderTitle(cwd: cwd, agent: event.agent), model: nil,
                              state: initial, stateSince: now, startedAt: now, lastEventAt: now)
        state.tracking[session.id] = SessionTracking()

        // One terminal tab runs one session at a time, so a new session in the tab of a finished
        // one (after /clear or resume, say) takes over that card's place instead of adding a card.
        if let stale = staleNeighbour(state, of: session.id, context: event.context) {
            let old = state.sessions[stale]
            state.requests.removeAll { $0.sessionID == old.id }
            state.tracking[old.id] = nil
            state.tombstones[old.id] = now
            state.sessions[stale] = session
            return (stale, .replacedNeighbour)
        }
        state.sessions.append(session)
        return (state.sessions.count - 1, .created)
    }

    /// A card this new session should replace: a resting one on the same tty, or an ended one of the same process.
    private static func staleNeighbour(_ state: EngineState, of id: String, context: EventContext) -> Int? {
        let tty = context.tty.flatMap { $0.isEmpty ? nil : $0 }
        let pid = EngineFacts.validPID(context.pid)
        return state.sessions.firstIndex { other in
            guard other.id != id else { return false }
            let hasRequests = state.requests.contains { $0.sessionID == other.id }
            let resting = [.ended, .idle, .done, .failed].contains(other.state) && !hasRequests
            if let tty, other.terminal.tty == tty, resting { return true }
            if let pid, other.pid == pid, other.state == .ended { return true }
            return false
        }
    }

    /// Removes a card and withdraws everything that was waiting on it. Does nothing for an unknown id.
    @discardableResult
    static func removeSession(_ state: inout EngineState, id: String, now: Date, tombstone: Bool, reason: String) -> [EngineEffect] {
        guard let index = state.index(of: id) else { return [] }
        let waiting = state.requests(for: id).map { $0.id }
        state.sessions.remove(at: index)
        let effects = withdraw(&state, waiting, reason: reason, now: now)
        state.tracking[id] = nil
        if tombstone { state.tombstones[id] = now }
        return effects
    }

    // MARK: - Facts every event brings along

    /// Copies what the event knows about the process and terminal into the session.
    private static func absorbContext(_ state: inout EngineState, _ index: Int, _ event: NormalizedEvent, host: SessionVisibility.Host) {
        let context = event.context
        var session = state.sessions[index]
        session.lastEventAt = max(session.lastEventAt, context.receivedAt)

        if let pid = EngineFacts.validPID(context.pid), pid != session.pid {
            session.pid = pid
            // A different process: housekeeping must learn its identity afresh.
            state.tracking[session.id]?.process = nil
            state.tracking[session.id]?.processPID = nil
        }
        if let path = context.transcriptPath, !path.isEmpty { session.transcriptPath = path }
        if session.cwd.isEmpty, let cwd = context.cwd, !cwd.isEmpty {
            // The first folder seen is the project; later events may report sub-folders the agent moved into.
            session.cwd = cwd
            if state.tracking[session.id]?.titleSource == .folder {
                session.title = EngineText.folderTitle(cwd: cwd, agent: session.agent)
            }
        }
        session.terminal = merged(session.terminal, with: TerminalInfo(context: context))
        session.isHeadless = host == .headless || host == .desktopApp
        state.sessions[index] = session
    }

    /// Newer facts win, but a missing fact never erases a known one — except that a different tty
    /// means a different tab, so everything about the old tab is dropped.
    static func merged(_ old: TerminalInfo, with new: TerminalInfo) -> TerminalInfo {
        if let tty = new.tty, !tty.isEmpty, tty != old.tty { return new }
        var result = old
        result.bundleID = new.bundleID ?? old.bundleID
        result.termProgram = new.termProgram ?? old.termProgram
        result.itermSessionID = new.itermSessionID ?? old.itermSessionID
        result.terminalSessionID = new.terminalSessionID ?? old.terminalSessionID
        result.tmuxPane = new.tmuxPane ?? old.tmuxPane
        result.kittyWindowID = new.kittyWindowID ?? old.kittyWindowID
        result.weztermPane = new.weztermPane ?? old.weztermPane
        return result
    }

    // MARK: - State changes

    /// Sets the session's state. While a request is waiting the session keeps showing that it
    /// needs the user, whatever else happens ("activity never hides a waiting request").
    static func setState(_ state: inout EngineState, _ index: Int, _ newState: SessionState, now: Date) {
        let id = state.sessions[index].id
        if newState != .ended && state.requests.contains(where: { $0.sessionID == id }) { return }
        guard state.sessions[index].state != newState else { return }
        state.sessions[index].state = newState
        state.sessions[index].stateSince = now
    }

    /// Makes the session's state follow its request queue: the oldest request decides what is
    /// shown; with none left, a session that was waiting goes back to working.
    static func refreshAttention(_ state: inout EngineState, sessionID: String, now: Date) {
        guard let index = state.index(of: sessionID), state.sessions[index].state != .ended else { return }
        let wanted: SessionState
        if let head = state.requests.first(where: { $0.sessionID == sessionID }) {
            wanted = head.attentionState
        } else if state.sessions[index].state.needsAttention {
            wanted = .working
        } else {
            return
        }
        guard state.sessions[index].state != wanted else { return }
        state.sessions[index].state = wanted
        state.sessions[index].stateSince = now
    }

    // MARK: - Stepping aside

    /// Hands a waiting helper straight back to the agent, and says why in the activity log.
    static func stepAside(_ event: NormalizedEvent, sessionID: String?, because reason: String) -> [EngineEffect] {
        [.incomingReply(.passthrough),
         .note(event: "Stepped aside", summary: "Perch left this one to the terminal: \(reason).",
               agent: event.agent, sessionID: sessionID)]
    }
}

/// The notification kinds the engine acts on (see ARCHITECTURE.md §6).
enum EngineNotificationKind {
    static let permissionPrompt = "permission_prompt"
    static let idlePrompt = "idle_prompt"
}
