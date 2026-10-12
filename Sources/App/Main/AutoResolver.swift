// AutoResolver.swift — answers every request by itself. FOR END-TO-END TESTS ONLY.
//
// It exists only when Perch is started with PERCH_TEST_AUTORESOLVE=allow (or deny), which no
// normal launch does. A test then gets the same result as a person clicking Allow or Deny on
// every card, so the whole path — helper, socket, adapter, engine, reply — can be proven with a
// real agent and nobody at the keyboard.
//
// Each request waits a short moment first, as it would for a person. That also leaves time for a
// test to see the request waiting, or to take the helper away before the answer comes.

import Foundation
import Combine

final class AutoResolver {
    private let mode: LaunchOptions.AutoResolve
    private let delay: TimeInterval
    private let store: SessionStore
    private let resolve: (PendingRequest, Decision) -> Void
    private var scheduled: Set<UUID> = []
    private var subscription: AnyCancellable?
    /// How many requests have been answered so far.
    private(set) var answered = 0

    static let denyMessage = "Denied automatically by Perch's end-to-end test."

    init(mode: LaunchOptions.AutoResolve, delay: TimeInterval, store: SessionStore,
         resolve: @escaping (PendingRequest, Decision) -> Void) {
        self.mode = mode
        self.delay = delay
        self.store = store
        self.resolve = resolve
        subscription = store.$pending.sink { [weak self] pending in self?.schedule(pending) }
    }

    private func schedule(_ pending: [PendingRequest]) {
        for request in pending where !request.sessionID.isEmpty && scheduled.insert(request.id).inserted {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.answer(request.id) }
        }
        // Forget requests that are gone, so the set cannot grow for ever.
        scheduled.formIntersection(Set(pending.map(\.id)))
    }

    private func answer(_ id: UUID) {
        // Answered or withdrawn in the meantime (the helper went away): nothing to do.
        guard let request = store.pending.first(where: { $0.id == id }) else { return }
        answered += 1
        resolve(request, Self.decision(for: request.kind, mode: mode))
    }

    /// What "allow" and "deny" mean for each kind of request.
    static func decision(for kind: RequestKind, mode: LaunchOptions.AutoResolve) -> Decision {
        switch (kind, mode) {
        case (.permission, .allow):
            return .allow
        case (.question(let request), .allow):
            // The first option of every question (or a plain "Yes" where there are none).
            var answers: [String: String] = [:]
            for question in request.questions { answers[question.text] = question.options.first?.label ?? "Yes" }
            return .answer(answers)
        case (.plan, .allow):
            return .approvePlan(acceptEdits: false)
        case (.plan, .deny):
            return .rejectPlan(feedback: denyMessage)
        case (.permission, .deny), (.question, .deny):
            return .deny(message: denyMessage)
        }
    }
}
