// DemoUsage.swift — pretend usage numbers for demo mode, and a way to put the real ones back.
//
// The usage rings and charts need numbers to be worth looking at, so demo mode fills the usage
// store with sample figures and nudges them upwards as the story plays. The real figures are
// remembered in a UsageSnapshot and restored when the demo ends (see DemoDirector).

import Foundation

/// Everything the usage store holds at one moment.
struct UsageSnapshot: Equatable {
    var usage: [AgentKind: AgentUsage]
    var activityDays: [DailyActivity]
    var lastRefresh: Date?

    init(of store: UsageStore) {
        usage = store.usage
        activityDays = store.activityDays
        lastRefresh = store.lastRefresh
    }

    func write(to store: UsageStore) {
        if store.usage != usage { store.usage = usage }
        if store.activityDays != activityDays { store.activityDays = activityDays }
        if store.lastRefresh != lastRefresh { store.lastRefresh = lastRefresh }
    }
}

/// Things the demo counts in today's "how you worked" tally.
enum DemoTally {
    case sessionStarted, turnFinished, toolCall, approvalHandled, questionAnswered
}

struct DemoUsage {
    private(set) var usage: [AgentKind: AgentUsage]
    private(set) var activityDays: [DailyActivity]

    /// Shown under the numbers so nobody mistakes them for their own.
    static let note = "Demo numbers. Your real usage comes back when you leave demo mode."

    /// The starting figures: SampleData's numbers, re-dated so "today" is today.
    init(now: Date) {
        let offset = now.timeIntervalSince(SampleData.now)
        var usage = SampleData.usage
        for agent in Array(usage.keys) {
            guard var entry = usage[agent] else { continue }
            entry.windows = entry.windows.map { window in
                var moved = window
                moved.resetsAt = window.resetsAt?.addingTimeInterval(offset)
                return moved
            }
            let days = Self.dayNames(count: entry.days.count, endingAt: now)
            for index in entry.days.indices { entry.days[index].day = days[index] }
            entry.updatedAt = now
            entry.note = Self.note
            usage[agent] = entry
        }
        self.usage = usage

        var activity = SampleData.activityDays
        let days = Self.dayNames(count: activity.count, endingAt: now)
        for index in activity.indices { activity[index].day = days[index] }
        activityDays = activity
    }

    /// A little more of everything, as if the pretend sessions had just used the API.
    mutating func tick(now: Date, activeSeconds: Int) {
        let claudeSlice = TokenTotals(input: 2_400, output: 900, cacheWrite: 5_200, cacheRead: 64_000, costUSD: 0.11, messages: 4)
        let codexSlice = TokenTotals(input: 900, output: 350, cacheWrite: 0, cacheRead: 12_000, costUSD: 0.02, messages: 1)
        spend(.claude, claudeSlice, percentByWindow: ["5h": 0.7, "7d": 0.12], now: now)
        spend(.codex, codexSlice, percentByWindow: ["primary": 0.25], now: now)
        if let today = activityDays.indices.last {
            activityDays[today].activeSeconds += max(0, activeSeconds)
        }
    }

    /// Adds one to a counter in today's activity tally.
    mutating func count(_ tally: DemoTally) {
        guard let today = activityDays.indices.last else { return }
        switch tally {
        case .sessionStarted: activityDays[today].sessionsStarted += 1
        case .turnFinished: activityDays[today].turnsFinished += 1
        case .toolCall: activityDays[today].toolCalls += 1
        case .approvalHandled: activityDays[today].approvalsHandled += 1
        case .questionAnswered: activityDays[today].questionsAnswered += 1
        }
    }

    private mutating func spend(_ agent: AgentKind, _ slice: TokenTotals, percentByWindow: [String: Double], now: Date) {
        guard var entry = usage[agent] else { return }
        entry.windows = entry.windows.map { window in
            var grown = window
            // Stop short of 100% so the demo never looks like it locked the user out.
            grown.usedPercent = min(97, window.usedPercent + (percentByWindow[window.id] ?? 0))
            return grown
        }
        entry.today += slice
        entry.allTime += slice
        if let last = entry.days.indices.last { entry.days[last].totals += slice }
        entry.updatedAt = now
        usage[agent] = entry
    }

    /// "yyyy-MM-dd" names for `count` days, oldest first, the last one being the day of `end`.
    private static func dayNames(count: Int, endingAt end: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<count).map { index in
            formatter.string(from: end.addingTimeInterval(TimeInterval(-86_400 * (count - 1 - index))))
        }
    }
}
