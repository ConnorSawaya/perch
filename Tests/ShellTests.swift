// ShellTests.swift — checks the window shell's rules: where the island goes, which clicks it
// takes, when it opens and closes, and what the keyboard shortcuts may do.
//
// Everything tested here is pure logic (plus a few things that can be built without being shown:
// the menu-bar icon picture, the Settings window and the notch panel). Nothing appears on screen
// while this runs; the real panel is exercised separately by the throwaway harness under
// .build/shell-harness.
//
// Run with: scripts/test.sh Shell Sources/App/Shell

import Foundation
import AppKit
import SwiftUI

// MARK: - Fixtures

/// The 14-inch MacBook Pro this was built on: 1512 x 982 points, notch 185 x 32, menu bar 33.
private let builtin = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                 visibleFrame: CGRect(x: 0, y: 90, width: 1512, height: 859), safeAreaTop: 32,
                                 topLeftArea: CGRect(x: 0, y: 950, width: 665, height: 32),
                                 topRightArea: CGRect(x: 850, y: 950, width: 662, height: 32),
                                 isBuiltin: true, hasMenuBar: true)

/// An ordinary monitor to the right of it: 1920 x 1080, no notch, 24-point menu bar.
private let external = ScreenInfo(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1056),
                                  isBuiltin: false, hasMenuBar: false)

private let windowSize = IslandMetrics.windowSize

/// Preferences that live only in memory. AppSettings saves every change it is given; with this
/// behind it, nothing is ever written to ~/Library/Preferences.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

/// Runs `body` with a fresh set of default settings that can be changed freely.
private func withSettings(_ body: (AppSettings) throws -> Void) rethrows {
    try body(AppSettings(defaults: MemoryDefaults()))
}

private func permission(dangerous: Bool = false, age: TimeInterval = 10, session: String = "s1") -> PendingRequest {
    PendingRequest(sessionID: Session.makeID(.claude, session), agent: .claude,
                   kind: .permission(PermissionRequest(toolName: "Bash", summary: "Run a shell command", detail: "ls",
                                                       isDangerous: dangerous)),
                   createdAt: Date().addingTimeInterval(-age), raw: .null)
}

private func question(options: Int = 3, multiSelect: Bool = false, questions: Int = 1, age: TimeInterval = 10) -> PendingRequest {
    let list = (0..<questions).map { q in
        Question(id: q, text: "Question \(q)?", header: nil,
                 options: (0..<options).map { QuestionOption(id: $0, label: "Option \($0 + 1)", detail: nil) },
                 multiSelect: multiSelect)
    }
    return PendingRequest(sessionID: Session.makeID(.claude, "s2"), agent: .claude, kind: .question(QuestionRequest(questions: list)),
                          createdAt: Date().addingTimeInterval(-age), raw: .null)
}

private func plan(age: TimeInterval = 10) -> PendingRequest {
    PendingRequest(sessionID: Session.makeID(.claude, "s3"), agent: .claude, kind: .plan(PlanRequest(markdown: "# Plan", filePath: nil)),
                   createdAt: Date().addingTimeInterval(-age), raw: .null)
}

private func cmd(_ characters: String, keyCode: UInt16 = 0, isRepeat: Bool = false) -> KeyStroke {
    KeyStroke(keyCode: keyCode, characters: characters, command: true, isRepeat: isRepeat)
}

/// Stands in for the app controller: records what was asked and, like the real one, applies it.
private final class SpyActions: AppActions {
    let ui: UIState
    var setExpandedCalls: [Bool] = []
    var resolved: [(request: PendingRequest, decision: Decision)] = []
    var settingsOpened = 0
    var muteToggles = 0
    var demoCalls: [Bool] = []
    var quits = 0
    init(ui: UIState) { self.ui = ui }
    func setExpanded(_ expanded: Bool) {
        setExpandedCalls.append(expanded)
        ui.isExpanded = expanded
    }
    func resolve(_ request: PendingRequest, _ decision: Decision) { resolved.append((request, decision)) }
    func openSettings(_ tab: SettingsTab?) { settingsOpened += 1 }
    func toggleMute() { muteToggles += 1 }
    func setDemo(_ on: Bool) { demoCalls.append(on) }
    func quit() { quits += 1 }
    func jump(to session: Session) {}
    func dismiss(_ session: Session) {}
    func refreshAgents() {}
    func installHooks(for agent: AgentKind) {}
    func uninstallHooks(for agent: AgentKind) {}
    func refreshUsage() {}
    func clearSavedStats() {}
    func previewSound(_ cue: SoundCue) {}
    func clearActivityLog() {}
    func copyDiagnostics() {}
    func revealSupportFolder() {}
    func uninstallEverything() {}
}

// MARK: - Tests

func runShellTests(_ t: TestRunner) {
    screenGeometryTests(t)
    screenPickerTests(t)
    fullScreenTests(t)
    hoverMachineTests(t)
    watcherTests(t)
    shortcutTests(t)
    shortcutMonitorTests(t)
    statusMenuTests(t)
    appKitPieceTests(t)
}

