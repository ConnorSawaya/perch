// MascotPicker.swift — the mascot tiles in Settings → Look: "Off" and one tile per style.
//
// Each style is drawn live with the real MascotView, so what you pick here is exactly what sits
// in the pill. "Off" shows the plain coloured dot the pill has instead. One click sets both
// `showMascot` and `mascotStyle`.

import SwiftUI

extension MascotStyle {
    var title: String {
        switch self {
        case .orb: return "Orb"
        case .pixel: return "Bird"
        case .ring: return "Rings"
        }
    }

    /// A few words for VoiceOver, which cannot see the drawing.
    var tagline: String {
        switch self {
        case .orb: return "A drop of living light"
        case .pixel: return "A tiny pixel-art bird"
        case .ring: return "Arcs circling a dot"
        }
    }
}

struct SettingsMascotPicker: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            SettingsMascotTile(style: nil, isSelected: !settings.showMascot) {
                if settings.showMascot { settings.showMascot = false }
            }
            ForEach(MascotStyle.allCases) { style in
                SettingsMascotTile(style: style, isSelected: settings.showMascot && settings.mascotStyle == style) {
                    if settings.mascotStyle != style { settings.mascotStyle = style }
                    if !settings.showMascot { settings.showMascot = true }
                }
            }
        }
        .fixedSize()
    }
}

/// One choice: a mascot style, or no mascot when `style` is nil.
private struct SettingsMascotTile: View {
    let style: MascotStyle?
    let isSelected: Bool
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let style {
                        MascotView(mood: .busy, size: theme.scaled(18), style: style)
                    } else {
                        StateDot(.working, size: 7)
                    }
                }
                .frame(width: theme.scaled(20), height: theme.scaled(20))
                Text(style?.title ?? "Off")
                    .font(theme.font(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: theme.scaled(50))
            .padding(.vertical, 5)
            .background(shape.fill(isSelected ? theme.island : Color.white.opacity(hovering ? 0.08 : 0.04)))
            .overlay(shape.strokeBorder(isSelected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.stroke),
                                        lineWidth: isSelected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(style.map { "\($0.title) mascot, \($0.tagline)" } ?? "No mascot, a plain colored dot")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
