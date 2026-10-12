// FullScreenDetector.swift — "is this display showing a full-screen app right now?" (pure rule).
//
// macOS has no single public call that answers this for every display, so two signals are
// combined. Either one saying "full screen" is enough.
//
// A. THE SYSTEM'S WORD, for the display the user is working on. macOS publishes the
//    "presentation" of the app in front, and that includes whether it is in a full-screen Space.
//    This is exact, but it only describes the display that has the keyboard focus.
//
// B. THE WINDOW LIST, for any display. From the windows currently on screen (their sizes and
//    stacking layers only; no titles, no contents, no special permission), a display counts as
//    full screen when BOTH are true:
//      1. The menu bar is not at the top of the display. In a full-screen Space the system
//         slides the menu bar away; on the normal desktop it is always there.
//      2. Some other app has an ordinary window covering the display from top to bottom
//         (starting no lower than the notch). Full-screen and split-view windows do; desktop
//         windows cannot, because the menu bar is in the way.
//
// Known limits of B, chosen to err towards "not full screen" (the island simply stays visible):
//   - If the menu bar is set to hide automatically AND a window covers the whole height of the
//     display, that counts as full screen. In practice it looks like full screen too.
//   - On a display that does NOT have the focus, revealing the menu bar in full screen brings
//     the island back for as long as the menu bar is showing. (On the focused display signal A
//     keeps it hidden.)
//
// `ScreenReader` supplies the real facts; the rules themselves are tested with made-up ones.

import Foundation
import CoreGraphics

/// One window from the system's on-screen list. `bounds` uses Core Graphics' global coordinates:
/// the origin is the TOP-left of the primary display and y grows downwards.
struct WindowSnapshot: Equatable {
    /// Stacking layer: 0 for ordinary app windows, 24 for the menu bar, and so on.
    var layer: Int
    var bounds: CGRect
    var ownerPID: Int32
    var alpha: Double = 1
}

enum FullScreenDetector {
    /// The stacking layer the system menu bar lives on.
    static let menuBarLayer = 24
    /// The stacking layer of ordinary app windows.
    static let normalLayer = 0

    /// Signal A. `frontAppIsFullScreen` describes the app in front, so it only says something
    /// about the display that app is on: the one with the keyboard focus.
    static func systemSaysFullScreen(displayHasFocus: Bool, frontAppIsFullScreen: Bool) -> Bool {
        displayHasFocus && frontAppIsFullScreen
    }

    /// Signal B.
    /// - Parameters:
    ///   - screenBounds: the display in Core Graphics' global coordinates (top-left origin).
    ///   - safeAreaTop: height of the notch strip on this display, 0 without a notch.
    ///   - ownPID: Perch's own process id; its windows never count.
    static func isFullScreen(screenBounds: CGRect, safeAreaTop: CGFloat, windows: [WindowSnapshot], ownPID: Int32) -> Bool {
        guard screenBounds.width > 0, screenBounds.height > 0 else { return false }
        if menuBarIsShowing(on: screenBounds, windows: windows) { return false }
        return windows.contains { window in
            window.layer == normalLayer && window.ownerPID != ownPID && window.alpha > 0
                && coversFullHeight(window.bounds, of: screenBounds, safeAreaTop: safeAreaTop)
        }
    }

    /// True when a menu-bar-layer window is sitting along the top edge of the display.
    static func menuBarIsShowing(on screenBounds: CGRect, windows: [WindowSnapshot]) -> Bool {
        windows.contains { window in
            window.layer == menuBarLayer && window.alpha > 0
                && abs(window.bounds.minY - screenBounds.minY) <= 1
                && horizontalOverlap(window.bounds, screenBounds) >= screenBounds.width / 2
        }
    }

    /// True when the window reaches from the top of the display (the notch strip may stay
    /// uncovered) all the way to the bottom, and is wide enough to be a real tile rather than a sliver.
    private static func coversFullHeight(_ bounds: CGRect, of screenBounds: CGRect, safeAreaTop: CGFloat) -> Bool {
        bounds.minY <= screenBounds.minY + max(0, safeAreaTop) + 0.5
            && bounds.maxY >= screenBounds.maxY - 0.5
            && horizontalOverlap(bounds, screenBounds) >= screenBounds.width / 4
    }

    private static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }
}
