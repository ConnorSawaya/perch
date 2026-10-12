// ApprovalDiffModel.swift — turns a DiffPreview into the rows the diff view draws (pure, no UI).
//
// Three jobs:
//   1. Cut the diff to the "maximum diff lines" setting and remember how much was left out.
//   2. Work out a line number for each row from the "@@ -12,7 +12,9 @@" hunk headers, when the
//      diff has them: changed and unchanged lines show their number in the new file, removed
//      lines show the number they had in the old file.
//   3. Make the text safe to draw: tabs become spaces, very long lines are cut, and the
//      indentation all lines share is removed so the code is not pushed off to the right.

import Foundation

struct ApprovalDiffModel: Equatable {
    struct Row: Equatable, Identifiable {
        /// Position in the shown rows.
        let id: Int
        let kind: DiffLine.Kind
        /// Line number in the file, when a hunk header made it known.
        let number: Int?
        let text: String

        /// The gutter mark: "+" for added, "−" for removed.
        var sign: String {
            switch kind {
            case .added: return "+"
            case .removed: return "−"
            case .context, .header: return ""
            }
        }
    }

    let rows: [Row]
    /// Lines of the preview that did not fit under the limit.
    let hiddenLines: Int
    /// True when at least one row has a line number (so the number column is worth showing).
    let showsNumbers: Bool
    let added: Int
    let removed: Int
    /// A sentence to show under the diff when it is not the whole change; nil when it is.
    let footnote: String?

    /// The limits of the "maximum diff lines" setting.
    static let lineLimitRange = 10...200
    /// Longer lines are cut: a minified file on one line must not stall the layout.
    static let maxLineLength = 400

    init(diff: DiffPreview, maxLines: Int) {
        let limit = min(max(maxLines, Self.lineLimitRange.lowerBound), Self.lineLimitRange.upperBound)
        let shown = diff.lines.prefix(limit)

        var rows: [Row] = []
        // The next line's number in the old and in the new file; nil until a hunk header says.
        var oldNumber: Int?
        var newNumber: Int?
        for line in shown {
            var number: Int?
            var text = Self.clean(line.text)
            switch line.kind {
            case .header:
                if let hunk = Self.parseHunkHeader(line.text) {
                    oldNumber = hunk.oldStart
                    newNumber = hunk.newStart
                    text = hunk.context.isEmpty ? "Line \(hunk.newStart)" : "Line \(hunk.newStart) · \(Self.clean(hunk.context))"
                }
            case .context:
                number = newNumber
                oldNumber = oldNumber.map { $0 + 1 }
                newNumber = newNumber.map { $0 + 1 }
            case .added:
                number = newNumber
                newNumber = newNumber.map { $0 + 1 }
            case .removed:
                number = oldNumber
                oldNumber = oldNumber.map { $0 + 1 }
            }
            rows.append(Row(id: rows.count, kind: line.kind, number: number, text: text))
        }

        self.rows = Self.dedented(rows)
        hiddenLines = diff.lines.count - shown.count
        showsNumbers = rows.contains { $0.number != nil }

        // Trust the adapter's totals (they cover the whole change); count the lines only when it gave none.
        let countedAdded = diff.lines.filter { $0.kind == .added }.count
        let countedRemoved = diff.lines.filter { $0.kind == .removed }.count
        let hasTotals = diff.added > 0 || diff.removed > 0
        added = hasTotals ? max(diff.added, 0) : countedAdded
        removed = hasTotals ? max(diff.removed, 0) : countedRemoved

        if hiddenLines > 0 {
            let first = "Showing the first \(shown.count) of \(diff.lines.count) lines."
            footnote = diff.truncated ? first + " The whole change is longer still." : first
        } else if diff.truncated {
            footnote = "This is only the start — the whole change is longer than the preview."
        } else {
            footnote = nil
        }
    }

    /// Reads "@@ -12,7 +12,9 @@ final class NotchPanel {" → old start 12, new start 12, context "final class NotchPanel {".
    /// Returns nil for anything that is not a hunk header.
    static func parseHunkHeader(_ text: String) -> (oldStart: Int, newStart: Int, context: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@@") else { return nil }
        let afterOpening = trimmed.dropFirst(2)
        guard let closing = afterOpening.range(of: "@@") else { return nil }
        let ranges = afterOpening[..<closing.lowerBound].split(separator: " ")
        let context = afterOpening[closing.upperBound...].trimmingCharacters(in: .whitespaces)

        func start(_ prefix: Character) -> Int? {
            guard let range = ranges.first(where: { $0.first == prefix }) else { return nil }
            let digits = range.dropFirst().prefix { $0.isNumber }
            return Int(digits)
        }
        guard let oldStart = start("-"), let newStart = start("+") else { return nil }
        return (oldStart, newStart, context)
    }

    /// Removes the indentation every code row shares, so deeply nested code starts at the left
    /// edge of the preview instead of half-way across it. Relative indentation is kept.
    static func dedented(_ rows: [Row]) -> [Row] {
        let code = rows.filter { $0.kind != .header && !$0.text.allSatisfy { $0 == " " } }
        let shared = code.map { $0.text.prefix { $0 == " " }.count }.min() ?? 0
        guard shared > 0 else { return rows }
        return rows.map { row in
            guard row.kind != .header else { return row }
            return Row(id: row.id, kind: row.kind, number: row.number, text: String(row.text.dropFirst(shared)))
        }
    }

    /// Makes one line of file content safe and predictable to draw.
    static func clean(_ text: String) -> String {
        var line = text.replacingOccurrences(of: "\t", with: "    ")
        // `isNewline` also catches "\r\n", which Swift treats as one character.
        line.removeAll { $0.isNewline }
        if line.count > maxLineLength { line = String(line.prefix(maxLineLength)) + " …" }
        return line
    }
}
