// UsageTests.swift — checks the usage module (Sources/Core/Usage) against the fixtures.
//
// Run with: scripts/test.sh Usage Sources/Core/Usage
//
// Everything happens in temporary folders: PERCH_HOME points Perch's own paths (including the log)
// at one, and every engine is built with the test initialiser that takes custom folders. The
// fixtures under Fixtures/ are only read. No real agent folder, keychain or network is touched.

import Foundation
import Combine

// MARK: - Helpers

private let alphaSession = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let losAngeles = TimeZone(identifier: "America/Los_Angeles") ?? .current
private let utc = TimeZone(identifier: "UTC") ?? .current

private func approx(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) < tolerance }

private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso) ?? Date(timeIntervalSince1970: 0)
}

/// A mutable clock for engines and trackers under test.
private final class TestClock {
    var now: Date
    init(_ iso: String) { now = date(iso) }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Settings backed by a throw-away defaults domain.
private func makeSettings() -> AppSettings {
    AppSettings(defaults: UserDefaults(suiteName: "local.perch.tests.usage.\(UUID().uuidString)") ?? .standard)
}

private func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}

private func append(_ text: String, to url: URL) {
    guard let handle = try? FileHandle(forWritingTo: url) else { return write(text, to: url) }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(text.utf8))
}

private func copy(_ source: URL, to destination: URL) {
    try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: destination)
    try? FileManager.default.copyItem(at: source, to: destination)
}

/// Runs `body` with the bytes of `text`, the way the file reader hands lines over.
private func withLine<T>(_ text: String, _ body: (UnsafeRawBufferPointer) -> T) -> T {
    var bytes = Array(text.utf8)
    return bytes.withUnsafeMutableBytes { body(UnsafeRawBufferPointer($0)) }
}

private func claudeRecords(_ line: String, projectDir: String = "-Users-test-dev-alpha", session: String? = alphaSession) -> [UsageRecord] {
    withLine(line) { ClaudeUsageReader.records(fromLine: $0, projectDir: projectDir, pathSession: session) }
}

/// One synthetic "assistant" transcript line in Claude Code's compact form and key order.
private func assistantLine(id: String, request: String? = nil, model: String = "claude-opus-5-5",
                           time: String = "2026-10-11T20:00:00.000Z", input: Int = 2, output: Int = 10, write5m: Int = 0,
                           write1h: Int = 0, read: Int = 0, final: Bool = true, sidechain: Bool = false,
                           session: String = alphaSession, cwd: String = "/Users/test/dev/alpha", padding: Int = 0,
                           extraUsage: String = "") -> String {
    let text = String(repeating: "x", count: padding)
    let stop = final ? "\"end_turn\"" : "null"
    let tail = final ? ",\"speed\":\"standard\"" : ""
    let requestPart = request.map { "\"requestId\":\"\($0)\"," } ?? "\"requestId\":\"req_\(id)\","
    return "{\"parentUuid\":null,\"isSidechain\":\(sidechain),\"message\":{\"model\":\"\(model)\",\"id\":\"\(id)\",\"type\":\"message\","
        + "\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}],\"stop_reason\":\(stop),"
        + "\"usage\":{\"input_tokens\":\(input),\"cache_creation_input_tokens\":\(write5m + write1h),\"cache_read_input_tokens\":\(read),"
        + "\"cache_creation\":{\"ephemeral_1h_input_tokens\":\(write1h),\"ephemeral_5m_input_tokens\":\(write5m)},"
        + "\"output_tokens\":\(output),\"service_tier\":\"standard\",\"inference_geo\":\"global\"\(tail)\(extraUsage)}},"
        + "\(requestPart)\"type\":\"assistant\",\"uuid\":\"u-\(id)\",\"timestamp\":\"\(time)\",\"cwd\":\"\(cwd)\","
        + "\"sessionId\":\"\(session)\",\"version\":\"2.1.296\",\"gitBranch\":\"main\"}"
}

/// Scans a Claude projects folder into a ledger, with path order standing in for file age.
@discardableResult
private func scanClaude(_ projects: URL, into ledger: UsageLedger, age: ((String) -> Int64?)? = nil) -> ScanReport {
    UsageScanner.scan(ClaudeUsageReader(projectsDirs: [projects]), into: ledger, fileAge: age ?? { _ in 0 })
}

private func memoryLedger(_ t: TestRunner) throws -> UsageLedger {
    try t.unwrap(try? UsageLedger(url: nil), "an in-memory ledger must open")
}

private func total(_ ledger: UsageLedger, _ agent: AgentKind = .claude) -> TokenTotals {
    ((try? ledger.totals(by: .agent))?[agent.rawValue]) ?? TokenTotals()
}

/// Compares a TokenTotals with one block of expected.json.
private func checkTotals(_ t: TestRunner, _ got: TokenTotals?, _ want: JSONValue, _ label: String,
                         file: StaticString = #file, line: UInt = #line) {
    guard let got else {
        t.expect(false, "\(label): missing", file: file, line: line)
        return
    }
    t.expectEqual(got.messages, want["messages"].intValue ?? -1, "\(label) responses", file: file, line: line)
    t.expectEqual(got.input, want["input"].intValue ?? -1, "\(label) input", file: file, line: line)
    t.expectEqual(got.output, want["output"].intValue ?? -1, "\(label) output", file: file, line: line)
    t.expectEqual(got.cacheWrite, want["cacheWrite"].intValue ?? -1, "\(label) cache write", file: file, line: line)
    t.expectEqual(got.cacheRead, want["cacheRead"].intValue ?? -1, "\(label) cache read", file: file, line: line)
    t.expect(approx(got.costUSD, want["costUSD"].doubleValue ?? -1), "\(label) cost \(got.costUSD)", file: file, line: line)
}

private func usageEvent(_ agent: AgentKind = .claude, session: String = "s1", windows: [RateWindow], context: Double? = nil,
                        model: String? = nil, cost: Double? = nil, at time: Date = Date()) -> NormalizedEvent {
    NormalizedEvent(agent: agent, sessionID: session,
                    event: .usageUpdated(contextPercent: context, windows: windows, model: model, costUSD: cost),
                    context: EventContext(receivedAt: time), rawEventName: "statusline")
}

private func event(_ kind: AgentEvent, _ agent: AgentKind = .claude, session: String = "s1") -> NormalizedEvent {
    NormalizedEvent(agent: agent, sessionID: session, event: kind, context: EventContext(receivedAt: Date()), rawEventName: "test")
}

private func tool(_ name: String = "Bash") -> ToolCall {
    ToolCall(id: UUID().uuidString, name: name, summary: name, startedAt: Date())
}

private func permission(session: String = "s1", agent: AgentKind = .claude) -> PendingRequest {
    PendingRequest(sessionID: Session.makeID(agent, session), agent: agent,
                   kind: .permission(PermissionRequest(toolName: "Bash", summary: "Run a command", detail: "ls")),
                   createdAt: Date(), raw: .null)
}

/// Waits until a refresh has finished and the store is quiet.
private func waitForRefresh(_ t: TestRunner, _ store: UsageStore, file: StaticString = #file, line: UInt = #line) {
    let done = t.wait(20) { store.lastRefresh != nil && !store.isRefreshing }
    t.expect(done, "the refresh should finish", file: file, line: line)
}

/// The rate-limit windows of a status line payload, mapped as the research specifies (section 6.5).
private func statusLineWindows(_ payload: JSONValue) -> [RateWindow] {
    [("five_hour", "5h", "5-hour limit"), ("seven_day", "7d", "Weekly limit"), ("spend_limit", "spend", "Spend limit")].compactMap { key, id, label in
        let window = payload["rate_limits"][key]
        guard let used = window["used_percentage"].doubleValue else { return nil }
        return RateWindow(id: id, label: label, usedPercent: used,
                          resetsAt: window["resets_at"].doubleValue.map { Date(timeIntervalSince1970: $0) })
    }
}

// MARK: - Tests

