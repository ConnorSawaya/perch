// SettingsSnapshots.swift — draws the Settings window to PNG files so its look can be reviewed
// without launching the app, and runs a few checks on the Settings code while it is at it.
//
// Run:  scripts/test-all.sh Settings        (or scripts/snapshot.sh Settings <sources>, see test-all.sh)
// Look: .build/snapshots/Settings/*.png
//
// What is drawn:
//   page-NN-<name>.png       each of the four pages at the window's normal size (860 x 620)
//   ember-NN-<name>.png      the same four pages in another theme
//   text-130-NN-<name>.png   the same four pages with the largest text
//   welcome-*.png            the first-run welcome panel
//   state-*.png              other states worth a look: sounds off, a confirmation showing,
//                            agents in trouble, no agents, the diagram mid-animation, uninstalling
//   theme-*.png, size-*.png  the Look page in every theme, the smallest window and a wide one
//
//   live-*.png               frames captured from a real (never shown) window, see below
//
// Checks (they print "check ok" / "CHECK FAILED"; a failure makes the run exit with an error):
//   • the settings the window is meant to offer (`exposedSettings` below) are all used in
//     Sources/App/Settings, and no other setting has crept back in;
//   • every SettingsTab the rest of the app can ask for lands on one of the four pages;
//   • the slider arithmetic and the value wording behave at their edges;
//   • "live" checks put the real content in a real window that is never visible (transparent and
//     far off-screen), with a real scroll view, which the PNG renderer cannot draw. They compare
//     captured frames (every page draws, no page needs scrolling or makes the window grow, a
//     quiet window does not keep redrawing, a new activity line sends the dot along the diagram
//     and the diagram comes to rest again, "Reduce motion" stops the dot, the welcome panel
//     covers the window and goes away, picking a theme repaints everything) and they click
//     things: switches, sliders, the hour stepper, the segmented picker, the two-step confirm
//     button, the switches that drive several settings at once, the mascot tiles, the row with
//     demo mode and uninstalling, every sidebar entry and the welcome panel's buttons. The
//     clicks are handed straight to that window; the real pointer is not moved.

import SwiftUI
import AppKit

// MARK: - Entry point

@MainActor
func runSettingsSnapshots(_ out: URL) {
    AgentIconProvider.shared.source = .monogramOnly   // pictures must not depend on installed apps
    snapshotPages(out)
    snapshotWelcome(out)
    snapshotStates(out)
    snapshotVariations(out)
    checkExposedSettings()
    checkTabRouting()
    checkControlLogic()
    runLiveSettingsChecks(out)
    print(settingsChecksFailed == 0 ? "all checks ok" : "\(settingsChecksFailed) CHECK(S) FAILED")
    if settingsChecksFailed > 0 { exit(1) }
}

// MARK: - Helpers

private let windowSize = CGSize(width: 860, height: 620)

/// Settings kept in memory only, so snapshots never write preference files to disk.
private final class SettingsSnapshotDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

/// A sample environment showing `tab`, past the welcome panel unless `welcome` is true.
@MainActor
private func makeSettingsEnv(_ tab: SettingsTab, welcome: Bool = false, configure: (AppEnv) -> Void = { _ in }) -> AppEnv {
    let settings = AppSettings(defaults: SettingsSnapshotDefaults())
    settings.hasCompletedOnboarding = !welcome
    let env = SampleData.env(settings: settings)
    env.ui.settingsTab = tab
    env.ui.isDemo = false
    configure(env)
    return env
}

@MainActor
private func writeSettings(_ env: AppEnv, name: String, size: CGSize = windowSize, freeze: PipelineFreeze? = nil, to out: URL) {
    let view = SettingsRootView()
        .perchEnvironment(env)
        .environment(\.perchStaticRendering, true)
        .environment(\.perchPipelineFreeze, freeze)
    Snapshot.write(view, name: name, size: size, to: out, background: .black)
}

private var settingsChecksFailed = 0

private func settingsCheck(_ condition: Bool, _ what: String) {
    if condition {
        print("check ok: \(what)")
    } else {
        settingsChecksFailed += 1
        print("CHECK FAILED: \(what)")
    }
}

// MARK: - Pictures

@MainActor
private func snapshotPages(_ out: URL) {
    for (index, page) in SettingsPageID.allCases.enumerated() {
        let number = String(format: "%02d", index + 1)
        writeSettings(makeSettingsEnv(page.tab), name: "page-\(number)-\(page.rawValue)", to: out)
        writeSettings(makeSettingsEnv(page.tab) { $0.settings.theme = .ember }, name: "ember-\(number)-\(page.rawValue)",
                      freeze: page == .agents ? PipelineFreeze(progress: 0.62, isReply: false) : nil, to: out)
        writeSettings(makeSettingsEnv(page.tab) { $0.settings.textScale = 1.3 }, name: "text-130-\(number)-\(page.rawValue)", to: out)
    }
}

