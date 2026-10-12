// PointerMonitor.swift — tells the window controller when the mouse moves or a button goes down.
//
// It does not decide anything; it only reports. Three sources are combined because no single one
// covers every case:
//
//   - A GLOBAL monitor hears mouse events that go to other apps. That is the normal case: Perch
//     sits in the background while the user works elsewhere. Watching the mouse this way needs no
//     permission (watching the keyboard would, and Perch never does that).
//   - A LOCAL monitor hears mouse events that come to Perch itself: clicks on the island, and
//     everything while the Settings window is in front. Only a local monitor can swallow a click.
//   - A slow POLL re-reads the pointer position on a timer. macOS does not reliably send
//     mouse-moved events to a window that belongs to a background app, so while the pointer is
//     over the island (or Perch is frontmost) the controller asks for a poll to be sure it
//     notices the pointer leaving. The poll is off the rest of the time.
//
// All callbacks arrive on the main thread.

import AppKit

/// Where the window controller gets its mouse facts from. The app uses the real mouse (the
/// defaults below). The shell's harness substitutes its own values so that it can act out
/// pointer movements on the real panel without touching the real mouse.
struct PointerSource {
    /// The pointer's position in screen coordinates.
    var location: () -> CGPoint = { NSEvent.mouseLocation }
    /// Which mouse buttons are held down right now, as a bit mask (0 = none).
    var pressedButtons: () -> Int = { NSEvent.pressedMouseButtons }
    /// True while Perch is in the middle of one continuous interaction of its own: one of its
    /// menus is open (a card's "Always allow…" list, a right-click menu, the menu-bar icon's
    /// menu), or a scroll bar or slider is being dragged. AppKit runs its event loop in a special
    /// "event tracking" mode for exactly as long as that lasts, which is what is read here.
    var isMidInteraction: () -> Bool = { RunLoop.main.currentMode == .eventTracking }
    /// False ignores the real mouse altogether: no global or local monitors are installed.
    var listensToSystemEvents = true
}

final class PointerMonitor {
    enum Source { case global, local }

    /// The pointer may have moved, a button was released, or it is simply time to look again.
    var onMove: (() -> Void)?
    /// A mouse button went down. `isPrimary` is true for the main (left) button. Return true to
    /// keep the click away from Perch's own views; that is only possible for `.local` clicks.
    var onMouseDown: ((_ isPrimary: Bool, _ source: Source) -> Bool)?

    /// Moves, drags, and button releases (a release ends a drag, which can start a countdown).
    private static let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                                       .leftMouseUp, .rightMouseUp, .otherMouseUp]
    private static let presses: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval?

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    deinit { stop() }

    func start() {
        guard !isRunning else { return }
        let mask = Self.moves.union(Self.presses)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            _ = self?.handle(event, from: .global)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, from: .local) ? nil : event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        setPollInterval(nil)
    }

    /// Turns the safety-net poll on (seconds between looks) or off (nil).
    func setPollInterval(_ interval: TimeInterval?) {
        guard interval != pollInterval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        pollTimer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.onMove?() }
        timer.tolerance = interval / 4
        // `.common` keeps the timer running while a menu is open or a control is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Returns true when the event should be swallowed.
    private func handle(_ event: NSEvent, from source: Source) -> Bool {
        if Self.presses.contains(NSEvent.EventTypeMask(type: event.type)) {
            return onMouseDown?(event.type == .leftMouseDown, source) ?? false
        }
        onMove?()
        return false
    }
}
