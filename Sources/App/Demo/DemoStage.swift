// DemoStage.swift — turns one DemoAction into changes in the stores, the way the real engine would.
//
// The real app has a SessionEngine that reacts to hook events. Demo mode has no agents and no
// hooks, so this small class plays the engine's part for the pretend sessions only: it edits
// their cards, adds and removes their requests, writes activity lines and sets the "pulse" that
// triggers confetti and auto-open.
//
// Two promises it keeps:
//   • It only ever touches sessions marked `isDemo` and requests / activity lines it created
//     itself. Real sessions in the same stores are never changed.
//   • If a demo card has disappeared (the user dismissed it), actions for it quietly do nothing.
//
// Main thread only, like everything that touches the stores.

import Foundation

final class DemoStage {
    private let env: AppEnv
    private let now: () -> Date

    /// Called for moments that would make a sound in real use. The app may connect this to its
    /// sound player; left nil, the demo is silent.
    var onCue: ((SoundCue) -> Void)?

    /// Requests the demo created, so they can be recognised later.
    private(set) var requestIDs = Set<UUID>()
    /// Activity lines the demo wrote, so exactly those can be removed again.
    private(set) var activityIDs = Set<UUID>()
    /// Roles the user said "no" to. Their part of the story is skipped until they get a new prompt.
    private var stoodDown = Set<DemoRole>()
    private(set) var usage: DemoUsage

    /// The activity log keeps at most this many lines (the same cap the real engine uses).
    private static let activityCap = 300
    /// A session card remembers at most this many recent tools.
    private static let recentToolsCap = 24

    init(env: AppEnv, now: @escaping () -> Date) {
        self.env = env
        self.now = now
        self.usage = DemoUsage(now: now())
    }

    // MARK: - Curtain up, curtain down

    /// Puts the opening scene on stage.
    func raiseCurtain() {
        removeDemoSessions()
        stoodDown.removeAll()
        usage = DemoUsage(now: now())
        env.sessions.sessions.append(contentsOf: DemoCast.openingSessions(now: now()))
        note("Demo started", "Demo mode is on. The sessions marked as examples are pretend; nothing is really running.")
        DemoScript.opening.forEach(perform)
    }

    /// Takes every trace of the demo out of the session store. Real sessions stay as they are.
    func clear() {
        let demoIDs = Set(env.sessions.sessions.filter { $0.isDemo }.map { $0.id })
        removeDemoSessions()
        if env.sessions.activity.contains(where: { activityIDs.contains($0.id) }) {
            env.sessions.activity.removeAll { activityIDs.contains($0.id) }
        }
        if let pulse = env.sessions.pulse, demoIDs.contains(pulse.sessionID) { env.sessions.pulse = nil }
        if let selected = env.ui.selectedSessionID, demoIDs.contains(selected) { env.ui.selectedSessionID = nil }
        if let focused = env.ui.focusedRequestID, requestIDs.contains(focused) { env.ui.focusedRequestID = nil }
        requestIDs.removeAll()
        activityIDs.removeAll()
        stoodDown.removeAll()
    }

    // MARK: - Actions from the script

    func perform(_ action: DemoAction) {
        switch action {
        case .startSession(let role): startSession(role)
        case .prompt(let role, let text): prompt(role, text)
        case .startTool(let role, let name, let summary): startTool(role, name: name, summary: summary)
        case .finishTool(let role, let succeeded): finishTool(role, succeeded: succeeded)
        case .ask(let role, let kind): ask(role, kind)
        case .autoResolve(let role): autoResolve(role)
        case .finish(let role, let message): finish(role, message: message)
        case .fail(let role, let error): fail(role, error: error)
        case .restart: restart()
        }
    }

    private func startSession(_ role: DemoRole) {
        guard session(role) == nil else { return }
        let session = DemoCast.session(role, now: now())
        env.sessions.sessions.append(session)
        usage.count(.sessionStarted)
        log(.incoming, "SessionStart", role, "A \(session.agent.displayName) session started in \(session.projectName)")
        pulse(.started, role)
        onCue?(.sessionStart)
    }

    private func prompt(_ role: DemoRole, _ text: String) {
        // A new prompt is a fresh start, even for a session the user said "no" to earlier.
        stoodDown.remove(role)
        guard pendingRequest(for: role) == nil else { return }
        let changed = update(role) { session in
            finishCurrentTool(&session, succeeded: true)
            session.state = .working
            session.lastPrompt = text
            if session.turnCount == 0 { session.title = text }
            session.turnCount += 1
            session.errorText = nil
            session.lastMessage = nil
        }
        if changed { log(.incoming, "UserPromptSubmit", role, "Prompt sent to \(shortName(role)): \(quoted(text))") }
    }

