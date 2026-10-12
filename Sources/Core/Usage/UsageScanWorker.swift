// UsageScanWorker.swift — the part of the usage engine that runs off the main thread.
//
// It owns the ledger, runs the readers over the agents' files, and folds the ledger into the
// totals the views show. UsageEngine calls it only from its scan queue, one request at a time,
// and takes the result back to the main thread; nothing in here touches a store.

import Foundation

final class UsageScanWorker {
    struct Request {
        var locations: UsageLocations
        /// Agents to scan and report on (the ones enabled in Settings).
        var agents: Set<AgentKind>
        var fileAge: ((String) -> Int64?)?
        var now: () -> Date
        var timeZone: () -> TimeZone
        /// Checked between files; a true answer ends the scan early.
        var shouldStop: () -> Bool
        /// Called now and then during a long scan with the totals so far.
        var progress: ([AgentKind: TokenSummary]) -> Void
    }

    struct Result {
        var summaries: [AgentKind: TokenSummary] = [:]
        /// Agents whose session folders exist on this Mac.
        var installed: Set<AgentKind> = []
        /// Rate-limit numbers found in files (Codex).
        var limits: [LimitReport] = []
        var reports: [AgentKind: ScanReport] = [:]
        var seconds = 0.0

        /// One line for the debug log, e.g. "Claude Code 3/412 files, Codex 0/18 files in 0.04 s".
        var summaryLine: String {
            let parts = reports.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.displayName) \($0.value.filesRead)/\($0.value.filesFound) files" }
            return (parts.isEmpty ? "no agents" : parts.joined(separator: ", ")) + String(format: " in %.2f s", seconds)
        }
    }

    /// Seconds between progress reports during a long scan (tests shorten it).
    static var progressInterval = 2.0

    private var ledger: UsageLedger?
    private var ledgerURL: URL?
    /// The ledger's slices, reused while the ledger has not changed (re-reading them is the
    /// expensive part of a scan in which nothing was new).
    private var cache: (changeCount: Int, buckets: [UsageBucket], unpriced: [AgentKind: [String]])?

    func run(_ request: Request) -> Result {
        let started = Date()
        var result = Result()
        result.installed = request.locations.installedAgents()
        guard let ledger = openLedger(at: request.locations.ledgerURL) else { return result }

        var lastProgress = Date()
        for reader in request.locations.readers(for: request.agents) {
            let report = UsageScanner.scan(reader, into: ledger, fileAge: request.fileAge, shouldStop: request.shouldStop) { [self] in
                guard Date().timeIntervalSince(lastProgress) >= Self.progressInterval else { return }
                lastProgress = Date()
                request.progress(summaries(of: ledger, request: request))
            }
            result.reports[reader.agent] = report
            result.limits += report.limits
            if report.filesUnreadable > 0 || report.oversizedLines > 0 {
                Log.debug("\(reader.agent.displayName): skipped \(report.filesUnreadable) unreadable file(s) and \(report.oversizedLines) oversized line(s).", "usage")
            }
        }
        result.summaries = summaries(of: ledger, request: request)
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    /// Closes the ledger so its files can be deleted.
    func closeLedger() {
        ledger?.close()
        ledger = nil
        ledgerURL = nil
        cache = nil
    }

    private func summaries(of ledger: UsageLedger, request: Request) -> [AgentKind: TokenSummary] {
        do {
            if cache?.changeCount != ledger.changeCount {
                cache = (ledger.changeCount, try ledger.buckets(), try ledger.unpricedModels())
            }
        } catch {
            Log.error("Usage ledger could not be read: \(error)", "usage")
        }
        guard let cache else { return [:] }
        return UsageAggregator.summarize(cache.buckets, unpriced: cache.unpriced, now: request.now(), timeZone: request.timeZone())
            .filter { request.agents.contains($0.key) }
    }

    /// Opens the ledger. A file that cannot be opened (damaged, written by a newer build) is
    /// replaced by an empty one: scanning rebuilds everything the agents still keep. If even that
    /// fails (a read-only disk), a ledger in memory keeps this run of the app working.
    private func openLedger(at url: URL) -> UsageLedger? {
        if let ledger, ledgerURL == url { return ledger }
        closeLedger()
        do {
            ledger = try UsageLedger(url: url)
        } catch {
            Log.error("Usage ledger could not be opened (\(error)); starting a new one.", "usage")
            UsageFiles.remove(UsageLocations.ledgerFiles(at: url))
            ledger = (try? UsageLedger(url: url)) ?? (try? UsageLedger(url: nil))
        }
        ledgerURL = url
        return ledger
    }
}

/// Counts how often saved stats were cleared. The main thread bumps it; a running scan compares
/// it with the value it started under and gives up when they differ.
final class ScanEpoch {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func advance() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