private func screenGeometryTests(_ t: TestRunner) {
    t.test("the notch is measured from the strips on either side of it") {
        t.expectEqual(builtin.notchRect, CGRect(x: 665, y: 950, width: 185, height: 32))
        t.expectNil(external.notchRect, "no safe-area inset means no notch")
        t.expectEqual(builtin.menuBarHeight, 33)
        t.expectEqual(external.menuBarHeight, 24)
    }

    t.test("a notch without side strips falls back to the usual size, centred") {
        var odd = builtin
        odd.topLeftArea = nil
        odd.topRightArea = nil
        let notch = try t.unwrap(odd.notchRect)
        t.expectEqual(notch.width, 185)
        t.expectEqual(notch.midX, 756)
        t.expectEqual(notch.height, 32)
    }

    t.test("the window hangs from the top of the screen, centred on the notch") {
        let placement = IslandPlacement(screen: builtin, windowSize: windowSize)
        t.expect(placement.hasNotch)
        t.expectEqual(placement.notchSize, CGSize(width: 185, height: 32))
        // The notch on this Mac is 1.5 points right of the screen's centre (757.5, not 756). The
        // window follows it as closely as whole points allow.
        t.expectEqual(placement.windowFrame, CGRect(x: 337, y: 222, width: 840, height: 760))
        t.expectEqual(placement.windowFrame.maxY, builtin.frame.maxY, "top edge is the top of the display")
        t.expect(abs(placement.windowFrame.midX - 757.5) <= 0.5, "centred on the notch to within half a point")
    }

    t.test("a display without a notch gets a zero-width stand-in as tall as its menu bar") {
        let placement = IslandPlacement(screen: external, windowSize: windowSize)
        t.expect(!placement.hasNotch)
        t.expectEqual(placement.notchSize, CGSize(width: 0, height: 24))
        t.expectEqual(placement.windowFrame, CGRect(x: 1512 + 960 - 420, y: 1080 - 760, width: 840, height: 760))
        t.expectEqual(IslandPlacement.standInHeight(menuBarHeight: 0), 28, "hidden menu bar")
        t.expectEqual(IslandPlacement.standInHeight(menuBarHeight: 44), 32, "clamped")
        t.expectEqual(IslandPlacement.standInHeight(menuBarHeight: 10), 24, "clamped")
    }

    t.test("the window never hangs off a small display, and sits on whole points") {
        var small = external
        small.frame = CGRect(x: 0, y: 0, width: 1281, height: 700)
        small.visibleFrame = small.frame
        let placement = IslandPlacement(screen: small, windowSize: windowSize)
        t.expectEqual(placement.windowFrame.height, 700)
        t.expectEqual(placement.windowFrame.maxY, 700)
        // Centre 640.5 - 420 = 220.5: macOS cannot place a window there, so it becomes 220.
        t.expectEqual(placement.windowFrame.minX, 220)

        // With a menu bar and a Dock the window stops short of them: on macOS 26 a transparent
        // window as tall as the whole screen can stop being drawn.
        small.visibleFrame = CGRect(x: 0, y: 70, width: 1281, height: 606)
        t.expectEqual(small.usableHeight, 606)
        let shorter = IslandPlacement(screen: small, windowSize: windowSize)
        t.expectEqual(shorter.windowFrame.height, 606)
        t.expectEqual(shorter.windowFrame.maxY, 700, "still hanging from the very top")
        t.expectEqual(builtin.usableHeight, 859)
        t.expectEqual(IslandPlacement(screen: builtin, windowSize: windowSize).windowFrame.height, windowSize.height,
                      "a display with room to spare gets the full fixed size")
        var unknown = small
        unknown.visibleFrame = .zero
        t.expectEqual(unknown.usableHeight, 700, "no usable-area information: fall back to the whole display")
    }

    t.test("window space (top-left origin) converts to screen space (bottom-left origin)") {
        let placement = IslandPlacement(screen: builtin, windowSize: windowSize)
        let rect = placement.screenRect(fromWindowRect: CGRect(x: 160, y: 0, width: 520, height: 220))
        t.expectEqual(rect, CGRect(x: 497, y: 762, width: 520, height: 220))
        let lower = placement.screenRect(fromWindowRect: CGRect(x: 0, y: 700, width: 10, height: 60))
        t.expectEqual(lower.minY, placement.windowFrame.minY, "the bottom of the window is the bottom of the rect")
    }

    t.test("pointer zones follow the sizes the views draw at") {
        withSettings { settings in
            let ui = UIState()
            let placement = IslandPlacement(screen: builtin, windowSize: windowSize)
            func zones() -> IslandZones {
                let pill = IslandMetrics.pillSize(ui: ui, settings: settings)
                return IslandZones(placement: placement,
                                   pillRect: CGRect(x: (windowSize.width - pill.width) / 2, y: 0, width: pill.width, height: pill.height),
                                   islandRect: IslandMetrics.islandRect(ui: ui, settings: settings))
            }

            // Collapsed, detailed pill: 84-point wings either side of the 185-point notch.
            t.expectEqual(zones().pill, CGRect(x: 580.5, y: 950, width: 353, height: 32))
            t.expectEqual(zones().island, zones().pill)
            t.expectEqual(zones().hit(CGPoint(x: 600, y: 970)), IslandZones.Hit(onPill: true, onIsland: true, nearIsland: true))
            t.expectEqual(zones().hit(CGPoint(x: 757, y: 982)).onIsland, true, "the very top edge of the screen counts")
            t.expectEqual(zones().hit(CGPoint(x: 578, y: 970)).onIsland, true, "within the 4-point slop")
            t.expectEqual(zones().hit(CGPoint(x: 576, y: 970)).onIsland, false, "just past the slop: click passes through")
            t.expectEqual(zones().hit(CGPoint(x: 600, y: 942)), IslandZones.Hit(onPill: false, onIsland: false, nearIsland: true))
            t.expectEqual(zones().hit(CGPoint(x: 300, y: 500)), IslandZones.Hit())

            settings.pillStyle = .compact
            t.expectEqual(zones().pill.width, 185 + 44 * 2)

            // Expanded: the default panel is 520 wide and 220 tall until the views ask for more.
            settings.pillStyle = .detailed
            ui.isExpanded = true
            t.expectEqual(zones().island, CGRect(x: 497, y: 762, width: 520, height: 220))
            let inPanel = zones().hit(CGPoint(x: 520, y: 800))
            t.expectEqual(inPanel, IslandZones.Hit(onPill: false, onIsland: true, nearIsland: true))
            t.expectEqual(zones().hit(CGPoint(x: 600, y: 970)).onPill, true, "the pill's footprint is still there inside the panel")
            t.expectEqual(zones().hit(CGPoint(x: 490, y: 800)), IslandZones.Hit(onPill: false, onIsland: false, nearIsland: true))
            t.expectEqual(zones().hit(CGPoint(x: 480, y: 800)).nearIsland, false, "beyond the 12-point leave slop")

            ui.desiredPanelHeight = 400
            settings.panelWidth = 640
            t.expectEqual(zones().island, CGRect(x: 437, y: 582, width: 640, height: 400))
        }
    }
}

private func screenPickerTests(_ t: TestRunner) {
    let both = [builtin, external]

    t.test("the display follows the 'show on' setting") {
        t.expectEqual(ScreenPicker.pick(mode: .builtin, screens: both, focusedScreenID: 2, pointer: nil)?.id, 1)
        t.expectEqual(ScreenPicker.pick(mode: .builtin, screens: [external], focusedScreenID: nil, pointer: nil)?.id, 2,
                      "no built-in display: fall back to the primary one")
        var primaryExternal = external
        primaryExternal.hasMenuBar = true
        var secondaryBuiltin = builtin
        secondaryBuiltin.hasMenuBar = false
        t.expectEqual(ScreenPicker.pick(mode: .main, screens: [secondaryBuiltin, primaryExternal], focusedScreenID: nil, pointer: nil)?.id, 2)
        t.expectEqual(ScreenPicker.pick(mode: .main, screens: both, focusedScreenID: 2, pointer: nil)?.id, 1)
        t.expectNil(ScreenPicker.pick(mode: .builtin, screens: [], focusedScreenID: nil, pointer: nil))
    }

    t.test("follow-focus prefers the focused display, then the one under the pointer") {
        t.expectEqual(ScreenPicker.pick(mode: .followFocus, screens: both, focusedScreenID: 2, pointer: CGPoint(x: 10, y: 10))?.id, 2)
        t.expectEqual(ScreenPicker.pick(mode: .followFocus, screens: both, focusedScreenID: nil, pointer: CGPoint(x: 2000, y: 500))?.id, 2)
        t.expectEqual(ScreenPicker.pick(mode: .followFocus, screens: both, focusedScreenID: 99, pointer: CGPoint(x: 10, y: 10))?.id, 1,
                      "an unknown display id is ignored")
        t.expectEqual(ScreenPicker.pick(mode: .followFocus, screens: both, focusedScreenID: nil, pointer: nil)?.id, 1)
        t.expectEqual(ScreenPicker.pick(mode: .followFocus, screens: both, focusedScreenID: nil, pointer: CGPoint(x: -500, y: -500))?.id, 1,
                      "a pointer that is on no display falls back to the primary one")
    }

    t.test("the 'hide when...' settings decide whether the island is on screen") {
        typealias Input = IslandVisibility.Input
        t.expectEqual(IslandVisibility.verdict(Input(screen: builtin)), .show)
        t.expectEqual(IslandVisibility.verdict(Input(isRequested: false, screen: builtin)), .hide(.notRequested))
        t.expectEqual(IslandVisibility.verdict(Input(screen: nil)), .hide(.noScreen))

        t.expectEqual(IslandVisibility.verdict(Input(screen: external)), .show, "stand-in pill on a display without a notch")
        t.expectEqual(IslandVisibility.verdict(Input(screen: external, showOnNonNotchDisplays: false)), .hide(.noNotch))
        t.expectEqual(IslandVisibility.verdict(Input(screen: builtin, showOnNonNotchDisplays: false)), .show)

        t.expectEqual(IslandVisibility.verdict(Input(screen: builtin, hideWhenNoSessions: true, sessionCount: 0)), .hide(.noSessions))
        t.expectEqual(IslandVisibility.verdict(Input(screen: builtin, hideWhenNoSessions: true, sessionCount: 2)), .show)
        t.expectEqual(IslandVisibility.verdict(Input(screen: builtin, hideWhenNoSessions: true, sessionCount: 0, isExpanded: true)), .show,
                      "a panel the user opened from the menu bar is shown even with no sessions")
        t.expectEqual(IslandVisibility.verdict(Input(screen: builtin, hideWhenNoSessions: false, sessionCount: 0)), .show)

        t.expectEqual(IslandVisibility.verdict(Input(screen: builtin, hideInFullScreen: true, screenIsFullScreen: true)), .hide(.fullScreen))
        t.expectEqual(IslandVisibility.verdict(Input(screen: builtin, hideInFullScreen: false, screenIsFullScreen: true)), .show)
        t.expectEqual(IslandVisibility.verdict(Input(screen: builtin, isExpanded: true, hideInFullScreen: true, screenIsFullScreen: true)),
                      .hide(.fullScreen), "full screen hides even an open panel")
    }
}

