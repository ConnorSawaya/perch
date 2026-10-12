// NotchWindowController.swift — puts the island on screen and makes it behave.
//
// This is the conductor of the window shell. It owns the transparent NotchPanel and keeps four
// things true at all times:
//
//   1. PLACE   The panel sits on the right display, pinned to its top edge and centred on the
//              notch (ScreenPicker + IslandPlacement), or is hidden when a "hide when..." setting
//              says so (IslandVisibility).
//   2. CLICKS  The panel takes mouse clicks only while the pointer is on the island; everywhere
//              else it is click-through, so the apps underneath work normally (IslandZones).
//              A panel that opens by itself stays click-through for a moment, so a click already
//              on its way to the app underneath cannot hit "Allow" by accident.
//   3. OPEN    Hovering or clicking the pill opens the panel, leaving it closes it (HoverMachine).
//              The views never decide this themselves.
//   4. KEYS    The panel takes the keyboard only while the pointer is deliberately over the open
//              panel or a text field needs it, and gives it straight back afterwards (KeyPolicy).
//              Perch never becomes the frontmost app because of the island: the app the user is
//              working in keeps its menu bar and its place.
//
// One exception to 2-4: while a menu belonging to Perch is open, nothing changes until it closes.
//
// The flow is always the same: something changes (PointerMonitor reports the mouse, ShellWatcher
// reports settings, stores, displays and Spaces) -> `refreshPlacement()` or `refreshPointer()`
// re-reads the facts, asks the pure rule types what should be true, and applies the difference.
//
// Use from the main thread only.

import AppKit
import SwiftUI

final class NotchWindowController {
    private let env: AppEnv
    private let expander: PanelExpander
    private let pointer = PointerMonitor()
    private var hover = HoverMachine()

    /// The window itself. Other parts of the shell only need it to ask "is the island key?".
    let panel: NotchPanel
    /// Where the island currently is, or nil before it has ever been placed.
    private(set) var placement: IslandPlacement?
    /// Where the mouse facts come from: the real mouse, unless the shell's harness swaps this out.
    var pointerSource = PointerSource()

    /// True between `show()` and `hide()`.
    private var isRequested = false
    private var lastPointer: CGPoint?
    /// The panel state as of the last pointer refresh, to notice it opening by itself.
    private var sawExpanded = false
    /// The panel opened by itself under a pointer that has not moved since (see KeyPolicy).
    private var isParked = false
    /// Until this moment the island lets clicks fall through even under the pointer, because
    /// the panel has only just opened by itself.
    private var clickGuardUntil: TimeInterval = 0
    private var lastVerdict: IslandVisibility.Verdict?

    private var watcher: ShellWatcher?
    private var checkTimer: Timer?
    /// The moment `checkTimer` is set for, so an unchanged countdown is not rescheduled on every mouse move.
    private var checkTime: TimeInterval?
    private var surroundingsTimer: Timer?
    private var refreshIsQueued = false
    private var queuedRefreshNeedsPlacement = false

    /// `content` is the SwiftUI island. It must draw itself at the top-centre of the space it is
    /// given, at the size `IslandMetrics` reports.
    init(env: AppEnv, content: AnyView) {
        self.env = env
        expander = PanelExpander(env: env)
        panel = NotchPanel(size: IslandMetrics.windowSize)
        panel.contentView = NotchHostingView.hosting(content, size: IslandMetrics.windowSize)
        pointer.onMove = { [weak self] in self?.pointerDidMove() }
        pointer.onMouseDown = { [weak self] isPrimary, source in
            self?.mouseDidGoDown(isPrimary: isPrimary, source: source) ?? false
        }
        watcher = ShellWatcher(env: env, window: panel) { [weak self] change in self?.handle(change) }
    }

    deinit {
        watcher?.stop()
        pointer.stop()
        checkTimer?.invalidate()
        surroundingsTimer?.invalidate()
    }

    // MARK: - Public

    /// Starts showing the island (subject to the "hide when..." settings) and keeps it placed.
    func show() {
        if !isRequested {
            isRequested = true
            watcher?.start()
        }
        refreshPlacement()
    }

    /// Removes the island from the screen until `show()` is called again.
    func hide() {
        guard isRequested else { return }
        isRequested = false
        watcher?.stop()
        surroundingsTimer?.invalidate()
        surroundingsTimer = nil
        takeOffScreen()
    }

    /// Call when the pointer may have moved. The mouse monitors do this by themselves.
    func pointerDidMove() {
        refreshPointer()
    }

