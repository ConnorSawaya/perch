// ActivityTracker.swift — Perch's own tally of how each day went.
//
// Fed with the same events the session engine sees, it keeps one DailyActivity per local day:
//   active seconds     time during which at least one session was busy (working, running a tool)
//   sessions started   sessions that began that day
//   turns finished     turns the agents completed
//   tool calls         tools the agents started
//   approvals handled  permission prompts and plans the user decided in Perch
//   questions answered questions the user answered in Perch
//   longest task       longest stretch from a prompt to the end of its turn
//   peak concurrent    most sessions busy at the same moment
//
// It is a plain value with no clock, files or timers of its own: every call is told what time it
// is, which makes it easy to test. UsageEngine owns one on the main thread, saves it, and stops
// feeding it when the "collect activity stats" setting is off.
//
// "Busy" is inferred from events, and events can be missed (Perch was not running, an agent was
// killed). So a session that has been silent for 30 minutes stops counting as busy; without that
// rule one lost "finished" event would add active time for ever.

import Foundation

struct ActivityTracker {
    /// How many days are kept.
    static let keptDays = 90
    /// A busy session with no event for this long is assumed to have stopped.
    static let quietLimit: TimeInterval = 30 * 60
    /// A session that is not busy and has been silent this long is forgotten.
    private static let forgetAfter: TimeInterval = 24 * 3600

    private struct LiveSession {
        var isBusy = false
        /// When the task in progress began (a prompt, or the first tool seen).
        var taskStartedAt: Date?
        var lastEventAt: Date
    }

    private var days: [String: DailyActivity] = [:]
    /// Active time with fractions, so many short stretches are not each rounded down to zero.
    private var activeExact: [String: Double] = [:]
    private var live: [String: LiveSession] = [:]
    /// Active time has been added up to this moment.
    private var accountedUntil: Date?
    /// Goes up whenever a number changes; the engine uses it to know when to save and redraw.
    private(set) var revision = 0

    init(saved: [DailyActivity] = []) {
        for day in saved { days[day.day] = day }
    }

    // MARK: Input

    mutating func observe(_ event: NormalizedEvent, at now: Date, in zone: LocalDays) {
        advance(to: now, in: zone)
        let key = Session.makeID(event.agent, event.sessionID)
        let today = zone.day(of: now)
        let wasKnown = live[key] != nil
        var session = live[key] ?? LiveSession(lastEventAt: now)
        session.lastEventAt = now

        switch event.event {
        case .usageUpdated, .metadata:
            // Numbers only. They show a known session is alive, but never start tracking one.
            if wasKnown { live[key] = session }
            return
        case .sessionEnded:
            if wasKnown { revision += 1 }
            live[key] = nil
            return
        case .sessionStarted(_, _, let source):
            // "compact" is Claude Code restarting its context inside the same session, not a new one.
            if !wasKnown && source != "compact" { edit(today) { $0.sessionsStarted += 1 } }
        case .promptSubmitted:
            session.isBusy = true
            session.taskStartedAt = now
        case .toolStarted:
            edit(today) { $0.toolCalls += 1 }
            session.isBusy = true
            if session.taskStartedAt == nil { session.taskStartedAt = now }
        case .toolFinished, .compactionStarted:
            session.isBusy = true
        case .compactionFinished:
            session.isBusy = session.taskStartedAt != nil
        case .permissionRequested, .questionAsked, .planProposed:
            session.isBusy = false                      // waiting for the user is not the agent working
        case .notification(let kind, _):
            if kind == "permission_prompt" || kind == "idle_prompt" { session.isBusy = false }
        case .turnFinished(_, let backgroundWork):
            edit(today) { $0.turnsFinished += 1 }
            if !backgroundWork {
                finishTask(&session, at: now, day: today)
                session.isBusy = false
            }
        case .turnFailed:
            finishTask(&session, at: now, day: today)
            session.isBusy = false
        case .subagentStarted, .subagentStopped:
            break
        }
        live[key] = session
        notePeak(today)
    }

