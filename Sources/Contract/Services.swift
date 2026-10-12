// Services.swift — the jobs in the app, described as protocols.
//
// Each protocol is implemented by one module under Sources/Core or Sources/App. Modules only
// know each other through these protocols and the stores, which keeps every piece small enough
// to read on its own.
//
// Threading rule for the whole app: stores are read and written on the MAIN thread only.
// Services may work on background queues but must hop to main before touching a store or
// calling a callback declared here.

import Foundation
import SwiftUI

// MARK: - Socket server (Sources/Core/Runtime)

/// A waiting helper process. Exactly one of `reply` / `close` should be called, once.
protocol ReplyHandle: AnyObject {
    var id: UUID { get }
    /// Sends the reply line and closes the connection.
    func reply(_ reply: HookReply)
    /// Closes without replying; the helper then exits 0 with no output (agent shows its own prompt).
    func close()
    /// Called on the main thread if the helper goes away before a reply was sent — for example
    /// because the user answered in the terminal and the agent killed the hook.
    var onDisconnect: (() -> Void)? { get set }
}

protocol HookServing: AnyObject {
    /// Called on the main thread for every envelope. The handle is non-nil only when `wantsReply` is true.
    var onEnvelope: ((HookEnvelope, ReplyHandle?) -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

// MARK: - Agent adapters (Sources/Core/Adapters)

/// Everything agent-specific lives behind this protocol.
protocol AgentAdapter: AnyObject {
    var kind: AgentKind { get }
    var capabilities: AgentCapabilities { get }

    /// Is the agent installed, and are Perch's hooks in place? May read small config files.
    func status() -> AgentStatus
    /// Adds Perch's hooks to the agent's config without disturbing anything else. Backs the file up
    /// first (into PerchPaths.backupsDir). Returns a plain-English summary of what changed.
    func installHooks() throws -> String
    /// Removes only what `installHooks` added. Returns a plain-English summary.
    func uninstallHooks() throws -> String

    /// Translates one raw envelope into normalized events (possibly none).
    func normalize(_ envelope: HookEnvelope) -> [NormalizedEvent]
    /// Builds the exact reply the agent expects for the user's decision on a request.
    func encode(_ decision: Decision, for request: PendingRequest) -> HookReply

    /// For agents that are watched through files instead of (or as well as) hooks. `emit` must be
    /// called on the main thread. Adapters with nothing to watch do nothing.
    func startMonitoring(emit: @escaping ([NormalizedEvent]) -> Void)
    func stopMonitoring()
}

extension AgentAdapter {
    func startMonitoring(emit: @escaping ([NormalizedEvent]) -> Void) {}
    func stopMonitoring() {}
}

// MARK: - Session engine (Sources/Core/Engine)

/// Turns normalized events into session state and manages requests waiting on the user.
protocol SessionEngineProtocol: AnyObject {
    /// Applies events to the SessionStore. `reply` is the waiting helper for a blocking request, if any.
    func ingest(_ events: [NormalizedEvent], reply: ReplyHandle?)
    /// Answers a pending request: encodes the decision with the agent's adapter and replies to the helper.
    func resolve(_ requestID: UUID, with decision: Decision)
    /// Removes a session card (does not affect the agent).
    func dismiss(sessionID: String)
    /// Starts / stops the housekeeping timers (dead-process checks, idle cleanup, reminders).
    func start()
    func stop()
}

// MARK: - System integration (Sources/Core/System)

enum JumpResult: Equatable {
    case focused            // the exact tab / pane was brought to the front
    case activatedApp       // only the app could be brought forward
    case failed(String)     // plain-English reason
}

protocol TerminalJumping: AnyObject {
    /// Brings the session's terminal (or editor) to the front. Call on the main thread.
    func jump(to session: Session) -> JumpResult
    /// True when the session's own tab is already frontmost (used to stay quiet).
    func isFrontmost(_ session: Session) -> Bool
}

enum SoundCue: String, CaseIterable, Identifiable {
    case sessionStart, needsApproval, needsAnswer, done, failed, approved, denied, reminder
    var id: String { rawValue }
}

protocol SoundPlaying: AnyObject {
    /// Plays a cue, honouring the user's sound settings (mute, per-cue toggles, quiet hours, volume).
    func play(_ cue: SoundCue)
    /// Plays a cue regardless of mute settings, for the Settings preview buttons.
    func preview(_ cue: SoundCue)
}

protocol SystemNotifying: AnyObject {
    /// Posts a macOS notification if the user enabled them. `sessionID` lets a click jump to the session.
    func notify(title: String, body: String, sessionID: String?)
}

// MARK: - Usage (Sources/Core/Usage)

protocol UsageEngineProtocol: AnyObject {
    func start()
    func stop()
    /// Rescans usage sources now (off the main thread) and updates UsageStore.
    func refreshNow()
    /// Lets the engine tally activity stats and pick up live usage numbers from events.
    func observe(_ event: NormalizedEvent)
    /// Records that the user handled a request, for the daily activity tally.
    func recordDecision(_ decision: Decision, for request: PendingRequest)
    /// Deletes Perch's own saved statistics (never the agents' files).
    func clearSavedStats()
}

// MARK: - Actions views can trigger (implemented by the app controller in Sources/App)

protocol AppActions: AnyObject {
    func resolve(_ request: PendingRequest, _ decision: Decision)
    func jump(to session: Session)
    func dismiss(_ session: Session)
    func setExpanded(_ expanded: Bool)
    func openSettings(_ tab: SettingsTab?)
    func refreshAgents()
    func installHooks(for agent: AgentKind)
    func uninstallHooks(for agent: AgentKind)
    func refreshUsage()
    func clearSavedStats()
    func previewSound(_ cue: SoundCue)
    func toggleMute()
    func setDemo(_ on: Bool)
    func clearActivityLog()
    func copyDiagnostics()
    func revealSupportFolder()
    /// Removes Perch's hooks from every agent and deletes its support folder contents, then quits.
    func uninstallEverything()
    func quit()
}

/// Does nothing. Used in previews, snapshots and tests.
final class NoopActions: AppActions {
    init() {}
    func resolve(_ request: PendingRequest, _ decision: Decision) {}
    func jump(to session: Session) {}
    func dismiss(_ session: Session) {}
    func setExpanded(_ expanded: Bool) {}
    func openSettings(_ tab: SettingsTab?) {}
    func refreshAgents() {}
    func installHooks(for agent: AgentKind) {}
    func uninstallHooks(for agent: AgentKind) {}
    func refreshUsage() {}
    func clearSavedStats() {}
    func previewSound(_ cue: SoundCue) {}
    func toggleMute() {}
    func setDemo(_ on: Bool) {}
    func clearActivityLog() {}
    func copyDiagnostics() {}
    func revealSupportFolder() {}
    func uninstallEverything() {}
    func quit() {}
}

// MARK: - SwiftUI plumbing

private struct PerchActionsKey: EnvironmentKey {
    static let defaultValue: AppActions = NoopActions()
}

extension EnvironmentValues {
    /// How views ask the app to do something: `@Environment(\.perchActions) private var actions`.
    var perchActions: AppActions {
        get { self[PerchActionsKey.self] }
        set { self[PerchActionsKey.self] = newValue }
    }
}

extension View {
    /// Injects every store and the actions object. Root views call this once; child views then use
    /// `@EnvironmentObject var settings: AppSettings` (and SessionStore, UsageStore, AgentsStore, UIState).
    func perchEnvironment(_ env: AppEnv) -> some View {
        self.environmentObject(env.settings)
            .environmentObject(env.sessions)
            .environmentObject(env.usage)
            .environmentObject(env.agents)
            .environmentObject(env.ui)
            .environment(\.perchActions, env.actions)
    }
}
