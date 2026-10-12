// PanelSnapshots.swift — draws the pill, the panel and the design system to PNG files so their
// look can be reviewed without launching the app.
//
// Run:  scripts/snapshot.sh Panel Sources/App/Design Sources/App/Panel Sources/App/Cards
// Look: .build/snapshots/Panel/*.png
//
// What is covered: the pill (empty / busy / needs you / done / failed, compact and detailed,
// without a notch, each mascot style), the open panel (full, empty, each theme, text sizes,
// widths, tabs, sort orders, effects off), a session card in every state, and a gallery of the
// shared components. The island is drawn over a fake desktop so it can be judged in context.
//
// Three things here are also behaviour checks (they print "check ok" / "CHECK FAILED"):
//   • the panel's height report (`UIState.desiredPanelHeight`) is measured for real by hosting
//     the view off-screen, once with a real scroll view and once with the static stand-in;
//   • session ordering, wording and formatting helpers are spot-checked;
//   • "live" checks run the island in a real (never shown) window and compare captured frames:
//     does confetti fire exactly when it should, does an idle pill stay still, does "Reduce
//     motion" stop everything, does the pill come back unchanged after opening and closing.
//     Frames from those runs are saved as live-*.png (captured from the window, not rendered
//     by Snapshot.write), which is the only way to look at a moment in the middle of an animation.

import SwiftUI
import AppKit

// MARK: - Entry point

@MainActor
func runPanelSnapshots(_ out: URL) {
    AgentIconProvider.shared.source = .monogramOnly   // pictures must not depend on installed apps
    snapshotPills(out)
    snapshotPanels(out)
    snapshotSessionCards(out)
    snapshotDesignSystem(out)
    runLogicChecks()
    runLiveChecks(out)
    print(checksFailed == 0 ? "all checks ok" : "\(checksFailed) CHECK(S) FAILED")
    // A failed check fails the run, so scripts notice.
    if checksFailed > 0 { exit(1) }
}

// MARK: - Helpers

/// Settings kept in memory only, so snapshots never write preference files to disk.
private final class SnapshotDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

@MainActor
private func makeSettings(_ configure: (AppSettings) -> Void = { _ in }) -> AppSettings {
    let settings = AppSettings(defaults: SnapshotDefaults())
    configure(settings)
    return settings
}

/// A sample environment. `states` picks sample sessions by state (nil = all eight).
@MainActor
private func makeEnv(expanded: Bool, states: [SessionState]? = nil, sessions: [Session]? = nil,
                     configure: (AppSettings) -> Void = { _ in }) -> AppEnv {
    let chosen = sessions ?? states.map { wanted in SampleData.sessions.filter { wanted.contains($0.state) } }
    return SampleData.env(expanded: expanded, sessions: chosen, settings: makeSettings(configure))
}

private var checksFailed = 0

private func check(_ condition: Bool, _ what: String) {
    if condition {
        print("check ok: \(what)")
    } else {
        checksFailed += 1
        print("CHECK FAILED: \(what)")
    }
}

/// A stand-in desktop: wallpaper, a menu bar, and the island on top.
private struct Desk: View {
    let menuBarHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.13, green: 0.2, blue: 0.42), Color(red: 0.36, green: 0.24, blue: 0.52),
                                    Color(red: 0.72, green: 0.36, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 14) {
                Spacer().frame(width: 150)
                Image(systemName: "apple.logo")
                Text("Terminal").fontWeight(.semibold)
                Text("Shell")
                Spacer()
                Image(systemName: "wifi")
                Text("Mon 9:41")
                Spacer().frame(width: 150)
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .frame(height: menuBarHeight)
            .background(Color.black.opacity(0.25))
            IslandRootView()
        }
    }
}

