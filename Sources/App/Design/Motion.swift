// Motion.swift — one place that decides whether and how things move.
//
// Two tools live here:
//   • PerchMotion — the handful of springs and fades the app uses, each with a calm version for
//     people who turned on "Reduce motion" (in Perch's settings or in macOS).
//   • PerchClock  — a tiny wrapper around TimelineView for looping animations (mascot, glow,
//     shimmer). It hands the drawing code "seconds since I appeared", stops completely when it
//     is not running, and stands still when motion is reduced. Wrap only the small view that
//     actually moves so the rest of the panel is not redrawn every frame.

import SwiftUI

enum PerchMotion {
    /// The pill growing into the panel and back.
    static func morph(reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.8)
    }

    /// Small state changes: hover highlights, a tab indicator sliding, a card appearing.
    static func quick(reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.08) : .spring(response: 0.28, dampingFraction: 0.84)
    }

    /// Plain fades (colours, opacity).
    static func fade(reduce: Bool) -> Animation { .easeOut(duration: reduce ? 0.08 : 0.18) }
}

extension AppSettings {
    /// True when either Perch's own "Reduce motion" toggle or the macOS accessibility setting is on.
    /// Usage: `@Environment(\.accessibilityReduceMotion) var systemReduceMotion`, then
    /// `settings.prefersCalm(systemReduceMotion)`.
    func prefersCalm(_ systemReduceMotion: Bool) -> Bool { reduceMotion || systemReduceMotion }
}

/// Drives a looping animation. `content` receives the seconds elapsed since the view appeared;
/// when the clock is not running (or motion is reduced) it receives 0 once and nothing is redrawn.
/// Draw so that time 0 already looks right — that is also the frame snapshots capture.
struct PerchClock<Content: View>: View {
    private let fps: Double
    private let isRunning: Bool
    private let content: (TimeInterval) -> Content

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var start = Date()

    /// - Parameters:
    ///   - fps: Upper limit on redraws per second. Slow effects look fine at 15–20.
    ///   - isRunning: Pass false to freeze (for example when the session is idle).
    init(fps: Double = 30, isRunning: Bool = true, @ViewBuilder content: @escaping (TimeInterval) -> Content) {
        self.fps = max(1, fps)
        self.isRunning = isRunning
        self.content = content
    }

    var body: some View {
        if isRunning && !settings.prefersCalm(systemReduceMotion) {
            TimelineView(.animation(minimumInterval: 1 / fps)) { timeline in
                content(max(0, timeline.date.timeIntervalSince(start)))
            }
        } else {
            content(0)
        }
    }
}
