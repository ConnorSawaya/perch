// CardsControls.swift — three small controls the cards and tabs share.
//
//   CardsButtonLabel      the words on a button plus its keyboard hint: "Allow ⌘Y"
//   CardsSegmentedPicker  a row of choices where one is selected: [Today | 7 days | 30 days]
//   CardsCodeBox          a dark well of monospaced, selectable text with a copy button
//
// They are built from the design system's colours and components; nothing here invents a new look.

import SwiftUI
import AppKit

// MARK: - Button label with a keyboard hint

struct CardsButtonLabel: View {
    private let title: String
    private let systemImage: String?
    private let keys: [String]
    private let onAccent: Bool

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.cardsHintsDimmed) private var hintsDimmed

    /// - Parameters:
    ///   - keys: The shortcut, one entry per key ("⌘", "Y"). Hidden when shortcuts are switched off,
    ///     and drawn faintly on a card the shortcuts would not act on (see `cardsHintsDimmed`).
    ///   - onAccent: The button is filled with the accent colour (a primary button). The usual
    ///     grey key caps are hard to read there, so the hint is drawn in the button's own text colour.
    init(_ title: String, systemImage: String? = nil, keys: [String] = [], onAccent: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.keys = keys
        self.onAccent = onAccent
    }

    var body: some View {
        let theme = Theme.current(settings)
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(theme.font(size: 9.5, weight: .bold))
            }
            Text(title)
            if settings.shortcutsEnabled, !keys.isEmpty {
                Group {
                    if onAccent {
                        Text(keys.joined())
                            .font(theme.font(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textOnAccent.opacity(0.85))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.2)))
                            .accessibilityLabel(keys.joined(separator: " "))
                    } else {
                        KeyHint(keys: keys)
                    }
                }
                .opacity(hintsDimmed ? 0.55 : 1)
            }
        }
        // Button labels are a word or two: never let a rounding error in the layout squeeze
        // one into "…".
        .fixedSize()
    }
}

// MARK: - Segmented picker

struct CardsSegmentedPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let label: String
        var help: String?

        init(_ value: Value, _ label: String, help: String? = nil) {
            self.value = value
            self.label = label
            self.help = help
        }
    }

    private let options: [Option]
    @Binding private var selection: Value

    @EnvironmentObject private var settings: AppSettings

    init(_ options: [Option], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    var body: some View {
        let theme = Theme.current(settings)
        // Normally one pill-shaped row. With many choices on a narrow panel the choices wrap
        // onto more lines inside a rounded box instead of running off the edge.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) { segments }
                .padding(2)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
                // The outline is decoration drawn over the choices; it must never take their clicks.
                .overlay(Capsule(style: .continuous).strokeBorder(theme.stroke, lineWidth: 1).allowsHitTesting(false))
            CardsFlow(spacing: 2, lineSpacing: 2) { segments }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(theme.stroke, lineWidth: 1).allowsHitTesting(false))
        }
    }

    private var segments: some View {
        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
            CardsSegment(label: option.label, help: option.help, isSelected: option.value == selection) {
                selection = option.value
            }
        }
    }
}

/// One choice inside a CardsSegmentedPicker. A separate view so it can track hover.
private struct CardsSegment: View {
    let label: String
    let help: String?
    let isSelected: Bool
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(settings)
        Button(action: action) {
            Text(label)
                .font(theme.font(size: 10.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected || hovering ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Capsule(style: .continuous).fill(isSelected ? theme.surfaceHover : Color.white.opacity(hovering ? 0.05 : 0)))
                .overlay(Capsule(style: .continuous).strokeBorder(isSelected ? theme.strokeStrong : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Code box

struct CardsCodeBox: View {
    private let text: String
    private let systemImage: String?
    private let maxHeight: CGFloat
    private let smallText: Bool

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false
    @State private var copiedAt: Date?

    /// Text longer than this is cut (with a note saying so), so a giant payload cannot freeze the panel.
    static let maxCharacters = 6_000

    /// - Parameters:
    ///   - systemImage: A small icon before the text, e.g. the tool's symbol.
    ///   - maxHeight: The box scrolls once the text is taller than this.
    ///   - smallText: Use the smaller code font (for raw JSON rather than a command to read carefully).
    init(_ text: String, systemImage: String? = nil, maxHeight: CGFloat = 112, smallText: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.maxHeight = maxHeight
        self.smallText = smallText
    }

    var body: some View {
        let theme = Theme.current(settings)
        let shown = Self.clipped(text)
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(theme.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: theme.scaled(13), height: theme.scaled(15))
            }
            CardsScrollBox(maxHeight: theme.scaled(maxHeight)) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text(shown.text)
                        .font(theme.font(smallText ? .monoSmall : .mono))
                        .foregroundStyle(theme.textPrimary.opacity(smallText ? 0.82 : 0.96))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if shown.hidden > 0 {
                        Text("… \(PerchFormat.count(shown.hidden)) more characters are not shown here. See the terminal for the rest.")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.Spacing.m)
        .background(CardBackground(isSunken: true, cornerRadius: Theme.Radius.control))
        .overlay(alignment: .topTrailing) { copyButton(theme) }
        .onHover { hovering = $0 }
    }

    /// Shown only under the pointer, so the box stays calm the rest of the time.
    @ViewBuilder
    private func copyButton(_ theme: Theme) -> some View {
        let justCopied = copiedAt != nil
        if hovering || justCopied {
            PerchIconButton(systemName: justCopied ? "checkmark" : "doc.on.doc", help: justCopied ? "Copied" : "Copy",
                            size: 20, tint: justCopied ? theme.success : nil) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                copiedAt = Date()
            }
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.surfaceHover))
            .padding(4)
            .task(id: copiedAt) {
                guard copiedAt != nil else { return }
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if !Task.isCancelled { copiedAt = nil }
            }
        }
    }

    /// The part of `text` that is shown, and how many characters were left out.
    static func clipped(_ text: String) -> (text: String, hidden: Int) {
        guard text.count > maxCharacters else { return (text, 0) }
        return (String(text.prefix(maxCharacters)), text.count - maxCharacters)
    }
}
