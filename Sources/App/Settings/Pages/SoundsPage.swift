// SoundsPage.swift — Settings → Sounds & approvals: what Perch plays and when it stays quiet,
// and what can be answered from the notch with which safety rails.

import SwiftUI

struct SoundsSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.perchActions) private var actions

    var body: some View {
        let theme = Theme.current(settings)
        let on = settings.soundsEnabled

        SettingsSection("Sounds", systemImage: "speaker.wave.2.fill") {
            SettingsToggleRow("Play sounds",
                              subtitle: "A short sound when an agent needs you, finishes or runs into an error.",
                              systemImage: on ? "speaker.wave.2.fill" : "speaker.slash.fill", isOn: $settings.soundsEnabled)
            SettingsSliderRow("Volume",
                              subtitle: "How loud Perch is next to the rest of your Mac.",
                              systemImage: "dial.medium.fill", value: $settings.volume, range: 0...1, step: 0.05,
                              format: SettingsFormat.percent(fraction:))
                .disabled(!on)
            SettingsRow("Sound style", subtitle: packExplanation, systemImage: "music.note.list") {
                HStack(spacing: Theme.Spacing.m) {
                    SettingsSegmented([
                        SettingsOption(SoundPack.chime, "Chime"),
                        SettingsOption(SoundPack.arcade, "Arcade"),
                        SettingsOption(SoundPack.soft, "Soft"),
                        SettingsOption(SoundPack.system, "Mac"),
                    ], selection: $settings.soundPack)
                    // Plays even while sounds are off elsewhere, but not while this row is disabled.
                    Button { actions.previewSound(.done) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("Hear it")
                        }
                    }
                    .buttonStyle(.perch(.secondary, size: .small))
                }
            }
            .disabled(!on)
            SettingsRow("Quiet hours", subtitle: quietExplanation, systemImage: "moon.zzz.fill") {
                HStack(spacing: Theme.Spacing.m) {
                    HStack(spacing: Theme.Spacing.s) {
                        SettingsHourStepper(hour: $settings.quietStartHour)
                        Text("to")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.textTertiary)
                        SettingsHourStepper(hour: $settings.quietEndHour)
                    }
                    .disabled(!settings.quietHoursEnabled)
                    PerchSwitch(isOn: $settings.quietHoursEnabled)
                }
            }
            .disabled(!on)
        }

        SettingsSection("Approvals", systemImage: "hand.raised.fill",
                        footer: settings.autoAllowReadOnly
                            ? "Auto-allow is on. Read-only requests will not appear in the notch; everything else still asks."
                            : "Perch never answers for you. Every request waits until you decide, here or in the terminal.") {
            SettingsToggleRow("Approve from the notch",
                              subtitle: "Answer permissions, questions and plans here. Off, the agent asks in its terminal as usual.",
                              systemImage: "checkmark.shield.fill", isOn: answersInNotch)
            SettingsToggleRow("Ask twice for risky commands",
                              subtitle: "Deleting files, sudo, force-pushing or piping a download into a shell needs a second click.",
                              systemImage: "exclamationmark.triangle.fill", tint: theme.warning, isOn: $settings.confirmDangerous)
            SettingsToggleRow("Allow read-only tools without asking",
                              subtitle: "Perch answers \u{201C}allow\u{201D} by itself when an agent only wants to look: reading a "
                                + "file, listing a folder, searching. Nothing that changes anything is ever allowed this way. "
                                + "Off unless you turn it on.",
                              systemImage: "eyeglasses", isOn: $settings.autoAllowReadOnly)
        }
    }

    /// One switch for the three kinds of request that can be answered in the notch.
    private var answersInNotch: Binding<Bool> {
        Binding(get: { settings.approvalsInNotch || settings.questionsInNotch || settings.planReviewInNotch },
                set: { on in
                    settings.approvalsInNotch = on
                    settings.questionsInNotch = on
                    settings.planReviewInNotch = on
                })
    }

    private var packExplanation: String {
        switch settings.soundPack {
        case .chime: return "Short, clear bell tones."
        case .arcade: return "Playful blips, like an old game."
        case .soft: return "Low, rounded tones."
        case .system: return "The alert sounds of macOS."
        }
    }

    private var quietExplanation: String {
        if settings.quietHoursEnabled && settings.quietStartHour == settings.quietEndHour {
            return "Pick two different hours."
        }
        return settings.inQuietHours() ? "No sounds between these hours. Quiet now." : "No sounds between these hours."
    }
}
