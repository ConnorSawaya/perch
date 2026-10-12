// UsageLedger.swift — Perch's own record of token usage: one row per API response, kept for good.
//
// Why Perch keeps its own copy: agents delete their session files (Claude Code after 30 days by
// default), so "all time" only exists if Perch remembers it. Why one row per response: the files
// repeat each response on several lines, and copies of whole conversations appear when a session
// is forked, so usage must be de-duplicated by the response's identity, not added up line by line.
//
// The ledger is a single SQLite file (`usage.sqlite` in Perch's data folder) with two tables:
//   responses — one row per API response (tokens, model, project, time, estimated cost)
//   files     — what the scanner remembers about each file it has read (size, how far it got),
//               so a restart continues where it stopped instead of reading everything again
// Both are written in the same transaction, so "how far we read" can never run ahead of "what we
// stored". Rows are only ever added or improved; a file that shrinks or disappears removes nothing.
//
// Not thread-safe: UsageEngine uses it from its scan queue only.

import Foundation

/// One API response (for agents without response ids: one usage step) on its way into the ledger.
struct UsageRecord: Equatable {
    /// Identity used for de-duplication. See ClaudeUsageReader for how Claude's key is built.
    var key: String
    var agent: AgentKind
    /// The agent's session id. Subagent usage carries the parent session's id.
    var session: String
    /// The API message id, used to spot a sidechain replay. Empty for agents that have none.
    var messageID = ""
    /// Display name of the project: the folder name of the session's working directory.
    var project: String
    /// When the response started, in milliseconds since 1970 (UTC).
    var timestampMs: Int64
    /// Normalised model id.
    var model: String
    var tokens: PricedTokens
    /// True for subagent / side-question lines.
    var isSidechain = false
    /// False for a line written while the response was still streaming (its output count is too low).
    var isFinal = true
}

/// What the scanner remembers about one file between scans.
struct ScannedFile: Equatable {
    /// Row id in the ledger; 0 until first saved.
    var id: Int64 = 0
    var path: String
    var agent: AgentKind
    var cursor = FileCursor()
    /// When the file was created (ms since 1970). Older files win ties, so a fork's copies of
    /// earlier responses stay with the original session.
    var birthMs: Int64 = 0
    /// Small JSON blob for readers that need to remember something between lines (Codex running totals).
    var carry = ""
}

/// One slice of the ledger: a quarter of an hour of one model in one project.
/// Quarter hours are used because every time zone's offset is a multiple of 15 minutes, so these
/// slices can be regrouped into local calendar days exactly, for any time zone, without reading rows again.
struct UsageBucket: Equatable {
    static let seconds: Int64 = 900

    var agent: AgentKind
    /// Start of the quarter hour, seconds since 1970.
    var start: Int64
    var model: String
    var project: String
    var totals: TokenTotals
}

final class UsageLedger {
    enum Outcome: Equatable {
        case inserted
        /// Replaced a stored row that had a smaller token total (a streaming placeholder).
        case upgraded
        /// Replaced a stored row for another reason (main copy beats sidechain copy, older file wins a tie).
        case replaced
        case duplicate
        /// A sidechain copy of a response the main conversation already has.
        case droppedSidechainReplay
    }

    /// Counters for diagnostics and tests.
    struct Stats: Equatable {
        var inserted = 0
        var duplicates = 0
        var upgrades = 0
        var sidechainReplays = 0
    }

    private static let schemaVersion: Int64 = 1

    private let database: SQLiteDatabase
    private var files: [String: ScannedFile] = [:]
    private var filesByID: [Int64: ScannedFile] = [:]
    private(set) var stats = Stats()
    /// Goes up whenever a row is added, changed or removed, so callers can skip re-reading totals.
    private(set) var changeCount = 0

