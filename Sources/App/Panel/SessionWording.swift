// SessionWording.swift — the plain-English words and icons Perch uses for session states.
//
// Everything a user reads about a session's state comes from here, so the pill, the panel
// header and the cards never disagree ("Thinking" in one place, "Working" in another).
// These are pure functions: data in, words out.

import Foundation

enum SessionWording {
    /// The label on a session card's state chip.
    static func label(for state: SessionState) -> String {
        switch state {
        case .idle: return "Idle"
        case .working: return "Thinking"
        case .runningTool: return "Running"
        case .needsApproval: return "Needs approval"
        case .needsAnswer: return "Has a question"
        case .planReview: return "Plan ready"
        case .compacting: return "Tidying up"
        case .done: return "Done"
        case .failed: return "Failed"
        case .ended: return "Closed"
        }
    }

    /// One short word for the pill, where there is room for about eight letters.
    /// While a tool runs, the tool's own name ("Bash", "Edit") is the most useful word.
    static func pillWord(for session: Session) -> String {
        switch session.state {
        case .idle: return "Idle"
        case .working: return "Thinking"
        case .runningTool:
            let name = session.currentTool?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty || name.count > 9 ? "Working" : name
        case .needsApproval: return "Approve?"
        case .needsAnswer: return "Question"
        case .planReview: return "Plan"
        case .compacting: return "Tidying"
        case .done: return "Done"
        case .failed: return "Failed"
        case .ended: return "Closed"
        }
    }

    /// An SF Symbol for a state, used where there is no room for the mascot or a word.
    static func symbol(for state: SessionState) -> String {
        switch state {
        case .idle: return "moon.zzz.fill"
        case .working: return "sparkle"
        case .runningTool: return "hammer.fill"
        case .needsApproval: return "hand.raised.fill"
        case .needsAnswer: return "questionmark.bubble.fill"
        case .planReview: return "list.clipboard.fill"
        case .compacting: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .ended: return "xmark.circle"
        }
    }

    /// An SF Symbol for a tool, guessed from its name. Unknown tools get a generic wrench.
    static func toolSymbol(_ toolName: String) -> String {
        let name = toolName.lowercased()
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
        if has("bash", "shell", "exec", "command", "terminal") { return "terminal.fill" }
        if has("edit", "write", "patch", "replace", "notebook") { return "pencil" }
        if has("read", "view", "cat") { return "doc.text" }
        if has("grep", "glob", "search", "find", "ls") { return "magnifyingglass" }
        if has("web", "fetch", "browser", "http") { return "globe" }
        if has("task", "agent") { return "person.2.fill" }
        if has("todo", "plan") { return "checklist" }
        if has("mcp") { return "puzzlepiece.extension.fill" }
        return "wrench.and.screwdriver.fill"
    }

    /// The panel's one-line summary, most urgent part first. `detail` may be dropped when space is tight.
    static func summary(of sessions: [Session]) -> (headline: String, detail: String?) {
        let attention = sessions.filter { $0.state.needsAttention }.count
        let busy = sessions.filter { $0.state.isBusy }.count
        let failed = sessions.filter { $0.state == .failed }.count
        let done = sessions.filter { $0.state == .done }.count

        if sessions.isEmpty { return ("No sessions", nil) }
        if attention > 0 {
            return (attention == 1 ? "1 needs you" : "\(attention) need you", busy > 0 ? "\(busy) working" : nil)
        }
        if busy > 0 { return ("\(busy) working", done > 0 ? "\(done) done" : nil) }
        if failed > 0 { return ("\(failed) failed", done > 0 ? "\(done) done" : nil) }
        if done > 0 { return (done == sessions.count ? "All done" : "\(done) done", nil) }
        return ("All quiet", sessions.count == 1 ? "1 session" : "\(sessions.count) sessions")
    }

