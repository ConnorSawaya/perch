// FocusLoan.swift — remembers which app Perch borrowed the keyboard from, and gives it back.
//
// Perch borrows the keyboard in two situations: the island takes it while the pointer is over
// the open panel, and the Settings window takes it while it is open. Either way the focus has to
// go back to the app the user was working in, without them having to click.
//
// Usually nothing needs doing. The island's panel is "non-activating": it gets the keyboard
// while the user's app stays frontmost, and letting go is enough. But macOS sometimes makes
// Perch the frontmost app for real — measured on macOS 26: the first time the panel takes the
// keyboard after Perch was started by the app that is in front (a terminal, say), and always
// for the Settings window. Then letting go leaves Perch frontmost with nothing to type into,
// and the user's app stays greyed out. `repay()` fixes exactly that case, and only that case.
//
// Use from the main thread only.

import AppKit

final class FocusLoan {
    /// The app that was in front the last time Perch took the keyboard.
    private var lender: NSRunningApplication?

    /// Call just BEFORE Perch takes the keyboard.
    func noteLender() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lender = frontmost
    }

    /// Call AFTER Perch has let go of the keyboard. Does nothing unless Perch is still the active
    /// app with no window of its own that wants the keyboard.
    func repay() {
        let app = NSApplication.shared
        guard app.isActive, app.keyWindow == nil else { return }
        // An ordinary Perch window is open (Settings): the focus belongs with it, not elsewhere.
        let hasOwnWindow = app.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0.canBecomeKey }
        guard !hasOwnWindow else { return }
        if let lender, !lender.isTerminated {
            // The polite, modern way: tell macOS we step aside for that app, then bring it forward.
            app.yieldActivation(to: lender)
            lender.activate(from: .current)
        } else {
            // Nobody to hand it to by name. Hiding makes macOS pick whichever app was in front
            // before; the island itself is not affected (it is marked as never hidden). A moment
            // later Perch is un-hidden again, quietly, so its windows can be shown as usual.
            app.hide(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.unhideWithoutActivation() }
        }
        Log.debug("handed the keyboard focus back to the app it came from", "shell")
    }
}
