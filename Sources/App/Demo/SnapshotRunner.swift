// SnapshotRunner.swift — draws every major screen of Perch to PNG files, using sample data.
//
//   Perch.app/Contents/MacOS/Perch --snapshot <folder>
//
// This is how the look of the whole app can be checked (and shown to someone) without running
// any coding agent: the pill in each state, the open panel on each tab, each kind of request
// card, every Settings page, the welcome panel, and the panel in every theme. Nothing real is
// read or changed: the data is SampleData, and the settings used here live in memory only.
//
// Pictures are drawn by SwiftUI's image renderer, which shows animations at their first frame
// and cannot draw scroll views; `perchStaticRendering` makes the scrolling parts lay their
// content out in place instead.

import SwiftUI
import AppKit

enum SnapshotRunner {
    /// Draws everything into `outputDir`. Returns how many pictures could not be written.
    @MainActor @discardableResult
    static func run(outputDir: URL) -> Int {
        var failures = 0
        func keep(_ url: URL?) { if url == nil { failures += 1 } }

        // 1. The pill.
        let pills: [(String, [SessionState], (AppEnv) -> Void)] = [
            ("pill-1-empty", [], { _ in }),
            ("pill-2-busy", [.runningTool, .working], { _ in }),
            ("pill-3-needs-you", [.needsApproval, .needsAnswer, .runningTool], { _ in }),
            ("pill-4-done", [.done], { _ in }),
            ("pill-5-failed", [.failed], { _ in }),
            ("pill-6-compact-busy", [.runningTool], { $0.settings.pillStyle = .compact }),
            ("pill-7-no-notch-needs-you", [.planReview, .working], { $0.ui.screenHasNotch = false }),
        ]
        for (name, states, adjust) in pills {
            let env = makeEnv(expanded: false, states: states)
            adjust(env)
            keep(island(name, env, to: outputDir))
        }

        // 2. The open panel, one picture per tab.
        for tab in PanelTab.allCases {
            let env = makeEnv(expanded: true, pending: [])
            env.ui.panelTab = tab
            keep(island("panel-\(tab.rawValue)", env, to: outputDir))
        }
        keep(island("panel-sessions-empty", makeEnv(expanded: true, states: [], pending: []), to: outputDir))
        keep(island("panel-sessions-with-requests", makeEnv(expanded: true), to: outputDir))

        // 3. Each kind of request card, alone with its session.
        let requests: [(String, PendingRequest)] = [
            ("card-approval-command", SampleData.pending[0]),
            ("card-approval-edit-with-diff", SampleData.editPending),
            ("card-question", SampleData.pending[1]),
            ("card-plan", SampleData.pending[2]),
        ]
        for (name, request) in requests {
            let session = SampleData.sessions.filter { $0.id == request.sessionID }
            keep(island(name, makeEnv(expanded: true, sessions: session, pending: [request]), to: outputDir))
        }

        // 4. Settings: every page, and the welcome panel shown on first launch.
        for (index, page) in SettingsPageID.allCases.enumerated() {
            let env = makeEnv(expanded: false)
            env.ui.settingsTab = page.tab
            keep(settings("settings-\(index + 1)-\(page.rawValue)", env, to: outputDir))
        }
        let firstRun = makeEnv(expanded: false)
        firstRun.settings.hasCompletedOnboarding = false
        if !firstRun.agents.statuses.isEmpty { firstRun.agents.statuses[0].hookStatus = .notInstalled }
        keep(settings("settings-welcome", firstRun, to: outputDir))

        // 5. Themes: the open panel and one Settings page in every theme.
        for theme in ThemeID.allCases {
            let env = makeEnv(expanded: true)
            env.settings.theme = theme
            keep(island("theme-\(theme.rawValue)-panel", env, to: outputDir))
            let window = makeEnv(expanded: false)
            window.settings.theme = theme
            window.ui.settingsTab = .appearance
            keep(settings("theme-\(theme.rawValue)-settings", window, to: outputDir))
        }
        // The mono theme's switches once had a white knob on a white track; keep an eye on them.
        do {
            let window = makeEnv(expanded: false)
            window.settings.theme = .mono
            window.ui.settingsTab = .general
            keep(settings("theme-mono-settings-switches", window, to: outputDir))
        }

        print(failures == 0 ? "all snapshots written to \(outputDir.path)" : "\(failures) snapshot(s) FAILED")
        return failures
    }

    // MARK: - Sample environments

    /// A sample environment whose settings are kept in memory only. `states` picks the sample
    /// sessions by state; `sessions` and `pending` override the samples entirely.
    @MainActor
    private static func makeEnv(expanded: Bool, states: [SessionState]? = nil, sessions: [Session]? = nil,
                                pending: [PendingRequest]? = nil) -> AppEnv {
        let settings = AppSettings(defaults: FileDefaults.inMemory())
        settings.hasCompletedOnboarding = true
        // Room for a whole request card, so the pictures show all of it.
        settings.panelMaxHeight = Double(IslandMetrics.maxPanelHeight)
        let chosen = sessions ?? states.map { wanted in SampleData.sessions.filter { wanted.contains($0.state) } }
        let env = SampleData.env(expanded: expanded, sessions: chosen, pending: pending, settings: settings)
        env.ui.isDemo = false
        return env
    }

    // MARK: - Drawing

    /// Draws the island (pill or open panel) at the top of a stand-in desktop.
    @MainActor
    private static func island(_ name: String, _ env: AppEnv, to folder: URL) -> URL? {
        var canvas = CGSize(width: 620, height: 120)
        if env.ui.isExpanded {
            measurePanelHeight(env)
            let panel = IslandMetrics.panelSize(ui: env.ui, settings: env.settings)
            canvas = CGSize(width: panel.width + 100, height: panel.height + 60)
        }
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.19, blue: 0.4), Color(red: 0.34, green: 0.23, blue: 0.5),
                                    Color(red: 0.7, green: 0.36, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            IslandRootView()
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .clipped()
        .perchEnvironment(env)
        .environment(\.perchStaticRendering, true)
        return Snapshot.write(view, name: name, size: canvas, to: folder)
    }

    /// Draws the Settings window's content at the size the window opens at.
    @MainActor
    private static func settings(_ name: String, _ env: AppEnv, to folder: URL) -> URL? {
        let size = SettingsRootView.idealSize
        let view = SettingsRootView()
            .perchEnvironment(env)
            .environment(\.perchStaticRendering, true)
        return Snapshot.write(view, name: name, size: size, to: folder, background: .black)
    }

    /// The open panel reports the height it wants a moment after it is first laid out. Host it
    /// in a window that is never shown, long enough for that to happen, so the picture shows the
    /// panel at the size the real window would give it.
    @MainActor
    private static func measurePanelHeight(_ env: AppEnv) {
        env.ui.desiredPanelHeight = 0
        let host = NSHostingView(rootView: IslandRootView().perchEnvironment(env).environment(\.perchStaticRendering, true))
        host.frame = NSRect(origin: .zero, size: IslandMetrics.windowSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.contentView = nil
    }
}
