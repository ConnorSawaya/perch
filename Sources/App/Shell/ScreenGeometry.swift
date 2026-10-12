// ScreenGeometry.swift — where the notch is and where the island's window goes (pure maths).
//
// Nothing in this file talks to AppKit. A display is described by a plain `ScreenInfo` value, so
// every rule here can be unit-tested with made-up screens. `ScreenReader.swift` fills these values
// in from the real displays, and `NotchWindowController` applies the answers.
//
// Two coordinate spaces are involved:
//   - "screen space" is AppKit's: the origin is the bottom-left of the primary display and y
//     grows UPWARDS.
//   - "window space" is what the contract's `IslandMetrics.islandRect` uses: the origin is the
//     window's TOP-left corner and y grows DOWNWARDS (the way SwiftUI lays views out).
// `IslandPlacement.screenRect(fromWindowRect:)` converts from the second to the first.

import Foundation
import CoreGraphics

/// The facts about one display that the shell needs.
struct ScreenInfo: Equatable {
    /// The system's number for the display (a `CGDirectDisplayID`).
    var id: UInt32
    /// The whole display, in screen space.
    var frame: CGRect
    /// The display minus the menu bar and the Dock.
    var visibleFrame: CGRect
    /// Height of the strip at the top that a notch cuts into (0 when there is no notch).
    var safeAreaTop: CGFloat = 0
    /// The usable strips to the left and right of the notch (nil when there is no notch).
    var topLeftArea: CGRect?
    var topRightArea: CGRect?
    var isBuiltin = false
    /// True for the display that carries the menu bar (the "primary" display).
    var hasMenuBar = false

    /// The notch's rectangle in screen space, or nil on a display without one.
    var notchRect: CGRect? {
        guard safeAreaTop > 0 else { return nil }
        if let left = topLeftArea, let right = topRightArea, right.minX > left.maxX {
            return CGRect(x: left.maxX, y: frame.maxY - safeAreaTop, width: right.minX - left.maxX, height: safeAreaTop)
        }
        // The display says it has a notch but not where: assume the usual size, centred.
        let width = (frame.width * ShellTuning.typicalNotchFraction).rounded()
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - safeAreaTop, width: width, height: safeAreaTop)
    }

    /// Height of the menu bar on this display right now (0 when it is hidden or lives elsewhere).
    var menuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }

    /// Height of the display minus the menu bar and the Dock (the whole height if that is unknown).
    var usableHeight: CGFloat {
        visibleFrame.height > 0 ? min(visibleFrame.height, frame.height) : frame.height
    }
}

/// Where the island's window sits on one particular display.
struct IslandPlacement: Equatable {
    var screenID: UInt32
    var hasNotch: Bool
    /// Published to the views as `UIState.notchSize`: the real notch, or a zero-width stand-in
    /// (so the pill is just its two wings joined together) on a display without one.
    var notchSize: CGSize
    /// The window's frame in screen space. Its top edge is the top of the display and it is
    /// centred on the notch (which is not always the exact centre of the display), to the
    /// nearest whole point: macOS only places windows on whole points. It has the contract's
    /// fixed size, except on a display too small to hold it, where it is cut short at the bottom.
    var windowFrame: CGRect

    init(screen: ScreenInfo, windowSize: CGSize) {
        screenID = screen.id
        let centreX: CGFloat
        if let notch = screen.notchRect {
            hasNotch = true
            notchSize = notch.size
            centreX = notch.midX
        } else {
            hasNotch = false
            notchSize = CGSize(width: 0, height: IslandPlacement.standInHeight(menuBarHeight: screen.menuBarHeight))
            centreX = screen.frame.midX
        }
        // Never taller than the usable part of the display (what is left beside the menu bar
        // and the Dock). That only matters on small displays. The macOS 26 window server is
        // known to stop drawing a transparent window that is as tall as the whole screen.
        let height = min(windowSize.height, screen.usableHeight)
        // Whole points only. AppKit would round a half-point origin down by itself; doing it here
        // keeps this value identical to the frame the window really ends up with.
        let x = (centreX - windowSize.width / 2).rounded(.down)
        windowFrame = CGRect(x: x, y: screen.frame.maxY - height, width: windowSize.width, height: height)
    }

    /// Height of the pill on a display without a notch: as tall as the menu bar it hangs in.
    static func standInHeight(menuBarHeight: CGFloat) -> CGFloat {
        guard menuBarHeight > 0 else { return ShellTuning.standInDefaultHeight }
        let range = ShellTuning.standInHeightRange
        return min(max(menuBarHeight, range.lowerBound), range.upperBound)
    }

    /// Converts a rectangle from window space (top-left origin) to screen space (bottom-left origin).
    func screenRect(fromWindowRect rect: CGRect) -> CGRect {
        CGRect(x: windowFrame.minX + rect.minX, y: windowFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// The two rectangles the pointer is compared against, in screen space.
struct IslandZones: Equatable {
    /// Footprint of the collapsed pill. While the panel is open this is the strip at its top
    /// where the pill used to be.
    var pill: CGRect
    /// Whatever is showing right now: the pill, or the open panel.
    var island: CGRect

    /// `pillRect` and `islandRect` are in window space, exactly as `IslandMetrics` reports them.
    init(placement: IslandPlacement, pillRect: CGRect, islandRect: CGRect) {
        pill = placement.screenRect(fromWindowRect: pillRect)
        island = placement.screenRect(fromWindowRect: islandRect)
    }

    /// Where a point is relative to the island.
    struct Hit: Equatable {
        /// Over the pill's footprint.
        var onPill = false
        /// Over the island: clicks here belong to Perch.
        var onIsland = false
        /// Over the island or within a few points of it: not yet counted as "left".
        var nearIsland = false
    }

    func hit(_ point: CGPoint) -> Hit {
        Hit(onPill: pill.grown(by: ShellTuning.hitSlop).holds(point),
            onIsland: island.grown(by: ShellTuning.hitSlop).holds(point),
            nearIsland: island.grown(by: ShellTuning.leaveSlop).holds(point))
    }

    /// True for a point to the right of the notch: over the pill's right-hand "wing" (of width
    /// `wing`) or beyond. While the panel is open, that is where its top strip shows the usage
    /// readouts, which are a button.
    func isRightOfNotch(_ point: CGPoint, wing: CGFloat) -> Bool {
        point.x > pill.maxX - wing
    }
}

extension CGRect {
    /// The rectangle made larger by `amount` on every side.
    func grown(by amount: CGFloat) -> CGRect { insetBy(dx: -amount, dy: -amount) }

    /// Like `contains`, but the right and top edges count as inside. The pointer can sit exactly
    /// on the top edge of the screen, which is also the top edge of the island.
    func holds(_ point: CGPoint) -> Bool {
        !isNull && point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
