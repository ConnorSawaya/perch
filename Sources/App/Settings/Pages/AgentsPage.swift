// AgentsPage.swift — Settings → Agents & help: one row per coding agent with its connection
// state and buttons, a short "How it works", and a last row for demo mode, diagnostics,
// resetting and uninstalling.
//
// Everything shown comes from AgentsStore, which the app controller fills in. The buttons only
// call AppActions; the result of the last one comes back as `AgentsStore.lastMessage` and is
// written under the list.
//
//   SettingsAgentsSection     the agents and the "is Perch listening?" chip   (below)
//   HowItWorksSection         the live diagram and four short answers          (HowItWorks/)
//   SettingsMaintenanceRow    demo, diagnostics, reset, uninstall              (MaintenanceRow.swift)

import SwiftUI

struct AgentsSettingsPage: View {
    /// True while the page shows what uninstalling does, in place of its usual sections.
    @State private var showsUninstall = false

    var body: some View {
        if showsUninstall {
            SettingsUninstallPanel { showsUninstall = false }
        } else {
            SettingsAgentsSection()
            HowItWorksSection()
            SettingsMaintenanceRow { showsUninstall = true }
        }
    }
}

// MARK: - The agents

private struct SettingsAgentsSection: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var agents: AgentsStore
    @Environment(\.perchActions) private var actions

    var body: some View {
        let theme = Theme.current(settings)
        let trouble = healthTrouble
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader("Your agents", systemImage: "terminal.fill") {
                Chip(trouble?.words ?? "Perch is listening",
                     systemImage: trouble == nil ? "checkmark" : "exclamationmark.triangle.fill",
                     tint: trouble == nil ? theme.success : theme.warning)
                PerchIconButton(systemName: "arrow.clockwise", help: "Look for agents and re-read their settings files", size: 22) {
                    actions.refreshAgents()
                }
            }
            .padding(.horizontal, Theme.Spacing.xs)

            if agents.statuses.isEmpty {
                PerchEmptyState(title: "No agents checked yet",
                                message: "Perch has not looked for coding agents on this Mac yet.",
                                systemImage: "magnifyingglass") {
                    Button("Look for agents") { actions.refreshAgents() }
                        .buttonStyle(.perch(.primary))
                }
                .background(CardBackground())
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(agents.statuses) { status in
                        if status.id != agents.statuses.first?.id {
                            PerchDivider().padding(.leading, SettingsRowMetrics.sidePadding + SettingsAgentRow.badge + Theme.Spacing.l)
                        }
                        SettingsAgentRow(status: status)
                            .padding(.horizontal, SettingsRowMetrics.sidePadding)
                            .padding(.vertical, 7)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CardBackground())
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if let trouble {
                    Text(trouble.advice).foregroundStyle(theme.warning)
                }
                if let message = agents.lastMessage, !message.isEmpty {
                    Text(message)
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .font(theme.font(.caption))
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Spacing.xs)
        }
    }

    /// What is wrong with Perch's own side of the line, if anything, and what to do about it.
    private var healthTrouble: (words: String, advice: String)? {
        if !agents.serverRunning {
            return ("Perch is not listening",
                    "The socket agents talk to could not be opened, so no events can arrive. Quit and reopen Perch; "
                    + "if it stays like this, use Copy diagnostics below.")
        }
        if !agents.helperInstalled {
            return ("The helper is missing",
                    "The perch-hook program that agents run is not in Perch's folder. Reopen Perch to put it back, "
                    + "then click Reconnect on each agent.")
        }
        return nil
    }
}

/// One agent: who it is, how it is connected, its buttons, and the switch that shows or hides
/// its sessions.
private struct SettingsAgentRow: View {
    let status: AgentStatus

    /// The badge keeps one size whatever the text size is, so the rows' dividers line up with it.
    static let badge: CGFloat = 28

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.perchActions) private var actions

    var body: some View {
        let theme = Theme.current(settings)
        let agent = status.agent
        let enabled = settings.isEnabled(agent)
        let enabledBinding = Binding<Bool>(get: { settings.isEnabled(agent) }, set: { settings.setEnabled(agent, $0) })

        HStack(alignment: .center, spacing: Theme.Spacing.l) {
            AgentBadge(agent, size: Self.badge)
                .opacity(status.detected && enabled ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.m) {
                    Text(agent.displayName)
                        .font(theme.font(.label))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Chip(SettingsAgentWording.statusWords(status.hookStatus),
                         systemImage: SettingsAgentWording.statusImage(status.hookStatus),
                         tint: SettingsAgentWording.statusTint(status.hookStatus, theme: theme))
                }
                Text(enabled ? status.detail : "Switched off: Perch ignores this agent, even while it is connected.")
                    .font(theme.font(.caption))
                    .foregroundStyle(SettingsRowMetrics.explanationColor(theme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(status.configPath.map { "\(status.detail)\nSettings file: \($0)" } ?? status.detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(status.detected && enabled ? 1 : 0.55)
            buttons
            PerchSwitch(isOn: enabledBinding)
                .help("Show \(agent.displayName) sessions in Perch")
                .accessibilityLabel("Show \(agent.displayName) sessions in Perch")
        }
    }

    /// Connect when nothing is installed; Reconnect / Update and Disconnect once something is.
    @ViewBuilder
    private var buttons: some View {
        let agent = status.agent
        HStack(spacing: Theme.Spacing.s) {
            switch status.hookStatus {
            case .notDetected:
                EmptyView()
            case .notInstalled:
                Button("Connect") { actions.installHooks(for: agent) }
                    .buttonStyle(.perch(.primary, size: .small))
            case .installed:
                Button("Reconnect") { actions.installHooks(for: agent) }
                    .buttonStyle(.perch(.secondary, size: .small))
                    .help("Write Perch's hooks again, in case the settings file was changed by hand")
                Button("Disconnect") { actions.uninstallHooks(for: agent) }
                    .buttonStyle(.perch(.ghost, size: .small))
            case .needsUpdate:
                Button("Update") { actions.installHooks(for: agent) }
                    .buttonStyle(.perch(.primary, size: .small))
                Button("Disconnect") { actions.uninstallHooks(for: agent) }
                    .buttonStyle(.perch(.ghost, size: .small))
            case .error:
                Button("Try again") { actions.installHooks(for: agent) }
                    .buttonStyle(.perch(.primary, size: .small))
                Button("Disconnect") { actions.uninstallHooks(for: agent) }
                    .buttonStyle(.perch(.ghost, size: .small))
            }
        }
        .fixedSize()
    }
}

// MARK: - Words

/// Plain words, an icon and a colour for each hook state.
enum SettingsAgentWording {
    static func statusWords(_ status: HookStatus) -> String {
        switch status {
        case .notDetected: return "Not on this Mac"
        case .notInstalled: return "Not connected"
        case .installed: return "Connected"
        case .needsUpdate: return "Needs an update"
        case .error: return "Problem"
        }
    }

    static func statusImage(_ status: HookStatus) -> String {
        switch status {
        case .notDetected: return "questionmark"
        case .notInstalled: return "bolt.slash.fill"
        case .installed: return "bolt.fill"
        case .needsUpdate: return "arrow.up.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    static func statusTint(_ status: HookStatus, theme: Theme) -> Color {
        switch status {
        case .notDetected: return theme.textTertiary
        case .notInstalled: return theme.textSecondary
        case .installed: return theme.success
        case .needsUpdate: return theme.warning
        case .error: return theme.danger
        }
    }
}
