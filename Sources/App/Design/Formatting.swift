// Formatting.swift — turning numbers and dates into short, plain words, in one place so the
// whole app says "5m 12s" and "1.2M" the same way.
//
//   PerchFormat.elapsed(312)            "5m 12s"
//   PerchFormat.ago(date)               "3m ago"
//   PerchFormat.percent(41.6)           "42%"
//   PerchFormat.count(1_240_000)        "1.2M"
//   PerchFormat.path("/Users/me/code")  "~/code"
//   PerchElapsedText(since: date)       a label that keeps counting by itself

import SwiftUI

enum PerchFormat {
    /// A duration in at most two units: "8s", "5m 12s", "1h 03m", "2d 4h".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        switch total {
        case ..<60: return "\(total)s"
        case ..<3600: return "\(total / 60)m \(String(format: "%02d", total % 60))s"
        case ..<86_400: return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
        default: return "\(total / 86_400)d \((total % 86_400) / 3600)h"
        }
    }

    /// How long ago something happened: "just now", "42s ago", "3m ago", "2h ago", "5d ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = wholeSeconds(now.timeIntervalSince(date))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    /// How long until something happens: "now", "in 40s", "in 2h 24m", "in 3d 4h".
    static func until(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        return seconds < 1 ? "now" : "in " + remaining(seconds)
    }

    /// A countdown without seconds once it is longer than a minute: "40s", "24m", "2h 24m", "3d 4h".
    static func remaining(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        switch total {
        case ..<60: return "\(total)s"
        case ..<3600: return "\(total / 60)m"
        case ..<86_400: return "\(total / 3600)h \((total % 3600) / 60)m"
        default: return "\(total / 86_400)d \((total % 86_400) / 3600)h"
        }
    }

    /// Seconds as a whole number that is safe to do arithmetic on: never negative, never
    /// "not a number", never too big to fit (a broken date must not crash the panel).
    private static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        seconds.isFinite ? Int(min(max(seconds, 0), 1e11)) : 0
    }

    /// A 0...100 number as a whole percentage: "42%".
    static func percent(_ value: Double) -> String {
        "\(Int((value.isFinite ? min(max(value, 0), 100) : 0).rounded()))%"
    }

    /// Big counts made short: 950 → "950", 12_400 → "12.4K", 1_240_000 → "1.2M".
    static func count(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        func short(_ divisor: Double, _ suffix: String) -> String {
            let scaled = Double(value) / divisor
            return (abs(scaled) >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)) + suffix
        }
        switch magnitude {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return short(1_000, "K")
        case ..<1_000_000_000: return short(1_000_000, "M")
        default: return short(1_000_000_000, "B")
        }
    }

    /// An estimated cost: "$0.42", "$7.85", "$1,099".
    static func cost(_ dollars: Double) -> String {
        guard dollars.isFinite else { return "$0.00" }
        if abs(dollars) >= 1000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return "$" + (formatter.string(from: NSNumber(value: dollars)) ?? String(format: "%.0f", dollars))
        }
        return String(format: "$%.2f", dollars)
    }

    /// A folder path with the home folder shortened to "~".
    static func path(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        // Sessions from another account (or sample data) still read better with "~".
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Users" { return "~/" + parts.dropFirst(2).joined(separator: "/") }
        return path
    }
}

/// A label showing how long ago `since` was, counting up on its own ("14s" … "5m 12s" … "1h 03m").
/// It inherits font and colour like a Text. Only this label redraws each second, not its parent.
struct PerchElapsedText: View {
    enum Style {
        /// "5m 12s" — time spent in a state.
        case elapsed
        /// "5m ago" — when something happened.
        case ago
    }

    private let since: Date
    private let style: Style

    init(since: Date, style: Style = .elapsed) {
        self.since = since
        self.style = style
    }

    var body: some View {
        // Tick every second only while the seconds are actually shown; after that a slow tick is enough.
        let age = Date().timeIntervalSince(since)
        let showsSeconds = age < 60 || (style == .elapsed && age < 3600)
        let interval: TimeInterval = showsSeconds ? 1 : 20
        TimelineView(.periodic(from: since, by: interval)) { timeline in
            Text(text(at: timeline.date))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func text(at now: Date) -> String {
        switch style {
        case .elapsed: return PerchFormat.elapsed(now.timeIntervalSince(since))
        case .ago: return PerchFormat.ago(since, now: now)
        }
    }
}
