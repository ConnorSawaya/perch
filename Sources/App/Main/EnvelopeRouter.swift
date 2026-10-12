// EnvelopeRouter.swift — decides where each message from a hook helper goes.
//
// Every message the socket server receives (a HookEnvelope) passes through `route`:
//
//   channel "debug"            → answered at once with a JSON description of the app's state
//   unknown or switched-off agent → answered at once with "no opinion" (HookReply.passthrough)
//   anything else              → the agent's adapter translates it, the session engine applies it
//
// The one rule that matters most here: a helper that is waiting for an answer must never be left
// hanging. Every path below either replies or hands the helper to the engine, which promises
// the same (it answers "no opinion" itself when the adapter produced nothing to decide).
//
// Main thread only, like everything that touches the adapters and the engine.

import Foundation

final class EnvelopeRouter {
    /// How many messages took each path. Shown by the debug channel and the diagnostics.
    struct Counts: Equatable {
        var received = 0
        var debugQueries = 0
        /// Messages for agents Perch does not know, or that are switched off in Settings.
        var turnedAway = 0
        /// Messages the adapter read but that meant nothing to it.
        var withoutEvents = 0
        var eventsIngested = 0
        var fromFileWatchers = 0
    }

    private let adapters: [AgentKind: AgentAdapter]
    private let settings: AppSettings
    private let engine: SessionEngineProtocol
    private(set) var counts = Counts()

    /// Supplies the text for the debug channel. Set by the app controller.
    var debugReport: () -> String = { "{}" }

    init(adapters: [AgentKind: AgentAdapter], settings: AppSettings, engine: SessionEngineProtocol) {
        self.adapters = adapters
        self.settings = settings
        self.engine = engine
    }

    /// Handles one message from the socket. `handle` is the waiting helper, when there is one.
    func route(_ envelope: HookEnvelope, _ handle: ReplyHandle?) {
        dispatchPrecondition(condition: .onQueue(.main))
        counts.received += 1

        if envelope.channel == Self.debugChannel {
            counts.debugQueries += 1
            handle?.reply(HookReply(stdout: debugReport(), exitCode: 0))
            return
        }
        guard let kind = AgentKind(rawValue: envelope.agent), let adapter = adapters[kind], settings.isEnabled(kind) else {
            counts.turnedAway += 1
            handle?.reply(.passthrough)
            return
        }
        let events = adapter.normalize(envelope)
        if events.isEmpty { counts.withoutEvents += 1 }
        counts.eventsIngested += events.count
        // Called even with no events: the engine then lets the waiting helper go.
        engine.ingest(events, reply: handle)
    }

    /// Handles events an adapter read from the agent's own files (no helper is involved).
    func ingestWatched(_ events: [NormalizedEvent]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let wanted = events.filter { settings.isEnabled($0.agent) }
        guard !wanted.isEmpty else { return }
        counts.fromFileWatchers += wanted.count
        engine.ingest(wanted, reply: nil)
    }

    static let debugChannel = "debug"
}
