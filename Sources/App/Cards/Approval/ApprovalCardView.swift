// ApprovalCardView.swift — the card for "the agent wants to do something: may it?".
//
//   ┌──────────────────────────────────────────────────────────────────┐
//   │ [C]  ✋ Run a shell command                        [Bash]   20s  │
//   │      sightsense · Clean up the build folder and rerun tests      │
//   │  ⚠  This one could do damage …                                   │  only when flagged dangerous
//   │  ▸ rm -rf build && scripts/test.sh Engine                        │  the command / path / URL
//   │  (a diff, when the tool edits a file)                            │
//   │  [ Allow ⌘Y ] [ Deny ⌘N ] [ Always allow… ]    Deny with a note…  Answer in terminal ⌘T
//   └──────────────────────────────────────────────────────────────────┘
//
// What each button sends (always through RequestCardShell's `send`, so only once):
//   Allow                → Decision.allow
//   Deny                 → Decision.deny(message: nil)
//   Deny with a note…    → opens a text field; Decision.deny(message: what you typed)
//   Always allow…        → opens the rules the agent offered; picking one sends Decision.allowAlways
//   Answer in terminal   → Decision.passToTerminal (Perch steps aside)
//
// Dangerous requests (when "Confirm dangerous commands" is on) need two separate clicks: the
// first click on "Allow…" only arms the card and changes the warning, the second one allows.
// "Always allow" is not offered for those — a rule that waves through `rm -rf` is never a
// one-click decision.

import SwiftUI

struct ApprovalCardView: View {
    private let request: PendingRequest
    private let session: Session?

    @EnvironmentObject private var settings: AppSettings
    /// When the user clicked "Allow…" on a dangerous request. Non-nil = waiting for the confirming click.
    @State private var armedAt: Date?
    @State private var rememberOpen: Bool
    @State private var noteOpen: Bool
    @State private var note: String

    /// - Parameter preview: Draws the card part-way through being used. Only for snapshots; the app leaves it out.
    init(request: PendingRequest, session: Session?, preview: CardsPreview = CardsPreview()) {
        self.request = request
        self.session = session
        self._armedAt = State(initialValue: preview.confirmArmed ? .distantPast : nil)
        self._rememberOpen = State(initialValue: preview.rememberOpen)
        self._noteOpen = State(initialValue: preview.noteOpen)
        self._note = State(initialValue: preview.noteText)
    }

    /// A second click sooner than this after the first is taken for a double click and ignored.
    private static let confirmPause: TimeInterval = 0.45
    /// An armed card that is left alone goes back to normal after this long.
    private static let armedTimeout: UInt64 = 12_000_000_000

