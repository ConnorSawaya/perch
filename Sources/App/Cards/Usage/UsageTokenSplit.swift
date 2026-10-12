// UsageTokenSplit.swift — today's tokens: the total, what it roughly cost, and (for one agent)
// how it splits into the four kinds of token.
//
//   5.9M                                              $7.85
//   tokens today · 310 messages                 estimated cost
//   ▰▰▱▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱
//   ■ Input 180K   ■ Output 64K   ■ Cache write 420K   ■ Cache read 5.2M
//
// The four kinds share one colour at four strengths (strongest = input, faintest = cache read)
// rather than four different colours: it stays readable in every theme, including the grey one,
// and the legend names each part so nothing depends on telling colours apart.
// The cost is hidden when "Show cost estimates" is off, or when no price is known.
// The "All" view shows only the two big numbers (`showsKinds: false`).

import SwiftUI

struct UsageTokenSplit: View {
    let totals: TokenTotals
    let tint: Color
    /// Draw the bar and legend of the four kinds of token under the big numbers.
    var showsKinds = true

    @EnvironmentObject private var settings: AppSettings

    private struct Part: Identifiable {
        let name: String
        let help: String
        let value: Int
        let strength: Double
        var id: String { name }
    }

    private var parts: [Part] {
        [
            Part(name: "Input", help: "What you and your files sent to the model", value: totals.input, strength: 1),
            Part(name: "Output", help: "What the model wrote back", value: totals.output, strength: 0.68),
            Part(name: "Cache write", help: "Context saved so later turns can reuse it cheaply", value: totals.cacheWrite, strength: 0.4),
            Part(name: "Cache read", help: "Saved context read back (the cheapest kind)", value: totals.cacheRead, strength: 0.2),
        ]
    }

    var body: some View {
        let theme = Theme.current(settings)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top) {
                hero(PerchFormat.count(totals.total), caption: caption, theme, alignment: .leading)
                Spacer(minLength: Theme.Spacing.l)
                // No price is known for some models; "$0.00" would then be wrong, so say nothing.
                if settings.showCostEstimates, totals.costUSD > 0 {
                    hero(PerchFormat.cost(totals.costUSD), caption: "estimated cost", theme, alignment: .trailing)
                        .help("Worked out from list prices. It is an estimate, not a bill.")
                }
            }
            if showsKinds, totals.total > 0 {
                bar
                legend(theme)
            }
        }
    }

    private var caption: String {
        totals.messages > 0 ? "tokens today · \(CardsWording.counted(totals.messages, "message"))" : "tokens today"
    }

    private func hero(_ value: String, caption: String, _ theme: Theme, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(value)
                .font(theme.font(.display))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
            Text(caption)
                .font(theme.font(.caption))
                .foregroundStyle(theme.textSecondary)
        }
        .lineLimit(1)
    }

    /// One bar cut into four parts, with a gap between parts. Tiny parts keep a visible sliver.
    private var bar: some View {
        let parts = self.parts
        let tint = self.tint
        return Canvas { context, size in
            let shown = parts.filter { $0.value > 0 }
            let gap: CGFloat = 2
            let minimum: CGFloat = 4
            let room = size.width - gap * CGFloat(max(shown.count - 1, 0))
            let whole = Double(shown.reduce(0) { $0 + $1.value })
            guard room > 0, whole > 0 else { return }
            // Give every part its sliver first, then share what is left by size.
            let spare = max(room - minimum * CGFloat(shown.count), 0)
            var x: CGFloat = 0
            for part in shown {
                let width = minimum + spare * CGFloat(Double(part.value) / whole)
                let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(tint.opacity(part.strength)))
                x += width + gap
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }

    private func legend(_ theme: Theme) -> some View {
        CardsFlow(spacing: Theme.Spacing.l, lineSpacing: Theme.Spacing.xs) {
            ForEach(parts) { part in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint.opacity(part.strength))
                        .frame(width: 8, height: 8)
                    Text(part.name)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.textSecondary)
                    Text(PerchFormat.count(part.value))
                        .font(theme.font(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary)
                }
                .lineLimit(1)
                .fixedSize()
                .help(part.help)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
