// NotchPanel.swift — the invisible window that sits over the notch, and the view that puts SwiftUI in it.
//
// The panel is a fixed-size, fully transparent rectangle pinned to the top of the screen. The
// SwiftUI island draws itself at the panel's top-centre; everything else stays see-through.
// The panel is set up so that it:
//   - floats above the menu bar and the notch, on every Space and beside full-screen apps;
//   - never makes Perch the frontmost app (it is a "non-activating" panel), so showing it does
//     not pull focus away from the terminal;
//   - can take the keyboard only while `allowsKey` is true. NotchWindowController flips that
//     switch; see KeyPolicy for when.
// Which clicks reach the panel and which pass through to the apps below is also decided by
// NotchWindowController (through `ignoresMouseEvents`).

import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    /// The panel may become the key window (receive typing) only while this is true.
    var allowsKey = false
    private let focusLoan = FocusLoan()

    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        // Three levels above the menu bar: over the notch and the menu-bar icons, under open menus.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Panels normally vanish when their app is not active. Perch is never active.
        hidesOnDeactivate = false
        canHide = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // When the panel is allowed the keyboard, any click in it should give it the keyboard,
        // not only a click on a text field.
        becomesKeyOnlyIfNeeded = false
        allowsToolTipsWhenApplicationIsInactive = true
        // Click-through until the controller sees the pointer on the island.
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// AppKit likes to push windows down below the menu bar (after wake, or when displays
    /// change). The island belongs over the menu bar, so the frame is taken exactly as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// A key press that nothing in the island wanted ends up here, and AppKit's usual answer
    /// is the alert sound. The island can hold the keyboard merely because the pointer is
    /// resting on it, so a stray key press is ignored quietly instead.
    override func noResponder(for eventSelector: Selector) {
        if eventSelector == #selector(NSResponder.keyDown(with:)) { return }
        super.noResponder(for: eventSelector)
    }

    /// Takes the keyboard (if `allowsKey` permits), remembering whose it was.
    func takeKey() {
        focusLoan.noteLender()
        makeKey()
    }

    /// Takes the panel off the screen, handing the keyboard back if the panel had it.
    func leaveScreen() {
        let hadKey = isKeyWindow
        allowsKey = false
        if isVisible { orderOut(nil) }
        if hadKey { focusLoan.repay() }
    }

    /// Hands the keyboard back to whatever the user was typing in. The panel stays on screen.
    func giveUpKey() {
        guard isKeyWindow else { return }
        // A key window stays key until it leaves the screen or another window takes over, and
        // AppKit has no "stop being key" call. Stepping out and straight back in is the way to
        // let go. The two steps reach the window server back to back, well inside one frame.
        orderOut(nil)
        orderFrontRegardless()
        // Normally that is all. FocusLoan covers the case where macOS made Perch frontmost.
        focusLoan.repay()
    }
}

/// Hosts the SwiftUI island inside the panel.
final class NotchHostingView: NSHostingView<AnyView> {
    /// Wraps `content` so it fills the panel and hangs from its top edge, wherever the notch is.
    static func hosting(_ content: AnyView, size: CGSize) -> NotchHostingView {
        let pinned = AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).ignoresSafeArea())
        let view = NotchHostingView(rootView: pinned)
        // The window has a fixed size; the SwiftUI content must never try to resize it.
        view.sizingOptions = []
        // The island draws INTO the notch strip, which SwiftUI would otherwise treat as off limits.
        view.safeAreaRegions = []
        view.frame = CGRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        return view
    }

    /// Without this the first click on a window of a background app is spent on "waking" the
    /// window, and the button under the pointer would need a second click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
