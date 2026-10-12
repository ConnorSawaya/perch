// LookPage.swift — Settings → Look: the theme, the mascot, text size, animations and the usage
// ring in the pill.
//
// The two pickers drawn here live in Settings/Look: SettingsThemePicker and
// SettingsMascotPicker.

import SwiftUI

struct LookSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader("Theme", systemImage: "paintpalette.fill")
                .padding(.horizontal, Theme.Spacing.xs)
            SettingsThemePicker()
        }

        SettingsSection("The notch", systemImage: "capsule.fill") {
            SettingsRow("Mascot",
                        subtitle: "The small character on the left of the notch.",
                        systemImage: "bird.fill") {
                SettingsMascotPicker()
            }
            SettingsSliderRow("Text size",
                              subtitle: "All of Perch's text, here and in the notch. It changes when you let go.",
                              systemImage: "textformat.size", value: $settings.textScale, range: 0.85...1.3, step: 0.05,
                              appliesOnRelease: true, format: SettingsFormat.percent(fraction:))
            SettingsToggleRow("Animations",
                              subtitle: "Glow, confetti and moving effects. Off, Perch keeps still.",
                              systemImage: "sparkles", isOn: animations)
            SettingsToggleRow("Show usage in the pill",
                              subtitle: "A small ring on the right of the notch shows how much of a limit is used.",
                              systemImage: "circle.dotted.circle", isOn: usageInPill)
            SettingsChoiceRow("The ring measures",
                              subtitle: metricExplanation,
                              systemImage: "gauge.with.dots.needle.50percent",
                              options: [
                                  SettingsOption(PillMetric.fiveHour, "5-hour limit"),
                                  SettingsOption(PillMetric.weekly, "Weekly limit"),
                                  SettingsOption(PillMetric.context, "Context"),
                              ],
                              selection: $settings.pillMetric)
                .disabled(!usageInPill.wrappedValue)
        }
    }

    /// One switch for every effect: glow and confetti go on and off together, and "reduce
    /// motion" is always their opposite.
    private var animations: Binding<Bool> {
        Binding(get: { (settings.showGlow || settings.showParticles) && !settings.reduceMotion },
                set: { on in
                    settings.showGlow = on
                    settings.showParticles = on
                    settings.reduceMotion = !on
                })
    }

    /// On means a ring is really drawn, so turning it on also picks something to measure.
    private var usageInPill: Binding<Bool> {
        Binding(get: { settings.showUsageInPill && settings.pillMetric != .none },
                set: { on in
                    settings.showUsageInPill = on
                    if on && settings.pillMetric == .none { settings.pillMetric = .fiveHour }
                })
    }

    private var metricExplanation: String {
        switch settings.pillMetric {
        case .fiveHour, .none: return "The short rolling limit, the one that usually stops a long session."
        case .weekly: return "How much of the weekly limit is used."
        case .context: return "How full the busiest session's memory is."
        }
    }
}