/// Hosts the island off-screen in a real (invisible) window so that layout, preferences and
/// deferred work actually run, then returns the height the panel reported.
@MainActor
private func measureReportedHeight(_ env: AppEnv, staticRendering: Bool) -> CGFloat {
    env.ui.desiredPanelHeight = 0
    let root = IslandRootView().perchEnvironment(env).environment(\.perchStaticRendering, staticRendering)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(origin: .zero, size: IslandMetrics.windowSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    window.contentView = nil
    return env.ui.desiredPanelHeight
}

/// Writes one snapshot of the island over the fake desktop. For an open panel the height is
/// measured first (see above), so the picture shows the size the real window would get.
@MainActor
private func snap(_ name: String, _ env: AppEnv, to out: URL, width: CGFloat? = nil, verifyHeight: Bool = false) {
    var canvas = CGSize(width: width ?? 560, height: 110)
    if env.ui.isExpanded {
        let live = measureReportedHeight(env, staticRendering: false)
        if verifyHeight {
            let still = measureReportedHeight(env, staticRendering: true)
            check(live > 0 && abs(live - still) < 1, "\(name): height reported with a real scroll view (\(live)) matches the static layout (\(still))")
            let limit = min(max(CGFloat(env.settings.panelMaxHeight), IslandMetrics.minPanelHeight), IslandMetrics.maxPanelHeight)
            check(live <= limit && live >= env.ui.notchSize.height + 60, "\(name): reported height \(live) is inside the allowed range")
        }
        let panel = IslandMetrics.panelSize(ui: env.ui, settings: env.settings)
        canvas = CGSize(width: width ?? panel.width + 100, height: panel.height + 56)
    }
    // The island's window is larger than the picture; pin its top-centre to the picture's top-centre.
    let view = Desk(menuBarHeight: env.ui.notchSize.height)
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .clipped()
        .perchEnvironment(env)
        .environment(\.perchStaticRendering, true)
    Snapshot.write(view, name: name, size: canvas, to: out)
}

// MARK: - Pill

@MainActor
private func snapshotPills(_ out: URL) {
    snap("pill-01-empty", makeEnv(expanded: false, states: []), to: out)
    snap("pill-02-busy", makeEnv(expanded: false, states: [.runningTool, .working]), to: out)
    snap("pill-03-needs-you", makeEnv(expanded: false, states: [.needsApproval, .needsAnswer, .runningTool]), to: out)
    snap("pill-04-done", makeEnv(expanded: false, states: [.done]), to: out)
    snap("pill-05-failed", makeEnv(expanded: false, states: [.failed]), to: out)
    snap("pill-06-idle", makeEnv(expanded: false, states: [.idle]), to: out)

    snap("pill-10-compact-empty", makeEnv(expanded: false, states: []) { $0.pillStyle = .compact }, to: out)
    snap("pill-11-compact-busy", makeEnv(expanded: false, states: [.runningTool]) { $0.pillStyle = .compact }, to: out)
    snap("pill-12-compact-needs-you", makeEnv(expanded: false, states: [.needsAnswer, .working]) { $0.pillStyle = .compact }, to: out)
    snap("pill-13-compact-done", makeEnv(expanded: false, states: [.done]) { $0.pillStyle = .compact }, to: out)

    for (name, states) in [("busy", [SessionState.working]), ("needs-you", [.planReview]), ("empty", [])] {
        let env = makeEnv(expanded: false, states: states)
        env.ui.screenHasNotch = false
        snap("pill-20-no-notch-\(name)", env, to: out)
    }

    for style in MascotStyle.allCases {
        snap("pill-30-mascot-\(style.rawValue)-busy", makeEnv(expanded: false, states: [.runningTool]) { $0.mascotStyle = style }, to: out)
        snap("pill-31-mascot-\(style.rawValue)-needs-you", makeEnv(expanded: false, states: [.needsApproval]) { $0.mascotStyle = style }, to: out)
        snap("pill-32-mascot-\(style.rawValue)-done", makeEnv(expanded: false, states: [.done]) { $0.mascotStyle = style }, to: out)
    }

    snap("pill-40-no-mascot-no-usage", makeEnv(expanded: false, states: [.runningTool, .working]) {
        $0.showMascot = false
        $0.showUsageInPill = false
    }, to: out)
    snap("pill-41-weekly-remaining", makeEnv(expanded: false, states: [.working]) {
        $0.pillMetric = .weekly
        $0.usageShowRemaining = true
    }, to: out)
    snap("pill-42-context", makeEnv(expanded: false, states: [.runningTool]) { $0.pillMetric = .context }, to: out)
    snap("pill-43-text-130", makeEnv(expanded: false, states: [.runningTool, .working]) { $0.textScale = 1.3 }, to: out)
    snap("pill-44-glow-off", makeEnv(expanded: false, states: [.needsApproval]) { $0.showGlow = false }, to: out)
}

// MARK: - Panel

@MainActor
private func snapshotPanels(_ out: URL) {
    // The whole sample set, at the default size (it scrolls) and at the tallest size.
    snap("panel-01-full", makeEnv(expanded: true), to: out, verifyHeight: true)
    snap("panel-02-full-tall", makeEnv(expanded: true) { $0.panelMaxHeight = 720 }, to: out, verifyHeight: true)

    // A calmer, more typical moment: nothing waiting, three sessions.
    let typical: [SessionState] = [.runningTool, .working, .done]
    snap("panel-03-typical", makeEnv(expanded: true, states: typical), to: out, verifyHeight: true)
    snap("panel-04-one-request", makeEnv(expanded: true, states: [.needsApproval, .runningTool, .done]), to: out, verifyHeight: true)

    // Empty states.
    snap("panel-05-empty", makeEnv(expanded: true, states: []), to: out, verifyHeight: true)
    let unconnected = makeEnv(expanded: true, states: [])
    unconnected.agents.statuses = unconnected.agents.statuses.map { status in
        var copy = status
        if copy.hookStatus == .installed { copy.hookStatus = .notInstalled }
        return copy
    }
    unconnected.ui.isDemo = false
    snap("panel-06-empty-not-connected", unconnected, to: out)

    // Other tabs (placeholders until the cards module lands).
    for tab in [PanelTab.usage, .activity] {
        let env = makeEnv(expanded: true, states: typical)
        env.ui.panelTab = tab
        snap("panel-07-tab-\(tab.rawValue)", env, to: out)
    }

    // Every theme.
    for theme in ThemeID.allCases {
        snap("panel-10-theme-\(theme.rawValue)",
             makeEnv(expanded: true, states: [.needsApproval, .runningTool, .working, .done, .failed]) { $0.theme = theme }, to: out)
    }

    // Text sizes.
    snap("panel-20-text-085", makeEnv(expanded: true, states: typical + [.needsAnswer]) { $0.textScale = 0.85 }, to: out, verifyHeight: true)
    snap("panel-21-text-130", makeEnv(expanded: true, states: typical + [.needsAnswer]) { $0.textScale = 1.3 }, to: out, verifyHeight: true)

    // Panel widths.
    snap("panel-22-width-420", makeEnv(expanded: true, states: typical + [.failed]) { $0.panelWidth = 420 }, to: out)
    snap("panel-23-width-760", makeEnv(expanded: true, states: typical + [.failed]) { $0.panelWidth = 760 }, to: out)

    // Mascot styles in the strip.
    for style in MascotStyle.allCases where style != .orb {
        snap("panel-30-mascot-\(style.rawValue)", makeEnv(expanded: true, states: typical) { $0.mascotStyle = style }, to: out)
    }

    // Sort orders.
    snap("panel-40-sort-recent", makeEnv(expanded: true, states: [.runningTool, .working, .done, .failed, .idle]) { $0.sortMode = .recent }, to: out)
    snap("panel-41-sort-project", makeEnv(expanded: true, states: [.runningTool, .working, .done, .failed, .planReview]) {
        $0.sortMode = .project
        $0.panelMaxHeight = 720
    }, to: out)

    // Everything decorative switched off, and every optional detail switched the other way.
    snap("panel-50-effects-off", makeEnv(expanded: true, states: [.needsApproval, .runningTool, .done]) {
        $0.showGlow = false
        $0.showMascot = false
        $0.useAgentColors = false
        $0.reduceMotion = true
        $0.soundsEnabled = false
    }, to: out)
    snap("panel-51-details-flipped", makeEnv(expanded: true, states: typical) {
        $0.showToolSparkline = false
        $0.showElapsedTime = false
        $0.showGitBranch = false
        $0.showModel = false
        $0.showSubagents = false
        $0.showProjectPath = true
        $0.usageShowRemaining = true
    }, to: out)

    // No notch (external display): the strip has no gap.
    let external = makeEnv(expanded: true, states: typical)
    external.ui.screenHasNotch = false
    snap("panel-60-no-notch", external, to: out)

    // Real use: not demo mode, so no footer.
    let real = makeEnv(expanded: true, states: typical)
    real.ui.isDemo = false
    snap("panel-61-not-demo", real, to: out, verifyHeight: true)

    snapshotOddInputs(out)
}

/// Values no well-behaved part of the app should produce. Nothing here may crash, and the
/// height report must stay inside its limits whatever it is fed.
@MainActor
private func snapshotOddInputs(_ out: URL) {
    var broken = SampleData.session(.claude, "s-broken", title: String(repeating: "wide ", count: 400), cwd: "relative/path",
                                    state: .runningTool, model: "m", ago: 10)
    broken.contextPercent = .nan
    broken.activeSubagents = -3
    broken.stateSince = Date(timeIntervalSince1970: 1e300)
    broken.currentTool = ToolCall(id: "", name: "", summary: "", startedAt: .distantFuture, finishedAt: .distantPast, succeeded: nil)
    broken.recentTools = (0..<200).map { SampleData.tool("T\($0)", "", ago: Double($0), took: $0.isMultiple(of: 7) ? nil : -4) }
    var twin = broken
    twin.id = Session.makeID(.codex, "s-broken-twin")
    twin.state = .needsApproval
    twin.contextPercent = .infinity

    for expanded in [false, true] {
        let env = makeEnv(expanded: expanded, sessions: [broken, twin]) {
            $0.panelWidth = expanded ? 99_999 : -50
            $0.panelMaxHeight = -1
            $0.textScale = 40
            $0.warnAtPercent = .nan
        }
        env.usage.usage[.claude]?.windows = [RateWindow(id: "5h", label: "", usedPercent: .nan, resetsAt: .distantPast),
                                             RateWindow(id: "7d", label: "Weekly", usedPercent: 1e9, resetsAt: nil)]
        env.ui.notchSize = expanded ? CGSize(width: 2000, height: 90) : .zero
        env.sessions.pulse = Pulse(kind: .done, sessionID: broken.id, at: Date())
        snap("odd-inputs-\(expanded ? "panel" : "pill")", env, to: out, width: 900)
        if expanded {
            let reported = env.ui.desiredPanelHeight
            check(reported > 0 && reported <= IslandMetrics.maxPanelHeight,
                  "odd inputs: the reported height (\(reported)) stays inside the window's limits")
        }
    }
    check(PerchFormat.elapsed(1e300) == PerchFormat.elapsed(1e11) && PerchFormat.ago(.distantFuture) == "just now"
          && PerchFormat.remaining(-.infinity) == "0s" && PerchFormat.cost(.nan) == "$0.00" && PerchFormat.path("") == "",
          "odd inputs: formatting helpers do not trap on absurd numbers")
}

// MARK: - Session cards

/// One session for each state, with believable details for that state.
@MainActor
private func sessionsForEveryState() -> (sessions: [Session], pending: [PendingRequest]) {
    let samples = SampleData.sessions
    func sample(_ state: SessionState) -> Session? { samples.first { $0.state == state } }
    var all: [Session] = []
    for state in SessionState.allCases {
        if let existing = sample(state) {
            all.append(existing)
            continue
        }
        var made = SampleData.session(.claude, "s-\(state.rawValue)", title: "Tidy the changelog and tag a release",
                                      cwd: "/Users/you/code/perch", state: state, model: "Sonnet 5.5", ago: 700)
        made.contextPercent = state == .compacting ? 93 : 24
        all.append(made)
    }
    return (all, SampleData.pending)
}

@MainActor
private func snapshotSessionCards(_ out: URL) {
    let everything = sessionsForEveryState()
    check(Set(everything.sessions.map(\.state)).count == SessionState.allCases.count, "there is a sample card for every session state")

    func sheet(_ name: String, sessions: [Session], width: CGFloat = 496, hover: Bool = false,
               configure: @escaping (AppSettings) -> Void = { _ in }) {
        let env = SampleData.env(sessions: sessions, pending: everything.pending, settings: makeSettings(configure))
        let view = VStack(spacing: 8) {
            ForEach(sessions) { SessionCardView(session: $0, previewHover: hover) }
        }
        .padding(16)
        .frame(width: width + 32)
        .perchEnvironment(env)
        let height = CGFloat(sessions.count) * 86 * CGFloat(env.settings.textScale) + 40
        Snapshot.write(view, name: name, size: CGSize(width: width + 32, height: height), to: out, background: .black)
    }

    sheet("cards-01-every-state", sessions: everything.sessions)
    sheet("cards-02-every-state-ember", sessions: everything.sessions) { $0.theme = .ember }
    sheet("cards-03-every-state-mono-large", sessions: everything.sessions) {
        $0.theme = .mono
        $0.textScale = 1.3
    }
    sheet("cards-04-narrow-full-paths", sessions: Array(everything.sessions.prefix(5)), width: 396) { $0.showProjectPath = true }

    // Awkward content: very long words, empty strings, missing optionals, absurd numbers.
    var long = SampleData.session(.codex, "s-long", title: "Refactor the authentication middleware so that refresh tokens rotate correctly across devices",
                                  cwd: "/Users/you/code/a-very-long-project-folder-name-that-keeps-going/packages/authentication-service",
                                  state: .runningTool, model: "gpt-5.5-codex-high-reasoning", ago: 90_000)
    long.gitBranch = "feature/JIRA-48213-rotate-refresh-tokens-across-devices-and-sessions"
    long.currentTool = SampleData.tool("Bash", "cd packages/authentication-service && npm run test:integration -- --runInBand --detectOpenHandles", ago: 4000, took: nil)
    long.contextPercent = 250
    long.activeSubagents = 12
    var bare = SampleData.session(.gemini, "s-bare", title: "", cwd: "", state: .done, model: nil, ago: 5)
    bare.gitBranch = nil
    bare.recentTools = []
    bare.lastMessage = "   "
    var multiline = SampleData.session(.claude, "s-multi", title: "Fix\nthe   build", cwd: "/", state: .failed, model: "", ago: 300)
    multiline.errorText = "error: linker command failed with exit code 1\n  ld: symbol(s) not found for architecture arm64\n  clang: error: use -v to see invocation"
    multiline.contextPercent = -5
    sheet("cards-05-awkward-content", sessions: [long, bare, multiline], configure: { $0.showProjectPath = true })
    check(SessionWording.title(for: bare) == "Gemini CLI session", "a session with no title and no folder is named after its agent")
    check(SessionWording.statusLine(for: bare, pending: nil).text == "Finished — waiting for your next prompt",
          "a blank last message falls back to plain words")

    // What the pointer reveals: a lifted card with the dismiss button where the time was.
    sheet("cards-06-hovered", sessions: Array(everything.sessions.dropFirst(2).prefix(3)), hover: true)
}

// MARK: - Logic checks

@MainActor
private func runLogicChecks() {
    let samples = SampleData.sessions

    let byAttention = SessionSorting.sorted(samples, by: .attention).map(\.state)
    check(byAttention.prefix(3).allSatisfy { $0.needsAttention }, "attention order puts the three waiting sessions first")
    check(byAttention.last == .idle, "attention order puts the idle session last")
    check(zip(byAttention, byAttention.dropFirst()).allSatisfy { SessionSorting.urgency($0) <= SessionSorting.urgency($1) },
          "attention order never puts a calmer state above a more urgent one")

    var older = samples[0], newer = samples[1]
    older.lastEventAt = Date(timeIntervalSince1970: 100)
    newer.lastEventAt = Date(timeIntervalSince1970: 200)
    check(SessionSorting.sorted([older, newer], by: .recent).first?.id == newer.id, "recent order puts the latest event first")

    let groups = SessionSorting.grouped(samples, by: .project)
    check(groups.map { $0.title ?? "" } == groups.map { $0.title ?? "" }.sorted(), "project groups are in A–Z order")
    check(groups.reduce(0) { $0 + $1.sessions.count } == samples.count, "project grouping keeps every session exactly once")
    check(SessionSorting.grouped([], by: .attention).isEmpty, "no sessions means no groups")
    check(Set([SortMode.attention, .recent, .project].map(SessionSorting.next(after:))).count == 3, "the sort button visits every order")

    check(SessionWording.summary(of: []).headline == "No sessions", "summary with no sessions")
    check(SessionWording.summary(of: samples).headline == "3 need you", "summary counts waiting sessions")
    check(SessionWording.oneLine(" a\n\n b   c ") == "a b c", "oneLine collapses whitespace")
    check(SessionState.allCases.allSatisfy { !SessionWording.label(for: $0).isEmpty && !SessionWording.symbol(for: $0).isEmpty },
          "every state has a label and a symbol")
    check(SampleData.sessions.allSatisfy { SessionWording.pillWord(for: $0).count <= 9 }, "pill words stay short")

    let usage = SampleData.usage
    check(UsageReadout.pick(.fiveHour, usage: usage, headline: nil)?.usedPercent == 37, "5-hour readout picks the fullest window")
    check(UsageReadout.pick(.weekly, usage: usage, headline: nil)?.usedPercent == 82, "weekly readout")
    check(UsageReadout.pick(.none, usage: usage, headline: nil) == nil, "metric none shows nothing")
    check(UsageReadout.pick(.context, usage: usage, headline: samples[0])?.usedPercent == 42, "context readout follows the headline session")
    check(UsageReadout.pick(.fiveHour, usage: [:], headline: nil) == nil, "no usage data means no readout")
    check(UsageReadout(label: "5h", title: "t", usedPercent: 130, resetsAt: nil).shownPercent(showRemaining: true) == 0, "percentages are clamped")

    check(PerchFormat.elapsed(14) == "14s" && PerchFormat.elapsed(312) == "5m 12s" && PerchFormat.elapsed(3_780) == "1h 03m"
          && PerchFormat.elapsed(-5) == "0s" && PerchFormat.elapsed(.nan) == "0s", "elapsed formatting")
    check(PerchFormat.count(950) == "950" && PerchFormat.count(12_400) == "12.4K" && PerchFormat.count(1_240_000) == "1.2M", "count formatting")
    check(PerchFormat.percent(41.6) == "42%" && PerchFormat.percent(250) == "100%" && PerchFormat.percent(.infinity) == "0%", "percent formatting")
    check(PerchFormat.path("/Users/you/code/perch") == "~/code/perch", "paths are shortened with ~")

    check(MascotMood(nil) == .idle && MascotMood(.compacting) == .busy && MascotMood(.planReview) == .attention
          && MascotMood(.done) == .done && MascotMood(.failed) == .failed, "session states map onto mascot moods")

    // Every theme must define every colour the views ask for, and keep the island black.
    for id in ThemeID.allCases {
        let settings = makeSettings { $0.theme = id; $0.textScale = 5 }
        let theme = Theme.current(settings)
        check(theme.id == id && theme.island == .black && theme.scale == 1.3 && !theme.glowColors.isEmpty
              && AgentKind.allCases.allSatisfy { theme.agentTints[$0] != nil }, "theme \(id.rawValue) is complete and clamps the text scale")
    }
    let plain = makeSettings { $0.useAgentColors = false }
    check(Theme.current(plain).accent(for: .codex, settings: plain) == Theme.current(plain).accent, "agent colours off falls back to the accent")
}

// MARK: - Live behaviour checks

/// The island in a real window that is never put on screen, so time can pass and frames can be compared.
@MainActor
private final class LiveIsland {
    let env: AppEnv
    private let host: NSHostingView<AnyView>
    private let window: NSWindow
    private static let size = CGSize(width: 720, height: 440)

    init(_ env: AppEnv) {
        self.env = env
        let root = ZStack(alignment: .top) {
            Color(red: 0.2, green: 0.2, blue: 0.3)
            IslandRootView()
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .clipped()
        .perchEnvironment(env)
        host = NSHostingView(rootView: AnyView(root))
        host.frame = NSRect(origin: .zero, size: Self.size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        wait(0.3)
    }

    func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// What the window shows right now.
    func frame() -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: image)
        return image
    }

    func finishSession(_ id: String, kind: Pulse.Kind = .done) {
        env.sessions.pulse = Pulse(kind: kind, sessionID: id, at: Date())
    }

    func close() { window.contentView = nil }
}

private func save(_ image: NSBitmapImageRep?, _ name: String, to out: URL) {
    guard let data = image?.representation(using: .png, properties: [:]) else { return }
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try? data.write(to: out.appendingPathComponent(name + ".png"))
}

/// How many pixels differ visibly between two captures. -1 when they cannot be compared.
private func changedPixels(_ first: NSBitmapImageRep?, _ second: NSBitmapImageRep?) -> Int {
    guard let first, let second, let a = first.bitmapData, let b = second.bitmapData,
          first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh,
          first.bytesPerRow == second.bytesPerRow, first.bitsPerPixel == second.bitsPerPixel else { return -1 }
    let step = max(1, first.bitsPerPixel / 8)
    var changed = 0
    for row in 0..<first.pixelsHigh {
        var offset = row * first.bytesPerRow
        for _ in 0..<first.pixelsWide {
            for channel in 0..<min(step, 3) where abs(Int(a[offset + channel]) - Int(b[offset + channel])) > 24 {
                changed += 1
                break
            }
            offset += step
        }
    }
    return changed
}

@MainActor
private func runLiveChecks(_ out: URL) {
    // One finished session: nothing on screen should be moving, so any change is the effect under test.
    let finished = SampleData.sessions.filter { $0.state == .done }
    guard let session = finished.first else { return check(false, "sample data has a finished session") }
    let island = LiveIsland(makeEnv(expanded: false, sessions: finished) { $0.showElapsedTime = false })
    let settings = island.env.settings

    let pill = island.frame()
    island.wait(0.3)
    check(changedPixels(pill, island.frame()) == 0, "live: a pill with nothing going on does not redraw")

    island.finishSession(session.id)
    island.wait(0.4)
    let confetti = island.frame()
    save(confetti, "live-01-pill-confetti", to: out)
    check(changedPixels(pill, confetti) > 40, "live: confetti falls from the pill when a session finishes")
    island.wait(1.6)
    check(changedPixels(pill, island.frame()) == 0, "live: the confetti is gone again after a moment")

    settings.showParticles = false
    island.finishSession(session.id)
    island.wait(0.4)
    check(changedPixels(pill, island.frame()) == 0, "live: no confetti when Particles is switched off")
    settings.showParticles = true

    settings.reduceMotion = true
    island.finishSession(session.id)
    island.wait(0.4)
    check(changedPixels(pill, island.frame()) == 0, "live: no confetti when Reduce motion is on")
    settings.reduceMotion = false

    island.finishSession(session.id, kind: .failed)
    island.wait(0.4)
    check(changedPixels(pill, island.frame()) == 0, "live: no confetti for a failure")
    island.finishSession("claude:not-a-listed-session")
    island.wait(0.4)
    check(changedPixels(pill, island.frame()) == 0, "live: no confetti for a session that is not on show")

    // Open the panel and catch it part-way.
    island.env.ui.isExpanded = true
    island.wait(0.1)
    let opening = island.frame()
    save(opening, "live-02-panel-opening", to: out)
    island.wait(1.0)
    let open = island.frame()
    save(open, "live-03-panel-open", to: out)
    check(changedPixels(pill, opening) > 2000 && changedPixels(opening, open) > 2000, "live: the panel grows out of the pill over several frames")
    check(island.env.ui.desiredPanelHeight > island.env.ui.notchSize.height + 60, "live: opening the panel reports its height")
    island.wait(0.3)
    check(changedPixels(open, island.frame()) == 0, "live: an open panel with nothing going on does not redraw")

    island.finishSession(session.id)
    island.wait(0.45)
    let cardConfetti = island.frame()
    save(cardConfetti, "live-04-card-confetti", to: out)
    check(changedPixels(open, cardConfetti) > 40, "live: confetti bursts from the card of the session that finished")
    island.wait(1.6)

    island.env.ui.isExpanded = false
    island.wait(0.12)
    save(island.frame(), "live-05-panel-closing", to: out)
    island.wait(1.0)
    check(changedPixels(pill, island.frame()) == 0, "live: closing the panel brings back exactly the same pill")
    island.close()

    // A busy session animates; Reduce motion freezes it.
    let busy = LiveIsland(makeEnv(expanded: false, states: [.runningTool]))
    let before = busy.frame()
    busy.wait(0.35)
    check(changedPixels(before, busy.frame()) > 0, "live: the mascot moves while a session is busy")
    busy.env.settings.reduceMotion = true
    busy.wait(0.3)
    let frozen = busy.frame()
    busy.wait(0.35)
    check(changedPixels(frozen, busy.frame()) == 0, "live: Reduce motion stops the pill's animations")
    busy.close()

    // Changing a setting repaints at once: here the theme and the pill style.
    let themed = LiveIsland(makeEnv(expanded: false, states: [.done]))
    let midnight = themed.frame()
    themed.env.settings.theme = .ember
    themed.env.settings.pillStyle = .compact
    themed.wait(0.8)
    check(changedPixels(midnight, themed.frame()) > 200, "live: changing theme and pill style repaints the pill")
    themed.close()
}

// MARK: - Design-system gallery

@MainActor
private func snapshotDesignSystem(_ out: URL) {
    let env = SampleData.env(settings: makeSettings())
    let black = Color.black
    Snapshot.write(GalleryControls().perchEnvironment(env), name: "design-controls",
                   size: CGSize(width: 760, height: 700), to: out, background: black)
    Snapshot.write(GalleryStatus().perchEnvironment(env), name: "design-status",
                   size: CGSize(width: 760, height: 520), to: out, background: black)
    snapshotRealIconBadges(env, out)
    Snapshot.write(GalleryMascots().perchEnvironment(env), name: "design-mascots",
                   size: CGSize(width: 760, height: 400), to: out, background: black)
    Snapshot.write(GalleryEffects().perchEnvironment(env), name: "design-effects",
                   size: CGSize(width: 760, height: 480), to: out, background: Color(red: 0.16, green: 0.17, blue: 0.2))
}

/// The one picture that does depend on this Mac: badges with the icons of whichever agent apps are
/// installed here, above the same badges with the monogram they fall back to.
@MainActor
private func snapshotRealIconBadges(_ env: AppEnv, _ out: URL) {
    let provider = AgentIconProvider.shared
    provider.source = .installedApps
    for agent in AgentKind.allCases {
        print("real icon: \(agent.rawValue) -> \(provider.appURL(for: agent)?.path ?? "none (monogram)")")
    }
    let icons = Snapshot.write(GalleryBadgeRow(title: "Installed app icons (this Mac)").perchEnvironment(env),
                               name: "design-badges-real-icons", size: CGSize(width: 760, height: 150), to: out, background: .black)
    provider.source = .monogramOnly
    let monograms = Snapshot.write(GalleryBadgeRow(title: "Monogram fallback").perchEnvironment(env),
                                   name: "design-badges-monogram", size: CGSize(width: 760, height: 150), to: out, background: .black)
    check(provider.icon(for: .claude) == nil, "badges: monogramOnly hides every app icon")
    check(icons != nil && monograms != nil, "badges: both badge pictures were written")

    let square = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.systemTeal.setFill()
        rect.fill()
        return true
    }
    provider.source = .fixed([.gemini: square])
    check(provider.icon(for: .gemini) != nil && provider.icon(for: .claude) == nil,
          "badges: an injected image is used for its agent only")
    provider.source = .monogramOnly
}