private func fullScreenTests(_ t: TestRunner) {
    // Core Graphics coordinates here: origin at the TOP-left, y grows downwards.
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let menuBar = WindowSnapshot(layer: 24, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33), ownerPID: 90)
    let dockOverlay = WindowSnapshot(layer: 20, bounds: screen, ownerPID: 91)
    let statusIcon = WindowSnapshot(layer: 25, bounds: CGRect(x: 1354, y: 0, width: 160, height: 33), ownerPID: 92)
    func app(_ bounds: CGRect, pid: Int32 = 500, alpha: Double = 1) -> WindowSnapshot {
        WindowSnapshot(layer: 0, bounds: bounds, ownerPID: pid, alpha: alpha)
    }
    func isFull(_ windows: [WindowSnapshot], on bounds: CGRect = screen, notch: CGFloat = 32) -> Bool {
        FullScreenDetector.isFullScreen(screenBounds: bounds, safeAreaTop: notch, windows: windows, ownPID: 7)
    }

    t.test("the normal desktop is not full screen") {
        // This is the real window list from the development Mac's desktop.
        t.expect(!isFull([statusIcon, menuBar, dockOverlay, app(CGRect(x: 0, y: 33, width: 860, height: 499))]))
        t.expect(!isFull([menuBar, dockOverlay, app(CGRect(x: 0, y: 33, width: 1512, height: 949))]),
                 "a maximised window under a visible menu bar is still the desktop")
        t.expect(!isFull([menuBar, dockOverlay]))
        t.expect(!isFull([]))
    }

    t.test("a full-screen app is detected, with or without the notch strip covered") {
        t.expect(isFull([dockOverlay, app(CGRect(x: 0, y: 32, width: 1512, height: 950))]), "window below the notch")
        t.expect(isFull([dockOverlay, app(screen)]), "window that also draws behind the notch")
        t.expect(isFull([app(CGRect(x: 0, y: 32, width: 756, height: 950)), app(CGRect(x: 756, y: 32, width: 756, height: 950))]),
                 "split view: two tiles side by side")
    }

    t.test("things that merely look similar do not count as full screen") {
        let covering = app(CGRect(x: 0, y: 32, width: 1512, height: 950))
        t.expect(!isFull([menuBar, covering]), "menu bar is showing (the user revealed it): the island may come back")
        t.expect(!isFull([dockOverlay]), "the Dock's own screen-sized layer is not an app window")
        t.expect(!isFull([app(screen, pid: 7)]), "Perch's own windows never count")
        t.expect(!isFull([app(screen, alpha: 0)]), "an invisible window does not cover anything")
        t.expect(!isFull([app(CGRect(x: 0, y: 32, width: 120, height: 950))]), "a sliver is not a full-screen tile")
        t.expect(!isFull([app(CGRect(x: 0, y: 40, width: 1512, height: 942))]), "starts below the notch strip: not full height")
        t.expect(!isFull([app(CGRect(x: 0, y: 32, width: 1512, height: 900))]), "does not reach the bottom")
        t.expect(!isFull([app(screen)], on: .zero), "a display with no size is never full screen")
    }

    t.test("each display is judged on its own") {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let secondMenuBar = WindowSnapshot(layer: 24, bounds: CGRect(x: 1512, y: 0, width: 1920, height: 24), ownerPID: 90)
        let fullOnSecond = app(second)
        t.expect(isFull([menuBar, fullOnSecond], on: second, notch: 0), "the first display's menu bar says nothing about the second")
        t.expect(!isFull([menuBar, fullOnSecond], on: screen), "and the second display's window does not cover the first")
        t.expect(!isFull([menuBar, secondMenuBar, app(CGRect(x: 1512, y: 24, width: 1920, height: 1056))], on: second, notch: 0))
        t.expect(FullScreenDetector.menuBarIsShowing(on: second, windows: [secondMenuBar]))
        t.expect(!FullScreenDetector.menuBarIsShowing(on: second, windows: [menuBar]))
    }

    t.test("the system's own word counts only for the display the user is working on") {
        t.expect(FullScreenDetector.systemSaysFullScreen(displayHasFocus: true, frontAppIsFullScreen: true))
        t.expect(!FullScreenDetector.systemSaysFullScreen(displayHasFocus: false, frontAppIsFullScreen: true),
                 "the app in front is full screen on ANOTHER display: says nothing about this one")
        t.expect(!FullScreenDetector.systemSaysFullScreen(displayHasFocus: true, frontAppIsFullScreen: false))
        t.expect(!FullScreenDetector.systemSaysFullScreen(displayHasFocus: false, frontAppIsFullScreen: false))
        _ = NSApplication.shared
        t.expect(!ScreenReader.isFullScreen(ScreenInfo(id: 0, frame: .zero, visibleFrame: .zero)),
                 "a display that does not exist is never full screen")
    }
}

