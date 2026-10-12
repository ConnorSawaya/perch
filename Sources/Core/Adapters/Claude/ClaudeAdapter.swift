// ClaudeAdapter.swift — everything Perch knows about Claude Code, behind the AgentAdapter protocol.
//
// The adapter is the only part of the app that understands Claude Code's formats. It has four jobs,
// each done by a small helper type in this folder:
//
//   status()            is Claude Code installed, and are our hooks in place?   ClaudeLocator, ClaudeInstaller
//   installHooks()      add our hooks + status line script to settings.json     ClaudeInstaller
//   uninstallHooks()    take exactly those out again                            ClaudeInstaller
//   normalize(_:)       Claude Code's hook / status line JSON → NormalizedEvent ClaudeEventNormalizer
//   encode(_:for:)      the user's decision → the JSON Claude Code expects      ClaudeDecisionEncoder
//
// Claude Code is driven entirely by hooks, so there is nothing to watch in files and
// startMonitoring / stopMonitoring keep their do-nothing defaults.
//
// Threading: like the rest of the app's services, call this on the main thread.

import Foundation

final class ClaudeAdapter: AgentAdapter {
    let kind = AgentKind.claude
    /// Claude Code supports everything Perch can do.
    let capabilities = AgentCapabilities(liveEvents: true, approvals: true, questions: true, planReview: true, usage: true, jump: true)

    /// Claude Code's configuration folder (normally ~/.claude).
    let configDir: URL
    private let installer: ClaudeInstaller
    private let locator: ClaudeLocator
    private let normalizer = ClaudeEventNormalizer()

    // MARK: - Creating

    /// The real thing: Claude Code's own config folder ($CLAUDE_CONFIG_DIR, else ~/.claude) and
    /// Perch's installed helper.
    convenience init() {
        self.init(configDir: Self.defaultConfigDir(), helperURL: PerchPaths.helperURL)
    }

    /// For tests (and unusual setups): any config folder and helper path.
    /// - Parameters:
    ///   - backupsDir: where settings backups go; defaults to PerchPaths.backupsDir.
    ///   - locator: how to look for the Claude Code program; tests pass one aimed at a temporary folder.
    init(configDir: URL, helperURL: URL, backupsDir: URL? = nil, locator: ClaudeLocator = ClaudeLocator()) {
        self.configDir = configDir
        self.locator = locator
        self.installer = ClaudeInstaller(
            settings: ClaudeSettingsFile(url: configDir.appendingPathComponent("settings.json"),
                                         backupsDir: backupsDir ?? PerchPaths.backupsDir),
            helperURL: helperURL)
    }

    static func defaultConfigDir(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    // MARK: - Status

    /// The Claude Code version found on disk, or the one a running session last reported.
    var detectedVersion: ClaudeVersion? {
        locator.find()?.version ?? normalizer.lastSeenVersion.flatMap { ClaudeVersion($0) }
    }

    /// True when Claude Code's status line runs Perch's script, so context % and limits arrive.
    var isStatusLineConnected: Bool {
        (try? installer.inspect(version: detectedVersion))?.statusLine == .connected
    }

    func status() -> AgentStatus {
        let installation = locator.find()
        let version = installation?.version ?? normalizer.lastSeenVersion.flatMap { ClaudeVersion($0) }
        let settingsPath = installer.settings.url.path
        let detected = installation != nil || FileManager.default.fileExists(atPath: configDir.path)
        func result(_ hookStatus: HookStatus, _ detail: String) -> AgentStatus {
            AgentStatus(agent: .claude, detected: detected, version: version?.description, configPath: settingsPath,
                        hookStatus: hookStatus, capabilities: capabilities, detail: detail)
        }
        guard detected else {
            return result(.notDetected, "Claude Code was not found on this Mac.")
        }
        let inspection: ClaudeInstaller.Inspection
        do {
            inspection = try installer.inspect(version: version)
        } catch {
            return result(.error, (error as? LocalizedError)?.errorDescription ?? "Claude Code's settings could not be read.")
        }

        switch inspection.hooks {
        case .notInstalled:
            return result(.notInstalled, "Claude Code is installed, but Perch's hooks are not set up yet.")
        case .needsUpdate:
            return result(.needsUpdate, "Perch's hooks are out of date or incomplete; install them again to refresh them.")
        case .installed:
            break
        }
        if inspection.hooksDisabledByUser {
            return result(.installed, "Perch's hooks are installed, but Claude Code is set to ignore all hooks (disableAllHooks).")
        }
        switch inspection.statusLine {
        case .connected:
            return result(.installed, "Hooks are installed and the status line is connected.")
        case .notSetUp, .needsRepair:
            return result(.needsUpdate, "Hooks are installed, but the status line is not connected; install again to connect it.")
        case .changedByUser:
            return result(.installed, "Hooks are installed. Status line not connected (you changed it), so context and limit readings are missing.")
        case .unsupported:
            return result(.installed, "Hooks are installed. Status line not connected (yours is not a plain command), so context and limit readings are missing.")
        }
    }

    // MARK: - Install / uninstall

    func installHooks() throws -> String {
        try installer.install(version: detectedVersion)
    }

    func uninstallHooks() throws -> String {
        try installer.uninstall()
    }

    // MARK: - Translating

    func normalize(_ envelope: HookEnvelope) -> [NormalizedEvent] {
        normalizer.events(for: envelope)
    }

    func encode(_ decision: Decision, for request: PendingRequest) -> HookReply {
        ClaudeDecisionEncoder.reply(for: decision, request: request)
    }

    // MARK: - Test seams

    /// Replaces the clock used for event timestamps.
    func setClock(_ now: @escaping () -> Date) { normalizer.now = now }
    /// Replaces the git branch lookup (tests should not depend on real repositories).
    func setGitBranchLookup(_ lookup: @escaping (String) -> String?) { normalizer.gitBranch = lookup }
}