    /// What the bottom line of a session card says. See `statusLine(for:pending:)`.
    struct StatusLine: Equatable {
        enum Tone { case normal, quiet, success, danger, attention }
        var symbol: String
        var text: String
        var tone: Tone = .normal
        /// Show in the code font (commands and file paths).
        var isCode = false
        /// The thing is happening right now: draw the moving shimmer.
        var isLive = false
        /// How many lines the text may use.
        var lines = 1
    }

    /// The most useful single thing to say about a session right now.
    /// `pending` is the request the session is blocked on, when there is one.
    static func statusLine(for session: Session, pending: PendingRequest?) -> StatusLine {
        switch session.state {
        case .idle:
            return StatusLine(symbol: "moon.zzz.fill", text: "Waiting for a prompt", tone: .quiet)
        case .working:
            return StatusLine(symbol: "sparkle", text: "Thinking…", isLive: true)
        case .runningTool:
            if let tool = session.currentTool, let text = meaningful(tool.summary) ?? meaningful(tool.name) {
                return StatusLine(symbol: toolSymbol(tool.name), text: text, isCode: true, isLive: true)
            }
            return StatusLine(symbol: "hammer.fill", text: "Running a tool…", isLive: true)
        case .needsApproval, .needsAnswer, .planReview:
            return attentionLine(for: session.state, pending: pending)
        case .compacting:
            return StatusLine(symbol: "arrow.triangle.2.circlepath", text: "Summarising the conversation to make room…", isLive: true)
        case .done:
            if let message = meaningful(session.lastMessage) {
                return StatusLine(symbol: "checkmark.circle.fill", text: message, tone: .success, lines: 2)
            }
            return StatusLine(symbol: "checkmark.circle.fill", text: "Finished — waiting for your next prompt", tone: .success)
        case .failed:
            return StatusLine(symbol: "exclamationmark.triangle.fill", text: meaningful(session.errorText) ?? "Something went wrong",
                              tone: .danger, lines: 2)
        case .ended:
            return StatusLine(symbol: "xmark.circle", text: "Session closed", tone: .quiet)
        }
    }

    private static func attentionLine(for state: SessionState, pending: PendingRequest?) -> StatusLine {
        switch pending?.kind {
        case .permission(let request):
            let parts = [meaningful(request.summary), meaningful(request.detail)].compactMap { $0 }
            return StatusLine(symbol: "hand.raised.fill", text: parts.isEmpty ? "Wants your approval" : parts.joined(separator: ": "),
                              tone: .attention)
        case .question(let request):
            return StatusLine(symbol: "questionmark.bubble.fill",
                              text: meaningful(request.questions.first?.text) ?? "Asked you a question", tone: .attention)
        case .plan:
            return StatusLine(symbol: "list.clipboard.fill", text: "Wants you to review its plan", tone: .attention)
        case .none:
            // No request card (the agent is showing its own prompt): point at the terminal.
            switch state {
            case .needsAnswer:
                return StatusLine(symbol: "questionmark.bubble.fill", text: "Asked a question — answer in the terminal", tone: .attention)
            case .planReview:
                return StatusLine(symbol: "list.clipboard.fill", text: "Has a plan ready — review it in the terminal", tone: .attention)
            default:
                return StatusLine(symbol: "hand.raised.fill", text: "Waiting for your approval in the terminal", tone: .attention)
            }
        }
    }

    /// Collapses line breaks and runs of spaces so multi-line text reads as one tidy line.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The text tidied onto one line, or nil when there is nothing to read (missing, empty, only spaces).
    static func meaningful(_ text: String?) -> String? {
        guard let text else { return nil }
        let tidy = oneLine(text)
        return tidy.isEmpty ? nil : tidy
    }

    /// What to call a session: its title, else its folder, else the agent's name.
    static func title(for session: Session) -> String {
        meaningful(session.title) ?? meaningful(session.projectName) ?? "\(session.agent.displayName) session"
    }
}
