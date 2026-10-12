// CodexUsageReader.swift — reads token usage and rate limits from Codex session files.
//
// Codex writes each conversation ("thread") to
//   $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl
// and now and then appends a `token_count` line with two things:
//   • the thread's running token totals (so usage = the difference between two such lines), and
//   • a snapshot of the account's rate limits (5-hour and weekly window, plan name).
// Nothing else is needed: no login, no network. See docs/research/codex.md sections 3.5 and 5.7.
//
// Because the totals are running totals, this reader has to remember the last totals it saw in
// each file. That memory travels in the `carry` text the scanner stores next to the scan position.
//
// Uncertain, because no real Codex install was available to check against (the research marks
// these as guesses): how a forked or resumed thread repeats earlier totals. Two precautions:
// usage is keyed by the thread a fork came from, and when a file's first totals are larger than
// its first response, only that response is counted. Compressed files (".jsonl.zst") cannot be
// read without extra software and are skipped.

import Foundation

struct CodexUsageReader: UsageFileReader {
    let agent = AgentKind.codex
    /// Codex home folders, normally just ~/.codex.
    var homes: [URL]

    init(homes: [URL]) { self.homes = homes }
    init(home: URL) { homes = [home] }

    func files() -> [UsageSourceFile] {
        var found: [UsageSourceFile] = []
        for home in homes {
            for folder in ["sessions", "archived_sessions"] { found += Self.rollouts(in: home.appendingPathComponent(folder, isDirectory: true)) }
        }
        return found
    }

