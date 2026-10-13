// PipelineDiagram.swift — the picture at the top of "How it works": the five stops an event
// passes on its way from a coding agent to the notch, and the way an answer travels back.
//
//   your agent → hook → perch-hook → Perch → the notch
//        ◄──────────── your answer goes back ───────────
//
// It is live: whenever a new line appears in the activity log, a dot of light runs along the
// diagram (left to right for something an agent sent, right to left for an answer) and each stop
// lights up as the dot passes. With "Reduce motion" on, the stops simply glow for a moment.
//
// The view only redraws every frame while a dot is travelling; the rest of the time it is still.

import SwiftUI

/// One run of the light: which activity line caused it and which way it travels.
struct PipelineSignal: Equatable {
    var id: UUID
    /// False = from the agent to the notch. True = an answer going back to the agent.
    var isReply: Bool
    var startedAt: Date
}

struct PipelineDiagram: View {
    private let signal: PipelineSignal?
    private let frozenProgress: Double?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The signal currently being played; nil while the diagram is at rest.
    @State private var playing: PipelineSignal?

    /// Seconds the dot takes to cross the diagram.
    static let travelTime: TimeInterval = 1.5

    /// - Parameters:
    ///   - signal: Pass a new value (a new `id`) to send a dot along the diagram.
    ///   - frozenProgress: Draws the dot stopped at this point (0...1) of `signal`'s journey and
    ///     never animates. Used to picture a moment of the animation in snapshots.
    init(signal: PipelineSignal?, frozenProgress: Double? = nil) {
        self.signal = signal
        self.frozenProgress = frozenProgress
    }

    var body: some View {
        let calm = settings.prefersCalm(systemReduceMotion)
        Group {
            if let frozenProgress, let signal {
                PipelineDrawing(progress: min(max(frozenProgress, 0), 1), isReply: signal.isReply, showsDot: true)
            } else if let playing, calm {
                // No travelling dot: every stop on the route glows together, then fades.
                PipelineDrawing(progress: nil, isReply: playing.isReply, showsDot: false, glowAll: true)
            } else if let playing {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(playing.startedAt)
                    PipelineDrawing(progress: min(max(elapsed / Self.travelTime, 0), 1), isReply: playing.isReply, showsDot: true)
                }
            } else {
                PipelineDrawing(progress: nil, isReply: false, showsDot: false)
            }
        }
        .animation(PerchMotion.fade(reduce: calm), value: playing)
        .onChange(of: signal) { _, new in
            guard frozenProgress == nil, let new else { return }
            playing = new
        }
        .task(id: playing) {
            // Go back to rest (and stop redrawing) once the dot has arrived.
            guard playing != nil else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64((Self.travelTime + 0.35) * 1_000_000_000))
                playing = nil
            } catch {}
        }
        .accessibilityElement()
        .accessibilityLabel("Diagram: your coding agent runs a hook, the hook starts the perch-hook helper, the helper "
            + "passes the event to Perch, Perch shows it in the notch, and your answer travels back the same way.")
    }
}

// MARK: - The stops

/// One stop on the route.
private struct PipelineStage: Identifiable {
    let id: Int
    let title: String
    let caption: String
    let systemImage: String

    static let all: [PipelineStage] = [
        PipelineStage(id: 0, title: "Your agent", caption: "Claude, Codex\u{2026}", systemImage: "terminal.fill"),
        PipelineStage(id: 1, title: "Hook", caption: "\u{201C}tell Perch\u{201D}", systemImage: "link"),
        PipelineStage(id: 2, title: "perch-hook", caption: "tiny messenger", systemImage: "paperplane.fill"),
        PipelineStage(id: 3, title: "Perch", caption: "makes sense of it", systemImage: "gearshape.2.fill"),
        PipelineStage(id: 4, title: "The notch", caption: "shows it to you", systemImage: "menubar.rectangle"),
    ]
}

// MARK: - Drawing

/// The diagram at one instant. `progress` is where the dot is (nil = at rest).
private struct PipelineDrawing: View {
    let progress: Double?
    let isReply: Bool
    let showsDot: Bool
    var glowAll = false

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let stages = PipelineStage.all
        let tile = theme.scaled(46)
        let lane: CGFloat = 20