private func hoverMachineTests(_ t: TestRunner) {
    typealias Input = HoverMachine.Input
    typealias Output = HoverMachine.Output
    // Delays of a quarter and a half second keep the arithmetic below exact.
    let onPill = Input(isExpanded: false, onPill: true, hoverDelay: 0.25, collapseDelay: 0.5)
    let away = Input(isExpanded: false, hoverDelay: 0.25, collapseDelay: 0.5)
    let inside = Input(isExpanded: true, onPill: false, inPanel: true, hoverDelay: 0.25, collapseDelay: 0.5)
    let left = Input(isExpanded: true, hoverDelay: 0.25, collapseDelay: 0.5)

    t.test("hover: resting on the pill for the hover delay opens the panel") {
        var machine = HoverMachine()
        t.expectEqual(machine.update(onPill, now: 10.0), Output(checkAgainAt: 10.25))
        t.expectEqual(machine.update(onPill, now: 10.125), Output(checkAgainAt: 10.25), "the countdown does not restart on each move")
        t.expectEqual(machine.update(onPill, now: 10.25), Output(command: .expand))
    }

    t.test("hover: a quick pass over the pill opens nothing") {
        var machine = HoverMachine()
        _ = machine.update(onPill, now: 1.0)
        t.expectEqual(machine.update(away, now: 1.125), Output())
        t.expectEqual(machine.update(away, now: 2.0), Output(), "nothing is pending once the pointer has left")
        t.expectEqual(machine.update(onPill, now: 3.0), Output(checkAgainAt: 3.25), "coming back starts a fresh countdown")
    }

    t.test("hover: a zero hover delay opens at once") {
        var machine = HoverMachine()
        var instant = onPill
        instant.hoverDelay = 0
        t.expectEqual(machine.update(instant, now: 5), Output(command: .expand))
    }

    t.test("hover: leaving the open panel closes it after the collapse delay, and returning cancels that") {
        var machine = HoverMachine()
        t.expectEqual(machine.update(inside, now: 20.0), Output())
        t.expectEqual(machine.update(left, now: 21.0), Output(checkAgainAt: 21.5))
        t.expectEqual(machine.update(left, now: 21.25), Output(checkAgainAt: 21.5))
        t.expectEqual(machine.update(inside, now: 21.375), Output(), "back inside: countdown cancelled")
        t.expectEqual(machine.update(left, now: 30.0), Output(checkAgainAt: 30.5), "leaving again starts over")
        t.expectEqual(machine.update(left, now: 30.5), Output(command: .collapse))
    }

    t.test("a waiting request or an active text field holds the panel open") {
        var machine = HoverMachine()
        var held = left
        held.hold = true
        _ = machine.update(inside, now: 1)
        t.expectEqual(machine.update(held, now: 2), Output())
        t.expectEqual(machine.update(held, now: 500), Output(), "held for as long as it takes")
        t.expectEqual(machine.click(.outside, held), HoverMachine.ClickResult(), "a click elsewhere does not close a held panel")
        // The hold ends (the request was answered): the normal countdown starts from that moment.
        t.expectEqual(machine.update(left, now: 600), Output(checkAgainAt: 600.5))
        t.expectEqual(machine.update(left, now: 600.25), Output(checkAgainAt: 600.5))
        t.expectEqual(machine.update(left, now: 600.5), Output(command: .collapse))
    }

    t.test("a panel that opened by itself lingers, then closes, without the pointer ever visiting") {
        var machine = HoverMachine()
        let linger = ShellTuning.unvisitedLinger
        t.expectEqual(machine.update(left, now: 100), Output(checkAgainAt: 100 + linger))
        t.expectEqual(machine.update(left, now: 100 + linger - 0.1), Output(checkAgainAt: 100 + linger))
        t.expectEqual(machine.update(left, now: 100 + linger), Output(command: .collapse))

        // Same in click mode: nobody is there to click it away.
        var clickMachine = HoverMachine()
        var clickLeft = left
        clickLeft.trigger = .click
        t.expectEqual(clickMachine.update(clickLeft, now: 0), Output(checkAgainAt: linger))
    }

    t.test("a panel that opened for a request closes soon after the request is answered elsewhere") {
        var machine = HoverMachine()
        var held = left
        held.hold = true
        t.expectEqual(machine.update(held, now: 50), Output())
        t.expectEqual(machine.update(left, now: 60), Output(checkAgainAt: 60.5), "collapse delay, not the long linger")
    }

    t.test("after closing, the pointer must leave the pill before hover can open the panel again") {
        var machine = HoverMachine()
        var openOnPill = inside
        openOnPill.onPill = true
        _ = machine.update(openOnPill, now: 1)
        // Closed (by Escape, say) while the pointer is still resting on the pill.
        t.expectEqual(machine.update(onPill, now: 2), Output())
        t.expectEqual(machine.update(onPill, now: 9), Output(), "it does not spring back open")
        _ = machine.update(away, now: 10)
        t.expectEqual(machine.update(onPill, now: 11), Output(checkAgainAt: 11.25), "after leaving, hover works again")
    }

    t.test("click mode: hovering does nothing; a click on the pill toggles") {
        var machine = HoverMachine()
        var closed = onPill
        closed.trigger = .click
        t.expectEqual(machine.update(closed, now: 1), Output())
        t.expectEqual(machine.update(closed, now: 60), Output(), "no amount of hovering opens it")
        t.expectEqual(machine.click(.pill, closed), HoverMachine.ClickResult(command: .expand, consume: true))

        var open = inside
        open.trigger = .click
        open.onPill = true
        t.expectEqual(machine.update(open, now: 61), Output())
        var openAway = left
        openAway.trigger = .click
        t.expectEqual(machine.update(openAway, now: 62), Output(), "leaving does not close a panel the user clicked open")
        t.expectEqual(machine.update(openAway, now: 999), Output())
        t.expectEqual(machine.click(.panel, open), HoverMachine.ClickResult(), "clicks inside the panel belong to the views")
        t.expectEqual(machine.click(.pill, open), HoverMachine.ClickResult(command: .collapse, consume: true),
                      "second click on the pill closes, and does not also press what the panel draws there")
    }

    t.test("click mode: clicking anywhere else closes; the pill click wins even over a hold") {
        var machine = HoverMachine()
        var open = left
        open.trigger = .click
        _ = machine.update(open, now: 1)
        t.expectEqual(machine.click(.outside, open), HoverMachine.ClickResult(command: .collapse))

        var held = open
        held.hold = true
        t.expectEqual(machine.click(.outside, held), HoverMachine.ClickResult())
        t.expectEqual(machine.click(.pill, held), HoverMachine.ClickResult(command: .collapse, consume: true),
                      "clicking the pill is the user saying 'go away'")
    }

    t.test("hover mode: a click on the pill opens at once but is left for the views; clicks elsewhere do nothing while closed") {
        var machine = HoverMachine()
        t.expectEqual(machine.click(.pill, onPill), HoverMachine.ClickResult(command: .expand, consume: false))
        t.expectEqual(machine.click(.outside, away), HoverMachine.ClickResult())
        t.expectEqual(machine.click(.panel, away), HoverMachine.ClickResult())
        var open = inside
        open.onPill = true
        t.expectEqual(machine.click(.pill, open), HoverMachine.ClickResult(), "in hover mode the pill strip of an open panel is just panel")
        t.expectEqual(machine.click(.outside, left), HoverMachine.ClickResult(command: .collapse))
    }

    t.test("nothing opens or closes by timer while a mouse button is held down") {
        var machine = HoverMachine()
        var dragging = onPill
        dragging.mouseButtonDown = true
        t.expectEqual(machine.update(dragging, now: 1), Output(), "dragging a window past the notch starts no countdown")
        t.expectEqual(machine.update(dragging, now: 50), Output())
        t.expectEqual(machine.update(onPill, now: 51), Output(checkAgainAt: 51.25), "the countdown starts when the button is released")

        var openMachine = HoverMachine()
        _ = openMachine.update(inside, now: 1)
        var draggingOut = left
        draggingOut.mouseButtonDown = true
        t.expectEqual(openMachine.update(draggingOut, now: 2), Output(), "selecting text that strays outside does not close the panel")
        t.expectEqual(openMachine.update(draggingOut, now: 90), Output())
        t.expectEqual(openMachine.update(left, now: 91), Output(checkAgainAt: 91.5))
        // A click is judged on its own, whatever the drag flag says.
        t.expectEqual(openMachine.click(.outside, draggingOut), HoverMachine.ClickResult(command: .collapse))
    }

    t.test("the panel may take the keyboard only when it is open and wanted") {
        t.expect(KeyPolicy.wantsKey(isExpanded: true, pointerOnPanel: true, isParked: false, needsKeyboard: false))
        t.expect(!KeyPolicy.wantsKey(isExpanded: true, pointerOnPanel: false, isParked: false, needsKeyboard: false))
        t.expect(!KeyPolicy.wantsKey(isExpanded: true, pointerOnPanel: true, isParked: true, needsKeyboard: false),
                 "a panel that opened under a resting pointer leaves the keyboard alone")
        t.expect(KeyPolicy.wantsKey(isExpanded: true, pointerOnPanel: false, isParked: false, needsKeyboard: true))
        t.expect(KeyPolicy.wantsKey(isExpanded: true, pointerOnPanel: true, isParked: true, needsKeyboard: true))
        t.expect(!KeyPolicy.wantsKey(isExpanded: false, pointerOnPanel: true, isParked: false, needsKeyboard: true),
                 "the collapsed pill never takes the keyboard, whatever the flags say")
    }

    t.test("opening and closing goes through the app's actions, with a fallback when nobody is listening") {
        let quiet = AppEnv(settings: AppSettings(defaults: MemoryDefaults()))
        PanelExpander(env: quiet).setExpanded(true)
        t.expect(quiet.ui.isExpanded, "NoopActions does nothing, so the expander flips the state itself")
        PanelExpander(env: quiet).toggle()
        t.expect(!quiet.ui.isExpanded)

        let wired = AppEnv(settings: quiet.settings)
        let spy = SpyActions(ui: wired.ui)
        wired.actions = spy
        PanelExpander(env: wired).setExpanded(true)
        PanelExpander(env: wired).setExpanded(true)
        t.expectEqual(spy.setExpandedCalls, [true], "asked once; no repeat when the panel is already open")
        t.expect(wired.ui.isExpanded)
        PanelExpander(env: wired).setExpanded(false)
        t.expectEqual(spy.setExpandedCalls, [true, false])
    }
}

