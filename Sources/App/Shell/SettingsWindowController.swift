// SettingsWindowController.swift — the ordinary window that holds the Settings screens.
//
// Perch normally runs as a background ("accessory") app: no Dock icon, no menu bar of its own,
// never in front. A settings window needs the opposite for a while, so:
//
//   show:   Perch becomes a regular app (Dock icon, menus, Cmd-Tab), comes to the front and
//           shows the window. The same window is reused every time.
//   close:  Perch goes back to being a background app.
//
// What is IN the window is the Settings module's business; this file only provides the frame.
// Use from the main thread only.

import AppKit
import SwiftUI

final class SettingsWindowController {
    private let env: AppEnv
    private let content: AnyView
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    /// True while Perch is a regular app because of this window.
    private var madeAppRegular = false
    private let focusLoan = FocusLoan()

    init(env: AppEnv, content: AnyView) {
        self.env = env
        self.content = content
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    /// Opens Settings, or brings it forward if it is already open. Pass a tab to land on it.
    func show(tab: SettingsTab?) {
        select(tab)
        let window = loadWindow()
        let app = NSApplication.shared
        // Remember which app the user came from, so closing Settings can take them back there.
        focusLoan.noteLender()
        FallbackMainMenu.installIfNeeded()
        if app.activationPolicy() != .regular {
            madeAppRegular = app.setActivationPolicy(.regular)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // Put the window in front even if macOS decides not to hand Perch the focus.
        window.orderFrontRegardless()
        app.activate()
        // Turning into a regular app takes effect a beat later. If the first request came too
        // early to count, ask once more on the next turn of the main loop.
        DispatchQueue.main.async {
            if !app.isActive { app.activate() }
        }
    }

    /// Chooses which Settings tab is showing. Nil leaves the current one alone.
    func select(_ tab: SettingsTab?) {
        guard let tab, env.ui.settingsTab != tab else { return }
        env.ui.settingsTab = tab
    }

    /// The window, built on first use.
    func loadWindow() -> NSWindow {
        if let window { return window }
        let size = ShellTuning.settingsSize, minSize = ShellTuning.settingsMinSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "\(PerchPaths.appName) Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        // Appear on whichever desktop the user is looking at instead of dragging them to another.
        window.collectionBehavior = [.moveToActiveSpace]

        let hosting = NSHostingView(rootView: content.frame(minWidth: minSize.width, maxWidth: .infinity,
                                                            minHeight: minSize.height, maxHeight: .infinity))
        // Let the content report its smallest size, but never let it resize the window by itself.
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.contentMinSize = minSize
        window.setContentSize(size)
        window.center()
        // Remember where the user put the window — but only in the real app, so that tests and
        // tools which build this window leave no saved preferences behind.
        // A run with PERCH_HOME set (a test) keeps everything in that folder and must not write
        // to the real preferences either.
        let isTestRun = !(ProcessInfo.processInfo.environment["PERCH_HOME"] ?? "").isEmpty
        if Bundle.main.bundleIdentifier == PerchPaths.bundleID, !isTestRun {
            window.setFrameAutosaveName("PerchSettingsWindow")
        }

        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { [weak self] _ in
            self?.windowDidClose()
        }
        self.window = window
        return window
    }

    /// Back to being a background app — after the close has finished, and only if this window
    /// was the reason Perch became a regular app and no other ordinary window is still open.
    private func windowDidClose() {
        guard madeAppRegular else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible != true else { return }
            let app = NSApplication.shared
            let otherWindowIsOpen = app.windows.contains { other in
                other !== self.window && other.isVisible && other.styleMask.contains(.titled) && !(other is NSPanel)
            }
            guard !otherWindowIsOpen else { return }
            self.madeAppRegular = false
            app.setActivationPolicy(.accessory)
            // With its last window gone Perch has nothing to be in front for: step back, so the
            // app the user was in before gets the keyboard again without an extra click.
            self.focusLoan.repay()
        }
    }
}
