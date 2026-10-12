// ApprovalDiffView.swift — the "what exactly will change in this file?" preview on an approval card.
//
//   ┌────────────────────────────────────────────────────────┐
//   │ ▤ Sources/App/Shell/NotchPanel.swift      +2  −1  ▪▪▫  │  file · lines added / removed
//   ├────────────────────────────────────────────────────────┤
//   │      Line 12 · final class NotchPanel: NSPanel {       │  where in the file
//   │ 12       isFloatingPanel = true                        │  unchanged line
//   │ 13 −     level = .statusBar                            │  removed (red)
//   │ 13 +     level = .mainMenu + 3                         │  added (green)
//   ├────────────────────────────────────────────────────────┤
//   │ Showing the first 40 of 120 lines.                     │  only when something was left out
//   └────────────────────────────────────────────────────────┘
//
// Long lines scroll sideways (the line numbers and +/− marks stay put); a long diff scrolls
// inside the box. The numbers and the row list come from ApprovalDiffModel.

import SwiftUI

struct ApprovalDiffView: View {
    private let diff: DiffPreview
    private let maxLines: Int

    @EnvironmentObject private var settings: AppSettings

    /// - Parameter maxLines: The "maximum diff lines" setting; the rest of the diff is summarised in a footnote.
    init(diff: DiffPreview, maxLines: Int) {
        self.diff = diff
        self.maxLines = maxLines
    }

    var body: some View {
        let theme = Theme.current(settings)
        let model = ApprovalDiffModel(diff: diff, maxLines: maxLines)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            titleBar(theme, model)
            PerchDivider()
            if model.rows.isEmpty {
                Text("There is no preview for this change.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textTertiary)
                    .padding(10)
            } else {
                CardsScrollBox(maxHeight: theme.scaled(204)) { table(theme, model) }
            }
            if let footnote = model.footnote {
                PerchDivider()
                Label(footnote, systemImage: "scissors")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, Theme.Spacing.s)
            }
        }
        .background(CardBackground(isSunken: true, cornerRadius: Theme.Radius.control))
        .clipShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(model))
    }

    // MARK: Title bar

    private func titleBar(_ theme: Theme, _ model: ApprovalDiffModel) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "doc.text")
                .font(theme.font(size: 9.5, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text(CardsWording.tidy(diff.filePath).map(PerchFormat.path) ?? "Changes")
                .font(theme.font(.monoSmall))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                // Keep the end of a long path: the file name matters more than the top folders.
                .truncationMode(.head)
            Spacer(minLength: Theme.Spacing.m)
            HStack(spacing: Theme.Spacing.s) {
                Text("+\(model.added)").foregroundStyle(theme.success)
                Text("−\(model.removed)").foregroundStyle(theme.danger)
            }
            .font(theme.font(size: 10.5, weight: .semibold, design: .monospaced))
            .fixedSize()
            ApprovalDiffBalance(added: model.added, removed: model.removed)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.Spacing.s)
        .help("\(CardsWording.counted(model.added, "line")) added, \(CardsWording.counted(model.removed, "line")) removed")
    }

    // MARK: Rows

    private func table(_ theme: Theme, _ model: ApprovalDiffModel) -> some View {
        let rowHeight = theme.scaled(17)
        let height = rowHeight * CGFloat(model.rows.count)
        return HStack(alignment: .top, spacing: 0) {
            gutter(theme, model, rowHeight: rowHeight)
            CardsSidewaysScroll(height: height) { code(theme, model, rowHeight: rowHeight) }
        }
        .padding(.vertical, Theme.Spacing.xs)
        // The coloured bands sit behind everything and span the full width, so they stay put
        // (and stay complete) while the code scrolls sideways over them.
        .background { bands(theme, model, rowHeight: rowHeight).padding(.vertical, Theme.Spacing.xs) }
    }

    /// Line numbers and the +/− marks. This column does not scroll sideways.
    private func gutter(_ theme: Theme, _ model: ApprovalDiffModel, rowHeight: CGFloat) -> some View {
        // Every number gets the width of the widest one: an invisible run of 8s as wide as the
        // biggest number sets the column width, so nothing is guessed from the font size.
        let widest = String(repeating: "8", count: String(model.rows.compactMap(\.number).max() ?? 0).count)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
                HStack(spacing: 5) {
                    if model.showsNumbers {
                        Text(widest)
                            .hidden()
                            .overlay(alignment: .trailing) {
                                Text(row.number.map(String.init) ?? "")
                                    .foregroundStyle(theme.textTertiary.opacity(0.85))
                                    .fixedSize()
                            }
                    }
                    Text(row.sign)
                        .fontWeight(.bold)
                        .foregroundStyle(colour(row.kind, theme))
                        .frame(width: theme.scaled(8))
                }
                .frame(height: rowHeight)
            }
        }
        .font(theme.font(.monoSmall))
        .lineLimit(1)
        .padding(.leading, 9)
        .padding(.trailing, 7)
    }

    private func code(_ theme: Theme, _ model: ApprovalDiffModel, rowHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
                Text(row.text.isEmpty ? " " : row.text)
                    .font(row.kind == .header ? theme.font(size: 10, weight: .medium) : theme.font(.monoSmall))
                    .foregroundStyle(colour(row.kind, theme))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: rowHeight, alignment: .leading)
            }
        }
        // Room to scroll the end of the longest line clear of the fading edge.
        .padding(.trailing, 28)
    }

    private func bands(_ theme: Theme, _ model: ApprovalDiffModel, rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(model.rows) { row in
                band(row.kind, theme).frame(height: rowHeight)
            }
        }
    }

    @ViewBuilder
    private func band(_ kind: DiffLine.Kind, _ theme: Theme) -> some View {
        switch kind {
        case .added: edgeBand(theme.success)
        case .removed: edgeBand(theme.danger)
        case .header: Color.white.opacity(0.045)
        case .context: Color.clear
        }
    }

    /// A tinted band with a brighter stripe on its left edge.
    private func edgeBand(_ colour: Color) -> some View {
        colour.opacity(0.13).overlay(alignment: .leading) { colour.opacity(0.9).frame(width: 2) }
    }

    private func colour(_ kind: DiffLine.Kind, _ theme: Theme) -> Color {
        switch kind {
        case .added: return theme.success
        case .removed: return theme.danger
        case .header: return theme.textTertiary
        case .context: return theme.textSecondary
        }
    }

    private func accessibilitySummary(_ model: ApprovalDiffModel) -> String {
        let file = CardsWording.tidy(diff.filePath) ?? "a file"
        return "Changes to \(file): \(CardsWording.counted(model.added, "line")) added, \(CardsWording.counted(model.removed, "line")) removed"
    }
}

/// Five small squares showing the balance of added (green) to removed (red) lines at a glance.
private struct ApprovalDiffBalance: View {
    let added: Int
    let removed: Int

    @EnvironmentObject private var settings: AppSettings

    private static let squares = 5

    var body: some View {
        let theme = Theme.current(settings)
        let total = added + removed
        // At least one square for a side that has any lines, so a small removal is not lost.
        let greenExact = total > 0 ? Double(added) / Double(total) * Double(Self.squares) : 0
        var green = Int(greenExact.rounded())
        if added > 0 { green = max(green, 1) }
        if removed > 0 { green = min(green, Self.squares - 1) }
        return HStack(spacing: 1.5) {
            ForEach(0..<Self.squares, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(total == 0 ? Color.white.opacity(0.14) : (index < green ? theme.success : theme.danger))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
