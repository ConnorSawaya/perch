// ThemePicker.swift — the six theme tiles in Settings → Look, side by side.
//
// Each tile is a tiny picture of the island drawn in that theme's own colours (its card colour,
// accent gradient, state colours and glow), so the choice can be made by eye. Clicking a tile
// switches the whole app at once.

import SwiftUI

extension ThemeID {
    var title: String {
        switch self {
        case .midnight: return "Midnight"
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        case .synthwave: return "Synthwave"
        case .forest: return "Forest"
        case .mono: return "Mono"
        }
    }

    /// Two or three words describing the mood, for VoiceOver and the tooltip.
    var tagline: String {
        switch self {
        case .midnight: return "Deep blue, violet glow"
        case .aurora: return "Mint and sky"
        case .ember: return "Warm coals"
        case .synthwave: return "Neon pink and cyan"
        case .forest: return "Moss and pine"
        case .mono: return "Quiet graphite"
        }
    }
}

struct SettingsThemePicker: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ForEach(ThemeID.allCases) { id in
                SettingsThemeTile(id: id, isSelected: settings.theme == id) {
                    if settings.theme != id { settings.theme = id }
                }
            }
        }
    }
}

private struct SettingsThemeTile: View {
    let id: ThemeID
    let isSelected: Bool
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    var body: some View {
        // `current` styles the tile's frame and label; `palette` is the theme being pictured.
        let current = Theme.current(settings)
        let palette = Theme.palette(id)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        Button(action: action) {
            VStack(spacing: Theme.Spacing.s) {
                SettingsThemeSwatch(palette: palette)
                    .frame(height: 54)
                Text(id.title)
                    .font(current.font(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? current.textPrimary : current.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(Theme.Spacing.s)
            .padding(.bottom, 1)
            .frame(maxWidth: .infinity)
            .background(shape.fill(hovering || isSelected ? current.surfaceHover : current.surface))
            .overlay(shape.strokeBorder(isSelected
                                            ? AnyShapeStyle(palette.accent)
                                            : AnyShapeStyle(hovering ? current.strokeStrong : current.stroke),
                                        lineWidth: isSelected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(id.tagline)
        .accessibilityLabel("\(id.title) theme, \(id.tagline)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A miniature island in one theme's colours: glow at the top, a card with a title bar, an accent
/// button and the state colours. Its bars stretch, so it can be drawn at any width.
private struct SettingsThemeSwatch: View {
    let palette: Theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(palette.island)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Circle().fill(palette.accent).frame(width: 8, height: 8)
                    Capsule().fill(palette.textPrimary.opacity(0.9)).frame(height: 4)
                    Capsule().fill(palette.accent).frame(width: 16, height: 8)
                }
                Capsule().fill(palette.textSecondary.opacity(0.6)).frame(height: 3).padding(.trailing, 14)
                HStack(spacing: 3) {
                    ForEach(Array([palette.success, palette.warning, palette.danger, palette.info, palette.ask].enumerated()),
                            id: \.offset) { _, colour in
                        Circle().fill(colour).frame(width: 5, height: 5)
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.strokeStrong, lineWidth: 1))
            .padding(.horizontal, 7)
            .padding(.top, 11)
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}
