// UsageNotes.swift — the plain-English caveat shown under each agent's usage numbers.
//
// The numbers on the usage screen come from different places and have different limits. The
// note says, in a few short sentences, where the tokens and the limits come from, when the
// limits were last updated, and that the dollar figure is an estimate at list prices.

import Foundation

enum UsageNotes {
    struct Facts {
        var agent: AgentKind
        /// True when the ledger holds any usage for this agent.
        var hasTokens = false
        var unpricedModels: [String] = []
        var hasLimits = false
        var limitsUpdatedAt: Date?
        /// Labels of windows whose reset time has passed since they were reported.
        var expiredLabels: [String] = []
        /// Windows at or above the user's warning level (empty when warnings are off).
        var warnings: [RateWindow] = []
        /// False when cost estimates are hidden in Settings; the note then says nothing about cost.
        var showsCost = true
    }

    static func note(_ facts: Facts, now: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        var sentences: [String] = []
        for window in facts.warnings {
            sentences.append("Heads-up: the \(window.label) is at \(Int(window.usedPercent.rounded()))%.")
        }
        let updated = facts.limitsUpdatedAt.map { " and were last updated \(when($0, now: now, timeZone: timeZone, locale: locale))" } ?? ""

        switch facts.agent {
        case .claude:
            sentences.append("Tokens are counted from Claude Code's transcripts on this Mac, so other devices and Claude Code's own background requests are not included.")
            if facts.showsCost { sentences.append("Cost is an estimate at API list prices, not a bill.") }
            if facts.hasLimits {
                sentences.append("Limits come from Claude Code's status line\(updated).")
            } else {
                sentences.append("Limits appear here once Claude Code's status line reports them to Perch.")
            }
        case .codex:
            if facts.hasLimits {
                sentences.append("Tokens and limits are read from Codex's session files on this Mac; the limits are as fresh as Codex's last reply\(updated).")
            } else {
                sentences.append("Tokens are read from Codex's session files on this Mac. Limits appear here once Codex reports them.")
            }
        case .gemini:
            sentences.append("Tokens are read from Gemini CLI's session files on this Mac.")
            if facts.hasLimits {
                sentences.append("Limits come from Gemini CLI\(updated).")
            } else {
                sentences.append("Gemini CLI does not share its limits without your login, so Perch shows none.")
            }
        case .antigravity:
            if facts.hasLimits {
                sentences.append("Limits come from Antigravity's status feed\(updated).")
            } else {
                sentences.append("Limits appear here once Antigravity's status feed reports them to Perch.")
            }
            if !facts.hasTokens { sentences.append("Antigravity keeps no token history that Perch can read.") }
        }

        if !facts.expiredLabels.isEmpty {
            let names = list(facts.expiredLabels.map { "the \($0)" })
            let one = facts.expiredLabels.count == 1
            sentences.append("\(names.prefix(1).uppercased() + names.dropFirst()) \(one ? "has" : "have") reset since then and \(one ? "shows" : "show") 0% until the next update.")
        }
        if facts.showsCost, let caveat = costCaveat(facts) { sentences.append(caveat) }
        return sentences.joined(separator: " ")
    }

    /// Why a cost figure is missing or too low, if it is.
    private static func costCaveat(_ facts: Facts) -> String? {
        if facts.agent != .claude {
            guard facts.hasTokens else { return nil }
            return "No cost is estimated because Perch has no verified price list for \(facts.agent.displayName) models."
        }
        guard !facts.unpricedModels.isEmpty else { return nil }
        return "No list price is known for \(list(facts.unpricedModels)), so \(facts.unpricedModels.count == 1 ? "its" : "their") tokens are counted at $0."
    }

    /// "today at 14:32", "yesterday at 09:05", "on 9 Oct at 14:32".
    static func when(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        let days = LocalDays(timeZone: timeZone)
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        let clock = time.string(from: date)
        let day = days.day(of: date)
        if day == days.day(of: now) { return "today at \(clock)" }
        if day == days.lastDays(2, endingAt: now).first { return "yesterday at \(clock)" }
        let calendarDay = DateFormatter()
        calendarDay.locale = locale
        calendarDay.timeZone = timeZone
        calendarDay.setLocalizedDateFormatFromTemplate("d MMM")
        return "on \(calendarDay.string(from: date)) at \(clock)"
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