func runUsageTests(_ t: TestRunner) {
    let sandbox = TestRunner.tempDir("perch-usage-tests")
    setenv("PERCH_HOME", sandbox.appendingPathComponent("perch-home").path, 1)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let fixtures = TestRunner.fixture("claude/usage")
    let expected = JSONValue.parse(TestRunner.fixtureText("claude/usage/expected.json")) ?? .null
    let pricing = JSONValue.parse(TestRunner.fixtureText("claude/usage/pricing.json")) ?? .null
    var folderCount = 0
    func folder(_ name: String) -> URL {
        folderCount += 1
        let url = sandbox.appendingPathComponent("\(folderCount)-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    pricingTests(t, pricing: pricing, expected: expected)
    timingTest(t, folder: folder)        // early, while the process is still small, so its memory check means something
    claudeLineTests(t)
    claudePathTests(t)
    claudeFixtureTests(t, fixtures: fixtures, expected: expected, folder: folder)
    tailTests(t, fixtures: fixtures, expected: expected, folder: folder)
    aggregationTests(t)
    codexTests(t, folder: folder)
    geminiTests(t, folder: folder)
    limitTests(t)
    activityTests(t)
    engineTests(t, fixtures: fixtures, expected: expected, folder: folder)
    engineLiveTests(t, fixtures: fixtures, folder: folder)
    noteAndLocationTests(t, sandbox: sandbox)
}

// MARK: Pricing

private func pricingTests(_ t: TestRunner, pricing: JSONValue, expected: JSONValue) {
    t.test("model ids are normalised to the price table's form") {
        let cases = [
            ("claude-opus-5-5", "claude-opus-5-5"),
            ("Claude-Opus-5-5", "claude-opus-5-5"),
            ("claude-opus-4-5-20251101", "claude-opus-4-5"),
            ("claude-sonnet-4-6[1m]", "claude-sonnet-4-6"),
            ("anthropic/claude-opus-4-8", "claude-opus-4-8"),
            ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5"),
            ("anthropic.claude-3-5-haiku-20241022-v1:0", "claude-3-5-haiku"),
            ("claude-haiku-4-5@20251001", "claude-haiku-4-5"),
            ("claude-3-7-sonnet-20250219", "claude-3-7-sonnet"),
            ("eu.anthropic.claude-opus-4-1-20250805-v1", "claude-opus-4-1"),
            ("claude-next-9", "claude-next-9"),
        ]
        for (raw, want) in cases { t.expectEqual(UsagePricing.normalizedModelID(raw), want, raw) }
    }

    t.test("the price table equals Fixtures/claude/usage/pricing.json row for row") {
        let rows = pricing["models"].arrayValue ?? []
        t.expectEqual(rows.count, UsagePricing.table.count, "number of priced models")
        for row in rows {
            let id = row["id"].stringValue ?? "?"
            guard let price = UsagePricing.price(for: id) else {
                t.expect(false, "no price for \(id)")
                continue
            }
            let same = price.rates.input == row["input"].doubleValue && price.rates.output == row["output"].doubleValue
                && price.rates.cacheWrite5m == row["cache_write_5m"].doubleValue
                && price.rates.cacheWrite1h == row["cache_write_1h"].doubleValue
                && price.rates.cacheRead == row["cache_read"].doubleValue
                && price.fastMultiplier == (row["fast_multiplier"].doubleValue ?? 1)
            t.expect(same, "rates of \(id)")
            let long = row["long_context"]
            if long.isNull {
                t.expect(price.longContext == nil, "\(id) has no long-context prices")
            } else {
                t.expectEqual(price.longContext?.over, long["prompt_tokens_over"].intValue, "\(id) long-context threshold")
                t.expectEqual(price.longContext?.rates.input, long["input"].doubleValue, "\(id) long-context input")
                t.expectEqual(price.longContext?.rates.cacheRead, long["cache_read"].doubleValue, "\(id) long-context cache read")
            }
        }
        t.expectEqual(UsagePricing.webSearchUSD, pricing["web_search_usd_per_request"].doubleValue ?? -1)
        t.expectEqual(UsagePricing.geoUSMultiplier, pricing["inference_geo_us_multiplier"].doubleValue ?? -1)
    }

    t.test("golden vectors reproduce the costs Claude Code itself wrote") {
        let opus = PricedTokens(input: 2, output: 13, cacheWrite1h: 9_560, cacheRead: 24_253)
        let sonnet = PricedTokens(input: 6, output: 254, cacheWrite1h: 12_100, cacheRead: 56_850)
        let haiku = PricedTokens(input: 4, output: 279, cacheWrite1h: 6_449, cacheRead: 30_532)
        t.expect(approx(UsagePricing.cost(of: opus, model: "claude-opus-5-5") ?? -1, 0.0815986))
        t.expect(approx(UsagePricing.cost(of: sonnet, model: "claude-sonnet-5-5") ?? -1, 0.056637))
        t.expect(approx(UsagePricing.cost(of: haiku, model: "claude-haiku-5-5") ?? -1, 0.00173502))
    }

    t.test("every fixture response is priced exactly as expected.json says") {
        let events = expected["events"].arrayValue ?? []
        t.expectEqual(events.count, 18)
        for item in events {
            let tokens = PricedTokens(input: item["input"].intValue ?? 0, output: item["output"].intValue ?? 0,
                                      cacheWrite5m: item["cacheWrite5m"].intValue ?? 0, cacheWrite1h: item["cacheWrite1h"].intValue ?? 0,
                                      cacheRead: item["cacheRead"].intValue ?? 0, webSearches: item["webSearch"].intValue ?? 0,
                                      isFast: item["speed"].stringValue == "fast", isGeoUS: item["geo"].stringValue == "us")
            let cost = UsagePricing.cost(of: tokens, model: item["model"].stringValue ?? "")
            t.expect(approx(cost ?? 0, item["costUSD"].doubleValue ?? -1), "cost of \(item["name"].stringValue ?? "?")")
        }
    }

    t.test("pricing rules: long context, fast mode, US inference, web search, unknown models") {
        // Haiku 5.5: exactly 100,000 prompt tokens stays on the normal prices; one more moves the whole request.
        let atLimit = PricedTokens(input: 0, output: 0, cacheRead: 100_000)
        let overLimit = PricedTokens(input: 1, output: 0, cacheRead: 100_000)
        t.expect(approx(UsagePricing.cost(of: atLimit, model: "claude-haiku-5-5") ?? -1, 0.001))
        t.expect(approx(UsagePricing.cost(of: overLimit, model: "claude-haiku-5-5") ?? -1, (0.5 + 100_000 * 0.05) / 1_000_000))
        // No long-context premium for other models.
        t.expect(approx(UsagePricing.cost(of: PricedTokens(input: 500_000), model: "claude-opus-5-5") ?? -1, 2.0))

        let plain = PricedTokens(input: 1_000_000, output: 1_000_000)
        var fast = plain
        fast.isFast = true
        t.expect(approx(UsagePricing.cost(of: plain, model: "claude-opus-5-5") ?? -1, 24))
        t.expect(approx(UsagePricing.cost(of: fast, model: "claude-opus-5-5") ?? -1, 48), "fast mode doubles Opus 5.5")
        t.expect(approx(UsagePricing.cost(of: fast, model: "claude-opus-4-7") ?? -1, 30), "no fast price for Opus 4.7")
        t.expect(approx(UsagePricing.cost(of: fast, model: "claude-sonnet-5-5") ?? -1, 12), "no fast price for Sonnet")

        var us = plain
        us.isGeoUS = true
        t.expect(approx(UsagePricing.cost(of: us, model: "claude-sonnet-5-5") ?? -1, 13.2), "US inference is 1.1x")
        var searching = PricedTokens()
        searching.webSearches = 3
        t.expect(approx(UsagePricing.cost(of: searching, model: "claude-opus-5-5") ?? -1, 0.03), "web search is $0.01 each")
        var both = fast
        both.isGeoUS = true
        both.webSearches = 1
        t.expect(approx(UsagePricing.cost(of: both, model: "claude-opus-5-5") ?? -1, 24 * 2 * 1.1 + 0.01))

        t.expectNil(UsagePricing.cost(of: plain, model: "claude-next-9"), "an unknown model has no price")
        t.expectNil(UsagePricing.cost(of: plain, model: "gpt-5.2-codex"))
        t.expectNil(UsagePricing.cost(of: plain, model: "<synthetic>"))
        t.expectNil(UsagePricing.price(for: "claude-mythos-preview"), "Mythos Preview has no listed price")
        // No prefix matching: these are different models with different prices.
        t.expectEqual(UsagePricing.price(for: "claude-opus-5")?.rates.input, 5)
        t.expectEqual(UsagePricing.price(for: "claude-opus-5-5")?.rates.input, 4)
        t.expectNil(UsagePricing.price(for: "claude-opus-5-5-5"))
        t.expectEqual(UsagePricing.price(for: "claude-opus-4-5-20251101")?.rates.cacheRead, 0.5)
        UsagePricing.noteUnknownModel("claude-next-9")       // logging the same model twice must be harmless
        UsagePricing.noteUnknownModel("claude-next-9")
    }
}

// MARK: Claude lines and paths

private func claudeLineTests(_ t: TestRunner) {
    t.test("an assistant line becomes one record with the right key and tokens") {
        let records = claudeRecords(assistantLine(id: "msg_01A", input: 3, output: 420, write5m: 100, write1h: 12_000, read: 7))
        t.expectEqual(records.count, 1)
        let record = try t.unwrap(records.first)
        t.expectEqual(record.key, "claude|msg_01A|req_msg_01A")
        t.expectEqual(record.session, alphaSession)
        t.expectEqual(record.messageID, "msg_01A")
        t.expectEqual(record.project, "alpha")
        t.expectEqual(record.model, "claude-opus-5-5")
        t.expectEqual(record.tokens.input, 3)
        t.expectEqual(record.tokens.output, 420)
        t.expectEqual(record.tokens.cacheWrite5m, 100)
        t.expectEqual(record.tokens.cacheWrite1h, 12_000)
        t.expectEqual(record.tokens.cacheRead, 7)
        t.expectEqual(record.timestampMs, Int64(date("2026-10-11T20:00:00Z").timeIntervalSince1970 * 1000))
        t.expect(record.isFinal && !record.isSidechain)
    }

    t.test("lines that are not API responses give nothing") {
        t.expectEqual(claudeRecords("{this line is not valid JSON \"usage\":{").count, 0, "malformed")
        t.expectEqual(claudeRecords("").count, 0, "empty")
        t.expectEqual(claudeRecords("[1,2,3]").count, 0, "not an object")
        t.expectEqual(claudeRecords(#"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-10-11T20:00:00.000Z"}"#).count, 0)
        t.expectEqual(claudeRecords(assistantLine(id: "msg_01S", model: "<synthetic>")).count, 0, "synthetic model")
        let apiError = assistantLine(id: "msg_01E").replacingOccurrences(of: "\"type\":\"assistant\"", with: "\"type\":\"assistant\",\"isApiErrorMessage\":true")
        t.expectEqual(claudeRecords(apiError).count, 0, "API error message")
        let userWithUsage = assistantLine(id: "msg_01U").replacingOccurrences(of: "\"type\":\"assistant\"", with: "\"type\":\"user\"")
        t.expectEqual(claudeRecords(userWithUsage).count, 0, "only assistant lines count")
        let noTime = assistantLine(id: "msg_01T").replacingOccurrences(of: "\"timestamp\":\"2026-10-11T20:00:00.000Z\",", with: "")
        t.expectEqual(claudeRecords(noTime).count, 0, "no timestamp")
        let noModel = assistantLine(id: "msg_01M").replacingOccurrences(of: "\"model\":\"claude-opus-5-5\",", with: "")
        t.expectEqual(claudeRecords(noModel).count, 0, "no model")
        t.expectEqual(claudeRecords(#"{"type":"assistant","message":{"model":"claude-opus-5-5","usage":"none"},"note":"\"usage\":{"}"#).count, 0,
                      "usage must be an object")
    }

    t.test("keys follow the research rule for missing request ids") {
        let noRequest = assistantLine(id: "msg_01N").replacingOccurrences(of: "\"requestId\":\"req_msg_01N\",", with: "")
        t.expectEqual(claudeRecords(noRequest).first?.key, "claude|msg_01N||\(alphaSession)")
        let gateway = assistantLine(id: "gw-7").replacingOccurrences(of: "\"requestId\":\"req_gw-7\",", with: "")
        let ms = Int64(date("2026-10-11T20:00:00Z").timeIntervalSince1970 * 1000)
        t.expectEqual(claudeRecords(gateway).first?.key, "claude|gw-7||\(alphaSession)|\(ms)")
        // The session comes from the path; without one, from the line.
        t.expectEqual(claudeRecords(assistantLine(id: "msg_01P", session: "from-line"), session: nil).first?.session, "from-line")
        t.expectEqual(claudeRecords(assistantLine(id: "msg_01P", session: "from-line")).first?.session, alphaSession)
    }

    t.test("streaming placeholders, sidechains and flags are recognised") {
        let placeholder = try t.unwrap(claudeRecords(assistantLine(id: "msg_01P", output: 6, final: false)).first)
        t.expect(!placeholder.isFinal, "stop_reason null and no speed = placeholder")
        let side = try t.unwrap(claudeRecords(assistantLine(id: "msg_01Q", sidechain: true)).first)
        t.expect(side.isSidechain)
        let fast = assistantLine(id: "msg_01F").replacingOccurrences(of: "\"speed\":\"standard\"", with: "\"speed\":\"fast\"")
        t.expect(claudeRecords(fast).first?.tokens.isFast == true)
        let us = assistantLine(id: "msg_01G").replacingOccurrences(of: "\"inference_geo\":\"global\"", with: "\"inference_geo\":\"us\"")
        t.expect(claudeRecords(us).first?.tokens.isGeoUS == true)
        let search = assistantLine(id: "msg_01W", extraUsage: ",\"server_tool_use\":{\"web_search_requests\":2,\"web_fetch_requests\":5}")
        t.expectEqual(claudeRecords(search).first?.tokens.webSearches, 2)
        let dated = try t.unwrap(claudeRecords(assistantLine(id: "msg_01D", model: "claude-opus-4-5-20251101")).first)
        t.expectEqual(dated.model, "claude-opus-4-5", "the stored model is the normalised id")
    }

    t.test("cache-write tokens are split, and repaired when the split and the total disagree") {
        // Old shape: no split, everything is a 5-minute write.
        let old = #"{"message":{"model":"claude-opus-4-5-20251101","id":"msg_01O","usage":{"input_tokens":100,"output_tokens":300,"cache_creation_input_tokens":5000,"cache_read_input_tokens":20000},"stop_reason":"end_turn"},"costUSD":9.99,"requestId":"r","type":"assistant","timestamp":"2026-10-11T19:40:00.000Z"}"#
        let oldTokens = try t.unwrap(claudeRecords(old).first).tokens
        t.expectEqual(oldTokens.cacheWrite5m, 5000)
        t.expectEqual(oldTokens.cacheWrite1h, 0)
        // Total larger than the split: the difference is priced as 5-minute.
        let larger = ClaudeUsageReader.tokens(from: ["cache_creation_input_tokens": 1000,
                                                     "cache_creation": ["ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 600]])
        t.expectEqual(larger.cacheWrite5m, 400)
        t.expectEqual(larger.cacheWrite1h, 600)
        // Total smaller than the split (0 before Claude Code 2.1.152): the split is kept.
        let smaller = ClaudeUsageReader.tokens(from: ["cache_creation_input_tokens": 0,
                                                      "cache_creation": ["ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 600]])
        t.expectEqual(smaller.cacheWrite5m, 100)
        t.expectEqual(smaller.cacheWrite1h, 600)
        // Odd values never crash and never go negative.
        let odd = ClaudeUsageReader.tokens(from: ["input_tokens": -5, "output_tokens": "12", "cache_read_input_tokens": true,
                                                  "cache_creation_input_tokens": NSNull(), "cache_creation": "nope"])
        t.expectEqual(odd.total, 0)
        t.expectEqual(ClaudeUsageReader.tokens(from: ["input_tokens": 12.0]).input, 12, "a whole number written as 12.0 still counts")
    }

    t.test("spaced JSON and other timestamp forms are still read") {
        let spaced = #"{ "type": "assistant", "requestId": "req_1", "timestamp": "2026-10-11T13:00:00-07:00", "message": { "model": "claude-sonnet-5-5", "id": "msg_01Z", "usage": { "input_tokens": 5, "output_tokens": 6 } } }"#
        let record = try t.unwrap(claudeRecords(spaced).first, "a line with spaces after separators")
        t.expectEqual(record.tokens.input, 5)
        t.expectEqual(record.timestampMs, Int64(date("2026-10-11T20:00:00Z").timeIntervalSince1970 * 1000), "offset form")
        t.expectEqual(LineBytes.timestampMs("2026-10-11T20:00:01.250Z"), Int64(date("2026-10-11T20:00:01Z").timeIntervalSince1970 * 1000) + 250)
        t.expectEqual(LineBytes.timestampMs("2026-10-11T20:00:01Z"), Int64(date("2026-10-11T20:00:01Z").timeIntervalSince1970 * 1000))
        t.expectEqual(LineBytes.timestampMs("1970-01-01T00:00:00.000Z"), 0)
        t.expectEqual(LineBytes.timestampMs("2024-02-29T23:59:59.999Z"), Int64(date("2024-02-29T23:59:59Z").timeIntervalSince1970 * 1000) + 999)
        t.expectNil(LineBytes.timestampMs("yesterday"))
        t.expectNil(LineBytes.timestampMs(42))
    }

    t.test("advisor calls inside a response become their own records") {
        let extra = ",\"iterations\":[{\"type\":\"message\",\"input_tokens\":2,\"output_tokens\":10},"
            + "{\"type\":\"advisor_message\",\"model\":\"claude-fable-5-1\",\"input_tokens\":1000,\"output_tokens\":200,"
            + "\"cache_read_input_tokens\":50,\"cache_creation_input_tokens\":0}]"
        let records = claudeRecords(assistantLine(id: "msg_01V", extraUsage: extra))
        t.expectEqual(records.count, 2)
        let advisor = try t.unwrap(records.last)
        t.expectEqual(advisor.key, "claude|msg_01V|req_msg_01V:advisor:1")
        t.expectEqual(advisor.model, "claude-fable-5-1")
        t.expectEqual(advisor.tokens.input, 1000)
        t.expectEqual(advisor.tokens.output, 200)
        t.expectEqual(advisor.tokens.cacheRead, 50)
        t.expectEqual(records.first?.tokens.input, 2, "the main record keeps the top-level numbers")
    }

    t.test("the project is the folder the session was started in") {
        t.expectEqual(ClaudeProjectName.name(cwd: "/Users/test/dev/alpha", projectDir: "-Users-test-dev-alpha"), "alpha")
        t.expectEqual(ClaudeProjectName.name(cwd: "/Users/test/dev/beta site", projectDir: "-Users-test-dev-beta-site"), "beta site")
        t.expectEqual(ClaudeProjectName.name(cwd: "/Users/test/dev/alpha/Sources/App", projectDir: "-Users-test-dev-alpha"), "alpha",
                      "a subfolder the agent moved into still belongs to the project")
        t.expectEqual(ClaudeProjectName.name(cwd: "/Users/test/elsewhere", projectDir: "custom-name"), "elsewhere", "no match: folder of cwd")
        t.expectEqual(ClaudeProjectName.name(cwd: nil, projectDir: "-Users-test-dev-alpha"), "-Users-test-dev-alpha")
        t.expectEqual(ClaudeProjectName.name(cwd: nil, projectDir: ""), "unknown")
        t.expectEqual(ClaudeProjectName.encoded("/Users/me/x.y_z/perch/.build"), "-Users-me-x-y-z-perch--build")
    }
}

private func claudePathTests(_ t: TestRunner) {
    let session = "11111111-1111-4111-8111-111111111111"
    t.test("transcript file names and the session they belong to") {
        t.expect(ClaudeUsageReader.isTranscriptName("\(session).jsonl"))
        t.expect(ClaudeUsageReader.isTranscriptName("agent-a1b2c3d4e5f60718.jsonl"))
        t.expect(ClaudeUsageReader.isTranscriptName("\(session).orphaned-1791756060000-k3x9.jsonl"))
        t.expect(ClaudeUsageReader.isTranscriptName("\(session).jsonl.superseded-1791756000000"))
        t.expect(!ClaudeUsageReader.isTranscriptName("journal.jsonl"), "workflow journals are not transcripts")
        t.expect(!ClaudeUsageReader.isTranscriptName("agent-a1b2c3d4e5f60718.meta.json"))
        t.expect(!ClaudeUsageReader.isTranscriptName("notes.jsonl.superseded-1"), "a superseded name needs a session id in front")
        t.expect(!ClaudeUsageReader.isTranscriptName("\(session).jsonl.bak"))

        t.expectEqual(ClaudeUsageReader.place(ofRelativePath: ["-p", "\(session).jsonl"])?.session, session)
        t.expectEqual(ClaudeUsageReader.place(ofRelativePath: ["-p", "\(session).jsonl"])?.projectDir, "-p")
        t.expectEqual(ClaudeUsageReader.place(ofRelativePath: ["-p", session, "subagents", "agent-x.jsonl"])?.session, session,
                      "a subagent belongs to the session folder above it")
        t.expectEqual(ClaudeUsageReader.place(ofRelativePath: ["-p", session, "subagents", "workflows", "w1", "agent-x.jsonl"])?.session, session)
        t.expectEqual(ClaudeUsageReader.place(ofRelativePath: ["-p", "\(session).orphaned-1791756060000-k3x9.jsonl"])?.session, session,
                      "a set-aside file is never a session of its own")
        t.expectEqual(ClaudeUsageReader.place(ofRelativePath: ["-p", "\(session).jsonl.superseded-1791756000000"])?.session, session)
        t.expect(ClaudeUsageReader.place(ofRelativePath: ["-p", "not-a-uuid.jsonl"]).map { $0.session == nil } ?? false,
                 "a file name that is not a session id is not used as one")
        t.expect(ClaudeUsageReader.place(ofRelativePath: ["stray.jsonl"]) == nil, "files directly in projects/ are ignored")
        t.expect(ClaudeUsageReader.isUUID(session) && ClaudeUsageReader.isUUID(session.uppercased()))
        t.expect(!ClaudeUsageReader.isUUID("11111111-1111-4111-8111-11111111111") && !ClaudeUsageReader.isUUID("\(session)x"))
    }
}

// MARK: Claude fixtures

private func claudeFixtureTests(_ t: TestRunner, fixtures: URL, expected: JSONValue, folder: (String) -> URL) {
    let projects = fixtures.appendingPathComponent("projects")
    /// Path order stands in for file age, as the fixtures' README asks.
    func pathRank(_ paths: [String]) -> (String) -> Int64? {
        let order = Dictionary(uniqueKeysWithValues: paths.sorted().enumerated().map { ($1, Int64($0)) })
        return { order[$0] }
    }
    let fixturePaths = ClaudeUsageReader(projectsDirs: [projects]).files().map(\.path)

    t.test("the fixture tree is found: six transcripts, no journal, no side files") {
        t.expectEqual(fixturePaths.count, expected["counts"]["transcriptFiles"].intValue ?? -1)
        t.expect(fixturePaths.allSatisfy { $0.hasSuffix(".jsonl") })
        t.expectEqual(fixturePaths.filter { $0.contains("/subagents/") }.count, 2)
    }

    t.test("fixture totals: all time, by model, by project, by session, main vs sidechain") {
        let ledger = try memoryLedger(t)
        let report = scanClaude(projects, into: ledger, age: pathRank(fixturePaths))
        t.expectEqual(report.filesFound, 6)
        t.expectEqual(report.filesRead, 6)
        t.expect(!report.incomplete)

        checkTotals(t, total(ledger), expected["allTime"], "all time")
        t.expectEqual(total(ledger).total, expected["allTime"]["totalTokens"].intValue ?? -1, "total tokens")
        let split = try ledger.cacheWriteSplit(agent: .claude)
        t.expectEqual(split.fiveMinute, expected["allTime"]["cacheWrite5m"].intValue ?? -1, "5-minute cache writes")
        t.expectEqual(split.oneHour, expected["allTime"]["cacheWrite1h"].intValue ?? -1, "1-hour cache writes")
        t.expectEqual(split.webSearches, expected["allTime"]["webSearchRequests"].intValue ?? -1, "web searches")

        let byModel = try ledger.totals(by: .model)
        t.expectEqual(byModel.count, 6)
        for (model, want) in expected["byModel"].objectValue ?? [:] { checkTotals(t, byModel[model], want, "model \(model)") }

        let byProject = try ledger.totals(by: .project)
        t.expectEqual(Set(byProject.keys), ["alpha", "beta site"], "projects are named after the cwd's folder")
        for (dir, want) in expected["byProject"].objectValue ?? [:] {
            checkTotals(t, byProject[expected["projects"][dir]["name"].stringValue ?? "?"], want, "project \(dir)")
        }

        let bySession = try ledger.totals(by: .session)
        t.expectEqual(bySession.count, 4, "subagent usage belongs to the parent session")
        for (session, want) in expected["bySession"].objectValue ?? [:] { checkTotals(t, bySession[session], want, "session \(session.prefix(4))") }

        let bySidechain = try ledger.totals(by: .sidechain)
        checkTotals(t, bySidechain["main"], expected["bySidechain"]["main"], "main conversation")
        checkTotals(t, bySidechain["sidechain"], expected["bySidechain"]["sidechain"], "sidechain")

        t.expectEqual(try ledger.unpricedModels()[.claude] ?? [], expected["unpricedModels"].arrayValue?.compactMap(\.stringValue) ?? ["?"])

        let diagnostics = expected["scanDiagnostics"]["scan"]
        t.expectEqual(ledger.stats.duplicates, diagnostics["duplicateLines"].intValue ?? -1, "duplicate lines")
        t.expectEqual(ledger.stats.upgrades, diagnostics["upgrades"].intValue ?? -1, "placeholder upgrades")
        t.expectEqual(ledger.stats.sidechainReplays, diagnostics["sidechainReplays"].intValue ?? -1, "sidechain replays")
        t.expectEqual(report.recordsSeen, diagnostics["usageLines"].intValue ?? -1, "usage lines")
        t.expectEqual(try ledger.buckets().reduce(0) { $0 + $1.totals.messages }, 18, "rows in the ledger")

        // The wrong answers the README warns about must not come out.
        let naive = expected["scanDiagnostics"]["naiveSumOfEveryUsageLine"]
        t.expect(total(ledger).output != naive["output"].intValue, "adding every line would overcount output")
        t.expect(total(ledger).cacheRead != naive["cacheRead"].intValue, "adding every line would overcount cache reads")
    }

    t.test("scanning the same lines again changes nothing") {
        let ledger = try memoryLedger(t)
        scanClaude(projects, into: ledger, age: pathRank(fixturePaths))
        let before = total(ledger)
        let again = scanClaude(projects, into: ledger, age: pathRank(fixturePaths))
        t.expectEqual(again.filesRead, 0, "unchanged files are skipped without being read")
        // The same lines arriving from other paths (a restored backup, a second config folder).
        let twin = folder("claude-twin").appendingPathComponent("projects")
        copy(projects, to: twin)
        let twinReport = scanClaude(twin, into: ledger)
        t.expectEqual(twinReport.filesRead, 6)
        t.expect(approx(total(ledger).costUSD, before.costUSD))
        var withoutCost = total(ledger), beforeWithoutCost = before
        withoutCost.costUSD = 0
        beforeWithoutCost.costUSD = 0
        t.expectEqual(withoutCost, beforeWithoutCost, "totals after a second pass")
    }

    t.test("the result does not depend on the order files are scanned in") {
        // Give the files modification times in reverse path order, so the fork is read before the original.
        let shuffled = folder("claude-reversed").appendingPathComponent("projects")
        copy(projects, to: shuffled)
        let paths = ClaudeUsageReader(projectsDirs: [shuffled]).files().map(\.path).sorted()
        for (index, path) in paths.enumerated() {
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 60)],
                                                   ofItemAtPath: path)
        }
        let ledger = try memoryLedger(t)
        scanClaude(shuffled, into: ledger, age: pathRank(paths))
        let bySession = try ledger.totals(by: .session)
        for (session, want) in expected["bySession"].objectValue ?? [:] {
            checkTotals(t, bySession[session], want, "reversed order, session \(session.prefix(4))")
        }
        checkTotals(t, total(ledger), expected["allTime"], "reversed order, all time")
    }

    for zoneName in ["America/Los_Angeles", "UTC"] {
        t.test("days in \(zoneName) match expected.json, by model and by project") {
            let ledger = try memoryLedger(t)
            scanClaude(projects, into: ledger, age: pathRank(fixturePaths))
            let zone = try t.unwrap(TimeZone(identifier: zoneName))
            let summary = try t.unwrap(UsageAggregator.summarize(try ledger.buckets(), now: date("2026-10-12T02:00:00Z"), timeZone: zone)[.claude])
            let wantDays = expected["days"][zoneName].objectValue ?? [:]
            t.expectEqual(summary.days.filter { $0.totals.messages > 0 }.map(\.day), wantDays.keys.sorted(), "which days have usage")
            for day in summary.days where day.totals.messages > 0 {
                let want = wantDays[day.day] ?? .null
                checkTotals(t, day.totals, want["totals"], "\(zoneName) \(day.day)")
                t.expectEqual(day.byModel.count, want["byModel"].objectValue?.count ?? -1, "\(day.day) models")
                for (model, block) in want["byModel"].objectValue ?? [:] { checkTotals(t, day.byModel[model], block, "\(day.day) \(model)") }
                for (dir, block) in want["byProject"].objectValue ?? [:] {
                    checkTotals(t, day.byProject[expected["projects"][dir]["name"].stringValue ?? "?"], block, "\(day.day) \(dir)")
                }
            }
            checkTotals(t, summary.allTime, expected["allTime"], "\(zoneName) all time")
            // 02:00 UTC on the 12th is still the 11th in Los Angeles and already the 12th in UTC.
            if zoneName == "UTC" {
                t.expectEqual(summary.today.messages, 0, "nothing yet on the 12th in UTC")
            } else {
                checkTotals(t, summary.today, wantDays["2026-10-11"]?["totals"] ?? .null, "today in Los Angeles")
            }
        }
    }

    t.test("set-aside transcripts: every response once, one session") {
        let ledger = try memoryLedger(t)
        let report = scanClaude(fixtures.appendingPathComponent("set-aside/projects"), into: ledger)
        t.expectEqual(report.filesFound, 3, "the .jsonl.superseded-… file is found too")
        let want = expected["setAside"]
        checkTotals(t, total(ledger), want["totals"], "set-aside")
        let bySession = try ledger.totals(by: .session)
        t.expectEqual(Array(bySession.keys), [want["session"].stringValue ?? "?"], "exactly one session")
        t.expectEqual(Array(try ledger.totals(by: .project).keys), ["gamma"])

        // Reading only the live file would undercount.
        let liveOnly = folder("set-aside-live").appendingPathComponent("projects/-Users-test-dev-gamma")
        copy(fixtures.appendingPathComponent("set-aside/projects/-Users-test-dev-gamma/66666666-6666-4666-8666-666666666666.jsonl"),
             to: liveOnly.appendingPathComponent("66666666-6666-4666-8666-666666666666.jsonl"))
        let live = try memoryLedger(t)
        scanClaude(liveOnly.deletingLastPathComponent(), into: live)
        checkTotals(t, total(live), want["liveFileOnlyTotals"], "live file only")
    }

    t.test("the de-duplication rule, one case at a time") {
        let ledger = try memoryLedger(t)
        var older = ScannedFile(path: "/t/older.jsonl", agent: .claude)
        older.birthMs = 100
        try ledger.save(&older)
        var newer = ScannedFile(path: "/t/newer.jsonl", agent: .claude)
        newer.birthMs = 200
        try ledger.save(&newer)
        t.expect(older.id != 0 && newer.id != 0 && older.id != newer.id, "saved files get ids")
        func record(_ key: String, message: String = "msg_1", session: String = "s1", output: Int, final: Bool = true,
                    sidechain: Bool = false, at ms: Int64 = 1_800_000_000_000) -> UsageRecord {
            UsageRecord(key: key, agent: .claude, session: session, messageID: message, project: "p", timestampMs: ms,
                        model: "claude-opus-5-5", tokens: PricedTokens(input: 1, output: output), isSidechain: sidechain, isFinal: final)
        }
        func count() -> Int { total(ledger).messages }

        // Step 7: a new key is stored; a repeat is not counted again.
        t.expectEqual(try ledger.upsert(record("k1", output: 6, final: false), from: newer), .inserted)
        t.expectEqual(try ledger.upsert(record("k1", output: 6, final: false), from: newer), .duplicate)
        // 7.2 the larger token total wins (final usage replaces a streaming placeholder), never the smaller.
        t.expectEqual(try ledger.upsert(record("k1", output: 380), from: newer), .upgraded)
        t.expectEqual(try ledger.upsert(record("k1", output: 6, final: false), from: newer), .duplicate)
        t.expectEqual(total(ledger).output, 380, "'first line wins' would have kept 6")
        // 7.3 same total: the final shape replaces the placeholder shape.
        t.expectEqual(try ledger.upsert(record("k2", message: "msg_2", output: 9, final: false), from: newer), .inserted)
        t.expectEqual(try ledger.upsert(record("k2", message: "msg_2", output: 9), from: newer), .replaced)
        t.expectEqual(try ledger.upsert(record("k2", message: "msg_2", output: 9, final: false), from: newer), .duplicate)
        // 7.1 the main-conversation copy beats a sidechain copy of the same key, even with fewer tokens.
        t.expectEqual(try ledger.upsert(record("k3", message: "msg_3", output: 50, sidechain: true), from: newer), .inserted)
        t.expectEqual(try ledger.upsert(record("k3", message: "msg_3", output: 40), from: newer), .upgraded)
        t.expectEqual(try ledger.upsert(record("k3", message: "msg_3", output: 500, sidechain: true), from: newer), .duplicate)
        t.expectEqual(count(), 3)
        t.expectEqual(total(ledger).output, 380 + 9 + 40)

        // Step 8: the response keeps the time of its earliest line, whichever copy is kept.
        let dayMs: Int64 = 86_400_000
        t.expectEqual(try ledger.upsert(record("k1", output: 380, at: 1_800_000_000_000 - dayMs), from: newer), .duplicate)
        t.expectEqual(try ledger.upsert(record("k2", message: "msg_2", output: 900, at: 1_800_000_000_000 + dayMs), from: newer), .upgraded)
        let starts = Set(try ledger.buckets().map(\.start))
        t.expectEqual(starts, [1_800_000_000 - 86_400 - (1_800_000_000 - 86_400) % 900, 1_800_000_000 - 1_800_000_000 % 900],
                      "k1 moved a day earlier; k2 stayed although its better copy was written later")

        // Step 6: a sidechain replay (same session and message, other key) is one response.
        t.expectEqual(try ledger.upsert(record("k1-replay", output: 380, sidechain: true), from: newer), .droppedSidechainReplay)
        t.expectEqual(count(), 3)
        // ...in either order: here the sidechain copy arrives first and is removed when the main one arrives.
        t.expectEqual(try ledger.upsert(record("k4-replay", message: "msg_4", output: 70, sidechain: true), from: newer), .inserted)
        t.expectEqual(try ledger.upsert(record("k4", message: "msg_4", output: 70), from: newer), .inserted)
        t.expectEqual(count(), 4)
        t.expectEqual(try ledger.totals(by: .sidechain)["sidechain"]?.messages ?? 0, 0)
        // The same message id in ANOTHER session is a different response (the rule is per session).
        t.expectEqual(try ledger.upsert(record("k4-other", message: "msg_4", session: "s2", output: 70, sidechain: true), from: newer), .inserted)
        t.expectEqual(count(), 5)
        // Two sidechain entries with one message id but different keys are both kept (no main copy exists).
        t.expectEqual(try ledger.upsert(record("k5a", message: "msg_5", output: 1, sidechain: true), from: newer), .inserted)
        t.expectEqual(try ledger.upsert(record("k5b", message: "msg_5", output: 1, sidechain: true), from: newer), .inserted)
        t.expectEqual(count(), 7)

        // Exact tie between files (a fork's copy): the older file keeps the response, in either scan order.
        t.expectEqual(try ledger.upsert(record("k6", message: "msg_6", session: "fork", output: 5), from: newer), .inserted)
        t.expectEqual(try ledger.upsert(record("k6", message: "msg_6", session: "original", output: 5), from: older), .replaced)
        t.expectEqual(try ledger.upsert(record("k6", message: "msg_6", session: "fork", output: 5), from: newer), .duplicate)
        t.expectEqual(try ledger.totals(by: .session)["original"]?.messages, 1)
        t.expect(try ledger.totals(by: .session)["fork"] == nil)
        // Same age: the path decides.
        var twin = ScannedFile(path: "/t/a-first.jsonl", agent: .claude)
        twin.birthMs = 100
        try ledger.save(&twin)
        t.expectEqual(try ledger.upsert(record("k6", message: "msg_6", session: "twin", output: 5), from: twin), .replaced)
        t.expectEqual(try ledger.upsert(record("k6", message: "msg_6", session: "original", output: 5), from: older), .duplicate)

        t.expectEqual(ledger.stats.upgrades, 3)
        t.expectEqual(ledger.stats.sidechainReplays, 2)
        // Records without a message id (other agents) skip the replay rule and still de-duplicate by key.
        let plain = UsageRecord(key: "codex|t|1|0|0|1", agent: .codex, session: "t", project: "p", timestampMs: 0, model: "gpt-x",
                                tokens: PricedTokens(input: 1, output: 1))
        t.expectEqual(try ledger.upsert(plain, from: older), .inserted)
        t.expectEqual(try ledger.upsert(plain, from: older), .duplicate)
        t.expectEqual(total(ledger, .codex).messages, 1)
        t.expectEqual(count(), 8, "agents are kept apart")
    }

    t.test("stored costs are re-estimated when the price table changes") {
        let url = folder("reprice").appendingPathComponent("usage.sqlite")
        var ledger = try t.unwrap(try? UsageLedger(url: url))
        scanClaude(projects, into: ledger, age: pathRank(fixturePaths))
        ledger.close()
        // Pretend the rows were priced by an older table: wrong costs, an old version number.
        let database = try SQLiteDatabase(path: url.path)
        try database.execute("UPDATE responses SET cost_usd = 99, priced = 0, price_version = 0")
        database.close()
        ledger = try t.unwrap(try? UsageLedger(url: url))
        checkTotals(t, total(ledger), expected["allTime"], "after re-pricing")
        t.expectEqual(try ledger.unpricedModels()[.claude] ?? [], ["claude-next-9"])
        t.expectEqual(scanClaude(projects, into: ledger, age: pathRank(fixturePaths)).filesRead, 0, "re-pricing does not need a rescan")
        ledger.close()
    }

    t.test("a scan that is told to stop reads nothing more and forgets nothing") {
        let ledger = try memoryLedger(t)
        let stopped = UsageScanner.scan(ClaudeUsageReader(projectsDirs: [projects]), into: ledger, shouldStop: { true })
        t.expect(stopped.incomplete)
        t.expectEqual(stopped.filesRead, 0)
        t.expectEqual(total(ledger).messages, 0)
        var allowed = 2
        let partial = UsageScanner.scan(ClaudeUsageReader(projectsDirs: [projects]), into: ledger, fileAge: pathRank(fixturePaths), shouldStop: {
            allowed -= 1
            return allowed < 0
        })
        t.expect(partial.incomplete)
        t.expectEqual(partial.filesRead, 2)
        let known = fixturePaths.filter { ledger.file(atPath: $0) != nil }
        t.expectEqual(known.count, 2, "the two files that were read are remembered")
        // The next full scan finishes the job and arrives at the same totals as an uninterrupted one.
        var progressCalls = 0
        let rest = UsageScanner.scan(ClaudeUsageReader(projectsDirs: [projects]), into: ledger, fileAge: pathRank(fixturePaths), afterFile: { progressCalls += 1 })
        t.expectEqual(rest.filesRead, 4)
        t.expectEqual(progressCalls, 4)
        checkTotals(t, total(ledger), expected["allTime"], "interrupted, then finished")
        let bySession = try ledger.totals(by: .session)
        for (session, want) in expected["bySession"].objectValue ?? [:] { checkTotals(t, bySession[session], want, "resumed scan, session \(session.prefix(4))") }
    }
}

// MARK: Reading growing files

private func tailTests(_ t: TestRunner, fixtures: URL, expected: JSONValue, folder: (String) -> URL) {
    let session = "44444444-4444-4444-8444-444444444444"

    t.test("incremental snapshots: half a line waits, an upgrade crosses scans, a rewrite removes nothing") {
        let projects = folder("incremental").appendingPathComponent("projects")
        let file = projects.appendingPathComponent("-Users-test-dev-alpha/\(session).jsonl")
        let ledger = try memoryLedger(t)
        for step in ["step1", "step2", "step3"] {
            let want = expected["incremental"][step]
            let source = fixtures.appendingPathComponent(want["file"].stringValue?.replacingOccurrences(of: "incremental/", with: "incremental/") ?? "")
            // Rewrite in place so it stays the same file, as a growing transcript would.
            let bytes = try Data(contentsOf: source)
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: bytes)
                try handle.close()
            } else {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file)
            }
            t.expectEqual(bytes.count, want["fileBytes"].intValue ?? -1, "\(step) file size")
            scanClaude(projects, into: ledger)
            t.expectEqual(ledger.file(atPath: file.standardizedFileURL.path)?.cursor.offset, Int64(want["consumedBytes"].intValue ?? -1),
                          "\(step) bytes consumed")
            checkTotals(t, total(ledger), want["totals"], step)
        }
        t.expectEqual(ledger.stats.upgrades, 1, "d1 was upgraded from its placeholder exactly once")
        t.expectEqual(Array(try ledger.totals(by: .session).keys), [session])
    }

    t.test("a half-written last line is left alone until its newline arrives") {
        let projects = folder("half-line").appendingPathComponent("projects")
        let file = projects.appendingPathComponent("-Users-test-dev-alpha/\(alphaSession).jsonl")
        let first = assistantLine(id: "msg_01H1", output: 100)
        let second = assistantLine(id: "msg_01H2", output: 200)
        let cut = second.index(second.startIndex, offsetBy: second.count / 2)
        write(first + "\n" + second[..<cut], to: file)
        let ledger = try memoryLedger(t)
        scanClaude(projects, into: ledger)
        t.expectEqual(total(ledger).messages, 1)
        t.expectEqual(ledger.file(atPath: file.standardizedFileURL.path)?.cursor.offset, Int64(first.utf8.count + 1))

        append(String(second[cut...]), to: file)             // still no newline
        scanClaude(projects, into: ledger)
        t.expectEqual(total(ledger).messages, 1, "a complete-looking line without a newline is not consumed")

        append("\n", to: file)
        scanClaude(projects, into: ledger)
        t.expectEqual(total(ledger).messages, 2)
        t.expectEqual(total(ledger).output, 300)
        t.expectEqual(ledger.file(atPath: file.standardizedFileURL.path)?.cursor.offset, Int64(first.utf8.count + second.utf8.count + 2))
    }

    t.test("a file read in several scans gives the same result as one full scan, also across a restart") {
        var lines: [String] = []
        for index in 0..<120 {
            let id = "msg_01G\(index)"
            // Two placeholder lines and a final line per response, with other lines in between.
            lines.append(assistantLine(id: id, output: 5, read: 1000 + index, final: false, padding: index * 7))
            lines.append(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"timestamp":"2026-10-11T20:00:00.000Z"}"#)
            lines.append(assistantLine(id: id, output: 5, read: 1000 + index, final: false))
            lines.append("{not json at all")
            lines.append(assistantLine(id: id, model: index % 3 == 0 ? "claude-haiku-5-5" : "claude-opus-5-5", output: 50 + index, read: 1000 + index))
        }
        let whole = lines.joined(separator: "\n") + "\n"

        let fullRoot = folder("growth-full").appendingPathComponent("projects")
        write(whole, to: fullRoot.appendingPathComponent("-Users-test-dev-alpha/\(alphaSession).jsonl"))
        let full = try memoryLedger(t)
        scanClaude(fullRoot, into: full)

        let stepRoot = folder("growth-steps")
        let stepProjects = stepRoot.appendingPathComponent("projects")
        let stepFile = stepProjects.appendingPathComponent("-Users-test-dev-alpha/\(alphaSession).jsonl")
        let ledgerURL = stepRoot.appendingPathComponent("data/usage.sqlite")
        let bytes = Array(whole.utf8)
        // Cut points chosen without regard to line ends.
        let cuts = [0, 137, 2_048, 9_999, bytes.count / 2, bytes.count - 3, bytes.count]
        var changedScans = 0
        for index in 1..<cuts.count {
            let piece = String(decoding: bytes[cuts[index - 1]..<cuts[index]], as: UTF8.self)
            append(piece, to: stepFile)
            // A new ledger object each time: what was learned must survive on disk.
            let ledger = try t.unwrap(try? UsageLedger(url: ledgerURL))
            changedScans += scanClaude(stepProjects, into: ledger).filesRead
            ledger.close()
        }
        let stepped = try t.unwrap(try? UsageLedger(url: ledgerURL))
        t.expectEqual(changedScans, cuts.count - 1)
        t.expectEqual(total(stepped).messages, 120)
        t.expectEqual(total(stepped).messages, total(full).messages)
        t.expectEqual(total(stepped).output, total(full).output)
        t.expectEqual(total(stepped).cacheRead, total(full).cacheRead)
        t.expect(approx(total(stepped).costUSD, total(full).costUSD), "cost of stepped vs full scan")
        t.expectEqual(try stepped.totals(by: .model).keys.sorted(), ["claude-haiku-5-5", "claude-opus-5-5"])
        t.expectEqual(stepped.file(atPath: stepFile.standardizedFileURL.path)?.cursor.offset, Int64(bytes.count))
        // After a restart nothing is read again.
        t.expectEqual(scanClaude(stepProjects, into: stepped).filesRead, 0, "an unchanged file is not rescanned after a restart")
        stepped.close()
    }

    t.test("truncated, replaced and rewritten files start again and remove nothing") {
        let projects = folder("truncate").appendingPathComponent("projects")
        let file = projects.appendingPathComponent("-Users-test-dev-alpha/\(alphaSession).jsonl")
        let a = assistantLine(id: "msg_01TA", output: 10), b = assistantLine(id: "msg_01TB", output: 20), c = assistantLine(id: "msg_01TC", output: 40)
        write(a + "\n" + b + "\n", to: file)
        let ledger = try memoryLedger(t)
        scanClaude(projects, into: ledger)
        t.expectEqual(total(ledger).output, 30)

        // Truncated to nothing, then a new, shorter conversation.
        write(c + "\n", to: file)
        scanClaude(projects, into: ledger)
        t.expectEqual(total(ledger).messages, 3, "a and b stay although they are no longer in the file")
        t.expectEqual(total(ledger).output, 70)

        // Replaced by another file of the same name (new inode), longer than the old position.
        let d = assistantLine(id: "msg_01TD", output: 80, padding: 600)
        let replacement = file.deletingLastPathComponent().appendingPathComponent("replacement.tmp")
        write(d + "\n" + a + "\n", to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        scanClaude(projects, into: ledger)
        t.expectEqual(total(ledger).messages, 4)
        t.expectEqual(total(ledger).output, 150)

        // Same size, different bytes just before the saved position (rewritten in place).
        let e = assistantLine(id: "msg_01TE", output: 80, session: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", padding: 600)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data((a + "\n" + e + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        scanClaude(projects, into: ledger)
        t.expectEqual(total(ledger).messages, 5, "the rewritten line is noticed through the tail hash")

        // The file disappears: its responses stay, its scan position is forgotten.
        try FileManager.default.removeItem(at: file)
        let after = scanClaude(projects, into: ledger)
        t.expectEqual(after.filesFound, 0)
        t.expectEqual(total(ledger).messages, 5)
        t.expect(ledger.file(atPath: file.standardizedFileURL.path) == nil)
    }

    t.test("unreadable files, empty lines, CRLF and non-transcript files are tolerated") {
        let projects = folder("tolerant").appendingPathComponent("projects")
        let dir = projects.appendingPathComponent("-Users-test-dev-alpha")
        let good = dir.appendingPathComponent("\(alphaSession).jsonl")
        write("\n\n" + assistantLine(id: "msg_01K1", output: 11) + "\r\n\r\n" + assistantLine(id: "msg_01K2", output: 22) + "\n", to: good)
        let locked = dir.appendingPathComponent("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jsonl")
        write(assistantLine(id: "msg_01K3", output: 33) + "\n", to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        write(assistantLine(id: "msg_01K4", output: 44) + "\n", to: dir.appendingPathComponent("\(alphaSession)/subagents/workflows/w1/journal.jsonl"))
        write(assistantLine(id: "msg_01K5", output: 55) + "\n", to: dir.appendingPathComponent("\(alphaSession)/tool-results/dump.jsonl"))
        write("{}", to: dir.appendingPathComponent("\(alphaSession)/subagents/agent-1.meta.json"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder-named.jsonl"), withIntermediateDirectories: true)

        let ledger = try memoryLedger(t)
        let report = scanClaude(projects, into: ledger)
        t.expectEqual(report.filesFound, 2, "a folder whose name ends in .jsonl is not a file")
        t.expectEqual(report.filesUnreadable, 1, "the locked file")
        t.expectEqual(total(ledger).messages, 2)
        t.expectEqual(total(ledger).output, 33, "journal.jsonl and tool-results are not transcripts")
        t.expect(!report.incomplete)

        // Once it becomes readable it is picked up.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        scanClaude(projects, into: ledger)
        t.expectEqual(total(ledger).output, 66)

        // A named pipe that looks like a transcript must not hang the scan.
        let pipe = dir.appendingPathComponent("dddddddd-dddd-4ddd-8ddd-dddddddddddd.jsonl")
        t.expectEqual(mkfifo(pipe.path, 0o644), 0)
        let withPipe = scanClaude(projects, into: ledger)
        t.expectEqual(withPipe.filesUnreadable, 1, "the pipe is skipped")
        t.expectEqual(total(ledger).output, 66)
        try FileManager.default.removeItem(at: pipe)

        // A missing projects folder is not an error.
        let nothing = scanClaude(projects.appendingPathComponent("does-not-exist"), into: ledger)
        t.expectEqual(nothing.filesFound, 0)
        t.expect(!nothing.incomplete)
    }

    t.test("a line larger than the cap is skipped and the lines after it are still read") {
        let projects = folder("oversized").appendingPathComponent("projects")
        let file = projects.appendingPathComponent("-Users-test-dev-alpha/\(alphaSession).jsonl")
        write(assistantLine(id: "msg_01L1", output: 1) + "\n", to: file)
        // 33 MB without a newline, then a normal line.
        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd()
        let megabyte = Data(repeating: UInt8(ascii: "y"), count: 1 << 20)
        for _ in 0..<33 { try handle.write(contentsOf: megabyte) }
        try handle.write(contentsOf: Data(("\n" + assistantLine(id: "msg_01L2", output: 2) + "\n").utf8))
        try handle.close()

        var seen = 0
        var longest = 0
        guard case .ready(let tail) = JSONLTail.open(path: file.path, cursor: FileCursor()) else {
            t.expect(false, "the file should open")
            return
        }
        tail.forEachLine { line in
            seen += 1
            longest = max(longest, line.count)
        }
        t.expectEqual(seen, 2, "the two normal lines")
        t.expectEqual(tail.oversizedLines, 1)
        t.expect(longest < 10_000)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
        t.expectEqual(tail.cursor.offset, Int64(size), "everything up to the last newline is consumed")

        // A line of a few megabytes (larger than one read) is still delivered whole.
        let bigFile = projects.appendingPathComponent("-Users-test-dev-alpha/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jsonl")
        write(assistantLine(id: "msg_01L3", output: 3, padding: 3 << 20) + "\n" + assistantLine(id: "msg_01L4", output: 4) + "\n", to: bigFile)
        let ledger = try memoryLedger(t)
        scanClaude(projects, into: ledger)
        t.expectEqual(total(ledger).output, 1 + 2 + 3 + 4)
    }

    t.test("opening reports unchanged, unreadable and restarted files") {
        let file = folder("tail").appendingPathComponent("a.jsonl")
        write("one\ntwo\n", to: file)
        guard case .ready(let first) = JSONLTail.open(path: file.path, cursor: FileCursor()) else {
            t.expect(false, "should open")
            return
        }
        var lines: [String] = []
        first.forEachLine { lines.append(String(decoding: $0, as: UTF8.self)) }
        t.expectEqual(lines, ["one", "two"])
        t.expect(!first.startsOver)
        t.expect(first.birthMs > 0)
        if case .unchanged = JSONLTail.open(path: file.path, cursor: first.cursor) { t.expect(true) } else { t.expect(false, "expected unchanged") }
        if case .unreadable = JSONLTail.open(path: file.path + ".missing", cursor: FileCursor()) { t.expect(true) } else { t.expect(false, "expected unreadable") }
        if case .unreadable = JSONLTail.open(path: file.deletingLastPathComponent().path, cursor: FileCursor()) { t.expect(true) } else {
            t.expect(false, "a folder is not readable as a file")
        }
        write("x\n", to: file)
        guard case .ready(let second) = JSONLTail.open(path: file.path, cursor: first.cursor) else {
            t.expect(false, "should open again")
            return
        }
        t.expect(second.startsOver, "shorter than the saved position")
        lines = []
        second.forEachLine { lines.append(String(decoding: $0, as: UTF8.self)) }
        t.expectEqual(lines, ["x"])
    }
}

// MARK: Days

private func aggregationTests(_ t: TestRunner) {
    func bucket(_ iso: String, model: String = "m", project: String = "p", input: Int = 1, agent: AgentKind = .claude) -> UsageBucket {
        let seconds = Int64(date(iso).timeIntervalSince1970)
        return UsageBucket(agent: agent, start: seconds - seconds % UsageBucket.seconds, model: model, project: project,
                           totals: TokenTotals(input: input, output: 0, cacheWrite: 0, cacheRead: 0, costUSD: Double(input), messages: 1))
    }

    t.test("days are local, listed without gaps, and limited to 90") {
        let now = date("2026-10-12T19:00:00Z")           // noon in Los Angeles
        let buckets = [bucket("2026-10-12T18:00:00Z", input: 5),          // today
                       bucket("2026-10-12T06:59:00Z", input: 7),          // 23:59 on the 11th, local
                       bucket("2026-10-09T19:00:00Z", model: "other", project: "q", input: 11),
                       bucket("2026-07-15T19:00:00Z", input: 13),         // 89 days back: the first kept day
                       bucket("2026-07-14T19:00:00Z", input: 17),         // 90 days back: all time only
                       bucket("2026-10-13T19:00:00Z", input: 19)]         // a clock that ran ahead: all time only
        let summary = try t.unwrap(UsageAggregator.summarize(buckets, now: now, timeZone: losAngeles)[.claude])
        t.expectEqual(summary.today.input, 5)
        t.expectEqual(summary.allTime.input, 72)
        t.expectEqual(summary.allTime.messages, 6)
        t.expectEqual(summary.days.count, 90)
        t.expectEqual(summary.days.first?.day, "2026-07-15")
        t.expectEqual(summary.days.last?.day, "2026-10-12")
        t.expectEqual(summary.days.first { $0.day == "2026-10-11" }?.totals.input, 7)
        t.expectEqual(summary.days.first { $0.day == "2026-10-10" }?.totals.messages, 0, "a day without usage is listed as zero")
        let ninth = try t.unwrap(summary.days.first { $0.day == "2026-10-09" })
        t.expectEqual(ninth.byModel["other"]?.input, 11)
        t.expectEqual(ninth.byProject["q"]?.input, 11)
        t.expect(approx(summary.days.reduce(0) { $0 + $1.totals.costUSD }, 5 + 7 + 11 + 13))
    }

    t.test("a short history starts at its first day, and agents are kept apart") {
        let now = date("2026-10-12T19:00:00Z")
        let result = UsageAggregator.summarize([bucket("2026-10-10T19:00:00Z", input: 2), bucket("2026-10-12T19:00:00Z", input: 3, agent: .codex)],
                                               unpriced: [.codex: ["gpt-x"], .gemini: ["g"]], now: now, timeZone: losAngeles)
        t.expectEqual(result[.claude]?.days.map(\.day), ["2026-10-10", "2026-10-11", "2026-10-12"])
        t.expectEqual(result[.claude]?.today.messages, 0)
        t.expectEqual(result[.codex]?.days.map(\.day), ["2026-10-12"])
        t.expectEqual(result[.codex]?.unpricedModels, ["gpt-x"])
        t.expectEqual(result[.gemini]?.days.count, 0)
        t.expect(UsageAggregator.summarize([], now: now, timeZone: losAngeles).isEmpty)
    }

    t.test("day boundaries follow the local time zone, including half-hour zones and clock changes") {
        let kolkata = try t.unwrap(TimeZone(identifier: "Asia/Kolkata"))          // UTC+5:30: midnight is 18:30 UTC
        let kathmandu = try t.unwrap(TimeZone(identifier: "Asia/Kathmandu"))      // UTC+5:45: midnight is 18:15 UTC
        let ledger = try memoryLedger(t)
        var file = ScannedFile(path: "/x", agent: .claude)
        try ledger.save(&file)
        func add(_ id: String, _ iso: String) throws {
            try ledger.upsert(UsageRecord(key: id, agent: .claude, session: "s", messageID: id, project: "p",
                                          timestampMs: Int64(date(iso).timeIntervalSince1970 * 1000), model: "claude-opus-5-5",
                                          tokens: PricedTokens(input: 1)), from: file)
        }
        try add("a", "2026-10-11T18:14:59Z")
        try add("b", "2026-10-11T18:15:00Z")
        try add("c", "2026-10-11T18:29:59Z")
        try add("d", "2026-10-11T18:30:00Z")
        let buckets = try ledger.buckets()
        let now = date("2026-10-12T12:00:00Z")
        let india = try t.unwrap(UsageAggregator.summarize(buckets, now: now, timeZone: kolkata)[.claude])
        t.expectEqual(india.days.first { $0.day == "2026-10-11" }?.totals.messages, 3, "18:29:59 UTC is 23:59:59 in Kolkata")
        t.expectEqual(india.days.first { $0.day == "2026-10-12" }?.totals.messages, 1)
        let nepal = try t.unwrap(UsageAggregator.summarize(buckets, now: now, timeZone: kathmandu)[.claude])
        t.expectEqual(nepal.days.first { $0.day == "2026-10-11" }?.totals.messages, 1, "18:14:59 UTC is 23:59:59 in Kathmandu")
        t.expectEqual(nepal.days.first { $0.day == "2026-10-12" }?.totals.messages, 3)

        // The day the clocks go back in Los Angeles (1 November 2026) is 25 hours long.
        let days = LocalDays(timeZone: losAngeles)
        let start = date("2026-11-01T07:00:00Z")          // local midnight
        t.expectEqual(days.day(of: start), "2026-11-01")
        t.expectEqual(days.nextMidnight(after: start).timeIntervalSince(start), 25 * 3600)
        t.expectEqual(days.day(of: date("2026-11-02T07:59:59Z")), "2026-11-01")
        t.expectEqual(days.day(of: date("2026-11-02T08:00:00Z")), "2026-11-02")
        t.expectEqual(days.lastDays(3, endingAt: date("2026-11-02T20:00:00Z")), ["2026-10-31", "2026-11-01", "2026-11-02"])
        t.expectEqual(LocalDays(timeZone: utc).day(of: date("2026-12-31T23:59:59Z")), "2026-12-31")
        t.expectEqual(days.lastDays(90, endingAt: date("2026-10-12T19:00:00Z")).count, 90)
    }
}

// MARK: Codex and Gemini

private func codexTests(_ t: TestRunner, folder: (String) -> URL) {
    let rollout = "rollout-2026-10-10T09-15-02-019a9d1e-6c2a-7b30-9f4e-2d1c8a5b7e10.jsonl"
    let thread = "019a9d1e-6c2a-7b30-9f4e-2d1c8a5b7e10"

    for (label, fixture) in [("paginated", "codex/rollout/\(rollout)"), ("legacy", "codex/rollout/legacy/\(rollout)")] {
        t.test("Codex \(label) rollout: tokens are the differences between running totals") {
            let home = folder("codex-\(label)")
            copy(TestRunner.fixture(fixture), to: home.appendingPathComponent("sessions/2026/10/10/\(rollout)"))
            let ledger = try memoryLedger(t)
            let report = UsageScanner.scan(CodexUsageReader(home: home), into: ledger)
            t.expectEqual(report.filesRead, 1)
            let totals = total(ledger, .codex)
            // Final running totals in the fixture: input 36,590 of which 33,024 cached; output 731.
            t.expectEqual(totals.messages, 3, "three token_count lines")
            t.expectEqual(totals.input, 36_590 - 33_024)
            t.expectEqual(totals.cacheRead, 33_024)
            t.expectEqual(totals.output, 731)
            t.expectEqual(totals.cacheWrite, 0)
            t.expectEqual(totals.total, 37_321, "equals Codex's own total_tokens")
            t.expectEqual(totals.costUSD, 0, "no price list for Codex models")
            t.expectEqual(Array(try ledger.totals(by: .model).keys), ["gpt-5.2-codex"])
            t.expectEqual(Array(try ledger.totals(by: .project).keys), ["acme-api"])
            t.expectEqual(Array(try ledger.totals(by: .session).keys), [thread])
            t.expectEqual(try ledger.unpricedModels()[.codex] ?? [], ["gpt-5.2-codex"])

            // Limits: the newest line wins (13%, not the earlier 12%).
            var book = LimitBook()
            for limits in report.limits { book.merge(limits) }
            let windows = book.windows(for: .codex, at: date("2026-10-10T16:16:00Z"))
            t.expectEqual(windows.map(\.id), ["primary", "secondary"])
            t.expectEqual(windows.first?.label, "5-hour limit")
            t.expectEqual(windows.first?.usedPercent, 13)
            t.expectEqual(windows.first?.resetsAt, Date(timeIntervalSince1970: 1_791_668_102))
            t.expectEqual(windows.last?.label, "Weekly limit")
            t.expectEqual(windows.last?.usedPercent, 31.5)
            t.expectEqual(windows.last?.resetsAt, Date(timeIntervalSince1970: 1_792_166_400))
            t.expectEqual(book.planName(for: .codex), "Plus")
            t.expectEqual(book.lastUpdate(for: .codex), date("2026-10-10T16:15:58Z").addingTimeInterval(0.44))
        }
    }

    t.test("Codex: the same thread in two files is counted once, and reading resumes mid-file after a restart") {
        let home = folder("codex-twice")
        let text = TestRunner.fixtureText("codex/rollout/\(rollout)")
        let lines = text.split(separator: "\n").map(String.init)
        let file = home.appendingPathComponent("sessions/2026/10/10/\(rollout)")
        let ledgerURL = home.appendingPathComponent("perch/usage.sqlite")
        // First scan sees the lines up to and including the second token_count.
        let secondCount = (lines.enumerated().filter { $0.element.contains("\"token_count\"") }.map(\.offset))[1]
        write(lines[...secondCount].joined(separator: "\n") + "\n", to: file)
        var ledger = try t.unwrap(try? UsageLedger(url: ledgerURL))
        UsageScanner.scan(CodexUsageReader(home: home), into: ledger)
        t.expectEqual(total(ledger, .codex).messages, 2)
        t.expectEqual(total(ledger, .codex).total, 24_508)
        ledger.close()

        // After a restart the running totals are remembered, so the third line adds only its difference.
        append(lines[(secondCount + 1)...].joined(separator: "\n") + "\n", to: file)
        ledger = try t.unwrap(try? UsageLedger(url: ledgerURL))
        UsageScanner.scan(CodexUsageReader(home: home), into: ledger)
        t.expectEqual(total(ledger, .codex).messages, 3)
        t.expectEqual(total(ledger, .codex).total, 37_321)

        // The archived copy of the same thread adds nothing.
        copy(TestRunner.fixture("codex/rollout/legacy/\(rollout)"), to: home.appendingPathComponent("archived_sessions/\(rollout)"))
        let again = UsageScanner.scan(CodexUsageReader(home: home), into: ledger)
        t.expectEqual(again.filesRead, 1)
        t.expectEqual(total(ledger, .codex).total, 37_321, "same thread, same running totals: one set of rows")
        // A compressed rollout cannot be read and is ignored.
        write("not really zstd", to: home.appendingPathComponent("sessions/2026/10/01/rollout-2026-10-01T09-15-02-\(thread).jsonl.zst"))
        t.expectEqual(CodexUsageReader(home: home).files().count, 2)
        ledger.close()
    }

    t.test("Codex line shapes: nulls, old reset form, extra limits, totals that go backwards, forks") {
        func findings(_ lines: [String], state: inout CodexUsageReader.Carry) -> [UsageFinding] {
            lines.flatMap { line in withLine(line) { CodexUsageReader.findings(fromLine: $0, state: &state) } }
        }
        func count(_ input: Int, _ cached: Int, _ output: Int, last: (Int, Int, Int)? = nil, limits: String = "null",
                   time: String = "2026-10-10T16:00:00.000Z") -> String {
            let lastPart = last.map { ",\"last_token_usage\":{\"input_tokens\":\($0.0),\"cached_input_tokens\":\($0.1),\"output_tokens\":\($0.2)}" } ?? ""
            return "{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":"
                + "{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output)}\(lastPart)},\"rate_limits\":\(limits)}}"
        }
        func records(_ found: [UsageFinding]) -> [UsageRecord] {
            found.compactMap { if case .record(let record) = $0 { return record } else { return nil } }
        }

        var state = CodexUsageReader.Carry(thread: "t1")
        let nothing = findings([#"{"timestamp":"2026-10-10T16:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#,
                                "{broken \"token_count\"", #"{"type":"response_item","payload":{"type":"function_call_output","output":"\"token_count\""}}"#],
                               state: &state)
        t.expectEqual(nothing.count, 0, "null info, malformed lines and look-alikes give nothing")

        // Model and folder come from the lines before; repeated totals add nothing.
        let found = records(findings([#"{"type":"session_meta","payload":{"id":"t1","cwd":"/Users/alex/code/acme-api"}}"#,
                                      #"{"type":"turn_context","payload":{"model":"GPT-5.2-Codex","cwd":"/Users/alex/code/acme-api/sub"}}"#,
                                      count(100, 40, 10), count(100, 40, 10), count(250, 140, 30)], state: &state))
        t.expectEqual(found.count, 2)
        t.expectEqual(found.first?.tokens.input, 60)
        t.expectEqual(found.first?.tokens.cacheRead, 40)
        t.expectEqual(found.last?.tokens.input, 50)
        t.expectEqual(found.last?.tokens.cacheRead, 100)
        t.expectEqual(found.last?.tokens.output, 20)
        t.expectEqual(found.last?.model, "gpt-5.2-codex")
        t.expectEqual(found.last?.project, "sub")
        t.expect(found.first?.key != found.last?.key)

        // Totals that went backwards: only the last response is counted, and counting goes on from there.
        let rolledBack = records(findings([count(120, 60, 12, last: (20, 5, 2)), count(150, 70, 15)], state: &state))
        t.expectEqual(rolledBack.map(\.tokens.output), [2, 3])
        t.expectEqual(rolledBack.first?.tokens.input, 15)
        // Backwards without a last response: nothing to count.
        t.expectEqual(records(findings([count(10, 0, 1)], state: &state)).count, 0)

        // A file whose first totals already include earlier usage (a resumed or forked thread).
        var resumed = CodexUsageReader.Carry(thread: "t2")
        let first = records(findings([count(5_000, 4_000, 500, last: (300, 200, 30))], state: &resumed))
        t.expectEqual(first.first?.tokens.total, 330, "only the response in this file is counted")
        // A fork that repeats its parent's lines is keyed by the parent.
        var parent = CodexUsageReader.Carry(thread: "parent")
        var fork = CodexUsageReader.Carry(thread: "child")
        let original = records(findings([count(100, 40, 10)], state: &parent))
        let copied = records(findings([#"{"type":"session_meta","payload":{"id":"child","forked_from_id":"parent"}}"#, count(100, 40, 10)], state: &fork))
        t.expectEqual(original.first?.key, copied.first?.key)
        t.expectEqual(copied.first?.session, "child")

        // Rate limits: the old "resets in N seconds" form, a window without a length, an extra limit, an unknown plan.
        let old = try t.unwrap(CodexUsageReader.limitReport(["primary": ["used_percent": 150.0, "window_minutes": 300, "resets_in_seconds": 600],
                                                             "secondary": ["used_percent": 2, "resets_at": NSNull()],
                                                             "plan_type": "unknown"], timestampMs: 1_000_000))
        t.expectEqual(old.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_600))
        t.expectEqual(old.windows.first?.usedPercent, 100, "percentages are kept within 0...100")
        t.expectEqual(old.windows.last?.label, "Secondary limit")
        t.expectNil(old.windows.last?.resetsAt)
        t.expectNil(old.planName)
        let other = try t.unwrap(CodexUsageReader.limitReport(["limit_id": "codex_other", "limit_name": "Spark",
                                                               "primary": ["used_percent": 5, "window_minutes": 1440]], timestampMs: 0))
        t.expectEqual(other.windows.first?.id, "codex_other:primary")
        t.expectEqual(other.windows.first?.label, "Spark: Daily limit")
        t.expectNil(CodexUsageReader.limitReport(["primary": NSNull(), "secondary": "?"], timestampMs: 0))
        t.expectEqual(CodexUsageReader.planName("edu_plus"), "Edu Plus")
        t.expectEqual(CodexUsageReader.label(forMinutes: 10_080), "Weekly limit")
        t.expectEqual(CodexUsageReader.label(forMinutes: 180), "3-hour limit")
        t.expectEqual(CodexUsageReader.label(forMinutes: 45), "45-minute limit")
        t.expectEqual(CodexUsageReader.threadID(fromFileName: rollout), thread)
        t.expectNil(CodexUsageReader.threadID(fromFileName: "rollout-short.jsonl"))
    }

    t.test("an agent that is not installed is skipped silently") {
        let empty = folder("no-agents")
        let ledger = try memoryLedger(t)
        t.expectEqual(UsageScanner.scan(CodexUsageReader(home: empty.appendingPathComponent(".codex")), into: ledger).filesFound, 0)
        t.expectEqual(UsageScanner.scan(GeminiUsageReader(home: empty.appendingPathComponent(".gemini")), into: ledger).filesFound, 0)
        t.expectEqual(try ledger.buckets().count, 0)
        let locations = UsageLocations(claudeProjectsDirs: [empty.appendingPathComponent("projects")], codexHomes: [empty], geminiHome: empty, dataDir: empty)
        t.expect(locations.installedAgents().isEmpty)
        t.expectEqual(locations.readers(for: [.claude, .codex, .gemini, .antigravity]).map(\.agent), [.claude, .codex, .gemini])
        t.expectEqual(locations.readers(for: [.codex]).map(\.agent), [.codex])
    }
}

private func geminiTests(_ t: TestRunner, folder: (String) -> URL) {
    t.test("Gemini CLI session file: tokens per reply, last copy of a reply wins") {
        let home = folder("gemini")
        let hash = "9a3f6c0d5e7b1a2c4d6e8f00112233445566778899aabbccddeeff0011223344"
        let file = home.appendingPathComponent("tmp/\(hash)/chats/session-2026-10-12T04-40-5f0c1d1e.jsonl")
        copy(TestRunner.fixture("antigravity/gemini-cli/session/session.synth.jsonl"), to: file)
        write("{}", to: home.appendingPathComponent("tmp/\(hash)/logs.json"))
        let ledger = try memoryLedger(t)
        let report = UsageScanner.scan(GeminiUsageReader(home: home), into: ledger)
        t.expectEqual(report.filesFound, 1)
        let totals = total(ledger, .gemini)
        t.expectEqual(totals.messages, 2)
        t.expectEqual(totals.input, (12_840 - 9_100) + (13_950 - 12_800))
        t.expectEqual(totals.cacheRead, 9_100 + 12_800)
        t.expectEqual(totals.output, 212 + 388 + 64 + 120, "thinking tokens count as output")
        t.expectEqual(totals.total, 13_440 + 14_134, "equals the files' own totals")
        t.expectEqual(Array(try ledger.totals(by: .session).keys), ["5f0c1d1e-6a0b-4b53-8f58-0d5a8c2c9f01"])
        t.expectEqual(Array(try ledger.totals(by: .project).keys), ["9a3f6c0d"], "a hash-named project folder is shortened")
        t.expectEqual(Array(try ledger.totals(by: .model).keys), ["gemini-3-pro-preview"])

        // The same reply written again with more tokens replaces the first copy.
        append(#"{"id":"m-0003","timestamp":"2026-10-12T04:41:31.000Z","type":"gemini","content":"","model":"gemini-3-pro-preview","tokens":{"input":13950,"output":100,"cached":12800,"thoughts":120,"tool":10,"total":14180}}"# + "\n", to: file)
        UsageScanner.scan(GeminiUsageReader(home: home), into: ledger)
        t.expectEqual(total(ledger, .gemini).messages, 2)
        t.expectEqual(total(ledger, .gemini).output, 212 + 388 + 100 + 120)
        t.expectEqual(total(ledger, .gemini).input, (12_840 - 9_100) + (13_950 - 12_800) + 10, "tool tokens are prompt tokens")
        t.expectEqual(GeminiUsageReader.projectName("my-app"), "my-app")
    }
}

// MARK: Limits

private func limitTests(_ t: TestRunner) {
    let noon = date("2026-10-11T19:00:00Z")
    func window(_ id: String, _ percent: Double, resetsIn seconds: TimeInterval?, label: String? = nil) -> RateWindow {
        RateWindow(id: id, label: label ?? id, usedPercent: percent, resetsAt: seconds.map { noon.addingTimeInterval($0) })
    }
    func report(_ windows: [RateWindow], at offset: TimeInterval = 0, plan: String? = nil, agent: AgentKind = .claude) -> LimitReport {
        LimitReport(agent: agent, windows: windows, planName: plan, capturedAt: noon.addingTimeInterval(offset))
    }

    t.test("the freshest window wins, window by window") {
        var book = LimitBook()
        t.expect(book.windows(for: .claude, at: noon).isEmpty)
        t.expect(book.merge(report([window("7d", 8, resetsIn: 86_400), window("5h", 24, resetsIn: 3600)])))
        t.expectEqual(book.windows(for: .claude, at: noon).map(\.id), ["5h", "7d"], "5-hour first, then weekly")
        t.expect(!book.merge(report([window("7d", 8, resetsIn: 86_400), window("5h", 24, resetsIn: 3600)])), "the same numbers again change nothing")
        // A report with only one window updates that one and keeps the other.
        t.expect(book.merge(report([window("5h", 31, resetsIn: 3600)], at: 60)))
        t.expectEqual(book.windows(for: .claude, at: noon).map(\.usedPercent), [31, 8])
        // An older report (read late from a file) never overwrites a newer one.
        t.expect(!book.merge(report([window("5h", 2, resetsIn: 3600)], at: 30)))
        t.expectEqual(book.windows(for: .claude, at: noon).first?.usedPercent, 31)
        t.expectEqual(book.lastUpdate(for: .claude), noon.addingTimeInterval(60))
        t.expect(book.windows(for: .codex, at: noon).isEmpty, "agents are kept apart")
        t.expectNil(book.lastUpdate(for: .codex))
        t.expect(!book.merge(report([])), "an empty report changes nothing")
    }

    t.test("a window whose reset time has passed shows 0% and no reset time") {
        var book = LimitBook()
        book.merge(report([window("5h", 88, resetsIn: 3600, label: "5-hour limit"), window("7d", 40, resetsIn: 86_400, label: "Weekly limit")]))
        let before = book.windows(for: .claude, at: noon.addingTimeInterval(3599))
        t.expectEqual(before.first?.usedPercent, 88)
        t.expect(book.expiredLabels(for: .claude, at: noon.addingTimeInterval(3599)).isEmpty)
        let after = book.windows(for: .claude, at: noon.addingTimeInterval(3600))
        t.expectEqual(after.first?.usedPercent, 0, "not the stale 88%")
        t.expectNil(after.first?.resetsAt)
        t.expectEqual(after.last?.usedPercent, 40, "the weekly window is still current")
        t.expectEqual(book.expiredLabels(for: .claude, at: noon.addingTimeInterval(3600)), ["5-hour limit"])
        // A fresh report brings it back.
        book.merge(report([window("5h", 3, resetsIn: 3600 + 18_000)], at: 3700))
        t.expectEqual(book.windows(for: .claude, at: noon.addingTimeInterval(3700)).first?.usedPercent, 3)
        // A window without a reset time never expires by itself.
        book.merge(report([window("spend", 62.8, resetsIn: nil)], at: 3700))
        t.expectEqual(book.windows(for: .claude, at: noon.addingTimeInterval(10_000_000)).first { $0.id == "spend" }?.usedPercent, 62.8)
    }

    t.test("odd input is cleaned up; order, plan names and saving work") {
        var book = LimitBook()
        book.merge(report([window("zeta", 1, resetsIn: 60), window("", 5, resetsIn: 60), window("secondary", 250, resetsIn: 60),
                           window("nan", .nan, resetsIn: 60), window("primary", -4, resetsIn: 60), window("alpha", 2, resetsIn: 60)],
                          plan: "Plus", agent: .codex))
        let windows = book.windows(for: .codex, at: noon)
        t.expectEqual(windows.map(\.id), ["primary", "secondary", "zeta", "alpha"], "known windows first, others in arrival order")
        t.expectEqual(windows.map(\.usedPercent), [0, 100, 1, 2], "percentages are kept within 0...100")
        t.expectEqual(book.planName(for: .codex), "Plus")
        book.merge(report([], at: 10, plan: nil, agent: .codex))
        t.expectEqual(book.planName(for: .codex), "Plus", "a report without a plan keeps the last known one")
        book.merge(report([], at: 20, plan: "Pro", agent: .codex))
        t.expectEqual(book.planName(for: .codex), "Pro")
        book.merge(report([], at: 5, plan: "Old", agent: .codex))
        t.expectEqual(book.planName(for: .codex), "Pro", "an older plan name does not come back")
        t.expect(book.windows(for: .claude, at: noon).isEmpty && book.planName(for: .claude) == nil)

        let data = try JSONEncoder().encode(book)
        t.expectEqual(try JSONDecoder().decode(LimitBook.self, from: data), book, "limits survive saving and loading")
    }

    t.test("a warning is due once per window and period") {
        var book = LimitBook()
        book.merge(report([window("5h", 79, resetsIn: 3600), window("7d", 82, resetsIn: 86_400)]))
        t.expectEqual(book.windowsNeedingWarning(for: .claude, threshold: 80, at: noon).map(\.id), ["7d"])
        t.expect(book.windowsNeedingWarning(for: .claude, threshold: 80, at: noon).isEmpty, "not twice")
        book.merge(report([window("5h", 85, resetsIn: 3601), window("7d", 90, resetsIn: 86_402)], at: 60))
        t.expectEqual(book.windowsNeedingWarning(for: .claude, threshold: 80, at: noon).map(\.id), ["5h"],
                      "the weekly window was already warned about, even though its reset time wobbled")
        // A new period (reset five hours later) warns again; an expired window never does.
        book.merge(report([window("5h", 95, resetsIn: 3600 + 18_000)], at: 4000))
        t.expectEqual(book.windowsNeedingWarning(for: .claude, threshold: 80, at: noon.addingTimeInterval(4000)).map(\.id), ["5h"])
        t.expect(book.windowsNeedingWarning(for: .claude, threshold: 80, at: noon.addingTimeInterval(900_000)).isEmpty)
        t.expect(book.windowsNeedingWarning(for: .gemini, threshold: 80, at: noon).isEmpty)
    }
}

// MARK: Activity

private func activityTests(_ t: TestRunner) {
    let zone = LocalDays(timeZone: losAngeles)

    t.test("a working day is tallied: sessions, turns, tools, decisions, active time, longest task") {
        var tracker = ActivityTracker()
        let clock = TestClock("2026-10-11T17:00:00Z")          // 10:00 in Los Angeles
        func feed(_ kind: AgentEvent, session: String = "s1", after seconds: TimeInterval = 0) {
            clock.advance(seconds)
            tracker.observe(event(kind, session: session), at: clock.now, in: zone)
        }
        feed(.sessionStarted(title: nil, model: nil, source: "startup"))
        feed(.promptSubmitted(text: "go"), after: 60)                 // idle minute: not active
        feed(.toolStarted(tool()), after: 30)
        feed(.toolFinished(id: nil, name: "Bash", succeeded: true), after: 10)
        feed(.toolStarted(tool("Edit")), after: 5)
        feed(.permissionRequested(PermissionRequest(toolName: "Edit", summary: "Edit a file", detail: "a.swift")), after: 5)
        // 50 s of work so far. Two minutes pass while the agent waits for the user: not active.
        clock.advance(120)
        tracker.recordDecision(.allow, for: permission(), at: clock.now, in: zone)
        feed(.toolFinished(id: nil, name: "Edit", succeeded: true), after: 20)
        feed(.questionAsked(QuestionRequest(questions: [])), after: 10)
        clock.advance(40)
        tracker.recordDecision(.answer(["q": "a"]), for: PendingRequest(sessionID: "claude:s1", agent: .claude,
                                                                        kind: .question(QuestionRequest(questions: [])), createdAt: clock.now, raw: .null),
                               at: clock.now, in: zone)
        feed(.turnFinished(lastMessage: "done", backgroundWork: false), after: 15)
        feed(.usageUpdated(contextPercent: 10, windows: [], model: nil, costUSD: nil), after: 300)
        feed(.sessionEnded(reason: "exit"), after: 10)

        let day = try t.unwrap(tracker.recentDays(at: clock.now, in: zone).last)
        t.expectEqual(day.day, "2026-10-11")
        t.expectEqual(day.sessionsStarted, 1)
        t.expectEqual(day.turnsFinished, 1)
        t.expectEqual(day.toolCalls, 2)
        t.expectEqual(day.approvalsHandled, 1)
        t.expectEqual(day.questionsAnswered, 1)
        t.expectEqual(day.activeSeconds, 50 + 20 + 10 + 15, "busy stretches only; waiting for the user and idling are left out")
        t.expectEqual(day.longestTaskSeconds, 30 + 10 + 5 + 5 + 120 + 20 + 10 + 40 + 15, "from the prompt to the end of the turn")
        t.expectEqual(day.peakConcurrent, 1)
        t.expectEqual(tracker.busyCount, 0)
        t.expectEqual(tracker.recentDays(at: clock.now, in: zone).count, 1)
    }

    t.test("several sessions: peak, overlap counted once, failures, plans, hand-offs") {
        var tracker = ActivityTracker()
        let clock = TestClock("2026-10-11T17:00:00Z")
        func feed(_ kind: AgentEvent, session: String, agent: AgentKind = .claude, after seconds: TimeInterval = 0) {
            clock.advance(seconds)
            tracker.observe(event(kind, agent, session: session), at: clock.now, in: zone)
        }
        feed(.promptSubmitted(text: "a"), session: "a")                    // no sessionStarted seen: not counted as started
        feed(.promptSubmitted(text: "b"), session: "b", agent: .codex, after: 10)
        feed(.promptSubmitted(text: "c"), session: "c", after: 10)
        t.expectEqual(tracker.busyCount, 3)
        feed(.turnFailed(error: "rate limit"), session: "a", after: 10)    // a: 30 s task
        feed(.turnFinished(lastMessage: nil, backgroundWork: true), session: "b", after: 10)    // still busy
        t.expectEqual(tracker.busyCount, 2)
        feed(.planProposed(PlanRequest(markdown: "# plan")), session: "c", after: 10)
        clock.advance(100)                                                // b is still working in the background
        tracker.recordDecision(.passToTerminal, for: permission(session: "c"), at: clock.now, in: zone)
        tracker.recordDecision(.rejectPlan(feedback: "no"), for: PendingRequest(sessionID: "claude:c", agent: .claude,
                                                                                kind: .plan(PlanRequest(markdown: "# plan")), createdAt: clock.now, raw: .null),
                               at: clock.now, in: zone)
        feed(.turnFinished(lastMessage: nil, backgroundWork: false), session: "b", agent: .codex, after: 10)
        feed(.turnFinished(lastMessage: nil, backgroundWork: false), session: "c", after: 10)
        feed(.sessionStarted(title: nil, model: nil, source: "compact"), session: "c")
        feed(.sessionStarted(title: nil, model: nil, source: "resume"), session: "new")
        feed(.notification(kind: "idle_prompt", message: "waiting"), session: "c")

        let day = try t.unwrap(tracker.recentDays(at: clock.now, in: zone).last)
        t.expectEqual(day.peakConcurrent, 3)
        t.expectEqual(day.sessionsStarted, 1, "only the session whose start was seen; a compaction is not a start")
        t.expectEqual(day.turnsFinished, 3, "the background turn, then b and c")
        t.expectEqual(day.approvalsHandled, 1, "the rejected plan; the hand-off to the terminal is not counted")
        t.expectEqual(day.activeSeconds, 170, "overlapping work is counted once")
        t.expectEqual(day.longestTaskSeconds, 150, "session b, from its prompt to its final turn end")
        t.expectEqual(tracker.busyCount, 0)
    }

    t.test("active time is split at local midnight and stops after 30 silent minutes") {
        var tracker = ActivityTracker()
        let clock = TestClock("2026-10-12T06:50:00Z")           // 23:50 on the 11th in Los Angeles
        tracker.observe(event(.promptSubmitted(text: "late"), session: "night"), at: clock.now, in: zone)
        clock.advance(20 * 60)                                  // 00:10 on the 12th
        tracker.observe(event(.toolStarted(tool()), session: "night"), at: clock.now, in: zone)
        var days = tracker.recentDays(at: clock.now, in: zone)
        t.expectEqual(days.map(\.day), ["2026-10-11", "2026-10-12"])
        t.expectEqual(days.first?.activeSeconds, 600)
        t.expectEqual(days.last?.activeSeconds, 600)
        t.expectEqual(days.last?.peakConcurrent, 1, "a session still busy at midnight counts for the new day")
        t.expectEqual(days.last?.toolCalls, 1)

        // No more events (the "finished" event was lost): only 30 more minutes are believed.
        clock.advance(5 * 3600)
        tracker.advance(to: clock.now, in: zone)
        days = tracker.recentDays(at: clock.now, in: zone)
        t.expectEqual(days.last?.activeSeconds, 600 + 1800)
        t.expectEqual(tracker.busyCount, 0)
        let revision = tracker.revision
        clock.advance(3600)
        tracker.advance(to: clock.now, in: zone)
        t.expectEqual(tracker.revision, revision, "nothing changes while nobody is busy")
        // A late "finished" event after the session went quiet records the turn but no absurd task length.
        tracker.observe(event(.turnFinished(lastMessage: nil, backgroundWork: false), session: "night"), at: clock.now, in: zone)
        t.expectEqual(tracker.recentDays(at: clock.now, in: zone).last?.longestTaskSeconds, 0)
        t.expectEqual(tracker.recentDays(at: clock.now, in: zone).last?.turnsFinished, 1)
    }

    t.test("saved days come back, gaps are filled, and only 90 days are kept") {
        let saved = [DailyActivity(day: "2026-07-01", activeSeconds: 5), DailyActivity(day: "2026-10-08", activeSeconds: 100, toolCalls: 4),
                     DailyActivity(day: "2026-10-10", activeSeconds: 50, peakConcurrent: 2)]
        var tracker = ActivityTracker(saved: saved)
        let now = date("2026-10-11T19:00:00Z")
        let days = tracker.recentDays(at: now, in: zone)
        t.expectEqual(days.map(\.day), ["2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11"])
        t.expectEqual(days[1], DailyActivity(day: "2026-10-09"), "a day without activity is listed as zero")
        t.expectEqual(days.first?.toolCalls, 4)
        t.expectEqual(tracker.daysToSave(at: now, in: zone).map(\.day), ["2026-10-08", "2026-10-10"], "the day from July is too old to keep")
        // New activity today is added to what was saved.
        tracker.observe(event(.toolStarted(tool())), at: now, in: zone)
        tracker.observe(event(.toolStarted(tool())), at: now.addingTimeInterval(86_400), in: zone)
        t.expectEqual(tracker.daysToSave(at: now.addingTimeInterval(86_400), in: zone).map(\.day), ["2026-10-08", "2026-10-10", "2026-10-11", "2026-10-12"])
        let afterwards = tracker.recentDays(at: now.addingTimeInterval(86_400), in: zone)
        t.expectEqual(afterwards.first { $0.day == "2026-10-11" }?.activeSeconds, 1800, "a tool that never finished is believed for 30 minutes")
        t.expectEqual(afterwards.last?.activeSeconds, 0)
        t.expectEqual(afterwards.first { $0.day == "2026-10-10" }?.activeSeconds, 50, "saved numbers are kept")
        t.expect(ActivityTracker().recentDays(at: now, in: zone).isEmpty)
        tracker.forgetLiveSessions()
        t.expectEqual(tracker.busyCount, 0)
    }
}

// MARK: The engine

private func engineTests(_ t: TestRunner, fixtures: URL, expected: JSONValue, folder: (String) -> URL) {
    let projects = fixtures.appendingPathComponent("projects")
    let rollout = "rollout-2026-10-10T09-15-02-019a9d1e-6c2a-7b30-9f4e-2d1c8a5b7e10.jsonl"

    t.test("refreshNow fills the store with the fixtures' exact totals, on the main thread") {
        let root = folder("engine")
        let codexHome = root.appendingPathComponent("codex")
        copy(TestRunner.fixture("codex/rollout/\(rollout)"), to: codexHome.appendingPathComponent("sessions/2026/10/10/\(rollout)"))
        let store = UsageStore()
        let clock = TestClock("2026-10-12T03:00:00Z")          // 20:00 on the 11th in Los Angeles
        let engine = UsageEngine(store: store, settings: makeSettings(), claudeProjectsDir: projects, codexHome: codexHome,
                                 geminiHome: root.appendingPathComponent("no-gemini"), dataDir: root.appendingPathComponent("data"),
                                 clock: { clock.now }, timeZone: losAngeles, fileAge: { _ in 0 })
        var offMainChanges = 0
        var sawRefreshing = false
        var refreshCount = 0
        var watchers = Set<AnyCancellable>()
        store.objectWillChange.sink { if !Thread.isMainThread { offMainChanges += 1 } }.store(in: &watchers)
        store.$isRefreshing.sink { if $0 { sawRefreshing = true } }.store(in: &watchers)
        store.$lastRefresh.dropFirst().sink { _ in refreshCount += 1 }.store(in: &watchers)

        t.expect(store.usage.isEmpty && !store.isRefreshing && store.lastRefresh == nil)
        // Several requests at once are folded together: one scan now, at most one follow-up.
        for _ in 0..<6 { engine.refreshNow() }
        t.expect(store.isRefreshing, "refreshing is flagged at once")
        waitForRefresh(t, store)
        t.wait(1) { false }
        t.expect(sawRefreshing)
        t.expect(refreshCount >= 1 && refreshCount <= 2, "6 requests ran \(refreshCount) scans")
        t.expectEqual(offMainChanges, 0, "the store is only changed on the main thread")
        t.expectEqual(store.lastRefresh, clock.now)

        let claude = try t.unwrap(store.usage[.claude])
        checkTotals(t, claude.allTime, expected["allTime"], "store all time")
        let wantDays = expected["days"]["America/Los_Angeles"]
        checkTotals(t, claude.today, wantDays["2026-10-11"]["totals"], "store today")
        t.expectEqual(claude.days.map(\.day), ["2026-10-09", "2026-10-10", "2026-10-11"])
        for day in claude.days { checkTotals(t, day.totals, wantDays[day.day]["totals"], "store \(day.day)") }
        t.expectEqual(claude.days.last?.byProject.keys.sorted(), ["beta site"])
        t.expectEqual(claude.days[1].byModel.keys.sorted(), ["claude-haiku-5-5", "claude-opus-5-5", "claude-sonnet-5-5"])
        t.expect(claude.windows.isEmpty, "no limits until a status line reports them")
        t.expectNil(claude.planName)
        t.expectEqual(claude.updatedAt, clock.now)
        let note = try t.unwrap(claude.note)
        t.expect(note.contains("estimate at API list prices"), "the note says cost is an estimate")
        t.expect(note.contains("transcripts on this Mac"))
        t.expect(note.contains("once Claude Code's status line reports them"))
        t.expect(note.contains("claude-next-9"), "the model without a price is named")

        let codex = try t.unwrap(store.usage[.codex])
        t.expectEqual(codex.allTime.total, 37_321)
        t.expectEqual(codex.allTime.messages, 3)
        t.expectEqual(codex.allTime.costUSD, 0)
        t.expectEqual(codex.days.map(\.day), ["2026-10-10", "2026-10-11"])
        t.expectEqual(codex.planName, "Plus")
        t.expectEqual(codex.windows.map(\.id), ["primary", "secondary"])
        t.expectEqual(codex.windows.first?.usedPercent, 0, "its 5-hour window ended before 'now', so the stale 13% is not shown")
        t.expectNil(codex.windows.first?.resetsAt)
        t.expectEqual(codex.windows.last?.usedPercent, 31.5)
        t.expect(codex.note?.contains("No cost is estimated") == true)
        t.expect(codex.note?.contains("5-hour limit has reset") == true)
        t.expect(store.usage[.gemini] == nil && store.usage[.antigravity] == nil, "agents that are not installed are not listed")

        // A new day: the heartbeat notices and "today" starts again at zero.
        clock.advance(5 * 3600)
        store.lastRefresh = nil
        engine.heartbeat()
        waitForRefresh(t, store)
        t.expectEqual(store.usage[.claude]?.today.messages, 0)
        t.expectEqual(store.usage[.claude]?.days.map(\.day), ["2026-10-09", "2026-10-10", "2026-10-11", "2026-10-12"])
        t.expect(approx(store.usage[.claude]?.allTime.costUSD ?? 0, expected["allTime"]["costUSD"].doubleValue ?? -1))
        t.expectEqual(offMainChanges, 0)
    }

    t.test("status line payloads from the fixtures become the store's windows") {
        let root = folder("engine-statusline")
        let store = UsageStore()
        let clock = TestClock("2026-10-10T07:00:00Z")
        let engine = UsageEngine(store: store, settings: makeSettings(), claudeProjectsDir: nil, codexHome: nil,
                                 dataDir: root.appendingPathComponent("data"), clock: { clock.now }, timeZone: losAngeles)
        func send(_ name: String) -> JSONValue {
            let payload = JSONValue.parse(TestRunner.fixtureText("claude/usage/statusline/\(name)")) ?? .null
            engine.observe(usageEvent(session: payload["session_id"].stringValue ?? "?", windows: statusLineWindows(payload),
                                      context: payload["context_window"]["used_percentage"].doubleValue,
                                      model: payload["model"]["id"].stringValue, cost: payload["cost"]["total_cost_usd"].doubleValue,
                                      at: clock.now))
            return expected["statusline"][name]
        }
        func check(_ name: String, _ want: JSONValue, ids: [String]) {
            let windows = store.usage[.claude]?.windows ?? []
            t.expectEqual(windows.map(\.id), ids, "\(name) windows")
            for item in want["windows"].arrayValue ?? [] {
                let window = windows.first { $0.id == item["id"].stringValue }
                t.expectEqual(window?.label, item["label"].stringValue, "\(name) label")
                t.expectEqual(window?.usedPercent, item["usedPercent"].doubleValue, "\(name) percent")
                t.expectEqual(window?.resetsAt, item["resetsAtEpoch"].doubleValue.map { Date(timeIntervalSince1970: $0) }, "\(name) reset time")
            }
        }

        _ = send("first-render.json")
        t.expect(store.usage[.claude] == nil, "a payload without limits shows nothing")
        t.expectEqual(engine.latestReading(agent: .claude, sessionID: "22222222-2222-4222-8222-222222222222")?.model, "claude-sonnet-5-5")
        t.expectNil(engine.latestReading(agent: .claude, sessionID: "22222222-2222-4222-8222-222222222222")?.contextPercent)

        check("limits-before-context.json", send("limits-before-context.json"), ids: ["5h", "7d"])
        t.expectEqual(store.usage[.claude]?.updatedAt, clock.now)
        t.expect(store.usage[.claude]?.note?.contains("Limits come from Claude Code's status line and were last updated today at") == true)

        clock.advance(30)
        check("fractional-percentages.json", send("fractional-percentages.json"), ids: ["5h", "7d"])
        t.expectEqual(store.usage[.claude]?.windows.first?.usedPercent, 23.5)
        t.expectEqual(store.usage[.claude]?.updatedAt, clock.now)
        let reading = engine.latestReading(agent: .claude, sessionID: "11111111-1111-4111-8111-111111111111")
        t.expectEqual(reading?.model, "claude-opus-5-5")
        t.expect(reading?.contextPercent != nil)
        t.expectEqual(reading?.costUSD, 0.4321)
        t.expectEqual(reading?.updatedAt, clock.now)

        // Only the weekly window arrives: the 5-hour window is kept, not dropped.
        clock.advance(30)
        check("weekly-only.json", send("weekly-only.json"), ids: ["5h", "7d"])
        t.expectEqual(store.usage[.claude]?.windows.first?.usedPercent, 23.5)
        t.expectEqual(store.usage[.claude]?.windows.last?.usedPercent, 100)

        clock.advance(30)
        check("gateway-spend-limit.json", send("gateway-spend-limit.json"), ids: ["5h", "7d", "spend"])
        _ = send("api-key-user.json")
        t.expectEqual(store.usage[.claude]?.windows.count, 3, "a payload without limits leaves the known ones alone")
        let contextBefore = engine.latestReading(agent: .claude, sessionID: "11111111-1111-4111-8111-111111111111")?.contextPercent
        _ = send("after-compact-documented.json")
        t.expect(contextBefore != nil)
        t.expectEqual(engine.latestReading(agent: .claude, sessionID: "11111111-1111-4111-8111-111111111111")?.contextPercent, contextBefore,
                      "an unknown context right after a compaction keeps the last known value")

        // The 5-hour window passes its reset time (1791670200): 0% and no reset time, not the stale number.
        clock.now = Date(timeIntervalSince1970: 1_791_670_200 + 1)
        engine.heartbeat()
        let fiveHour = store.usage[.claude]?.windows.first
        t.expectEqual(fiveHour?.usedPercent, 0)
        t.expectNil(fiveHour?.resetsAt)
        t.expectEqual(store.usage[.claude]?.windows.last?.usedPercent, 62.8)
        t.expect(store.usage[.claude]?.note?.contains("The 5-hour limit has reset since then") == true)

        // The session ends: its reading is dropped, the account-wide limits stay.
        engine.observe(event(.sessionEnded(reason: nil), session: "11111111-1111-4111-8111-111111111111"))
        t.expectNil(engine.latestReading(agent: .claude, sessionID: "11111111-1111-4111-8111-111111111111"))
        t.expectEqual(store.usage[.claude]?.windows.count, 3)

        // Limits survive a restart: a new engine on the same data folder shows them before any event.
        engine.flush()
        let secondStore = UsageStore()
        let second = UsageEngine(store: secondStore, settings: makeSettings(), claudeProjectsDir: nil, codexHome: nil,
                                 dataDir: root.appendingPathComponent("data"), clock: { clock.now }, timeZone: losAngeles)
        second.refreshNow()
        waitForRefresh(t, secondStore)
        t.expectEqual(secondStore.usage[.claude]?.windows.map(\.id), ["5h", "7d", "spend"])
        t.expectEqual(secondStore.usage[.claude]?.windows.last?.usedPercent, 62.8)
    }

    t.test("limit warnings fire once per period and follow the settings") {
        let root = folder("engine-warnings")
        let store = UsageStore()
        let settings = makeSettings()
        let clock = TestClock("2026-10-11T19:00:00Z")
        let engine = UsageEngine(store: store, settings: settings, claudeProjectsDir: nil, codexHome: nil,
                                 dataDir: root.appendingPathComponent("data"), clock: { clock.now }, timeZone: losAngeles)
        var warned: [String] = []
        engine.onLimitWarning = { agent, window in warned.append("\(agent.rawValue):\(window.id):\(Int(window.usedPercent))") }
        func send(_ percent: Double, weekly: Double = 10, agent: AgentKind = .claude) {
            clock.advance(10)
            engine.observe(usageEvent(agent, windows: [RateWindow(id: "5h", label: "5-hour limit", usedPercent: percent,
                                                                  resetsAt: date("2026-10-11T22:00:00Z")),
                                                       RateWindow(id: "7d", label: "Weekly limit", usedPercent: weekly,
                                                                  resetsAt: date("2026-10-15T00:00:00Z"))]))
        }
        send(79)
        t.expect(warned.isEmpty)
        t.expect(store.usage[.claude]?.note?.contains("Heads-up") == false)
        send(81)
        t.expectEqual(warned, ["claude:5h:81"])
        t.expect(store.usage[.claude]?.note?.hasPrefix("Heads-up: the 5-hour limit is at 81%.") == true)
        send(86)
        t.expectEqual(warned.count, 1, "one warning per period, not one per update")
        settings.warnAtPercent = 50
        send(87, weekly: 55)
        t.expectEqual(warned, ["claude:5h:81", "claude:7d:55"])
        settings.usageWarnings = false
        send(99, weekly: 99, agent: .codex)
        t.expectEqual(warned.count, 2, "warnings switched off")
        t.expect(store.usage[.codex]?.note?.contains("Heads-up") == false)
        t.expectEqual(store.usage[.codex]?.windows.first?.usedPercent, 99, "the numbers are still shown")

        // A disabled agent is ignored and not listed.
        settings.codexEnabled = false
        send(50, agent: .codex)
        engine.heartbeat()
        t.expect(store.usage[.codex] == nil)
        t.expect(store.usage[.claude] != nil)
    }

    t.test("activity stats through the engine: collected, saved, restored, switched off") {
        let root = folder("engine-activity")
        let dataDir = root.appendingPathComponent("data")
        let store = UsageStore()
        let settings = makeSettings()
        let clock = TestClock("2026-10-11T17:00:00Z")
        let engine = UsageEngine(store: store, settings: settings, claudeProjectsDir: nil, codexHome: nil, dataDir: dataDir,
                                 clock: { clock.now }, timeZone: losAngeles)
        engine.observe(event(.sessionStarted(title: nil, model: nil, source: "startup")))
        engine.observe(event(.promptSubmitted(text: "go")))
        clock.advance(40)
        engine.observe(event(.toolStarted(tool())))
        engine.observe(event(.permissionRequested(PermissionRequest(toolName: "Bash", summary: "Run", detail: "ls"))))
        clock.advance(100)
        engine.recordDecision(.deny(message: "no"), for: permission())
        clock.advance(20)
        engine.heartbeat()                                           // time passes without events
        t.expectEqual(store.activityDays.last?.activeSeconds, 60)
        clock.advance(20)
        engine.observe(event(.turnFinished(lastMessage: "ok", backgroundWork: false)))
        let today = try t.unwrap(store.activityDays.last)
        t.expectEqual(store.activityDays.count, 1)
        t.expectEqual(today, DailyActivity(day: "2026-10-11", activeSeconds: 80, sessionsStarted: 1, turnsFinished: 1, toolCalls: 1,
                                           approvalsHandled: 1, questionsAnswered: 0, longestTaskSeconds: 180, peakConcurrent: 1))

        // Round trip through the file.
        engine.flush()
        let activityFile = dataDir.appendingPathComponent("activity-stats.json")
        let saved = JSONValue.parse((try? String(contentsOf: activityFile, encoding: .utf8)) ?? "") ?? .null
        t.expectEqual(saved["version"].intValue, 1)
        t.expectEqual(saved["days"][0]["day"].stringValue, "2026-10-11")
        t.expectEqual(saved["days"][0]["activeSeconds"].intValue, 80)
        t.expectEqual(saved["days"][0]["longestTaskSeconds"].intValue, 180)

        let secondStore = UsageStore()
        clock.advance(86_400)                                        // the next day
        let second = UsageEngine(store: secondStore, settings: settings, claudeProjectsDir: nil, codexHome: nil, dataDir: dataDir,
                                 clock: { clock.now }, timeZone: losAngeles)
        second.observe(event(.toolStarted(tool()), session: "other"))
        t.expectEqual(secondStore.activityDays.map(\.day), ["2026-10-11", "2026-10-12"])
        t.expectEqual(secondStore.activityDays.first, today, "yesterday came back from the file unchanged")
        t.expectEqual(secondStore.activityDays.last?.toolCalls, 1)

        // A file from a build that knew fewer counters (or more) still loads.
        let older = #"{"days":[{"day":"2026-10-01","toolCalls":7,"somethingNew":3},{"toolCalls":1},{"day":"2026-10-02","activeSeconds":-5}]}"#
        let lenient = try JSONDecoder().decode(SavedActivity.self, from: Data(older.utf8))
        t.expectEqual(lenient.days, [DailyActivity(day: "2026-10-01", toolCalls: 7), DailyActivity(day: "2026-10-02")])

        // Switched off: nothing is collected, not even while sessions run.
        settings.collectActivityStats = false
        let before = secondStore.activityDays
        second.observe(event(.toolStarted(tool()), session: "other"))
        second.observe(event(.turnFinished(lastMessage: nil, backgroundWork: false), session: "other"))
        second.recordDecision(.allow, for: permission(session: "other"))
        clock.advance(600)
        second.heartbeat()
        t.expectEqual(secondStore.activityDays, before)
        // Limits still work with stats off.
        second.observe(usageEvent(windows: [RateWindow(id: "5h", label: "5-hour limit", usedPercent: 5, resetsAt: nil)]))
        t.expectEqual(secondStore.usage[.claude]?.windows.count, 1)
        second.flush()
        let resaved = JSONValue.parse((try? String(contentsOf: activityFile, encoding: .utf8)) ?? "") ?? .null
        t.expectEqual(resaved["days"].arrayValue?.count, 2)
        t.expectEqual(resaved["days"][1]["toolCalls"].intValue, 1)
    }

    t.test("clearSavedStats deletes only Perch's own files and empties the store") {
        let root = folder("engine-clear")
        let dataDir = root.appendingPathComponent("data")
        let claudeCopy = root.appendingPathComponent("claude/projects")
        copy(projects, to: claudeCopy)
        let agentFilesBefore = ClaudeUsageReader(projectsDirs: [claudeCopy]).files().map(\.path).sorted()
        let store = UsageStore()
        let clock = TestClock("2026-10-12T03:00:00Z")
        let engine = UsageEngine(store: store, settings: makeSettings(), claudeProjectsDir: claudeCopy, codexHome: nil, dataDir: dataDir,
                                 clock: { clock.now }, timeZone: losAngeles, fileAge: { _ in 0 })
        engine.refreshNow()
        waitForRefresh(t, store)
        engine.observe(usageEvent(windows: [RateWindow(id: "5h", label: "5-hour limit", usedPercent: 40, resetsAt: nil)]))
        engine.observe(event(.toolStarted(tool())))
        engine.flush()
        let keepsake = dataDir.appendingPathComponent("someone-elses-file.txt")
        write("not ours", to: keepsake)
        let fm = FileManager.default
        t.expect(fm.fileExists(atPath: dataDir.appendingPathComponent("usage.sqlite").path), "the ledger file exists")
        t.expect(fm.fileExists(atPath: dataDir.appendingPathComponent("limits.json").path))
        t.expect(fm.fileExists(atPath: dataDir.appendingPathComponent("activity-stats.json").path))
        t.expectEqual(store.usage[.claude]?.allTime.messages, 18)
        t.expectEqual(store.activityDays.count, 1)

        engine.clearSavedStats()
        t.expect(store.usage.isEmpty, "usage is emptied at once")
        t.expect(store.activityDays.isEmpty)
        t.expectNil(store.lastRefresh)
        engine.flush()
        // The deletions run behind any scan or save in progress; wait for them.
        let deleted = t.wait(10) {
            !fm.fileExists(atPath: dataDir.appendingPathComponent("usage.sqlite").path)
                && !fm.fileExists(atPath: dataDir.appendingPathComponent("limits.json").path)
                && !fm.fileExists(atPath: dataDir.appendingPathComponent("activity-stats.json").path)
        }
        t.expect(deleted, "the ledger, the limits and the activity file are gone")
        t.expectEqual((try? fm.contentsOfDirectory(atPath: dataDir.path))?.sorted(), ["someone-elses-file.txt"],
                      "nothing else in the data folder is touched")
        t.expectEqual(ClaudeUsageReader(projectsDirs: [claudeCopy]).files().map(\.path).sorted(), agentFilesBefore, "the agent's files are untouched")
        t.expectEqual(fm.contents(atPath: agentFilesBefore[0]), fm.contents(atPath: agentFilesBefore[0].replacingOccurrences(of: claudeCopy.path, with: projects.path)))

        // The next refresh starts from nothing and rebuilds what the agent still keeps.
        engine.refreshNow()
        waitForRefresh(t, store)
        checkTotals(t, store.usage[.claude]?.allTime, expected["allTime"], "after clearing and rescanning")
        t.expect(store.usage[.claude]?.windows.isEmpty == true, "the saved limits are gone")
        t.expect(store.activityDays.isEmpty)
    }

    t.test("a damaged ledger file is replaced instead of breaking usage") {
        let root = folder("engine-damaged")
        let dataDir = root.appendingPathComponent("data")
        write("this is not a database, it is a text file that is long enough to look like one page of something", to: dataDir.appendingPathComponent("usage.sqlite"))
        write("{ not json", to: dataDir.appendingPathComponent("limits.json"))
        write("[]", to: dataDir.appendingPathComponent("activity-stats.json"))
        let store = UsageStore()
        let engine = UsageEngine(store: store, settings: makeSettings(), claudeProjectsDir: projects, codexHome: nil, dataDir: dataDir,
                                 clock: { date("2026-10-12T03:00:00Z") }, timeZone: losAngeles, fileAge: { _ in 0 })
        engine.refreshNow()
        waitForRefresh(t, store)
        checkTotals(t, store.usage[.claude]?.allTime, expected["allTime"], "with a damaged ledger file")
        t.expect(store.activityDays.isEmpty)
    }

    t.test("start and stop: first scan, timer follows the setting, extra folders are learned from events") {
        let root = folder("engine-start")
        let dataDir = root.appendingPathComponent("data")
        let store = UsageStore()
        let settings = makeSettings()
        settings.usageRefreshMinutes = 5
        var locations = UsageLocations(claudeProjectsDirs: [], dataDir: dataDir)
        locations.learnsFromEvents = true
        let clock = TestClock("2026-10-12T03:00:00Z")
        let engine = UsageEngine(store: store, settings: settings, locations: locations, clock: { clock.now }, timeZone: losAngeles,
                                 fileAge: { _ in 0 })
        t.expectNil(engine.refreshIntervalSeconds, "no timer before start")
        engine.start()
        engine.start()                                              // starting twice is harmless
        waitForRefresh(t, store)
        t.expect(store.usage.isEmpty, "nothing installed, nothing listed")
        t.expectEqual(engine.refreshIntervalSeconds, 300)
        settings.usageRefreshMinutes = 2
        t.expectEqual(engine.refreshIntervalSeconds, 120, "the timer follows the setting")
        settings.usageRefreshMinutes = 0.1
        t.expectEqual(engine.refreshIntervalSeconds, 60, "never more often than once a minute")
        settings.usageRefreshMinutes = 600
        t.expectEqual(engine.refreshIntervalSeconds, 3600)

        // A hook event reveals that Claude Code keeps its files in a custom folder.
        var context = EventContext(receivedAt: clock.now)
        context.env = ["CLAUDE_CONFIG_DIR": fixtures.path]
        engine.observe(NormalizedEvent(agent: .claude, sessionID: "s1", event: .promptSubmitted(text: "hi"), context: context, rawEventName: "UserPromptSubmit"))
        // ...and that Codex has a custom home.
        let codexHome = root.appendingPathComponent("custom-codex")
        let rollout = "rollout-2026-10-10T09-15-02-019a9d1e-6c2a-7b30-9f4e-2d1c8a5b7e10.jsonl"
        copy(TestRunner.fixture("codex/rollout/\(rollout)"), to: codexHome.appendingPathComponent("sessions/2026/10/10/\(rollout)"))
        context.env = ["CODEX_HOME": codexHome.path]
        for _ in 0..<2 {
            engine.observe(NormalizedEvent(agent: .codex, sessionID: "c1", event: .promptSubmitted(text: "hi"), context: context, rawEventName: "UserPromptSubmit"))
        }
        store.lastRefresh = nil
        engine.refreshNow()
        waitForRefresh(t, store)
        t.expectEqual(store.usage[.claude]?.allTime.messages, 18)
        t.expectEqual(store.usage[.codex]?.allTime.total, 37_321)

        // Hiding cost estimates takes the cost sentences out of the note (the numbers are still computed).
        t.expect(store.usage[.claude]?.note?.contains("Cost is an estimate") == true)
        settings.showCostEstimates = false
        t.expect(t.wait(2) { store.usage[.claude]?.note?.lowercased().contains("cost") == false }, "the note follows the setting")
        t.expect((store.usage[.claude]?.allTime.costUSD ?? 0) > 1.6, "cost is computed either way")
        settings.showCostEstimates = true
        t.expect(t.wait(2) { store.usage[.claude]?.note?.contains("Cost is an estimate") == true })

        // Switching the agent off removes it; switching it on brings it back (both trigger a refresh by themselves).
        store.lastRefresh = nil
        settings.claudeEnabled = false
        waitForRefresh(t, store)
        t.expect(store.usage[.claude] == nil)
        store.lastRefresh = nil
        settings.claudeEnabled = true
        waitForRefresh(t, store)
        t.expectEqual(store.usage[.claude]?.allTime.messages, 18)

        engine.stop()
        t.expectNil(engine.refreshIntervalSeconds, "no timer after stop")
        t.expect(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("activity-stats.json").path), "stop saves what was collected")
        engine.stop()
    }
}

// MARK: Timing

private func timingTest(_ t: TestRunner, folder: (String) -> URL) {
    t.test("a 50 MB transcript is scanned quickly and without loading it into memory") {
        let root = folder("timing")
        let projects = root.appendingPathComponent("projects")
        let file = projects.appendingPathComponent("-Users-test-dev-alpha/\(alphaSession).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        let toolResult = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\""
            + String(repeating: "lorem ipsum ", count: 300) + "\"}]},\"timestamp\":\"2026-10-11T20:00:00.000Z\"}\n"
        var responses = 0
        var written = 0
        var expectedOutput = 0
        let target = 50 * 1024 * 1024
        while written < target {
            var chunk = ""
            for _ in 0..<200 {
                let id = "msg_01T\(responses)"
                let minute = String(format: "%02d", responses % 60), hour = String(format: "%02d", (responses / 60) % 24)
                let time = "2026-10-11T\(hour):\(minute):00.000Z"
                // Three lines per response, as Claude Code writes them: two while streaming, one final.
                chunk += assistantLine(id: id, time: time, output: 8, read: 40_000, final: false, padding: 1200) + "\n"
                chunk += assistantLine(id: id, time: time, output: 8, read: 40_000, final: false, padding: 900) + "\n"
                chunk += toolResult
                chunk += assistantLine(id: id, time: time, output: 500 + responses % 100, read: 40_000, padding: 1500) + "\n"
                expectedOutput += 500 + responses % 100
                responses += 1
            }
            let data = Data(chunk.utf8)
            try handle.write(contentsOf: data)
            written += data.count
        }
        try handle.close()

        let ledger = try t.unwrap(try? UsageLedger(url: root.appendingPathComponent("data/usage.sqlite")))
        var usageBefore = rusage()
        getrusage(RUSAGE_SELF, &usageBefore)
        let started = Date()
        let report = scanClaude(projects, into: ledger)
        let seconds = Date().timeIntervalSince(started)
        var usageAfter = rusage()
        getrusage(RUSAGE_SELF, &usageAfter)
        let megabytes = Double(written) / 1_048_576
        let grownMB = Double(max(0, usageAfter.ru_maxrss - usageBefore.ru_maxrss)) / 1_048_576

        t.expectEqual(report.filesRead, 1)
        t.expectEqual(report.recordsSeen, responses * 3)
        t.expectEqual(total(ledger).messages, responses)
        t.expectEqual(total(ledger).output, expectedOutput)
        t.expect(seconds < 30, "the scan took \(seconds) s")
        t.expect(grownMB < 16, "peak memory grew by \(grownMB) MB for a \(megabytes) MB file")

        let restarted = Date()
        let again = scanClaude(projects, into: ledger)
        let idleSeconds = Date().timeIntervalSince(restarted)
        t.expectEqual(again.filesRead, 0)
        let summaryStarted = Date()
        let buckets = try ledger.buckets()
        let summarySeconds = Date().timeIntervalSince(summaryStarted)
        t.expectEqual(buckets.reduce(0) { $0 + $1.totals.messages }, responses)
        ledger.close()
        print(String(format: "  timing: scanned %.1f MB (%d lines, %d responses) in %.2f s = %.0f MB/s; peak memory +%.1f MB; "
                     + "rescan with nothing new %.4f s; totals query %.3f s",
                     megabytes, responses * 4, responses, seconds, megabytes / seconds, grownMB, idleSeconds, summarySeconds))
    }
}

// MARK: The engine, live behaviour

private func engineLiveTests(_ t: TestRunner, fixtures: URL, folder: (String) -> URL) {
    t.test("a long scan shows partial totals on the way") {
        let root = folder("engine-progress")
        let store = UsageStore()
        let engine = UsageEngine(store: store, settings: makeSettings(), claudeProjectsDir: fixtures.appendingPathComponent("projects"),
                                 codexHome: nil, dataDir: root.appendingPathComponent("data"),
                                 clock: { date("2026-10-12T03:00:00Z") }, timeZone: losAngeles, fileAge: { _ in 0 })
        var seen: [Int] = []
        let watcher = store.$usage.sink { seen.append($0[.claude]?.allTime.messages ?? 0) }
        UsageScanWorker.progressInterval = 0
        defer { UsageScanWorker.progressInterval = 2 }
        engine.refreshNow()
        waitForRefresh(t, store)
        t.wait(0.2) { false }
        watcher.cancel()
        t.expectEqual(seen.last, 18)
        t.expect(seen.filter { $0 > 0 && $0 < 18 }.count >= 1, "partial totals were shown before the final ones: \(seen)")
        t.expect(seen == seen.sorted(), "totals only grow while a scan runs")
    }

    t.test("a finished turn triggers a rescan, but not more than one every 20 seconds") {
        let root = folder("engine-turn")
        let projects = root.appendingPathComponent("claude/projects")
        let transcript = projects.appendingPathComponent("-Users-test-dev-alpha/\(alphaSession).jsonl")
        write(assistantLine(id: "msg_01R1", output: 10) + "\n", to: transcript)
        let store = UsageStore()
        let clock = TestClock("2026-10-12T03:00:00Z")
        let engine = UsageEngine(store: store, settings: makeSettings(), claudeProjectsDir: projects, codexHome: nil,
                                 dataDir: root.appendingPathComponent("data"), clock: { clock.now }, timeZone: losAngeles)
        // Not started: events never start scans by themselves.
        engine.observe(event(.turnFinished(lastMessage: nil, backgroundWork: false)))
        t.wait(0.3) { false }
        t.expect(store.lastRefresh == nil && !store.isRefreshing)

        engine.start()
        waitForRefresh(t, store)
        t.expectEqual(store.usage[.claude]?.allTime.messages, 1)
        t.expectEqual(store.usage[.claude]?.today.output, 10)

        append(assistantLine(id: "msg_01R2", output: 25) + "\n", to: transcript)
        store.lastRefresh = nil
        engine.observe(event(.turnFinished(lastMessage: "done", backgroundWork: false)))
        waitForRefresh(t, store)
        t.expectEqual(store.usage[.claude]?.allTime.messages, 2, "the new response is counted without waiting for the timer")
        t.expectEqual(store.usage[.claude]?.today.output, 35)

        append(assistantLine(id: "msg_01R3", output: 40) + "\n", to: transcript)
        store.lastRefresh = nil
        clock.advance(5)
        engine.observe(event(.turnFinished(lastMessage: "done", backgroundWork: false)))
        t.wait(0.4) { false }
        t.expectNil(store.lastRefresh, "a second turn five seconds later does not scan again")
        clock.advance(30)
        engine.observe(event(.turnFinished(lastMessage: "done", backgroundWork: false)))
        waitForRefresh(t, store)
        t.expectEqual(store.usage[.claude]?.today.output, 75)
        engine.stop()
    }
}

// MARK: Notes and locations

private func noteAndLocationTests(_ t: TestRunner, sandbox: URL) {
    let british = Locale(identifier: "en_GB")
    let now = date("2026-10-11T22:00:00Z")           // 15:00 in Los Angeles

    t.test("notes say where the numbers come from, in plain English") {
        func note(_ facts: UsageNotes.Facts) -> String { UsageNotes.note(facts, now: now, timeZone: losAngeles, locale: british) }
        let bare = note(UsageNotes.Facts(agent: .claude))
        t.expectEqual(bare, "Tokens are counted from Claude Code's transcripts on this Mac, so other devices and Claude Code's own background requests are not included. "
            + "Cost is an estimate at API list prices, not a bill. Limits appear here once Claude Code's status line reports them to Perch.")

        var facts = UsageNotes.Facts(agent: .claude, hasTokens: true, unpricedModels: ["claude-next-9"], hasLimits: true,
                                     limitsUpdatedAt: date("2026-10-11T21:32:00Z"))
        t.expect(note(facts).contains("Limits come from Claude Code's status line and were last updated today at 14:32."))
        t.expect(note(facts).hasSuffix("No list price is known for claude-next-9, so its tokens are counted at $0."))
        facts.unpricedModels = ["a", "b", "c"]
        t.expect(note(facts).hasSuffix("No list price is known for a, b and c, so their tokens are counted at $0."))
        facts.limitsUpdatedAt = date("2026-10-10T16:05:00Z")
        t.expect(note(facts).contains("last updated yesterday at 09:05."))
        facts.limitsUpdatedAt = date("2026-10-02T16:05:00Z")
        t.expect(note(facts).contains("last updated on 2 Oct at 09:05."))
        facts.expiredLabels = ["5-hour limit"]
        t.expect(note(facts).contains("The 5-hour limit has reset since then and shows 0% until the next update."))
        facts.expiredLabels = ["5-hour limit", "Weekly limit"]
        t.expect(note(facts).contains("The 5-hour limit and the Weekly limit have reset since then and show 0% until the next update."))
        facts.warnings = [RateWindow(id: "7d", label: "Weekly limit", usedPercent: 81.6, resetsAt: nil)]
        t.expect(note(facts).hasPrefix("Heads-up: the Weekly limit is at 82%. Tokens are counted"))

        // With cost estimates hidden in Settings the note does not talk about cost.
        var hidden = UsageNotes.Facts(agent: .claude, hasTokens: true, unpricedModels: ["claude-next-9"])
        hidden.showsCost = false
        t.expect(!note(hidden).lowercased().contains("cost") && !note(hidden).contains("price"))
        hidden.agent = .codex
        t.expect(!note(hidden).lowercased().contains("cost"))

        let codex = note(UsageNotes.Facts(agent: .codex, hasTokens: true, unpricedModels: ["gpt-5.2-codex"], hasLimits: true,
                                          limitsUpdatedAt: date("2026-10-11T21:32:00Z")))
        t.expectEqual(codex, "Tokens and limits are read from Codex's session files on this Mac; the limits are as fresh as Codex's last reply "
            + "and were last updated today at 14:32. No cost is estimated because Perch has no verified price list for Codex models.")
        t.expect(note(UsageNotes.Facts(agent: .codex)).contains("Limits appear here once Codex reports them."))
        t.expect(!note(UsageNotes.Facts(agent: .codex)).contains("cost"), "nothing about cost when there are no tokens")
        let gemini = note(UsageNotes.Facts(agent: .gemini, hasTokens: true))
        t.expect(gemini.contains("Gemini CLI's session files") && gemini.contains("does not share its limits") && gemini.contains("Gemini CLI models"))
        let antigravity = note(UsageNotes.Facts(agent: .antigravity))
        t.expect(antigravity.contains("status feed") && antigravity.contains("no token history"))
        t.expect(note(UsageNotes.Facts(agent: .antigravity, hasLimits: true, limitsUpdatedAt: now)).contains("Limits come from Antigravity's status feed and were last updated today at 15:00."))
    }

    t.test("the real locations: agents' folders are read, Perch's data folder is written") {
        let saved = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], ProcessInfo.processInfo.environment["CODEX_HOME"])
        defer {
            if let claude = saved.0 { setenv("CLAUDE_CONFIG_DIR", claude, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") }
            if let codex = saved.1 { setenv("CODEX_HOME", codex, 1) } else { unsetenv("CODEX_HOME") }
        }
        unsetenv("CLAUDE_CONFIG_DIR")
        unsetenv("CODEX_HOME")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let standard = UsageLocations.standard
        t.expectEqual(standard.claudeProjectsDirs.map(\.path), ["\(home)/.claude/projects", "\(home)/.config/claude/projects"])
        t.expectEqual(standard.codexHomes.map(\.path), ["\(home)/.codex"])
        t.expectEqual(standard.geminiHome?.path, "\(home)/.gemini")
        t.expect(standard.learnsFromEvents)
        t.expect(standard.dataDir.path.hasPrefix(sandbox.path), "PERCH_HOME moves the data folder (tests never write to the real one)")
        t.expectEqual(standard.ownFiles.map(\.lastPathComponent), ["usage.sqlite", "usage.sqlite-wal", "usage.sqlite-shm", "limits.json", "activity-stats.json"])
        t.expect(standard.ownFiles.allSatisfy { $0.path.hasPrefix(standard.dataDir.path + "/") }, "every file Perch writes is inside its data folder")

        setenv("CLAUDE_CONFIG_DIR", "/tmp/one, /tmp/two", 1)
        setenv("CODEX_HOME", "/tmp/codex-home", 1)
        t.expectEqual(UsageLocations.standard.claudeProjectsDirs.map(\.path), ["/tmp/one/projects", "/tmp/two/projects"])
        t.expectEqual(UsageLocations.standard.codexHomes.map(\.path), ["/tmp/codex-home"])

        // The app's initialiser exists and does nothing until it is started.
        let store = UsageStore()
        let engine: UsageEngineProtocol = UsageEngine(store: store, settings: makeSettings())
        _ = engine
        t.expect(store.usage.isEmpty && store.lastRefresh == nil && !store.isRefreshing)
        t.expect(!FileManager.default.fileExists(atPath: standard.dataDir.path), "creating an engine writes nothing")
    }
}
