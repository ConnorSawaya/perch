// CardsInlineText.swift — turns a line of text with a little inline formatting into styled text.
//
// Two strengths, for two kinds of source:
//   CardsInline.markdown(...)   **bold**, *italic*, `code`, ~~struck~~ and [links](…) — for plans,
//                               which agents write as Markdown.
//   CardsInline.codeSpans(...)  only `code` — for Perch's own one-line summaries, where a stray
//                               "*" (as in "*.swift") must stay a star.
//
// Both return an AttributedString that a SwiftUI Text draws directly. Links are shown in the
// accent colour but are not clickable: a plan is something an agent wrote, and a click in the
// notch should never open a web page by surprise.

import SwiftUI

enum CardsInline {
    /// How the plain parts of the text look; bold, italic and code are derived from it.
    struct Style {
        var size: CGFloat
        var weight: Font.Weight = .regular
        var color: Color
        var italic = false
    }

    static func markdown(_ source: String, theme: Theme, style: Style) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return piece(source, theme: theme, style: style)
        }
        var result = AttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            result.append(piece(String(parsed[run.range].characters), theme: theme, style: style,
                                bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized),
                                code: intent.contains(.code), struck: intent.contains(.strikethrough),
                                link: run.link != nil))
        }
        return result
    }

    static func codeSpans(_ source: String, theme: Theme, style: Style) -> AttributedString {
        // Text between a pair of backticks is code. An unpaired backtick is just a backtick.
        let parts = source.components(separatedBy: "`")
        guard parts.count >= 3 else { return piece(source, theme: theme, style: style) }
        var result = AttributedString()
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            let isCode = index % 2 == 1 && !isLast
            // An odd backtick left over at the end is put back as typed.
            let text = (index % 2 == 1 && isLast) ? "`" + part : part
            if !text.isEmpty { result.append(piece(text, theme: theme, style: style, code: isCode)) }
        }
        return result
    }

    private static func piece(_ text: String, theme: Theme, style: Style, bold: Bool = false, italic: Bool = false,
                              code: Bool = false, struck: Bool = false, link: Bool = false) -> AttributedString {
        var piece = AttributedString(text)
        let weight: Font.Weight = bold ? (style.weight == .regular ? .semibold : .bold) : style.weight
        var font = code ? theme.font(size: style.size * 0.93, weight: weight, design: .monospaced)
                        : theme.font(size: style.size, weight: weight)
        if italic || style.italic { font = font.italic() }
        piece.swiftUI.font = font
        piece.swiftUI.foregroundColor = link ? theme.accent : (code || bold ? theme.textPrimary : style.color)
        if code { piece.swiftUI.backgroundColor = Color.white.opacity(0.08) }
        if struck { piece.swiftUI.strikethroughStyle = Text.LineStyle(pattern: .solid, color: style.color) }
        return piece
    }
}
