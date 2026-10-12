// Housekeeping.swift — the tidying the engine does every few seconds.
//
// Some things never arrive as an event: a terminal window that is force-quit, a setting the user
// just changed, a card nobody has looked at for hours, a request that has been waiting a long
// time. `tick` checks for all of those. Like the rest of the reducer it is a pure function: the
// time and the "is this process still there?" check are passed in, so tests can step through
// hours in microseconds.

import Foundation

extension SessionReducer {
    /// Runs one round of housekeeping.
    /// - Parameter processIdentity: returns nil when the process is gone, otherwise what is known about it.
    static func tick(_ state: inout EngineState, now: Date, config: EngineConfig,
                     processIdentity: (Int32) -> ProcessLiveness.Identity?) -> [EngineEffect] {
        var effects: [EngineEffect] = []

        for session in state.sessions {
            if let reason = reasonToRemove(session, &state, now: now, config: config, processIdentity: processIdentity) {
                effects += removeSession(&state, id: session.id, now: now, tombstone: reason.tombstone, reason: reason.text)
            } else if let index = state.index(of: session.id), isStuck(state.sessions[index], state, now: now) {
                // The safety net for interrupts, which fire no hook: nothing has happened for a long time.
                state.tracking[session.id]?.openTools = []
                setState(&state, index, .idle, now: now)
            }
        }

        effects += reminders(&state, now: now, config: config)
        state.tombstones = state.tombstones.filter { now.timeIntervalSince($0.value) < EngineTuning.tombstoneLifetime }
        return effects
    }

    private struct Removal {
        var text: String
        /// True when late events for the session must not bring the card back.
        var tombstone: Bool
    }

    private static func reasonToRemove(_ session: Session, _ state: inout EngineState, now: Date, config: EngineConfig,
                                       processIdentity: (Int32) -> ProcessLiveness.Identity?) -> Removal? {
        // Sessions that are not the engine's (demo mode puts its own in the store) never get here:
        // the engine only ever looks at its own state.
        if !config.enabledAgents.contains(session.agent) {
            return Removal(text: "\(session.agent.displayName) was turned off in Settings.", tombstone: false)
        }
        let host = SessionVisibility.host(of: session)
        if !SessionVisibility.isVisible(host, config) {
            return Removal(text: "Card removed: \(SessionVisibility.hiddenReason(host)).", tombstone: false)
        }
        if session.state == .ended {
            let endedAt = state.tracking[session.id]?.endedAt ?? session.stateSince
            if now.timeIntervalSince(endedAt) >= EngineTuning.endedCardLifetime {
                return Removal(text: "The session ended.", tombstone: true)
            }
            return nil
        }
        if let pid = EngineFacts.validPID(session.pid), !isSameLiveProcess(pid, session.id, &state, processIdentity) {
            return Removal(text: "The agent's process is gone, so nothing is waiting any more.", tombstone: true)
        }
        let resting: [SessionState] = [.idle, .done, .failed]
        if config.idleCleanupMinutes > 0, resting.contains(session.state) {
            let quietSince = max(session.lastEventAt, session.stateSince)
            if now.timeIntervalSince(quietSince) >= config.idleCleanupMinutes * 60 {
                return Removal(text: "Nothing happened for a long time, so the card was cleared.", tombstone: false)
            }
        }
        return nil
    }

    /// True while the session's process id still belongs to the process it belonged to at first.
    /// Process ids are reused, so "a process with this id exists" is not enough: the start time
    /// is remembered the first time and compared afterwards.
    private static func isSameLiveProcess(_ pid: Int32, _ sessionID: String, _ state: inout EngineState,
                                          _ processIdentity: (Int32) -> ProcessLiveness.Identity?) -> Bool {
        guard let seen = processIdentity(pid) else { return false }
        var tracked = state.tracking[sessionID] ?? SessionTracking()
        defer { state.tracking[sessionID] = tracked }
        guard tracked.processPID == pid, let remembered = tracked.process else {
            tracked.processPID = pid
            tracked.process = seen
            return true
        }
        if let before = remembered.startedAt, let after = seen.startedAt { return before == after }
        if remembered.startedAt == nil { tracked.process = seen }
        return true
    }

    private static func isStuck(_ session: Session, _ state: EngineState, now: Date) -> Bool {
        guard session.state == .working, session.activeSubagents == 0 else { return false }
        guard !state.requests.contains(where: { $0.sessionID == session.id }) else { return false }
        return now.timeIntervalSince(max(session.lastEventAt, session.stateSince)) >= EngineTuning.stuckWorkingSeconds
    }

    /// One reminder sound per session per round, for requests that have waited a whole interval.
    private static func reminders(_ state: inout EngineState, now: Date, config: EngineConfig) -> [EngineEffect] {
        guard config.reminderEnabled, config.reminderSeconds > 0 else { return [] }
        let interval = max(config.reminderSeconds, EngineTuning.minReminderSeconds)
        var effects: [EngineEffect] = []
        var reminded: Set<String> = []
        for position in state.requests.indices where now.timeIntervalSince(state.requests[position].lastNudgeAt) >= interval {
            state.requests[position].lastNudgeAt = now
            let sessionID = state.requests[position].sessionID
            if reminded.insert(sessionID).inserted { effects.append(.sound(.reminder, sessionID: sessionID)) }
        }
        return effects
    }
}