private func watcherTests(_ t: TestRunner) {
    t.test("the shell hears about every setting and store value it depends on, and nothing else") {
        _ = NSApplication.shared
        withSettings { settings in
            let env = AppEnv(settings: settings)
            var seen: [ShellWatcher.Change] = []
            let watcher = ShellWatcher(env: env, window: NotchPanel(size: CGSize(width: 10, height: 10))) { seen.append($0) }
            watcher.start()
            t.expectEqual(seen, [], "the values things already have are not news")

            // Where the island is and whether it shows.
            settings.displayMode = .main
            settings.showOnNonNotchDisplays = false
            settings.hideWhenNoSessions = true
            settings.hideInFullScreen = true
            env.sessions.sessions = [SampleData.sessions[0]]
            env.ui.isExpanded = true
            t.expectEqual(seen, Array(repeating: .placement, count: 6))

            // The island's size and the open/close rules.
            seen = []
            settings.expandTrigger = .click
            settings.hoverDelay = 0.5
            settings.collapseDelay = 1
            settings.keepExpandedWhilePending = false
            settings.panelWidth = 600
            settings.panelMaxHeight = 400
            settings.pillStyle = .compact
            env.ui.desiredPanelHeight = 300
            env.ui.notchSize = CGSize(width: 200, height: 38)
            env.ui.needsKeyboard = true
            env.sessions.pending = [permission()]
            t.expectEqual(seen, Array(repeating: .pointer, count: 11))

            // Not news: the same value again, a second session, an unrelated setting.
            seen = []
            env.ui.isExpanded = true
            settings.hoverDelay = 0.5
            env.sessions.sessions.append(SampleData.sessions[1])
            env.sessions.pending.append(permission())
            settings.theme = .ember
            env.ui.panelTab = .usage
            t.expectEqual(seen, [])

            watcher.stop()
            env.ui.isExpanded = false
            settings.displayMode = .builtin
            t.expectEqual(seen, [], "silent once stopped")
        }
    }
}

