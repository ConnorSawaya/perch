// PlanCardView.swift — the card for "the agent wrote a plan: go ahead with it?".
//
//   ┌──────────────────────────────────────────────────────────────────┐
//   │ [C]  ▤ Plan ready for review            [refactor-engine.md]  4s │
//   │      perch · Refactor the session engine                         │
//   │  ┌────────────────────────────────────────────────────────────┐  │
//   │  │ Refactor the session engine                                │  │  the plan, drawn from
//   │  │ GOAL                                                       │  │  its Markdown; scrolls
//   │  │ Split the 600-line SessionEngine into …                    │  │  when it is long
//   │  └────────────────────────────────────────────────────────────┘  │
//   │  [ Approve ⌘Y ] [ Approve + auto-accept edits ] [ Request changes… ]   Answer in terminal ⌘T
//   └──────────────────────────────────────────────────────────────────┘
//
// What each button sends:
//   Approve                       → Decision.approvePlan(acceptEdits: false)  (still asks before edits)
//   Approve + auto-accept edits   → Decision.approvePlan(acceptEdits: true)
//   Request changes…              → opens a text field; Decision.rejectPlan(feedback: what you typed)
//   Answer in terminal            → Decision.passToTerminal

import SwiftUI

struct PlanCardView: View {
    private let request: PendingRequest
    private let session: Session?

    @EnvironmentObject private var settings: AppSettings
    @State private var feedbackOpen: Bool
    @State private var feedback: String

    /// - Parameter preview: Draws the card part-way through being used. Only for snapshots; the app leaves it out.
    init(request: PendingRequest, session: Session?, preview: CardsPreview = CardsPreview()) {
        self.request = request
        self.session = session
        self._feedbackOpen = State(initialValue: preview.noteOpen)
        self._feedback = State(initialValue: preview.noteText)
    }

    var body: some View {
        if case .plan(let plan) = request.kind {
            let theme = Theme.current(settings)
            RequestCardShell(request: request, session: session, symbol: "list.clipboard.fill",
                             title: "Plan ready for review", tint: theme.ask, tag: fileTag(plan)) { send in
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    planBox(plan, theme)
                    if feedbackOpen {
                        feedbackEditor(theme, send)
                    } else {
                        buttons(theme, send)
                    }
                }
            }
        }
    }

    /// The plan file's name, when the agent saved the plan to a file.
    private func fileTag(_ plan: PlanRequest) -> RequestCardTag? {
        guard let path = CardsWording.tidy(plan.filePath) else { return nil }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        return RequestCardTag(text: name.count > 26 ? "…" + name.suffix(25) : name, systemImage: "doc.text", monospaced: true)
    }

    private func planBox(_ plan: PlanRequest, _ theme: Theme) -> some View {
        CardsScrollBox(maxHeight: theme.scaled(236)) {
            PlanMarkdownView(markdown: plan.markdown)
                .equatable()
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, 11)
        }
        // The last lines fade out, hinting that a long plan continues below.
        .mask(VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom).frame(height: 11)
        })
        .background(CardBackground(isSunken: true, cornerRadius: Theme.Radius.control))
    }

    // MARK: Buttons

    private func buttons(_ theme: Theme, _ send: @escaping (Decision) -> Void) -> some View {
        CardsActionRow {
            Button { send(.approvePlan(acceptEdits: false)) } label: {
                CardsButtonLabel("Approve", keys: ["⌘", "Y"], onAccent: true)
            }
            .buttonStyle(.perch(.primary))
            .help("Go ahead with the plan. \(request.agent.displayName) still asks before each edit.")
            Button("Approve + auto-accept edits") { send(.approvePlan(acceptEdits: true)) }
                .buttonStyle(.perch(.secondary))
                .help("Go ahead, and let \(request.agent.displayName) edit files without asking each time")
            Button("Request changes…") { feedbackOpen = true }
                .buttonStyle(.perch(.secondary))
                .help("Send the plan back with a note about what to change")
        } extra: {
            Button { send(.passToTerminal) } label: {
                CardsButtonLabel("Answer in terminal", systemImage: "terminal", keys: ["⌘", "T"])
            }
            .buttonStyle(.perch(.ghost, size: .small))
            .help("Perch steps aside and \(request.agent.displayName) shows its own prompt")
        }
    }

    // MARK: Request changes

    private func feedbackEditor(_ theme: Theme, _ send: @escaping (Decision) -> Void) -> some View {
        let note = CardsWording.tidy(feedback)
        let sendFeedback = { send(.rejectPlan(feedback: note ?? "")) }
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            CardsTextField("What should \(request.agent.displayName) change?", text: $feedback, multiline: true,
                           onSubmit: sendFeedback)
            CardsActionRow {
                if note == nil {
                    Button(action: sendFeedback) { CardsButtonLabel("Reject without a note") }
                        .buttonStyle(.perch(.destructive))
                } else {
                    Button(action: sendFeedback) { CardsButtonLabel("Send feedback", keys: ["↩"], onAccent: true) }
                        .buttonStyle(.perch(.primary))
                }
                Button("Cancel") { feedbackOpen = false }
                    .buttonStyle(.perch(.ghost))
            }
        }
    }
}
