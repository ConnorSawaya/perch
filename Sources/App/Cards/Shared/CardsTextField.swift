// CardsTextField.swift — the one text field used on cards (deny reason, "Other…" answer, plan feedback),
// and the bookkeeping that tells the window when typing is needed.
//
// Why the bookkeeping: the island is a window that normally refuses the keyboard, so that showing
// it never steals focus from your terminal. A text field needs the keyboard, so while one is on
// screen it sets `UIState.needsKeyboard`, and the window shell lets the panel become the key
// window for that time. `CardsKeyboardClaim` counts the fields that are showing, so two open
// fields cannot switch the flag off under each other.
//
// A field only ever appears because the user clicked something ("Other…", "Deny with a note…"),
// never just because a card arrived — so Perch never swallows keys meant for your editor.
//
// Snapshots: the system text field does not draw into images, so with `perchStaticRendering`
// the field is drawn as plain text with a caret.

import SwiftUI

/// Keeps `UIState.needsKeyboard` true while at least one card text field is showing.
@MainActor
enum CardsKeyboardClaim {
    /// Fields that currently want the keyboard, per window state (there is one in the app; tests make several).
    private static var holders: [ObjectIdentifier: Set<UUID>] = [:]

    static func update(_ field: UUID, wantsKeyboard: Bool, ui: UIState) {
        let key = ObjectIdentifier(ui)
        var fields = holders[key] ?? []
        if wantsKeyboard { fields.insert(field) } else { fields.remove(field) }
        holders[key] = fields.isEmpty ? nil : fields
        let needed = !fields.isEmpty
        if ui.needsKeyboard != needed { ui.needsKeyboard = needed }
    }
}

struct CardsTextField: View {
    private let placeholder: String
    @Binding private var text: String
    private let multiline: Bool
    private let onSubmit: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @Environment(\.perchStaticRendering) private var isStatic
    @FocusState private var focused: Bool
    /// This field's ticket in CardsKeyboardClaim.
    @State private var claim = UUID()

    /// - Parameters:
    ///   - multiline: Grow to a few lines as the text wraps (Return still submits).
    ///   - onSubmit: Called when the user presses Return.
    init(_ placeholder: String, text: Binding<String>, multiline: Bool = false, onSubmit: @escaping () -> Void) {
        self.placeholder = placeholder
        self._text = text
        self.multiline = multiline
        self.onSubmit = onSubmit
    }

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        field(theme)
            .font(theme.font(.body))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: theme.scaled(28), alignment: .leading)
            .background(CardBackground(isSunken: true, cornerRadius: Theme.Radius.control))
            // Decoration over the field: a click must reach the text, not the outline.
            .overlay(shape.strokeBorder(theme.accent.opacity(focused || isStatic ? 0.7 : 0.3), lineWidth: 1).allowsHitTesting(false))
            .onAppear {
                setClaim(ui.isExpanded)
                // The field was just revealed by a click, so typing should go straight into it.
                DispatchQueue.main.async { focused = true }
            }
            .onDisappear { setClaim(false) }
            // A closed panel must not keep hold of the keyboard.
            .onChange(of: ui.isExpanded) { _, open in setClaim(open) }
    }

    @ViewBuilder
    private func field(_ theme: Theme) -> some View {
        if isStatic {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                if !text.isEmpty { Text(text) }
                Rectangle().fill(theme.accent).frame(width: 1.5, height: theme.scaled(13)).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                if text.isEmpty { Text(placeholder).foregroundStyle(theme.textTertiary) }
            }
            .lineLimit(multiline ? 4 : 1)
        } else {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.textTertiary),
                      axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .lineLimit(multiline ? 4 : 1)
                .focused($focused)
                .onSubmit(onSubmit)
                .accessibilityLabel(placeholder)
        }
    }

    private func setClaim(_ wantsKeyboard: Bool) {
        let ui = self.ui
        let claim = self.claim
        // A moment later: shared state must not change in the middle of a view update.
        DispatchQueue.main.async { CardsKeyboardClaim.update(claim, wantsKeyboard: wantsKeyboard, ui: ui) }
    }
}
