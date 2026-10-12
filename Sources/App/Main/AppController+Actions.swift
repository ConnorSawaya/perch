// AppController+Actions.swift — what every button, menu item and shortcut in Perch does.
//
// Views never change anything themselves; they call one of these AppActions methods (through
// `@Environment(\.perchActions)`), and so do the menu-bar menu and the keyboard shortcuts. Each
// method is a few lines that pass the request to the part of the app that does the work.

import AppKit

extension AppController: AppActions {

    // MARK: - Requests and sessions

    func resolve(_ request: PendingRequest, _ decision: Decision) {
        // Requests that belong to the demo are answered by the demo and never reach an agent.
        if demo.handle(request, decision) { return }
        engine.resolve(request.id, with: decision)
    }

    func jump(to session: Session) {
        switch jumper.jump(to: session) {
        case .focused, .activatedApp:
            // The user is now looking at the terminal; the panel would only be in the way.
            setExpanded(false)
        case .failed(let reason):
            Log.info("jump to \(session.id) failed: \(reason)")
            note("Jump", "Could not jump to the session's terminal: \(reason)", agent: session.agent, sessionID: session.id)
            showToast(reason, systemImage: "arrow.up.forward.app", isProblem: true)
        }
    }

    func dismiss(_ session: Session) {
        if demo.dismiss(session) { return }
        engine.dismiss(sessionID: session.id)
    }

    // MARK: - Panel and Settings

    func setExpanded(_ expanded: Bool) {
        guard env.ui.isExpanded != expanded else { return }
        env.ui.isExpanded = expanded
    }

    func openSettings(_ tab: SettingsTab?) {
        // The open panel would sit on top of the Settings window.
        setExpanded(false)
        refreshAgents()
        settingsWindow?.show(tab: tab)
    }

    // MARK: - Agents

    /// Looks for installed agents and re-reads their settings files, then fills AgentsStore.
    /// This runs on the main thread, where the adapters ask to be called: measured on a Mac with
    /// two agents installed, all four checks together take about 8 ms the first time and about
    /// 1 ms after that, so there is nothing worth moving to another thread. If one ever is slow,
    /// the log says so.
    func refreshAgents() {
        let started = Date()
        env.agents.serverRunning = server.isRunning
        env.agents.helperInstalled = HelperInstaller.isInstalled
        let statuses = orderedAdapters.map { $0.status() }
        if env.agents.statuses != statuses { env.agents.statuses = statuses }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        if milliseconds > 100 {
            Log.error("checking the agents took \(milliseconds) ms on the main thread")
        } else {
            Log.debug("checked \(statuses.count) agents in \(milliseconds) ms")
        }
    }

    func installHooks(for agent: AgentKind) {
        guard let adapter = adapters[agent] else { return }
        guard options.mayChangeAgentSettings else {
            env.agents.lastMessage = LaunchOptions.agentSettingsLockedMessage
            Log.info("did not connect \(agent.rawValue): agent settings are read-only in a PERCH_HOME run")
            return
        }
        // Hooks point at the helper and the helper talks to the socket, so both come first.
        installHelper()
        if !server.isRunning {
            do { try server.start() } catch {
                Log.error("could not start listening before connecting \(agent.rawValue): \(describe(error))")
            }
        }
        do {
            env.agents.lastMessage = try adapter.installHooks()
            Log.info("connected \(agent.rawValue)")
        } catch {
            env.agents.lastMessage = "Could not connect \(agent.displayName): \(describe(error))"
            Log.error("connecting \(agent.rawValue) failed: \(describe(error))")
        }
        refreshAgents()
    }

    func uninstallHooks(for agent: AgentKind) {
        guard let adapter = adapters[agent] else { return }
        guard options.mayChangeAgentSettings else {
            env.agents.lastMessage = LaunchOptions.agentSettingsLockedMessage
            Log.info("did not disconnect \(agent.rawValue): agent settings are read-only in a PERCH_HOME run")
            return
        }
        do {
            env.agents.lastMessage = try adapter.uninstallHooks()
            Log.info("disconnected \(agent.rawValue)")
        } catch {
            env.agents.lastMessage = "Could not disconnect \(agent.displayName): \(describe(error))"
            Log.error("disconnecting \(agent.rawValue) failed: \(describe(error))")
        }
        refreshAgents()
    }

    // MARK: - Usage, sounds, demo

    func refreshUsage() { usage.refreshNow() }

    func clearSavedStats() { usage.clearSavedStats() }

    func previewSound(_ cue: SoundCue) { sounds.preview(cue) }

    func toggleMute() { env.settings.soundsEnabled.toggle() }

    func setDemo(_ on: Bool) {
        if on { demo.start() } else { demo.stop() }
    }

    // MARK: - Advanced

    func clearActivityLog() {
        env.sessions.activity = []
    }

    /// Puts a short text summary on the clipboard. It holds versions, paths, hook status and the
    /// end of the log — never titles, prompts, commands or messages.
    func copyDiagnostics() {
        // Use what the files say right now, not what the Agents screen last showed.
        refreshAgents()
        let text = Diagnostics.text(snapshot(), logTail: Diagnostics.logTail())
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast("Diagnostics copied. Read them before you send them to anyone.", systemImage: "doc.on.clipboard.fill", isProblem: false)
    }

    func revealSupportFolder() {
        let folder = PerchPaths.supportDir
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Removes everything Perch added to this Mac, then quits. See Uninstaller.swift for the steps;
    /// the wording on Settings → Advanced describes exactly this.
    func uninstallEverything() {
        guard !isShutDown else { return }
        Log.info("uninstalling Perch at the user's request")
        if env.ui.isDemo { demo.stop() }
        var problems = options.mayChangeAgentSettings ? Uninstaller.removeHooks(adapters: orderedAdapters) : []
        shutDown()
        if !options.skipLoginItem { LoginItem.setEnabled(false) }
        // The last log lines are written a moment after they are asked for. Wait for them, so the
        // log file is not created again in the folder that is about to be emptied.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [options] in
            problems += Uninstaller.emptyFolder(PerchPaths.supportDir)
            Uninstaller.forgetPreferences(options: options)
            if !problems.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Perch could not remove everything"
                alert.informativeText = problems.joined(separator: "\n") + "\n\nEverything else was removed."
                alert.addButton(withTitle: "Quit Perch")
                NSApplication.shared.activate()
                alert.runModal()
            }
            NSApplication.shared.terminate(nil)
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
