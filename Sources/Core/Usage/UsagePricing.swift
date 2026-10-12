// UsagePricing.swift — the one price table Perch uses to ESTIMATE what tokens would cost.
//
// Perch never sees a bill. It multiplies the token counts it finds in local files by Anthropic's
// public list prices, so every dollar figure in the app is an estimate ("at list prices"), and for
// people on a subscription it is not money they are charged at all.
//
// Source of every number below:
//   https://platform.claude.com/docs/en/about-claude/pricing      (read 2026-10-11)
//   The four retired Claude 3 rows are no longer on that page; they come from the official page as
//   archived on 2025-08-30:
//   https://web.archive.org/web/20250830174646/https://docs.anthropic.com/en/docs/about-claude/pricing
// The same table, with the reasoning behind each rule, is in docs/research/claude-usage.md
// (section 5) and Fixtures/claude/usage/pricing.json. When prices change: edit `table`, bump
// `version`, and the ledger re-prices what it has stored the next time it opens.
//
// Only Claude models are priced. Perch has no verified price list for other agents' models, so
// their tokens are counted and their cost stays at $0 (the usage note says so).

import Foundation

/// USD per million tokens for each kind of token.
struct TokenRates: Equatable {
    var input: Double
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double
}

/// One row of the price table.
struct ModelPrice {
    /// Normalised model id (see `UsagePricing.normalizedModelID`).
    var id: String
    var rates: TokenRates
    /// Higher prices for the WHOLE request when its prompt is larger than `over` tokens.
    var longContext: (over: Int, rates: TokenRates)?
    /// What `usage.speed == "fast"` multiplies the request by (1 = fast mode is not sold for this model).
    var fastMultiplier = 1.0
}

/// The token counts of one API response, as far as pricing cares.
struct PricedTokens: Equatable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var webSearches = 0
    /// `usage.speed == "fast"`.
    var isFast = false
    /// `usage.inference_geo == "us"`.
    var isGeoUS = false

    /// Everything the model had to read: decides whether long-context prices apply.
    var promptTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
}

enum UsagePricing {
    /// Bump whenever `table` or a rule in `cost(of:model:)` changes.
    static let version = 1

    /// US-only inference costs 10% more on every token category.
    static let geoUSMultiplier = 1.1
    /// Web search is billed per request: $10 per 1,000 searches.
    static let webSearchUSD = 0.01

    // MARK: The table (USD per million tokens)

    private static func row(_ id: String, _ input: Double, _ output: Double, _ write5m: Double, _ write1h: Double,
                            _ read: Double, fast: Double = 1) -> ModelPrice {
        ModelPrice(id: id, rates: TokenRates(input: input, output: output, cacheWrite5m: write5m, cacheWrite1h: write1h,
                                             cacheRead: read), longContext: nil, fastMultiplier: fast)
    }

    static let table: [ModelPrice] = {
        //             model id               input  output  write 5m  write 1h  cache read
        var rows = [
            row("claude-fable-5-1",            10,    50,    12.5,     20,       0.25),
            row("claude-mythos-5-1",           10,    50,    12.5,     20,       0.25),
            row("claude-fable-5",              10,    50,    12.5,     20,       1),
            row("claude-mythos-5",             10,    50,    12.5,     20,       1),
            row("claude-opus-5-5",              4,    20,     5,        8,       0.2, fast: 2),
            row("claude-opus-5",                5,    25,     6.25,    10,       0.5, fast: 2),
            row("claude-opus-4-8",              5,    25,     6.25,    10,       0.5, fast: 2),
            row("claude-opus-4-7",              5,    25,     6.25,    10,       0.5),
            row("claude-opus-4-6",              5,    25,     6.25,    10,       0.5),
            row("claude-opus-4-5",              5,    25,     6.25,    10,       0.5),
            row("claude-opus-4-1",             15,    75,    18.75,    30,       1.5),
            row("claude-opus-4",               15,    75,    18.75,    30,       1.5),
            row("claude-sonnet-5-5",            2,    10,     2.5,      4,       0.1),
            row("claude-sonnet-5",              2,    10,     2.5,      4,       0.2),
            row("claude-sonnet-4-6",            3,    15,     3.75,     6,       0.3),
            row("claude-sonnet-4-5",            3,    15,     3.75,     6,       0.3),
            row("claude-sonnet-4",              3,    15,     3.75,     6,       0.3),
            row("claude-haiku-5-5",             0.1,   0.5,   0.125,    0.2,     0.01),
            row("claude-haiku-4-5",             1,     5,     1.25,     2,       0.1),
            row("claude-3-5-haiku",             0.8,   4,     1,        1.6,     0.08),
            // Retired; prices from the archived page.
            row("claude-3-7-sonnet",            3,    15,     3.75,     6,       0.3),
            row("claude-3-5-sonnet",            3,    15,     3.75,     6,       0.3),
            row("claude-3-haiku",               0.25,  1.25,  0.3,      0.5,     0.03),
            row("claude-3-opus",               15,    75,    18.75,    30,       1.5),
        ]
        // Haiku 5.5 is the only model with long-context prices: a prompt over 100,000 tokens
        // (cache reads and writes included) moves the whole request to these rates.
        if let haiku = rows.firstIndex(where: { $0.id == "claude-haiku-5-5" }) {
            rows[haiku].longContext = (over: 100_000,
                                       rates: TokenRates(input: 0.5, output: 2.5, cacheWrite5m: 0.625, cacheWrite1h: 1, cacheRead: 0.05))
        }
        return rows
    }()