private func shortcutTests(_ t: TestRunner) {
    typealias Context = ShortcutContext

    t.test("each key combination maps to its shortcut") {
        t.expectEqual(ShortcutMap.action(for: cmd("y")), .allow)
        t.expectEqual(ShortcutMap.action(for: cmd("\r", keyCode: KeyStroke.returnKey)), .allow)
        t.expectEqual(ShortcutMap.action(for: cmd("\u{3}", keyCode: KeyStroke.keypadEnter)), .allow)
        t.expectEqual(ShortcutMap.action(for: cmd("n")), .deny)
        t.expectEqual(ShortcutMap.action(for: cmd("\u{7f}", keyCode: KeyStroke.delete)), .deny)
        t.expectEqual(ShortcutMap.action(for: cmd("t")), .passToTerminal)
        t.expectEqual(ShortcutMap.action(for: cmd(",")), .openSettings)
        t.expectEqual(ShortcutMap.action(for: cmd("1")), .pickOption(1))
        t.expectEqual(ShortcutMap.action(for: cmd("9")), .pickOption(9))
        t.expectEqual(ShortcutMap.action(for: cmd("&", keyCode: 18)), .pickOption(1), "French layout: the 1 key types & without Shift")
        t.expectNil(ShortcutMap.action(for: cmd("0")))
        t.expectEqual(ShortcutMap.action(for: KeyStroke(keyCode: KeyStroke.escape, characters: "\u{1b}")), .collapse)
    }

    t.test("plain typing and other modifier combinations are not shortcuts") {
        t.expectNil(ShortcutMap.action(for: KeyStroke(keyCode: 16, characters: "y")), "y without Command")
        t.expectNil(ShortcutMap.action(for: KeyStroke(keyCode: KeyStroke.returnKey, characters: "\r")), "Return without Command")
        t.expectNil(ShortcutMap.action(for: KeyStroke(keyCode: 16, characters: "y", command: true, shift: true)))
        t.expectNil(ShortcutMap.action(for: KeyStroke(keyCode: 16, characters: "y", command: true, option: true)))
        t.expectNil(ShortcutMap.action(for: KeyStroke(keyCode: 16, characters: "y", command: true, control: true)))
        t.expectNil(ShortcutMap.action(for: KeyStroke(keyCode: KeyStroke.escape, characters: "\u{1b}", command: true)))
        t.expectNil(ShortcutMap.action(for: cmd("q")))
    }

    t.test("allow, deny and pass act on a permission request") {
        let request = permission()
        let context = Context(pending: [request])
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: context), .resolve(request, .allow))
        t.expectEqual(ShortcutMap.outcome(for: cmd("n"), in: context), .resolve(request, .deny(message: nil)))
        t.expectEqual(ShortcutMap.outcome(for: cmd("t"), in: context), .resolve(request, .passToTerminal))
        t.expectEqual(ShortcutMap.outcome(for: cmd("1"), in: context), .ignore, "numbers mean nothing for a permission request")
    }

    t.test("a dangerous request cannot be allowed with one key press while confirmation is on") {
        let risky = permission(dangerous: true)
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(confirmDangerous: true, pending: [risky])), .needsConfirmation(risky))
        t.expectEqual(ShortcutMap.outcome(for: cmd("\r", keyCode: KeyStroke.returnKey), in: Context(confirmDangerous: true, pending: [risky])),
                      .needsConfirmation(risky))
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(confirmDangerous: false, pending: [risky])), .resolve(risky, .allow),
                      "with the confirmation setting off it behaves like any other request")
        t.expectEqual(ShortcutMap.outcome(for: cmd("n"), in: Context(confirmDangerous: true, pending: [risky])), .resolve(risky, .deny(message: nil)),
                      "denying is always one key press")
        t.expectEqual(ShortcutMap.outcome(for: cmd("t"), in: Context(confirmDangerous: true, pending: [risky])), .resolve(risky, .passToTerminal))

        let riskyRequest = PermissionRequest(toolName: "Bash", summary: "", detail: "rm -rf /", isDangerous: true)
        let safeRequest = PermissionRequest(toolName: "Read", summary: "", detail: "README.md")
        t.expect(!ShortcutMap.canAllowWithShortcut(riskyRequest, confirmDangerous: true))
        t.expect(ShortcutMap.canAllowWithShortcut(riskyRequest, confirmDangerous: false))
        t.expect(ShortcutMap.canAllowWithShortcut(safeRequest, confirmDangerous: true))
    }

    t.test("shortcuts aim at the focused card, otherwise at the oldest request") {
        let older = permission(age: 60, session: "old")
        let newer = permission(age: 5, session: "new")
        t.expectEqual(ShortcutMap.target(focusedRequestID: nil, pending: [newer, older])?.id, older.id)
        t.expectEqual(ShortcutMap.target(focusedRequestID: newer.id, pending: [older, newer])?.id, newer.id)
        t.expectEqual(ShortcutMap.target(focusedRequestID: UUID(), pending: [older, newer])?.id, older.id, "a stale focus falls back to the oldest")
        t.expectNil(ShortcutMap.target(focusedRequestID: nil, pending: []))
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(focusedRequestID: newer.id, pending: [older, newer])), .resolve(newer, .allow))
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(pending: [])), .ignore, "nothing waiting: the key is not ours")
    }

    t.test("numbers answer a single single-choice question, and nothing else") {
        let simple = question(options: 3)
        t.expectEqual(ShortcutMap.outcome(for: cmd("2"), in: Context(pending: [simple])),
                      .resolve(simple, .answer(["Question 0?": "Option 2"])))
        t.expectEqual(ShortcutMap.outcome(for: cmd("4"), in: Context(pending: [simple])), .ignore, "there is no option 4")
        t.expectEqual(ShortcutMap.outcome(for: cmd("1"), in: Context(pending: [question(multiSelect: true)])), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: cmd("1"), in: Context(pending: [question(questions: 2)])), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(pending: [simple])), .ignore, "a question cannot be 'allowed'")
        t.expectEqual(ShortcutMap.outcome(for: cmd("n"), in: Context(pending: [simple])), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: cmd("t"), in: Context(pending: [simple])), .resolve(simple, .passToTerminal))
    }

    t.test("allow and deny approve or reject a plan") {
        let proposal = plan()
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(pending: [proposal])), .resolve(proposal, .approvePlan(acceptEdits: false)))
        t.expectEqual(ShortcutMap.outcome(for: cmd("n"), in: Context(pending: [proposal])), .resolve(proposal, .rejectPlan(feedback: "")))
    }

    t.test("nothing happens unless the island is key and shortcuts are on") {
        let request = permission()
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(panelIsKey: false, pending: [request])), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(shortcutsEnabled: false, pending: [request])), .ignore)
        let escape = KeyStroke(keyCode: KeyStroke.escape)
        t.expectEqual(ShortcutMap.outcome(for: escape, in: Context(shortcutsEnabled: false)), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: escape, in: Context(panelIsKey: false)), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: escape, in: Context()), .collapse)
        t.expectEqual(ShortcutMap.outcome(for: cmd(","), in: Context()), .openSettings)
    }

    t.test("Cmd-Q never reaches Perch's Quit command while the island has the keyboard") {
        let quit = cmd("q")
        t.expectEqual(ShortcutMap.outcome(for: quit, in: Context()), .swallow)
        t.expectEqual(ShortcutMap.outcome(for: quit, in: Context(shortcutsEnabled: false)), .swallow, "even with shortcuts switched off")
        t.expectEqual(ShortcutMap.outcome(for: quit, in: Context(needsKeyboard: true)), .swallow, "even while typing")
        t.expectEqual(ShortcutMap.outcome(for: quit, in: Context(panelIsKey: false)), .ignore, "in the Settings window Cmd-Q works normally")
        t.expectEqual(ShortcutMap.outcome(for: KeyStroke(keyCode: 12, characters: "q"), in: Context()), .ignore, "a plain q is just a letter")
    }

    t.test("Hide, Close and Minimise are kept away from Perch too while the island has the keyboard") {
        for letter in ["h", "w", "m"] {
            t.expectEqual(ShortcutMap.outcome(for: cmd(letter), in: Context()), .swallow, "Cmd-\(letter)")
            t.expectEqual(ShortcutMap.outcome(for: cmd(letter), in: Context(shortcutsEnabled: false, needsKeyboard: true)), .swallow)
            t.expectEqual(ShortcutMap.outcome(for: cmd(letter), in: Context(panelIsKey: false)), .ignore, "Settings window: works normally")
            t.expectEqual(ShortcutMap.outcome(for: KeyStroke(keyCode: 0, characters: letter), in: Context()), .ignore, "a plain letter is just a letter")
        }
        let hideOthers = KeyStroke(keyCode: 4, characters: "h", command: true, option: true)
        t.expectEqual(ShortcutMap.outcome(for: hideOthers, in: Context()), .swallow, "Hide Others would hide the app the user is working in")
    }

    t.test("cut, copy, paste, select all, undo and redo are handed to the text field") {
        t.expectEqual(ShortcutMap.editCommand(for: cmd("x")), .cut)
        t.expectEqual(ShortcutMap.editCommand(for: cmd("c")), .copy)
        t.expectEqual(ShortcutMap.editCommand(for: cmd("v")), .paste)
        t.expectEqual(ShortcutMap.editCommand(for: cmd("a")), .selectAll)
        t.expectEqual(ShortcutMap.editCommand(for: cmd("z")), .undo)
        t.expectEqual(ShortcutMap.editCommand(for: KeyStroke(keyCode: 6, characters: "z", command: true, shift: true)), .redo)
        t.expectNil(ShortcutMap.editCommand(for: KeyStroke(keyCode: 9, characters: "v")), "a plain v is just a letter")
        t.expectNil(ShortcutMap.editCommand(for: KeyStroke(keyCode: 9, characters: "v", command: true, shift: true)))
        t.expectNil(ShortcutMap.editCommand(for: KeyStroke(keyCode: 9, characters: "v", command: true, option: true)))
        t.expectNil(ShortcutMap.editCommand(for: KeyStroke(keyCode: 9, characters: "v", command: true, control: true)))
        t.expectNil(ShortcutMap.editCommand(for: cmd("y")), "the shortcuts keep their own letters")
        t.expectNil(ShortcutMap.action(for: cmd("v")), "and the editing letters are no shortcuts")

        let request = permission()
        t.expectEqual(ShortcutMap.outcome(for: cmd("v"), in: Context(needsKeyboard: true, pending: [request])), .edit(.paste),
                      "typing in a field: paste works")
        t.expectEqual(ShortcutMap.outcome(for: cmd("c"), in: Context(pending: [request])), .edit(.copy),
                      "no field in use: copying selected text from a card still works")
        t.expectEqual(ShortcutMap.outcome(for: cmd("a"), in: Context(shortcutsEnabled: false)), .edit(.selectAll),
                      "these are not Perch shortcuts, so the shortcuts switch does not turn them off")
        t.expectEqual(ShortcutMap.outcome(for: cmd("z", isRepeat: true), in: Context(needsKeyboard: true)), .edit(.undo),
                      "holding Cmd-Z keeps undoing, as in every text field")
        t.expectEqual(ShortcutMap.outcome(for: cmd("v"), in: Context(panelIsKey: false)), .ignore,
                      "in the Settings window the Edit menu does this")
    }

    t.test("while a text field is in use only Escape is taken") {
        let request = permission()
        let typing = Context(needsKeyboard: true, pending: [request])
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: typing), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: cmd("\r", keyCode: KeyStroke.returnKey), in: typing), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: cmd("n"), in: typing), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: cmd(","), in: typing), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: KeyStroke(keyCode: 16, characters: "y"), in: typing), .ignore)
        t.expectEqual(ShortcutMap.outcome(for: KeyStroke(keyCode: KeyStroke.escape), in: typing), .collapse)
    }

    t.test("a held-down key never answers anything") {
        let request = permission()
        let context = Context(pending: [request])
        t.expectEqual(ShortcutMap.outcome(for: cmd("y", isRepeat: true), in: context), .swallow)
        t.expectEqual(ShortcutMap.outcome(for: cmd("n", isRepeat: true), in: context), .swallow)
        t.expectEqual(ShortcutMap.outcome(for: KeyStroke(keyCode: KeyStroke.escape, isRepeat: true), in: context), .swallow)
        t.expectEqual(ShortcutMap.outcome(for: cmd("y", isRepeat: true), in: Context(pending: [])), .ignore, "a repeat of a key that is not ours stays not ours")
    }

    t.test("a request that only just appeared cannot be approved or answered by a shortcut") {
        let fresh = permission(age: 0.1)
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(pending: [fresh])), .swallow)
        t.expectEqual(ShortcutMap.outcome(for: cmd("n"), in: Context(pending: [fresh])), .resolve(fresh, .deny(message: nil)), "saying no is always safe")
        t.expectEqual(ShortcutMap.outcome(for: cmd("t"), in: Context(pending: [fresh])), .resolve(fresh, .passToTerminal))
        let freshQuestion = question(age: 0.1)
        t.expectEqual(ShortcutMap.outcome(for: cmd("1"), in: Context(pending: [freshQuestion])), .swallow)
        let freshPlan = plan(age: 0.1)
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(pending: [freshPlan])), .swallow)
        let settled = permission(age: ShellTuning.minimumAllowAge + 0.1)
        t.expectEqual(ShortcutMap.outcome(for: cmd("y"), in: Context(pending: [settled])), .resolve(settled, .allow))
    }
}

