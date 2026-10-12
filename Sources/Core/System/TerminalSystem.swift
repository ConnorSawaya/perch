// TerminalSystem.swift — the handful of things the terminal jumper asks macOS to do.
//
// The jumper's decisions ("which script, what to fall back to, what to report") are kept apart
// from the acts themselves ("run this script", "bring that app forward"). The acts live behind
// the `TerminalSystem` protocol: `LiveTerminalSystem` is the real thing, and tests swap in a fake
// so they can check every decision without moving a single window.

import AppKit

/// What came back from running an AppleScript.
enum ScriptOutcome: Equatable {
    /// The script ran; this is what it returned (trimmed).
    case output(String)
    /// macOS refused: the user has not allowed Perch to control that app (Automation permission).
    case permissionDenied
    case timedOut
    /// Any other failure, with the tool's own message.
    case failed(String)

    /// Reads the result of an `osascript` run.
    init(_ result: ExternalToolResult) {
        if result.timedOut {
            self = .timedOut
        } else if result.succeeded {
            self = .output(result.trimmedOutput)
        } else if result.stderr.contains("-1743") || result.stderr.localizedCaseInsensitiveContains("not authorized to send apple events") {
            self = .permissionDenied
        } else {
            self = .failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Whether Perch may send Apple events to an app (System Settings → Privacy & Security → Automation).
enum AutomationPermission: Equatable {
    case granted
    case denied
    /// The user has never been asked; sending an event now would show the system's question.
    case notAskedYet
    /// Could not find out (for example the app is not running).
    case unknown
}

struct RunningApp: Equatable {
    var pid: Int32
    /// The name the app shows in the Dock, e.g. "Terminal".
    var name: String?
    /// Path of the `.app` bundle, used to find tools shipped inside it.
    var bundlePath: String?
}

protocol TerminalSystem: AnyObject {
    /// Bundle id of the app the user is working in.
    func frontmostBundleID() -> String?
    /// Bundle id of the app that hosts a process (see `ProcessProbe.hostApp`).
    func hostBundleID(of pid: Int32) -> String?
    /// The running app with this bundle id, or nil when it is not open.
    func runningApp(bundleID: String) -> RunningApp?
    /// Brings a running app to the front. Call on the main thread. False when it could not be asked.
    func activate(bundleID: String) -> Bool
    /// Opens a folder in a running app (editors bring the window that has it forward). Main thread.
    func openFolder(_ path: String, inApp bundleID: String) -> Bool
    func isDirectory(_ path: String) -> Bool

    /// Runs AppleScript source and waits for it. Blocks; call off the main thread.
    func runAppleScript(_ source: String, timeout: TimeInterval) -> ScriptOutcome
    /// Runs a command-line tool and waits for it. Blocks; call off the main thread.
    func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval) -> ExternalToolResult
    func firstExecutable(_ candidates: [String]) -> String?
    /// Path of the nearest ancestor of `pid` whose process name is `name` (finds the tmux in use).
    func ancestorExecutable(named name: String, of pid: Int32) -> String?
    /// File names in a folder (used to look for kitty's control socket).
    func fileNames(in directory: String) -> [String]

    /// Whether we may script this app. Never shows a prompt. May block; call off the main thread.
    func automationPermission(for bundleID: String) -> AutomationPermission
}

final class LiveTerminalSystem: TerminalSystem {

    func frontmostBundleID() -> String? { ProcessProbe.frontmostBundleID }

    func hostBundleID(of pid: Int32) -> String? { ProcessProbe.hostBundleID(of: pid) }

    func runningApp(bundleID: String) -> RunningApp? {
        guard let app = application(bundleID) else { return nil }
        return RunningApp(pid: app.processIdentifier, name: app.localizedName, bundlePath: app.bundleURL?.path)
    }

    func activate(bundleID: String) -> Bool {
        guard let app = application(bundleID) else { return false }
        if app.isHidden { app.unhide() }
        // Asking the system to "open" a running app is the dependable way to raise it: it also
        // switches Space, and works for apps that ignore a plain activate request from a
        // background app such as Perch.
        guard let url = app.bundleURL else { return app.activate(options: []) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { Log.error("Could not bring \(bundleID) forward: \(error.localizedDescription)", "system") }
        }
        return true
    }

    func openFolder(_ path: String, inApp bundleID: String) -> Bool {
        guard let appURL = application(bundleID)?.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: appURL,
                                configuration: configuration) { _, error in
            if let error { Log.error("Could not open the folder in \(bundleID): \(error.localizedDescription)", "system") }
        }
        return true
    }

    func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func runAppleScript(_ source: String, timeout: TimeInterval) -> ScriptOutcome {
        // Run out of process: NSAppleScript may only be used on the main thread, and a script
        // waiting on an unresponsive app would freeze Perch. macOS still attributes the request
        // to Perch, so the Automation question names Perch.
        ScriptOutcome(ExternalTool.run("/usr/bin/osascript", ["-e", source], timeout: timeout))
    }

    func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval) -> ExternalToolResult {
        ExternalTool.run(path, arguments, timeout: timeout)
    }

    func firstExecutable(_ candidates: [String]) -> String? { ExternalTool.firstExecutable(candidates) }

    func ancestorExecutable(named name: String, of pid: Int32) -> String? {
        for ancestor in ProcessProbe.ancestors(of: pid) where ProcessProbe.name(of: ancestor) == name {
            if let path = ProcessProbe.executablePath(of: ancestor), FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    func fileNames(in directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    }

    func automationPermission(for bundleID: String) -> AutomationPermission {
        guard application(bundleID) != nil else { return .unknown }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return .unknown }
        // `false` = only look up the answer, never ask the user.
        switch AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case Self.notPermitted: return .denied
        case Self.wouldRequireConsent: return .notAskedYet
        default: return .unknown
        }
    }

    /// `errAEEventNotPermitted` and `errAEEventWouldRequireUserConsent`.
    private static let notPermitted: OSStatus = -1743
    private static let wouldRequireConsent: OSStatus = -1744

    private func application(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }
}