    mutating func recordDecision(_ decision: Decision, for request: PendingRequest, at now: Date, in zone: LocalDays) {
        advance(to: now, in: zone)
        // Handing the request back to the terminal is not handling it in Perch.
        if decision == .passToTerminal { return }
        let today = zone.day(of: now)
        switch request.kind {
        case .permission, .plan: edit(today) { $0.approvalsHandled += 1 }
        case .question: edit(today) { $0.questionsAnswered += 1 }
        }
        // Whatever the answer, the agent carries on with it.
        if var session = live[request.sessionID] {
            session.isBusy = true
            session.lastEventAt = now
            live[request.sessionID] = session
            notePeak(today)
        }
    }

    /// Adds the active time that has passed since the last call. Call it now and then even when
    /// no events arrive, so a long-running task shows up while it runs.
    mutating func advance(to now: Date, in zone: LocalDays) {
        defer { accountedUntil = now }
        guard let from = accountedUntil, now > from else { return }
        let busy = live.values.filter(\.isBusy)
        // Busy time is believed up to 30 minutes after the last sign of life of any busy session.
        if let believedUntil = busy.map({ $0.lastEventAt.addingTimeInterval(Self.quietLimit) }).max() {
            addActive(from: from, to: min(now, believedUntil), busyCount: busy.count, in: zone)
        }
        for (key, session) in live {
            let silent = now.timeIntervalSince(session.lastEventAt)
            if session.isBusy && silent >= Self.quietLimit {
                live[key]?.isBusy = false
                live[key]?.taskStartedAt = nil
            } else if !session.isBusy && silent >= Self.forgetAfter {
                live[key] = nil
            }
        }
    }

    /// Forgets which sessions are running (not the saved numbers). Used when collecting is switched off.
    mutating func forgetLiveSessions() {
        live.removeAll()
        accountedUntil = nil
    }

    // MARK: Output

    /// The days to show: up to 90, oldest first, without gaps from the first day with numbers up to today.
    func recentDays(at now: Date, in zone: LocalDays) -> [DailyActivity] {
        let window = zone.lastDays(Self.keptDays, endingAt: now)
        guard let first = window.firstIndex(where: { days[$0] != nil }) else { return [] }
        return window[first...].map { days[$0] ?? DailyActivity(day: $0) }
    }

    /// Everything worth saving: the days inside the 90-day window, oldest first.
    func daysToSave(at now: Date, in zone: LocalDays) -> [DailyActivity] {
        let window = Set(zone.lastDays(Self.keptDays, endingAt: now))
        return days.values.filter { window.contains($0.day) }.sorted { $0.day < $1.day }
    }

    /// Number of sessions currently counted as busy.
    var busyCount: Int { live.values.filter(\.isBusy).count }

    // MARK: Helpers

    private mutating func edit(_ day: String, _ change: (inout DailyActivity) -> Void) {
        var entry = days[day] ?? DailyActivity(day: day)
        let before = entry
        change(&entry)
        guard entry != before else { return }
        days[day] = entry
        revision += 1
    }

    private mutating func finishTask(_ session: inout LiveSession, at now: Date, day: String) {
        guard let started = session.taskStartedAt else { return }
        session.taskStartedAt = nil
        let seconds = Int(now.timeIntervalSince(started).rounded())
        guard seconds > 0 else { return }
        edit(day) { $0.longestTaskSeconds = max($0.longestTaskSeconds, seconds) }
    }

    private mutating func notePeak(_ day: String) {
        let count = busyCount
        guard count > 0 else { return }
        edit(day) { $0.peakConcurrent = max($0.peakConcurrent, count) }
    }

    /// Adds the stretch `from ..< to` as active time, split at local midnights.
    private mutating func addActive(from: Date, to: Date, busyCount: Int, in zone: LocalDays) {
        var start = from
        while start < to {
            let end = min(to, zone.nextMidnight(after: start))
            guard end > start else { break }
            let day = zone.day(of: start)
            let exact = (activeExact[day] ?? Double(days[day]?.activeSeconds ?? 0)) + end.timeIntervalSince(start)
            activeExact[day] = exact
            edit(day) {
                $0.activeSeconds = Int(exact.rounded())
                $0.peakConcurrent = max($0.peakConcurrent, busyCount)
            }
            start = end
        }
    }
}
