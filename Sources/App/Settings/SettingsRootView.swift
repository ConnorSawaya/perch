// SettingsRootView.swift — everything inside the Settings window.
//
// The window itself (title bar, size, coming to the front) belongs to the shell; this view is
// what it shows: a sidebar listing the four pages on the left and the chosen page on the right.
// The first time Perch runs, a short welcome panel sits on top until it is dismissed.
//
//   SettingsRootView().perchEnvironment(env)
//
// Where things are:
//   SettingsPageID       the four pages, and which page each SettingsTab opens   (SettingsPageInfo.swift)
//   SettingsSidebar      the list of pages                      (SettingsSidebar.swift)
//   SettingsPage         title + scrolling area around a page   (SettingsPage.swift)
//   Pages/…              one file per page
//   SettingsRows / SettingsControls   the rows and controls every page is built from
//   WelcomePanel         the first-run welcome                  (WelcomePanel.swift)

import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init() {}

    var body: some View {
        let theme = Theme.current(settings)
        let page = SettingsPageID(ui.settingsTab)
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: theme.scaled(SettingsRootView.sidebarWidth))
            Rectangle().fill(theme.stroke).frame(width: 1)
            SettingsPage(page: page)
                // A fresh view per page, so each one opens scrolled to the top.
                .id(page)
        }
        // Say plainly how small and how big this view likes to be. Without this a host that asks
        // would be told "as tall as the longest page", because that is a scroll view's natural size.
        .frame(minWidth: Self.minimumSize.width, idealWidth: Self.idealSize.width, maxWidth: .infinity,
               minHeight: Self.minimumSize.height, idealHeight: Self.idealSize.height, maxHeight: .infinity)
        .background(theme.island)
        .overlay {
            if !settings.hasCompletedOnboarding {
                WelcomeOverlay()
                    .transition(.opacity)
            }
        }
        .animation(PerchMotion.fade(reduce: settings.prefersCalm(systemReduceMotion)), value: settings.hasCompletedOnboarding)
        .preferredColorScheme(.dark)
    }

    /// Sidebar width in points before text scaling.
    static let sidebarWidth: CGFloat = 196
    /// The smallest size the layout is designed for. The shell's own minimum (760 x 520) is larger.
    static let minimumSize = CGSize(width: 700, height: 500)
    /// The size the window opens at.
    static let idealSize = CGSize(width: 860, height: 620)
}

/// Picks the view for a page. The only place that lists all four.
struct SettingsPageContent: View {
    let page: SettingsPageID

    var body: some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .look: LookSettingsPage()
        case .sounds: SoundsSettingsPage()
        case .agents: AgentsSettingsPage()
        }
    }
}
