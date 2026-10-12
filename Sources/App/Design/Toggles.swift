// Toggles.swift — Perch's on/off switch and the settings row built around it.
//
//   PerchToggleRow("Glow effects", subtitle: "A soft light when something needs you.",
//                  systemImage: "sparkles", isOn: $settings.showGlow)
//   Toggle("Sounds", isOn: $settings.soundsEnabled).toggleStyle(PerchToggleStyle())
//
// The switch is drawn in SwiftUI (not the system control) so it follows the theme, looks the
// same in the notch panel and the settings window, and shows up in snapshot images.

import SwiftUI

struct PerchToggleStyle: ToggleStyle {
    init() {}

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.l) {
            configuration.label
            Spacer(minLength: Theme.Spacing.m)
            PerchSwitch(isOn: configuration.$isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

/// The switch on its own, for places that lay out their own label.
struct PerchSwitch: View {
    @Binding private var isOn: Bool

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(isOn: Binding<Bool>) { self._isOn = isOn }

    var body: some View {
        let theme = Theme.current(settings)
        let width: CGFloat = 32
        let height: CGFloat = 19
        let knob = height - 4
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? AnyShapeStyle(theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.14)))
            Capsule().strokeBorder(Color.white.opacity(isOn ? 0.18 : 0.1), lineWidth: 1)
            Circle()
                // The mono theme's "on" track is nearly white, so a white knob would vanish on it.
                .fill(isOn ? (theme.id == .mono ? theme.textOnAccent : Color.white) : Color.white.opacity(0.8))
                .frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                .padding(2)
        }
        .frame(width: width, height: height)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture { if isEnabled { isOn.toggle() } }
        .animation(PerchMotion.quick(reduce: settings.prefersCalm(systemReduceMotion)), value: isOn)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAction { if isEnabled { isOn.toggle() } }
    }
}

/// A settings row: icon, title, one-line explanation and a switch.
struct PerchToggleRow: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    @Binding private var isOn: Bool

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - subtitle: One plain sentence saying what the toggle does.
    ///   - systemImage: Optional SF Symbol shown before the title.
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self._isOn = isOn
    }

    var body: some View {
        let theme = Theme.current(settings)
        Toggle(isOn: $isOn) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(theme.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: theme.scaled(18))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.font(.label))
                        .foregroundStyle(theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .toggleStyle(PerchToggleStyle())
    }
}
