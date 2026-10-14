// RateWindowKind.swift — tells a short (5-hour) usage limit from a long (weekly) one.
//
// The label says it best: Codex's "primary" window, for example, can be its weekly limit.
// The id is only used when the label gives no hint. Shared by the pill, the panel and the cards.

import Foundation

extension RateWindow {
    var isShortWindow: Bool {
        let text = label.lowercased()
        if text.contains("week") || text.contains("7-day") { return false }
        if text.contains("hour") { return true }
        return ["5h", "primary", "five_hour", "session"].contains(id)
    }
}
