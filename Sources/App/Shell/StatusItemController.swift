// StatusItemController.swift — Perch's icon in the menu bar and the menu under it.
//
// The icon is the bird from StatusIcon.swift, with an orange dot when a session is waiting for
// the user. The menu shows one status line ("3 sessions, 1 needs you") and a few commands. Every
// command goes through `AppActions`, the same path the views use, so this file holds no logic of
// its own. The icon appears and disappears live with the "Show menu-bar icon" setting.
//
// Create it once at launch, on the main thread, and keep it alive for as long as the app runs.

import AppKit
import Combine

final class StatusItemController: NSObject {
    private let env: AppEnv
    private let expander: PanelExpander
    private var statusItem: NSStatusItem?
    private var attentionDot: NSView?
    private var subscriptions = Set<AnyCancellable>()
    private var updateIsQueued = false
    /// What the menu and icon show right now, so nothing is redrawn when nothing changed.
    private var shown: StatusMenuModel?

    /// The menu under the icon. It exists (and works) even while the icon itself is switched off.
    let menu = NSMenu()
    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let panelItem = NSMenuItem(title: "Open Panel", action: #selector(togglePanel), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    private let muteItem = NSMenuItem(title: "Mute Sounds", action: #selector(toggleMute), keyEquivalent: "")
    private let demoItem = NSMenuItem(title: "Demo Mode", action: #selector(toggleDemo), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit Perch", action: #selector(quit), keyEquivalent: "q")

    init(env: AppEnv) {
        self.env = env
        expander = PanelExpander(env: env)
        super.init()
        buildMenu()
        setIconVisible(env.settings.showMenuBarIcon)
        watchStores()
    }

    deinit {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        statusLineItem.isEnabled = false
        let items: [NSMenuItem] = [statusLineItem, .separator(), panelItem, settingsItem, .separator(),
                                   muteItem, demoItem, .separator(), quitItem]
        for item in items {
            if item.action != nil { item.target = self }
            menu.addItem(item)
        }
    }

    /// Copies the current state into the menu and the icon.
    private func refresh() {
        let model = StatusMenuModel(env: env)
        guard model != shown else { return }
        shown = model
        statusLineItem.title = model.statusLine
        panelItem.title = model.panelItemTitle
        muteItem.state = model.isMuted ? .on : .off
        demoItem.state = model.isDemo ? .on : .off
        statusItem?.button?.toolTip = "Perch — \(model.statusLine)"
        attentionDot?.isHidden = !model.needsAttention
    }

    @objc private func togglePanel() { expander.toggle() }
    @objc private func openSettings() { env.actions.openSettings(nil) }
    @objc private func toggleMute() { env.actions.toggleMute() }
    @objc private func toggleDemo() { env.actions.setDemo(!env.ui.isDemo) }
    @objc private func quit() { env.actions.quit() }

    // MARK: - Icon

    /// Adds the icon to the menu bar or takes it out again.
    private func setIconVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.menu = menu
            if let button = item.button {
                button.image = StatusIcon.image()
                button.imagePosition = .imageOnly
                button.setAccessibilityLabel("Perch")
                attentionDot = makeAttentionDot(in: button)
            }
            statusItem = item
            shown = nil
            refresh()
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            attentionDot = nil
        }
    }

    /// The orange dot is a tiny coloured view laid over the icon, in the empty corner that
    /// StatusIcon keeps free for it.
    private func makeAttentionDot(in button: NSStatusBarButton) -> NSView {
        let diameter = StatusIcon.dotRadius * 2
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dot.layer?.cornerRadius = StatusIcon.dotRadius
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        // The icon is centred in the button, so the dot is placed relative to the button's
        // centre. Layout measures downwards, the icon's own coordinates upwards — hence the minus.
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: diameter),
            dot.heightAnchor.constraint(equalToConstant: diameter),
            dot.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: StatusIcon.dotCenter.x - StatusIcon.size.width / 2),
            dot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: -(StatusIcon.dotCenter.y - StatusIcon.size.height / 2)),
        ])
        return dot
    }

    // MARK: - Keeping up to date

    private func watchStores() {
        env.settings.$showMenuBarIcon.removeDuplicates().dropFirst()
            .sink { [weak self] visible in self?.setIconVisible(visible) }
            .store(in: &subscriptions)

        // Anything that changes the status line, the dot or a tick. Stores announce a change
        // just before the new value is in place, so the refresh waits one turn of the main loop
        // (which also folds a burst of changes into a single refresh).
        Publishers.MergeMany([
            env.sessions.objectWillChange.eraseToAnyPublisher(),
            env.ui.objectWillChange.eraseToAnyPublisher(),
            env.settings.$soundsEnabled.map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] in self?.queueRefresh() }
        .store(in: &subscriptions)
    }

    private func queueRefresh() {
        guard !updateIsQueued, statusItem != nil else { return }
        updateIsQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateIsQueued = false
            self.refresh()
        }
    }
}

extension StatusItemController: NSMenuDelegate {
    /// Called just before the menu opens, so what it shows is never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }
}
