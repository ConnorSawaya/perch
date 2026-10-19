// ClaudeLimitsProbe.swift — the fallback when Anthropic's usage endpoint will not answer.
//
// Claude Code only renews its saved login when it talks to Anthropic, so if you use the Claude app
// rather than a terminal, that login expires and the usage endpoint stops working. Anthropic also
// answers that endpoint with "too many requests" quite often. In either case Perch runs Claude
// Code once, headless, with a one-word prompt on the cheapest model:
//   - Claude Code renews its own login as a side effect (Perch never touches the login itself),
//   - and its output includes a "rate_limit_event" with the 5-hour and weekly percentages.
// It costs a fraction of a cent of usage, so it runs at most once an hour. It ignores your user
// settings (`--setting-sources project,local`), so your hooks, including Perch's, are not run.

import Foundation

enum ClaudeLimitsProbe {
    /// Runs the probe off the main thread and calls back on main with a report, or nil.
    static func run(completion: @escaping (LimitReport?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let report = runNow()
            DispatchQueue.main.async { completion(report) }
        }
    }

    private static func runNow() -> LimitReport? {
        guard let claude = claudeBinary() else { return nil }
        let folder = PerchPaths.dataDir.appendingPathComponent("limits-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let tool = Process()
        tool.executableURL = claude
        tool.arguments = ["-p", "Reply with only: ok", "--model", "haiku", "--max-turns", "1",
                          "--setting-sources", "project,local", "--output-format", "stream-json", "--verbose"]
        tool.currentDirectoryURL = folder
        // A plain environment, so nothing from whatever launched Perch changes how Claude Code behaves.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        tool.environment = ["HOME": home, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]
        let output = Pipe()
        tool.standardOutput = output
        tool.standardError = FileHandle.nullDevice
        tool.standardInput = FileHandle.nullDevice
        do { try tool.run() } catch { return nil }

        // Never let a stuck run hang around: give it one minute.
        let watchdog = DispatchWorkItem { if tool.isRunning { tool.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        watchdog.cancel()
        return parse(String(decoding: data, as: UTF8.self), at: Date())
    }

    /// The limits from the newest "rate_limit_event" line in Claude Code's stream-json output.
    static func parse(_ output: String, at now: Date) -> LimitReport? {
        var newest: LimitReport?
        for line in output.split(separator: "\n") where line.contains("rate_limit_event") {
            guard let event = JSONValue.parse(String(line)), event["type"].stringValue == "rate_limit_event" else { continue }
            let windows = event["rate_limit_info"]["unifiedWindows"]
            let found: [RateWindow] = [("five_hour", "5h", "5-hour limit"), ("seven_day", "7d", "Weekly limit")].compactMap { key, id, label in
                // Here utilization is a fraction (0.25 = 25%).
                guard let fraction = windows[key]["utilization"].doubleValue, fraction.isFinite else { return nil }
                let resets = windows[key]["resetsAt"].doubleValue.map { Date(timeIntervalSince1970: $0) }
                return RateWindow(id: id, label: label, usedPercent: min(max(fraction * 100, 0), 100), resetsAt: resets)
            }
            if !found.isEmpty { newest = LimitReport(agent: .claude, windows: found, planName: nil, capturedAt: now) }
        }
        return newest
    }

    private static func claudeBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
