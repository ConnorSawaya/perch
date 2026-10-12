// GeneralPage.swift — Settings → General: when Perch starts, and how the panel opens and hides.

import SwiftUI

struct GeneralSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        SettingsSection("Starting up", systemImage: "power") {
            SettingsToggleRow("Open Perch when you log in",
                              subtitle: "Perch starts quietly with your Mac, so the notch is ready for your first session.",
                              systemImage: "sunrise.fill", isOn: $settings.launchAtLogin)
            SettingsToggleRow("Show the menu-bar icon",
                              subtitle: "A small bird with a menu for Settings, mute and quit. Hidden, use the gear in the panel.",
                              systemImage: "menubar.arrow.up.rectangle", isOn: $settings.showMenuBarIcon)
        }

        SettingsSection("The panel", systemImage: "rectangle.expand.vertical") {
            SettingsChoiceRow("Open the panel with",
                              subtitle: settings.expandTrigger == .hover
                                ? "Rest the pointer on the notch and the panel drops down."
                                : "Click the notch to open the panel; click elsewhere to close it.",
                              systemImage: "cursorarrow.click.2",
                              options: [
                                  SettingsOption(ExpandTrigger.hover, "Hover", systemImage: "cursorarrow"),
                                  SettingsOption(ExpandTrigger.click, "Click", systemImage: "cursorarrow.click"),
                              ],
                              selection: $settings.expandTrigger)
            SettingsToggleRow("Open when an agent needs you",
                              subtitle: "The panel opens by itself for a permission, a question or a plan.",
                              systemImage: "hand.raised.fill", isOn: $settings.autoExpandOnAttention)
            SettingsToggleRow("Hide when nothing is running",
                              subtitle: "The pill disappears while there are no sessions and comes back when one starts.",
                              systemImage: "moon.zzz.fill", isOn: $settings.hideWhenNoSessions)
        }
    }
}
