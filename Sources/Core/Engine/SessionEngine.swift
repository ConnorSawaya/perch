// SessionEngine.swift — turns normalized events into the session cards the notch shows, and looks
// after the requests that wait for the user.
//
// The engine is two layers:
//   SessionReducer (pure)   decides what an event means: the rules of ARCHITECTURE.md §6.
//   SessionEngine (this)    owns everything with a side effect: the helpers that are waiting for
//                           an answer (reply handles), the housekeeping timer, the store, sounds,
//                           notifications and the activity log.
// So this file contains no rules about sessions — it feeds the reducer and does what it asks.
//
// How the app uses it:
//   let engine = SessionEngine(store: ..., settings: ..., adapters: ..., sounds: ..., ...)
//   engine.start()                                   // housekeeping timer
//   server.onEnvelope = { envelope, handle in        // from the hook socket
//       engine.ingest(adapter.normalize(envelope), reply: handle)
//   }
//   engine.resolve(request.id, with: .allow)         // from AppActions.resolve
//
// Threading: everything here must be called on the main thread (the stores are main-thread only,
// and the hook server delivers envelopes and disconnects there). Each entry point checks it.

import Foundation

final class SessionEngine: SessionEngineProtocol {
    private let store: SessionStore
    private let settings: AppSettings
    private let adapters: [AgentKind: AgentAdapter]
    private let sounds: SoundPlaying?
    private let jumper: TerminalJumping?
    private let usage: UsageEngineProtocol?
    private let notifier: SystemNotifying?

    /// The engine's own picture of the world. The store is kept in step with it by `publish()`.
    private(set) var state = EngineState()
    /// The helper waiting for each blocking request, by request id.
    private var handles: [UUID: ReplyHandle] = [:]
    private var timer: Timer?
    private var publishedSessionIDs: Set<String> = []
    private var publishedRequestIDs: Set<UUID> = []

    /// The clock. Tests replace it so nothing depends on real time.
    var clock: () -> Date = { Date() }
    /// "Is this process still there?" — nil when it is gone. Tests replace it.
    var processIdentity: (Int32) -> ProcessLiveness.Identity? = { ProcessLiveness.identity(of: $0) }
    /// Seconds between housekeeping rounds; read when `start()` is called.
    var tickInterval: TimeInterval = EngineTuning.tickInterval

    init(store: SessionStore, settings: AppSettings, adapters: [AgentKind: AgentAdapter], sounds: SoundPlaying?,
         jumper: TerminalJumping?, usage: UsageEngineProtocol?, notifier: SystemNotifying?) {
        self.store = store
        self.settings = settings
        self.adapters = adapters
        self.sounds = sounds
        self.jumper = jumper
        self.usage = usage
        self.notifier = notifier
    }

    deinit { timer?.invalidate() }

    /// True between `start()` and `stop()`.
    var isRunning: Bool { timer != nil }
    /// How many helpers are waiting for an answer right now.
    var waitingHelperCount: Int { handles.count }

    // MARK: - SessionEngineProtocol

    func ingest(_ events: [NormalizedEvent], reply: ReplyHandle?) {
        dispatchPrecondition(condition: .onQueue(.main))
        var waiting = reply
        let config = EngineConfig(settings: settings)
        for event in events {
            usage?.observe(event)
            logIncoming(event)
            var effects: [EngineEffect] = []
            for effect in SessionReducer.reduce(&state, event, offersReply: waiting != nil, config: config) {
                if case .incomingReply(let plan) = effect {
                    // Only the first request of an envelope can own the helper.
                    if let handle = waiting { answer(handle, plan) }
                    waiting = nil
                } else {
                    effects.append(effect)
                }
            }
            publish()
            perform(effects)
        }
        // A helper that came with something Perch has no decision to make about (an unknown or
        // irrelevant blocking hook) must never be left waiting.
        waiting?.reply(.passthrough)
    }

    func resolve(_ requestID: UUID, with decision: Decision) {
        dispatchPrecondition(condition: .onQueue(.main))
        let effects = SessionReducer.resolve(&state, requestID: requestID, decision: decision, now: clock())
        publish()
        perform(effects)
    }

