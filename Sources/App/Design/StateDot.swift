// StateDot.swift — the small coloured dot that says what a session is doing.
//
// The colour comes from `Theme.color(for:)`. The dot also moves a little, differently per state,
// so the state can be read without relying on colour alone:
//   idle / ended   hollow ring, still
//   busy           solid dot with a slow breathing halo
//   needs you      solid dot with quick double "pings"
//   done / failed  solid dot, still

import SwiftUI

struct StateDot: View {
    private let state: SessionState
    private let size: CGFloat
    private let color: Color?

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - size: Diameter of the dot. The halo is drawn outside it and takes no layout space.
    ///   - color: Overrides the state colour (rarely needed).
    init(_ state: SessionState, size: CGFloat = 8, color: Color? = nil) {
        self.state = state
        self.size = size
        self.color = color
    }

    var body: some View {
        let colour = color ?? Theme.current(settings).color(for: state)
        core(colour)
            .frame(width: size, height: size)
            .background(halo(colour))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func core(_ colour: Color) -> some View {
        if state == .idle || state == .ended {
            Circle().strokeBorder(colour, lineWidth: max(1.2, size * 0.22))
        } else {
            Circle().fill(colour)
                .shadow(color: colour.opacity(settings.showGlow ? 0.7 : 0), radius: size * 0.45)
        }
    }

    @ViewBuilder
    private func halo(_ colour: Color) -> some View {
        if state.needsAttention {
            // Two rings half a beat apart: reads as "ping, ping".
            PerchClock(fps: 24) { time in
                ZStack {
                    ring(colour, progress: phase(time, period: 1.3, offset: 0.3))
                    ring(colour, progress: phase(time, period: 1.3, offset: 0.8))
                }
            }
        } else if state.isBusy {
            PerchClock(fps: 20) { time in
                ring(colour, progress: phase(time, period: 1.8, offset: 0.35))
            }
        }
    }

    /// One expanding, fading ring. `progress` runs 0 → 1.
    private func ring(_ colour: Color, progress: Double) -> some View {
        Circle()
            .stroke(colour.opacity(0.6 * (1 - progress)), lineWidth: max(1, size * 0.16))
            .frame(width: size, height: size)
            .scaleEffect(1 + 1.4 * progress)
    }

    /// Where we are in a repeating cycle, 0..<1. The offset makes time 0 a good-looking frame.
    private func phase(_ time: TimeInterval, period: Double, offset: Double) -> Double {
        (time / period + offset).truncatingRemainder(dividingBy: 1)
    }
}