    private func startTool(_ role: DemoRole, name: String, summary: String) {
        // A session that is blocked on a request, or that was told "no", cannot be running tools.
        guard !stoodDown.contains(role), pendingRequest(for: role) == nil else { return }
        let call = ToolCall(id: UUID().uuidString, name: name, summary: summary, startedAt: now(), finishedAt: nil, succeeded: nil)
        let changed = update(role) { session in
            finishCurrentTool(&session, succeeded: true)
            session.currentTool = call
            session.recentTools.append(call)
            if session.recentTools.count > Self.recentToolsCap {
                session.recentTools.removeFirst(session.recentTools.count - Self.recentToolsCap)
            }
            session.toolCount += 1
            session.state = .runningTool
            // Every tool call uses a bit more of the context window.
            session.contextPercent = min(92, (session.contextPercent ?? 0) + 1.5)
        }
        guard changed else { return }
        usage.count(.toolCall)
        log(.incoming, "PreToolUse", role, "\(shortName(role)) is running \(name): \(summary)", tool: name)
    }

    private func finishTool(_ role: DemoRole, succeeded: Bool) {
        guard let tool = session(role)?.currentTool else { return }
        update(role) { session in
            finishCurrentTool(&session, succeeded: succeeded)
            if session.state == .runningTool { session.state = .working }
        }
        log(.incoming, "PostToolUse", role, succeeded ? "\(tool.name) finished" : "\(tool.name) failed", tool: tool.name)
    }

    private func ask(_ role: DemoRole, _ kind: RequestKind) {
        guard !stoodDown.contains(role), let session = session(role), pendingRequest(for: role) == nil else { return }
        let request = PendingRequest(sessionID: session.id, agent: session.agent, kind: kind, createdAt: now(), raw: .null)
        requestIDs.insert(request.id)
        env.sessions.pending.append(request)
        update(role) { session in
            finishCurrentTool(&session, succeeded: true)
            session.state = Self.waitingState(for: kind)
        }
        log(.incoming, "PermissionRequest", role, Self.describe(kind, asker: shortName(role)), tool: Self.toolName(of: kind))
        pulse(.attention, role)
        if case .permission = kind { onCue?(.needsApproval) } else { onCue?(.needsAnswer) }
    }

    private func autoResolve(_ role: DemoRole) {
        guard let request = pendingRequest(for: role) else { return }
        let decision: Decision
        switch request.kind {
        case .permission:
            decision = .allow
        case .question(let asked):
            // Pick the first option of every question.
            var answers: [String: String] = [:]
            for question in asked.questions { answers[question.text] = question.options.first?.label ?? "" }
            decision = .answer(answers)
        case .plan:
            decision = .approvePlan(acceptEdits: false)
        }
        resolve(request, with: decision, byUser: false)
    }

    private func finish(_ role: DemoRole, message: String) {
        guard !stoodDown.contains(role), pendingRequest(for: role) == nil, let session = session(role) else { return }
        update(role) { session in
            finishCurrentTool(&session, succeeded: true)
            session.state = .done
            session.lastMessage = message
            session.activeSubagents = 0
        }
        usage.count(.turnFinished)
        log(.incoming, "Stop", role, "\(shortName(role)) finished: \(session.title)")
        pulse(.done, role)
        onCue?(.done)
    }

    private func fail(_ role: DemoRole, error: String) {
        guard !stoodDown.contains(role), pendingRequest(for: role) == nil, session(role) != nil else { return }
        update(role) { session in
            finishCurrentTool(&session, succeeded: false)
            session.state = .failed
            session.errorText = error
            session.activeSubagents = 0
        }
        log(.incoming, "Error", role, "\(shortName(role)) stopped with an error: \(error)")
        pulse(.failed, role)
        onCue?(.failed)
    }

    private func restart() {
        // Withdraw whatever is still waiting, send the late arrivals home, reset everyone else.
        if env.sessions.pending.contains(where: { requestIDs.contains($0.id) }) {
            env.sessions.pending.removeAll { requestIDs.contains($0.id) }
        }
        stoodDown.removeAll()
        usage = DemoUsage(now: now())
        var sessions = env.sessions.sessions.filter { session in
            guard let role = DemoCast.role(of: session) else { return true }
            return DemoCast.openingRoles.contains(role)
        }
        for fresh in DemoCast.openingSessions(now: now()) {
            if let index = sessions.firstIndex(where: { $0.isDemo && $0.id == fresh.id }) {
                sessions[index] = fresh
            } else {
                sessions.append(fresh)
            }
        }
        env.sessions.sessions = sessions
        note("Demo restarted", "The demo story starts over from the beginning.")
        DemoScript.opening.forEach(perform)
    }