    private static func rollouts(in root: URL) -> [UsageSourceFile] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: UsageSourceFile.walkKeys,
                                                          options: [], errorHandler: { _, _ in true }) else { return [] }
        var found: [UsageSourceFile] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            found.append(UsageSourceFile(path: url.standardizedFileURL.path, modified: UsageSourceFile.modificationDate(of: url)))
        }
        return found
    }

    // MARK: What is remembered per file

    struct Counts: Codable, Equatable {
        var input = 0       // all input tokens, cached ones included
        var cached = 0
        var cacheWrite = 0
        var output = 0

        var total: Int { input + output }

        init() {}

        init(_ usage: [String: Any]) {
            input = LineBytes.count(usage["input_tokens"])
            cached = LineBytes.count(usage["cached_input_tokens"])
            cacheWrite = LineBytes.count(usage["cache_write_input_tokens"])
            output = LineBytes.count(usage["output_tokens"])
        }

        /// The usage between two running totals, or nil when the totals went backwards.
        func since(_ earlier: Counts) -> Counts? {
            guard input >= earlier.input, cached >= earlier.cached, cacheWrite >= earlier.cacheWrite, output >= earlier.output else { return nil }
            var delta = Counts()
            delta.input = input - earlier.input
            delta.cached = cached - earlier.cached
            delta.cacheWrite = cacheWrite - earlier.cacheWrite
            delta.output = output - earlier.output
            return delta
        }
    }

    struct Carry: Codable, Equatable {
        var thread: String?
        var forkedFrom: String?
        var model: String?
        var cwd: String?
        /// The running totals of the last `token_count` line read from this file.
        var totals: Counts?
    }

    // MARK: Reading

    func read(_ tail: JSONLTail, file: UsageSourceFile, carry: inout String, emit: (UsageFinding) throws -> Void) throws {
        var state = Self.decode(carry)
        if state.thread == nil { state.thread = Self.threadID(fromFileName: (file.path as NSString).lastPathComponent) }
        try tail.forEachLine { line in
            for finding in Self.findings(fromLine: line, state: &state) { try emit(finding) }
        }
        carry = Self.encode(state)
    }

    /// Reads one line: updates what is known about the thread and returns any usage or limits in it.
    static func findings(fromLine line: UnsafeRawBufferPointer, state: inout Carry) -> [UsageFinding] {
        guard LineBytes.contains(line, "\"token_count\"") || LineBytes.contains(line, "\"turn_context\"")
                || LineBytes.contains(line, "\"session_meta\"") else { return [] }
        guard let object = LineBytes.object(line), let payload = object["payload"] as? [String: Any] else { return [] }
        switch object["type"] as? String {
        case "session_meta":
            state.thread = LineBytes.text(payload["id"]) ?? LineBytes.text(payload["session_id"]) ?? state.thread
            state.forkedFrom = LineBytes.text(payload["forked_from_id"]) ?? state.forkedFrom
            state.cwd = LineBytes.text(payload["cwd"]) ?? state.cwd
            return []
        case "turn_context":
            state.model = LineBytes.text(payload["model"]) ?? state.model
            state.cwd = LineBytes.text(payload["cwd"]) ?? state.cwd
            return []
        case "event_msg" where payload["type"] as? String == "token_count":
            guard let timestampMs = LineBytes.timestampMs(object["timestamp"]) else { return [] }
            var findings: [UsageFinding] = []
            if let info = payload["info"] as? [String: Any], let record = usageRecord(info: info, timestampMs: timestampMs, state: &state) {
                findings.append(.record(record))
            }
            if let limits = payload["rate_limits"] as? [String: Any], let report = limitReport(limits, timestampMs: timestampMs) {
                findings.append(.limits(report))
            }
            return findings
        default:
            return []
        }
    }

    private static func usageRecord(info: [String: Any], timestampMs: Int64, state: inout Carry) -> UsageRecord? {
        guard let totalUsage = info["total_token_usage"] as? [String: Any] else { return nil }
        let totals = Counts(totalUsage)
        let last = (info["last_token_usage"] as? [String: Any]).map(Counts.init)
        let delta: Counts
        if let previous = state.totals {
            if totals == previous { return nil }                    // the same totals written again
            // Totals that went backwards (a rolled-back thread): fall back to the last response alone.
            guard let step = totals.since(previous) ?? last else {
                state.totals = totals
                return nil
            }
            delta = step
        } else if let last, last.total > 0, last.total < totals.total {
            delta = last        // the rest was used before this file began (a resumed or forked thread)
        } else {
            delta = totals
        }
        state.totals = totals
        guard delta.total > 0 else { return nil }

        let thread = state.thread ?? "unknown"
        var tokens = PricedTokens()
        // Cached and cache-write tokens are part of `input_tokens` (Codex's own total is input + output).
        tokens.input = max(0, delta.input - delta.cached - delta.cacheWrite)
        tokens.cacheRead = min(delta.cached, delta.input)
        tokens.cacheWrite5m = delta.cacheWrite
        tokens.output = delta.output
        let project = state.cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        // Running totals only go up, so "thread + totals" names one step of one thread. A fork
        // that repeats its parent's lines is keyed by the parent and so is not counted twice.
        let key = "codex|\(state.forkedFrom ?? thread)|\(totals.input)|\(totals.cached)|\(totals.cacheWrite)|\(totals.output)"
        return UsageRecord(key: key, agent: .codex, session: thread, project: project, timestampMs: timestampMs,
                           model: (state.model ?? "unknown").lowercased(), tokens: tokens)
    }

    /// The rate-limit snapshot of a `token_count` line as Perch's windows.
    static func limitReport(_ limits: [String: Any], timestampMs: Int64) -> LimitReport? {
        let capturedAt = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
        let limitID = LineBytes.text(limits["limit_id"]) ?? "codex"
        let limitName = LineBytes.text(limits["limit_name"])
        var windows: [RateWindow] = []
        for (slot, fallbackLabel) in [("primary", "Primary limit"), ("secondary", "Secondary limit")] {
            guard let window = limits[slot] as? [String: Any], let used = LineBytes.number(window["used_percent"]) else { continue }
            var resetsAt: Date?
            if let epoch = LineBytes.number(window["resets_at"]), epoch > 0 {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let seconds = LineBytes.number(window["resets_in_seconds"]) {
                resetsAt = capturedAt.addingTimeInterval(seconds)       // written by Codex 0.47 and older
            }
            var label = Self.label(forMinutes: LineBytes.count(window["window_minutes"])) ?? fallbackLabel
            // The main limit is called "codex"; extra metered limits get their name in front.
            if limitID != "codex" { label = "\(limitName ?? limitID): \(label)" }
            windows.append(RateWindow(id: limitID == "codex" ? slot : "\(limitID):\(slot)", label: label,
                                      usedPercent: min(100, max(0, used)), resetsAt: resetsAt))
        }
        let plan = LineBytes.text(limits["plan_type"]).flatMap(planName)
        guard !windows.isEmpty || plan != nil else { return nil }
        return LimitReport(agent: .codex, windows: windows, planName: plan, capturedAt: capturedAt)
    }

    /// "5-hour limit", "Weekly limit"... from the window length Codex reports.
    static func label(forMinutes minutes: Int) -> String? {
        switch minutes {
        case 0: return nil
        case 300: return "5-hour limit"
        case 1440: return "Daily limit"
        case 10080: return "Weekly limit"
        case let m where m % 1440 == 0: return "\(m / 1440)-day limit"
        case let m where m % 60 == 0: return "\(m / 60)-hour limit"
        default: return "\(minutes)-minute limit"
        }
    }

    /// "plus" → "Plus", "edu_plus" → "Edu Plus". Codex writes "unknown" when it does not know.
    static func planName(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let name = words.joined(separator: " ")
        return name.isEmpty || raw.lowercased() == "unknown" ? nil : name
    }

    /// The thread id inside "rollout-2026-10-10T09-15-02-<uuid>.jsonl" (also "…-<uuid>_<uuid>.jsonl").
    static func threadID(fromFileName name: String) -> String? {
        let prefix = "rollout-0000-00-00T00-00-00-".count
        guard name.count >= prefix + 36 else { return nil }
        let id = String(name.dropFirst(prefix).prefix(36))
        return ClaudeUsageReader.isUUID(id) ? id : nil
    }

    private static func decode(_ carry: String) -> Carry {
        guard let data = carry.data(using: .utf8), let state = try? JSONDecoder().decode(Carry.self, from: data) else { return Carry() }
        return state
    }

    private static func encode(_ state: Carry) -> String {
        (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
