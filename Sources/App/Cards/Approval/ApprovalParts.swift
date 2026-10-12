// ApprovalParts.swift — two pieces of the approval card that are big enough to stand alone.
//
//   ApprovalDangerBanner   the red warning on a request flagged as dangerous
//   ApprovalRememberList   the "Always allow…" choices the agent offered, as a list of buttons

import SwiftUI

/// The warning shown on top of a dangerous request. It changes its wording once the user has
/// clicked "Allow…" and the card is waiting for the second, confirming click.
struct ApprovalDangerBanner: View {
    private let isArmed: Bool
    private let agentName: String

    @EnvironmentObject private var settings: AppSettings

    init(isArmed: Bool, agentName: String) {
        self.isArmed = isArmed
        self.agentName = agentName
    }

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: isArmed ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.danger)
                .frame(width: theme.scaled(16))
            VStack(alignment: .leading, spacing: 2) {
                Text(isArmed ? "Really allow this?" : "This could do damage")
                    .font(theme.font(.label))
                    .foregroundStyle(theme.danger)
                Text(isArmed
                     ? "\(agentName) will run it exactly as written below. Perch cannot undo it."
                     : "It may delete files, change your system or rewrite history.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.Spacing.m)
        .background(shape.fill(theme.danger.opacity(isArmed ? 0.2 : 0.11)))
        .overlay(shape.strokeBorder(theme.danger.opacity(isArmed ? 0.7 : 0.32), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The agent's ready-made "remember this" rules. Choosing one allows the request now and saves
/// that rule, so the same thing is not asked again.
struct ApprovalRememberList: View {
    private let suggestions: [PermissionSuggestion]
    private let choose: (Int) -> Void

    @EnvironmentObject private var settings: AppSettings

    /// - Parameter choose: Called with the chosen suggestion's `id`.
    init(suggestions: [PermissionSuggestion], choose: @escaping (Int) -> Void) {
        self.suggestions = suggestions
        self.choose = choose
    }

    var body: some View {
        let theme = Theme.current(settings)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Allow now, and do not ask again for:")
                .font(theme.font(.caption))
                .foregroundStyle(theme.textSecondary)
                .padding(.bottom, 1)
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                ApprovalRememberRow(label: CardsWording.tidy(suggestion.label) ?? "Rule \(index + 1) offered by the agent") {
                    choose(suggestion.id)
                }
            }
        }
        .padding(Theme.Spacing.m)
        .background(CardBackground(isSunken: true, cornerRadius: Theme.Radius.control))
    }
}

/// One rule in the list. A separate view so it can track hover.
private struct ApprovalRememberRow: View {
    let label: String
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                Image(systemName: "checkmark.shield.fill")
                    .font(theme.font(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.success)
                Text(label)
                    .font(theme.font(.label))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Spacing.m)
                Image(systemName: "arrow.right")
                    .font(theme.font(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? theme.textPrimary : theme.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(shape.fill(hovering ? theme.surfaceHover : theme.surface))
            .overlay(shape.strokeBorder(hovering ? theme.strokeStrong : theme.stroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Allow this request and remember the rule")
        .accessibilityLabel(label)
    }
}
