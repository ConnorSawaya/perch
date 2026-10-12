// GlowBorder.swift — the thin coloured edge that means "this needs you".
//
// Put it on top of a card or the island:
//   .overlay(GlowBorder(cornerRadius: Theme.Radius.card, isActive: needsAttention))
//   .overlay(GlowBorder(IslandShape(closed: false)))
//
// It draws the shape's outline in one colour that breathes slowly, with a faint soft copy
// underneath. Settings: with "Glow effects" off it falls back to a plain
// thin outline; with "Reduce motion" on it stands still.

import SwiftUI

struct GlowBorder<S: Shape>: View {
    private let shape: S
    private let colors: [Color]?
    private let lineWidth: CGFloat
    private let blur: CGFloat
    private let isActive: Bool

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - shape: The outline to light up.
    ///   - colors: Gradient colours. Defaults to the theme's glow colours.
    ///   - lineWidth: Width of the sharp line; the glow is drawn about three times wider.
    ///   - blur: How far the glow spreads.
    ///   - isActive: False draws nothing, so it can sit on a view permanently.
    init(_ shape: S, colors: [Color]? = nil, lineWidth: CGFloat = 1.5, blur: CGFloat = 7, isActive: Bool = true) {
        self.shape = shape
        self.colors = colors
        self.lineWidth = lineWidth
        self.blur = blur
        self.isActive = isActive
    }

    var body: some View {
        if isActive {
            let palette = resolvedColors
            Group {
                if settings.showGlow {
                    // One full turn every 4.5 seconds: noticeable, never frantic.
                    PerchClock(fps: 30) { time in
                        layers(palette, angle: .degrees(time * 80 + 35))
                    }
                } else {
                    shape.stroke(palette.first?.opacity(0.75) ?? .clear, lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var resolvedColors: [Color] {
        let chosen = colors ?? Theme.current(settings).glowColors
        return chosen.isEmpty ? [Theme.current(settings).accent] : chosen
    }

    private func layers(_ palette: [Color], angle: Angle) -> some View {
        // One colour that breathes slowly instead of a spinning gradient.
        let colour = palette[0]
        let breath = 0.8 + 0.2 * sin(angle.radians * 1.5)
        return ZStack {
            shape.stroke(colour, lineWidth: lineWidth * 2).blur(radius: blur * 0.6).opacity(0.25 * breath)
            shape.stroke(colour, lineWidth: lineWidth).opacity(breath)
        }
    }
}

extension GlowBorder where S == RoundedRectangle {
    /// Glow around a rounded rectangle, the common case for cards.
    init(cornerRadius: CGFloat = Theme.Radius.card, colors: [Color]? = nil, lineWidth: CGFloat = 1.5, blur: CGFloat = 7,
         isActive: Bool = true) {
        self.init(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), colors: colors,
                  lineWidth: lineWidth, blur: blur, isActive: isActive)
    }
}
