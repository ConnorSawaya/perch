// UsageLimits.swift — remembers the latest rate-limit numbers of each agent.
//
// Rate limits ("37% of your 5-hour limit used, resets at 15:00") are never computed by Perch.
// The agents report them: Claude Code through its status line, Codex inside its session files.
// A report is only as fresh as the agent's last API response, so each window is stored with the
// time it was reported, and:
//   • a newer report replaces an older one, window by window (a report may hold just one window);
//   • once a window's reset time has passed, the stored percentage is known to be out of date,
//     so the window is shown as 0% with no reset time until the agent reports again.
//
// A plain value type: UsageEngine owns one on the main thread and saves it as JSON.

import Foundation

struct LimitBook: Codable, Equatable {
    struct Reading: Codable, Equatable {
        var window: RateWindow
        var capturedAt: Date
    }

    struct AgentLimits: Codable, Equatable {
        var readings: [Reading] = []
        var planName: String?
        var planCapturedAt: Date?
        /// Window id → reset time (seconds since 1970) of the period a warning was already given for.
        var warned: [String: Double] = [:]
    }

    /// Keyed by `AgentKind.rawValue` (text keys keep the saved JSON a plain object).
    private var agents: [String: AgentLimits] = [:]

    /// Windows people look at first come first; anything else keeps the order it arrived in.
    private static let preferredOrder = ["5h", "7d", "spend", "primary", "secondary"]

    /// Takes in a report. Returns true when anything changed.
    @discardableResult
    mutating func merge(_ report: LimitReport) -> Bool {
        var entry = agents[report.agent.rawValue] ?? AgentLimits()
        let before = entry
        for var window in report.windows {
            guard !window.id.isEmpty, window.usedPercent.isFinite else { continue }
            window.usedPercent = min(100, max(0, window.usedPercent))
            if let index = entry.readings.firstIndex(where: { $0.window.id == window.id }) {
                // An older report (a file read late) never overwrites a newer one.
                guard report.capturedAt >= entry.readings[index].capturedAt else { continue }
                entry.readings[index] = Reading(window: window, capturedAt: report.capturedAt)
            } else {
                entry.readings.append(Reading(window: window, capturedAt: report.capturedAt))
            }
        }
        if let plan = report.planName, !plan.isEmpty, report.capturedAt >= (entry.planCapturedAt ?? .distantPast) {
            entry.planName = plan
            entry.planCapturedAt = report.capturedAt
        }
        // Well-known windows first; the others after them, in the order they first arrived.
        entry.readings = entry.readings.enumerated()
            .map { (rank: Self.preferredOrder.firstIndex(of: $1.window.id) ?? Self.preferredOrder.count + $0, reading: $1) }
            .sorted { $0.rank < $1.rank }
            .map(\.reading)
        agents[report.agent.rawValue] = entry
        return entry != before
    }

    /// The windows to show at `now`. A window whose reset time has passed shows 0% and no reset time.
    func windows(for agent: AgentKind, at now: Date) -> [RateWindow] {
        (agents[agent.rawValue]?.readings ?? []).map { reading in
            var window = reading.window
            if let resetsAt = window.resetsAt, resetsAt <= now {
                window.usedPercent = 0
                window.resetsAt = nil
            }
            return window
        }
    }

    /// Labels of windows whose reset time has passed since they were reported.
    func expiredLabels(for agent: AgentKind, at now: Date) -> [String] {
        (agents[agent.rawValue]?.readings ?? []).compactMap { reading in
            guard let resetsAt = reading.window.resetsAt, resetsAt <= now else { return nil }
            return reading.window.label
        }
    }

    /// When the most recent report for this agent was made.
    func lastUpdate(for agent: AgentKind) -> Date? {
        agents[agent.rawValue]?.readings.map(\.capturedAt).max()
    }

    func planName(for agent: AgentKind) -> String? { agents[agent.rawValue]?.planName }

    /// Windows that are at or above `threshold` percent and have not been warned about in their
    /// current period. Calling this marks them as warned, so each period warns once.
    mutating func windowsNeedingWarning(for agent: AgentKind, threshold: Double, at now: Date) -> [RateWindow] {
        guard var entry = agents[agent.rawValue] else { return [] }
        var due: [RateWindow] = []
        for reading in entry.readings {
            let window = reading.window
            let expired = window.resetsAt.map { $0 <= now } ?? false
            guard window.usedPercent >= threshold, !expired else {
                if window.usedPercent < threshold { entry.warned[window.id] = nil }
                continue
            }
            // Reset times can wobble by a few seconds between reports; an hour apart is a new period.
            let period = window.resetsAt?.timeIntervalSince1970 ?? 0
            if let already = entry.warned[window.id], abs(already - period) < 3600 { continue }
            entry.warned[window.id] = period
            due.append(window)
        }
        agents[agent.rawValue] = entry
        return due
    }
}