    /// Call when a mouse button goes down. Returns true when the click was used up here and
    /// should not also reach the island's views.
    func mouseDidGoDown(isPrimary: Bool, source: PointerMonitor.Source) -> Bool {
        guard isRequested, panel.isVisible, let placement else { return false }
        // While a panel that opened by itself is still settling (see noteSelfOpening), a click
        // can be neither aimed at it nor a reaction to it. It passes through and changes nothing.
        guard clickGuardUntil <= now else { return false }
        let location = pointerSource.location()
        let islandZones = zones(for: placement)
        let hit = islandZones.hit(location)
        let zone: HoverMachine.ClickZone
        if !hit.onIsland {
            zone = .outside
        } else if hit.onPill && isPrimary && !landsOnStripButton(location, islandZones) {
            zone = .pill
        } else {
            zone = .panel
        }
        // The button that was just pressed is not "a drag in progress", so it is left out here.
        let result = hover.click(zone, hoverInput(hit, mouseButtonDown: false))
        if let command = result.command { run(command) }
        refreshPointer(clicked: true)
        return result.consume && source == .local
    }

    /// While the panel is open, the strip where the pill was shows the usage readouts to the
    /// right of the notch, and they are a button (it opens the Usage tab). In click mode a click
    /// on the pill's footprint normally means "close the panel" and is used up; a click on that
    /// button must reach the button instead. With no limit readings nothing is drawn there, and
    /// the whole footprint keeps meaning "close".
    private func landsOnStripButton(_ point: CGPoint, _ zones: IslandZones) -> Bool {
        guard env.ui.isExpanded, env.usage.usage.values.contains(where: { !$0.windows.isEmpty }) else { return false }
        return zones.isRightOfNotch(point, wing: IslandMetrics.wing(env.settings))
    }

    // MARK: - 1. Place

    /// Works out which display the island belongs on and whether it should be visible, then
    /// moves, shows or hides the panel to match.
    private func refreshPlacement() {
        guard isRequested else { return }
        let settings = env.settings
        updateSurroundingsTimer()
        let screen = ScreenPicker.pick(mode: settings.displayMode, screens: ScreenReader.screens(),
                                       focusedScreenID: ScreenReader.focusedScreenID(), pointer: pointerSource.location())
        // Reading the window list is only worth it when the setting that needs it is on.
        let isFullScreen = settings.hideInFullScreen && (screen.map(ScreenReader.isFullScreen) ?? false)
        let verdict = IslandVisibility.verdict(IslandVisibility.Input(
            isRequested: isRequested, screen: screen, showOnNonNotchDisplays: settings.showOnNonNotchDisplays,
            hideWhenNoSessions: settings.hideWhenNoSessions, sessionCount: env.sessions.sessions.count,
            isExpanded: env.ui.isExpanded, hideInFullScreen: settings.hideInFullScreen, screenIsFullScreen: isFullScreen))
        if verdict != lastVerdict {
            lastVerdict = verdict
            if case .hide(let reason) = verdict { Log.debug("island hidden: \(reason.rawValue)", "shell") }
        }
        guard verdict == .show, let screen else {
            takeOffScreen()
            return
        }
        putOnScreen(IslandPlacement(screen: screen, windowSize: IslandMetrics.windowSize))
        refreshPointer()
    }

    private func putOnScreen(_ newPlacement: IslandPlacement) {
        if newPlacement != placement {
            placement = newPlacement
            Log.debug("island on display \(newPlacement.screenID), window \(newPlacement.windowFrame), notch \(newPlacement.notchSize)", "shell")
        }
        pinFrame()
        // Tell the views what they are drawing around. Only write real changes: every write redraws.
        if env.ui.screenHasNotch != newPlacement.hasNotch { env.ui.screenHasNotch = newPlacement.hasNotch }
        if env.ui.notchSize != newPlacement.notchSize { env.ui.notchSize = newPlacement.notchSize }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if pointerSource.listensToSystemEvents { pointer.start() }
    }

    private func takeOffScreen() {
        scheduleCheck(at: nil)
        pointer.stop()
        panel.ignoresMouseEvents = true
        panel.leaveScreen()
        // Start from scratch when the island comes back.
        hover = HoverMachine()
        lastPointer = nil
        sawExpanded = false
        isParked = false
        clickGuardUntil = 0
    }

