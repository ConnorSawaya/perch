// AntigravityAdapter.swift — everything Perch knows about Google Antigravity, behind the AgentAdapter protocol.
//
// "Antigravity" is a family: the `agy` command-line tool, the Antigravity 2.0 desktop app and the
// Antigravity IDE. They share one hook system and one config folder (`~/.gemini/config`), which
// that folder also shares with Gemini CLI.
//
// What Perch can do (docs/research/antigravity.md): watch sessions work and finish, and jump to
// them. What it cannot do: approve tools or answer questions. Antigravity's hooks can block a
// tool but cannot approve one, so those stay in Antigravity. That is a limit of Antigravity.
//
// Safety: Antigravity refuses tool calls when a "before tool" hook fails. So Perch installs
// observing hooks only, and what Antigravity runs is a small script that answers by itself before
// it tells Perch anything (see AntigravityShim). Perch being closed, slow or deleted cannot get
// in Antigravity's way.
//
// Antigravity is not installed on the machine this was written on; nothing here was observed live.

import Foundation

final class AntigravityAdapter: AgentAdapter {
    let kind = AgentKind.antigravity

    /// Live events and jumping only. There is no file-based usage source that avoids credentials,
    /// and nothing can be answered from outside.
    let capabilities = AgentCapabilities(liveEvents: true, approvals: false, questions: false, planReview: false, usage: false, jump: true)

    /// `~/.gemini`, shared with Gemini CLI.
    private let geminiDir: URL
    private let home: URL
    private let binaryCandidates: [String]
    private let appLookup: (String) -> URL?
    private let installer: AntigravityHooksInstaller
    private let memory = AntigravitySessionMemory()
    private let toolMemory = ToolStartMemory()

    convenience init() {
        let environment = AdapterEnvironment.live
        let home = environment.home
        // The config folder cannot be moved for the `agy` CLI (it ignores GEMINI_HOME), so it is always ~/.gemini.
        self.init(geminiDir: home.appendingPathComponent(".gemini", isDirectory: true), helperPath: environment.helperPath,
                  backupsDir: environment.backupsDir,
                  binaryCandidates: [home.appendingPathComponent(".local/bin/agy").path, "/opt/homebrew/bin/agy", "/usr/local/bin/agy"],
                  appLookup: environment.appLookup, home: home)
    }

    /// For tests (and the shared initialiser): explicit folders, and no LaunchServices unless asked.
    init(geminiDir: URL, helperPath: String, backupsDir: URL, binaryCandidates: [String] = [],
         appLookup: @escaping (String) -> URL? = { _ in nil }, home: URL? = nil) {
        self.geminiDir = geminiDir
        self.home = home ?? geminiDir.deletingLastPathComponent()
        self.binaryCandidates = binaryCandidates
        self.appLookup = appLookup
        installer = AntigravityHooksInstaller(configDir: geminiDir.appendingPathComponent("config", isDirectory: true),
                                              helperPath: helperPath, backupsDir: backupsDir)
    }

    // MARK: Status

    /// Which Antigravity products are on this Mac. `~/.gemini` alone does not count (Gemini CLI uses
    /// it too), and neither does `~/.antigravity`, which belongs to an unrelated tool.
    var detectedSurfaces: [String] {
        let fm = FileManager.default
        func folder(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: geminiDir.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        var found: [String] = []
        if binaryCandidates.contains(where: { fm.isExecutableFile(atPath: $0) }) || folder("antigravity-cli") { found.append("CLI") }
        if appLookup("com.google.antigravity") != nil || folder("antigravity") { found.append("app") }
        if appLookup("com.google.antigravity-ide") != nil || folder("antigravity-ide") { found.append("IDE") }
        return found
    }

    static let limitsSentence = "Antigravity lets other apps watch but not approve tools or answer questions, so those stay in Antigravity, and its usage is not available without your Google login."

    func status() -> AgentStatus {
        let surfaces = detectedSurfaces
        func make(_ hookStatus: HookStatus, _ detail: String) -> AgentStatus {
            AgentStatus(agent: .antigravity, detected: !surfaces.isEmpty, version: nil,
                        configPath: surfaces.isEmpty ? nil : installer.hooksFile.path, hookStatus: hookStatus,
                        capabilities: capabilities, detail: detail)
        }
        guard !surfaces.isEmpty else { return make(.notDetected, "Antigravity was not found on this Mac.") }
        let found = "Found Antigravity (\(surfaces.joined(separator: ", ")))."
        switch installer.inspect() {
        case .unreadable(let reason):
            return make(.error, "Perch cannot read Antigravity's hooks file (\(reason)), so it will not change it.")
        case .notInstalled:
            return make(.notInstalled, "\(found) Perch's hooks are not installed, so its sessions are not shown. " + AntigravityAdapter.limitsSentence)
        case .needsUpdate:
            return make(.needsUpdate, "Perch's Antigravity hooks or helper script are out of date. Install again to repair them.")
        case .installed(_, let paused):
            if paused {
                return make(.installed, "Perch's hooks are installed but paused (\"enabled\": false in hooks.json), so nothing is shown.")
            }
            let suspicious = installer.suspiciousOtherHooks()
            if !suspicious.isEmpty {
                return make(.installed, "Perch's hooks are installed, but another hook in the same file (\(suspicious.joined(separator: ", "))) looks invalid and may make Antigravity ignore all hooks.")
            }
            return make(.installed, "Sessions are shown while they work and when they finish (restart running sessions after installing). " + AntigravityAdapter.limitsSentence)
        }
    }

    // MARK: Install / uninstall

    func installHooks() throws -> String {
        try installHooks(includingPreToolUse: false)
    }

    /// `includingPreToolUse` adds the experimental "show the tool before it runs" hook. It is off
    /// unless asked for, because Antigravity refuses tool calls when that hook fails and may prompt
    /// more often with it. The script answers it with "ask" (leave the decision to Antigravity).
    func installHooks(includingPreToolUse: Bool) throws -> String {
        // Without this check Perch would create ~/.gemini/config for someone who only has Gemini CLI.
        guard !detectedSurfaces.isEmpty else { throw AdapterConfigError.agentNotDetected("Antigravity") }
        return try installer.install(includePreToolUse: includingPreToolUse)
    }

    func uninstallHooks() throws -> String {
        try installer.uninstall()
    }

    // MARK: Events and decisions

    func normalize(_ envelope: HookEnvelope) -> [NormalizedEvent] {
        AntigravityHookEvents.normalize(envelope, home: home, memory: memory, toolMemory: toolMemory)
    }

    /// Antigravity gets its answer from the script before Perch even hears about the event, so there
    /// is never a decision to encode.
    func encode(_ decision: Decision, for request: PendingRequest) -> HookReply {
        .passthrough
    }

    // Monitoring: Antigravity's state comes from hooks. Its session databases are an undocumented
    // binary format and its transcript is only read on demand, so there is nothing to watch.
}
