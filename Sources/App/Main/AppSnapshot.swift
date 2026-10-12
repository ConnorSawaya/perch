// AppSnapshot.swift — "what is the app doing right now?", as plain data and in two written forms.
//
// AppController fills in an AppSnapshot from the stores, the engine and the socket server. It is
// then written out as:
//
//   DebugReport.json(_:)     JSON for the debug channel. A test (or a curious person) asks with
//                               perch-hook --agent perch --channel debug --wait
//                            and gets one line describing sessions, requests, server and hooks.
//                            It can only be asked through Perch's private socket on this Mac.
//   Diagnostics.text(_:)     the text "Copy diagnostics" puts on the clipboard: versions, paths,
//                            hook status and the end of the log. It deliberately contains no
//                            titles, prompts, commands or messages — nothing of a conversation.

import Foundation

struct AppSnapshot {
    var version: String
    var processID: Int32
    var launchedAt: Date
    var takenAt: Date
    var options: LaunchOptions
    var supportDir: String
    var socketPath: String
    var serverRunning: Bool
    /// Helpers connected to the socket right now (nearly always: waiting for an answer).
    var connections: Int
    /// Helpers the engine is holding for a request card.
    var waitingHelpers: Int
    var helperInstalled: Bool
    var isDemo: Bool
    var isExpanded: Bool
    /// The cards on screen.
    var sessions: [Session]
    /// Sessions the engine knows, including ones whose cards are hidden by settings.
    var engineSessionCount: Int
    /// Requests shown as cards (a helper is waiting for each).
    var pending: [PendingRequest]
    /// Requests the engine tracks in total, including ones that can only be answered in the terminal.
    var trackedRequestCount: Int
    var statuses: [AgentStatus]
    var enabledAgents: [AgentKind]
    var counts: EnvelopeRouter.Counts
    var activityCount: Int
    /// The newest lines of the activity log, newest first (for the debug channel only).
    var recentActivity: [ActivityEntry] = []
}

enum DebugReport {
    static func json(_ snapshot: AppSnapshot) -> String {
        let report: JSONValue = [
            "app": [
                "version": .string(snapshot.version),
                "pid": .number(Double(snapshot.processID)),
                "uptimeSeconds": .number(snapshot.takenAt.timeIntervalSince(snapshot.launchedAt).rounded()),
                "supportDir": .string(snapshot.supportDir),
                "demo": .bool(snapshot.isDemo),
                "expanded": .bool(snapshot.isExpanded),
                "autoResolve": text(snapshot.options.autoResolve?.rawValue),
                "loginItemHandling": .bool(!snapshot.options.skipLoginItem),
            ],
            "server": [
                "running": .bool(snapshot.serverRunning),
                "socket": .string(snapshot.socketPath),
                "connections": .number(Double(snapshot.connections)),
                "waitingHelpers": .number(Double(snapshot.waitingHelpers)),
            ],
            "helperInstalled": .bool(snapshot.helperInstalled),
            "sessions": .array(snapshot.sessions.map(session)),
            "pending": .array(snapshot.pending.map { request($0, now: snapshot.takenAt) }),
            "agents": .array(snapshot.statuses.map(agent)),
            "enabledAgents": .array(snapshot.enabledAgents.map { .string($0.rawValue) }),
            "recentActivity": .array(snapshot.recentActivity.map { entry in
                ["event": .string(entry.event), "direction": .string(entry.direction.rawValue), "agent": .string(entry.agent),
                 "sessionID": text(entry.sessionID), "summary": .string(entry.summary)]
            }),
            "counts": [
                "sessions": .number(Double(snapshot.sessions.count)),
                "engineSessions": .number(Double(snapshot.engineSessionCount)),
                "pending": .number(Double(snapshot.pending.count)),
                "trackedRequests": .number(Double(snapshot.trackedRequestCount)),
                "needingAttention": .number(Double(snapshot.sessions.filter { $0.state.needsAttention }.count)),
                "activity": .number(Double(snapshot.activityCount)),
                "envelopes": .number(Double(snapshot.counts.received)),
                "debugQueries": .number(Double(snapshot.counts.debugQueries)),
                "turnedAway": .number(Double(snapshot.counts.turnedAway)),
                "withoutEvents": .number(Double(snapshot.counts.withoutEvents)),
                "eventsIngested": .number(Double(snapshot.counts.eventsIngested)),
                "fromFileWatchers": .number(Double(snapshot.counts.fromFileWatchers)),
            ],
        ]
        return report.serialized()
    }