    func dismiss(sessionID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let effects = SessionReducer.dismiss(&state, sessionID: sessionID, now: clock())
        publish()
        perform(effects)
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard timer == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick(now: self.clock())
        }
        timer.tolerance = tickInterval / 6
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.invalidate()
        timer = nil
        let effects = SessionReducer.shutDown(&state, now: clock())
        publish()
        perform(effects)
        // Belt and braces: whatever is still held is let go.
        for handle in handles.values { release(handle) }
        handles.removeAll()
    }

    // MARK: - Housekeeping

    /// One round of housekeeping: dead processes, idle cards, ended cards, reminders, and settings
    /// that hide sessions. The timer calls this every few seconds; tests call it with any time they like.
    func tick(now: Date) {
        dispatchPrecondition(condition: .onQueue(.main))
        let effects = SessionReducer.tick(&state, now: now, config: EngineConfig(settings: settings),
                                          processIdentity: processIdentity)
        publish()
        perform(effects)
    }

    // MARK: - Reply handles

    private func answer(_ handle: ReplyHandle, _ plan: IncomingReply) {
        switch plan {
        case .hold(let requestID):
            hold(handle, for: requestID)
        case .replace(let requestID):
            if let old = handles.removeValue(forKey: requestID) { release(old) }
            hold(handle, for: requestID)
        case .passthrough:
            handle.reply(.passthrough)
        case .autoAllow(let request):
            let reply = encode(.allow, for: request)
            handle.reply(reply)
            log(.outgoing, agent: request.agent, event: "Decision", sessionID: request.sessionID,
                summary: "Perch answered for you: allowed", raw: reply.stdout)
        }
    }

    private func hold(_ handle: ReplyHandle, for requestID: UUID) {
        handles[requestID] = handle
        handle.onDisconnect = { [weak self] in self?.helperDisconnected(requestID) }
    }

    /// Lets a helper go without an answer, so the agent falls back to its own prompt.
    private func release(_ handle: ReplyHandle) {
        handle.onDisconnect = nil
        handle.close()
    }

    /// The helper went away before a decision was sent (see `ReplyHandle.onDisconnect`).
    private func helperDisconnected(_ requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard handles.removeValue(forKey: requestID) != nil else { return }
        let effects = SessionReducer.replyDisconnected(&state, requestID: requestID, now: clock())
        publish()
        perform(effects)
    }

    private func encode(_ decision: Decision, for request: PendingRequest) -> HookReply {
        if decision == .passToTerminal { return .passthrough }
        guard let adapter = adapters[request.agent] else {
            // Without the adapter Perch cannot speak the agent's language; saying nothing is the safe answer.
            Log.error("no adapter for \(request.agent.rawValue); the request was handed back to the terminal", "engine")
            return .passthrough
        }
        return adapter.encode(decision, for: request)
    }

    // MARK: - Carrying out effects

    private func perform(_ effects: [EngineEffect]) {
        // Asking "is that terminal tab in front?" can be slow, so ask at most once per session here.
        var lookingAt: [String: Bool] = [:]
        func userIsLooking(at sessionID: String) -> Bool {
            if let known = lookingAt[sessionID] { return known }
            var result = false
            if settings.muteWhenTerminalFocused, let jumper, let session = state.session(sessionID) {
                result = jumper.isFrontmost(session)
            }
            lookingAt[sessionID] = result
            return result
        }

        for effect in effects {
            switch effect {
            case .pulse(let kind, let sessionID):
                store.pulse = Pulse(kind: kind, sessionID: sessionID, at: clock())
            case .sound(let cue, let sessionID):
                // No need to chime about a session the user is looking at right now.
                if Self.cuesMutedWhenFocused.contains(cue) && userIsLooking(at: sessionID) { continue }
                sounds?.play(cue)
            case .notify(let title, let body, let sessionID):
                if userIsLooking(at: sessionID) { continue }
                notifier?.notify(title: title, body: body, sessionID: sessionID)
            case .closeReply(let requestID):
                if let handle = handles.removeValue(forKey: requestID) { release(handle) }
            case .sendDecision(let decision, let request):
                send(decision, for: request)
            case .note(let event, let summary, let agent, let sessionID):
                log(.note, agent: agent, event: event, sessionID: sessionID, summary: summary, raw: "")
            case .incomingReply:
                break   // handled in `ingest`, where the helper is at hand
            }
        }
    }

    /// The cues that are about "look at this session", which is pointless when it is already in front.
    private static let cuesMutedWhenFocused: Set<SoundCue> = [.needsApproval, .needsAnswer, .done, .failed, .reminder]

    private func send(_ decision: Decision, for request: PendingRequest) {
        let reply = encode(decision, for: request)
        if let handle = handles.removeValue(forKey: request.id) {
            handle.onDisconnect = nil
            handle.reply(reply)
        }
        log(.outgoing, agent: request.agent, event: "Decision", sessionID: request.sessionID,
            summary: ActivitySummary.describe(decision, for: request), raw: reply.stdout)
        if decision != .passToTerminal { usage?.recordDecision(decision, for: request) }
    }

    // MARK: - Keeping the store in step

    /// Copies the engine's sessions and visible requests into the store. Entries the engine did
    /// not put there (demo mode adds its own) are left exactly where they are.
    private func publish() {
        let sessions = Self.merge(current: store.sessions, mine: state.sessions, published: publishedSessionIDs) { $0.id }
        if sessions != store.sessions { store.sessions = sessions }
        publishedSessionIDs = Set(state.sessions.map { $0.id })

        let requests = state.visibleRequests
        let pending = Self.merge(current: store.pending, mine: requests, published: publishedRequestIDs) { $0.id }
        if pending != store.pending { store.pending = pending }
        publishedRequestIDs = Set(requests.map { $0.id })
    }

    /// Rebuilds a store list: the engine's entries (in the engine's order) take the slots its
    /// entries had before, anything new goes at the end, and other people's entries do not move.
    static func merge<Item, ID: Hashable>(current: [Item], mine: [Item], published: Set<ID>, id: (Item) -> ID) -> [Item] {
        let mineIDs = Set(mine.map(id))
        var queue = mine[...]
        var result: [Item] = []
        result.reserveCapacity(current.count + mine.count)
        for item in current {
            if published.contains(id(item)) || mineIDs.contains(id(item)) {
                if let next = queue.popFirst() { result.append(next) }
            } else {
                result.append(item)
            }
        }
        result.append(contentsOf: queue)
        return result
    }

    // MARK: - Activity log

    private func logIncoming(_ event: NormalizedEvent) {
        guard settings.activityLogEnabled else { return }
        let sessionID = Session.makeID(event.agent, event.sessionID)
        let entry = ActivityEntry(at: event.context.receivedAt, direction: .incoming, agent: event.agent.rawValue,
                                  event: event.rawEventName, sessionID: sessionID,
                                  summary: ActivitySummary.describe(event), raw: ActivitySummary.rawText(event.raw))
        // Usage numbers can arrive many times a minute. Keep only the latest of a run, so they do
        // not push everything else out of the log.
        if case .usageUpdated = event.event, let top = store.activity.first, top.direction == .incoming,
           top.sessionID == sessionID, top.event == event.rawEventName, top.summary.hasPrefix("Usage") {
            store.activity[0] = entry
            return
        }
        append(entry)
    }

    private func log(_ direction: ActivityEntry.Direction, agent: AgentKind, event: String, sessionID: String?,
                     summary: String, raw: String) {
        guard settings.activityLogEnabled else { return }
        append(ActivityEntry(at: clock(), direction: direction, agent: agent.rawValue, event: event, sessionID: sessionID,
                             summary: summary, raw: EngineText.clipBytes(raw)))
    }

    private func append(_ entry: ActivityEntry) {
        var activity = store.activity
        activity.insert(entry, at: 0)
        if activity.count > EngineTuning.activityCap { activity.removeLast(activity.count - EngineTuning.activityCap) }
        store.activity = activity
    }
}
