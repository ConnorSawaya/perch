// ShellWatcher.swift — everything the window controller needs to be told about, in one list.
//
// The island has to react to three kinds of news:
//   - the app's own state changing (stores and settings, through Combine);
//   - the Mac's surroundings changing (displays, Spaces, wake from sleep, which app is in front);
//   - the system moving the window behind our back.
// This file subscribes to all of them and boils each down to one of a handful of `Change`
// values. It decides nothing; NotchWindowController decides what each change means.
//
// Stores announce a change just BEFORE the new value is in place (that is how @Published works),
// so whoever receives `.placement` or `.pointer` must wait a turn of the main loop before
// reading the stores. The controller does.

import AppKit
import Combine

final class ShellWatcher {
    enum Change {
        /// Something that decides WHERE the island is or WHETHER it shows (display setting, the
        /// "hide when..." settings, sessions appearing or all going away, the panel opening).
        case placement
        /// Something that changes the island's size or the open/close rules, or how the pointer
        /// has to be watched.
        case pointer
        /// Displays, Spaces or sleep state changed. These settle in stages.
        case surroundings
        /// The user switched to another app.
        case appSwitched
        /// The island's window was moved by something other than us.
        case windowMoved
    }

    private let env: AppEnv
    private let window: NSWindow
    private let onChange: (Change) -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var observations: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(env: AppEnv, window: NSWindow, onChange: @escaping (Change) -> Void) {
        self.env = env
        self.window = window
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard subscriptions.isEmpty else { return }
        let ui = env.ui, settings = env.settings, sessions = env.sessions

        report(.placement, when: [
            changes(settings.$displayMode), changes(settings.$showOnNonNotchDisplays),
            changes(settings.$hideWhenNoSessions), changes(settings.$hideInFullScreen),
            changes(sessions.$sessions.map(\.isEmpty)), changes(ui.$isExpanded),
        ])
        report(.pointer, when: [
            changes(ui.$desiredPanelHeight), changes(ui.$notchSize), changes(ui.$needsKeyboard),
            changes(settings.$panelWidth), changes(settings.$panelMaxHeight), changes(settings.$pillStyle),
            changes(settings.$expandTrigger), changes(settings.$hoverDelay), changes(settings.$collapseDelay),
            changes(settings.$keepExpandedWhilePending), changes(sessions.$pending.map(\.isEmpty)),
        ])

        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        report(.surroundings, on: app, NSApplication.didChangeScreenParametersNotification)
        report(.surroundings, on: workspace, NSWorkspace.didWakeNotification)
        report(.surroundings, on: workspace, NSWorkspace.screensDidWakeNotification)
        report(.surroundings, on: workspace, NSWorkspace.sessionDidBecomeActiveNotification)
        report(.surroundings, on: workspace, NSWorkspace.activeSpaceDidChangeNotification)
        report(.appSwitched, on: workspace, NSWorkspace.didActivateApplicationNotification)
        // Perch coming to the front (its Settings window) or leaving it changes how the pointer
        // has to be watched; see PointerMonitor.
        report(.pointer, on: app, NSApplication.didBecomeActiveNotification)
        report(.pointer, on: app, NSApplication.didResignActiveNotification)
        report(.windowMoved, on: app, NSWindow.didMoveNotification, object: window)
    }

    func stop() {
        subscriptions.removeAll()
        for observation in observations { observation.center.removeObserver(observation.token) }
        observations.removeAll()
    }

    // MARK: - Helpers

    private func report(_ change: Change, when publishers: [AnyPublisher<Void, Never>]) {
        Publishers.MergeMany(publishers)
            .sink { [weak self] in self?.onChange(change) }
            .store(in: &subscriptions)
    }

    private func report(_ change: Change, on center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            self?.onChange(change)
        }
        observations.append((center, token))
    }

    /// A stream that fires each time `publisher`'s value really changes (not for the value it
    /// already has when we start listening).
    private func changes<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Output: Equatable, P.Failure == Never {
        publisher.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
    }
}
