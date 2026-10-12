// ClaudeStatusLineReader.swift — picks the usage numbers out of Claude Code's status line data.
//
// Every time Claude Code redraws its status line it hands the status line command a JSON object
// with the model, the session's cost so far, how full the context window is and — for
// subscribers — how much of the 5-hour and weekly limits is used. Perch's status line script
// forwards that object here. Field meanings follow docs/research/claude-usage.md §6; every
// field can be missing or null (the first render of a session has almost nothing).

import Foundation

enum ClaudeStatusLineReader {
    struct Reading: Equatable {
        /// 0...100, or nil before the first reply of a session.
        var contextPercent: Double?
        var windows: [RateWindow] = []
        var modelID: String?
        var modelDisplayName: String?
        var costUSD: Double?
        /// The session's name or generated title, once it has one.
        var sessionName: String?
    }

    /// The rate-limit windows Claude Code may report, in display order.
    private static let knownWindows: [(key: String, id: String, label: String)] = [
        ("five_hour", "5h", "5-hour limit"),
        ("seven_day", "7d", "Weekly limit"),
        ("spend_limit", "spend", "Spend limit"),
    ]

    static func read(_ payload: JSONValue) -> Reading {
        var reading = Reading()
        reading.contextPercent = contextPercent(payload["context_window"])
        for window in knownWindows {
            let entry = payload["rate_limits"][window.key]
            guard let used = entry["used_percentage"].doubleValue, used.isFinite else { continue }
            let resets = entry["resets_at"].doubleValue.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            reading.windows.append(RateWindow(id: window.id, label: window.label, usedPercent: clamp(used), resetsAt: resets))
        }
        reading.modelID = nonEmpty(payload["model"]["id"].stringValue)
        reading.modelDisplayName = nonEmpty(payload["model"]["display_name"].stringValue)
        reading.costUSD = payload["cost"]["total_cost_usd"].doubleValue
        reading.sessionName = nonEmpty(payload["session_name"].stringValue)
        return reading
    }

    /// Share of the context window in use. Claude Code's own `used_percentage` is rounded to a
    /// whole number, so when the token counts of the latest reply are there we work it out exactly.
    static func contextPercent(_ window: JSONValue) -> Double? {
        let usage = window["current_usage"]
        let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .reduce(0.0) { $0 + (usage[$1].doubleValue ?? 0) }
        if tokens > 0, let size = window["context_window_size"].doubleValue, size > 0 {
            return clamp(tokens / size * 100)
        }
        return window["used_percentage"].doubleValue.map(clamp)
    }

    private static func clamp(_ percent: Double) -> Double { min(100, max(0, percent)) }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
