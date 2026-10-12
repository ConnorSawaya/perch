// PlanMarkdown.swift — reads a plan written in Markdown into a list of blocks (pure, no UI).
//
// Agents write their plans as Markdown. This is a small reader for the parts plans actually
// use, not a full Markdown implementation:
//   # headings              paragraphs (wrapped lines are joined)
//   - bullets, nested       1. numbered lists        - [x] check-list items
//   ``` fenced code ```     > quotes                 --- rules            | simple | tables |
// Bold, italic and `code` inside a line are handled later, when the text is drawn
// (CardsInline.markdown). Anything not recognised is kept as ordinary paragraph text, so
// nothing an agent wrote is ever dropped.

import Foundation

struct PlanDocument: Equatable {
    enum ListMarker: Equatable {
        case bullet
        /// The number as written, e.g. "3".
        case number(String)
        case task(done: Bool)
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// One list entry. `depth` 0 is the outermost list.
        case listItem(marker: ListMarker, depth: Int, text: String)
        case code(language: String?, lines: [String])
        case quote(String)
        case rule
        /// The first row is the header.
        case table(rows: [[String]])
    }

    var blocks: [Block] = []
    /// True when the plan was longer than the reader's limits and the end was left out.
    var truncated = false

    /// Limits that keep a runaway plan from stalling the panel.
    static let maxCharacters = 40_000
    static let maxBlocks = 400
    static let maxListDepth = 4

    init(markdown: String) {
        var source = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if source.count > Self.maxCharacters {
            source = String(source.prefix(Self.maxCharacters))
            truncated = true
        }
        var reader = Reader()
        for line in source.components(separatedBy: "\n") {
            reader.read(line.replacingOccurrences(of: "\t", with: "    "))
        }
        reader.finish()
        blocks = reader.blocks
        if blocks.count > Self.maxBlocks {
            blocks = Array(blocks.prefix(Self.maxBlocks))
            truncated = true
        }
    }
}

// MARK: - Line-by-line reader

private struct Reader {
    var blocks: [PlanDocument.Block] = []

    /// Lines of the paragraph being collected.
    private var paragraph: [String] = []
    private var quote: [String] = []
    private var table: [[String]] = []
    /// The open code fence ("```" or "~~~"), its language and its lines.
    private var fence: (marker: String, language: String?, lines: [String])?
    /// Indentation of each list level seen so far in the current list, outermost first.
    private var listIndents: [Int] = []
    /// True when the last thing read was a list item (so an indented line continues it).
    private var inListItem = false

    mutating func read(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if let open = fence {
            if trimmed.hasPrefix(open.marker), trimmed.dropFirst(open.marker.count).allSatisfy({ $0 == open.marker.first }) {
                closeFence()
            } else {
                fence?.lines.append(line)
            }
            return
        }
        if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
            flush()
            listIndents = []
            let language = trimmed.drop { $0 == marker.first }.trimmingCharacters(in: .whitespaces)
            fence = (marker, language.isEmpty ? nil : language, [])
            return
        }
        if trimmed.isEmpty {
            flush()
            return
        }
        if let heading = Self.heading(trimmed) {
            flush()
            listIndents = []
            blocks.append(.heading(level: heading.level, text: heading.text))
            return
        }
        if Self.isRule(trimmed) {
            flush()
            listIndents = []
            blocks.append(.rule)
            return
        }
        if trimmed.hasPrefix(">") {
            if quote.isEmpty { flush() }
            quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            return
        }
        if trimmed.hasPrefix("|"), trimmed.count > 1 {
            if table.isEmpty { flush() }
            if !Self.isTableDivider(trimmed) { table.append(Self.cells(trimmed)) }
            return
        }
        let indent = line.prefix { $0 == " " }.count
        if let item = Self.listItem(trimmed) {
            flush()
            blocks.append(.listItem(marker: item.marker, depth: depth(forIndent: indent), text: item.text))
            inListItem = true
            return
        }
        // A plain line right under a list item belongs to that item.
        if inListItem, paragraph.isEmpty, case .listItem(let marker, let depth, let text)? = blocks.last {
            blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: text + " " + trimmed)
            return
        }
        if paragraph.isEmpty {
            flush()
            listIndents = []
        }
        // Two spaces or a backslash at the end of a line ask for a real line break.
        let hardBreak = line.hasSuffix("  ") || trimmed.hasSuffix("\\")
        let text = trimmed.hasSuffix("\\") ? String(trimmed.dropLast()) : trimmed
        paragraph.append(text + (hardBreak ? "\n" : " "))
    }

    mutating func finish() {
        if fence != nil { closeFence() }
        flush()
    }

    // MARK: Closing what is open

    private mutating func closeFence() {
        guard let open = fence else { return }
        var lines = open.lines
        // Drop the indentation the whole block shares (fences inside list items are indented).
        let shared = lines.filter { !$0.allSatisfy { $0 == " " } }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        if shared > 0 { lines = lines.map { String($0.dropFirst(min(shared, $0.count))) } }
        while let last = lines.last, last.allSatisfy({ $0 == " " }) { lines.removeLast() }
        blocks.append(.code(language: open.language, lines: lines))
        fence = nil
    }

    private mutating func flush() {
        if !paragraph.isEmpty {
            let text = paragraph.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        if !quote.isEmpty {
            blocks.append(.quote(quote.joined(separator: " ").trimmingCharacters(in: .whitespaces)))
            quote = []
        }
        if !table.isEmpty {
            blocks.append(.table(rows: table))
            table = []
        }
        inListItem = false
    }

    /// How deep a list item with this indentation is, remembering the indentation of its parents.
    private mutating func depth(forIndent indent: Int) -> Int {
        listIndents.removeAll { $0 >= indent }
        let depth = min(listIndents.count, PlanDocument.maxListDepth)
        listIndents.append(indent)
        return depth
    }

    // MARK: Recognising lines

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        // "## Title ##" is the same heading as "## Title".
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func listItem(_ trimmed: String) -> (marker: PlanDocument.ListMarker, text: String)? {
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            let text = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            for (box, done) in [("[ ]", false), ("[x]", true), ("[X]", true)] where text.hasPrefix(box + " ") {
                return (.task(done: done), text.dropFirst(box.count).trimmingCharacters(in: .whitespaces))
            }
            return (.bullet, text)
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return (.number(String(digits)), rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// "|---|:--:|" — the line between a table's header and its rows.
    private static func isTableDivider(_ trimmed: String) -> Bool {
        trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ trimmed: String) -> [String] {
        var inner = Substring(trimmed)
        if inner.hasPrefix("|") { inner = inner.dropFirst() }
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
