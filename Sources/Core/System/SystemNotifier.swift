// SystemNotifier.swift — optional macOS notifications ("Claude needs your permission", "Done").
//
// Off by default; the user turns it on with the `systemNotifications` setting. The first time a
// notification is needed, macOS asks the user whether Perch may show them. If the answer is no —
// or notifications cannot work at all, as when Perch runs as a bare binary in tests — every call
// quietly does nothing.
//
// Clicking a notification hands the session's id to `onOpenSession`, so the app can jump to it.
// Create the notifier early at launch: macOS only delivers the click that opened the app to a
// handler that is already in place.
//
// The notification itself is silent; sounds are SoundEngine's job, so the two never double up.

import Foundation
import UserNotifications

/// One notification, as plain data.
struct NotificationPayload: Equatable {
    var title: String
    var body: String
    /// `Session.id` of the session it is about, if any. Comes back when the user clicks it.
    var sessionID: String?
    /// Notifications with the same identifier replace each other, so one session never fills the
    /// screen with a stack of stale banners.
    var identifier: String

    static let fallbackTitle = "Perch"
    static let maxTitleLength = 90
    static let maxBodyLength = 260

    /// Tidies raw text into something that fits a banner. `unique` supplies the identifier for
    /// notifications that are not about a session.
    init(title: String, body: String, sessionID: String?, unique: () -> String = { UUID().uuidString }) {
        let cleanTitle = Self.clip(title.split(whereSeparator: \.isNewline).joined(separator: " "), to: Self.maxTitleLength)
        self.title = cleanTitle.isEmpty ? Self.fallbackTitle : cleanTitle
        self.body = Self.clip(body, to: Self.maxBodyLength)
        let session = sessionID.flatMap { $0.isEmpty ? nil : $0 }
        self.sessionID = session
        self.identifier = "perch." + (session.map { "session." + $0 } ?? "note." + unique())
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit - 1)) + "…"
    }
}

/// The system's notification service, reduced to what we use, so tests can stand in for it.
protocol NotificationService: AnyObject {
    /// Calls back with true when notifications may be shown, asking the user first if they have
    /// never been asked. The callback may arrive on any thread.
    func ensurePermission(_ completion: @escaping (Bool) -> Void)
    func post(_ payload: NotificationPayload)
    /// Called (on any thread) with the session id of a notification the user clicked.
    var onClick: ((String?) -> Void)? { get set }
}

final class SystemNotifier: SystemNotifying {
    /// Called on the main thread with `Session.id` when the user clicks a notification about a session.
    var onOpenSession: ((String) -> Void)?

    private let settings: AppSettings
    private let service: NotificationService?

    convenience init(settings: AppSettings) {
        // UNUserNotificationCenter crashes the process when there is no app bundle, so the real
        // service is only created inside a proper .app.
        self.init(settings: settings, service: AppBundle.isRealApp ? UserNotificationService() : nil)
    }

    /// For tests: any service, or nil for "notifications are unavailable".
    init(settings: AppSettings, service: NotificationService?) {
        self.settings = settings
        self.service = service
        service?.onClick = { [weak self] sessionID in
            guard let sessionID, !sessionID.isEmpty else { return }
            DispatchQueue.main.async { self?.onOpenSession?(sessionID) }
        }
    }

    func notify(title: String, body: String, sessionID: String?) {
        if Thread.isMainThread {
            post(title: title, body: body, sessionID: sessionID)
        } else {
            DispatchQueue.main.async { self.post(title: title, body: body, sessionID: sessionID) }
        }
    }

    /// True when a notification would be attempted right now (the setting is on and the service exists).
    var isAvailable: Bool { settings.systemNotifications && service != nil }

    private func post(title: String, body: String, sessionID: String?) {
        guard settings.systemNotifications, let service else { return }
        let payload = NotificationPayload(title: title, body: body, sessionID: sessionID)
        service.ensurePermission { allowed in
            if allowed { service.post(payload) }
        }
    }
}

/// True when Perch is running as a real `.app`. The system services that are tied to an app's
/// identity (notifications, login items) only work then.
enum AppBundle {
    static var isRealApp: Bool {
        isRealApp(bundleIdentifier: Bundle.main.bundleIdentifier, bundlePath: Bundle.main.bundlePath)
    }

    static func isRealApp(bundleIdentifier: String?, bundlePath: String) -> Bool {
        guard let id = bundleIdentifier, !id.isEmpty else { return false }
        return (bundlePath as NSString).pathExtension.lowercased() == "app"
    }
}

/// The real thing: UNUserNotificationCenter.
private final class UserNotificationService: NSObject, NotificationService, UNUserNotificationCenterDelegate {
    var onClick: ((String?) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private static let sessionKey = "perchSessionID"

    override init() {
        super.init()
        center.delegate = self
    }

    func ensurePermission(_ completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { [center] current in
            switch current.authorizationStatus {
            case .authorized, .provisional:
                completion(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, error in
                    if let error { Log.debug("Notification permission request failed: \(error.localizedDescription)", "system") }
                    completion(granted)
                }
            default:
                completion(false)
            }
        }
    }

    func post(_ payload: NotificationPayload) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        if let sessionID = payload.sessionID {
            content.userInfo = [Self.sessionKey: sessionID]
            content.threadIdentifier = sessionID
        }
        let request = UNNotificationRequest(identifier: payload.identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error { Log.debug("Could not post a notification: \(error.localizedDescription)", "system") }
        }
    }

    /// Show the banner even while one of Perch's own windows (Settings) is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            onClick?(response.notification.request.content.userInfo[Self.sessionKey] as? String)
        }
        completionHandler()
    }
}
