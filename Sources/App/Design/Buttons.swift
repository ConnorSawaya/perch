// Buttons.swift — the buttons used across Perch.
//
//   Button("Allow") { ... }.buttonStyle(.perch(.primary))
//   Button("Deny") { ... }.buttonStyle(.perch(.destructive, size: .small))
//   PerchIconButton(systemName: "gearshape.fill", help: "Open Settings") { ... }
//
// Four kinds: primary (the accent gradient — one per card at most), secondary (a quiet filled
// button), destructive (red-tinted) and ghost (no background until hovered). All of them react to
// hover and press, dim when disabled and follow the text-size setting.

import SwiftUI

struct PerchButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, ghost }
    enum Size { case small, regular, large }

    var kind: Kind
    var size: Size
    /// Replaces the theme accent (primary) or the text colour (other kinds).
    var tint: Color?
    /// Stretch to the width on offer, for buttons that share a row equally.
    var fullWidth: Bool

    init(_ kind: Kind = .secondary, size: Size = .regular, tint: Color? = nil, fullWidth: Bool = false) {
        self.kind = kind
        self.size = size
        self.tint = tint
        self.fullWidth = fullWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        PerchButtonBody(style: self, configuration: configuration)
    }
}

extension ButtonStyle where Self == PerchButtonStyle {
    /// Shorthand so call sites read `.buttonStyle(.perch(.primary))`.
    static func perch(_ kind: PerchButtonStyle.Kind = .secondary, size: PerchButtonStyle.Size = .regular,
                      tint: Color? = nil, fullWidth: Bool = false) -> PerchButtonStyle {
        PerchButtonStyle(kind, size: size, tint: tint, fullWidth: fullWidth)
    }
}

/// The drawing behind PerchButtonStyle. A separate view so it can track hover.
private struct PerchButtonBody: View {
    let style: PerchButtonStyle
    let configuration: ButtonStyleConfiguration

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var hovering = false

    private var metrics: (font: CGFloat, horizontal: CGFloat, vertical: CGFloat, minHeight: CGFloat, radius: CGFloat) {
        switch style.size {
        case .small: return (11, 9, 3, 22, 7)
        case .regular: return (12, 12, 5, 28, Theme.Radius.control)
        case .large: return (13, 16, 8, 34, 11)
        }
    }

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
        let lit = hovering && isEnabled
        let calm = settings.prefersCalm(systemReduceMotion)

        configuration.label
            .font(theme.font(size: metrics.font, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground(theme, lit: lit))
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .frame(maxWidth: style.fullWidth ? .infinity : nil)
            .frame(minHeight: theme.scaled(metrics.minHeight))
            .background(background(theme, shape: shape, lit: lit))
            .overlay(shape.strokeBorder(border(theme, lit: lit), lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !calm ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(PerchMotion.quick(reduce: calm), value: hovering)
            .animation(PerchMotion.quick(reduce: calm), value: configuration.isPressed)
    }

    private func foreground(_ theme: Theme, lit: Bool) -> Color {
        switch style.kind {
        case .primary: return theme.textOnAccent
        case .secondary: return style.tint ?? theme.textPrimary
        case .destructive: return theme.danger
        case .ghost: return style.tint ?? (lit ? theme.textPrimary : theme.textSecondary)
        }
    }

    @ViewBuilder
    private func background(_ theme: Theme, shape: RoundedRectangle, lit: Bool) -> some View {
        let pressed = configuration.isPressed
        switch style.kind {
        case .primary:
            ZStack {
                shape.fill(style.tint ?? theme.accent)
                shape.fill(Color.white.opacity(lit && !pressed ? 0.08 : 0))
                shape.fill(Color.black.opacity(pressed ? 0.18 : 0))
            }
        case .secondary:
            ZStack {
                shape.fill(theme.surfaceHover)
                shape.fill(Color.white.opacity(pressed ? 0.02 : (lit ? 0.07 : 0)))
            }
        case .destructive:
            shape.fill(theme.danger.opacity(pressed ? 0.3 : (lit ? 0.24 : 0.14)))
        case .ghost:
            shape.fill(Color.white.opacity(pressed ? 0.11 : (lit ? 0.07 : 0)))
        }
    }

    private func border(_ theme: Theme, lit: Bool) -> Color {
        switch style.kind {
        case .primary: return Color.white.opacity(0.14)
        case .secondary: return lit ? theme.strokeStrong : theme.stroke
        case .destructive: return theme.danger.opacity(lit ? 0.55 : 0.32)
        case .ghost: return .clear
        }
    }
}

/// A small square button that shows only an SF Symbol: header actions, close and dismiss buttons.
struct PerchIconButton: View {
    private let systemName: String
    private let help: String
    private let size: CGFloat
    private let isActive: Bool
    private let tint: Color?
    private let action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    /// - Parameters:
    ///   - help: Tooltip and VoiceOver label. Say what the button does in plain words.
    ///   - size: Width and height of the clickable square, before text scaling.
    ///   - isActive: Draws the icon in the accent colour (a toggle that is on).
    ///   - tint: Overrides the icon colour.
    init(systemName: String, help: String, size: CGFloat = 24, isActive: Bool = false, tint: Color? = nil,
         action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.size = size
        self.isActive = isActive
        self.tint = tint
        self.action = action
    }

    var body: some View {
        let theme = Theme.current(settings)
        let side = theme.scaled(size)
        let shape = RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: side * 0.5, weight: .semibold))
                .foregroundStyle(tint ?? (isActive ? theme.accent : (hovering ? theme.textPrimary : theme.textSecondary)))
                .frame(width: side, height: side)
                .background(shape.fill(Color.white.opacity(hovering ? 0.09 : 0)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