    private static let byID: [String: ModelPrice] = Dictionary(table.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    // MARK: Looking a model up

    /// Reduces the many spellings of a model id to the form used in `table`:
    /// lowercase; no trailing "[1m]"; no gateway prefix ("anthropic/claude-…"); no Bedrock prefix
    /// ("us.anthropic.claude-…") or suffix ("-v1:0"); no snapshot date ("-20251101", "@20251101").
    static func normalizedModelID(_ raw: String) -> String {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.hasSuffix("[1m]") { id.removeLast(4) }
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        if id.hasPrefix("anthropic.") {
            id.removeFirst("anthropic.".count)
        } else if let marker = id.range(of: ".anthropic."),
                  !id[..<marker.lowerBound].isEmpty,
                  id[..<marker.lowerBound].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
            id = String(id[marker.upperBound...])
        }
        if id.hasSuffix("-v1:0") { id.removeLast(5) } else if id.hasSuffix("-v1") { id.removeLast(3) }
        // A snapshot date is exactly eight digits after "-" or "@".
        let tail = id.suffix(9)
        if tail.count == 9, let separator = tail.first, separator == "-" || separator == "@",
           tail.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
            id.removeLast(9)
        }
        return id
    }

    /// The price row for a model id in any spelling, or nil when Perch has no price for it.
    /// Matching is exact after normalising: "claude-opus-5" is a different model from "claude-opus-5-5".
    static func price(for model: String) -> ModelPrice? {
        byID[normalizedModelID(model)]
    }

    // MARK: Cost of one response

    /// Estimated USD for one API response at list prices, or nil when the model has no known price
    /// (the caller then counts the tokens and adds $0).
    static func cost(of tokens: PricedTokens, model: String) -> Double? {
        guard let price = price(for: model) else { return nil }
        var rates = price.rates
        if let long = price.longContext, tokens.promptTokens > long.over { rates = long.rates }
        var usd = (Double(tokens.input) * rates.input
            + Double(tokens.output) * rates.output
            + Double(tokens.cacheWrite5m) * rates.cacheWrite5m
            + Double(tokens.cacheWrite1h) * rates.cacheWrite1h
            + Double(tokens.cacheRead) * rates.cacheRead) / 1_000_000
        if tokens.isFast { usd *= price.fastMultiplier }
        if tokens.isGeoUS { usd *= geoUSMultiplier }
        return usd + Double(tokens.webSearches) * webSearchUSD
    }

    // MARK: Unknown models

    private static let lock = NSLock()
    private static var reportedUnknown = Set<String>()

    /// Writes one log line the first time a model without a price shows up, so a new model is
    /// noticed without filling the log.
    static func noteUnknownModel(_ model: String) {
        let id = normalizedModelID(model)
        lock.lock()
        let isNew = reportedUnknown.insert(id).inserted
        lock.unlock()
        if isNew { Log.info("No list price known for model \"\(id)\"; its tokens are counted and its cost stays at $0.", "usage") }
    }
}
