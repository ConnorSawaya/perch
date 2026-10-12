// UsageFiles.swift — where the usage module reads from and what it keeps on disk.
//
// Reads (never writes): the agents' own session folders.
// Writes: three things in Perch's data folder (~/Library/Application Support/Perch/data):
//   usage.sqlite         the usage ledger and scan positions (plus SQLite's -wal / -shm side files)
//   limits.json          the latest rate-limit numbers, so they are there right after a restart
//   activity-stats.json  the daily activity tally
// "Clear saved stats" deletes exactly these files and nothing else.

import Foundation

struct UsageLocations {
    /// Folders holding Claude Code transcripts (`<project>/<session>.jsonl`).
    var claudeProjectsDirs: [URL]
    /// Codex home folders (each holds `sessions/`), normally just ~/.codex.
    var codexHomes: [URL] = []
    /// Gemini CLI home folder (holds `tmp/<project>/chats/`), or nil to leave Gemini alone.
    var geminiHome: URL?
    /// Where Perch keeps its own files.
    var dataDir: URL
    /// True for the real locations: hook events may then reveal extra folders (a custom
    /// CLAUDE_CONFIG_DIR or CODEX_HOME that a menu-bar app cannot see in its own environment).
    var learnsFromEvents = false

    var ledgerURL: URL { dataDir.appendingPathComponent("usage.sqlite") }
    var limitsURL: URL { dataDir.appendingPathComponent("limits.json") }
    var activityURL: URL { dataDir.appendingPathComponent("activity-stats.json") }

    /// Every file this module may create.
    var ownFiles: [URL] { Self.ledgerFiles(at: ledgerURL) + [limitsURL, activityURL] }

    /// The ledger and the two side files SQLite keeps next to it while it is open.
    static func ledgerFiles(at url: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
    }

    /// The places the agents use on a normal install.
    static var standard: UsageLocations {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        var claude: [URL] = []
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            // The variable moves Claude Code's whole folder; some tools accept several, comma-separated.
            claude = custom.split(separator: ",").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces), isDirectory: true) }
        } else {
            claude = [home.appendingPathComponent(".claude", isDirectory: true), home.appendingPathComponent(".config/claude", isDirectory: true)]
        }
        var codex = home.appendingPathComponent(".codex", isDirectory: true)
        if let custom = environment["CODEX_HOME"], !custom.isEmpty { codex = URL(fileURLWithPath: custom, isDirectory: true) }
        return UsageLocations(claudeProjectsDirs: claude.map { $0.appendingPathComponent("projects", isDirectory: true) },
                              codexHomes: [codex], geminiHome: home.appendingPathComponent(".gemini", isDirectory: true),
                              dataDir: PerchPaths.dataDir, learnsFromEvents: true)
    }

    /// The readers for the given agents, in a fixed order.
    func readers(for agents: Set<AgentKind>) -> [UsageFileReader] {
        var readers: [UsageFileReader] = []
        if agents.contains(.claude), !claudeProjectsDirs.isEmpty { readers.append(ClaudeUsageReader(projectsDirs: claudeProjectsDirs)) }
        if agents.contains(.codex), !codexHomes.isEmpty { readers.append(CodexUsageReader(homes: codexHomes)) }
        if agents.contains(.gemini), let geminiHome { readers.append(GeminiUsageReader(home: geminiHome)) }
        return readers
    }

    /// Agents whose session folder exists, i.e. that look installed. Checked on the scan queue.
    func installedAgents() -> Set<AgentKind> {
        func isFolder(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        var agents = Set<AgentKind>()
        if claudeProjectsDirs.contains(where: isFolder) { agents.insert(.claude) }
        if codexHomes.contains(where: { isFolder($0.appendingPathComponent("sessions")) }) { agents.insert(.codex) }
        if let geminiHome, isFolder(geminiHome.appendingPathComponent("tmp")) { agents.insert(.gemini) }
        return agents
    }
}

/// Small JSON files, written atomically (a reader never sees a half-written file).
enum UsageFiles {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            Log.error("Could not save \(url.lastPathComponent): \(error.localizedDescription)", "usage")
        }
    }

    static func remove(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch {
                Log.error("Could not delete \(url.lastPathComponent): \(error.localizedDescription)", "usage")
            }
        }
    }
}

/// The saved form of the daily activity tally.
struct SavedActivity: Codable, Equatable {
    var version = 1
    var days: [DailyActivity]

    init(days: [DailyActivity]) { self.days = days }

    /// Reads each day field by field, so a file written before a counter existed (or after one
    /// was dropped) still loads; a missing counter starts at zero.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        days = try container.decode([[String: JSONValue]].self, forKey: .days).compactMap { fields in
            guard let day = fields["day"]?.stringValue, !day.isEmpty else { return nil }
            func count(_ key: String) -> Int { max(0, fields[key]?.intValue ?? 0) }
            return DailyActivity(day: day, activeSeconds: count("activeSeconds"), sessionsStarted: count("sessionsStarted"),
                                 turnsFinished: count("turnsFinished"), toolCalls: count("toolCalls"),
                                 approvalsHandled: count("approvalsHandled"), questionsAnswered: count("questionsAnswered"),
                                 longestTaskSeconds: count("longestTaskSeconds"), peakConcurrent: count("peakConcurrent"))
        }
    }
}
