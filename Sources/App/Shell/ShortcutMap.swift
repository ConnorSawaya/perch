// ShortcutMap.swift — what each keyboard shortcut means, and whether it is allowed right now (pure).
//
// Two steps, both plain functions so they can be unit-tested without a keyboard:
//
//   1. `action(for:)`   which shortcut is this key press, if any?
//         Cmd-Y  or Cmd-Return   allow the request
//         Cmd-N  or Cmd-Delete   deny it
//         Cmd-T                  "let me answer in the terminal"
//         Cmd-1 ... Cmd-9        pick that option of a question
//         Escape                 close the panel
//         Cmd-,                  open Settings
//
//   2. `outcome(for:in:)` given the state of the app, what should actually happen?
//
// The safety rules live in step 2:
//   - Nothing happens unless the island is the key window and shortcuts are switched on.
//   - While a text field is in use, only Escape is taken; every other key is left for typing.
//   - A request flagged as dangerous is never allowed by one key press while "confirm dangerous
//     commands" is on. The card is brought into focus instead, where the user must confirm.
//   - Holding a key down (auto-repeat) never answers anything, so one press answers one request.
//   - A request that appeared a split second ago cannot be allowed or answered by a shortcut,
//     so a quick second press cannot say yes to something the user has not seen yet.
//   - A shortcut that does not apply (Cmd-3 when there is no question) is left alone, so the
//     views are free to use that key themselves.
//
// Two more rules apply whenever the island has the keyboard, whatever the settings say:
//   - Cmd-Q, Cmd-H, Cmd-W and Cmd-M are swallowed. The user is hovering over the island with
//     another app in front; those keys are meant for that app and must not quit or hide Perch.
//   - Cmd-X / C / V / A / Z (and Shift-Cmd-Z) are the editing commands every Mac text field
//     has: cut, copy, paste, select all, undo, redo. Normally an app's Edit menu delivers them,
//     but a background app like Perch shows no menu bar, so they are delivered from here.

import Foundation

/// One key press, reduced to the facts the shortcuts care about.
struct KeyStroke: Equatable {
    /// The hardware key number (the same on every keyboard layout).
    var keyCode: UInt16
    /// What the key types on the current layout, ignoring Command, in lower case.
    var characters: String = ""
    var command = false
    var shift = false
    var option = false
    var control = false
    /// True for the repeats a held-down key produces.
    var isRepeat = false

    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let escape: UInt16 = 53
    /// The number keys along the top of the keyboard, 1 to 9. Used when the layout needs Shift
    /// to type a digit (French, for one), where `characters` is a symbol instead.
    static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
}

enum ShortcutAction: Equatable {
    case allow
    case deny
    case passToTerminal
    /// 1-based: Cmd-1 is option 1.
    case pickOption(Int)
    case collapse
    case openSettings
}

/// The standard text-editing commands (see the note at the top of the file).
enum EditCommand: Equatable {
    case cut, copy, paste, selectAll, undo, redo
}

/// What the shortcut monitor needs to know about the app to judge a key press.
struct ShortcutContext {
    var shortcutsEnabled = true
    /// The island is the key window (the pointer is over the open panel, or a text field is active).
    var panelIsKey = true
    /// A text field in the panel is being typed into.
    var needsKeyboard = false
    var confirmDangerous = true
    var focusedRequestID: UUID?
    /// Requests waiting for an answer.
    var pending: [PendingRequest] = []
    var now = Date()
}

enum ShortcutOutcome: Equatable {
    /// Not ours: pass the key on untouched.
    case ignore
    /// Ours, but nothing may happen (a repeat, or the request is too new): eat the key quietly.
    case swallow
    /// Answer this request with this decision.
    case resolve(PendingRequest, Decision)
    /// The request is dangerous: do not answer; put its card in focus so the user confirms there.
    case needsConfirmation(PendingRequest)
    /// Hand this editing command to whatever has the text cursor in the island.
    case edit(EditCommand)
    case collapse
    case openSettings
}

enum ShortcutMap {
    // MARK: Step 1 — which shortcut is it?

    static func action(for key: KeyStroke) -> ShortcutAction? {
        if key.keyCode == KeyStroke.escape {
            return key.command || key.option || key.control ? nil : .collapse
        }
        // Every other shortcut is Command plus one key, with no other modifier held.
        guard key.command, !key.shift, !key.option, !key.control else { return nil }
        switch key.keyCode {
        case KeyStroke.returnKey, KeyStroke.keypadEnter: return .allow
        case KeyStroke.delete, KeyStroke.forwardDelete: return .deny
        default: break
        }
        switch key.characters {
        case "y": return .allow
        case "n": return .deny
        case "t": return .passToTerminal
        case ",": return .openSettings
        default: break
        }
        if let digit = Int(key.characters), (1...9).contains(digit) { return .pickOption(digit) }
        if let digit = KeyStroke.digitKeys[key.keyCode] { return .pickOption(digit) }
        return nil
    }

