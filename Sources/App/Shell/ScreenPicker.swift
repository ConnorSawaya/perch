// ScreenPicker.swift — which display the island lives on, and whether it should be visible (pure rules).
//
// Two questions are answered here, both from plain values so they can be unit-tested:
//   1. `ScreenPicker.pick`: given the "Show on" setting and the connected displays, which one?
//   2. `IslandVisibility.verdict`: given that display and the "hide when..." settings, show or hide?
// `NotchWindowController` asks both every time something relevant changes.

import Foundation
import CoreGraphics

enum ScreenPicker {
    /// - Parameters:
    ///   - focusedScreenID: the display that currently has keyboard focus, if known.
    ///   - pointer: the pointer's position in screen space, if known.
    static func pick(mode: DisplayMode, screens: [ScreenInfo], focusedScreenID: UInt32?, pointer: CGPoint?) -> ScreenInfo? {
        let primary = screens.first { $0.hasMenuBar } ?? screens.first
        switch mode {
        case .builtin:
            // A Mac with its lid closed (or a desktop Mac) has no built-in display: use the primary one.
            return screens.first { $0.isBuiltin } ?? primary
        case .main:
            return primary
        case .followFocus:
            if let id = focusedScreenID, let focused = screens.first(where: { $0.id == id }) { return focused }
            if let pointer, let underPointer = screens.first(where: { $0.frame.holds(pointer) }) { return underPointer }
            return primary
        }
    }
}

enum IslandVisibility {
    enum Verdict: Equatable {
        case show
        case hide(Reason)
    }

    /// Why the island is hidden. Only used for the debug log, so it reads as a sentence.
    enum Reason: String, Equatable {
        case notRequested = "the app has not asked for the island yet"
        case noScreen = "there is no display to show it on"
        case noNotch = "this display has no notch and 'show on displays without a notch' is off"
        case noSessions = "no sessions are running and 'hide when there are no sessions' is on"
        case fullScreen = "this display is showing a full-screen app and 'hide in full screen' is on"
    }

    struct Input: Equatable {
        /// True between `NotchWindowController.show()` and `hide()`.
        var isRequested = true
        var screen: ScreenInfo?
        var showOnNonNotchDisplays = true
        var hideWhenNoSessions = false
        var sessionCount = 0
        /// True while the panel is open.
        var isExpanded = false
        var hideInFullScreen = false
        var screenIsFullScreen = false
    }

    static func verdict(_ input: Input) -> Verdict {
        guard input.isRequested else { return .hide(.notRequested) }
        guard let screen = input.screen else { return .hide(.noScreen) }
        if screen.notchRect == nil && !input.showOnNonNotchDisplays { return .hide(.noNotch) }
        if input.hideInFullScreen && input.screenIsFullScreen { return .hide(.fullScreen) }
        // An open panel is never hidden for lack of sessions: with nothing running, the only way it
        // can be open is that the user asked for it (the menu-bar icon's "Open Panel").
        if input.hideWhenNoSessions && input.sessionCount == 0 && !input.isExpanded { return .hide(.noSessions) }
        return .show
    }
}
