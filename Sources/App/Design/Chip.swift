// Chip.swift — small labels: a rounded "chip" for facts and states, and a key cap for shortcuts.
//
//   Chip("main", systemImage: "arrow.triangle.branch")            quiet fact
//   Chip("Needs approval", tint: theme.warning)                   coloured state
//   Chip("3", tint: theme.warning, style: .solid)                 loud count
//   KeyHint("⌘", "Y")                                             keyboard shortcut

import SwiftUI

struct Chip: View {
    enum Style {
        /// Tinted background with tinted text. The default for states.
        case tinted
        /// Filled with the tint; for counts that must be seen.
        case solid
        /// Just an outline.
        case outline
        /// Neutral grey; for facts that are not states (model, branch, folder).
        case plain
    }

    private let text: String
    private let systemImage: String?
    private let tint: Color?
    private let style: Style
    private let monospaced: Bool

    @EnvironmentObject private var settings: AppSettings

    /// - Parameters:
    ///   - tint: Colour for the tinted / solid / outline styles. Defaults to the theme accent.
    ///   - monospaced: Use the code font (branch names, commands, paths).
    init(_ text: String, systemImage: String? = nil, tint: Color? = nil, style: Style = .tinted, monospaced: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.style = style
        self.monospaced = monospaced
    }

    var body: some View {
        let theme = Theme.current(settings)
        let colour = tint ?? theme.accent
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(theme.font(size: 8.5, weight: .bold))
            }
            Text(text)
                .font(monospaced ? theme.font(size: 10, weight: .medium, design: .monospaced) : theme.font(.micro))
                .lineLimit(1)
        }
        .foregroundStyle(foreground(theme, colour))
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule(style: .continuous).fill(background(theme, colour)))
        .overlay(Capsule(style: .continuous).strokeBorder(border(theme, colour), lineWidth: 1))
        .fixedSize()
    }

    private func foreground(_ theme: Theme, _ colour: Color) -> Color {
        switch style {
        case .tinted, .outline: return colour
        case .solid: return theme.textOnAccent
        case .plain: return theme.textSecondary
        }
    }

    private func background(_ theme: Theme, _ colour: Color) -> Color {
        switch style {
        case .tinted: return colour.opacity(0.15)
        case .solid: return colour
        case .outline: return .clear
        case .plain: return Color.white.opacity(0.06)
        }
    }

    private func border(_ theme: Theme, _ colour: Color) -> Color {
        switch style {
        case .tinted: return colour.opacity(0.22)
        case .solid: return .clear
        case .outline: return colour.opacity(0.5)
        case .plain: return theme.stroke
        }
    }
}

/// One or more keyboard key caps in a row, e.g. `KeyHint("⌘", "Y")` or `KeyHint("esc")`.
struct KeyHint: View {
    private let keys: [String]

    @EnvironmentObject private var settings: AppSettings

    init(_ keys: String...) { self.keys = keys }
    init(keys: [String]) { self.keys = keys }

    var body: some View {
        let theme = Theme.current(settings)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(theme.font(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 3.5)
                    .frame(minWidth: theme.scaled(16), minHeight: theme.scaled(15))
                    .background(shape.fill(Color.white.opacity(0.08)))
                    // A heavier bottom edge makes it read as a physical key.
                    .overlay(shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 0, y: 1)
            }
        }
        .fixedSize()
        .accessibilityLabel(keys.joined(separator: " "))
    }
}
