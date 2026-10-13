// SettingsControls.swift — the hand-drawn controls the Settings window uses besides switches:
// a slider, a segmented picker, an hour stepper and a two-step "are you sure?" button.
//
//   SettingsSlider(value: $settings.volume, range: 0...1, step: 0.05)
//   SettingsSegmented([SettingsOption(.hover, "Hover"), SettingsOption(.click, "Click")], selection: $settings.expandTrigger)
//   SettingsHourStepper(hour: $settings.quietStartHour)
//   ConfirmButton("Reset settings…", confirmTitle: "Yes, reset every setting") { settings.resetToDefaults() }
//   SettingsFormat.percent(fraction: 0.6)                      "60%" — the words shown next to controls
//
// Why not the system Slider and Picker? They are AppKit controls underneath: they ignore the
// theme, look out of place on the dark island style, and do not appear in snapshot images.
// These are plain SwiftUI drawing on top of the design system, so they match everything else.
// All of them dim themselves inside `.disabled(true)`.

import SwiftUI

// MARK: - Segmented picker

/// One choice in a SettingsSegmented.
struct SettingsOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let systemImage: String?

    var id: Value { value }

    init(_ value: Value, _ title: String, systemImage: String? = nil) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
    }
}

/// A row of mutually exclusive choices; the chosen one is a dark capsule.
struct SettingsSegmented<Value: Hashable>: View {
    private let options: [SettingsOption<Value>]
    @Binding private var selection: Value

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(_ options: [SettingsOption<Value>], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    var body: some View {
        let theme = Theme.current(settings)
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(option, theme: theme)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        // The outline is decoration only. Left hit-testable, a capsule outline laid over the
        // buttons swallows every click meant for them.
        .overlay(Capsule().strokeBorder(theme.stroke, lineWidth: 1).allowsHitTesting(false))
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
        .animation(PerchMotion.quick(reduce: settings.prefersCalm(systemReduceMotion)), value: selection)
    }

    private func segment(_ option: SettingsOption<Value>, theme: Theme) -> some View {
        let isSelected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            HStack(spacing: 4) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage).font(theme.font(size: 9.5, weight: .semibold))
                }
                Text(option.title)
                    .font(theme.font(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(minHeight: theme.scaled(22))
            .background(Capsule().fill(isSelected ? theme.island : Color.clear))
            .overlay(Capsule().strokeBorder(isSelected ? theme.strokeStrong : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Slider

/// A horizontal slider that snaps to `step`. Drag anywhere on it, or click to jump.
struct SettingsSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let width: CGFloat
    private let onEditingEnded: (() -> Void)?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false
    @State private var isHovering = false

    private static let knob: CGFloat = 16
    private static let track: CGFloat = 4

    /// - Parameters:
    ///   - step: The slider only stops on multiples of this (counted from the low end).
    ///   - width: Width of the whole control in points.
    ///   - onEditingEnded: Called when a drag is let go (and after each keyboard / VoiceOver step).
    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, width: CGFloat = 150,
         onEditingEnded: (() -> Void)? = nil) {
        self._value = value
        self.range = range
        self.step = step
        self.width = width
        self.onEditingEnded = onEditingEnded
    }

    var body: some View {
        let theme = Theme.current(settings)
        let fraction = SliderMath.fraction(of: value, in: range)
        let travel = max(1, width - Self.knob)
        let lit = (isHovering || isDragging) && isEnabled
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.12)).frame(height: Self.track)
            Capsule().fill(theme.accent)
                .frame(width: Self.knob / 2 + travel * fraction, height: Self.track)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(theme.accent.opacity(lit ? 0.9 : 0), lineWidth: 2))
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .scaleEffect(isDragging ? 1.12 : 1)
                .offset(x: travel * fraction)
        }
        .frame(width: width, height: 22)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard isEnabled else { return }
                isDragging = true
                let wanted = SliderMath.value(atX: drag.location.x, width: width, knob: Self.knob, range: range, step: step)
                // Only write real changes, so dragging inside one step saves nothing.
                if wanted != value { value = wanted }
            }
            .onEnded { _ in
                isDragging = false
                onEditingEnded?()
            })
        .onHover { isHovering = $0 }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: value = SliderMath.snapped(value + step, range: range, step: step)
            case .decrement: value = SliderMath.snapped(value - step, range: range, step: step)
            @unknown default: break
            }
            onEditingEnded?()
        }
    }
}

/// The arithmetic behind SettingsSlider, kept apart so it can be checked without a mouse.
enum SliderMath {
    /// Where `value` sits in `range`, as 0...1.
    static func fraction(of value: Double, in range: ClosedRange<Double>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0, value.isFinite else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    /// The nearest allowed value: inside the range and on a step.
    static func snapped(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let stepped = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
        // Tidy away floating-point dust (0.30000000000000004), then keep inside the range.
        let tidy = (stepped * 10_000).rounded() / 10_000
        return min(max(tidy, range.lowerBound), range.upperBound)
    }

    /// The value for a pointer position `x` points from the slider's left edge.
    static func value(atX x: CGFloat, width: CGFloat, knob: CGFloat, range: ClosedRange<Double>, step: Double) -> Double {
        let travel = max(1, width - knob)
        let fraction = Double(min(max((x - knob / 2) / travel, 0), 1))
        return snapped(range.lowerBound + fraction * (range.upperBound - range.lowerBound), range: range, step: step)
    }
}

// MARK: - Hour stepper

/// Picks an hour of the day (0...23) with minus and plus buttons. Wraps around midnight.
struct SettingsHourStepper: View {
    @Binding private var hour: Int

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.isEnabled) private var isEnabled

