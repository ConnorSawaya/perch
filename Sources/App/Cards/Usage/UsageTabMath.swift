// UsageTabMath.swift — the sums behind the Usage tab (pure, no UI).
//
// UsageStore holds raw numbers per agent: rate-limit windows, a list of days, and Perch's own
// daily activity tally. This file answers the small questions the tab asks of them:
//   - which ranges can be picked, and which calendar days does a range cover?
//   - how does a set of slices (projects) rank, as shares of the whole?
//   - what should a limit ring show (used or remaining), and should it warn?
//   - how active was the user in a range?
// Adding agents together and splitting days by model lives in UsageCombine.swift.
//
// Days are identified by local-calendar strings, "yyyy-MM-dd", exactly as the stores keep them.

import Foundation

/// The time span the breakdowns and activity numbers cover.
enum UsageTabRange: String, CaseIterable, Identifiable {
    case today, week, month, quarter

    var id: String { rawValue }

    var dayCount: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    /// Short label for the picker.
    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        }
    }

    /// The same span as part of a sentence or heading: "today", "last 7 days".
    var phrase: String { self == .today ? "today" : "last \(dayCount) days" }
}

/// Turning dates into the day strings the stores use, and back.
enum UsageTabCalendar {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let labelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func date(_ day: String) -> Date? { dayFormatter.date(from: day) }

    /// "Oct 3" for a day string; the string itself when it cannot be read.
    static func shortLabel(_ day: String) -> String {
        date(day).map(labelFormatter.string(from:)) ?? day
    }

    /// The last `count` calendar days ending today, oldest first.
    static func lastDays(_ count: Int, endingAt now: Date) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<max(count, 0)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }
}

/// One slice of a breakdown (a project) and how much of the total it used.
struct UsageTabShare: Identifiable, Equatable {
    var name: String
    var totals: TokenTotals
    /// 0...1 of the range's total (by cost when costs are shown and known, otherwise by tokens).
    var fraction: Double

    var id: String { name }
}

/// What a limit ring shows.
struct UsageLimitReading: Equatable {
    enum Level { case calm, warning, danger }
    /// 0...100, how much of the limit is used.
    var used: Double
    /// 0...100, the number printed: used, or what is left.
    var shown: Double
    var showsRemaining: Bool
    var level: Level
}

/// Perch's own tally, added up over a range.
struct UsageActivitySummary: Equatable {
    var activeSeconds = 0
    var sessions = 0
    var requestsHandled = 0
    var longestTaskSeconds = 0
    var turns = 0
    var toolCalls = 0
    var peakConcurrent = 0
}

enum UsageTabMath {
    /// Slices beyond this many are folded into one "Other" slice.
    static let maxShares = 4

    /// True when there is anything at all worth showing for an agent.
    static func hasData(_ usage: AgentUsage) -> Bool {
        !usage.windows.isEmpty || !usage.days.isEmpty || usage.today.total > 0 || usage.allTime.total > 0
    }

    // MARK: Shares

    /// Sorts slices biggest first, keeps the top few and folds the rest into "Other".
    static func shares(_ parts: [String: TokenTotals], byCost: Bool) -> [UsageTabShare] {
        let useCost = byCost && parts.values.contains { $0.costUSD > 0 }
        func weight(_ totals: TokenTotals) -> Double {
            let value = useCost ? totals.costUSD : Double(totals.total)
            return value.isFinite ? max(value, 0) : 0
        }
        let sorted = parts.filter { weight($0.value) > 0 }
            .sorted { weight($0.value) == weight($1.value) ? $0.key < $1.key : weight($0.value) > weight($1.value) }
        let whole = sorted.reduce(0) { $0 + weight($1.value) }
        guard whole > 0 else { return [] }

        var kept = sorted.prefix(maxShares).map { UsageTabShare(name: $0.key, totals: $0.value, fraction: weight($0.value) / whole) }
        let rest = sorted.dropFirst(maxShares)
        if !rest.isEmpty {
            let folded = rest.reduce(into: TokenTotals()) { $0 += $1.value }
            kept.append(UsageTabShare(name: "\(rest.count) more", totals: folded, fraction: weight(folded) / whole))
        }
        return kept
    }

    /// A model or project name short enough for a row: folders lose their path.
    static func displayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Unknown" }
        if trimmed.contains("/") {
            let last = (trimmed as NSString).lastPathComponent
            return last.isEmpty ? trimmed : last
        }
        return trimmed
    }

    // MARK: Limits

    static func reading(_ window: RateWindow, showRemaining: Bool, warnings: Bool, warnAt: Double) -> UsageLimitReading {
        let used = window.usedPercent.isFinite ? min(max(window.usedPercent, 0), 100) : 0
        let threshold = min(max(warnAt, 50), 95)
        var level = UsageLimitReading.Level.calm
        // The level always follows what is USED, so "12% left" warns exactly like "88% used".
        if warnings {
            if used >= 95 { level = .danger } else if used >= threshold { level = .warning }
        }
        return UsageLimitReading(used: used, shown: showRemaining ? 100 - used : used, showsRemaining: showRemaining, level: level)
    }

    // MARK: Perch's own activity

    static func activity(_ days: [DailyActivity], range: UsageTabRange, now: Date) -> UsageActivitySummary {
        let wanted = Set(UsageTabCalendar.lastDays(range.dayCount, endingAt: now).map(UsageTabCalendar.dayString))
        var summary = UsageActivitySummary()
        for day in days where wanted.contains(day.day) {
            summary.activeSeconds += max(day.activeSeconds, 0)
            summary.sessions += max(day.sessionsStarted, 0)
            summary.requestsHandled += max(day.approvalsHandled, 0) + max(day.questionsAnswered, 0)
            summary.longestTaskSeconds = max(summary.longestTaskSeconds, day.longestTaskSeconds)
            summary.turns += max(day.turnsFinished, 0)
            summary.toolCalls += max(day.toolCalls, 0)
            summary.peakConcurrent = max(summary.peakConcurrent, day.peakConcurrent)
        }
        return summary
    }

    /// A whole number with the user's thousands separators: 1039 → "1,039".
    static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// A length of time without seconds once it is longer than a minute: "42s", "12m", "6h 12m".
    static func duration(_ seconds: Int) -> String {
        let total = max(seconds, 0)
        switch total {
        case ..<60: return "\(total)s"
        case ..<3600: return "\(total / 60)m"
        default: return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
        }
    }
}
