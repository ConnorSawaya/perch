// ScreenReader.swift — reads the real displays and windows from macOS.
//
// This is the thin layer between the system and the pure rules in ScreenGeometry.swift,
// ScreenPicker.swift and FullScreenDetector.swift: it only gathers facts and hands them over as
// plain values. Call it on the main thread.

import AppKit
import CoreGraphics

enum ScreenReader {
    /// Every connected display. The first one is the display that carries the menu bar.
    static func screens() -> [ScreenInfo] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = displayID(of: screen) else { return nil }
            return ScreenInfo(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame,
                              safeAreaTop: screen.safeAreaInsets.top,
                              topLeftArea: screen.auxiliaryTopLeftArea, topRightArea: screen.auxiliaryTopRightArea,
                              isBuiltin: CGDisplayIsBuiltin(id) != 0, hasMenuBar: index == 0)
        }
    }

    /// The display the user is working on: the one holding the window that receives typing.
    static func focusedScreenID() -> UInt32? {
        NSScreen.main.flatMap(displayID(of:))
    }

    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// True when the display is showing a full-screen app. See FullScreenDetector for the rules.
    static func isFullScreen(_ screen: ScreenInfo) -> Bool {
        // The cheap, exact signal first; the window list is only read when it has nothing to say.
        let app = NSApplication.shared
        // While a Perch window has the keyboard (the island under the pointer, say), "the display
        // with the focus" is just Perch's own and tells nothing about where the app in front is.
        let displayHasFocus = app.keyWindow == nil && focusedScreenID() == screen.id
        if FullScreenDetector.systemSaysFullScreen(displayHasFocus: displayHasFocus,
                                                   frontAppIsFullScreen: app.currentSystemPresentationOptions.contains(.fullScreen)) {
            return true
        }
        return FullScreenDetector.isFullScreen(screenBounds: CGDisplayBounds(screen.id), safeAreaTop: screen.safeAreaTop,
                                               windows: onScreenWindows(), ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// The windows currently on screen, front to back. Only layer, position, size, owner and
    /// opacity are read, which needs no permission (titles and contents would).
    static func onScreenWindows() -> [WindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return WindowSnapshot(layer: layer, bounds: bounds, ownerPID: pid, alpha: alpha)
        }
    }
}
