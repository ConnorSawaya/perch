// ParticleBurst.swift — a one-off puff of confetti for "a task just finished".
//
//   .overlay(ParticleBurst(trigger: pulse?.id, triggeredAt: pulse?.at))
//
// It fires once each time `trigger` changes to a new value (and once on appearing, if
// `triggeredAt` is less than a second old — so a burst is not missed when the view shows up
// because of the very event it celebrates). While nothing is firing it draws nothing and costs
// nothing. It does not fire when "Particles" is off or motion is reduced.
//
// The particles are worked out from a seed and the time since the start, so no per-particle
// state is stored: every frame is just "where is particle i after t seconds?".

import SwiftUI

struct ParticleBurst: View {
    enum Style {
        /// Fly out in every direction, then sink. For cards.
        case radial
        /// Spray downwards and outwards. For the pill, which has nothing above it.
        case shower
    }

    private let trigger: UUID?
    private let triggeredAt: Date?
    private let colors: [Color]?
    private let origin: UnitPoint
    private let style: Style
    private let count: Int
    private let frozen: (progress: Double, seed: UInt64)?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var live: LiveBurst?

    private struct LiveBurst: Equatable {
        let seed: UInt64
        let start: Date
    }

    /// Seconds from pop to fully faded.
    private static let duration: TimeInterval = 1.5

    /// - Parameters:
    ///   - trigger: Fires when this changes to a new non-nil value (e.g. `Pulse.id`).
    ///   - triggeredAt: When the trigger happened; lets a freshly shown view catch up on it.
    ///   - colors: Particle colours. Defaults to the theme's success, accent and warning colours.
    ///   - origin: Where in this view the particles start.
    ///   - count: How many particles (clamped to 4...80).
    init(trigger: UUID?, triggeredAt: Date? = nil, colors: [Color]? = nil, origin: UnitPoint = .center,
         style: Style = .radial, count: Int = 28) {
        self.trigger = trigger
        self.triggeredAt = triggeredAt
        self.colors = colors
        self.origin = origin
        self.style = style
        self.count = min(max(count, 4), 80)
        self.frozen = nil
    }

    /// A still frame part-way through a burst (`progress` 0...1), for previews and snapshots.
    init(frozenAt progress: Double, seed: UInt64 = 11, colors: [Color]? = nil, origin: UnitPoint = .center,
         style: Style = .radial, count: Int = 28) {
        self.trigger = nil
        self.triggeredAt = nil
        self.colors = colors
        self.origin = origin
        self.style = style
        self.count = min(max(count, 4), 80)
        self.frozen = (min(max(progress, 0), 1), seed)
    }

    var body: some View {
        ZStack {
            if let frozen {
                canvas(progress: frozen.progress, seed: frozen.seed)
            } else if let live {
                TimelineView(.animation) { timeline in
                    canvas(progress: timeline.date.timeIntervalSince(live.start) / Self.duration, seed: live.seed)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, newValue in
            if newValue != nil { fire() }
        }
        .onAppear {
            if trigger != nil, let triggeredAt, Date().timeIntervalSince(triggeredAt) < 1 { fire() }
        }
        .task(id: live) {
            // Remove the canvas once the burst has faded. A newer burst cancels this wait.
            guard let current = live else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
                if live == current { live = nil }
            } catch {}
        }
    }

    private func fire() {
        guard frozen == nil, settings.showParticles, !settings.prefersCalm(systemReduceMotion) else { return }
        live = LiveBurst(seed: UInt64.random(in: 1...UInt64.max), start: Date())
    }

    private func canvas(progress: Double, seed: UInt64) -> some View {
        let theme = Theme.current(settings)
        let palette = colors ?? [theme.success, theme.accent, theme.accentAlt, theme.warning, .white]
        let style = self.style
        let origin = self.origin
        let count = self.count
        return Canvas { context, size in
            guard progress >= 0, progress < 1, !palette.isEmpty else { return }
            let start = CGPoint(x: size.width * origin.x, y: size.height * origin.y)
            let seconds = progress * Self.duration
            for index in 0..<count {
                var random = SeededRandom(seed: seed &+ UInt64(index) &* 7919)
                let particle = Particle(random: &random, style: style, paletteCount: palette.count)
                let position = particle.position(from: start, seconds: seconds, progress: progress)
                // Pop in quickly, hold, then fade over the last 40%.
                let opacity = min(1, progress / 0.06) * min(1, (1 - progress) / 0.4)
                var layer = context
                layer.opacity = opacity
                layer.translateBy(x: position.x, y: position.y)
                layer.rotate(by: .radians(particle.spin * seconds * 6))
                let colour = palette[particle.colourIndex]
                if particle.isConfetti {
                    let rect = CGRect(x: -particle.size, y: -particle.size * 0.45, width: particle.size * 2, height: particle.size * 0.9)
                    layer.fill(Path(roundedRect: rect, cornerRadius: particle.size * 0.3), with: .color(colour))
                } else {
                    let rect = CGRect(x: -particle.size / 2, y: -particle.size / 2, width: particle.size, height: particle.size)
                    layer.fill(Path(ellipseIn: rect), with: .color(colour))
                }
            }
        }
    }
}

/// One particle's fixed properties, all derived from the random stream.
private struct Particle {
    let direction: CGVector
    let speed: Double
    let size: CGFloat
    let spin: Double
    let colourIndex: Int
    let isConfetti: Bool

    init(random: inout SeededRandom, style: ParticleBurst.Style, paletteCount: Int) {
        let angle: Double
        switch style {
        case .radial: angle = random.next() * 2 * .pi
        // 15°...165° in screen coordinates points downwards, fanning left and right.
        case .shower: angle = (15 + random.next() * 150) * .pi / 180
        }
        direction = CGVector(dx: cos(angle), dy: sin(angle))
        speed = 46 + random.next() * 84
        size = 2.2 + CGFloat(random.next()) * 2.6
        spin = random.next() * 2 - 1
        colourIndex = min(paletteCount - 1, Int(random.next() * Double(paletteCount)))
        isConfetti = random.next() < 0.45
    }

    /// Fast at first, slowing like something thrown through air, with gravity pulling it down.
    func position(from start: CGPoint, seconds: Double, progress: Double) -> CGPoint {
        let travelled = speed * (1 - pow(1 - progress, 3))
        return CGPoint(x: start.x + direction.dx * travelled,
                       y: start.y + direction.dy * travelled + 34 * seconds * seconds)
    }
}

/// A tiny repeatable random-number generator (SplitMix64). Same seed, same particles.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// The next number in 0..<1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