    // MARK: - Answers

    /// True for requests the demo created (whether or not they are still waiting).
    func owns(_ request: PendingRequest) -> Bool {
        requestIDs.contains(request.id) || env.sessions.session(id: request.sessionID)?.isDemo == true
    }

    /// Applies an answer to one of the demo's requests. `byUser` is false when the demo answers
    /// for a user who did not. Returns false (and does nothing) for a request that is not ours.
    @discardableResult
    func resolve(_ request: PendingRequest, with decision: Decision, byUser: Bool) -> Bool {
        guard owns(request) else { return false }
        // Already answered or withdrawn: ours, but there is nothing left to do.
        guard env.sessions.pending.contains(where: { $0.id == request.id }) else { return true }
        env.sessions.pending.removeAll { $0.id == request.id }

        let role = env.sessions.session(id: request.sessionID).flatMap(DemoCast.role(of:))
        let outcome = Self.outcome(of: decision)
        if let role {
            let next = env.sessions.pending(for: request.sessionID).first
            update(role) { session in
                if let next {
                    session.state = Self.waitingState(for: next.kind)
                } else if outcome == .refused, case .permission = request.kind {
                    session.state = .done
                    session.lastMessage = "Okay, I will not do that. Tell me how you would like to continue."
                } else {
                    session.state = .working
                }
            }
            if outcome == .refused { stoodDown.insert(role) }
        }

        if case .question = request.kind { usage.count(.questionAnswered) } else { usage.count(.approvalHandled) }
        let who = byUser ? "You" : "Nobody answered, so the demo"
        log(.outgoing, "Decision", role, "\(who) \(Self.describe(decision, for: request.kind))", agent: request.agent)
        if let role { pulse(outcome == .refused ? .denied : .approved, role) }
        if byUser { onCue?(outcome == .refused ? .denied : .approved) }
        return true
    }

    /// Removes one demo card (and anything waiting on it). Returns false for a real session.
    @discardableResult
    func dismiss(sessionID: String) -> Bool {
        guard env.sessions.session(id: sessionID)?.isDemo == true else { return false }
        env.sessions.pending.removeAll { $0.sessionID == sessionID && requestIDs.contains($0.id) }
        env.sessions.sessions.removeAll { $0.isDemo && $0.id == sessionID }
        return true
    }

    // MARK: - Usage

    /// Nudges the pretend usage numbers up a little.
    func tickUsage(activeSeconds: Int) {
        usage.tick(now: now(), activeSeconds: activeSeconds)
    }

    // MARK: - Small helpers

    private func session(_ role: DemoRole) -> Session? {
        let id = DemoCast.id(role)
        return env.sessions.sessions.first { $0.isDemo && $0.id == id }
    }

    private func pendingRequest(for role: DemoRole) -> PendingRequest? {
        let id = DemoCast.id(role)
        return env.sessions.pending.first { $0.sessionID == id && requestIDs.contains($0.id) }
    }

    /// Edits one demo session in place and stamps the time. Returns false if its card is gone.
    @discardableResult
    private func update(_ role: DemoRole, _ change: (inout Session) -> Void) -> Bool {
        let id = DemoCast.id(role)
        guard let index = env.sessions.sessions.firstIndex(where: { $0.isDemo && $0.id == id }) else { return false }
        var session = env.sessions.sessions[index]
        let before = session.state
        change(&session)
        let time = now()
        if session.state != before { session.stateSince = time }
        session.lastEventAt = time
        env.sessions.sessions[index] = session
        return true
    }

    /// Marks the tool a session is running (if any) as finished, on the card and in its history.
    private func finishCurrentTool(_ session: inout Session, succeeded: Bool) {
        guard let tool = session.currentTool else { return }
        if let index = session.recentTools.lastIndex(where: { $0.id == tool.id }) {
            session.recentTools[index].finishedAt = now()
            session.recentTools[index].succeeded = succeeded
        }
        session.currentTool = nil
    }

    private func removeDemoSessions() {
        let demoIDs = Set(env.sessions.sessions.filter { $0.isDemo }.map { $0.id })
        if env.sessions.pending.contains(where: { requestIDs.contains($0.id) || demoIDs.contains($0.sessionID) }) {
            env.sessions.pending.removeAll { requestIDs.contains($0.id) || demoIDs.contains($0.sessionID) }
        }
        if !demoIDs.isEmpty { env.sessions.sessions.removeAll { $0.isDemo } }
    }

