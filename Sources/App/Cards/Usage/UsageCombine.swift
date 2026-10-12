// UsageCombine.swift — adds several agents' usage together for the Usage tab (pure, no UI).
//
// The tab shows either every agent at once ("All") or one agent. Both views ask the same
// questions, so both are answered here, from one list of AgentUsage values:
//   - which view is showing, given what the user picked and which agents have numbers?
//   - how many tokens today, and over the chosen range?
//   - which models used the most? The top five keep their own name; the rest fold into "Other".
//     A model belongs to its agent, so the same model name under two agents is two entries.
//   - what does each day's bar look like, split into those same entries?
//   - (for one agent) which projects used the most?
//
// "Today" is special in two ways. The store keeps a fresher number for today than the day list
// may have, so today's record is topped up to it first. And one bar is no chart, so the "Today"
// range still draws the last seven days, with only today counted and lit.

import Foundation

/// What the Usage tab is showing: every agent together, or one of them.
enum UsageTabScope: Hashable {
    case all
    case agent(AgentKind)
}

/// One colour in the stacked chart and one row in the "by model" list.
struct UsageSeries: Identifiable, Equatable {
    /// The agent the model was used through. Nil for the folded "Other" entry.
    var agent: AgentKind?
    var model: String
    /// Added up over the chosen range.
    var totals: TokenTotals
    /// 0...1 of the range (by cost when costs are shown and known, otherwise by tokens).
    var fraction: Double
    /// Position among the same agent's entries, biggest first. Picks the strength of the colour.
    var shade: Int
    /// How many small models were folded into this entry ("Other" only).
    var folded = 0

    var id: String { "\(agent?.rawValue ?? "other")/\(model)" }
}

/// One bar of the stacked chart.
struct UsageStackDay: Identifiable, Equatable {
    var day: String
    var totals: TokenTotals
    /// False for a calendar day no agent's files say anything about.
    var hasData: Bool
    /// False for the days drawn only as context around "Today".
    var inRange: Bool
    /// Tokens per entry of `UsageCombined.series`, in the same order.
    var parts: [Int]

    var id: String { day }
    /// What the bar's height stands for.
    var stacked: Int { parts.reduce(0, +) }
}

struct UsageCombined: Equatable {
    var today = TokenTotals()
    /// The chosen range, all agents together.
    var range = TokenTotals()
    /// Biggest first; "Other" (if any) is last.
    var series: [UsageSeries] = []
    /// One per calendar day, oldest first, ending today.
    var days: [UsageStackDay] = []
    var byProject: [UsageTabShare] = []
}

enum UsageCombine {
    /// Models beyond this many are folded into "Other".
    static let maxSeries = 5
    static let otherName = "Other"

    /// Days the chart draws for a range.
    static func chartSpan(_ range: UsageTabRange) -> Int { max(range.dayCount, 7) }

    /// The view to show. "All" needs at least two agents; an agent that has no numbers (any
    /// more) cannot be shown. Nil when no agent has numbers at all.
    static func scope(picked: UsageTabScope?, agents: [AgentKind]) -> UsageTabScope? {
        guard let first = agents.first else { return nil }
        if case .agent(let agent)? = picked, agents.contains(agent) { return .agent(agent) }
        return agents.count > 1 ? .all : .agent(first)
    }