@MainActor
private func snapshotWelcome(_ out: URL) {
    // Claude Code found but not connected yet: the usual first launch.
    writeSettings(makeSettingsEnv(.general, welcome: true) { env in
        env.agents.statuses[0].hookStatus = .notInstalled
        env.agents.statuses[0].detail = "Found. Click Connect to add Perch's hooks."
    }, name: "welcome-01-first-run", to: out)
    writeSettings(makeSettingsEnv(.general, welcome: true), name: "welcome-02-already-connected", to: out)
    writeSettings(makeSettingsEnv(.general, welcome: true) { env in
        env.agents.statuses[0] = AgentStatus(agent: .claude, detected: false, version: nil, configPath: nil,
                                             hookStatus: .notDetected, capabilities: env.agents.statuses[0].capabilities,
                                             detail: "Not installed on this Mac.")
    }, name: "welcome-03-claude-not-found", to: out)
    writeSettings(makeSettingsEnv(.general, welcome: true) { env in
        env.settings.theme = .ember
        env.settings.textScale = 1.3
        env.settings.mascotStyle = .pixel
    }, name: "welcome-04-ember-large-text", to: out)
    // The smallest window the shell allows: the tighter layout, then the scrolling fallback.
    writeSettings(makeSettingsEnv(.general, welcome: true), name: "welcome-05-smallest-window",
                  size: CGSize(width: 760, height: 520), to: out)
    writeSettings(makeSettingsEnv(.general, welcome: true) { $0.settings.textScale = 1.3 },
                  name: "welcome-06-smallest-window-large-text", size: CGSize(width: 760, height: 520), to: out)
}

@MainActor
private func snapshotStates(_ out: URL) {
    writeSettings(makeSettingsEnv(.general) { env in
        env.settings.expandTrigger = .click
        env.settings.hideWhenNoSessions = true
    }, name: "state-general-click", to: out)

    writeSettings(makeSettingsEnv(.appearance) { env in
        env.settings.showMascot = false
        env.settings.showGlow = false
        env.settings.showParticles = false
        env.settings.reduceMotion = true
        env.settings.showUsageInPill = false
    }, name: "state-look-plain", to: out)

    writeSettings(makeSettingsEnv(.sounds) { env in
        env.settings.soundsEnabled = false
    }, name: "state-sounds-off", to: out)

    writeSettings(makeSettingsEnv(.approvals) { env in
        env.settings.quietHoursEnabled = true
        env.settings.soundPack = .arcade
        env.settings.autoAllowReadOnly = true
        env.settings.approvalsInNotch = false
        env.settings.questionsInNotch = false
        env.settings.planReviewInNotch = false
    }, name: "state-sounds-quiet-hours-auto-allow", to: out)

    writeSettings(makeSettingsEnv(.agents) { env in
        env.agents.serverRunning = false
        env.agents.helperInstalled = false
        env.agents.lastMessage = "Could not update ~/.codex/config.toml: the file is not valid TOML (line 14). Nothing was changed."
        env.agents.statuses[0].hookStatus = .needsUpdate
        env.agents.statuses[0].detail = "Connected, but 3 of Perch's hooks point at an older helper. Click Update."
        env.agents.statuses[1].hookStatus = .error
        env.agents.statuses[1].detail = "The settings file could not be read: it is not valid TOML (line 14)."
        env.settings.geminiEnabled = false
    }, name: "state-agents-trouble", size: CGSize(width: 860, height: 700), to: out)

    writeSettings(makeSettingsEnv(.agents) { env in
        env.agents.statuses = []
    }, name: "state-agents-none", size: CGSize(width: 860, height: 700), to: out)

    writeSettings(makeSettingsEnv(.agents) { env in
        env.agents.lastMessage = "Connected Claude Code: added 12 hooks to ~/.claude/settings.json. A backup was saved first."
    }, name: "state-agents-message", to: out)

    writeSettings(makeSettingsEnv(.howItWorks), name: "state-how-incoming", freeze: PipelineFreeze(progress: 0.62, isReply: false), to: out)
    writeSettings(makeSettingsEnv(.howItWorks) { env in
        env.sessions.activity.insert(ActivityEntry(at: Date(), direction: .outgoing, agent: "claude", event: "Decision",
                                                   sessionID: nil, summary: "You allowed `scripts/test.sh Engine`", raw: ""), at: 0)
    }, name: "state-how-reply", freeze: PipelineFreeze(progress: 0.3, isReply: true), to: out)

    writeSettings(makeSettingsEnv(.advanced) { env in
        env.ui.isDemo = true
    }, name: "state-demo-on", to: out)

    // What "Uninstall Perch…" shows in place of the page's sections, and the "are you sure?"
    // state of ConfirmButton, each on its own.
    let env = makeSettingsEnv(.advanced)
    let uninstall = VStack(alignment: .leading, spacing: 16) {
        SettingsUninstallPanel {}
    }
    .padding(24)
    .perchEnvironment(env)
    Snapshot.write(uninstall, name: "state-uninstall-panel", size: CGSize(width: 663, height: 400), to: out, background: .black)

    let confirm = VStack(alignment: .trailing, spacing: 16) {
        ConfirmButton("Reset settings\u{2026}", confirmTitle: "Yes, reset every setting", isDestructive: false) {}
        ConfirmButton("Reset settings\u{2026}", confirmTitle: "Yes, reset every setting", isDestructive: false, startsAsking: true) {}
        ConfirmButton("Uninstall\u{2026}", systemImage: "trash", confirmTitle: "Yes, remove everything and quit", startsAsking: true) {}
    }
    .padding(24)
    .perchEnvironment(env)
    Snapshot.write(confirm, name: "state-confirm-button", size: CGSize(width: 420, height: 160), to: out, background: .black)
}