    var body: some View {
        if case .permission(let permission) = request.kind {
            let theme = Theme.current(settings)
            let guarded = permission.isDangerous && settings.confirmDangerous
            RequestCardShell(request: request, session: session,
                             symbol: "hand.raised.fill",
                             title: CardsWording.tidy(permission.summary) ?? "Permission needed",
                             tint: permission.isDangerous ? theme.danger : theme.warning,
                             tag: toolTag(permission)) { send in
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    if guarded {
                        ApprovalDangerBanner(isArmed: armedAt != nil, agentName: request.agent.displayName)
                    }
                    what(permission, theme)
                    if rememberOpen, offersRules(permission, guarded: guarded) {
                        ApprovalRememberList(suggestions: permission.suggestions) { send(.allowAlways(suggestionID: $0)) }
                    }
                    if noteOpen {
                        noteEditor(theme, send)
                    } else {
                        buttons(permission, theme, guarded: guarded, send)
                    }
                }
            }
            .task(id: armedAt) {
                guard armedAt != nil, armedAt != .distantPast else { return }
                try? await Task.sleep(nanoseconds: Self.armedTimeout)
                if !Task.isCancelled { armedAt = nil }
            }
        }
    }

    // MARK: What the agent wants to do

    @ViewBuilder
    private func what(_ permission: PermissionRequest, _ theme: Theme) -> some View {
        let detail = CardsWording.tidy(permission.detail)
        let diff = settings.showDiffPreview ? permission.diff : nil
        // An edit's "detail" is just the file path, which the diff already shows in its title bar.
        let repeatsDiffTitle = diff != nil && detail == CardsWording.tidy(diff?.filePath)
        if let detail, !repeatsDiffTitle {
            CardsCodeBox(detail, systemImage: CardsWording.toolSymbol(permission.toolName))
        }
        if let diff {
            ApprovalDiffView(diff: diff, maxLines: settings.diffMaxLines)
        } else if let hidden = permission.diff, detail != nil {
            // Diff previews are switched off: still say how big the change is.
            Text("This adds \(CardsWording.counted(max(hidden.added, 0), "line")) and removes \(CardsWording.counted(max(hidden.removed, 0), "line")). Turn on diff previews in Settings to see the change here.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if detail == nil && diff == nil {
            Text("\(request.agent.displayName) did not say more about this request. Answer in the terminal to see its own prompt.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolTag(_ permission: PermissionRequest) -> RequestCardTag? {
        guard let name = CardsWording.tidy(permission.toolName) else { return nil }
        return RequestCardTag(text: CardsWording.shortToolName(name))
    }

    // MARK: Buttons

    private func offersRules(_ permission: PermissionRequest, guarded: Bool) -> Bool {
        settings.showAlwaysAllow && !permission.suggestions.isEmpty && !guarded
    }

    private func buttons(_ permission: PermissionRequest, _ theme: Theme, guarded: Bool,
                         _ send: @escaping (Decision) -> Void) -> some View {
        CardsActionRow {
            allowButton(theme, guarded: guarded, send)
            Button { send(.deny(message: nil)) } label: {
                CardsButtonLabel("Deny", keys: ["⌘", "N"])
            }
            .buttonStyle(.perch(.secondary))
            .help("Tell \(request.agent.displayName) not to do this")
            if armedAt != nil {
                Button("Cancel") { armedAt = nil }
                    .buttonStyle(.perch(.ghost))
                    .help("Go back without answering")
            }
            if offersRules(permission, guarded: guarded) {
                Button { rememberOpen.toggle() } label: {
                    HStack(spacing: 4) {
                        Text("Always allow…")
                        Image(systemName: "chevron.down")
                            .font(theme.font(size: 8, weight: .bold))
                            .rotationEffect(.degrees(rememberOpen ? 180 : 0))
                    }
                }
                .buttonStyle(.perch(.secondary, tint: rememberOpen ? theme.success : nil))
                .help("Allow this and stop asking about things like it")
            }
        } extra: {
            Button { noteOpen = true; rememberOpen = false; armedAt = nil } label: {
                CardsButtonLabel("Deny with a note…", systemImage: "text.bubble")
            }
            .buttonStyle(.perch(.ghost, size: .small))
            .help("Deny, and tell \(request.agent.displayName) what to do instead")
            Button { send(.passToTerminal) } label: {
                CardsButtonLabel("Answer in terminal", systemImage: "terminal", keys: ["⌘", "T"])
            }
            .buttonStyle(.perch(.ghost, size: .small))
            .help("Perch steps aside and \(request.agent.displayName) shows its own prompt")
        }
    }

    @ViewBuilder
    private func allowButton(_ theme: Theme, guarded: Bool, _ send: @escaping (Decision) -> Void) -> some View {
        if !guarded {
            Button { send(.allow) } label: {
                CardsButtonLabel("Allow", keys: ["⌘", "Y"], onAccent: true)
            }
            .buttonStyle(.perch(.primary))
            .help("Let \(request.agent.displayName) go ahead, this once")
        } else if let armed = armedAt {
            Button {
                // Deliberate means a separate click, not the second half of a double click.
                if Date().timeIntervalSince(armed) >= Self.confirmPause { send(.allow) }
            } label: {
                CardsButtonLabel("Yes, allow it", systemImage: "exclamationmark.octagon.fill")
            }
            .buttonStyle(.perch(.primary, tint: theme.danger))
            .help("Run it exactly as shown")
        } else {
            // No keyboard hint: the shortcut refuses dangerous requests on purpose.
            Button { armedAt = Date(); rememberOpen = false } label: {
                CardsButtonLabel("Allow…")
            }
            .buttonStyle(.perch(.secondary, tint: theme.danger))
            .help("Flagged as dangerous: you will be asked to confirm")
        }
    }

    // MARK: Deny with a note

    private func noteEditor(_ theme: Theme, _ send: @escaping (Decision) -> Void) -> some View {
        let sendNote = { send(.deny(message: CardsWording.tidy(note))) }
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            CardsTextField("What should \(request.agent.displayName) do instead? (optional)", text: $note, multiline: true,
                           onSubmit: sendNote)
            CardsActionRow {
                Button(action: sendNote) {
                    CardsButtonLabel(CardsWording.tidy(note) == nil ? "Deny" : "Deny and send note", keys: ["↩"])
                }
                .buttonStyle(.perch(.destructive))
                Button("Cancel") { noteOpen = false }
                    .buttonStyle(.perch(.ghost))
            }
        }
    }
}
