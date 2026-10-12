// CardBackground.swift — what a card looks like, plus the small header that sits above a group.
//
//   VStack { ... }.padding(12).background(CardBackground())
//   VStack { ... }.perchCard(tint: theme.warning)            same thing, padding included
//   SectionHeader("Needs you", count: 2, tint: theme.warning)
//   SectionHeader("Sessions", count: 8) { Button("Sort") { ... } }
//   PerchDivider()                                           a hairline between rows

import SwiftUI

struct CardBackground: View {
    private let tint: Color?
    private let isHovered: Bool
    private let isSelected: Bool
    private let isSunken: Bool
    private let cornerRadius: CGFloat

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - tint: Washes the card with a colour from its leading edge (a state or agent colour).
    ///   - isHovered: Lifts the card slightly; pass your hover state.
    ///   - isSelected: Outlines the card in the accent colour.
    ///   - isSunken: A darker well instead of a raised card (code blocks, diffs, text fields).
    init(tint: Color? = nil, isHovered: Bool = false, isSelected: Bool = false, isSunken: Bool = false,
         cornerRadius: CGFloat = Theme.Radius.card) {
        self.tint = tint
        self.isHovered = isHovered
        self.isSelected = isSelected
        self.isSunken = isSunken
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fill = isSunken ? theme.surfaceSunken : (isHovered ? theme.surfaceHover : theme.surface)
        ZStack {
            shape.fill(fill)
            if let tint {
                shape.fill(LinearGradient(colors: [tint.opacity(isHovered ? 0.07 : 0.04), tint.opacity(0.0)],
                                          startPoint: .leading, endPoint: .trailing))
            }
            shape.strokeBorder(outline(theme), lineWidth: 1)
        }
    }

    /// Lit from above: the top edge is a little brighter than the bottom one.
    private func outline(_ theme: Theme) -> LinearGradient {
        if isSelected {
            return LinearGradient(colors: [theme.accent.opacity(0.9), theme.accentAlt.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        if let tint {
            return LinearGradient(colors: [tint.opacity(0.22), theme.stroke], startPoint: .leading, endPoint: .trailing)
        }
        let top = isSunken ? theme.stroke.opacity(0.6) : (isHovered ? theme.strokeStrong : theme.stroke)
        return LinearGradient(colors: [top, theme.stroke.opacity(0.45)], startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// Pads the content and puts it on a card.
    func perchCard(tint: Color? = nil, isHovered: Bool = false, isSelected: Bool = false,
                   padding: CGFloat = Theme.Spacing.l, cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        self.padding(padding)
            .background(CardBackground(tint: tint, isHovered: isHovered, isSelected: isSelected, cornerRadius: cornerRadius))
    }
}

/// A small capitalised title above a group of cards, with an optional count and trailing control.
struct SectionHeader<Trailing: View>: View {
    private let title: String
    private let count: Int?
    private let systemImage: String?
    private let tint: Color?
    private let trailing: Trailing

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - count: Shown in a small bubble after the title.
    ///   - tint: Colours the title and the bubble (e.g. the warning colour for "Needs you").
    ///   - trailing: Anything that should sit at the right end: a button, a hint, a chip.
    init(_ title: String, count: Int? = nil, systemImage: String? = nil, tint: Color? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.count = count
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        let theme = Theme.current(settings)
        HStack(spacing: Theme.Spacing.s) {
            Text(title)
                .font(theme.font(.caption))
                .foregroundStyle(tint ?? theme.textTertiary)
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .font(theme.font(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? theme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill((tint ?? Color.white).opacity(tint == nil ? 0.08 : 0.16)))
            }
            Spacer(minLength: Theme.Spacing.m)
            trailing
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil, systemImage: String? = nil, tint: Color? = nil) {
        self.init(title, count: count, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

/// A one-pixel line in the theme's stroke colour.
struct PerchDivider: View {
    @EnvironmentObject private var settings: AppSettings

    init() {}

    var body: some View {
        Rectangle().fill(Theme.current(settings).stroke).frame(height: 1)
    }
}
