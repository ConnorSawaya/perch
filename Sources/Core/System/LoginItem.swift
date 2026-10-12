// LoginItem.swift — "open Perch when I log in".
//
// Uses the system's own login-item service (SMAppService), which shows Perch under
// System Settings → General → Login Items where the user can also turn it off. Nothing is written
// to disk by us. The service only works for a real, bundled app, so when Perch runs as a bare
// binary (tests, development) every call simply answers "no" instead of failing.

import Foundation
import Combine
import ServiceManagement

/// The one thing we need from the system, as a protocol so tests never touch the real service.
protocol LoginItemService {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

enum LoginItem {

    /// Turns "launch at login" on or off. Returns true when the system now matches what was asked.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        setEnabled(on, using: systemService())
    }

    /// True when Perch is currently registered to open at login.
    static var isEnabled: Bool {
        systemService()?.isRegistered ?? false
    }

    /// Makes the system match the user's `launchAtLogin` setting. Call once at launch and whenever
    /// the setting changes. Returns true when they agree afterwards.
    @discardableResult
    static func apply(_ settings: AppSettings) -> Bool {
        setEnabled(settings.launchAtLogin)
    }

    /// Keeps the system in step with the `launchAtLogin` setting from now on: applies it once
    /// straight away and again every time it changes. Keep the returned object for as long as
    /// that should go on (the app controller holds it for the life of the app).
    static func follow(_ settings: AppSettings) -> AnyCancellable {
        follow(settings, using: systemService())
    }

    static func follow(_ settings: AppSettings, using service: LoginItemService?) -> AnyCancellable {
        settings.$launchAtLogin.removeDuplicates().sink { on in
            _ = setEnabled(on, using: service)
        }
    }

    /// The same logic against any service (nil = unavailable). Tests pass a fake.
    static func setEnabled(_ on: Bool, using service: LoginItemService?) -> Bool {
        guard let service else { return false }
        if service.isRegistered == on { return true }
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            Log.error("Could not turn launch at login \(on ? "on" : "off"): \(error.localizedDescription)", "system")
            return false
        }
        return service.isRegistered == on
    }

    /// The real service, or nil when Perch is not running from an app bundle.
    private static func systemService() -> LoginItemService? {
        AppBundle.isRealApp ? MainAppLoginService() : nil
    }
}

/// SMAppService for the app itself.
private struct MainAppLoginService: LoginItemService {
    var isRegistered: Bool { SMAppService.mainApp.status == .enabled }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
