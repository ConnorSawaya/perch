// UsageScanner.swift — one pass over an agent's session files, feeding the ledger.
//
// Each agent has a small "reader" that knows where its files are and how to read a line
// (ClaudeUsageReader, CodexUsageReader, GeminiUsageReader). The scanner does the part they share:
// for every file, continue where the last scan stopped, hand the new lines to the reader, store
// what it finds, and remember the new position, all in one database transaction per file.
//
// A scan is cheap when nothing changed (one `stat` per file) and safe to repeat at any time.
// It runs on UsageEngine's background queue.

import Foundation

/// A session file a reader wants scanned.
struct UsageSourceFile: Equatable {
    var path: String
    /// Last modification time, used to read the most recent files first.
    var modified: Date?
    /// Whatever the reader worked out from the path (project folder, session id...).
    var context: [String: String] = [:]

    static let walkKeys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Rate-limit numbers found in a file or sent by a live event.
struct LimitReport: Equatable {
    var agent: AgentKind
    var windows: [RateWindow]
    var planName: String?
    /// When the agent reported these numbers.
    var capturedAt: Date
}

enum UsageFinding {
    case record(UsageRecord)
    case limits(LimitReport)
}

protocol UsageFileReader {
    var agent: AgentKind { get }
    /// Every session file that exists right now. An agent that is not installed has none.
    func files() -> [UsageSourceFile]
    /// Reads the new lines of one file. `carry` is the reader's own note about the file, saved
    /// with the scan position and handed back next time (empty for a file read from the start).
    func read(_ tail: JSONLTail, file: UsageSourceFile, carry: inout String, emit: (UsageFinding) throws -> Void) throws
}

/// What one pass did.
struct ScanReport: Equatable {
    var filesFound = 0
    /// Files that had something new.
    var filesRead = 0
    var filesUnreadable = 0
    /// Lines too large to be a transcript line (over 32 MB) that were skipped.
    var oversizedLines = 0
    var recordsSeen = 0
    /// The freshest rate-limit numbers seen in the new lines: one report per window, each with
    /// the time it was written, plus one without windows when a plan name was seen.
    var limits: [LimitReport] = []
    /// True when the pass was cut short (the engine was told to stop, or the database failed).
    var incomplete = false
}

enum UsageScanner {
    /// Scans every file of `reader`.
    /// - Parameters:
    ///   - fileAge: overrides a file's creation time in milliseconds (tests use it to make results repeatable).
    ///   - shouldStop: checked between files.
    ///   - afterFile: called after each file that had something new, e.g. to show progress.
    @discardableResult
    static func scan(_ reader: UsageFileReader, into ledger: UsageLedger, fileAge: ((String) -> Int64?)? = nil,
                     shouldStop: () -> Bool = { false }, afterFile: () -> Void = {}) -> ScanReport {
        var report = ScanReport()
        // Newest first, so today's numbers are there early when a long history is read for the first time.
        let files = reader.files().sorted {
            let a = $0.modified ?? .distantPast, b = $1.modified ?? .distantPast
            return a != b ? a > b : $0.path < $1.path
        }
        report.filesFound = files.count
        var newestWindows: [String: LimitReport] = [:]
        var newestPlan: LimitReport?

        for file in files {
            if shouldStop() {
                report.incomplete = true
                break
            }
            var state = ledger.file(atPath: file.path) ?? ScannedFile(path: file.path, agent: reader.agent)
            let tail: JSONLTail
            switch JSONLTail.open(path: file.path, cursor: state.cursor) {
            case .unchanged: continue
            case .unreadable:
                report.filesUnreadable += 1
                continue
            case .ready(let opened): tail = opened
            }
            if tail.startsOver { state.carry = "" }
            state.birthMs = fileAge?(file.path) ?? tail.birthMs
            do {
                try ledger.transaction {
                    // A new file needs its id before its first record can point at it.
                    if state.id == 0 { try ledger.save(&state) }
                    var carry = state.carry
                    try reader.read(tail, file: file, carry: &carry) { finding in
                        switch finding {
                        case .record(let record):
                            report.recordsSeen += 1
                            try ledger.upsert(record, from: state)
                        case .limits(let limits):
                            for window in limits.windows where (newestWindows[window.id]?.capturedAt ?? .distantPast) <= limits.capturedAt {
                                newestWindows[window.id] = LimitReport(agent: limits.agent, windows: [window], planName: nil,
                                                                       capturedAt: limits.capturedAt)
                            }
                            if limits.planName != nil, (newestPlan?.capturedAt ?? .distantPast) <= limits.capturedAt {
                                newestPlan = LimitReport(agent: limits.agent, windows: [], planName: limits.planName,
                                                         capturedAt: limits.capturedAt)
                            }
                        }
                    }
                    state.carry = carry
                    state.cursor = tail.cursor
                    try ledger.save(&state)
                }
                report.filesRead += 1
                report.oversizedLines += tail.oversizedLines
                afterFile()
            } catch {
                // The transaction was rolled back; forget what was cached for it and stop this
                // pass. The next pass reads the file again, which is always safe.
                Log.error("Usage scan stopped: \(error)", "usage")
                ledger.reloadFiles()
                report.incomplete = true
                break
            }
        }
        if !report.incomplete {
            do { try ledger.forgetFiles(of: reader.agent, notIn: Set(files.map(\.path))) } catch { Log.error("Usage ledger: \(error)", "usage") }
        }
        report.limits = newestWindows.keys.sorted().compactMap { newestWindows[$0] } + (newestPlan.map { [$0] } ?? [])
        return report
    }
}
