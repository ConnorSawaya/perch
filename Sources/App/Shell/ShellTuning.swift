// ShellTuning.swift — every "magic number" the window shell uses, in one place.
//
// These are the small distances and delays that make the island feel right. They are not user
// settings (those live in AppSettings); they are the fixed values behind them. Change one here
// and every part of the shell follows.

import Foundation
import CoreGraphics

enum ShellTuning {
    // MARK: Pointer

    /// Extra points around the island that still count as "on it", so a click on the very edge
    /// does not fall through to the app underneath.
    static let hitSlop: CGFloat = 4
    /// Extra points around the open panel the pointer may stray into before the panel starts
    /// counting down to close. Stops the panel closing when the pointer brushes past the edge.
    static let leaveSlop: CGFloat = 12
    /// Seconds a panel that opened by itself (a finished task, the menu-bar command) stays up
    /// when the pointer never comes near it.
    static let unvisitedLinger: TimeInterval = 6
    /// The pointer counts as "moved" once it is this far from where it was last seen.
    static let movementThreshold: CGFloat = 0.5
    /// Seconds a panel that opened by itself stays click-through, so a click the user was already
    /// making on the app underneath cannot land on a button that has only just appeared.
    static let surpriseClickGuard: TimeInterval = 0.4

    // MARK: Timers

    /// How often the pointer is re-read while it is over the island (see PointerMonitor for why).
    static let insidePollInterval: TimeInterval = 0.1
    /// How often the pointer is re-read while Perch itself is the frontmost app.
    static let activePollInterval: TimeInterval = 0.25
    /// How often to look again while one of Perch's menus is open, to notice it closing.
    static let menuPollInterval: TimeInterval = 0.15
    /// How often "which screen has focus?" and "is it full screen?" are re-checked, when the
    /// settings that need those answers are on.
    static let surroundingsInterval: TimeInterval = 2
    /// Displays come back in stages after wake or reconnect, so the island is placed at once and
    /// then again after this many seconds.
    static let screenSettleDelay: TimeInterval = 0.6

    // MARK: Screens

    /// Height of the stand-in pill on a display without a notch: the menu bar's height, kept
    /// inside this range, or `standInDefaultHeight` when the menu bar is hidden.
    static let standInHeightRange: ClosedRange<CGFloat> = 24...32
    static let standInDefaultHeight: CGFloat = 28
    /// Notch width as a share of the screen width (185 of 1512 points on a 14-inch MacBook Pro).
    /// Only used if a display reports a notch but not where it is.
    static let typicalNotchFraction: CGFloat = 185.0 / 1512.0

    // MARK: Shortcuts

    /// A request must have been waiting this long before a keyboard shortcut may say yes to it,
    /// so a second quick press cannot approve something that only just appeared.
    static let minimumAllowAge: TimeInterval = 0.4

    // MARK: Settings window

    static let settingsSize = CGSize(width: 860, height: 620)
    static let settingsMinSize = CGSize(width: 760, height: 520)
}
