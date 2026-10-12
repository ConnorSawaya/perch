// PlanMarkdownView.swift — draws a plan (already read into blocks by PlanMarkdown) with the app's fonts and colours.
//
// Headings, paragraphs, lists, check-lists, code, quotes, rules and simple tables. Code blocks
// scroll sideways instead of wrapping, because wrapped code is hard to read. The view is
// Equatable so that SwiftUI only re-reads the Markdown when the text itself changes, not every
// time the pointer moves over the card.

import SwiftUI

struct PlanMarkdownView: View, Equatable {
    private let markdown: String

    @EnvironmentObject private var settings: AppSettings

    init(markdown: String) {
        self.markdown = markdown
    }

    static func == (a: PlanMarkdownView, b: PlanMarkdownView) -> Bool { a.markdown == b.markdown }

    var body: some View {
        let theme = Theme.current(settings)
        let document = PlanDocument(markdown: markdown)
        VStack(alignment: .leading, spacing: 0) {
            if document.blocks.isEmpty {
                Text("The plan is empty.")
                    .font(theme.font(.body))
                    .foregroundStyle(theme.textTertiary)
            }
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, theme)
                    .padding(.top, index == 0 ? 0 : gap(before: block, after: document.blocks[index - 1]))
            }
            if document.truncated {
                Label("The plan is longer than Perch shows here. Read the rest in the terminal.", systemImage: "scissors")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.warning)
                    .padding(.top, Theme.Spacing.l)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// Space above a block. Headings get air, neighbouring list items stay close together.
    private func gap(before block: PlanDocument.Block, after previous: PlanDocument.Block) -> CGFloat {
        switch (previous, block) {
        case (_, .heading(let level, _)): return level <= 2 ? 14 : 11
        case (.heading, _): return 5
        case (.listItem, .listItem): return 4
        default: return 8
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private func view(for block: PlanDocument.Block, _ theme: Theme) -> some View {
        switch block {
        case .heading(let level, let text):
            heading(level, text, theme)
        case .paragraph(let text):
            Text(CardsInline.markdown(text, theme: theme, style: body(theme)))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let depth, let text):
            listItem(marker, depth, text, theme)
        case .code(let language, let lines):
            PlanCodeBlock(language: language, lines: lines)
        case .quote(let text):
            Text(CardsInline.markdown(text, theme: theme, style: .init(size: 12.5, color: theme.textSecondary, italic: true)))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(theme.ask.opacity(0.7)).frame(width: 2.5) }
        case .rule:
            PerchDivider().padding(.vertical, 2)
        case .table(let rows):
            PlanTable(rows: rows)
        }
    }

    private func body(_ theme: Theme) -> CardsInline.Style {
        .init(size: 12.5, color: theme.textPrimary.opacity(0.84))
    }

    @ViewBuilder
    private func heading(_ level: Int, _ text: String, _ theme: Theme) -> some View {
        switch level {
        case 1:
            Text(CardsInline.markdown(text, theme: theme, style: .init(size: 15, weight: .semibold, color: theme.textPrimary)))
                .fixedSize(horizontal: false, vertical: true)
        case 2:
            // Second-level headings are the plan's sections: a small coloured label reads better
            // than more big bold text inside a small card.
            Text(text)
                .font(theme.font(.micro))
                .foregroundStyle(theme.ask)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        default:
            Text(CardsInline.markdown(text, theme: theme, style: .init(size: 12.5, weight: .semibold, color: theme.textPrimary)))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listItem(_ marker: PlanDocument.ListMarker, _ depth: Int, _ text: String, _ theme: Theme) -> some View {
        let isDone = marker == .task(done: true)
        var style = body(theme)
        if isDone { style.color = theme.textTertiary }
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            markerView(marker, theme)
                .frame(minWidth: theme.scaled(14), alignment: .trailing)
            Text(CardsInline.markdown(text, theme: theme, style: style))
                .strikethrough(isDone, color: theme.textTertiary)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    @ViewBuilder
    private func markerView(_ marker: PlanDocument.ListMarker, _ theme: Theme) -> some View {
        switch marker {
        case .bullet:
            Circle().fill(theme.textTertiary)
                .frame(width: 4, height: 4)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + theme.scaled(3) }
        case .number(let number):
            Text(number + ".")
                .font(theme.font(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.ask)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(theme.font(size: 11, weight: .medium))
                .foregroundStyle(done ? theme.success : theme.textTertiary)
        }
    }
}

/// A fenced code block: monospaced, one row per line, scrolling sideways when lines are long.
private struct PlanCodeBlock: View {
    let language: String?
    let lines: [String]

    @EnvironmentObject private var settings: AppSettings

    /// Longer blocks are cut; the full plan is in the terminal and in the plan file.
    private static let maxLines = 60

    var body: some View {
        let theme = Theme.current(settings)
        let shown = Array(lines.prefix(Self.maxLines))
        let rowHeight = theme.scaled(16)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            CardsSidewaysScroll(height: rowHeight * CGFloat(max(shown.count, 1))) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(theme.font(.monoSmall))
                            .foregroundStyle(theme.textPrimary.opacity(0.9))
                            .lineLimit(1)
                            .fixedSize()
                            .frame(height: rowHeight, alignment: .leading)
                    }
                }
                .padding(.trailing, 24)
            }
            if lines.count > shown.count {
                Text("… \(CardsWording.counted(lines.count - shown.count, "more line")) not shown")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.white.opacity(0.05)))
        .overlay(shape.strokeBorder(theme.stroke, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let language = CardsWording.tidy(language) {
                Text(language)
                    .font(theme.font(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Code: " + shown.joined(separator: " "))
    }
}

/// A simple table: the first row is the header, columns are as wide as their content needs.
private struct PlanTable: View {
    let rows: [[String]]

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = Theme.current(settings)
        let columns = rows.map(\.count).max() ?? 0
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.l, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        let text = column < row.count ? row[column] : ""
                        Text(CardsInline.markdown(text, theme: theme, style: cellStyle(header: rowIndex == 0, theme)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if rowIndex == 0, rows.count > 1 {
                    PerchDivider().gridCellColumns(max(columns, 1))
                }
            }
        }
    }

    private func cellStyle(header: Bool, _ theme: Theme) -> CardsInline.Style {
        header ? .init(size: 11.5, weight: .semibold, color: theme.textSecondary)
               : .init(size: 12, color: theme.textPrimary.opacity(0.84))
    }
}
