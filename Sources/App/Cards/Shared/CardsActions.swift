// CardsActions.swift — how the buttons at the bottom of a request card are laid out.
//
//   [ Allow ⌘Y ] [ Deny ⌘N ] [ Always allow… ]          Deny with a note…   Answer in terminal ⌘T
//   └──────────── main choices ─────────────┘          └────────── quieter extras ───────────┘
//
// On a wide panel everything sits on one line, main choices on the left and extras on the right.
// When that does not fit (a narrow panel, large text) the extras drop to a second line, and if
// even one group is too wide for a line its buttons wrap — nothing is ever squeezed until its
// label turns into "…".
//
//   CardsActionRow { main buttons } extra: { quieter buttons }
//   CardsFlow { any views }            lays views out left to right, wrapping like words in a paragraph

import SwiftUI

struct CardsActionRow<Main: View, Extra: View>: View {
    private let main: Main
    private let extra: Extra

    init(@ViewBuilder main: () -> Main, @ViewBuilder extra: () -> Extra) {
        self.main = main()
        self.extra = extra()
    }

    /// How far a small quiet button's content sits inside its own edge.
    private static var quietInset: CGFloat { 9 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.m) {
                main
                Spacer(minLength: Theme.Spacing.l)
                // Quiet buttons have no background, so their content stops short of their edge;
                // push the group out so it lines up with the boxes above it.
                HStack(spacing: Theme.Spacing.xxs) { extra }
                    .padding(.trailing, -Self.quietInset)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                CardsFlow(spacing: Theme.Spacing.m) { main }
                // The same optical correction on the left when the extras get their own line.
                CardsFlow(spacing: Theme.Spacing.xxs) { extra }
                    .padding(.leading, -Self.quietInset)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension CardsActionRow where Extra == EmptyView {
    init(@ViewBuilder main: () -> Main) {
        self.init(main: main) { EmptyView() }
    }
}

/// Lays its children out in rows, starting a new row whenever the next child does not fit.
/// Children in a row are centred on each other vertically (a small button next to a regular one).
struct CardsFlow: Layout {
    var spacing: CGFloat = Theme.Spacing.m
    var lineSpacing: CGFloat = Theme.Spacing.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (index, frame) in arrangement.frames.enumerated() where index < subviews.count {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    /// Where every child goes, in the layout's own coordinates, and the total size that takes.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var rowStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        /// Centres the finished row's children on its tallest one.
        func closeRow() {
            for index in rowStart..<frames.count {
                frames[index].origin.y = y + (rowHeight - frames[index].height) / 2
            }
        }

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            // A child wider than a whole row gets the row; its own layout decides how to cope.
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                closeRow()
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
                rowStart = frames.count
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x + size.width)
            x += size.width + spacing
        }
        closeRow()
        return (frames, CGSize(width: widest, height: y + rowHeight))
    }
}

// MARK: - Dimming the shortcut hints of cards that are not in focus

private struct CardsHintsDimmedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a request card that keyboard shortcuts would NOT act on right now (another
    /// card has the focus). Its key hints are drawn faintly, so "⌘Y" never points at the wrong card.
    var cardsHintsDimmed: Bool {
        get { self[CardsHintsDimmedKey.self] }
        set { self[CardsHintsDimmedKey.self] = newValue }
    }
}
