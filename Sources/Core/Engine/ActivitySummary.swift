// ActivitySummary.swift — turns events and decisions into one plain-English line each.
//
// The activity log ("How it works" in Settings, and the Activity tab) shows everything that
// passes through Perch. These sentences are what make that log readable by someone who has never
// heard of a hook: "Claude wants to run `npm test`", "You allowed it", "Finished: all tests pass".
// The same wording is reused for notification texts. Everything here is a pure function.

import Foundation

enum ActivitySummary {
    // MARK: - Incoming events

    static func describe(_ event: NormalizedEvent) -> String {
        let agent = EngineFacts.name(event.agent)
        switch event.event {
        case .sessionStarted(_, _, let source):
            let place = folderPhrase(event.context.cwd)
            switch (source ?? "").lowercased() {
            case "resume": return "\(agent) picked up an earlier session\(place)"
            case "clear": return "\(agent) started a fresh conversation\(place)"
            case "compact": return "\(agent) reloaded the session after tidying its memory"
            default: return "\(agent) started a session\(place)"
            }
        case .sessionEnded(let reason):
            switch (reason ?? "").lowercased() {
            case "prompt_input_exit", "exit", "quit": return "The \(agent) session was closed"
            case "clear": return "\(agent) cleared the conversation"
            case "resume": return "\(agent) is switching to another session"
            case "logout": return "The \(agent) session ended because you signed out"
            default: return "The \(agent) session ended"
            }
        case .promptSubmitted(let text):
            guard let line = EngineText.firstLine(text) else { return "You sent \(agent) a prompt" }
            return "You asked \(agent): \(quoted(line))"
        case .toolStarted(let call):
            let summary = call.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty || summary == call.name { return "\(agent) is using \(call.name)" }
            return "\(agent) is using \(call.name): \(EngineText.clip(EngineText.firstLine(summary) ?? summary, to: 100))"
        case .toolFinished(_, let name, let succeeded):
            return succeeded ? "\(name) finished" : "\(name) did not succeed"
        case .permissionRequested(let request):
            return permissionLine(request, agent: agent)
        case .questionAsked(let request):
            return questionLine(request, agent: agent)
        case .planProposed:
            return "\(agent) wrote a plan and is waiting for you to review it"
        case .notification(let kind, let message):
            switch kind {
            case EngineNotificationKind.permissionPrompt: return "\(agent) is still waiting for your permission"
            case EngineNotificationKind.idlePrompt: return "\(agent) is waiting for your next prompt"
            default:
                guard let line = EngineText.firstLine(message) else { return "\(agent) sent a notice (\(kind))" }
                return "\(agent) says: \(EngineText.clip(line, to: 120))"
            }
        case .turnFinished(let lastMessage, let backgroundWork):
            if backgroundWork { return "\(agent) replied; background tasks are still running" }
            return finishedLine(lastMessage)
        case .turnFailed(let error):
            return "Stopped with an error: \(EngineText.clip(EngineText.firstLine(error) ?? "unknown error", to: 140))"
        case .subagentStarted(_, let type):
            if let type, !type.isEmpty { return "\(agent) started a helper agent (\(type))" }
            return "\(agent) started a helper agent"
        case .subagentStopped:
            return "A helper agent finished"
        case .compactionStarted:
            return "\(agent) is tidying its memory to free up room"
        case .compactionFinished:
            return "\(agent) finished tidying its memory"
        case .usageUpdated(let contextPercent, let windows, _, _):
            var parts: [String] = []
            if let contextPercent { parts.append("memory \(Int(contextPercent.rounded()))% full") }
            parts += windows.map { "\($0.label) \(Int($0.usedPercent.rounded()))% used" }
            return parts.isEmpty ? "Usage numbers updated" : "Usage update: " + parts.joined(separator: ", ")
        case .metadata(let title, let model, let gitBranch, let permissionMode):
            var parts: [String] = []
            if let title, !title.isEmpty { parts.append("title \(quoted(title))") }
            if let model, !model.isEmpty { parts.append("model \(model)") }
            if let gitBranch, !gitBranch.isEmpty { parts.append("branch \(gitBranch)") }
            if let permissionMode, !permissionMode.isEmpty { parts.append("mode \(permissionMode)") }
            return parts.isEmpty ? "Session details updated" : "Session details: " + parts.joined(separator: ", ")
        }
    }

