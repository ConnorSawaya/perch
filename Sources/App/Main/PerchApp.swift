// PerchApp.swift — where the program starts.
//
// Perch is an AppKit app with SwiftUI views inside it. This file reads the launch options, and
// then either draws the screens to image files and exits (`--snapshot <dir>`), or creates the
// application object, hands control to AppController (which builds and connects every part of
// the app) and starts the main event loop. Everything interesting is in AppController.swift.

import AppKit

@main
enum PerchApp {
    static func main() {
        let options = LaunchOptions.current
        let app = NSApplication.shared
        // A background ("accessory") app: no Dock icon and no menu bar of its own. The Settings
        // window temporarily turns Perch into a regular app while it is open.
        app.setActivationPolicy(.accessory)

        if let folder = options.snapshotDir {
            let failures = MainActor.assumeIsolated { SnapshotRunner.run(outputDir: folder) }
            exit(failures == 0 ? 0 : 1)
        }

        let controller = AppController(options: options)
        app.delegate = controller
        withExtendedLifetime(controller) {
            app.run()
        }
    }
}
