// QuestionCardView.swift — the card for "the agent is asking you to choose".
//
//   ┌──────────────────────────────────────────────────────────────────┐
//   │ [C]  ? Framework                                  [1 of 2]   8s  │
//   │      dashboard · Set up the web dashboard                        │
//   │  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬  ────────────────                              │  one bar per question
//   │  Which framework should the dashboard use?                       │
//   │  ◉ React       Largest ecosystem, most examples             ⌘1   │
//   │  ○ Svelte      Smaller bundles, less boilerplate            ⌘2   │
//   │  ✎ Other…                                                        │  opens a text field
//   │  [ ‹ Back ] [ Next › ]                      Answer in terminal ⌘T │
//   └──────────────────────────────────────────────────────────────────┘
//
// How answering works (the bookkeeping is in QuestionFlow):
//   - one single-select question   → a click on an option answers at once
//   - several questions            → pick, then Next; the last step says "Send answers"
//   - multi-select                 → tick any number, then Confirm / Next
//   - "Other…"                     → type your own answer; Return moves on
// The final answer is Decision.answer([question text: answer]); multi-select answers are the
// chosen labels joined with ", ".
//
// Keyboard: for a single single-select question the window shell answers ⌘1…⌘9 itself. For
// everything richer (several questions, multi-select) the shell leaves those keys alone, and
// this card handles them while it is the focused card: ⌘1…⌘9 pick or tick an option, ⌘↩ is
// Next / Confirm / Send. Never while a text field is open, and never on a held-down key.

import SwiftUI
import AppKit

struct QuestionCardView: View {
    private let request: PendingRequest
    private let session: Session?

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @State private var flow: QuestionFlow

    /// A question that appeared less than this long ago ignores key presses, so a key meant
    /// for something else cannot answer a question the user has not read yet.
    private static let keyboardGrace: TimeInterval = 0.6

    /// - Parameter preview: Draws the card part-way through being used. Only for snapshots; the app leaves it out.
    init(request: PendingRequest, session: Session?, preview: CardsPreview = CardsPreview()) {
        self.request = request
        self.session = session
        var questions: [Question] = []
        if case .question(let asked) = request.kind { questions = asked.questions }
        self._flow = State(initialValue: Self.flow(for: questions, preview: preview))
    }

    /// The starting state, moved along to wherever the preview says.
    private static func flow(for questions: [Question], preview: CardsPreview) -> QuestionFlow {
        var flow = QuestionFlow(questions: questions)
        for (step, options) in preview.questionPicks.sorted(by: { $0.key < $1.key }) {
            flow.show(step: step)
            // Simple cards answer on a pick; a preview only wants the highlight, so ignore the decision.
            for option in options.sorted() { flow.pick(option) }
        }
        flow.show(step: preview.questionStep)
        if preview.otherOpen {
            flow.setOtherOpen(true)
            flow.setOtherText(preview.otherText)
        }
        return flow
    }

    var body: some View {
        if case .question = request.kind {
            let theme = Theme.current(settings)
            let question = flow.current
            RequestCardShell(request: request, session: session, symbol: "questionmark.bubble.fill",
                             title: CardsWording.tidy(question?.header) ?? "A question for you",
                             tint: theme.ask, tag: stepTag) { send in
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    if flow.questions.count > 1 {
                        QuestionSteps(count: flow.questions.count, current: flow.step, answered: flow.answered, tint: theme.ask)
                    }
                    if let question {
                        prompt(question, theme)
                        options(question, theme, send)
                    } else {
                        Text("\(request.agent.displayName) asked something Perch could not read. Answer it in the terminal.")
                            .font(theme.font(.body))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    buttons(theme, send)
                }
                .background { keyboardShortcuts(send) }
            }
        }
    }

    // MARK: Keyboard

    /// True when this card should react to ⌘-number and ⌘↩ itself (see the note at the top).
    private var handlesKeys: Bool {
        settings.shortcutsEnabled && ui.focusedRequestID == request.id && !ui.needsKeyboard
            && !flow.isSimple && flow.current != nil
    }

