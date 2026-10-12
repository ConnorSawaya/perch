// Gauges.swift — "how full is it" drawings: a ring and a straight bar.
//
//   ProgressRing(value: 0.37)                       usage limits, in the pill and the usage tab
//   ProgressRing(value: 0.82, size: 44, tint: theme.warning).overlay(Text("82%"))
//   PerchMeter(value: 0.42).frame(width: 36)        context window on a session card
//
// Both take a value from 0 to 1 (anything outside is clamped) and animate when it changes.

import SwiftUI

struct ProgressRing: View {
    private let value: Double
    private let size: CGFloat
    private let lineWidth: CGFloat?
    private let tint: Color?
    private let secondaryTint: Color?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// - Parameters:
    ///   - value: 0...1.
    ///   - size: Outer diameter in points.
    ///   - lineWidth: Thickness of the ring. Defaults to a sixth of the diameter.
    ///   - tint: Ring colour. Defaults to the theme accent gradient.
    ///   - secondaryTint: Second gradient colour; leave nil for a single colour.
    init(value: Double, size: CGFloat = 16, lineWidth: CGFloat? = nil, tint: Color? = nil, secondaryTint: Color? = nil) {
        self.value = value
        self.size = size
        self.lineWidth = lineWidth
        self.tint = tint
        self.secondaryTint = secondaryTint
    }

    var body: some View {
        let theme = Theme.current(settings)
        let width = lineWidth ?? max(2, size / 6)
        let filled = min(max(value.isFinite ? value : 0, 0), 1)
        let start = tint ?? theme.accent
        let end = secondaryTint ?? (tint == nil ? theme.accentAlt : start)

        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: width)
            Circle()
                .trim(from: 0, to: filled)
                .stroke(LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        // Inset by half the line so the stroke stays inside the requested size.
        .padding(width / 2)
        .frame(width: size, height: size)
        .animation(PerchMotion.quick(reduce: settings.prefersCalm(systemReduceMotion)), value: filled)
        .accessibilityElement()
        .accessibilityValue("\(Int((filled * 100).rounded())) percent")
    }
}

/// A thin horizontal bar. Stretches to the width it is given.
struct PerchMeter: View {
    private let value: Double
    private let tint: Color?
    private let height: CGFloat

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// - Parameters:
    ///   - value: 0...1.
    ///   - tint: Fill colour. Defaults to the theme accent gradient.
    init(value: Double, tint: Color? = nil, height: CGFloat = 4) {
        self.value = value
        self.tint = tint
        self.height = height
    }

    var body: some View {
        let theme = Theme.current(settings)
        let filled = min(max(value.isFinite ? value : 0, 0), 1)
        let fill = tint.map { LinearGradient(colors: [$0.opacity(0.75), $0], startPoint: .leading, endPoint: .trailing) }
            ?? LinearGradient(colors: [theme.accent, theme.accentAlt], startPoint: .leading, endPoint: .trailing)

        Capsule()
            .fill(Color.white.opacity(0.12))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(fill)
                        // Never narrower than a dot, so "1%" is still visible.
                        .frame(width: filled > 0 ? max(height, geometry.size.width * filled) : 0)
                }
            }
            .animation(PerchMotion.quick(reduce: settings.prefersCalm(systemReduceMotion)), value: filled)
            .accessibilityElement()
            .accessibilityValue("\(Int((filled * 100).rounded())) percent")
    }
}
