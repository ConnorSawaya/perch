// CodexPaths.swift — where OpenAI's Codex CLI keeps its files, and how Perch tells it is installed.
//
// Everything Codex owns lives under one folder, `$CODEX_HOME` (default `~/.codex`). Perch reads
// `hooks.json`, `config.toml` and the session ("rollout") files there, and never touches
// `auth.json`. See docs/research/codex.md §1 for where each path comes from.

import Foundation

struct CodexPaths {
    /// `$CODEX_HOME`, or `~/.codex`.
    let home: URL
    /// Places a `codex` executable may be, most likely first.
    let binaryCandidates: [String]

    init(home: URL, binaryCandidates: [String]) {
        self.home = home
        self.binaryCandidates = binaryCandidates
    }

    /// The real locations on this Mac.
    init(environment: AdapterEnvironment) {
        let userHome = environment.home
        // An empty CODEX_HOME counts as unset, exactly as Codex treats it.
        if let override = environment.variables["CODEX_HOME"], !override.isEmpty {
            home = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            home = userHome.appendingPathComponent(".codex", isDirectory: true)
        }
        binaryCandidates = [
            userHome.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent("packages/standalone/current/bin/codex").path,
            home.appendingPathComponent("packages/standalone/current/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            userHome.appendingPathComponent(".volta/bin/codex").path,
            userHome.appendingPathComponent(".bun/bin/codex").path,
        ]
    }

    var hooksFile: URL { home.appendingPathComponent("hooks.json") }
    var configFile: URL { home.appendingPathComponent("config.toml") }
    var sessionsDir: URL { home.appendingPathComponent("sessions", isDirectory: true) }
    var sessionIndexFile: URL { home.appendingPathComponent("session_index.jsonl") }
    /// Process id of Codex's shared background server, when one is running.
    var daemonPidFile: URL { home.appendingPathComponent("app-server-daemon/app-server.pid") }

    var binaryPath: String? {
        binaryCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    var homeExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// "Codex is present" = a binary was found or its home folder exists.
    var isDetected: Bool { homeExists || binaryPath != nil }

    /// The session folders for today and yesterday (Codex names them by local date). Sessions that
    /// started earlier than that are not followed.
    func recentSessionDirectories(now: Date = Date(), calendar: Calendar = .current) -> [URL] {
        [now, now.addingTimeInterval(-24 * 60 * 60)].map { day in
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            return sessionsDir.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                                                      isDirectory: true)
        }
    }

    /// Plain-text rollout files in the recent session folders, or nil when Codex has no sessions
    /// folder at all. Compressed (`.jsonl.zst`) files are skipped: macOS cannot read them without
    /// extra software.
    func recentRolloutFiles(now: Date = Date()) -> [URL]? {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return nil }
        return recentSessionDirectories(now: now).flatMap { folder -> [URL] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }.map { folder.appendingPathComponent($0) }
        }
    }

    /// Codex's version without running it: the header line of the newest recent session file says
    /// which version wrote it.
    func versionFromRecentSession(now: Date = Date()) -> String? {
        guard let files = recentRolloutFiles(now: now) else { return nil }
        // File names start with a timestamp, so the greatest name is the newest session.
        guard let newest = files.max(by: { $0.lastPathComponent < $1.lastPathComponent }),
              let header = JSONLinesTailer.firstLine(of: newest).flatMap(JSONValue.parse) else { return nil }
        return header["payload"]["cli_version"].stringValue
    }

    /// The pid recorded for the shared background server, if the file exists and holds a number.
    func daemonPid() -> Int32? {
        guard let text = try? String(contentsOf: daemonPidFile, encoding: .utf8) else { return nil }
        // The file may be a bare number or a small JSON object with a "pid" member.
        if let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
        return JSONValue.parse(text)?["pid"].intValue.flatMap(Int32.init(exactly:))
    }
}