    /// Puts the panel back where it belongs if the system (or anything else) has nudged it.
    private func pinFrame() {
        guard var wanted = placement, panel.frame != wanted.windowFrame else { return }
        panel.setFrame(wanted.windowFrame, display: true)
        // AppKit has the last word on the exact frame. Whatever it settled on is where the
        // island really is, so that is what the pointer must be compared against.
        if panel.frame != wanted.windowFrame {
            wanted.windowFrame = panel.frame
            placement = wanted
        }
    }

    /// Displays, Spaces and wake-from-sleep all settle in stages, so place the island now and
    /// once more a moment later.
    private func surroundingsDidChange() {
        refreshPlacement()
        if panel.isVisible { panel.orderFrontRegardless() }
        DispatchQueue.main.asyncAfter(deadline: .now() + ShellTuning.screenSettleDelay) { [weak self] in
            self?.refreshPlacement()
        }
    }

    /// "Follow focus" and "hide in full screen" depend on things macOS does not announce, so
    /// while either is on the placement is re-checked on a slow timer.
    private func updateSurroundingsTimer() {
        let isNeeded = isRequested && (env.settings.displayMode == .followFocus || env.settings.hideInFullScreen)
        if isNeeded && surroundingsTimer == nil {
            let timer = Timer(timeInterval: ShellTuning.surroundingsInterval, repeats: true) { [weak self] _ in
                self?.refreshPlacement()
            }
            timer.tolerance = ShellTuning.surroundingsInterval / 4
            RunLoop.main.add(timer, forMode: .common)
            surroundingsTimer = timer
        } else if !isNeeded {
            surroundingsTimer?.invalidate()
            surroundingsTimer = nil
        }
    }

    // MARK: - 2. Clicks, 3. Open and close, 4. Keys

    /// Re-reads the pointer and brings click-through, the open/closed state and the keyboard in
    /// line with it. `clicked` marks a refresh caused by a mouse click.
    private func refreshPointer(clicked: Bool = false) {
        guard isRequested, panel.isVisible, let placement else { return }
        // While one of Perch's own menus is open the island holds still. Such a menu usually
        // hangs outside the island, so following it with the pointer looks like "leaving":
        // without this the panel would hand back the keyboard (which takes its window off the
        // screen for an instant) and then close, underneath the very menu the user is reading.
        // Nothing is lost by waiting: the poll below calls this method again until the menu
        // has closed, and every rule then applies from that moment.
        if pointerSource.isMidInteraction() {
            pointer.setPollInterval(ShellTuning.menuPollInterval)
            return
        }
        let location = pointerSource.location()
        let moved = lastPointer.map { hypot($0.x - location.x, $0.y - location.y) > ShellTuning.movementThreshold } ?? false
        lastPointer = location
        // "Deliberate" = the user did something with the mouse just now, as opposed to a timer
        // or a setting waking this method up while the pointer rests.
        let deliberate = moved || clicked

        // Opening or closing changes the island's size, which can change the answers below, so
        // go round again after each command. Two passes settle it; the third is a safety margin.
        for _ in 0..<3 {
            let hit = zones(for: placement).hit(location)
            noteSelfOpening(hit: hit, deliberate: deliberate)
            let guardEnds = clickGuardUntil > now ? clickGuardUntil : nil
            let takesClicks = hit.onIsland && guardEnds == nil
            if panel.ignoresMouseEvents == takesClicks { panel.ignoresMouseEvents = !takesClicks }
            let output = hover.update(hoverInput(hit, mouseButtonDown: pointerSource.pressedButtons() != 0), now: now)
            if let command = output.command {
                run(command)
                continue
            }
            // Look again when a countdown runs out or the click guard lifts, whichever is first.
            scheduleCheck(at: [output.checkAgainAt, guardEnds].compactMap { $0 }.min())
            updateKeyStatus(hit: hit, deliberate: deliberate)
            pointer.setPollInterval(pollInterval(hit: hit))
            return
        }
        queueRefresh(placement: false)
    }

    /// The pill and the island as rectangles on screen, from the sizes the views draw at.
    private func zones(for placement: IslandPlacement) -> IslandZones {
        let pillSize = IslandMetrics.pillSize(ui: env.ui, settings: env.settings)
        let pillRect = CGRect(x: (IslandMetrics.windowSize.width - pillSize.width) / 2, y: 0,
                              width: pillSize.width, height: pillSize.height)
        return IslandZones(placement: placement, pillRect: pillRect,
                           islandRect: IslandMetrics.islandRect(ui: env.ui, settings: env.settings))
    }

