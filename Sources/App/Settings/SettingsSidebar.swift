// SettingsSidebar.swift — the left column of the Settings window: Perch's name, the four pages,
// and a one-line "is Perch listening?" status at the bottom.
//
// Clicking a page sets `UIState.settingsTab`; the shell sets the same value when something asks
// for Settings to open on a particular tab, so both stay in step. Several tabs share a page
// (see SettingsPageInfo.swift), and the entry of whichever page is showing is highlighted.

import SwiftUI

struct SettingsSidebar: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var agents: AgentsStore

    var body: some View {
        let theme = Theme.current(settings)
        VStack(alignment: .leading, spacing: 0) {
            brand(theme)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.l)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPageID.allCases) { page in
                    SettingsSidebarItem(page: page, isSelected: SettingsPageID(ui.settingsTab) == page) {
                        if SettingsPageID(ui.settingsTab) != page { ui.settingsTab = page.tab }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
            Spacer(minLength: Theme.Spacing.l)
            status(theme)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.l)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surfaceSunken)
    }

    private func brand(_ theme: Theme) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.island)
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.strokeStrong, lineWidth: 1)
                MascotView(mood: MascotMood(sessions.headline?.state), size: theme.scaled(18))
            }
            .frame(width: theme.scaled(32), height: theme.scaled(32))
            VStack(alignment: .leading, spacing: 0) {
                Text(PerchPaths.appName)
                    .font(theme.font(.title))
                    .foregroundStyle(theme.textPrimary)
                Text("Settings")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Says in a few words whether Perch can hear the agents right now.
    private func status(_ theme: Theme) -> some View {
        let healthy = agents.serverRunning && agents.helperInstalled
        let connected = agents.statuses.filter { $0.hookStatus == .installed && settings.isEnabled($0.agent) }.count
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if ui.isDemo {
                Chip("Demo mode is on", systemImage: "theatermasks.fill", tint: theme.ask)
            }
            HStack(spacing: Theme.Spacing.s) {
                Circle().fill(healthy ? theme.success : theme.warning).frame(width: 7, height: 7)
                Text(healthy ? "Listening" : "Not listening")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textSecondary)
                Text(connected == 0 ? "· none connected" : "· \(connected) connected")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }
}

/// One page in the sidebar: a coloured icon tile and the page's name.
private struct SettingsSidebarItem: View {
    let page: SettingsPageID
    let isSelected: Bool
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: page.systemImage)
                    .font(theme.font(size: 10.5, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textTertiary)
                    .frame(width: theme.scaled(22), height: theme.scaled(22))
                Text(page.title)
                    .font(theme.font(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 5)
            .background(shape.fill(isSelected ? theme.surfaceHover : Color.white.opacity(hovering ? 0.05 : 0)))
            .overlay(shape.strokeBorder(isSelected ? theme.strokeStrong : Color.clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