    /// "Finished: all tests pass" — the first line of the agent's last message.
    static func finishedLine(_ lastMessage: String?) -> String {
        guard let message = lastMessage, let line = EngineText.firstLine(message) else { return "Finished its turn" }
        return "Finished: \(EngineText.clip(line, to: 140))"
    }

    private static func permissionLine(_ request: PermissionRequest, agent: String) -> String {
        let detail = EngineText.firstLine(request.detail).map { EngineText.clip($0, to: 100) }
        let summary = request.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var line: String
        if summary.isEmpty {
            line = request.toolName.isEmpty ? "\(agent) is asking for permission" : "\(agent) wants to use \(request.toolName)"
        } else {
            line = "\(agent) wants to \(lowercasedFirst(summary))"
        }
        if let detail { line += ": `\(detail)`" }
        if request.isDangerous { line += " (worth a second look)" }
        return line
    }

    private static func questionLine(_ request: QuestionRequest, agent: String) -> String {
        guard let first = request.questions.first, let text = EngineText.firstLine(first.text) else { return "\(agent) has a question for you" }
        let more = request.questions.count > 1 ? " (and \(request.questions.count - 1) more)" : ""
        return "\(agent) asks: \(quoted(text))\(more)"
    }

    // MARK: - Outgoing decisions

    static func describe(_ decision: Decision, for request: PendingRequest) -> String {
        switch decision {
        case .allow:
            return "You allowed it"
        case .allowAlways(let suggestionID):
            if case .permission(let permission) = request.kind,
               let suggestion = permission.suggestions.first(where: { $0.id == suggestionID }), !suggestion.label.isEmpty {
                return "You allowed it and chose \(quoted(suggestion.label))"
            }
            return "You allowed it and asked not to be asked again"
        case .deny(let message):
            if let line = message.flatMap(EngineText.firstLine) { return "You denied it: \(quoted(line))" }
            return "You denied it"
        case .answer(let answers):
            let pairs = answers.sorted { $0.key < $1.key }.map { "\(EngineText.clip($0.key, to: 40)) → \(EngineText.clip($0.value, to: 40))" }
            return pairs.isEmpty ? "You answered" : "You answered: " + pairs.joined(separator: "; ")
        case .approvePlan(let acceptEdits):
            return acceptEdits ? "You approved the plan and let it edit files without asking" : "You approved the plan"
        case .rejectPlan(let feedback):
            if let line = EngineText.firstLine(feedback) { return "You sent the plan back: \(quoted(line))" }
            return "You sent the plan back"
        case .passToTerminal:
            return "You chose to answer in the terminal"
        }
    }

    // MARK: - Notification texts

    static func attentionTitle(_ kind: RequestKind, agent: AgentKind) -> String {
        switch kind {
        case .permission: return "\(EngineFacts.name(agent)) needs your approval"
        case .question: return "\(EngineFacts.name(agent)) has a question"
        case .plan: return "\(EngineFacts.name(agent)) has a plan to review"
        }
    }

    static func attentionBody(_ kind: RequestKind, session: Session) -> String {
        let project = session.projectName
        let what: String
        switch kind {
        case .permission(let request):
            what = EngineText.firstLine(request.detail) ?? EngineText.firstLine(request.summary) ?? request.toolName
        case .question(let request):
            what = request.questions.first.flatMap { EngineText.firstLine($0.text) } ?? "It is waiting for your answer"
        case .plan(let request):
            what = EngineText.firstLine(request.markdown) ?? "It is waiting for your review"
        }
        let line = EngineText.clip(what, to: 140)
        if project.isEmpty { return line }
        return line.isEmpty ? project : "\(project): \(line)"
    }

    // MARK: - Raw payloads

    /// The original payload as text for the log, cut to about 4 KB. Empty when there was none.
    static func rawText(_ raw: JSONValue) -> String {
        raw.isNull ? "" : EngineText.clipBytes(raw.serialized())
    }

    // MARK: - Helpers

    private static func quoted(_ text: String) -> String { "\u{201C}\(EngineText.clip(text, to: 80))\u{201D}" }

    private static func folderPhrase(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "" : " in \(name)"
    }

    /// "Run a shell command" -> "run a shell command", but "URL fetch" stays as it is.
    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        let second = text.dropFirst().first
        if let second, second.isUppercase { return text }
        return first.lowercased() + text.dropFirst()
    }
}
