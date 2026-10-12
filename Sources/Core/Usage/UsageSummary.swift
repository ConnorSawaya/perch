// UsageSummary.swift — turns the ledger's slices into the per-day totals the views show.
//
// The ledger stores times in UTC. "Today" and "this day last week" depend on where the user is,
// so days are worked out here, at the moment a summary is built, in the user's CURRENT time
// zone. After a flight or a daylight-saving switch the whole history is regrouped consistently.

import Foundation

/// Local calendar days as "yyyy-MM-dd" text, the form DayUsage and DailyActivity use.
struct LocalDays {
    let calendar: Calendar

    init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    func day(of date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The first moment of the day after the one `date` falls in.
    func nextMidnight(after date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        // Not simply +24 h: a day is 23 or 25 hours long when the clocks change.
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    /// The `count` days that end with the day of `date`, oldest first.
    func lastDays(_ count: Int, endingAt date: Date) -> [String] {
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        return (0..<max(0, count)).reversed().map { back in
            day(of: calendar.date(byAdding: .day, value: -back, to: noon) ?? noon.addingTimeInterval(Double(-back) * 86_400))
        }
    }
}

/// Token totals of one agent, ready to be copied into AgentUsage.
struct TokenSummary: Equatable {
    var today = TokenTotals()
    /// Up to 90 days, oldest first, without gaps from the first day that has usage up to today.
    var days: [DayUsage] = []
    var allTime = TokenTotals()
    /// Models counted at $0 because no list price is known for them.
    var unpricedModels: [String] = []
}

enum UsageAggregator {
    /// How many days of history the views get.
    static let keptDays = 90

    static func summarize(_ buckets: [UsageBucket], unpriced: [AgentKind: [String]] = [:], now: Date,
                          timeZone: TimeZone) -> [AgentKind: TokenSummary] {
        let days = LocalDays(timeZone: timeZone)
        let window = days.lastDays(keptDays, endingAt: now)
        let today = window.last ?? days.day(of: now)
        let inWindow = Set(window)

        var allTime: [AgentKind: TokenTotals] = [:]
        var perDay: [AgentKind: [String: DayUsage]] = [:]
        // Many slices share a start time; work each day out once.
        var dayOfStart: [Int64: String] = [:]
        for bucket in buckets {
            allTime[bucket.agent, default: TokenTotals()] += bucket.totals
            let day: String
            if let known = dayOfStart[bucket.start] {
                day = known
            } else {
                day = days.day(of: Date(timeIntervalSince1970: TimeInterval(bucket.start)))
                dayOfStart[bucket.start] = day
            }
            guard inWindow.contains(day) else { continue }
            var entry = perDay[bucket.agent]?[day] ?? DayUsage(day: day)
            entry.totals += bucket.totals
            entry.byModel[bucket.model, default: TokenTotals()] += bucket.totals
            entry.byProject[bucket.project, default: TokenTotals()] += bucket.totals
            perDay[bucket.agent, default: [:]][day] = entry
        }

        var result: [AgentKind: TokenSummary] = [:]
        for agent in Set(allTime.keys).union(unpriced.keys) {
            var summary = TokenSummary()
            summary.allTime = allTime[agent] ?? TokenTotals()
            let known = perDay[agent] ?? [:]
            if let first = window.firstIndex(where: { known[$0] != nil }) {
                summary.days = window[first...].map { known[$0] ?? DayUsage(day: $0) }
            }
            summary.today = known[today]?.totals ?? TokenTotals()
            summary.unpricedModels = unpriced[agent] ?? []
            result[agent] = summary
        }
        return result
    }
}