    private static func session(_ session: Session) -> JSONValue {
        [
            "id": .string(session.id),
            "agent": .string(session.agent.rawValue),
            "sessionID": .string(session.sessionID),
            "state": .string(session.state.rawValue),
            "title": .string(session.title),
            "cwd": .string(session.cwd),
            "model": text(session.model),
            "currentTool": text(session.currentTool?.name),
            "recentTools": .array(session.recentTools.map { .string($0.name) }),
            "toolCount": .number(Double(session.toolCount)),
            "turnCount": .number(Double(session.turnCount)),
            "activeSubagents": .number(Double(session.activeSubagents)),
            "pid": session.pid.map { .number(Double($0)) } ?? .null,
            "tty": text(session.terminal.tty),
            "hostBundleID": text(session.terminal.bundleID),
            "permissionMode": text(session.permissionMode),
            "gitBranch": text(session.gitBranch),
            "lastMessage": text(session.lastMessage),
            "errorText": text(session.errorText),
            "contextPercent": session.contextPercent.map { .number($0) } ?? .null,
            "isHeadless": .bool(session.isHeadless),
            "isDemo": .bool(session.isDemo),
        ]
    }

    private static func request(_ request: PendingRequest, now: Date) -> JSONValue {
        var kind = "permission", tool = JSONValue.null, detail = JSONValue.null
        switch request.kind {
        case .permission(let permission):
            tool = .string(permission.toolName)
            detail = .string(permission.detail)
        case .question(let question):
            kind = "question"
            detail = text(question.questions.first?.text)
        case .plan:
            kind = "plan"
        }
        return [
            "id": .string(request.id.uuidString),
            "sessionID": .string(request.sessionID),
            "agent": .string(request.agent.rawValue),
            "kind": .string(kind),
            "tool": tool,
            "detail": detail,
            "ageSeconds": .number((now.timeIntervalSince(request.createdAt) * 10).rounded() / 10),
        ]
    }

    private static func agent(_ status: AgentStatus) -> JSONValue {
        [
            "agent": .string(status.agent.rawValue),
            "detected": .bool(status.detected),
            "version": text(status.version),
            "hookStatus": .string(status.hookStatus.rawValue),
            "configPath": text(status.configPath),
            "detail": .string(status.detail),
        ]
    }

    /// A string or JSON null. (Written out because `condition ? .string(x) : nil` would not do
    /// what it looks like for this type.)
    private static func text(_ value: String?) -> JSONValue {
        value.map { .string($0) } ?? .null
    }
}

enum Diagnostics {
    /// How many lines from the end of the log are included.
    static let logLineCount = 100

    static func text(_ snapshot: AppSnapshot, logTail: [String]) -> String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [String] = []
        lines.append("Perch diagnostics")
        lines.append("Perch \(snapshot.version), macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
        lines.append("Running for \(Int(snapshot.takenAt.timeIntervalSince(snapshot.launchedAt))) s, process \(snapshot.processID)")
        lines.append("")
        lines.append("Where things are")
        lines.append("  Perch's folder: \(snapshot.supportDir)")
        lines.append("  Socket:         \(snapshot.socketPath)")
        lines.append("  Listening:      \(yesNo(snapshot.serverRunning)) (\(snapshot.connections) helpers connected, \(snapshot.waitingHelpers) waiting for an answer)")
        lines.append("  Helper present: \(yesNo(snapshot.helperInstalled))")
        lines.append("")
        lines.append("Agents")
        for status in snapshot.statuses {
            let enabled = snapshot.enabledAgents.contains(status.agent) ? "shown" : "switched off"
            lines.append("  \(status.agent.displayName): \(status.hookStatus.rawValue), version \(status.version ?? "unknown"), \(enabled)")
            if let path = status.configPath { lines.append("    settings file: \(path)") }
            lines.append("    \(status.detail)")
        }
        if snapshot.statuses.isEmpty { lines.append("  (not checked yet)") }
        lines.append("")
        lines.append("Right now")
        let states = Dictionary(grouping: snapshot.sessions, by: { $0.state.rawValue })
            .map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
        lines.append("  Sessions shown: \(snapshot.sessions.count)" + (states.isEmpty ? "" : " (\(states))"))
        lines.append("  Sessions known to the engine: \(snapshot.engineSessionCount)")
        lines.append("  Requests waiting: \(snapshot.pending.count) with a card, \(snapshot.trackedRequestCount) tracked")
        lines.append("  Messages received: \(snapshot.counts.received) (\(snapshot.counts.eventsIngested) events, "
                     + "\(snapshot.counts.turnedAway) turned away, \(snapshot.counts.withoutEvents) not understood, "
                     + "\(snapshot.counts.fromFileWatchers) from files)")
        lines.append("  Demo mode: \(yesNo(snapshot.isDemo))")
        lines.append("")
        lines.append("Last \(logTail.count) log lines")
        lines.append(contentsOf: logTail.isEmpty ? ["  (the log is empty)"] : logTail.map { "  " + $0 })
        return lines.joined(separator: "\n") + "\n"
    }

    /// The last `count` lines of the log file, read without loading a large file whole.
    static func logTail(of url: URL = Log.fileURL, count: Int = logLineCount) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let wanted: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > wanted ? size - wanted : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(count).map(String.init)
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}
