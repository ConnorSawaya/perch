// ShortcutMonitor.swift — makes the keyboard shortcuts work while the island has the keyboard.
//
// This is a LOCAL key monitor: it only ever sees key presses that macOS has already decided to
// send to Perch. It cannot see (and Perch never asks to see) what is typed in other apps. On top
// of that it only acts while the island itself is the key window, which NotchWindowController
// allows only while the pointer is over the open panel or a text field in it is active.
//
// The monitor is a thin shell: it turns the key press into a `KeyStroke`, asks `ShortcutMap`
// what should happen, and carries that out through `AppActions` (or, for the standard editing
// keys such as Cmd-V, by handing the command to the text field that has the cursor).

import AppKit

final class ShortcutMonitor {
    private let env: AppEnv
    private let expander: PanelExpander
    private var monitor: Any?

    init(env: AppEnv) {
        self.env = env
        expander = PanelExpander(env: env)
    }

    deinit { stop() }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns true when the key press was used up and must not travel any further.
    private func handle(_ event: NSEvent) -> Bool {
        // A character is being put together from several key presses (Japanese, Chinese, an
        // accent...). Every key, Escape included, belongs to that until it is finished.
        let focus = NSApplication.shared.keyWindow?.firstResponder
        if let composing = focus as? NSTextInputClient, composing.hasMarkedText() { return false }
        let context = ShortcutContext(shortcutsEnabled: env.settings.shortcutsEnabled,
                                      panelIsKey: NSApplication.shared.keyWindow is NotchPanel,
                                      needsKeyboard: env.ui.needsKeyboard,
                                      confirmDangerous: env.settings.confirmDangerous,
                                      focusedRequestID: env.ui.focusedRequestID,
                                      pending: env.sessions.pending,
                                      now: Date())
        return perform(ShortcutMap.outcome(for: KeyStroke(event), in: context))
    }

    /// Carries out what ShortcutMap decided. Returns true when the key press was used up.
    func perform(_ outcome: ShortcutOutcome) -> Bool {
        switch outcome {
        case .ignore:
            return false
        case .swallow:
            return true
        case .resolve(let request, let decision):
            env.actions.resolve(request, decision)
            return true
        case .needsConfirmation(let request):
            // Show the user which card needs the extra click, and say "no" the way macOS does.
            env.ui.focusedRequestID = request.id
            if env.settings.soundsEnabled { NSSound.beep() }
            return true
        case .edit(let command):
            return Self.deliver(command, to: NSApplication.shared.keyWindow)
        case .collapse:
            expander.setExpanded(false)
            return true
        case .openSettings:
            env.actions.openSettings(nil)
            return true
        }
    }

    /// Offers an editing command to whatever has the text cursor in `window`, then to the views
    /// around it. Returns false when nothing there can do it; the key press then travels on.
    static func deliver(_ command: EditCommand, to window: NSWindow?) -> Bool {
        window?.firstResponder?.tryToPerform(command.action, with: nil) ?? false
    }
}

extension EditCommand {
    /// The standard AppKit action behind each command; text fields know all of them.
    var action: Selector {
        switch self {
        case .cut: return #selector(NSText.cut(_:))
        case .copy: return #selector(NSText.copy(_:))
        case .paste: return #selector(NSText.paste(_:))
        case .selectAll: return #selector(NSResponder.selectAll(_:))
        case .undo: return Selector(("undo:"))
        case .redo: return Selector(("redo:"))
        }
    }
}

extension KeyStroke {
    /// Reads the facts out of a real key-down event.
    init(_ event: NSEvent) {
        let flags = event.modifierFlags
        var typed = (event.charactersIgnoringModifiers ?? "").lowercased()
        // Keyboards that do not type Latin letters (Russian, Greek, Hebrew...) switch to their
        // Latin meaning while Command is held; that is how Cmd-C works on them everywhere. Read
        // the key the same way, so Cmd-Y is Cmd-Y on every keyboard.
        if flags.contains(.command), !typed.allSatisfy(\.isASCII),
           let latin = event.characters?.lowercased(), !latin.isEmpty, latin.allSatisfy(\.isASCII) {
            typed = latin
        }
        self.init(keyCode: event.keyCode,
                  characters: typed,
                  command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control),
                  isRepeat: event.isARepeat)
    }
}