private func shortcutMonitorTests(_ t: TestRunner) {
    _ = NSApplication.shared

    t.test("a real key event is read correctly") {
        let event = try t.unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "y", charactersIgnoringModifiers: "Y",
                                                  isARepeat: true, keyCode: 16))
        t.expectEqual(KeyStroke(event), KeyStroke(keyCode: 16, characters: "y", command: true, isRepeat: true),
                      "the character is lower-cased; Command and the repeat flag are picked up")
        let shifted = try t.unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .option, .control, .capsLock],
                                                    timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                    isARepeat: false, keyCode: KeyStroke.escape))
        t.expectEqual(KeyStroke(shifted), KeyStroke(keyCode: KeyStroke.escape, characters: "", shift: true, option: true, control: true))
        t.expectEqual(ShortcutMap.action(for: KeyStroke(event)), .allow)

        // A Russian keyboard: the key types "н", but with Command held macOS reports it as "y".
        let russian = try t.unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                    windowNumber: 0, context: nil, characters: "y", charactersIgnoringModifiers: "н",
                                                    isARepeat: false, keyCode: 16))
        t.expectEqual(KeyStroke(russian).characters, "y")
        t.expectEqual(ShortcutMap.action(for: KeyStroke(russian)), .allow, "Cmd-Y works on a keyboard without Latin letters")
        let plainRussian = try t.unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, characters: "н", charactersIgnoringModifiers: "н",
                                                         isARepeat: false, keyCode: 16))
        t.expectEqual(KeyStroke(plainRussian).characters, "н", "without Command the letter is just the letter")
    }

    t.test("what the shortcut rules decide is carried out through the app's actions") {
        let env = AppEnv(settings: AppSettings(defaults: MemoryDefaults()))
        env.settings.soundsEnabled = false   // a refused shortcut would otherwise play the system beep
        let spy = SpyActions(ui: env.ui)
        env.actions = spy
        let monitor = ShortcutMonitor(env: env)

        t.expect(!monitor.perform(.ignore), "a key that is not ours travels on")
        t.expect(monitor.perform(.swallow), "a swallowed key stops here")
        t.expectEqual(spy.resolved.count, 0)

        let request = permission()
        t.expect(monitor.perform(.resolve(request, .allow)))
        t.expectEqual(spy.resolved.count, 1)
        t.expectEqual(spy.resolved.first?.request.id, request.id)
        t.expectEqual(spy.resolved.first?.decision, .allow)

        let risky = permission(dangerous: true)
        t.expect(monitor.perform(.needsConfirmation(risky)))
        t.expectEqual(env.ui.focusedRequestID, risky.id, "the dangerous card is brought into focus")
        t.expectEqual(spy.resolved.count, 1, "and nothing was answered")

        env.ui.isExpanded = true
        t.expect(monitor.perform(.collapse))
        t.expect(!env.ui.isExpanded)
        t.expectEqual(spy.setExpandedCalls, [false])

        t.expect(monitor.perform(.openSettings))
        t.expectEqual(spy.settingsOpened, 1)

        // Starting and stopping twice is harmless.
        monitor.start()
        monitor.start()
        monitor.stop()
        monitor.stop()
    }

    t.test("an editing command reaches the text field that has the cursor") {
        // A panel that is never shown, holding one ordinary text field. Only "select all" and
        // "undo" are tried for real: cut, copy and paste would touch the user's clipboard.
        let panel = NotchPanel(size: CGSize(width: 200, height: 40))
        let field = NSTextField(string: "hello")
        field.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        panel.contentView?.addSubview(field)
        t.expect(panel.makeFirstResponder(field))
        let editor = try t.unwrap(field.currentEditor() as? NSTextView, "the field has no editor")
        editor.setSelectedRange(NSRange(location: 5, length: 0))

        t.expect(ShortcutMonitor.deliver(.selectAll, to: panel))
        t.expectEqual(editor.selectedRange(), NSRange(location: 0, length: 5))

        editor.insertText("bye", replacementRange: editor.selectedRange())
        t.expectEqual(editor.string, "bye")
        t.expect(ShortcutMonitor.deliver(.undo, to: panel))
        t.expectEqual(editor.string, "hello")
        t.expect(ShortcutMonitor.deliver(.redo, to: panel))
        t.expectEqual(editor.string, "bye")

        t.expect(panel.makeFirstResponder(nil))
        t.expect(!ShortcutMonitor.deliver(.paste, to: panel), "nothing has the cursor: nobody takes it, the key travels on")
        t.expect(!ShortcutMonitor.deliver(.selectAll, to: nil), "no window at all")
        t.expect(!panel.isVisible, "nothing was put on screen by this test")

        let actions = [EditCommand.cut, .copy, .paste, .selectAll, .undo, .redo].map { NSStringFromSelector($0.action) }
        t.expectEqual(actions, ["cut:", "copy:", "paste:", "selectAll:", "undo:", "redo:"])
    }
}