@MainActor
private func snapshotVariations(_ out: URL) {
    for theme in ThemeID.allCases where theme != .midnight && theme != .ember {
        writeSettings(makeSettingsEnv(.appearance) { $0.settings.theme = theme }, name: "theme-\(theme.rawValue)-look", to: out)
    }
    writeSettings(makeSettingsEnv(.sounds) { $0.settings.theme = .mono }, name: "theme-mono-sounds", to: out)
    writeSettings(makeSettingsEnv(.agents) { $0.settings.textScale = 1.3 }, name: "text-130-agents-whole-page",
                  size: CGSize(width: 860, height: 900), to: out)
    writeSettings(makeSettingsEnv(.sounds) { $0.settings.textScale = 0.85 }, name: "text-085-sounds", to: out)
    // The smallest size the shell allows, and a generously wide window.
    writeSettings(makeSettingsEnv(.sounds), name: "size-min-760x520-sounds", size: CGSize(width: 760, height: 520), to: out)
    writeSettings(makeSettingsEnv(.agents), name: "size-min-760x520-agents", size: CGSize(width: 760, height: 520), to: out)
    writeSettings(makeSettingsEnv(.general), name: "size-wide-1280x800-general", size: CGSize(width: 1280, height: 800), to: out)
}

// MARK: - Checks

/// The settings the window is meant to offer. Everything else in AppSettings keeps its default
/// and is deliberately not shown; add a name here when a control for it is added to a page.
private let exposedSettings: [String] = [
    // General
    "launchAtLogin", "showMenuBarIcon", "expandTrigger", "autoExpandOnAttention", "hideWhenNoSessions",
    // Look ("Animations" drives showGlow, showParticles and reduceMotion together)
    "theme", "showMascot", "mascotStyle", "textScale", "showGlow", "showParticles", "reduceMotion",
    "showUsageInPill", "pillMetric",
    // Sounds & approvals ("Approve from the notch" drives the three …InNotch settings together)
    "soundsEnabled", "volume", "soundPack", "quietHoursEnabled", "quietStartHour", "quietEndHour",
    "approvalsInNotch", "questionsInNotch", "planReviewInNotch", "confirmDangerous", "autoAllowReadOnly",
    // Agents & help (the four switches are reached through setEnabled / isEnabled, not by name)
    "claudeEnabled", "codexEnabled", "antigravityEnabled", "geminiEnabled",
]

/// Every setting on the list must be used in the Settings sources, and nothing off the list may be.
@MainActor
private func checkExposedSettings() {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PERCH_ROOT"] ?? FileManager.default.currentDirectoryPath)
    let folder = root.appendingPathComponent("Sources/App/Settings")
    var source = ""
    if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
        for case let url as URL in files where url.pathExtension == "swift" {
            source += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }
    settingsCheck(!source.isEmpty, "the Settings sources can be read for the coverage check")

    // @Published properties show up in a Mirror with a leading underscore.
    let names = Mirror(reflecting: AppSettings(defaults: SettingsSnapshotDefaults())).children
        .compactMap { $0.label }
        .filter { $0.hasPrefix("_") }
        .map { String($0.dropFirst()) }
    settingsCheck(names.count >= 70, "AppSettings still lists all its properties (\(names.count) found)")

    let unknown = exposedSettings.filter { !names.contains($0) }
    settingsCheck(unknown.isEmpty, "every setting on the exposed list exists in AppSettings"
        + (unknown.isEmpty ? "" : " — unknown: \(unknown.joined(separator: ", "))"))

    /// True when `settings.<name>` appears as a whole word (so `showGlow` does not count for `show`).
    func isUsed(_ name: String) -> Bool {
        source.range(of: "settings\\.\(name)\\b", options: .regularExpression) != nil
    }
    let viaAgent: Set<String> = ["claudeEnabled", "codexEnabled", "antigravityEnabled", "geminiEnabled"]
    let agentSwitchesUsed = source.contains("settings.setEnabled(") && source.contains("settings.isEnabled(")
    let missing = exposedSettings.filter { viaAgent.contains($0) ? !agentSwitchesUsed : !isUsed($0) }
    settingsCheck(missing.isEmpty, "every setting the window is meant to offer is used in Settings"
        + (missing.isEmpty ? "" : " — missing: \(missing.joined(separator: ", "))"))

    // The welcome panel's own flag is the one setting used here without being a control.
    let extra = names.filter { !exposedSettings.contains($0) && $0 != "hasCompletedOnboarding" && isUsed($0) }
    settingsCheck(extra.isEmpty, "no setting outside the exposed list has crept back into Settings"
        + (extra.isEmpty ? "" : " — found: \(extra.joined(separator: ", "))"))
    settingsCheck(exposedSettings.count <= 30, "the window offers a short list of settings (\(exposedSettings.count))")

    checkSymbolsExist(in: source)
}

