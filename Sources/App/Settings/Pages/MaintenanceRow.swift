// MaintenanceRow.swift — the last row of Settings → Agents & help: demo mode, Copy diagnostics,
// Reset settings and Uninstall Perch, and the panel that spells out what uninstalling does.
//
// The two things here that cannot be undone need a second, clearly worded click (ConfirmButton).
// Uninstalling first shows exactly what will be removed, and asks there.

import SwiftUI

/// Four small things in one row. It wraps onto a second line when the text is large.
struct SettingsMaintenanceRow: View {
    private let onUninstall: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @Environment(\.perchActions) private var actions

    /// - Parameter onUninstall: Called when "Uninstall Perch…" is clicked; show SettingsUninstallPanel.
    init(onUninstall: @escaping () -> Void) { self.onUninstall = onUninstall }

    var body: some View {
        let theme = Theme.current(settings)
        // Demo mode is run by the app (it owns the DemoDirector), so the switch asks the app
        // instead of flipping the flag itself.
        let demo = Binding<Bool>(get: { ui.isDemo }, set: { actions.setDemo($0) })

        SettingsFlow(spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.m) {
                PerchSwitch(isOn: demo)
                Text("Demo mode")
                    .font(theme.font(.label))
                    .foregroundStyle(theme.textPrimary)
            }
            .contentShape(Rectangle())
            .onTapGesture { demo.wrappedValue.toggle() }
            .help("Fills the notch with pretend sessions so you can try everything. Nothing real is touched.")
            .padding(.trailing, Theme.Spacing.m)

            Button {
                actions.copyDiagnostics()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard")
                    Text("Copy diagnostics")
                }
            }
            .buttonStyle(.perch(.secondary, size: .small))
            .help("Puts a short summary on the clipboard, ready to paste into a bug report. Read it before you send it.")

            ConfirmButton("Reset settings\u{2026}", systemImage: "arrow.counterclockwise",
                          confirmTitle: "Yes, reset every setting", isDestructive: false) {
                settings.resetToDefaults()
                // Someone resetting their settings has already seen the welcome.
                settings.hasCompletedOnboarding = true
            }
            .help("Puts every setting back to how it was when Perch was new. Your agents stay connected.")

            Button(action: onUninstall) {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                    Text("Uninstall Perch\u{2026}")
                }
            }
            .buttonStyle(.perch(.destructive, size: .small))
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }
}

/// What uninstalling does, line by line, with the button that does it.
struct SettingsUninstallPanel: View {
    private let onBack: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.perchActions) private var actions

    /// - Parameter onBack: Called by "Keep Perch"; go back to the page's usual sections.
    init(onBack: @escaping () -> Void) { self.onBack = onBack }

    var body: some View {
        let theme = Theme.current(settings)
        SettingsSection("Uninstall Perch", systemImage: "trash.fill", tint: theme.danger) {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                SettingsRowLabel(title: "Remove everything Perch added to this Mac",
                                 subtitle: "Use this before you drag Perch to the Trash, so nothing is left behind.",
                                 systemImage: "xmark.bin.fill", tint: theme.danger)
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SettingsBullet("Takes Perch's lines out of each connected agent's settings file. Everything else "
                                   + "in those files stays exactly as it is.", systemImage: "minus.circle.fill", tint: theme.danger)
                    SettingsBullet("Moves everything in Perch's folder to the Trash: the helper, saved statistics, logs "
                                   + "and the backups of your settings files. They stay in the Trash until you empty it, "
                                   + "so a backup can still be fished out.", systemImage: "minus.circle.fill", tint: theme.danger)
                    SettingsBullet("Forgets every preference you set in this window and takes Perch out of your "
                                   + "Login Items.", systemImage: "minus.circle.fill", tint: theme.danger)
                    SettingsBullet("Quits Perch. Your agents carry on as if it had never been installed.",
                                   systemImage: "minus.circle.fill", tint: theme.danger)
                    SettingsBullet("Does not touch your agents, their history, your projects, or the Perch app itself.",
                                   systemImage: "checkmark.circle.fill", tint: theme.success)
                }
                .padding(.leading, SettingsRowMetrics.iconColumn + Theme.Spacing.m)
                HStack(spacing: Theme.Spacing.m) {
                    Button(action: onBack) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                            Text("Keep Perch")
                        }
                    }
                    .buttonStyle(.perch(.secondary, size: .small))
                    Spacer(minLength: 0)
                    ConfirmButton("Uninstall\u{2026}", systemImage: "trash", confirmTitle: "Yes, remove everything and quit") {
                        actions.uninstallEverything()
                    }
                }
            }
        }
    }
}
