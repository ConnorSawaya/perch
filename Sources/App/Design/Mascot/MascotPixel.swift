// MascotPixel.swift — the "pixel" mascot: a tiny pixel-art bird that perches by the notch.
//
// The bird is Perch's own drawing, stored below as rows of letters on a 12 × 12 grid:
//   B body   S shaded body (wing, tail)   W pale belly   E eye
//   K beak   F feet   H sparkle   A alert mark   . nothing
//
// How each mood looks:
//   idle       grey, eyes closed, asleep
//   busy       hops and flaps its wing a few times a second, blinking now and then
//   attention  flaps quickly with a blinking "!" beside it
//   done       stands proud with sparkles
//   failed     slumped, beak down, eye shut tight
// Pixel art wants few frames, so this redraws only 8 times a second while animating.

import SwiftUI

struct MascotPixel: View {
    let mood: MascotMood
    let colors: MascotColors

    var body: some View {
        PerchClock(fps: 8, isRunning: mood.isAnimated) { time in
            Canvas { context, size in
                draw(&context, size: size, time: time)
            }
        }
    }

    // MARK: Sprites

    private static let grid = 12

    private static let standing = [
        "............",
        "....BBBB....",
        "...BBBBBB...",
        "..BBBBBEBB..",
        "..BBBBBBBKK.",
        ".SBBBBBBBB..",
        "SSBSSSBWWB..",
        ".SBBSSWWWB..",
        "..BBBWWWWB..",
        "...BBBBBB...",
        "....F..F....",
        "...FF.FF....",
    ]

    private static let flapping = [
        "............",
        "....BBBB....",
        "...BBBBBB...",
        "..BBBBBEBB..",
        ".SBSSBBBBKK.",
        "SSBSSSBBBB..",
        ".SBBSBBWWB..",
        "..BBBBWWWB..",
        "..BBBWWWWB..",
        "...BBBBBB...",
        "....F..F....",
        "...FF.FF....",
    ]

    private static let slumped = [
        "............",
        "............",
        "....BBBB....",
        "...BBBBBB...",
        "..BBBBEEBB..",
        "..BBBBBBBK..",
        ".SBBBBBBBK..",
        "SSBSSSBWWB..",
        ".SBBSSWWWB..",
        "..BBBWWWWB..",
        "...BBBBBB...",
        "...FF.FF....",
    ]

    /// Extra pixels laid over the bird: (column, row, letter).
    private static let alertMark: [(Int, Int, Character)] = [(0, 0, "A"), (0, 1, "A"), (0, 3, "A")]
    private static let sparkles: [(Int, Int, Character)] = [(1, 0, "H"), (0, 1, "H"), (1, 1, "H"), (2, 1, "H"), (1, 2, "H"), (11, 7, "H"), (10, 1, "H")]

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        // Whole half-points per pixel keep the edges crisp on Retina screens.
        let cell = max(0.5, (min(size.width, size.height) / CGFloat(Self.grid) * 2).rounded(.down) / 2)
        let side = cell * CGFloat(Self.grid)
        let origin = CGPoint(x: ((size.width - side) / 2 * 2).rounded() / 2, y: ((size.height - side) / 2 * 2).rounded() / 2)
        let pose = currentPose(at: time)

        func paint(_ column: Int, _ row: Int, _ letter: Character) {
            guard let colour = colour(for: letter) else { return }
            let rect = CGRect(x: origin.x + CGFloat(column) * cell, y: origin.y + CGFloat(row + pose.lift) * cell, width: cell, height: cell)
            context.fill(Path(rect), with: .color(colour))
            if letter == "S" {
                // Shade = body colour with a veil of the dark ink over it.
                context.fill(Path(rect), with: .color(colors.ink.opacity(0.32)))
            }
        }

        for (row, line) in pose.sprite.enumerated() {
            for (column, letter) in line.enumerated() {
                // A closed eye is drawn as shaded body.
                paint(column, row, letter == "E" && pose.eyesClosed ? "S" : letter)
            }
        }
        for (column, row, letter) in pose.extras {
            paint(column, row - pose.lift, letter)
        }
    }

    private struct Pose {
        var sprite: [String]
        /// Rows the bird is shifted by (negative = hopping up).
        var lift = 0
        var eyesClosed = false
        var extras: [(Int, Int, Character)] = []
    }

    private func currentPose(at time: TimeInterval) -> Pose {
        switch mood {
        case .idle:
            return Pose(sprite: Self.standing, eyesClosed: true)
        case .busy:
            // Four steps a second; step 1 is the frozen frame, so it shows the bird mid-hop.
            let step = Int(time * 4) + 1
            let blinking = step % 14 == 0
            return step % 2 == 1
                ? Pose(sprite: Self.flapping, lift: -1, eyesClosed: blinking)
                : Pose(sprite: Self.standing, eyesClosed: blinking)
        case .attention:
            let step = Int(time * 6)
            return Pose(sprite: step % 2 == 0 ? Self.flapping : Self.standing,
                        extras: step % 6 < 4 ? Self.alertMark : [])
        case .done:
            return Pose(sprite: Self.standing, extras: Self.sparkles)
        case .failed:
            return Pose(sprite: Self.slumped)
        }
    }

    private func colour(for letter: Character) -> Color? {
        switch letter {
        case "B", "S": return colors.primary
        case "W": return Color.white.opacity(0.88)
        case "E": return colors.ink
        case "K", "F", "A": return colors.secondary
        case "H": return Color.white
        default: return nil
        }
    }
}