private func statusMenuTests(_ t: TestRunner) {
    t.test("the menu's commands go through the app's actions") {
        _ = NSApplication.shared
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.showMenuBarIcon = false   // build the menu without putting an icon in the real menu bar
        let env = AppEnv(settings: settings)
        let spy = SpyActions(ui: env.ui)
        env.actions = spy
        env.sessions.sessions = Array(SampleData.sessions.prefix(3))   // one working, two waiting for the user
        let controller = StatusItemController(env: env)
        let menu = controller.menu
        func open() { menu.delegate?.menuNeedsUpdate?(menu) }
        func choose(_ title: String) {
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                t.expect(false, "no menu item called \(title)")
                return
            }
            menu.performActionForItem(at: index)
        }

        open()
        t.expectEqual(menu.items.map(\.title),
                      ["3 sessions, 2 need you", "", "Open Panel", "Settings…", "", "Mute Sounds", "Demo Mode", "", "Quit Perch"])
        t.expect(!menu.items[0].isEnabled, "the status line is information, not a command")
        t.expectEqual(menu.items.first { $0.title == "Mute Sounds" }?.state, .off)
        t.expectEqual(menu.items.first { $0.title == "Demo Mode" }?.state, .off)

        choose("Open Panel")
        t.expect(env.ui.isExpanded)
        t.expectEqual(spy.setExpandedCalls, [true])
        open()
        t.expect(menu.items.contains { $0.title == "Close Panel" }, "the item now offers to close the panel")
        choose("Close Panel")
        t.expect(!env.ui.isExpanded)

        choose("Settings…")
        t.expectEqual(spy.settingsOpened, 1)
        choose("Mute Sounds")
        t.expectEqual(spy.muteToggles, 1)
        choose("Demo Mode")
        t.expectEqual(spy.demoCalls, [true], "demo mode was off, so the command turns it on")
        choose("Quit Perch")
        t.expectEqual(spy.quits, 1)

        settings.soundsEnabled = false
        env.ui.isDemo = true
        env.sessions.sessions = []
        open()
        t.expectEqual(menu.items[0].title, "No sessions running")
        t.expectEqual(menu.items.first { $0.title == "Mute Sounds" }?.state, .on, "ticked while muted")
        t.expectEqual(menu.items.first { $0.title == "Demo Mode" }?.state, .on)
        choose("Demo Mode")
        t.expectEqual(spy.demoCalls, [true, false])
    }

    t.test("the menu's status line counts sessions and the ones waiting") {
        t.expectEqual(StatusMenuModel.statusLine(sessionCount: 0, needingYou: 0), "No sessions running")
        t.expectEqual(StatusMenuModel.statusLine(sessionCount: 1, needingYou: 0), "1 session")
        t.expectEqual(StatusMenuModel.statusLine(sessionCount: 3, needingYou: 0), "3 sessions")
        t.expectEqual(StatusMenuModel.statusLine(sessionCount: 3, needingYou: 1), "3 sessions, 1 needs you")
        t.expectEqual(StatusMenuModel.statusLine(sessionCount: 3, needingYou: 2), "3 sessions, 2 need you")
        t.expectEqual(StatusMenuModel.statusLine(sessionCount: 1, needingYou: 1), "1 session, 1 needs you")
        t.expectEqual(StatusMenuModel.statusLine(sessionCount: 0, needingYou: 1), "1 session, 1 needs you", "never '0 sessions, 1 needs you'")
        t.expectEqual(StatusMenuModel.statusLine(sessionCount: -4, needingYou: -1), "No sessions running")
    }

    t.test("the menu reflects the stores") {
        let env = SampleData.env(expanded: false)
        let model = StatusMenuModel(env: env)
        // Sample data: eight sessions, three of them blocked on the user.
        t.expectEqual(model.statusLine, "8 sessions, 3 need you")
        t.expect(model.needsAttention)
        t.expectEqual(model.panelItemTitle, "Open Panel")
        t.expectEqual(model.isMuted, !env.settings.soundsEnabled)
        t.expect(model.isDemo)

        let idle = StatusMenuModel(sessionCount: 2, needingYou: 0, isExpanded: true, soundsEnabled: false, isDemo: false)
        t.expect(!idle.needsAttention)
        t.expectEqual(idle.panelItemTitle, "Close Panel")
        t.expect(idle.isMuted)
        t.expect(!idle.isDemo)
    }

    t.test("a session counts as waiting through its state or through a queued request, once") {
        let sessions = SampleData.sessions
        let waitingByState = sessions.filter { $0.state.needsAttention }.count
        t.expectEqual(StatusMenuModel.needingYou(sessions: sessions, pending: SampleData.pending), waitingByState, "no double counting")
        let orphan = permission(session: "not-in-the-list")
        t.expectEqual(StatusMenuModel.needingYou(sessions: sessions, pending: [orphan]), waitingByState + 1)
        t.expectEqual(StatusMenuModel.needingYou(sessions: [], pending: []), 0)
    }
}

private func appKitPieceTests(_ t: TestRunner) {
    _ = NSApplication.shared

    t.test("the menu-bar icon is a template image with something drawn in it") {
        let image = StatusIcon.image()
        t.expect(image.isTemplate, "template images are tinted by the menu bar")
        t.expectEqual(image.size, StatusIcon.size)
        t.expect(image.size.height <= 22, "fits the menu bar")
        let width = Int(StatusIcon.size.width) * 2, height = Int(StatusIcon.size.height) * 2
        let bitmap = try t.unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for y in 0..<height {
            for x in 0..<width where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 }
        }
        let share = Double(inked) / Double(width * height)
        t.expect(share > 0.12 && share < 0.6, "the bird covers a sensible share of the icon, got \(share)")

        // The attention dot must sit inside the icon and on clear pixels, so it never hides the bird.
        let dot = StatusIcon.dotCenter, radius = StatusIcon.dotRadius
        t.expect(dot.x + radius <= StatusIcon.size.width && dot.y + radius <= StatusIcon.size.height)
        let dotPixel = bitmap.colorAt(x: Int(dot.x * 2), y: height - 1 - Int(dot.y * 2))
        t.expect((dotPixel?.alphaComponent ?? 0) < 0.1, "the dot's spot is empty in the picture")
    }

    t.test("the Settings window is an ordinary resizable window of the right size") {
        let env = AppEnv(settings: AppSettings(defaults: MemoryDefaults()))
        let controller = SettingsWindowController(env: env, content: AnyView(Color.clear))
        let window = controller.loadWindow()
        t.expect(window.styleMask.contains([.titled, .closable, .resizable, .miniaturizable]))
        t.expectEqual(window.contentRect(forFrameRect: window.frame).size, ShellTuning.settingsSize)
        t.expectEqual(ShellTuning.settingsSize, CGSize(width: 860, height: 620))
        t.expectEqual(window.contentMinSize, CGSize(width: 760, height: 520))
        t.expectEqual(window.title, "Perch Settings")
        t.expect(!window.isReleasedWhenClosed, "closing must not destroy the window: it is reused")
        t.expect(!window.isVisible, "building the window does not show it")
        t.expect(controller.loadWindow() === window, "one window, reused")

        t.expectEqual(env.ui.settingsTab, .general)
        controller.select(.agents)
        t.expectEqual(env.ui.settingsTab, .agents)
        controller.select(nil)
        t.expectEqual(env.ui.settingsTab, .agents, "no tab given: stay where the user was")
    }

    t.test("outside a menu or a drag, nothing tells the island to hold still") {
        t.expect(!PointerSource().isMidInteraction())
    }

    t.test("handing the focus back does nothing when Perch never had it") {
        // This test process is a background process that never becomes active, like Perch
        // most of the time. Nothing may be hidden, activated or changed.
        let loan = FocusLoan()
        loan.noteLender()
        loan.repay()
        t.expect(!NSApplication.shared.isActive)
        t.expect(!NSApplication.shared.isHidden)
        let panel = NotchPanel(size: CGSize(width: 10, height: 10))
        panel.giveUpKey()
        panel.leaveScreen()
        t.expect(!panel.isVisible && !panel.isKeyWindow && !panel.canBecomeKey)
    }

    t.test("the notch panel is set up to float over the menu bar without stealing focus") {
        let panel = NotchPanel(size: IslandMetrics.windowSize)
        t.expect(panel.styleMask.contains(.nonactivatingPanel), "showing it never makes Perch the active app")
        t.expect(!panel.styleMask.contains(.titled), "borderless")
        t.expectEqual(panel.level.rawValue, NSWindow.Level.mainMenu.rawValue + 3)
        t.expect(panel.collectionBehavior.contains([.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]))
        t.expect(panel.isFloatingPanel)
        t.expect(!panel.isOpaque)
        t.expect(!panel.hasShadow)
        t.expect(!panel.hidesOnDeactivate, "a background app's panel must not hide when the app is inactive")
        t.expect(panel.ignoresMouseEvents, "click-through until the pointer is on the island")
        t.expect(!panel.canBecomeKey, "no keyboard until the controller allows it")
        panel.allowsKey = true
        t.expect(panel.canBecomeKey)
        t.expect(!panel.canBecomeMain)
        let pushedDown = CGRect(x: 0, y: -400, width: 840, height: 760)
        t.expectEqual(panel.constrainFrameRect(pushedDown, to: nil), pushedDown, "the system may not move the island below the menu bar")
        t.expect(!panel.isVisible, "nothing was put on screen by this test")
    }
}
