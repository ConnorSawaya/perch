// SettingsRows.swift — the building blocks every Settings page is made of.
//
//   SettingsSection("The notch", footer: "…") {        a titled card; rows get hairlines between them
//       SettingsToggleRow("Animations", subtitle: "…", systemImage: "sparkles", isOn: $animations)
//       SettingsSliderRow("Text size", subtitle: "…", value: $settings.textScale, range: 0.85...1.3,
//                         step: 0.05, format: SettingsFormat.percent(fraction:))
//       SettingsChoiceRow("Open with", subtitle: "…", options: […], selection: $settings.expandTrigger)
//       SettingsRow("Mascot", subtitle: "…") { SettingsMascotPicker() }        any control you like
//   }
//   SettingsBullet("…", systemImage: "minus.circle.fill")   one line of a short list
//
// Every row has the same shape — icon, title, one plain sentence, control on the right — so a
// whole page can be read top to bottom like a list. Rows dim themselves inside `.disabled(true)`.

import SwiftUI

// MARK: - Section

/// A group of rows on one card, with an optional small title above and a footnote below.
struct SettingsSection<Content: View>: View {
    private let title: String?
    private let systemImage: String?
    private let footer: String?
    private let tint: Color?
    private let content: Content

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - footer: A sentence under the card for something that applies to the whole group.
    ///   - tint: Washes the card with a colour (the uninstall panel uses red).
    init(_ title: String? = nil, systemImage: String? = nil, footer: String? = nil, tint: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.footer = footer
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let title {
                SectionHeader(title, systemImage: systemImage, tint: tint)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
            VStack(alignment: .leading, spacing: 0) {
                // Put a hairline between every two rows, however many the caller passed.
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            PerchDivider().padding(.leading, SettingsRowMetrics.textInset)
                        }
                        row
                            .padding(.horizontal, SettingsRowMetrics.sidePadding)
                            .padding(.vertical, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardBackground(tint: tint))
        }
    }
}

/// Measurements shared by the rows and the section that holds them.
enum SettingsRowMetrics {
    static let sidePadding: CGFloat = 14
    static let iconColumn: CGFloat = 20
    /// Where a row's text starts, measured from the card's edge. Dividers start there too.
    static let textInset: CGFloat = sidePadding + iconColumn + Theme.Spacing.m
    /// Row icons keep one size whatever the text size is, so they always fit their column.
    static let iconFont = Font.system(size: 12.5, weight: .medium)

    /// The colour of the sentence under a row's title. The explanations are the point of this
    /// window, so they are a step brighter than the theme's faintest text (which is meant for
    /// asides) while still sitting clearly below the titles.
    static func explanationColor(_ theme: Theme) -> Color { theme.textSecondary.opacity(0.78) }
}

// MARK: - Rows

/// The left part of every row: icon, title and explanation.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tint: Color?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let theme = Theme.current(settings)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(.label))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isEnabled ? 1 : 0.5)
        .help(subtitle ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// A row with any control on the right.
struct SettingsRow<Control: View>: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let tint: Color?
    private let control: Control

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tint: Color? = nil,
         @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.l) {
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint)
            control
        }
    }
}

/// A row with a switch. Clicking anywhere on the row flips it.
struct SettingsToggleRow: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let tint: Color?
    @Binding private var isOn: Bool

    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, tint: Color? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle, systemImage: systemImage, tint: tint) {
            PerchSwitch(isOn: $isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { isOn.toggle() } }
    }
}

/// A row with a slider and the current value written out next to it.
struct SettingsSliderRow: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let appliesOnRelease: Bool
    private let format: (Double) -> String

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.isEnabled) private var isEnabled
    /// Where the knob is during a drag that has not been applied yet (`appliesOnRelease` only).
    @State private var draft: Double?

    /// - Parameters:
    ///   - appliesOnRelease: The setting changes when the knob is let go instead of while it is
    ///     being dragged. Use it when the setting moves the slider itself (text size re-lays-out
    ///     the whole window, which would pull the knob out from under the pointer).
    ///   - format: Turns the number into words for the label, e.g. `SettingsFormat.percent`.
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, value: Binding<Double>,
         range: ClosedRange<Double>, step: Double, appliesOnRelease: Bool = false, format: @escaping (Double) -> String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self._value = value
        self.range = range
        self.step = step
        self.appliesOnRelease = appliesOnRelease
        self.format = format
    }

    var body: some View {
        let theme = Theme.current(settings)
        let shown = Binding<Double>(get: { draft ?? value },
                                    set: { if appliesOnRelease { draft = $0 } else { value = $0 } })
        SettingsRow(title, subtitle: subtitle, systemImage: systemImage) {
            HStack(spacing: Theme.Spacing.m) {
                SettingsSlider(value: shown, range: range, step: step) {
                    if let draft {
                        value = draft
                        self.draft = nil
                    }
                }
                Text(format(shown.wrappedValue))
                    .font(theme.font(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: theme.scaled(62), alignment: .trailing)
                    .opacity(isEnabled ? 1 : 0.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(format(shown.wrappedValue))
    }
}

/// A row with a segmented picker.
struct SettingsChoiceRow<Value: Hashable>: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let options: [SettingsOption<Value>]
    @Binding private var selection: Value

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil,
         options: [SettingsOption<Value>], selection: Binding<Value>) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.options = options
        self._selection = selection
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle, systemImage: systemImage) {
            SettingsSegmented(options, selection: $selection)
        }
    }
}

/// One line of a short list: a small coloured mark and a sentence.
struct SettingsBullet: View {
    private let text: String
    private let systemImage: String
    private let tint: Color?

    @EnvironmentObject private var settings: AppSettings

    init(_ text: String, systemImage: String = "circle.fill", tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        let theme = Theme.current(settings)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(theme.font(size: 10, weight: .semibold))
                .foregroundStyle(tint ?? theme.textTertiary)
                .frame(width: theme.scaled(12))
            Text(text)
                .font(theme.font(.caption))
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
