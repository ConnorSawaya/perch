// LaunchOptions.swift — the few switches that change how Perch starts.
//
// Normal users never need these. They exist for looking at the app without touching anything
// real, and for the end-to-end tests:
//
//   --snapshot <dir>                 draw every major screen to PNG files in <dir>, then exit
//   --demo                           start with demo mode playing
//   PERCH_HOME=<dir>                 keep ALL of Perch's files (socket, helper, logs, statistics
//                                    and preferences) in <dir> instead of the real locations
//                                    — and never change any agent's settings file: Connect,
//                                    Disconnect and Uninstall leave them alone, because hooks
//                                    written by such a run would point into a temporary folder
//   PERCH_NO_LOGIN_ITEM=1            never register or unregister the "open at login" item
//   PERCH_TEST_AUTORESOLVE=allow|deny   answer every request automatically (tests only)
//   PERCH_TEST_AUTORESOLVE_DELAY=<s>    how long a request waits before that answer (default 0.4)
//
// Everything can be given either as an argument or as an environment variable; an argument wins.

import Foundation

struct LaunchOptions: Equatable {
    /// How the automatic answers of the end-to-end tests decide.
    enum AutoResolve: String, Equatable { case allow, deny }

    /// Folder to draw the screens into; nil for a normal launch.
    var snapshotDir: URL?
    var startInDemo = false
    var skipLoginItem = false
    var autoResolve: AutoResolve?
    var autoResolveDelay: TimeInterval = 0.4
    /// True when PERCH_HOME points Perch at a private folder (tests, experiments).
    var usesPrivateHome = false

    /// False in a PERCH_HOME run: the agents' settings files may be read but never changed.
    var mayChangeAgentSettings: Bool { !usesPrivateHome }
    static let agentSettingsLockedMessage = "This copy of Perch was started with PERCH_HOME set (a test run), "
        + "so it does not change any agent's settings file. Start Perch normally to connect or disconnect agents."

    init() {}

    init(arguments: [String], environment: [String: String]) {
        func flag(_ name: String) -> Bool { arguments.contains(name) }
        func value(after name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("--") ? nil : next
        }
        func variable(_ name: String) -> String? {
            guard let text = environment[name]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return text
        }
        func isOn(_ name: String) -> Bool {
            guard let text = variable(name)?.lowercased() else { return false }
            return !["0", "false", "no", "off"].contains(text)
        }

        if let folder = value(after: "--snapshot") ?? variable("PERCH_SNAPSHOT") {
            snapshotDir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        }
        startInDemo = flag("--demo") || isOn("PERCH_DEMO")
        skipLoginItem = flag("--no-login-item") || isOn("PERCH_NO_LOGIN_ITEM")
        autoResolve = (value(after: "--test-autoresolve") ?? variable("PERCH_TEST_AUTORESOLVE"))
            .flatMap { AutoResolve(rawValue: $0.lowercased()) }
        if let seconds = (value(after: "--test-autoresolve-delay") ?? variable("PERCH_TEST_AUTORESOLVE_DELAY")).flatMap(Double.init),
           seconds.isFinite, seconds >= 0 {
            autoResolveDelay = min(seconds, 60)
        }
        usesPrivateHome = variable("PERCH_HOME") != nil
    }

    /// The options this process was started with.
    static var current: LaunchOptions {
        LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
    }
}