    /// An agent's days by day string, with today topped up to the store's fresher number. The
    /// extra tokens are shared between today's models and projects in the proportions already known.
    static func days(_ usage: AgentUsage, now: Date) -> [String: DayUsage] {
        var known = Dictionary(usage.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let today = UsageTabCalendar.dayString(now)
        let recorded = known[today]?.totals.total ?? 0
        guard usage.today.total > recorded else { return known }
        let factor = recorded > 0 ? Double(usage.today.total) / Double(recorded) : 0
        known[today] = DayUsage(day: today, totals: usage.today,
                                byModel: (known[today]?.byModel ?? [:]).mapValues { scaled($0, by: factor) },
                                byProject: (known[today]?.byProject ?? [:]).mapValues { scaled($0, by: factor) })
        return known
    }

    static func combine(_ usages: [AgentUsage], range: UsageTabRange, now: Date, byCost: Bool) -> UsageCombined {
        let span = UsageTabCalendar.lastDays(chartSpan(range), endingAt: now).map(UsageTabCalendar.dayString)
        let counted = Set(span.suffix(range.dayCount))
        let known = usages.map { days($0, now: now) }

        // 1. Add up every model (per agent) and every project.
        var rangeTotals: [Key: TokenTotals] = [:]
        var spanTokens: [Key: Int] = [:]
        var projects: [String: TokenTotals] = [:]
        for (order, usage) in usages.enumerated() {
            for day in span {
                guard let record = known[order][day] else { continue }
                for (model, value) in record.byModel {
                    let key = Key(agent: usage.agent, order: order, model: model)
                    spanTokens[key, default: 0] += max(value.total, 0)
                    if counted.contains(day) { rangeTotals[key, default: TokenTotals()] += value }
                }
                guard counted.contains(day) else { continue }
                for (name, value) in record.byProject { projects[name, default: TokenTotals()] += value }
            }
        }

        // 2. Rank them: by the range first, then by what the chart shows, then by a fixed order.
        let useCost = byCost && rangeTotals.values.contains { $0.costUSD > 0 }
        func weight(_ totals: TokenTotals?) -> Double {
            guard let totals else { return 0 }
            let value = useCost ? totals.costUSD : Double(totals.total)
            return value.isFinite ? max(value, 0) : 0
        }
        let ranked = spanTokens.filter { $0.value > 0 }.keys.sorted { a, b in
            let (weightA, weightB) = (weight(rangeTotals[a]), weight(rangeTotals[b]))
            if weightA != weightB { return weightA > weightB }
            let (tokensA, tokensB) = (spanTokens[a] ?? 0, spanTokens[b] ?? 0)
            if tokensA != tokensB { return tokensA > tokensB }
            return a.order == b.order ? a.model < b.model : a.order < b.order
        }
        let kept = Array(ranked.prefix(maxSeries))
        let slot = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset) })

        // 3. One bar per day. Anything that is not a kept model lands in the last part, "Other":
        //    the folded models, and days whose record names no model at all.
        var result = UsageCombined()
        var other = TokenTotals()
        for day in span {
            var parts = [Int](repeating: 0, count: kept.count + 1)
            var totals = TokenTotals()
            var hasData = false
            for (order, usage) in usages.enumerated() {
                guard let record = known[order][day] else { continue }
                hasData = true
                totals += record.totals
                let pieces = record.byModel.isEmpty ? [(Key?.none, record.totals)]
                    : record.byModel.map { (Key(agent: usage.agent, order: order, model: $0.key), $0.value) }
                for (key, value) in pieces {
                    if let key, let index = slot[key] {
                        parts[index] += max(value.total, 0)
                    } else {
                        parts[kept.count] += max(value.total, 0)
                        if counted.contains(day) { other += value }
                    }
                }
            }
            if counted.contains(day) { result.range += totals }
            result.days.append(UsageStackDay(day: day, totals: totals, hasData: hasData, inRange: counted.contains(day), parts: parts))
        }
        result.today = result.days.last?.totals ?? TokenTotals()
        let hasOther = result.days.contains { ($0.parts.last ?? 0) > 0 }
        if !hasOther {
            for index in result.days.indices { result.days[index].parts.removeLast() }
        }

        // 4. The entries themselves, with their share of the range.
        let whole = kept.reduce(weight(other)) { $0 + weight(rangeTotals[$1]) }
        var shades: [AgentKind: Int] = [:]
        result.series = kept.map { key in
            let shade = shades[key.agent, default: 0]
            shades[key.agent] = shade + 1
            let totals = rangeTotals[key] ?? TokenTotals()
            return UsageSeries(agent: key.agent, model: key.model, totals: totals, fraction: whole > 0 ? weight(totals) / whole : 0, shade: shade)
        }
        if hasOther {
            result.series.append(UsageSeries(agent: nil, model: otherName, totals: other, fraction: whole > 0 ? weight(other) / whole : 0,
                                             shade: 0, folded: ranked.count - kept.count))
        }
        result.byProject = UsageTabMath.shares(projects, byCost: byCost)
        return result
    }

    /// A model as used through one agent. `order` is the agent's position in the list given.
    private struct Key: Hashable {
        var agent: AgentKind
        var order: Int
        var model: String
    }

    private static func scaled(_ totals: TokenTotals, by factor: Double) -> TokenTotals {
        func part(_ value: Int) -> Int { Int((Double(value) * factor).rounded()) }
        return TokenTotals(input: part(totals.input), output: part(totals.output), cacheWrite: part(totals.cacheWrite),
                           cacheRead: part(totals.cacheRead), costUSD: totals.costUSD * factor, messages: part(totals.messages))
    }
}