        VStack(spacing: Theme.Spacing.xs) {
            // Lane 1: agent → notch.
            HStack(alignment: .top, spacing: 0) {
                ForEach(stages) { stage in
                    stageView(stage, theme: theme, tile: tile)
                        .frame(maxWidth: .infinity)
                }
            }
            .background(alignment: .top) {
                PipelineLane(count: stages.count, progress: isReply ? nil : progress, pointsLeft: false, dashed: false,
                             capsEnds: false, colour: theme.accent, restColour: theme.strokeStrong, showsDot: showsDot)
                    .frame(height: tile)
            }
            // Lane 2: the answer going back.
            PipelineLane(count: stages.count, progress: isReply ? progress.map { 1 - $0 } : nil, pointsLeft: true, dashed: true,
                         capsEnds: true, colour: theme.success, restColour: theme.strokeStrong, showsDot: showsDot)
                .frame(height: lane)
            Text("Your answer goes back the same way, when the agent is waiting for one")
                .font(theme.font(.caption))
                .foregroundStyle(isReply && (progress != nil || glowAll) ? theme.success : theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func stageView(_ stage: PipelineStage, theme: Theme, tile: CGFloat) -> some View {
        let lit = litAmount(stage.id, count: PipelineStage.all.count)
        let colour = isReply ? theme.success : theme.accent
        let shape = RoundedRectangle(cornerRadius: tile * 0.3, style: .continuous)
        return VStack(spacing: Theme.Spacing.s) {
            Image(systemName: stage.systemImage)
                .font(.system(size: tile * 0.38, weight: .semibold))
                .foregroundStyle(lit > 0.05 ? AnyShapeStyle(colour) : AnyShapeStyle(theme.textSecondary))
                .frame(width: tile, height: tile)
                .background(shape.fill(colour.opacity(0.24 * lit)).background(shape.fill(theme.surfaceHover)))
                .overlay(shape.strokeBorder(lit > 0.05 ? colour.opacity(0.35 + 0.55 * lit) : theme.strokeStrong, lineWidth: 1))
                .scaleEffect(1 + 0.06 * lit)
            VStack(spacing: 1) {
                Text(stage.title)
                    .font(stage.id == 2 ? theme.font(size: 11.5, weight: .semibold, design: .monospaced) : theme.font(.label))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                // Two lines allowed, so the captions never run into each other at large text sizes.
                Text(stage.caption)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.xs)
        }
    }

    /// How brightly a stop is lit, 0...1: brightest when the dot is on it.
    private func litAmount(_ index: Int, count: Int) -> Double {
        if glowAll { return 0.8 }
        guard let progress, count > 1 else { return 0 }
        let position = isReply ? 1 - progress : progress
        let distance = abs(position - Double(index) / Double(count - 1))
        return max(0, 1 - distance * Double(count - 1) * 1.15)
    }
}

/// A horizontal line through the centres of `count` equal columns, with an arrowhead at the
/// far end and (optionally) a dot of light somewhere along it.
private struct PipelineLane: View {
    let count: Int
    /// Position of the dot along the line, 0 (first column) ... 1 (last column). Nil = no dot.
    let progress: Double?
    let pointsLeft: Bool
    let dashed: Bool
    /// Draws a dot where the line starts and an arrowhead where it ends. The upper lane does not
    /// need them, because its ends are tucked behind the first and last stop.
    let capsEnds: Bool
    let colour: Color
    let restColour: Color
    let showsDot: Bool

    var body: some View {
        Canvas { context, size in
            guard count > 1, size.width > 1 else { return }
            let column = size.width / CGFloat(count)
            let startX = column / 2
            let endX = size.width - column / 2
            let y = size.height / 2

            var line = Path()
            line.move(to: CGPoint(x: startX, y: y))
            line.addLine(to: CGPoint(x: endX, y: y))
            context.stroke(line, with: .color(restColour),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dashed ? [3, 5] : []))

            // Small arrowheads between the columns show which way things flow.
            for gap in 0..<(count - 1) {
                let x = column * CGFloat(gap + 1)
                let direction: CGFloat = pointsLeft ? -1 : 1
                var head = Path()
                head.move(to: CGPoint(x: x - 3.5 * direction, y: y - 4))
                head.addLine(to: CGPoint(x: x + 1.5 * direction, y: y))
                head.addLine(to: CGPoint(x: x - 3.5 * direction, y: y + 4))
                context.stroke(head, with: .color(restColour), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }

            if capsEnds {
                let from = pointsLeft ? endX : startX
                let to = pointsLeft ? startX : endX
                let direction: CGFloat = pointsLeft ? -1 : 1
                context.fill(Path(ellipseIn: CGRect(x: from - 3, y: y - 3, width: 6, height: 6)), with: .color(restColour))
                var tip = Path()
                tip.move(to: CGPoint(x: to - 5 * direction, y: y - 5))
                tip.addLine(to: CGPoint(x: to + 1 * direction, y: y))
                tip.addLine(to: CGPoint(x: to - 5 * direction, y: y + 5))
                context.stroke(tip, with: .color(restColour), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }

            guard showsDot, let progress else { return }
            let x = startX + (endX - startX) * CGFloat(min(max(progress, 0), 1))
            // A short bright tail behind the dot, pointing back to where it came from.
            let tail: CGFloat = pointsLeft ? 34 : -34
            var trail = Path()
            trail.move(to: CGPoint(x: min(max(x + tail, startX), endX), y: y))
            trail.addLine(to: CGPoint(x: x, y: y))
            context.stroke(trail, with: .color(colour.opacity(0.45)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: x - 9, y: y - 9, width: 18, height: 18)), with: .color(colour.opacity(0.22)))
            context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(colour))
            context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(.white))
        }
    }
}