    /// The shortcut shown next to an option, when pressing it would really pick that option.
    private func optionKeys(_ index: Int) -> [String] {
        // With the Other field open the keyboard belongs to the text field.
        index < 9 && !flow.isOtherOpen ? ["⌘", "\(index + 1)"] : []
    }

    /// Invisible buttons that carry the card's keyboard shortcuts while it is the focused card.
    @ViewBuilder
    private func keyboardShortcuts(_ send: @escaping (Decision) -> Void) -> some View {
        if handlesKeys {
            ZStack {
                ForEach(0..<min(flow.current?.options.count ?? 0, 9), id: \.self) { index in
                    Button("") { keyPressed { _ = flow.pick(index) } }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Button("") { keyPressed { advance(send) } }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Runs a shortcut's action unless the key is being held down or the question is brand new.
    private func keyPressed(_ action: () -> Void) {
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
        guard Date().timeIntervalSince(request.createdAt) >= Self.keyboardGrace else { return }
        action()
    }

    private var stepTag: RequestCardTag? {
        flow.questions.count > 1 ? RequestCardTag(text: "\(flow.step + 1) of \(flow.questions.count)") : nil
    }

    // MARK: The question

    private func prompt(_ question: Question, _ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CardsWording.tidy(question.text) ?? "Choose one")
                .font(theme.font(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineSpacing(1.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if question.multiSelect {
                Text("Tick everything that applies.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    // MARK: Options

    private func options(_ question: Question, _ theme: Theme, _ send: @escaping (Decision) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                QuestionOptionRow(label: CardsWording.tidy(option.label) ?? "Option \(index + 1)", detail: option.detail,
                                  marker: question.multiSelect ? .checkbox : .radio,
                                  isSelected: flow.isPicked(index), tint: theme.ask,
                                  keys: optionKeys(index)) {
                    if let decision = flow.pick(index) { send(decision) }
                }
            }
            if flow.isOtherOpen {
                otherEditor(question, theme, send)
            } else {
                QuestionOptionRow(label: question.options.isEmpty ? "Type your answer…" : "Other…", marker: .pencil,
                                  isSelected: false, tint: theme.ask) {
                    flow.setOtherOpen(true)
                }
                .help("Type an answer of your own")
            }
        }
    }

    private func otherEditor(_ question: Question, _ theme: Theme, _ send: @escaping (Decision) -> Void) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            CardsTextField(question.multiSelect ? "Something else to add" : "Your own answer",
                           text: Binding(get: { flow.otherText }, set: { flow.setOtherText($0) })) {
                advance(send)
            }
            PerchIconButton(systemName: "xmark", help: "Close this field", size: 22) { flow.setOtherOpen(false) }
        }
    }

    // MARK: Buttons

    private func buttons(_ theme: Theme, _ send: @escaping (Decision) -> Void) -> some View {
        // The simple card needs no Next button until the user types an answer of their own.
        let needsConfirm = flow.current != nil && (!flow.isSimple || flow.isOtherOpen)
        return CardsActionRow {
            if !flow.isFirst {
                Button { flow.back() } label: {
                    CardsButtonLabel("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.perch(.secondary))
            }
            if needsConfirm {
                Button { advance(send) } label: {
                    CardsButtonLabel(confirmTitle, keys: flow.isOtherOpen ? ["↩"] : ["⌘", "↩"], onAccent: true)
                }
                .buttonStyle(.perch(.primary))
                .disabled(!flow.canAdvance)
                .help(flow.canAdvance ? "Carry on" : "Choose an answer first")
            }
        } extra: {
            Button { send(.passToTerminal) } label: {
                CardsButtonLabel("Answer in terminal", systemImage: "terminal", keys: ["⌘", "T"])
            }
            .buttonStyle(.perch(.ghost, size: .small))
            .help("Perch steps aside and \(request.agent.displayName) shows its own prompt")
        }
    }

    private var confirmTitle: String {
        if !flow.isLast { return "Next" }
        return flow.questions.count > 1 ? "Send answers" : (flow.current?.multiSelect == true ? "Confirm" : "Send")
    }

    private func advance(_ send: @escaping (Decision) -> Void) {
        if let decision = flow.advance() { send(decision) }
    }
}
