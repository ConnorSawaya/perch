// WelcomePanel.swift — the short welcome shown the first time Settings opens.
//
// It appears on top of the Settings window while `AppSettings.hasCompletedOnboarding` is false:
// three sentences about what Perch does and two ways to begin — connect Claude Code, or play
// the demo. Any way of leaving it sets `hasCompletedOnboarding`, so it does not come back.

import SwiftUI

/// The welcome card on a dimmed backdrop, covering the whole Settings window.
struct WelcomeOverlay: View {
    var body: some View {
        ZStack {
            // Swallows clicks so the settings underneath cannot be changed by accident.
            Color.black.opacity(0.72)
                .contentShape(Rectangle())
                .onTapGesture {}
            // Use the roomy layout when the window is tall enough, a tighter one when it is not,
            // and let the tight one scroll if even that does not fit (small window, large text).
            ViewThatFits(in: .vertical) {
                WelcomePanel()
                WelcomePanel(isCompact: true)
                PerchScroll(fadeEdges: false) { WelcomePanel(isCompact: true) }
            }
            .padding(Theme.Spacing.l)
        }
    }
}

struct WelcomePanel: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var agents: AgentsStore
    @EnvironmentObject private var ui: UIState
    @Environment(\.perchActions) private var actions

    private let isCompact: Bool

    /// - Parameter isCompact: A shorter layout (no mascot, tighter spacing) for small windows.
    init(isCompact: Bool = false) { self.isCompact = isCompact }

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let claude = agents.status(.claude)
        let claudeConnected = claude?.hookStatus == .installed

        VStack(spacing: 0) {
            hero(theme)
            VStack(alignment: .leading, spacing: isCompact ? Theme.Spacing.l : Theme.Spacing.xl) {
                WelcomePoint(systemImage: "rectangle.topthird.inset.filled", tint: theme.accent,
                             title: "See every agent at a glance",
                             text: "Your Claude Code, Codex and other sessions live in the notch: what each one is doing, "
                                + "for how long, and which one needs you.")
                WelcomePoint(systemImage: "hand.tap.fill", tint: theme.warning,
                             title: "Answer without switching windows",
                             text: "Allow or deny a command, pick an answer, or approve a plan right from the notch. "
                                + "One click on a session takes you to its terminal tab.")
                WelcomePoint(systemImage: "lock.shield.fill", tint: theme.success,
                             title: "Private, and out of the way",
                             text: "No network, no account, no access to your logins. If Perch is closed, your agents "
                                + "behave exactly as they did before.")
            }
            .padding(.horizontal, Theme.Spacing.xxl + 4)
            .padding(.top, isCompact ? Theme.Spacing.l : Theme.Spacing.xl)

            VStack(spacing: Theme.Spacing.m) {
                HStack(spacing: Theme.Spacing.m) {
                    if claudeConnected {
                        Button { finish(openTab: nil) } label: {
                            label("Get started", "checkmark.circle.fill")
                        }
                        .buttonStyle(.perch(.primary, size: .large, fullWidth: true))
                    } else {
                        Button {
                            actions.installHooks(for: .claude)
                            // Land on the Agents page, where the result of connecting is shown.
                            finish(openTab: .agents)
                        } label: {
                            label("Connect Claude Code", "bolt.fill")
                        }
                        .buttonStyle(.perch(.primary, size: .large, fullWidth: true))
                    }
                    Button {
                        actions.setDemo(true)
                        finish(openTab: nil)
                    } label: {
                        label("Try the demo", "play.fill")
                    }
                    .buttonStyle(.perch(.secondary, size: .large, fullWidth: true))
                }
                Text(connectNote(claude))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Not now \u{2014} just show me the settings") { finish(openTab: nil) }
                    .buttonStyle(.perch(.ghost, size: .small))
            }
            .padding(.horizontal, Theme.Spacing.xxl + 4)
            .padding(.top, isCompact ? Theme.Spacing.xl : Theme.Spacing.xxl)
            .padding(.bottom, isCompact ? Theme.Spacing.l : Theme.Spacing.xl)
        }
        .frame(width: theme.scaled(500))
        .background(shape.fill(theme.surface))
        .clipShape(shape)
        // Decoration drawn over the buttons must never take their clicks.
        .overlay(shape.strokeBorder(theme.strokeStrong, lineWidth: 1).allowsHitTesting(false))
        .overlay(GlowBorder(cornerRadius: 22, lineWidth: 1, blur: 10))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
        .accessibilityAddTraits(.isModal)
    }

    private func hero(_ theme: Theme) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            if !isCompact {
                ZStack {
                    Circle().fill(theme.island).frame(width: theme.scaled(58), height: theme.scaled(58))
                    Circle().strokeBorder(theme.strokeStrong, lineWidth: 1).frame(width: theme.scaled(58), height: theme.scaled(58))
                    MascotView(mood: .done, size: theme.scaled(32))
                }
                .padding(.bottom, Theme.Spacing.xs)
            }
            Text("Welcome to \(PerchPaths.appName)")
                .font(theme.font(.display))
                .foregroundStyle(theme.textPrimary)
            Text("Your coding agents, at home in the notch.")
                .font(theme.font(.body))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, isCompact ? Theme.Spacing.xl : Theme.Spacing.xxl)
        .padding(.bottom, isCompact ? Theme.Spacing.l : Theme.Spacing.xl)
        .background(alignment: .top) {
            AuroraHeader(isAnimating: false).frame(height: isCompact ? 90 : 150)
        }
        .background(theme.island)
    }

    private func label(_ text: String, _ systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
    }

    /// One honest sentence about what the Connect button will do on this Mac.
    private func connectNote(_ claude: AgentStatus?) -> String {
        guard let claude else {
            return "Connecting adds Perch's hooks to Claude Code's settings file, after saving a backup. You can undo it under Agents & help."
        }
        switch claude.hookStatus {
        case .installed:
            return "Claude Code is already connected: start \u{201C}claude\u{201D} in a terminal and it appears in the notch."
        case .notDetected:
            return "Claude Code was not found on this Mac yet. You can connect it, or another agent, later under Agents & help."
        case .notInstalled, .needsUpdate, .error:
            return "Connecting adds Perch's hooks to \(claude.configPath ?? "Claude Code's settings file"), after saving a backup. "
                + "You can undo it under Agents & help."
        }
    }

    private func finish(openTab tab: SettingsTab?) {
        if let tab, ui.settingsTab != tab { ui.settingsTab = tab }
        settings.hasCompletedOnboarding = true
    }
}

/// One of the three things the welcome says about Perch.
private struct WelcomePoint: View {
    let systemImage: String
    let tint: Color
    let title: String
    let text: String

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(alignment: .top, spacing: Theme.Spacing.l) {
            Image(systemName: systemImage)
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: theme.scaled(32), height: theme.scaled(32))
                .background(shape.fill(tint.opacity(0.16)))
                .overlay(shape.strokeBorder(tint.opacity(0.3), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.textPrimary)
                Text(text)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
