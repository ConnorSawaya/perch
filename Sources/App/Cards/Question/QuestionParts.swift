// QuestionParts.swift — the pieces a question card is built from.
//
//   QuestionSteps       thin bars across the card: one per question, lit up to where you are
//   QuestionOptionRow   one choice: a radio dot or checkbox, the label, its explanation, a key hint

import SwiftUI

/// One bar per question. Answered ones are filled, the one on show is brightest.
struct QuestionSteps: View {
    let count: Int
    let current: Int
    let answered: Set<Int>
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(count, 0), id: \.self) { index in
                Capsule()
                    .fill(index == current ? tint : (answered.contains(index) ? tint.opacity(0.45) : Color.white.opacity(0.12)))
                    .frame(height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Question \(current + 1) of \(count)")
    }
}

struct QuestionOptionRow: View {
    enum Marker {
        /// Pick one.
        case radio
        /// Pick any.
        case checkbox
        /// The "Other…" row before it is opened.
        case pencil
    }

    private let label: String
    private let detail: String?
    private let marker: Marker
    private let isSelected: Bool
    private let tint: Color
    private let keys: [String]
    private let action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.cardsHintsDimmed) private var hintsDimmed
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var hovering = false

    /// - Parameters:
    ///   - detail: A short explanation shown under the label.
    ///   - keys: The shortcut that picks this row ("⌘", "1"); empty when there is none.
    init(label: String, detail: String? = nil, marker: Marker, isSelected: Bool, tint: Color, keys: [String] = [],
         action: @escaping () -> Void) {
        self.label = label
        self.detail = detail
        self.marker = marker
        self.isSelected = isSelected
        self.tint = tint
        self.keys = keys
        self.action = action
    }

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                QuestionMarkerView(marker: marker, isSelected: isSelected, tint: tint)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - theme.scaled(2.5) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(theme.font(.label))
                        .foregroundStyle(marker == .pencil && !hovering ? theme.textSecondary : theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = CardsWording.tidy(detail) {
                        Text(detail)
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Spacing.m)
                if settings.shortcutsEnabled, !keys.isEmpty {
                    KeyHint(keys: keys).opacity(hintsDimmed ? 0.55 : 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(shape.fill(isSelected ? tint.opacity(hovering ? 0.22 : 0.16) : Color.white.opacity(hovering ? 0.08 : 0.035)))
            .overlay(shape.strokeBorder(isSelected ? tint.opacity(0.6) : (hovering ? theme.strokeStrong : theme.stroke), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(PerchMotion.fade(reduce: settings.prefersCalm(systemReduceMotion)), value: isSelected)
        .accessibilityLabel(detail.map { "\(label). \($0)" } ?? label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The radio dot / checkbox / pencil at the start of an option row.
struct QuestionMarkerView: View {
    let marker: QuestionOptionRow.Marker
    let isSelected: Bool
    let tint: Color

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let side = theme.scaled(14)
        Group {
            switch marker {
            case .radio:
                ZStack {
                    Circle().strokeBorder(isSelected ? tint : theme.textTertiary, lineWidth: 1.5)
                    if isSelected { Circle().fill(tint).padding(side * 0.26) }
                }
            case .checkbox:
                let box = RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                ZStack {
                    if isSelected {
                        box.fill(tint)
                        Image(systemName: "checkmark")
                            .font(.system(size: side * 0.6, weight: .heavy))
                            .foregroundStyle(theme.island)
                    } else {
                        box.strokeBorder(theme.textTertiary, lineWidth: 1.5)
                    }
                }
            case .pencil:
                Image(systemName: "square.and.pencil")
                    .font(.system(size: side * 0.82, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