    /// Opens the ledger at `url`, or a temporary in-memory one when `url` is nil.
    init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        database = try SQLiteDatabase(path: url?.path ?? ":memory:")
        // WAL + NORMAL: a commit does not wait for the disk, which matters when a first scan
        // commits once per file for thousands of files. Losing the last commit in a power cut is
        // harmless because rescanning a file is always safe.
        try database.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        try prepareSchema()
        try loadFiles()
        try repriceIfNeeded()
    }

    func close() { database.close() }

    func transaction<T>(_ body: () throws -> T) throws -> T { try database.transaction(body) }

    // MARK: Schema

    private func prepareSchema() throws {
        let found = try database.statement("PRAGMA user_version")
        let version = try found.step() ? found.int(0) : 0
        found.reset()
        if version != 0 && version != Self.schemaVersion {
            // A layout this build does not know: start again. Scanning rebuilds whatever the agents still keep.
            try database.execute("DROP TABLE IF EXISTS responses; DROP TABLE IF EXISTS files;")
        }
        try database.execute("""
            CREATE TABLE IF NOT EXISTS responses(
                key TEXT PRIMARY KEY,
                agent TEXT NOT NULL,
                session TEXT NOT NULL,
                message_id TEXT NOT NULL,
                project TEXT NOT NULL,
                ts_ms INTEGER NOT NULL,
                model TEXT NOT NULL,
                input INTEGER NOT NULL,
                output INTEGER NOT NULL,
                cache_write_5m INTEGER NOT NULL,
                cache_write_1h INTEGER NOT NULL,
                cache_read INTEGER NOT NULL,
                web_search INTEGER NOT NULL,
                flags INTEGER NOT NULL,
                cost_usd REAL NOT NULL,
                priced INTEGER NOT NULL,
                price_version INTEGER NOT NULL,
                source INTEGER NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS responses_by_message ON responses(session, message_id);
            CREATE TABLE IF NOT EXISTS files(
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                agent TEXT NOT NULL,
                inode INTEGER NOT NULL,
                device INTEGER NOT NULL,
                size INTEGER NOT NULL,
                mtime_ms INTEGER NOT NULL,
                offset INTEGER NOT NULL,
                tail_hash INTEGER NOT NULL,
                birth_ms INTEGER NOT NULL,
                carry TEXT NOT NULL
            );
            PRAGMA user_version = \(Self.schemaVersion);
            """)
    }

    // MARK: Files

    /// Re-reads the scan positions from the database, after a rolled-back transaction left the
    /// in-memory copy ahead of what was stored.
    func reloadFiles() {
        files.removeAll()
        filesByID.removeAll()
        do { try loadFiles() } catch { Log.error("Usage ledger: \(error)", "usage") }
    }

    private func loadFiles() throws {
        let rows = try database.statement("SELECT id, path, agent, inode, device, size, mtime_ms, offset, tail_hash, birth_ms, carry FROM files")
        while try rows.step() {
            guard let agent = AgentKind(rawValue: rows.text(2)) else { continue }
            var file = ScannedFile(id: rows.int(0), path: rows.text(1), agent: agent)
            file.cursor = FileCursor(inode: UInt64(bitPattern: rows.int(3)), device: rows.int(4), size: rows.int(5),
                                     mtimeMs: rows.int(6), offset: rows.int(7), tailHash: UInt64(bitPattern: rows.int(8)))
            file.birthMs = rows.int(9)
            file.carry = rows.text(10)
            files[file.path] = file
            filesByID[file.id] = file
        }
    }

    /// What is remembered about the file at `path`, if it has been scanned before.
    func file(atPath path: String) -> ScannedFile? { files[path] }

    func knownPaths(of agent: AgentKind) -> [String] { files.values.filter { $0.agent == agent }.map(\.path) }

    /// Stores the file's scan position. Gives a new file its id.
    func save(_ file: inout ScannedFile) throws {
        let c = file.cursor
        if file.id == 0 {
            try database.statement("""
                INSERT INTO files(path, agent, inode, device, size, mtime_ms, offset, tail_hash, birth_ms, carry)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET agent = excluded.agent, inode = excluded.inode, device = excluded.device,
                    size = excluded.size, mtime_ms = excluded.mtime_ms, offset = excluded.offset,
                    tail_hash = excluded.tail_hash, birth_ms = excluded.birth_ms, carry = excluded.carry
                """)
                .bind(.text(file.path), .text(file.agent.rawValue), .int(Int64(bitPattern: c.inode)), .int(c.device), .int(c.size),
                      .int(c.mtimeMs), .int(c.offset), .int(Int64(bitPattern: c.tailHash)), .int(file.birthMs), .text(file.carry))
                .run()
            let lookup = try database.statement("SELECT id FROM files WHERE path = ?").bind(.text(file.path))
            if try lookup.step() { file.id = lookup.int(0) }
            lookup.reset()
        } else {
            try database.statement("""
                UPDATE files SET inode = ?, device = ?, size = ?, mtime_ms = ?, offset = ?, tail_hash = ?, birth_ms = ?, carry = ?
                WHERE id = ?
                """)
                .bind(.int(Int64(bitPattern: c.inode)), .int(c.device), .int(c.size), .int(c.mtimeMs), .int(c.offset),
                      .int(Int64(bitPattern: c.tailHash)), .int(file.birthMs), .text(file.carry), .int(file.id))
                .run()
        }
        files[file.path] = file
        filesByID[file.id] = file
    }

    /// Forgets scan positions for files that no longer exist. Their responses stay in the ledger.
    /// `present` is what the last sweep found; a file outside it is only forgotten when it is
    /// really gone, not when its folder merely was not part of that sweep.
    func forgetFiles(of agent: AgentKind, notIn present: Set<String>) throws {
        for path in knownPaths(of: agent) where !present.contains(path) && !FileManager.default.fileExists(atPath: path) {
            guard let file = files.removeValue(forKey: path) else { continue }
            filesByID[file.id] = nil
            try database.statement("DELETE FROM files WHERE id = ?").bind(.int(file.id)).run()
        }
    }

    // MARK: Adding responses

    private struct Stored {
        var timestampMs: Int64
        var total: Int
        var isSidechain: Bool
        var isFinal: Bool
        var source: Int64
    }

    private enum Flag {
        static let fast: Int64 = 1
        static let geoUS: Int64 = 2
        static let sidechain: Int64 = 4
        static let final: Int64 = 8
    }

    /// Adds a response, or improves the stored copy of it. This is the de-duplication rule of
    /// docs/research/claude-usage.md section 4.3, steps 6 to 9.
    @discardableResult
    func upsert(_ record: UsageRecord, from file: ScannedFile) throws -> Outcome {
        // A side-question file can replay a response of the main conversation under another
        // request id. Same session + same message id, one copy main and one sidechain = one response.
        if !record.messageID.isEmpty {
            let others = try database.statement("SELECT key, flags FROM responses WHERE session = ? AND message_id = ? AND key <> ?")
                .bind(.text(record.session), .text(record.messageID), .text(record.key))
            var replaced: [String] = []
            var dropNew = false
            while try others.step() {
                let otherIsSidechain = others.int(1) & Flag.sidechain != 0
                if record.isSidechain && !otherIsSidechain { dropNew = true }
                if otherIsSidechain && !record.isSidechain { replaced.append(others.text(0)) }
            }
            if dropNew {
                stats.sidechainReplays += 1
                return .droppedSidechainReplay
            }
            for key in replaced {
                try database.statement("DELETE FROM responses WHERE key = ?").bind(.text(key)).run()
                stats.sidechainReplays += 1
                changeCount += 1
            }
        }

        guard let existing = try stored(record.key) else {
            try write(record, timestampMs: record.timestampMs, source: file.id)
            stats.inserted += 1
            return .inserted
        }
        stats.duplicates += 1
        // A response keeps the time of its earliest line, so it stays in one day even when its
        // lines straddle midnight.
        let earliest = min(existing.timestampMs, record.timestampMs)
        if isBetter(record, from: file, than: existing) {
            try write(record, timestampMs: earliest, source: file.id)
            if record.tokens.total != existing.total {
                stats.upgrades += 1
                return .upgraded
            }
            return .replaced
        }
        if earliest != existing.timestampMs {
            try database.statement("UPDATE responses SET ts_ms = ? WHERE key = ?").bind(.int(earliest), .text(record.key)).run()
            changeCount += 1
        }
        return .duplicate
    }

    /// Should the new line replace the stored copy of the same response?
    private func isBetter(_ record: UsageRecord, from file: ScannedFile, than existing: Stored) -> Bool {
        if record.isSidechain != existing.isSidechain { return existing.isSidechain }      // the main-conversation copy wins
        if record.tokens.total != existing.total { return record.tokens.total > existing.total }  // final usage beats a placeholder
        if record.isFinal != existing.isFinal { return record.isFinal }
        // An exact tie (a fork's copy of an earlier response): the older file keeps it, whatever
        // order the files were scanned in. A stored row whose file is forgotten keeps it too.
        guard file.id != existing.source, let holder = filesByID[existing.source] else { return false }
        return (file.birthMs, file.path) < (holder.birthMs, holder.path)
    }

    private func stored(_ key: String) throws -> Stored? {
        let row = try database.statement("""
            SELECT ts_ms, input + output + cache_write_5m + cache_write_1h + cache_read, flags, source FROM responses WHERE key = ?
            """).bind(.text(key))
        guard try row.step() else { return nil }
        let flags = row.int(2)
        let found = Stored(timestampMs: row.int(0), total: Int(row.int(1)), isSidechain: flags & Flag.sidechain != 0,
                           isFinal: flags & Flag.final != 0, source: row.int(3))
        row.reset()
        return found
    }

    private func write(_ record: UsageRecord, timestampMs: Int64, source: Int64) throws {
        let cost = UsagePricing.cost(of: record.tokens, model: record.model)
        if cost == nil { UsagePricing.noteUnknownModel(record.model) }
        let t = record.tokens
        let flags = (t.isFast ? Flag.fast : 0) | (t.isGeoUS ? Flag.geoUS : 0)
            | (record.isSidechain ? Flag.sidechain : 0) | (record.isFinal ? Flag.final : 0)
        try database.statement("""
            INSERT OR REPLACE INTO responses(key, agent, session, message_id, project, ts_ms, model, input, output,
                cache_write_5m, cache_write_1h, cache_read, web_search, flags, cost_usd, priced, price_version, source)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
            .bind(.text(record.key), .text(record.agent.rawValue), .text(record.session), .text(record.messageID),
                  .text(record.project), .int(timestampMs), .text(record.model), .integer(t.input), .integer(t.output),
                  .integer(t.cacheWrite5m), .integer(t.cacheWrite1h), .integer(t.cacheRead), .integer(t.webSearches),
                  .int(flags), .real(cost ?? 0), .int(cost == nil ? 0 : 1), .integer(UsagePricing.version), .int(source))
            .run()
        changeCount += 1
    }

    /// After a price-table change, re-estimates the cost of every stored response.
    private func repriceIfNeeded() throws {
        while true {
            let stale = try database.statement("""
                SELECT key, model, input, output, cache_write_5m, cache_write_1h, cache_read, web_search, flags
                FROM responses WHERE price_version <> ? LIMIT 500
                """).bind(.integer(UsagePricing.version))
            var batch: [(key: String, cost: Double?)] = []
            while try stale.step() {
                let flags = stale.int(8)
                let tokens = PricedTokens(input: Int(stale.int(2)), output: Int(stale.int(3)), cacheWrite5m: Int(stale.int(4)),
                                          cacheWrite1h: Int(stale.int(5)), cacheRead: Int(stale.int(6)), webSearches: Int(stale.int(7)),
                                          isFast: flags & Flag.fast != 0, isGeoUS: flags & Flag.geoUS != 0)
                batch.append((stale.text(0), UsagePricing.cost(of: tokens, model: stale.text(1))))
            }
            if batch.isEmpty { return }
            try database.transaction {
                for item in batch {
                    try database.statement("UPDATE responses SET cost_usd = ?, priced = ?, price_version = ? WHERE key = ?")
                        .bind(.real(item.cost ?? 0), .int(item.cost == nil ? 0 : 1), .integer(UsagePricing.version), .text(item.key))
                        .run()
                }
            }
            changeCount += 1
        }
    }

    // MARK: Reading totals

    /// The whole ledger folded into quarter-hour slices per agent, model and project.
    func buckets() throws -> [UsageBucket] {
        let rows = try database.statement("""
            SELECT agent, ts_ms / \(UsageBucket.seconds * 1000), model, project, SUM(input), SUM(output),
                   SUM(cache_write_5m + cache_write_1h), SUM(cache_read), SUM(cost_usd), COUNT(*)
            FROM responses GROUP BY 1, 2, 3, 4
            """)
        var result: [UsageBucket] = []
        while try rows.step() {
            guard let agent = AgentKind(rawValue: rows.text(0)) else { continue }
            let totals = TokenTotals(input: Int(rows.int(4)), output: Int(rows.int(5)), cacheWrite: Int(rows.int(6)),
                                     cacheRead: Int(rows.int(7)), costUSD: rows.double(8), messages: Int(rows.int(9)))
            result.append(UsageBucket(agent: agent, start: rows.int(1) * UsageBucket.seconds, model: rows.text(2),
                                      project: rows.text(3), totals: totals))
        }
        return result
    }

    /// Models whose tokens are counted at $0 because Perch has no price for them, per agent, sorted.
    func unpricedModels() throws -> [AgentKind: [String]] {
        let rows = try database.statement("SELECT DISTINCT agent, model FROM responses WHERE priced = 0 ORDER BY model")
        var result: [AgentKind: [String]] = [:]
        while try rows.step() {
            guard let agent = AgentKind(rawValue: rows.text(0)) else { continue }
            result[agent, default: []].append(rows.text(1))
        }
        return result
    }

    /// Totals grouped by one column ("session", "model", "project", "agent"), or by main / sidechain.
    /// Used by diagnostics and tests; the app's views are fed from `buckets()`.
    func totals(by grouping: Grouping, agent: AgentKind? = nil) throws -> [String: TokenTotals] {
        let column: String
        switch grouping {
        case .session: column = "session"
        case .model: column = "model"
        case .project: column = "project"
        case .agent: column = "agent"
        case .sidechain: column = "CASE WHEN flags & \(Flag.sidechain) <> 0 THEN 'sidechain' ELSE 'main' END"
        }
        let rows = try database.statement("""
            SELECT \(column), SUM(input), SUM(output), SUM(cache_write_5m + cache_write_1h), SUM(cache_read), SUM(cost_usd), COUNT(*)
            FROM responses WHERE (?1 IS NULL OR agent = ?1) GROUP BY 1
            """).bind(.optionalText(agent?.rawValue))
        var result: [String: TokenTotals] = [:]
        while try rows.step() {
            result[rows.text(0)] = TokenTotals(input: Int(rows.int(1)), output: Int(rows.int(2)), cacheWrite: Int(rows.int(3)),
                                               cacheRead: Int(rows.int(4)), costUSD: rows.double(5), messages: Int(rows.int(6)))
        }
        return result
    }

    enum Grouping { case session, model, project, agent, sidechain }

    /// The two kinds of cache write and the web searches, which TokenTotals does not keep apart.
    func cacheWriteSplit(agent: AgentKind) throws -> (fiveMinute: Int, oneHour: Int, webSearches: Int) {
        let row = try database.statement("""
            SELECT COALESCE(SUM(cache_write_5m), 0), COALESCE(SUM(cache_write_1h), 0), COALESCE(SUM(web_search), 0)
            FROM responses WHERE agent = ?
            """).bind(.text(agent.rawValue))
        guard try row.step() else { return (0, 0, 0) }
        let split = (Int(row.int(0)), Int(row.int(1)), Int(row.int(2)))
        row.reset()
        return split
    }
}
