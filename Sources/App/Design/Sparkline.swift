// Sparkline.swift — a tiny chart with no axes: a feel for "how has this been going".
//
//   Sparkline(values: toolDurations)                               bars, one per value
//   Sparkline(values: tokensPerDay, style: .line).frame(width: 90) smooth line with a soft fill
//
// Bars: each value is one bar, newest on the right; the view is exactly as wide as its bars.
// Line: stretches to the width it is given. Give either one a height with `.frame(height:)`.

import SwiftUI

struct Sparkline: View {
    enum Style { case bars, line }

    private let values: [Double]
    private let style: Style
    private let tint: Color?
    private let colors: [Color?]
    private let barWidth: CGFloat
    private let spacing: CGFloat

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - values: Oldest first. Negative and non-finite numbers count as zero.
    ///   - tint: Colour of the bars or line. Defaults to the theme accent.
    ///   - colors: Bars only — a colour per value (nil entries use `tint`), e.g. red for failures.
    init(values: [Double], style: Style = .bars, tint: Color? = nil, colors: [Color?] = [],
         barWidth: CGFloat = 3, spacing: CGFloat = 1.5) {
        self.values = values.map { $0.isFinite ? max(0, $0) : 0 }
        self.style = style
        self.tint = tint
        self.colors = colors
        self.barWidth = barWidth
        self.spacing = spacing
    }

    var body: some View {
        let theme = Theme.current(settings)
        let colour = tint ?? theme.accent
        let peak = max(values.max() ?? 0, 0.0001)
        let series = values
        let perBar = colors
        let style = self.style
        let barWidth = self.barWidth
        let spacing = self.spacing

        Canvas { context, size in
            guard !series.isEmpty else { return }
            switch style {
            case .bars:
                for (index, value) in series.enumerated() {
                    // Never shorter than the bar is wide, so a zero still shows as a dot.
                    let height = max(barWidth, CGFloat(value / peak) * size.height)
                    let rect = CGRect(x: CGFloat(index) * (barWidth + spacing), y: size.height - height, width: barWidth, height: height)
                    let fill = (index < perBar.count ? perBar[index] : nil) ?? colour
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(fill))
                }
            case .line:
                let inset: CGFloat = 1.5
                let step = series.count > 1 ? (size.width - inset * 2) / CGFloat(series.count - 1) : 0
                let points = series.enumerated().map { index, value in
                    CGPoint(x: inset + CGFloat(index) * step,
                            y: inset + (1 - CGFloat(value / peak)) * (size.height - inset * 2))
                }
                var line = Path()
                line.addLines(points)
                if let first = points.first, let last = points.last {
                    var area = line
                    area.addLine(to: CGPoint(x: last.x, y: size.height))
                    area.addLine(to: CGPoint(x: first.x, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(Gradient(colors: [colour.opacity(0.28), colour.opacity(0)]),
                                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    context.stroke(line, with: .color(colour), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    context.fill(Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)), with: .color(colour))
                }
            }
        }
        .frame(width: style == .bars ? barsWidth : nil)
        .accessibilityHidden(true)
    }

    private var barsWidth: CGFloat {
        values.isEmpty ? 0 : CGFloat(values.count) * (barWidth + spacing) - spacing
    }
}