    private func hoverInput(_ hit: IslandZones.Hit, mouseButtonDown: Bool) -> HoverMachine.Input {
        let settings = env.settings
        let isExpanded = env.ui.isExpanded
        let hold = (settings.keepExpandedWhilePending && !env.sessions.pending.isEmpty) || env.ui.needsKeyboard
        return HoverMachine.Input(isExpanded: isExpanded, onPill: hit.onPill, inPanel: isExpanded && hit.nearIsland,
                                  hold: hold, mouseButtonDown: mouseButtonDown, trigger: settings.expandTrigger,
                                  hoverDelay: settings.hoverDelay, collapseDelay: settings.collapseDelay)
    }

    private func run(_ command: HoverMachine.Command) {
        expander.setExpanded(command == .expand)
        // This change was the pointer's doing, so it must not be mistaken for the panel opening
        // by itself (see noteSelfOpening).
        sawExpanded = env.ui.isExpanded
    }

    /// Notices the panel opening by itself (a request arrived, a task finished) instead of by
    /// the user's hover or click, which `run` handles. Two protections follow:
    ///   - for a moment the panel lets clicks fall through, so a click the user was already
    ///     making on the app underneath does not land on a button that just appeared there;
    ///   - if the pointer was resting on that spot, the panel leaves the keyboard alone until
    ///     the user moves or clicks.
    private func noteSelfOpening(hit: IslandZones.Hit, deliberate: Bool) {
        let isExpanded = env.ui.isExpanded
        if isExpanded && !sawExpanded {
            clickGuardUntil = now + ShellTuning.surpriseClickGuard
            if hit.onIsland && !deliberate { isParked = true }
        }
        if !isExpanded || !hit.onIsland || deliberate { isParked = false }
        sawExpanded = isExpanded
    }

    private func updateKeyStatus(hit: IslandZones.Hit, deliberate: Bool) {
        let wantsKey = KeyPolicy.wantsKey(isExpanded: env.ui.isExpanded, pointerOnPanel: hit.onIsland,
                                          isParked: isParked, needsKeyboard: env.ui.needsKeyboard)
        if wantsKey != panel.allowsKey {
            panel.allowsKey = wantsKey
            if wantsKey { panel.takeKey() } else { panel.giveUpKey() }
        } else if wantsKey && deliberate && !panel.isKeyWindow {
            // The keyboard went elsewhere in the meantime (the user switched apps with Cmd-Tab,
            // say). Take it back on a deliberate move only, never from a timer.
            panel.takeKey()
        }
    }

    /// How often the pointer needs re-reading on a timer (see PointerMonitor for why).
    private func pollInterval(hit: IslandZones.Hit) -> TimeInterval? {
        if hit.onIsland { return ShellTuning.insidePollInterval }
        return NSApplication.shared.isActive ? ShellTuning.activePollInterval : nil
    }

    /// Arranges one more look at the moment a hover or leave countdown runs out.
    private func scheduleCheck(at time: TimeInterval?) {
        guard time != checkTime else { return }
        checkTime = time
        checkTimer?.invalidate()
        checkTimer = nil
        guard let time else { return }
        let timer = Timer(timeInterval: max(0.01, time - now), repeats: false) { [weak self] _ in
            self?.checkTime = nil
            self?.refreshPointer()
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    /// A clock that only moves forward (seconds since the Mac started).
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Reacting to changes

    /// ShellWatcher reports what changed; this decides what to do about it.
    private func handle(_ change: ShellWatcher.Change) {
        switch change {
        case .placement:
            queueRefresh(placement: true)
        case .pointer:
            queueRefresh(placement: false)
        case .surroundings:
            surroundingsDidChange()
        case .appSwitched:
            // Which app is in front matters only to "follow focus" and "hide in full screen".
            if surroundingsTimer != nil { queueRefresh(placement: true) }
        case .windowMoved:
            pinFrame()
        }
    }

    /// Stores announce a change just BEFORE the new value is in place, and several often change
    /// together. So the work is put off to the next turn of the main loop and done once.
    private func queueRefresh(placement: Bool) {
        queuedRefreshNeedsPlacement = queuedRefreshNeedsPlacement || placement
        guard !refreshIsQueued else { return }
        refreshIsQueued = true
        DispatchQueue.main.async { [weak self] in self?.runQueuedRefresh() }
    }

    private func runQueuedRefresh() {
        let needsPlacement = queuedRefreshNeedsPlacement
        refreshIsQueued = false
        queuedRefreshNeedsPlacement = false
        if needsPlacement { refreshPlacement() } else { refreshPointer() }
    }
}
