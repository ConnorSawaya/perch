// AuroraHeader.swift — the soft, slowly drifting light behind the top of the open panel.
//
//   .background(alignment: .top) { AuroraHeader().frame(height: 110) }
//
// It is a handful of blurry colour patches (plain radial gradients, so there is no costly blur)
// that wander left and right. The view fades to nothing at its top and bottom edge, which keeps
// the area right next to the notch pure black. With "Glow effects" off it is not drawn; with
// "Reduce motion" on, or when `isAnimating` is false, it stands still.

import SwiftUI

struct AuroraHeader: View {
    private let colors: [Color]?
    private let isAnimating: Bool
    private let intensity: Double

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - colors: Patch colours. Defaults to the theme's aurora colours.
    ///   - isAnimating: Pass false to freeze it (e.g. when there is nothing going on).
    ///   - intensity: 0...1, how strong the light is.
    init(colors: [Color]? = nil, isAnimating: Bool = true, intensity: Double = 1) {
        self.colors = colors
        self.isAnimating = isAnimating
        self.intensity = min(max(intensity, 0), 1)
    }

    var body: some View {
        if settings.showGlow {
            let palette = colors ?? Theme.current(settings).auroraColors
            let strength = intensity
            // Slow drift: 20 redraws a second is plenty.
            PerchClock(fps: 20, isRunning: isAnimating) { time in
                Canvas { context, size in
                    guard !palette.isEmpty, size.width > 1, size.height > 1 else { return }
                    context.blendMode = .screen
                    for (index, colour) in palette.enumerated() {
                        // Each patch has its own lane and wanders around it. At time 0 every patch
                        // sits in the middle of its lane, so the resting picture is evenly lit.
                        let lane = (Double(index) + 0.5) / Double(palette.count)
                        let drift = sin(time * 0.22 + Double(index) * .pi) * 0.14
                        let bob = sin(time * 0.17 + Double(index) * 2.0) * 0.14
                        let centre = CGPoint(x: size.width * (lane + drift), y: size.height * (0.55 + bob))
                        let radius = size.width * 0.4
                        // Squash the circle into a wide ellipse by scaling the drawing vertically.
                        var layer = context
                        layer.translateBy(x: centre.x, y: centre.y)
                        layer.scaleBy(x: 1, y: max(0.1, size.height * 0.8 / radius))
                        layer.fill(Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
                                   with: .radialGradient(Gradient(colors: [colour.opacity(0.55 * strength), colour.opacity(0)]),
                                                         center: .zero, startRadius: 0, endRadius: radius))
                    }
                }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.55),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
