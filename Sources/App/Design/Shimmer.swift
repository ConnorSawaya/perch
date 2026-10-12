// Shimmer.swift — a band of light that sweeps across text to say "this is happening right now".
//
//   Text(tool.summary).perchShimmer(isActive: session.state == .runningTool)
//
// The light only shows where the text is (the text is used as a mask). With "Reduce motion" on,
// or when not active, the text is left exactly as it was.

import SwiftUI

extension View {
    /// Sweeps a soft highlight across this view while `isActive` is true.
    func perchShimmer(isActive: Bool = true) -> some View {
        modifier(PerchShimmer(isActive: isActive))
    }
}

private struct PerchShimmer: ViewModifier {
    let isActive: Bool

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// Seconds for one sweep, including a short rest before the next one.
    private let period = 1.9

    func body(content: Content) -> some View {
        if isActive && !settings.prefersCalm(systemReduceMotion) {
            content
                .overlay {
                    GeometryReader { geometry in
                        let band = max(36, geometry.size.width * 0.3)
                        PerchClock(fps: 30) { time in
                            // Start part-way across so the first frame already shows the light.
                            let progress = (time / period + 0.35).truncatingRemainder(dividingBy: 1)
                            LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: -band + (geometry.size.width + band * 2) * progress)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .mask(content)
        } else {
            content
        }
    }
}
