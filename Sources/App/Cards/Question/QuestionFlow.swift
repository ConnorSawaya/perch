// QuestionFlow.swift — the state of a question card while the user works through it (pure, no UI).
//
// An agent can ask several questions at once. The card shows one at a time; this type remembers
// which one is showing, what has been picked or typed for each, and builds the final answer.
//
// The rules:
//   - Single-select: at most one option is picked. Opening "Other…" un-picks it (Other is one
//     more choice); picking an option closes Other.
//   - Multi-select: any number of options, and Other adds one more answer to the list.
//   - A question counts as answered when something is picked or something is typed in Other.
//   - The "simple" case — exactly one single-select question — is answered by one click.
//   - The answer sent back is keyed by the question's text; multi-select labels are joined with ", ".

import Foundation

struct QuestionFlow: Equatable {
    let questions: [Question]
    /// Position of the question on show.
    private(set) var step = 0
    /// Picked options per question, as positions in that question's option list.
    private(set) var picks: [Int: Set<Int>] = [:]
    /// What was typed into "Other…" per question.
    private(set) var typed: [Int: String] = [:]
    /// Questions whose "Other…" field is open.
    private(set) var otherOpen: Set<Int> = []

    init(questions: [Question]) {
        self.questions = questions
    }

    // MARK: Where we are

    var current: Question? { questions.indices.contains(step) ? questions[step] : nil }
    var isFirst: Bool { step == 0 }
    var isLast: Bool { step >= questions.count - 1 }
    /// One single-select question: a click on an option is the whole answer.
    var isSimple: Bool { questions.count == 1 && questions[0].multiSelect == false }

    func isPicked(_ option: Int) -> Bool { picks[step]?.contains(option) ?? false }
    var isOtherOpen: Bool { otherOpen.contains(step) }
    var otherText: String { typed[step] ?? "" }

    /// Questions that have an answer so far, by position.
    var answered: Set<Int> { Set(questions.indices.filter { answer(at: $0) != nil }) }
    var canAdvance: Bool { answer(at: step) != nil }

    // MARK: Changing things

    /// Picks (or, for multi-select, toggles) an option of the question on show.
    /// Returns the finished decision when that click answers everything (the simple case).
    @discardableResult
    mutating func pick(_ option: Int) -> Decision? {
        guard let question = current, question.options.indices.contains(option) else { return nil }
        if question.multiSelect {
            var chosen = picks[step] ?? []
            if chosen.contains(option) { chosen.remove(option) } else { chosen.insert(option) }
            picks[step] = chosen.isEmpty ? nil : chosen
            return nil
        }
        picks[step] = [option]
        otherOpen.remove(step)
        return isSimple ? decision() : nil
    }

    /// Opens or closes the "Other…" field of the question on show.
    mutating func setOtherOpen(_ open: Bool) {
        guard let question = current else { return }
        if open {
            otherOpen.insert(step)
            if !question.multiSelect { picks[step] = nil }
        } else {
            otherOpen.remove(step)
        }
    }

    mutating func setOtherText(_ text: String) {
        guard current != nil else { return }
        typed[step] = text
    }

    /// Moves to the next question, or — on the last one — returns the finished decision.
    /// Does nothing while the question on show has no answer.
    mutating func advance() -> Decision? {
        guard canAdvance else { return nil }
        if isLast { return decision() }
        step += 1
        return nil
    }

    mutating func back() {
        if step > 0 { step -= 1 }
    }

    /// Jumps straight to a question (for drawing a card part-way through).
    mutating func show(step wanted: Int) {
        if questions.indices.contains(wanted) { step = wanted }
    }

    // MARK: Answers

    /// The answer to one question as it would be sent, or nil while it has none.
    func answer(at index: Int) -> String? {
        guard questions.indices.contains(index) else { return nil }
        let question = questions[index]
        let other = otherOpen.contains(index) ? Self.tidy(typed[index]) : nil
        let labels = (picks[index] ?? []).sorted()
            .filter { question.options.indices.contains($0) }
            .map { question.options[$0].label }
        if question.multiSelect {
            let all = labels + (other.map { [$0] } ?? [])
            return all.isEmpty ? nil : all.joined(separator: ", ")
        }
        return other ?? labels.first
    }

    /// The decision to send, or nil until every question has an answer.
    func decision() -> Decision? {
        var answers: [String: String] = [:]
        for index in questions.indices {
            guard let answer = answer(at: index) else { return nil }
            answers[questions[index].text] = answer
        }
        return answers.isEmpty ? nil : .answer(answers)
    }

    private static func tidy(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