    init(hour: Binding<Int>) { self._hour = hour }

    var body: some View {
        let theme = Theme.current(settings)
        HStack(spacing: 2) {
            PerchIconButton(systemName: "minus", help: "One hour earlier", size: 22) { hour = SettingsFormat.wrappedHour(hour - 1) }
            Text(SettingsFormat.hour(hour))
                .font(theme.font(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .frame(minWidth: theme.scaled(64))
            PerchIconButton(systemName: "plus", help: "One hour later", size: 22) { hour = SettingsFormat.wrappedHour(hour + 1) }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        // The outline is decoration only. Left hit-testable, a capsule outline laid over the
        // buttons swallows every click meant for them.
        .overlay(Capsule().strokeBorder(theme.stroke, lineWidth: 1).allowsHitTesting(false))
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityValue(SettingsFormat.hour(hour))
    }
}

// MARK: - Confirm button

/// A button for things that cannot be undone. The first click only asks; a second click on the
/// confirmation does it. Looking away (Cancel, or waiting a few seconds) backs out.
///
/// Two things stop a hurried double-click from confirming by accident:
///   • Cancel, not the confirmation, appears under the pointer (the control is right-aligned in
///     its row, so the last button takes the place of the one just clicked);
///   • the confirmation only starts accepting clicks a moment after it appears.
struct ConfirmButton: View {
    private let title: String
    private let systemImage: String?
    private let confirmTitle: String
    private let isDestructive: Bool
    private let action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var isAsking: Bool
    /// False for the first moment of asking, while the confirmation ignores clicks.
    @State private var isArmed: Bool

    /// Seconds before the confirmation accepts a click.
    private static let armingDelay = 0.5
    /// Seconds the confirmation stays up before it backs out by itself.
    private static let patience = 8.0

    /// - Parameters:
    ///   - confirmTitle: The text of the second, deciding button: say exactly what will happen.
    ///   - startsAsking: Shows the confirmation straight away (used to draw it in snapshots).
    init(_ title: String, systemImage: String? = nil, confirmTitle: String, isDestructive: Bool = true,
         startsAsking: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.action = action
        self._isAsking = State(initialValue: startsAsking)
        self._isArmed = State(initialValue: startsAsking)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if isAsking {
                Button(confirmTitle) {
                    guard isArmed else { return }
                    isAsking = false
                    action()
                }
                .buttonStyle(.perch(isDestructive ? .destructive : .primary, size: .small))
                .disabled(!isArmed)
                Button("Cancel") { isAsking = false }
                    .buttonStyle(.perch(.secondary, size: .small))
            } else {
                Button { isAsking = true } label: {
                    HStack(spacing: 5) {
                        if let systemImage { Image(systemName: systemImage) }
                        Text(title)
                    }
                }
                .buttonStyle(.perch(isDestructive ? .destructive : .secondary, size: .small))
            }
        }
        .fixedSize()
        .animation(PerchMotion.quick(reduce: settings.prefersCalm(systemReduceMotion)), value: isAsking)
        .animation(PerchMotion.fade(reduce: settings.prefersCalm(systemReduceMotion)), value: isArmed)
        .task(id: isAsking) {
            guard isAsking else {
                isArmed = false
                return
            }
            do {
                if !isArmed {
                    try await Task.sleep(nanoseconds: UInt64(Self.armingDelay * 1_000_000_000))
                    isArmed = true
                }
                // A forgotten confirmation should not sit there armed forever.
                try await Task.sleep(nanoseconds: UInt64(Self.patience * 1_000_000_000))
                isAsking = false
            } catch {}
        }
    }
}

// MARK: - Words for values

/// How slider values and hours are written next to their controls.
enum SettingsFormat {
    /// 0.6 → "60%".
    static func percent(fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// An hour of the day the way this Mac writes times: "10 PM" or "22:00".
    static func hour(_ hour: Int) -> String {
        var parts = DateComponents()
        parts.hour = wrappedHour(hour)
        parts.minute = 0
        let calendar = Calendar.current
        guard let date = calendar.date(from: parts) else { return "\(wrappedHour(hour)):00" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j")
        let text = formatter.string(from: date)
        // 24-hour locales give a bare "22"; make that read as a time.
        return text.allSatisfy { $0.isNumber } ? text + ":00" : text
    }

    /// Keeps an hour inside 0...23, wrapping around midnight in both directions.
    static func wrappedHour(_ hour: Int) -> Int { ((hour % 24) + 24) % 24 }
}