private struct GalleryBadgeRow: View {
    let title: String

    var body: some View {
        GallerySection(title: title) {
            HStack(spacing: 22) {
                ForEach(AgentKind.allCases) { agent in
                    HStack(spacing: 10) {
                        AgentBadge(agent, size: 14)
                        AgentBadge(agent, size: 18)
                        AgentBadge(agent, size: 30, state: .runningTool, backdrop: .black)
                        AgentBadge(agent, size: 44, state: .needsApproval, backdrop: .black)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GalleryControls: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        VStack(alignment: .leading, spacing: 22) {
            GallerySection(title: "Buttons") {
                ForEach([PerchButtonStyle.Size.small, .regular, .large], id: \.self) { size in
                    HStack(spacing: 10) {
                        Button("Allow") {}.buttonStyle(.perch(.primary, size: size))
                        Button("Always allow") {}.buttonStyle(.perch(.secondary, size: size))
                        Button("Deny") {}.buttonStyle(.perch(.destructive, size: size))
                        Button("Answer in terminal") {}.buttonStyle(.perch(.ghost, size: size))
                        Button("Disabled") {}.buttonStyle(.perch(.primary, size: size)).disabled(true)
                        Button { } label: { Label("With icon", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(.perch(.secondary, size: size))
                    }
                }
                HStack(spacing: 6) {
                    PerchIconButton(systemName: "speaker.wave.2.fill", help: "Mute") {}
                    PerchIconButton(systemName: "gearshape.fill", help: "Settings") {}
                    PerchIconButton(systemName: "bell.fill", help: "Active", isActive: true) {}
                    PerchIconButton(systemName: "xmark", help: "Close", size: 18) {}
                }
            }
            GallerySection(title: "Chips and key hints") {
                HStack(spacing: 8) {
                    Chip("Needs approval", systemImage: "hand.raised.fill", tint: theme.warning)
                    Chip("Running", tint: theme.info)
                    Chip("Done", systemImage: "checkmark", tint: theme.success)
                    Chip("Failed", tint: theme.danger)
                    Chip("3", tint: theme.warning, style: .solid)
                    Chip("Outline", style: .outline)
                    Chip("Opus 5.5", style: .plain)
                    Chip("feature/camera", systemImage: "arrow.triangle.branch", style: .plain, monospaced: true)
                    KeyHint("⌘", "Y")
                    KeyHint("esc")
                    KeyHint("↩")
                }
            }
            GallerySection(title: "Toggle rows") {
                VStack(spacing: 12) {
                    PerchToggleRow("Glow effects", subtitle: "A soft rotating light when something needs you.",
                                   systemImage: "sparkles", isOn: .constant(true))
                    PerchDivider()
                    PerchToggleRow("Particles", subtitle: "A little confetti when a task finishes.",
                                   systemImage: "party.popper", isOn: .constant(false))
                }
                .perchCard()
                .frame(width: 420)
            }
            GallerySection(title: "Text styles") {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Display").font(theme.font(.display)).foregroundStyle(theme.textPrimary)
                    Text("Title").font(theme.font(.title)).foregroundStyle(theme.textPrimary)
                    Text("Headline").font(theme.font(.headline)).foregroundStyle(theme.textPrimary)
                    Text("Body text").font(theme.font(.body)).foregroundStyle(theme.textSecondary)
                    Text("Label").font(theme.font(.label)).foregroundStyle(theme.textSecondary)
                    Text("Caption").font(theme.font(.caption)).foregroundStyle(theme.textTertiary)
                    Text("MICRO").font(theme.font(.micro)).foregroundStyle(theme.textTertiary)
                    Text("mono --flag").font(theme.font(.mono)).foregroundStyle(theme.textSecondary)
                }
            }
            GallerySection(title: "Empty state") {
                PerchEmptyState(title: "No activity yet", message: "Events show up here as your agents work.",
                                systemImage: "waveform.path.ecg") {
                    Button("Try demo mode") {}.buttonStyle(.perch(.primary))
                }
                .perchCard(padding: 0)
                .frame(width: 420)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GalleryStatus: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        VStack(alignment: .leading, spacing: 22) {
            GallerySection(title: "State dots") {
                HStack(spacing: 18) {
                    ForEach(SessionState.allCases, id: \.self) { state in
                        VStack(spacing: 8) {
                            StateDot(state, size: 10)
                            Text(state.rawValue).font(theme.font(size: 9)).foregroundStyle(theme.textTertiary)
                        }
                    }
                }
            }
            GallerySection(title: "Agent badges") {
                HStack(spacing: 16) {
                    ForEach(AgentKind.allCases) { agent in
                        HStack(spacing: 8) {
                            AgentBadge(agent, size: 18)
                            AgentBadge(agent, size: 30, state: .runningTool, backdrop: .black)
                            AgentBadge(agent, size: 44, state: .needsApproval, backdrop: .black)
                        }
                    }
                }
            }
            GallerySection(title: "Rings, meters and sparklines") {
                HStack(spacing: 20) {
                    ProgressRing(value: 0.37)
                    ProgressRing(value: 0.82, tint: theme.warning)
                    ProgressRing(value: 0.97, size: 22, tint: theme.danger)
                    ProgressRing(value: 0.62, size: 48)
                        .overlay(Text("62%").font(theme.font(size: 11, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary))
                    VStack(alignment: .leading, spacing: 8) {
                        PerchMeter(value: 0.42).frame(width: 90)
                        PerchMeter(value: 0.71, tint: theme.warning).frame(width: 90)
                        PerchMeter(value: 0.01, tint: theme.danger).frame(width: 90)
                    }
                    Sparkline(values: [2, 5, 3, 31, 12, 4, 9, 1, 14], colors: [nil, nil, nil, nil, theme.danger, nil, nil, nil, theme.info])
                        .frame(height: 18)
                    Sparkline(values: [3, 4, 2, 6, 9, 7, 12, 8, 14, 11, 16], style: .line, tint: theme.success)
                        .frame(width: 110, height: 28)
                    PerchActivityBars(tint: theme.info)
                    PerchActivityBars(tint: theme.textTertiary, isActive: false)
                }
            }
            GallerySection(title: "Cards") {
                HStack(spacing: 12) {
                    Text("Plain").font(theme.font(.label)).foregroundStyle(theme.textPrimary).perchCard()
                    Text("Hovered").font(theme.font(.label)).foregroundStyle(theme.textPrimary).perchCard(isHovered: true)
                    Text("Tinted").font(theme.font(.label)).foregroundStyle(theme.textPrimary).perchCard(tint: theme.warning)
                    Text("Selected").font(theme.font(.label)).foregroundStyle(theme.textPrimary).perchCard(isSelected: true)
                    Text("swift build").font(theme.font(.mono)).foregroundStyle(theme.textSecondary)
                        .padding(12).background(CardBackground(isSunken: true, cornerRadius: Theme.Radius.control))
                    Text("Needs you").font(theme.font(.label)).foregroundStyle(theme.textPrimary).perchCard()
                        .overlay(GlowBorder(cornerRadius: Theme.Radius.card))
                }
            }
            GallerySection(title: "Section headers and live text") {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Needs you", count: 2, systemImage: "bell.fill", tint: theme.warning)
                    SectionHeader("Sessions", count: 8) {
                        Button("Needs you first") {}.buttonStyle(.perch(.ghost, size: .small))
                    }
                    HStack(spacing: 14) {
                        PerchElapsedText(since: Date().addingTimeInterval(-14))
                        PerchElapsedText(since: Date().addingTimeInterval(-312))
                        PerchElapsedText(since: Date().addingTimeInterval(-4000))
                        PerchElapsedText(since: Date().addingTimeInterval(-200), style: .ago)
                        Text("scripts/build.sh release").font(theme.font(.mono)).perchShimmer()
                    }
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textSecondary)
                }
                .frame(width: 420)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GalleryMascots: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        VStack(alignment: .leading, spacing: 18) {
            ForEach(MascotStyle.allCases) { style in
                GallerySection(title: "Mascot — \(style.rawValue)") {
                    HStack(spacing: 26) {
                        ForEach(MascotMood.allCases, id: \.self) { mood in
                            HStack(spacing: 10) {
                                MascotView(mood: mood, size: 18, style: style)
                                MascotView(mood: mood, size: 56, style: style)
                            }
                        }
                    }
                    HStack(spacing: 26) {
                        ForEach(MascotMood.allCases, id: \.self) { mood in
                            Text(String(describing: mood)).font(theme.font(size: 9)).foregroundStyle(theme.textTertiary).frame(width: 84)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GalleryEffects: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        VStack(spacing: 30) {
            // The island shape as a pill and as a small panel, hanging from the top edge.
            HStack(alignment: .top, spacing: 60) {
                IslandShape().fill(theme.island).frame(width: 300, height: 32)
                    .overlay(GlowBorder(IslandShape(closed: false)))
                IslandShape(topRadius: 9, bottomRadius: Theme.Radius.panel).fill(theme.island).frame(width: 280, height: 150)
                    .overlay(alignment: .top) { AuroraHeader().frame(height: 110) }
                    .overlay(IslandShape(topRadius: 9, bottomRadius: Theme.Radius.panel, closed: false).stroke(theme.stroke, lineWidth: 1))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(theme.island)
                HStack(spacing: 0) {
                    ParticleBurst(frozenAt: 0.18)
                    ParticleBurst(frozenAt: 0.45, seed: 5)
                    ParticleBurst(frozenAt: 0.4, seed: 3, origin: .top, style: .shower)
                    ParticleBurst(frozenAt: 0.8, seed: 9)
                }
            }
            .frame(width: 680, height: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
