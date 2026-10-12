// FallbackMainMenu.swift — a minimal menu bar for when the Settings window is open.
//
// A background app has no menu bar, and without one the everyday shortcuts do not work in its
// windows: Cmd-W would not close Settings, Cmd-C / Cmd-V would not copy or paste in a text
// field, Cmd-Q would not quit. If the app has not set up a menu of its own, this installs the
// standard App / Edit / Window menus. Every item uses AppKit's standard actions, so no code
// here needs to know anything about Perch.

import AppKit

enum FallbackMainMenu {
    /// Installs the menu unless the app already has one.
    static func installIfNeeded() {
        let app = NSApplication.shared
        guard app.mainMenu == nil || app.mainMenu?.items.isEmpty == true else { return }
        let name = PerchPaths.appName
        let main = NSMenu()

        add(to: main, title: name, items: [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add(to: main, title: "Edit", items: [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let windowMenu = add(to: main, title: "Window", items: [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])

        app.mainMenu = main
        app.windowsMenu = windowMenu
    }

    /// A menu item whose action finds its own target (the focused view, window or the app).
    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @discardableResult
    private static func add(to main: NSMenu, title: String, items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }
}
