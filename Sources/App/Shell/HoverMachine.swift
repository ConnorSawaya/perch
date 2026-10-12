// HoverMachine.swift — decides when the panel opens and closes (pure logic, no timers, no AppKit).
//
// The window controller tells this machine where the pointer is ("on the pill", "inside the open
// panel", "somewhere else") and what time it is. The machine answers with "open now", "close now"
// or "nothing yet — ask me again at time T". Keeping it free of real timers and real windows is
// what makes every rule below testable.
//
// OPENING (panel closed)
//   hover mode:  the pointer stays on the pill for `hoverDelay`  -> open
//                (a quick pass over the notch on the way to the menu bar opens nothing)
//   either mode: a click on the pill                             -> open at once
//
// CLOSING (panel open, pointer away from it)
//   Nothing closes by itself while `hold` is true (a request is waiting, or a text field is in use).
//   Otherwise the panel closes after a delay that depends on how it came to be open:
//
//     the pointer has been inside it, hover mode   -> `collapseDelay` after the pointer leaves
//     the pointer has been inside it, click mode   -> never by itself; a click elsewhere closes it
//     never visited, was held open by a request    -> `collapseDelay` after the hold ends
//     never visited, opened by itself              -> `ShellTuning.unvisitedLinger`
//
//   A click outside the panel closes it at once (unless held). In click mode a click on the
//   pill's footprint (the strip at the top of the panel where the pill was) closes it too —
//   even when held, because that is the user saying "go away". That click is used up: it does
//   not also press whatever the panel draws in that strip.
//
// After any close the pointer must leave the pill before hovering can open the panel again;
// otherwise closing with Escape while the pointer rests on the pill would reopen it instantly.
//
// DRAGGING
//   While a mouse button is held down, no countdown runs in either direction: dragging a window
//   past the notch does not pop the panel open, and selecting text in the panel does not close
//   it when the pointer strays outside. The countdown starts once the button is released.

import Foundation

struct HoverMachine {
    /// Everything the machine needs to know about the present moment.
    struct Input: Equatable {
        var isExpanded = false
        /// Pointer is over the pill's footprint.
        var onPill = false
        /// Pointer is inside the open panel (or within a few points of its edge).
        var inPanel = false
        /// Something forbids closing automatically: a pending request with "keep expanded while
        /// pending" on, or a text field that needs the keyboard.
        var hold = false
        /// A mouse button is being held down (the user is dragging something).
        var mouseButtonDown = false
        var trigger = ExpandTrigger.hover
        var hoverDelay: TimeInterval = 0.15
        var collapseDelay: TimeInterval = 0.4
    }

    enum Command: Equatable { case expand, collapse }

    struct Output: Equatable {
        /// What to do right now, if anything.
        var command: Command?
        /// When a countdown is running: the moment to call `update` again.
        var checkAgainAt: TimeInterval?
    }

    /// Where a mouse click landed.
    enum ClickZone: Equatable {
        /// On the pill's footprint (with the main mouse button).
        case pill
        /// Elsewhere inside the open panel.
        case panel
        /// Anywhere else on any screen.
        case outside
    }

    struct ClickResult: Equatable {
        var command: Command?
        /// True when the click has done its job and must not also reach the views under it.
        var consume = false
    }

    private var wasExpanded = false
    /// False right after a close, until the pointer has left the pill.
    private var hoverArmed = true
    /// When the pointer arrived on the pill (panel closed).
    private var onPillSince: TimeInterval?
    /// When the pointer was first seen away from the open panel with nothing holding it open.
    private var awaySince: TimeInterval?
    /// The pointer has been inside the panel since it opened.
    private var visited = false
    /// A hold was in force at some point since the panel opened.
    private var wasHeld = false

    /// Call whenever the pointer moves, a setting or the panel state changes, or a countdown is due.
    /// `now` is any steadily increasing clock, in seconds.
    mutating func update(_ input: Input, now: TimeInterval) -> Output {
        noteOpenOrClose(input)
        return input.isExpanded ? updateOpen(input, now: now) : updateClosed(input, now: now)
    }

    /// Call when a mouse button goes down.
    mutating func click(_ zone: ClickZone, _ input: Input) -> ClickResult {
        noteOpenOrClose(input)
        guard input.isExpanded else {
            guard zone == .pill else { return ClickResult() }
            onPillSince = nil
            // In click mode the click IS the "open" command, so it stops here. In hover mode it
            // merely beat the hover timer, and the views may still want it.
            return ClickResult(command: .expand, consume: input.trigger == .click)
        }
        switch zone {
        case .pill:
            visited = true
            return input.trigger == .click ? ClickResult(command: .collapse, consume: true) : ClickResult()
        case .panel:
            visited = true
            return ClickResult()
        case .outside:
            return input.hold ? ClickResult() : ClickResult(command: .collapse)
        }
    }

    // MARK: - Steps

    /// Notices that the panel was opened or closed (by this machine or by anything else) and
    /// starts the new state with a clean slate.
    private mutating func noteOpenOrClose(_ input: Input) {
        guard input.isExpanded != wasExpanded else { return }
        wasExpanded = input.isExpanded
        onPillSince = nil
        awaySince = nil
        if input.isExpanded {
            visited = false
            wasHeld = false
        } else {
            hoverArmed = false
        }
    }

    private mutating func updateClosed(_ input: Input, now: TimeInterval) -> Output {
        guard input.onPill else {
            hoverArmed = true
            onPillSince = nil
            return Output()
        }
        guard input.trigger == .hover, hoverArmed, !input.mouseButtonDown else {
            onPillSince = nil
            return Output()
        }
        let since = onPillSince ?? now
        onPillSince = since
        let due = since + max(0, input.hoverDelay)
        if now >= due {
            onPillSince = nil
            return Output(command: .expand)
        }
        return Output(checkAgainAt: due)
    }

    private mutating func updateOpen(_ input: Input, now: TimeInterval) -> Output {
        if input.hold { wasHeld = true }
        if input.inPanel {
            visited = true
            awaySince = nil
            return Output()
        }
        guard !input.hold, !input.mouseButtonDown, let delay = autoCloseDelay(input) else {
            awaySince = nil
            return Output()
        }
        let since = awaySince ?? now
        awaySince = since
        let due = since + delay
        if now >= due {
            awaySince = nil
            return Output(command: .collapse)
        }
        return Output(checkAgainAt: due)
    }

    /// How long the panel may stay open with the pointer away, or nil for "until told otherwise".
    /// This is the table in the comment at the top of the file.
    private func autoCloseDelay(_ input: Input) -> TimeInterval? {
        let collapseDelay = max(0, input.collapseDelay)
        if visited { return input.trigger == .hover ? collapseDelay : nil }
        return wasHeld ? collapseDelay : max(ShellTuning.unvisitedLinger, collapseDelay)
    }
}

/// When the panel may take the keyboard. It must never do so behind the user's back: only while
/// the pointer is deliberately over the open panel, or while a text field in it needs typing.
enum KeyPolicy {
    /// - Parameters:
    ///   - pointerOnPanel: the pointer is over the island.
    ///   - isParked: the panel opened by itself underneath a pointer that has not moved since.
    ///     A resting pointer is not a request for the keyboard, so typing keeps going to the
    ///     user's terminal until they actually move onto the panel.
    static func wantsKey(isExpanded: Bool, pointerOnPanel: Bool, isParked: Bool, needsKeyboard: Bool) -> Bool {
        guard isExpanded else { return false }
        return needsKeyboard || (pointerOnPanel && !isParked)
    }
}