/// The window has four pages; each of the nine tabs the rest of the app can ask for opens one.
private func checkTabRouting() {
    let pages = SettingsPageID.allCases
    settingsCheck(pages.count == 4, "there are four pages")
    settingsCheck(Set(pages.map { $0.title }).count == 4, "every page has its own name")
    settingsCheck(pages.allSatisfy { NSImage(systemSymbolName: $0.systemImage, accessibilityDescription: nil) != nil },
                  "every page icon is a real SF Symbol")
    settingsCheck(pages.allSatisfy { SettingsPageID($0.tab) == $0 }, "the tab a sidebar entry selects opens that entry's page")

    let wanted: [SettingsTab: SettingsPageID] = [
        .general: .general, .behavior: .general,
        .appearance: .look,
        .sounds: .sounds, .approvals: .sounds,
        .agents: .agents, .usage: .agents, .howItWorks: .agents, .advanced: .agents,
    ]
    let wrong = SettingsTab.allCases.filter { wanted[$0] != SettingsPageID($0) }
    settingsCheck(wrong.isEmpty, "every SettingsTab opens the nearest page"
        + (wrong.isEmpty ? "" : " — wrong: \(wrong.map { $0.rawValue }.joined(separator: ", "))"))
}

/// SF Symbol names that are misspelt draw nothing at all, which is easy to miss in a picture.
private func checkSymbolsExist(in source: String) {
    var unknown = Set<String>()
    // Names appear as `systemImage: "…"`, `systemName: "…"`, or the bare third argument of a few helpers.
    let pattern = #"(?:systemImage|systemName):\s*(?:[A-Za-z.() ?!=]*\?\s*)?"([a-z0-9.]+)"(?:\s*:\s*"([a-z0-9.]+)")?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    let text = source as NSString
    for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
        for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
            let name = text.substring(with: match.range(at: group))
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil { unknown.insert(name) }
        }
    }
    settingsCheck(unknown.isEmpty, "every SF Symbol named in Settings exists"
        + (unknown.isEmpty ? "" : " — unknown: \(unknown.sorted().joined(separator: ", "))"))
}

private func checkControlLogic() {
    // Slider: fractions, snapping and pointer positions.
    settingsCheck(SliderMath.fraction(of: 0.6, in: 0...1) == 0.6, "slider fraction in the middle")
    settingsCheck(SliderMath.fraction(of: -5, in: 0...1) == 0 && SliderMath.fraction(of: 9, in: 0...1) == 1, "slider fraction is clamped")
    settingsCheck(SliderMath.fraction(of: .nan, in: 0...1) == 0, "slider fraction survives not-a-number")
    settingsCheck(SliderMath.fraction(of: 3, in: 3...3) == 0, "slider fraction survives an empty range")
    settingsCheck(SliderMath.snapped(0.37, range: 0...1, step: 0.05) == 0.35, "slider snaps to the step")
    settingsCheck(SliderMath.snapped(0.1 + 0.2, range: 0...1, step: 0.05) == 0.3, "slider tidies floating-point dust")
    settingsCheck(SliderMath.snapped(999, range: 420...760, step: 10) == 760, "slider snap is clamped to the range")
    settingsCheck(SliderMath.snapped(.infinity, range: 0...1, step: 0.1) == 0, "slider snap survives infinity")
    settingsCheck(SliderMath.snapped(0.42, range: 0...1, step: 0) == 0.42, "slider with no step keeps the value")
    settingsCheck(SliderMath.value(atX: -40, width: 168, knob: 16, range: 0...1, step: 0.05) == 0, "dragging past the left end gives the minimum")
    settingsCheck(SliderMath.value(atX: 400, width: 168, knob: 16, range: 0...1, step: 0.05) == 1, "dragging past the right end gives the maximum")
    settingsCheck(SliderMath.value(atX: 84, width: 168, knob: 16, range: 0...1, step: 0.05) == 0.5, "the middle of the slider is the middle value")

    // Wording of values.
    settingsCheck(SettingsFormat.percent(fraction: 0.6) == "60%" && SettingsFormat.percent(fraction: 1.3) == "130%", "percent wording")
    settingsCheck(SettingsFormat.wrappedHour(24) == 0 && SettingsFormat.wrappedHour(-1) == 23 && SettingsFormat.wrappedHour(49) == 1,
                  "hours wrap around midnight")
    settingsCheck(!SettingsFormat.hour(22).isEmpty && SettingsFormat.hour(22) != SettingsFormat.hour(8), "hours are written out")

    // Words for agents, and the explainer.
    let allStatuses: [HookStatus] = [.notDetected, .notInstalled, .installed, .needsUpdate, .error]
    settingsCheck(Set(allStatuses.map(SettingsAgentWording.statusWords)).count == 5, "every hook state has its own words")
    settingsCheck(HowItWorksAnswers.all.count >= 3 && HowItWorksAnswers.all.count <= 4, "the explainer has three or four answers")
    settingsCheck(HowItWorksAnswers.all.allSatisfy { $0.answer.count <= 140 }, "every answer in the explainer is short")
}

