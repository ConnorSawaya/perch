// SettingsLayout.swift — a layout the Settings pages share.
//
//   SettingsFlow { button; button; button }   lays things out left to right and wraps onto new lines

import SwiftUI

/// Places its children in rows, starting a new row whenever the next child would not fit.
/// Used for a row of buttons that must not be squeezed when the text is large.
struct SettingsFlow: Layout {
    var spacing: CGFloat = Theme.Spacing.s
    var lineSpacing: CGFloat = Theme.Spacing.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width.map { min($0, max(width, 0)) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y + (row.height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var width: CGFloat = 0
        var height: CGFloat = 0
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row(y: 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let x = row.items.isEmpty ? 0 : row.width + spacing
            if !row.items.isEmpty && x + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + lineSpacing)
                row.items.append((index, 0, size))
                row.width = size.width
            } else {
                row.items.append((index, x, size))
                row.width = x + size.width
            }
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
