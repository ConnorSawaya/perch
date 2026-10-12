// ActivityBars.swift — three little bars that bounce like a music equaliser: "work in progress".
//
//   PerchActivityBars(tint: theme.info)                 bouncing
//   PerchActivityBars(tint: theme.info, isActive: false) resting
//
// Used next to the count of busy sessions in the pill and the panel header.

import SwiftUI

struct PerchActivityBars: View {
    private let tint: Color?
    private let size: CGFloat
    private let isActive: Bool

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - size: Height of the tallest bar; the view is roughly as wide as it is tall.
    ///   - isActive: False shows three short, still bars.
    init(tint: Color? = nil, size: CGFloat = 10, isActive: Bool = true) {
        self.tint = tint
        self.size = size
        self.isActive = isActive
    }

    var body: some View {
        let colour = tint ?? Theme.current(settings).accent
        let barWidth = max(1.5, size * 0.2)
        let gap = max(1, size * 0.14)
        let active = isActive
        PerchClock(fps: 20, isRunning: isActive) { time in
            Canvas { context, canvas in
                for index in 0..<3 {
                    // Each bar bounces on its own rhythm; the offsets make the frozen frame uneven.
                    let wave = active ? 0.5 + 0.5 * sin(time * (5.2 + Double(index) * 1.1) + Double(index) * 1.9 + 0.6) : 0.15
                    let height = max(barWidth, canvas.height * CGFloat(0.3 + 0.7 * wave))
                    let rect = CGRect(x: CGFloat(index) * (barWidth + gap), y: canvas.height - height, width: barWidth, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(colour))
                }
            }
        }
        .frame(width: barWidth * 3 + gap * 2, height: size)
        .accessibilityHidden(true)
    }
}