    private func pulse(_ kind: Pulse.Kind, _ role: DemoRole) {
        env.sessions.pulse = Pulse(kind: kind, sessionID: DemoCast.id(role), at: now())
    }

    private func note(_ title: String, _ summary: String) {
        log(.note, title, nil, summary)
    }

    /// Adds one line to the activity log (newest first), if the user keeps that log.
    private func log(_ direction: ActivityEntry.Direction, _ event: String, _ role: DemoRole?, _ summary: String,
                     tool: String? = nil, agent: AgentKind? = nil) {
        guard env.settings.activityLogEnabled else { return }
        var fields: [String: JSONValue] = ["demo": true]
        if direction == .incoming { fields["hook_event_name"] = .string(event) }
        if let tool { fields["tool_name"] = .string(tool) }
        let agentName = (role.map(DemoCast.agent) ?? agent)?.rawValue ?? "perch"
        let entry = ActivityEntry(at: now(), direction: direction, agent: agentName, event: event,
                                  sessionID: role.map(DemoCast.id), summary: summary, raw: JSONValue.object(fields).serialized())
        activityIDs.insert(entry.id)
        var activity = env.sessions.activity
        activity.insert(entry, at: 0)
        if activity.count > Self.activityCap { activity.removeLast(activity.count - Self.activityCap) }
        env.sessions.activity = activity
        // Forget ids of lines that have since scrolled out of the log.
        if activityIDs.count > Self.activityCap * 2 {
            activityIDs.formIntersection(Set(activity.map { $0.id }))
        }
    }

    private func shortName(_ role: DemoRole) -> String { Self.shortName(DemoCast.agent(role)) }

    private func quoted(_ text: String) -> String { "\u{201C}\(Self.clipped(text, to: 70))\u{201D}" }

    // MARK: - Wording (pure)

    private enum Outcome { case accepted, refused, handedBack }

    private static func outcome(of decision: Decision) -> Outcome {
        switch decision {
        case .allow, .allowAlways, .answer, .approvePlan: return .accepted
        case .deny, .rejectPlan: return .refused
        case .passToTerminal: return .handedBack
        }
    }

    static func waitingState(for kind: RequestKind) -> SessionState {
        switch kind {
        case .permission: return .needsApproval
        case .question: return .needsAnswer
        case .plan: return .planReview
        }
    }

    static func shortName(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini"
        }
    }

    private static func toolName(of kind: RequestKind) -> String {
        switch kind {
        case .permission(let permission): return permission.toolName
        case .question: return "AskUserQuestion"
        case .plan: return "ExitPlanMode"
        }
    }

    /// "Claude wants to run `rm -rf build`", "Claude is asking: Which framework…".
    static func describe(_ kind: RequestKind, asker: String) -> String {
        switch kind {
        case .permission(let permission):
            return "\(asker) wants to \(verb(for: permission)) \(subject(of: permission))"
        case .question(let asked):
            return "\(asker) is asking: \(clipped(asked.questions.first?.text ?? "a question", to: 80))"
        case .plan:
            return "\(asker) has a plan ready for you to review"
        }
    }

    /// The second half of "You …" / "Nobody answered, so the demo …".
    static func describe(_ decision: Decision, for kind: RequestKind) -> String {
        let thing: String
        switch kind {
        case .permission(let permission): thing = subject(of: permission)
        case .question: thing = "the question"
        case .plan: thing = "the plan"
        }
        switch decision {
        case .allow: return "allowed \(thing)"
        case .allowAlways: return "allowed \(thing) and chose to always allow it"
        case .deny: return "denied \(thing)"
        case .answer(let answers):
            let picked = answers.keys.sorted().compactMap { answers[$0] }.filter { !$0.isEmpty }
            return picked.isEmpty ? "answered the question" : "answered: \(clipped(picked.joined(separator: "; "), to: 80))"
        case .approvePlan(let acceptEdits): return acceptEdits ? "approved the plan and turned on auto-accept for edits" : "approved the plan"
        case .rejectPlan(let feedback): return feedback.isEmpty ? "sent the plan back" : "sent the plan back with feedback"
        case .passToTerminal: return "chose to answer in the terminal"
        }
    }

    private static func verb(for permission: PermissionRequest) -> String {
        switch permission.toolName.lowercased() {
        case "bash", "shell": return "run"
        case "edit", "write", "multiedit", "apply_patch": return "edit"
        case "read": return "read"
        default: return "use \(permission.toolName) on"
        }
    }

    private static func subject(of permission: PermissionRequest) -> String {
        "`\(clipped(permission.detail.isEmpty ? permission.toolName : permission.detail, to: 60))`"
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit - 1)) + "\u{2026}" : oneLine
    }
}