    // MARK: Step 2 — what should happen?

    static func outcome(for key: KeyStroke, in context: ShortcutContext) -> ShortcutOutcome {
        guard context.panelIsKey else { return .ignore }
        if isAppCommand(key) { return .swallow }
        if let command = editCommand(for: key) { return .edit(command) }
        guard context.shortcutsEnabled, let action = action(for: key) else { return .ignore }
        // Typing comes first: while a text field is active only Escape is a shortcut.
        if context.needsKeyboard && action != .collapse { return .ignore }
        let outcome = outcome(for: action, in: context)
        // One press, one answer. A held key repeats many times a second.
        if key.isRepeat && outcome != .ignore { return .swallow }
        return outcome
    }

    private static func outcome(for action: ShortcutAction, in context: ShortcutContext) -> ShortcutOutcome {
        switch action {
        case .collapse: return .collapse
        case .openSettings: return .openSettings
        case .allow, .deny, .passToTerminal, .pickOption: break
        }
        guard let request = target(focusedRequestID: context.focusedRequestID, pending: context.pending) else { return .ignore }

        let decision: Decision
        switch (action, request.kind) {
        case (.allow, .permission(let permission)):
            guard canAllowWithShortcut(permission, confirmDangerous: context.confirmDangerous) else {
                return .needsConfirmation(request)
            }
            decision = .allow
        case (.allow, .plan):
            // Approve the plan but keep asking before each edit: the cautious reading of "yes".
            decision = .approvePlan(acceptEdits: false)
        case (.deny, .permission):
            decision = .deny(message: nil)
        case (.deny, .plan):
            decision = .rejectPlan(feedback: "")
        case (.passToTerminal, _):
            decision = .passToTerminal
        case (.pickOption(let number), .question(let asked)):
            // Only the simple case: one question, one answer. Anything richer needs the card.
            guard asked.questions.count == 1, let question = asked.questions.first, !question.multiSelect,
                  question.options.indices.contains(number - 1) else { return .ignore }
            decision = .answer([question.text: question.options[number - 1].label])
        default:
            // Allow or deny on a question, a number on something that is not a question: not ours.
            return .ignore
        }

        if isAffirmative(decision) && context.now.timeIntervalSince(request.createdAt) < ShellTuning.minimumAllowAge {
            return .swallow
        }
        return .resolve(request, decision)
    }

    /// Quit, Hide, Close and Minimise, with or without other modifiers (Option-Cmd-H is
    /// "Hide Others", which would hide the very app the user is working in).
    private static func isAppCommand(_ key: KeyStroke) -> Bool {
        key.command && ["q", "h", "w", "m"].contains(key.characters)
    }

    /// Which editing command a key press is, if any. These never clash with the shortcuts
    /// above: none of those letters is used there.
    static func editCommand(for key: KeyStroke) -> EditCommand? {
        guard key.command, !key.option, !key.control else { return nil }
        switch (key.characters, key.shift) {
        case ("x", false): return .cut
        case ("c", false): return .copy
        case ("v", false): return .paste
        case ("a", false): return .selectAll
        case ("z", false): return .undo
        case ("z", true): return .redo
        default: return nil
        }
    }

    /// The request a shortcut acts on: the card that has focus, otherwise the oldest one waiting.
    static func target(focusedRequestID: UUID?, pending: [PendingRequest]) -> PendingRequest? {
        if let id = focusedRequestID, let focused = pending.first(where: { $0.id == id }) { return focused }
        return pending.min { $0.createdAt < $1.createdAt }
    }

    /// May a single key press allow this permission request? Not when it is flagged dangerous
    /// and the user wants a confirmation for those — that takes a deliberate click on the card.
    static func canAllowWithShortcut(_ request: PermissionRequest, confirmDangerous: Bool) -> Bool {
        !(request.isDangerous && confirmDangerous)
    }

    /// Decisions that let the agent go ahead or steer it. These get the "not too new" check;
    /// denying or passing to the terminal is always safe.
    private static func isAffirmative(_ decision: Decision) -> Bool {
        switch decision {
        case .allow, .allowAlways, .answer, .approvePlan: return true
        case .deny, .rejectPlan, .passToTerminal: return false
        }
    }
}