// MARK: - Live behaviour checks

/// A view in a real window that the user never sees (fully transparent and far off-screen), so
/// time can pass, frames can be compared and mouse clicks can be delivered. Unlike the PNG
/// renderer this uses the real scroll view. Clicks are handed straight to the window: the real
/// pointer, the keyboard focus and other apps are not involved.
@MainActor
private final class LiveWindow {
    let env: AppEnv
    private let host: NSHostingView<AnyView>
    private let window: NSWindow

    init<Content: View>(_ env: AppEnv, size: CGSize = windowSize, content: Content) {
        self.env = env
        host = NSHostingView(rootView: AnyView(content.perchEnvironment(env)))
        // Sizing is left at its defaults on purpose: the hosting view may then resize the window
        // to suit the content, which is how a tab that asks for too much room would show up.
        host.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
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

    /// The size the hosting view has now, in points.
    var size: CGSize { host.frame.size }

    // Mouse events. Points are measured from the window's top-left corner.

    func press(_ point: CGPoint) {
        send(.leftMouseDown, point)
        wait(0.05)
    }

    func drag(to point: CGPoint) {
        send(.leftMouseDragged, point)
        wait(0.03)
    }

    func release(_ point: CGPoint) {
        send(.leftMouseUp, point)
        wait(0.25)
    }

    func click(_ point: CGPoint) {
        press(point)
        release(point)
    }

    func click(x: CGFloat, y: CGFloat) { click(CGPoint(x: x, y: y)) }

    private func send(_ type: NSEvent.EventType, _ point: CGPoint) {
        let location = NSPoint(x: point.x, y: host.bounds.height - point.y)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        window.sendEvent(event)
    }

    /// Adds a line to the activity log the way the engine does: newest first.
    func log(_ direction: ActivityEntry.Direction, _ summary: String) {
        env.sessions.activity.insert(ActivityEntry(at: Date().addingTimeInterval(-7200), direction: direction, agent: "claude",
                                                   event: direction == .outgoing ? "Decision" : "PreToolUse",
                                                   sessionID: nil, summary: summary, raw: ""), at: 0)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

/// Writes down every request the views make, so checks can see what a click asked for.
private final class RecordingActions: AppActions {
    var calls: [String] = []
    /// Stands in for the app: demo mode "works", so views that watch `isDemo` can be checked.
    weak var ui: UIState?

    func resolve(_ request: PendingRequest, _ decision: Decision) { calls.append("resolve") }
    func jump(to session: Session) { calls.append("jump") }
    func dismiss(_ session: Session) { calls.append("dismiss") }
    func setExpanded(_ expanded: Bool) { calls.append("setExpanded(\(expanded))") }
    func openSettings(_ tab: SettingsTab?) { calls.append("openSettings") }
    func refreshAgents() { calls.append("refreshAgents") }
    func installHooks(for agent: AgentKind) { calls.append("installHooks(\(agent.rawValue))") }
    func uninstallHooks(for agent: AgentKind) { calls.append("uninstallHooks(\(agent.rawValue))") }
    func refreshUsage() { calls.append("refreshUsage") }
    func clearSavedStats() { calls.append("clearSavedStats") }
    func previewSound(_ cue: SoundCue) { calls.append("previewSound(\(cue.rawValue))") }
    func toggleMute() { calls.append("toggleMute") }
    func setDemo(_ on: Bool) {
        calls.append("setDemo(\(on))")
        ui?.isDemo = on
    }
    func clearActivityLog() { calls.append("clearActivityLog") }
    func copyDiagnostics() { calls.append("copyDiagnostics") }
    func revealSupportFolder() { calls.append("revealSupportFolder") }
    func uninstallEverything() { calls.append("uninstallEverything") }
    func quit() { calls.append("quit") }
}

private func saveFrame(_ image: NSBitmapImageRep?, _ name: String, to out: URL) {
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

/// An environment in which nothing has a reason to move: no sessions, and an old activity line.
@MainActor
private func makeQuietEnv(_ tab: SettingsTab, welcome: Bool = false) -> AppEnv {
    makeSettingsEnv(tab, welcome: welcome) { env in
        env.sessions.sessions = []
        env.sessions.pending = []
        env.sessions.activity = env.sessions.activity.map { entry in
            var old = entry
            old.at = Date().addingTimeInterval(-7200)
            return old
        }
    }
}

@MainActor
private func runLiveSettingsChecks(_ out: URL) {
    checkWindowLive(out)
    checkControlsRespondToClicks()
    checkSidebarAndWelcomeRespondToClicks()
}

// MARK: Live: the whole window

@MainActor
private func checkWindowLive(_ out: URL) {
    let live = LiveWindow(makeQuietEnv(.general), content: SettingsRootView())
    let settings = live.env.settings
    let ui = live.env.ui

    // Every tab draws something of its own in a real window.
    var previous = live.frame()
    saveFrame(previous, "live-01-general", to: out)
    var blank: [String] = []
    var resized: [String] = []
    // Several tabs share a page now, so step through the four pages rather than every tab.
    for tab in SettingsPageID.allCases.dropFirst().map({ $0.tab }) {
        ui.settingsTab = tab
        live.wait(0.2)
        let frame = live.frame()
        if changedPixels(previous, frame) < 2000 { blank.append(tab.rawValue) }
        // A long tab must scroll inside the window, never make the window grow to fit it.
        if live.size != windowSize { resized.append("\(tab.rawValue) \(Int(live.size.width))x\(Int(live.size.height))") }
        previous = frame
    }
    settingsCheck(blank.isEmpty, "live: every tab draws in a real window" + (blank.isEmpty ? "" : " — unchanged: \(blank.joined(separator: ", "))"))
    settingsCheck(resized.isEmpty, "live: no tab makes the window grow" + (resized.isEmpty ? "" : " — resized: \(resized.joined(separator: ", "))"))

    // The diagram: still at rest, moving after an event, still again afterwards.
    ui.settingsTab = .howItWorks
    live.wait(0.4)
    let rest = live.frame()
    saveFrame(rest, "live-02-how-at-rest", to: out)
    live.wait(0.4)
    settingsCheck(changedPixels(rest, live.frame()) == 0, "live: a quiet Settings window does not redraw")

    live.log(.incoming, "Claude is about to run Bash")
    live.wait(0.55)
    let travelling = live.frame()
    saveFrame(travelling, "live-03-how-dot-travelling", to: out)
    live.wait(0.35)
    let further = live.frame()
    settingsCheck(changedPixels(travelling, further) > 30, "live: a new event sends the dot along the diagram")
    live.wait(2.0)
    let arrived = live.frame()
    settingsCheck(changedPixels(travelling, arrived) > 30, "live: the stops stop glowing once the dot has arrived")
    live.wait(0.4)
    settingsCheck(changedPixels(arrived, live.frame()) == 0, "live: the diagram is at rest again afterwards")

    live.log(.outgoing, "You allowed Bash")
    live.wait(0.7)
    let reply = live.frame()
    saveFrame(reply, "live-04-how-reply-travelling", to: out)
    settingsCheck(changedPixels(arrived, reply) > 30, "live: an answer sends the dot back along the lower lane")
    live.wait(2.2)

    live.log(.note, "Hooks installed")
    live.wait(0.5)
    let afterNote = live.frame()
    live.wait(0.3)
    settingsCheck(changedPixels(afterNote, live.frame()) == 0, "live: a note from Perch itself does not send a dot")

    settings.reduceMotion = true
    live.wait(0.3)
    live.log(.incoming, "Claude is about to run Edit")
    live.wait(0.5)
    let calm = live.frame()
    saveFrame(calm, "live-05-how-reduce-motion", to: out)
    live.wait(0.3)
    settingsCheck(changedPixels(calm, live.frame()) == 0, "live: with Reduce motion on nothing travels (the stops only glow)")
    live.wait(2.0)
    settingsCheck(changedPixels(calm, live.frame()) > 30, "live: with Reduce motion on the glow still fades away")
    settings.reduceMotion = false

    // The welcome panel covers the window and leaves again.
    ui.settingsTab = .general
    live.wait(0.4)
    let before = live.frame()
    settings.hasCompletedOnboarding = false
    live.wait(0.6)
    let welcome = live.frame()
    saveFrame(welcome, "live-06-welcome", to: out)
    settingsCheck(changedPixels(before, welcome) > 20_000, "live: the welcome panel covers the window on first run")
    settings.hasCompletedOnboarding = true
    live.wait(0.6)
    settingsCheck(changedPixels(before, live.frame()) == 0, "live: the window is back unchanged once the welcome is dismissed")

    // Picking a theme repaints everything at once.
    settings.theme = .ember
    live.wait(0.4)
    let ember = live.frame()
    saveFrame(ember, "live-07-ember", to: out)
    settingsCheck(changedPixels(before, ember) > 5000, "live: choosing a theme repaints the window")
    live.close()
}

// MARK: Live: the controls

/// Each control sits alone in a row of known size, so clicks can be aimed without guessing.
@MainActor
private func checkControlsRespondToClicks() {
    let env = makeQuietEnv(.general)
    let settings = env.settings
    let actions = RecordingActions()
    env.actions = actions
    let rowHeight: CGFloat = 60
    let width: CGFloat = 400
    var confirmed = 0
    var segment = "a"
    let segmentBinding = Binding<String>(get: { segment }, set: { segment = $0 })

    let bench = VStack(alignment: .leading, spacing: 0) {
        SettingsBenchRow(settings: settings, height: rowHeight)                                              // rows 0...3
        SettingsSegmented([SettingsOption("a", "AAAA"), SettingsOption("b", "BBBB"), SettingsOption("c", "CCCC")],
                          selection: segmentBinding)
            .frame(width: width, height: rowHeight, alignment: .leading)                                     // row 4
        ConfirmButton("Reset\u{2026}", confirmTitle: "Yes, reset every setting") { confirmed += 1 }
            .frame(width: width, height: rowHeight, alignment: .leading)                                     // row 5
    }
    .frame(width: width, height: rowHeight * 6, alignment: .topLeading)
    .background(Color.black)
    let live = LiveWindow(env, size: CGSize(width: width, height: rowHeight * 6), content: bench)
    func y(_ row: Int) -> CGFloat { rowHeight * (CGFloat(row) + 0.5) }

    // Row 0: a switch row. The whole row is the target, and so is the switch itself.
    settings.showGlow = true
    live.click(x: 120, y: y(0))
    settingsCheck(settings.showGlow == false, "click: clicking a row's text flips its switch")
    live.click(x: width - 16, y: y(0))
    settingsCheck(settings.showGlow == true, "click: clicking the switch itself flips it once, not twice")

    // Row 1: a bare slider, 150 points wide, at the left edge.
    settings.volume = 0
    live.click(x: 75, y: y(1))
    settingsCheck(settings.volume == 0.5, "click: clicking the middle of a slider jumps to the middle value (got \(settings.volume))")
    live.press(CGPoint(x: 75, y: y(1)))
    for x in stride(from: 85, through: 180, by: 19) { live.drag(to: CGPoint(x: CGFloat(x), y: y(1))) }
    settingsCheck(settings.volume == 1, "click: dragging a slider changes the setting while it moves")
    live.release(CGPoint(x: 180, y: y(1)))
    settingsCheck(settings.volume == 1, "click: dragging past the end stops at the maximum")

    // Row 2: the text-size row applies when the knob is let go. Its slider sits right of the text.
    settings.textScale = 1
    let sliderLeft = width - Theme.current(settings).scaled(62) - Theme.Spacing.m - 150
    live.press(CGPoint(x: sliderLeft + 75, y: y(2)))
    for step in 1...5 { live.drag(to: CGPoint(x: sliderLeft + 75 + CGFloat(step) * 16, y: y(2))) }
    settingsCheck(settings.textScale == 1, "click: the text size does not change while its slider is being dragged")
    live.release(CGPoint(x: sliderLeft + 155, y: y(2)))
    settingsCheck(settings.textScale == 1.3, "click: the text size changes when the slider is let go (got \(settings.textScale))")
    settings.textScale = 1
    live.wait(0.2)

    // Row 3: the hour stepper. Minus is the first button, plus the last.
    settings.quietStartHour = 0
    live.click(x: 13, y: y(3))
    settingsCheck(settings.quietStartHour == 23, "click: one hour earlier than midnight is 11 PM")
    live.click(x: 103, y: y(3))
    settingsCheck(settings.quietStartHour == 0, "click: one hour later brings midnight back")

    // Row 4: the segmented picker. Sweep across it; the choices must come up in order.
    var seen = [segment]
    for x in stride(from: 6, through: 220, by: 8) {
        live.click(x: CGFloat(x), y: y(4))
        if seen.last != segment { seen.append(segment) }
    }
    settingsCheck(seen == ["a", "b", "c"], "click: each segment of a picker selects its own choice (saw \(seen))")

    // Row 5: the two-step button. One click only asks; a hurried second click does nothing;
    // Cancel backs out; a deliberate click on the confirmation acts. Here the control is
    // left-aligned, so the confirmation starts at the left edge and Cancel follows it.
    live.click(x: 15, y: y(5))
    settingsCheck(confirmed == 0, "click: the first click on a dangerous button only asks")
    live.click(x: 15, y: y(5))
    settingsCheck(confirmed == 0, "click: a hurried second click cannot confirm")
    live.wait(0.6)
    live.click(x: 195, y: y(5))
    live.wait(0.5)
    live.click(x: 100, y: y(5))
    settingsCheck(confirmed == 0, "click: Cancel backs out without doing anything")
    live.click(x: 15, y: y(5))
    live.wait(0.7)
    live.click(x: 100, y: y(5))
    settingsCheck(confirmed == 1, "click: a deliberate click on the confirmation does it")
    live.wait(0.5)
    live.click(x: 100, y: y(5))
    settingsCheck(confirmed == 1, "click: and only once")
    live.close()

    settings.panelWidth = 700
    settings.soundsEnabled = false
    settings.theme = .forest
    settings.resetToDefaults()
    settingsCheck(settings.theme == .midnight && settings.panelWidth == 400 && settings.soundsEnabled,
                  "reset puts settings back to their defaults")
}

/// Rows 0 to 3 of the control bench: they need bindings into the settings, so they live in a view.
private struct SettingsBenchRow: View {
    @ObservedObject var settings: AppSettings
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsToggleRow("Glow", subtitle: "A test row.", systemImage: "sun.max.fill", isOn: $settings.showGlow)
                .frame(width: 400, height: height)
            SettingsSlider(value: $settings.volume, range: 0...1, step: 0.05)
                .frame(width: 400, height: height, alignment: .leading)
            SettingsSliderRow("Text", value: $settings.textScale, range: 0.85...1.3, step: 0.05, appliesOnRelease: true,
                              format: SettingsFormat.percent(fraction:))
                .frame(width: 400, height: height)
            SettingsHourStepper(hour: $settings.quietStartHour)
                .frame(width: 400, height: height, alignment: .leading)
        }
    }
}

// MARK: Live: sidebar and welcome

@MainActor
private func checkSidebarAndWelcomeRespondToClicks() {
    // Sweep down the sidebar: the tabs must be selected one after another, top to bottom.
    do {
        let live = LiveWindow(makeQuietEnv(.agents), content: SettingsRootView())
        var seen: [SettingsTab] = []
        for y in stride(from: 70, through: 420, by: 7) {
            live.press(CGPoint(x: 80, y: CGFloat(y)))
            live.release(CGPoint(x: 80, y: CGFloat(y)))
            if seen.last != live.env.ui.settingsTab { seen.append(live.env.ui.settingsTab) }
        }
        settingsCheck(seen == SettingsPageID.allCases.map { $0.tab }, "click: every sidebar entry opens its page, in order (saw \(seen.map { $0.rawValue }))")
        live.close()
    }

    // The welcome panel's two main buttons sit side by side; sweep down through each.
    func sweepWelcome(x: CGFloat, configure: (AppEnv) -> Void = { _ in }) -> (env: AppEnv, calls: [String]) {
        let env = makeQuietEnv(.general, welcome: true)
        configure(env)
        let actions = RecordingActions()
        actions.ui = env.ui
        env.actions = actions
        let live = LiveWindow(env, content: SettingsRootView())
        for y in stride(from: 300, through: 560, by: 8) where !env.settings.hasCompletedOnboarding {
            live.click(x: x, y: CGFloat(y))
        }
        live.close()
        return (env, actions.calls)
    }

    let connect = sweepWelcome(x: 300) { env in
        env.agents.statuses[0].hookStatus = .notInstalled
    }
    settingsCheck(connect.calls == ["installHooks(claude)"], "click: Connect Claude Code asks the app to install Claude's hooks (asked: \(connect.calls))")
    settingsCheck(connect.env.settings.hasCompletedOnboarding && connect.env.ui.settingsTab == .agents,
                  "click: connecting ends the welcome and lands on the Agents tab")

    let started = sweepWelcome(x: 300)
    settingsCheck(started.calls.isEmpty && started.env.settings.hasCompletedOnboarding && started.env.ui.settingsTab == .general,
                  "click: with Claude Code already connected, Get started just ends the welcome")

    let demo = sweepWelcome(x: 560)
    settingsCheck(demo.calls == ["setDemo(true)"] && demo.env.ui.isDemo, "click: Try the demo turns demo mode on (asked: \(demo.calls))")
    settingsCheck(demo.env.settings.hasCompletedOnboarding, "click: trying the demo ends the welcome")

    // Nothing under the welcome panel can be changed through it.
    do {
        let env = makeQuietEnv(.general, welcome: true)
        let live = LiveWindow(env, content: SettingsRootView())
        let before = env.settings.launchAtLogin
        live.click(x: 806, y: 124)   // where the first switch of General is
        live.click(x: 20, y: 20)     // a corner of the dimmed backdrop
        settingsCheck(env.settings.launchAtLogin == before && !env.settings.hasCompletedOnboarding,
                      "click: the welcome's backdrop swallows clicks and does not dismiss it")
        live.close()
    }
}
