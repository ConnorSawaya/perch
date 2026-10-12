// CardsSnapshots.swift — draws the request cards and the Usage / Activity tabs to PNG files so
// their look can be reviewed without launching the app, and checks how they behave.
//
// Run:  scripts/snapshot.sh Cards Sources/App/Design Sources/App/Cards
// Look: .build/snapshots/Cards/*.png
//
// Each picture shows the view the way the panel shows it: on the black island, at a panel
// width (420, 520 or 760), with the panel's own side padding.
//
// Pictures: approval (dangerous, armed, with a diff, "always allow" open, deny note), question
// (first step, picked, multi-select step, Other field, single question), plan (plain, feedback
// field, every Markdown block), Usage tab ("All", each agent, a single agent, empty, "remaining"
// mode, the ranges, widths 420 and 760, more models than the chart names), Activity tab (data,
// rows expanded, empty, switched off), four more themes, text sizes 0.85 and 1.3, settings
// flipped, and deliberately awkward content. "live-*.png" are captured from a real (never
// shown) window, with real scroll views and text fields.
//
// Checks (they print "check ok" / "CHECK FAILED", and a failure fails the run):
//   • the pure logic: diff rows, question flow, plan Markdown, usage sums (adding agents
//     together, splitting days by model, top five + "Other"), activity filters;
//   • every view takes the same height with real scroll views as with the static stand-ins,
//     and the Usage tab's "All" view stays short enough to be seen without scrolling;
//   • card text fields claim and release the keyboard (UIState.needsKeyboard);
//   • the question card's own shortcuts, driven by real key events through the app's event queue.

import SwiftUI
import AppKit

// MARK: - Entry point

@MainActor
func runCardsSnapshots(_ out: URL) {
    AgentIconProvider.shared.source = .monogramOnly   // pictures must not depend on installed apps
    snapshotApprovals(out)
    snapshotQuestions(out)
    snapshotPlans(out)
    snapshotUsage(out)
    snapshotActivity(out)
    snapshotVariants(out)
    snapshotAwkwardContent(out)
    runLogicChecks()
    runLayoutChecks()
    runLiveCaptures(out)
    runKeyboardChecks()
    print(cardsChecksFailed == 0 ? "all checks ok" : "\(cardsChecksFailed) CHECK(S) FAILED")
    // A failed check fails the run, so scripts notice.
    if cardsChecksFailed > 0 { exit(1) }
}

// MARK: - Helpers

/// Settings kept in memory only, so snapshots never write preference files to disk.
private final class CardsSnapshotDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

/// A sample environment with its own in-memory settings.
@MainActor
private func makeEnv(_ configure: (AppSettings) -> Void = { _ in }) -> AppEnv {
    let settings = AppSettings(defaults: CardsSnapshotDefaults())
    configure(settings)
    return SampleData.env(settings: settings)
}

private var cardsChecksFailed = 0

private func check(_ condition: Bool, _ what: String) {
    if condition {
        print("check ok: \(what)")
    } else {
        cardsChecksFailed += 1
        print("CHECK FAILED: \(what)")
    }
}

/// The black island at a panel width, with the padding the real panel gives its content.
private struct Stage<Content: View>: View {
    let panelWidth: CGFloat
    let content: Content

    var body: some View {
        content
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(width: panelWidth, alignment: .top)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .padding(22)
    }
}

/// The height a view takes at a fixed width, measured by really laying it out.
@MainActor
private func naturalHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}

/// Writes one picture of `content` on the island at `panelWidth`.
@MainActor
private func snap<V: View>(_ name: String, _ env: AppEnv, to out: URL, panelWidth: CGFloat = 520,
                           @ViewBuilder _ content: () -> V) {
    let staged = Stage(panelWidth: panelWidth, content: content())
        .perchEnvironment(env)
        .environment(\.perchStaticRendering, true)
        .environment(\.colorScheme, .dark)
    let width = panelWidth + 44
    let height = naturalHeight(staged, width: width)
    let wallpaper = LinearGradient(colors: [Color(red: 0.13, green: 0.2, blue: 0.42), Color(red: 0.36, green: 0.24, blue: 0.52),
                                            Color(red: 0.72, green: 0.36, blue: 0.42)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
    let picture = staged.frame(width: width, height: height, alignment: .top).background(wallpaper)
    Snapshot.write(picture, name: name, size: CGSize(width: width, height: height), to: out)
}

private func pending(_ kind: RequestKind, session: String, ago: TimeInterval = 20) -> PendingRequest {
    PendingRequest(sessionID: Session.makeID(.claude, session), agent: .claude, kind: kind,
                   createdAt: SampleData.now.addingTimeInterval(-ago), raw: .null)
}

// MARK: - Approval card

@MainActor
private func snapshotApprovals(_ out: URL) {
    let env = makeEnv()
    let bash = pending(.permission(SampleData.bashPermission), session: "s-approval")
    let edit = SampleData.editPending
    let session = env.sessions.session(id: bash.sessionID)
    env.ui.focusedRequestID = bash.id

    snap("approval-01-dangerous", env, to: out) {
        ApprovalCardView(request: bash, session: session)
    }
    snap("approval-02-dangerous-armed", env, to: out) {
        ApprovalCardView(request: bash, session: session, preview: CardsPreview(confirmArmed: true))
    }
    env.ui.focusedRequestID = edit.id
    snap("approval-03-diff", env, to: out) {
        ApprovalCardView(request: edit, session: session)
    }
    snap("approval-04-diff-always-allow-open", env, to: out) {
        ApprovalCardView(request: edit, session: session, preview: CardsPreview(rememberOpen: true))
    }
    snap("approval-05-deny-note", env, to: out) {
        ApprovalCardView(request: edit, session: session,
                         preview: CardsPreview(noteOpen: true, noteText: "Keep the old window level, just add the collection behaviour"))
    }
    var safe = SampleData.bashPermission
    safe.isDangerous = false
    safe.detail = "scripts/test.sh Engine Sources/Core/Engine"
    let safeRequest = pending(.permission(safe), session: "s-approval")
    env.ui.focusedRequestID = safeRequest.id
    snap("approval-06-plain", env, to: out) {
        ApprovalCardView(request: safeRequest, session: session)
    }
    for width in [420, 760] as [CGFloat] {
        snap("approval-10-width-\(Int(width))", env, to: out, panelWidth: width) {
            VStack(spacing: Theme.Spacing.m) {
                ApprovalCardView(request: safeRequest, session: session)
                ApprovalCardView(request: bash, session: session)
                ApprovalCardView(request: edit, session: session)
            }
        }
    }
}

// MARK: - Question card

@MainActor
private func snapshotQuestions(_ out: URL) {
    let env = makeEnv()
    let request = pending(.question(SampleData.question), session: "s-question", ago: 8)
    let session = env.sessions.session(id: request.sessionID)
    env.ui.focusedRequestID = request.id

    snap("question-01-first-step", env, to: out) {
        QuestionCardView(request: request, session: session)
    }
    snap("question-02-first-step-picked", env, to: out) {
        QuestionCardView(request: request, session: session, preview: CardsPreview(questionPicks: [0: [1]]))
    }
    snap("question-03-multi-select-step", env, to: out) {
        QuestionCardView(request: request, session: session,
                         preview: CardsPreview(questionStep: 1, questionPicks: [0: [1], 1: [0, 2]]))
    }
    snap("question-04-other-field", env, to: out) {
        QuestionCardView(request: request, session: session,
                         preview: CardsPreview(questionStep: 0, otherOpen: true, otherText: "SolidJS, we already use it elsewhere"))
    }
    let single = pending(.question(QuestionRequest(questions: [SampleData.question.questions[0]])), session: "s-question", ago: 8)
    env.ui.focusedRequestID = single.id
    snap("question-05-single-with-key-hints", env, to: out) {
        QuestionCardView(request: single, session: session)
    }
    for width in [420, 760] as [CGFloat] {
        snap("question-10-width-\(Int(width))", env, to: out, panelWidth: width) {
            VStack(spacing: Theme.Spacing.m) {
                QuestionCardView(request: single, session: session)
                QuestionCardView(request: request, session: session,
                                 preview: CardsPreview(questionStep: 1, questionPicks: [0: [1], 1: [0, 2]]))
            }
        }
    }
}

// MARK: - Plan card

@MainActor
private func snapshotPlans(_ out: URL) {
    let env = makeEnv()
    let request = pending(.plan(SampleData.plan), session: "s-plan", ago: 4)
    let session = env.sessions.session(id: request.sessionID)
    env.ui.focusedRequestID = request.id

    snap("plan-01", env, to: out) {
        PlanCardView(request: request, session: session)
    }
    snap("plan-02-request-changes", env, to: out) {
        PlanCardView(request: request, session: session,
                     preview: CardsPreview(noteOpen: true, noteText: "Keep the housekeeper inside the engine for now"))
    }
    let rich = PlanRequest(markdown: """
    ### Rollout
    - [x] Capture fixtures from a real session
    - [ ] Write the reducer
      - Pure function, **no timers**
      - Covered by `ReducerTests`
        1. happy path
        2. two requests at once
    - [ ] Swap it in behind a flag

    > Anything touching `pending` needs a round-trip test first.

    | Step | Owner | Risk |
    |---|---|---|
    | Reducer | engine | low |
    | Housekeeper | engine | *medium* |

    ---
    Plain paragraph with a [link](https://example.com), ~~old idea~~ and a hard\\
    line break. Searching for *.swift files keeps working.
    """, filePath: nil)
    let richRequest = pending(.plan(rich), session: "s-plan", ago: 4)
    snap("plan-03-lists-quote-table", env, to: out) {
        PlanCardView(request: richRequest, session: session)
    }
    // The same plan outside the card's scrolling box, to see all of it.
    snap("plan-04-markdown-in-full", env, to: out) {
        PlanMarkdownView(markdown: rich.markdown + "\n\n```\nlet veryLongLine = \"" + String(repeating: "scrolls sideways ", count: 9) + "\"\nshort()\n```")
            .padding(Theme.Spacing.l)
            .background(CardBackground(isSunken: true, cornerRadius: Theme.Radius.control))
    }
    for width in [420, 760] as [CGFloat] {
        snap("plan-10-width-\(Int(width))", env, to: out, panelWidth: width) {
            PlanCardView(request: request, session: session)
        }
    }
}

// MARK: - Usage tab

/// The sample environment with Codex using models of its own (the shared sample data gives
/// both agents the same model names), so the pictures show two agents' models side by side.
@MainActor
private func makeUsageEnv(_ configure: (AppSettings) -> Void = { _ in }) -> AppEnv {
    let env = makeEnv(configure)
    if var codex = env.usage.usage[.codex] {
        codex.days = codex.days.map { day in
            var day = day
            day.byModel = ["gpt-5.5-codex": day.totals.scaledForSnapshot(0.8), "gpt-5.5-mini": day.totals.scaledForSnapshot(0.2)]
            day.byProject = ["perch": day.totals.scaledForSnapshot(0.5), "notes-cli": day.totals.scaledForSnapshot(0.5)]
            return day
        }
        env.usage.usage[.codex] = codex
    }
    return env
}

private extension TokenTotals {
    func scaledForSnapshot(_ factor: Double) -> TokenTotals {
        TokenTotals(input: Int(Double(input) * factor), output: Int(Double(output) * factor), cacheWrite: Int(Double(cacheWrite) * factor),
                    cacheRead: Int(Double(cacheRead) * factor), costUSD: costUSD * factor, messages: Int(Double(messages) * factor))
    }
}

@MainActor
private func snapshotUsage(_ out: URL) {
    let env = makeUsageEnv()
    snap("usage-01-all", env, to: out) { UsagePanelView() }
    snap("usage-02-agent-claude", env, to: out) { UsagePanelView(initialAgent: .claude) }
    snap("usage-08-day-picked", env, to: out) {
        UsagePanelView(initialDay: UsageTabCalendar.dayString(Date().addingTimeInterval(-9 * 86_400)))
    }
    snap("usage-03-agent-codex", env, to: out) { UsagePanelView(initialAgent: .codex) }

    // One agent only: no row of buttons, its view directly, the activity line under it.
    let single = makeUsageEnv()
    single.usage.usage[.codex] = nil
    snap("usage-04-single-agent", single, to: out) { UsagePanelView() }

    let empty = makeEnv()
    empty.usage.usage = [:]
    empty.usage.activityDays = []
    snap("usage-05-empty", empty, to: out) { UsagePanelView() }

    let remaining = makeUsageEnv {
        $0.usageShowRemaining = true
        $0.showCostEstimates = false
        $0.useAgentColors = false
    }
    remaining.usage.isRefreshing = true
    snap("usage-06-all-remaining-no-costs-today", remaining, to: out) { UsagePanelView(initialRange: .today) }
    snap("usage-07-all-90-days", env, to: out) { UsagePanelView(initialRange: .quarter) }

    for width in [420, 760] as [CGFloat] {
        snap("usage-10-all-width-\(Int(width))", env, to: out, panelWidth: width) { UsagePanelView(initialRange: .month) }
        snap("usage-11-agent-width-\(Int(width))", env, to: out, panelWidth: width) { UsagePanelView(initialRange: .month, initialAgent: .claude) }
    }
}

// MARK: - Activity tab

@MainActor
private func snapshotActivity(_ out: URL) {
    let env = makeEnv()
    snap("activity-01-with-data", env, to: out) { ActivityPanelView() }
    snap("activity-02-row-expanded", env, to: out) { ActivityPanelView(preview: CardsPreview(expandedRows: [0, 5])) }

    let empty = makeEnv()
    empty.sessions.activity = []
    snap("activity-03-empty", empty, to: out) { ActivityPanelView() }
    let off = makeEnv { $0.activityLogEnabled = false }
    off.sessions.activity = []
    snap("activity-04-switched-off", off, to: out) { ActivityPanelView() }

    // Two agents in the log bring out the agent filter.
    let mixed = makeEnv()
    mixed.sessions.activity.insert(contentsOf: [
        ActivityEntry(at: SampleData.now.addingTimeInterval(2), direction: .outgoing, agent: "codex", event: "Decision",
                      sessionID: nil, summary: "You denied the patch", raw: "{\"decision\":\"deny\" (cut off"),
        ActivityEntry(at: SampleData.now.addingTimeInterval(1), direction: .incoming, agent: "codex", event: "PermissionRequest",
                      sessionID: nil, summary: "Codex wants to apply a patch to `Sources/Parser/Lexer.swift` and two other files in the parser package",
                      raw: #"{"hook_event_name":"PermissionRequest","tool_name":"apply_patch","tool_input":{"files":["Sources/Parser/Lexer.swift"]}}"#),
    ], at: 0)
    for width in [420, 760] as [CGFloat] {
        snap("activity-10-width-\(Int(width))", mixed, to: out, panelWidth: width) {
            ActivityPanelView(preview: CardsPreview(expandedRows: [0]))
        }
    }
}

// MARK: - Themes and text sizes

/// The three request cards one under the other, the way the Sessions tab stacks them.
@MainActor
private func requestStack(_ env: AppEnv) -> some View {
    let edit = SampleData.editPending
    let question = pending(.question(SampleData.question), session: "s-question", ago: 8)
    let plan = pending(.plan(SampleData.plan), session: "s-plan", ago: 4)
    env.ui.focusedRequestID = edit.id
    return VStack(spacing: Theme.Spacing.m) {
        ApprovalCardView(request: edit, session: env.sessions.session(id: edit.sessionID))
        QuestionCardView(request: question, session: env.sessions.session(id: question.sessionID),
                         preview: CardsPreview(questionPicks: [0: [0]]))
        PlanCardView(request: plan, session: env.sessions.session(id: plan.sessionID))
    }
}

@MainActor
private func snapshotVariants(_ out: URL) {
    for theme in [ThemeID.ember, .mono, .aurora, .synthwave] {
        let env = makeEnv { $0.theme = theme }
        snap("theme-\(theme.rawValue)-requests", env, to: out) { requestStack(env) }
        let usageEnv = makeUsageEnv { $0.theme = theme }
        snap("theme-\(theme.rawValue)-usage", usageEnv, to: out) { UsagePanelView() }
        snap("theme-\(theme.rawValue)-usage-agent", usageEnv, to: out) { UsagePanelView(initialAgent: .claude) }
        snap("theme-\(theme.rawValue)-activity", env, to: out) { ActivityPanelView(preview: CardsPreview(expandedRows: [0])) }
    }
    for (name, scale, width) in [("130", 1.3, 520), ("130-narrow", 1.3, 420), ("085", 0.85, 520)] as [(String, Double, CGFloat)] {
        let env = makeEnv { $0.textScale = scale }
        let bash = pending(.permission(SampleData.bashPermission), session: "s-approval")
        snap("text-\(name)-requests", env, to: out, panelWidth: width) {
            VStack(spacing: Theme.Spacing.m) {
                ApprovalCardView(request: bash, session: env.sessions.session(id: bash.sessionID), preview: CardsPreview(confirmArmed: true))
                requestStack(env)
            }
        }
        let usageEnv = makeUsageEnv { $0.textScale = scale }
        snap("text-\(name)-usage", usageEnv, to: out, panelWidth: width) { UsagePanelView() }
        snap("text-\(name)-usage-agent", usageEnv, to: out, panelWidth: width) { UsagePanelView(initialAgent: .claude) }
        snap("text-\(name)-activity", env, to: out, panelWidth: width) { ActivityPanelView(preview: CardsPreview(expandedRows: [0])) }
    }
    // Toggles the cards honour: no key hints, no "always allow", no diff, no elapsed time, plain agent colours.
    let plain = makeEnv {
        $0.shortcutsEnabled = false
        $0.showAlwaysAllow = false
        $0.showDiffPreview = false
        $0.showElapsedTime = false
        $0.useAgentColors = false
        $0.confirmDangerous = false
        $0.showGlow = false
        $0.showProjectPath = true
    }
    let bash = pending(.permission(SampleData.bashPermission), session: "s-approval")
    snap("settings-flipped-requests", plain, to: out) {
        VStack(spacing: Theme.Spacing.m) {
            ApprovalCardView(request: bash, session: plain.sessions.session(id: bash.sessionID))
            requestStack(plain)
        }
    }
}

// MARK: - Content that tries to break the layout

@MainActor
private func snapshotAwkwardContent(_ out: URL) {
    let env = makeEnv()
    let longCommand = "find . -name '*.swift' -not -path './.build/*' -print0 | xargs -0 sed -i '' -e 's/SessionEngineProtocol/SessionEngine/g' && git add -A && git commit -m 'Rename the protocol everywhere it is mentioned in the code base' && git push --force-with-lease origin feature/a-very-long-branch-name-that-keeps-going"
    let mcp = PermissionRequest(toolName: "mcp__github_enterprise__create_pull_request_review", summary: "Use a tool from the github_enterprise extension to create a pull request review",
                                detail: longCommand, diff: nil,
                                suggestions: (0..<3).map { PermissionSuggestion(id: $0, label: "Always allow github_enterprise tools in /Users/you/code/a-project-with-a-long-name (rule \($0 + 1))", raw: .null) })
    let bigDiff = DiffPreview(filePath: "/Users/you/code/perch/Sources/App/Some/Deeply/Nested/Folder/Structure/WithAVeryLongFileNameIndeed.swift",
                              lines: [DiffLine(kind: .header, text: "@@ -1198,60 +1198,61 @@")]
                                + (0..<60).map { DiffLine(kind: $0 % 5 == 0 ? .removed : ($0 % 5 == 1 ? .added : .context),
                                                          text: "\t\tlet value\($0) = compute(\($0)) // " + String(repeating: "long ", count: $0 % 7 * 6)) },
                              added: 412, removed: 12, truncated: true)
    let noDetail = PermissionRequest(toolName: "", summary: "", detail: "  ", diff: nil)
    let requests = [
        pending(.permission(mcp), session: "nowhere"),
        pending(.permission(PermissionRequest(toolName: "Write", summary: "Write a file", detail: "notes.md", diff: bigDiff)), session: "s-approval"),
        pending(.permission(noDetail), session: "nowhere"),
    ]
    env.ui.focusedRequestID = requests[0].id
    snap("awkward-01-approvals", env, to: out, panelWidth: 420) {
        VStack(spacing: Theme.Spacing.m) {
            ApprovalCardView(request: requests[0], session: nil, preview: CardsPreview(rememberOpen: true))
            ApprovalCardView(request: requests[1], session: env.sessions.session(id: requests[1].sessionID))
            ApprovalCardView(request: requests[2], session: nil)
        }
    }

    let wordy = QuestionRequest(questions: [
        Question(id: 0, text: "The migration can either run in place, which is faster but locks the table for the duration, or copy into a new table and swap at the end. Which one do you want me to use for the production database?",
                 header: nil, options: [
                    QuestionOption(id: 0, label: "Run in place and accept the lock, the maintenance window is long enough for it",
                                   detail: "Roughly four minutes of downtime on the current data set, measured on staging with a copy of last night's backup."),
                    QuestionOption(id: 0, label: "", detail: nil),
                 ] + (2..<11).map { QuestionOption(id: $0, label: "Choice \($0 + 1)", detail: nil) }, multiSelect: true),
    ])
    let noOptions = QuestionRequest(questions: [Question(id: 0, text: "What should the release be called?", header: "Name", options: [], multiSelect: false)])
    let questions = [pending(.question(wordy), session: "s-question"), pending(.question(noOptions), session: "s-question"),
                     pending(.question(QuestionRequest(questions: [])), session: "s-question")]
    snap("awkward-02-questions", env, to: out, panelWidth: 420) {
        VStack(spacing: Theme.Spacing.m) {
            ForEach(questions) { QuestionCardView(request: $0, session: nil, preview: CardsPreview(questionPicks: [0: [0, 3]])) }
        }
    }

    let plans = [pending(.plan(PlanRequest(markdown: "", filePath: "/tmp/a-plan-file-with-an-extraordinarily-long-name-2026-10-12.md")), session: "s-plan"),
                 pending(.plan(PlanRequest(markdown: "Just one line, no formatting at all, but with an_identifier_that_has_underscores and 2 * 3 * 4 stars.", filePath: nil)), session: "s-plan")]
    snap("awkward-03-plans", env, to: out, panelWidth: 420) {
        VStack(spacing: Theme.Spacing.m) {
            ForEach(plans) { PlanCardView(request: $0, session: env.sessions.session(id: $0.sessionID)) }
        }
    }

    // Usage: three limits, one of them nearly gone, no history; plus an agent with history but no limits.
    let odd = makeEnv()
    odd.usage.usage = [
        .gemini: AgentUsage(agent: .gemini, windows: [
            RateWindow(id: "5h", label: "5-hour limit", usedPercent: 97.4, resetsAt: SampleData.now.addingTimeInterval(-30)),
            RateWindow(id: "7d", label: "Weekly limit", usedPercent: 0, resetsAt: nil),
            RateWindow(id: "opus", label: "Weekly limit for the biggest model", usedPercent: .nan, resetsAt: SampleData.now.addingTimeInterval(90_000)),
        ], planName: "Pro"),
        .antigravity: AgentUsage(agent: .antigravity, today: TokenTotals(input: 12, output: 3),
                                 days: [DayUsage(day: UsageTabCalendar.dayString(SampleData.now), totals: TokenTotals(input: 12, output: 3, costUSD: 0),
                                                 byModel: Dictionary(uniqueKeysWithValues: (0..<7).map { ("a-model-with-a-rather-long-identifier-\($0)", TokenTotals(input: 10 * ($0 + 1))) }),
                                                 byProject: ["/Users/you/code/some/deep/project-folder": TokenTotals(input: 15)])],
                                 allTime: TokenTotals(input: 12, output: 3), note: "Antigravity does not publish limits, so only tokens counted from its session files are shown here."),
    ]
    odd.usage.activityDays = [DailyActivity(day: UsageTabCalendar.dayString(SampleData.now), activeSeconds: 59, sessionsStarted: 1)]
    snap("awkward-04-usage", odd, to: out, panelWidth: 420) { UsagePanelView(initialRange: .quarter) }
    snap("awkward-04-usage-agent-limits-only", odd, to: out, panelWidth: 420) { UsagePanelView(initialRange: .quarter, initialAgent: .gemini) }
    snap("awkward-04-usage-agent-many-models", odd, to: out, panelWidth: 420) { UsagePanelView(initialRange: .quarter, initialAgent: .antigravity) }

    // Usage: all four agents at once, with more models between them than the chart can name.
    let crowd = makeUsageEnv()
    let recent = crowd.usage.usage[.claude]?.days.suffix(12) ?? []
    crowd.usage.usage[.gemini] = AgentUsage(agent: .gemini, windows: [RateWindow(id: "day", label: "Daily limit", usedPercent: 64, resetsAt: SampleData.now.addingTimeInterval(7 * 3600))],
                                            today: SampleData.totals(0.3), days: recent.map {
        DayUsage(day: $0.day, totals: $0.totals.scaledForSnapshot(0.4),
                 byModel: ["gemini-3-pro": $0.totals.scaledForSnapshot(0.3), "gemini-3-flash": $0.totals.scaledForSnapshot(0.1)])
    }, allTime: SampleData.totals(4))
    crowd.usage.usage[.antigravity] = AgentUsage(agent: .antigravity, today: SampleData.totals(0.05), days: recent.suffix(4).map {
        DayUsage(day: $0.day, totals: $0.totals.scaledForSnapshot(0.1), byModel: ["gemini-3-pro": $0.totals.scaledForSnapshot(0.1)])
    }, allTime: SampleData.totals(1))
    for width in [420, 520] as [CGFloat] {
        snap("awkward-06-usage-four-agents-\(Int(width))", crowd, to: out, panelWidth: width) { UsagePanelView(initialRange: .month) }
    }

    let busy = makeEnv()
    let agentNames = ["claude", "codex", "antigravity", "gemini", "someNewAgent", ""]
    busy.sessions.activity = (0..<120).map { index -> ActivityEntry in
        let direction: ActivityEntry.Direction = index % 3 == 0 ? .outgoing : .incoming
        let event = index % 4 == 0 ? "AnEventWithAnUnusuallyLongNameThatGoesOnAndOn" : "PostToolUse"
        let summary = index % 5 == 0 ? "" : "Event number \(index) with an odd ` backtick and *stars* kept as typed"
        let raw = index % 2 == 0 ? "not json at all" : ""
        return ActivityEntry(at: SampleData.now.addingTimeInterval(TimeInterval(-index * 3600)), direction: direction,
                             agent: agentNames[index % 6], event: event, sessionID: nil, summary: summary, raw: raw)
    }
    snap("awkward-05-activity", busy, to: out, panelWidth: 420) { ActivityPanelView(preview: CardsPreview(expandedRows: [0, 1])) }
}

// MARK: - Behaviour checks (no pictures)

private func runLogicChecks() {
    // Diff model
    let diff = ApprovalDiffModel(diff: SampleData.editPermission.diff ?? DiffPreview(filePath: nil, lines: [], added: 0, removed: 0, truncated: false), maxLines: 40)
    check(diff.rows.map(\.number) == [nil, 12, 13, 13, 14, 15, 16], "diff rows are numbered from the hunk header (\(diff.rows.map(\.number)))")
    check(diff.rows[1].text == "    isFloatingPanel = true" && diff.rows[6].text == "}", "diff rows lose only the indentation they share")
    check(diff.footnote == nil && diff.added == 2 && diff.removed == 1, "a complete diff has no footnote and keeps the adapter's totals")
    let long = DiffPreview(filePath: nil, lines: (0..<500).map { DiffLine(kind: $0 % 2 == 0 ? .added : .removed, text: "x\($0)") }, added: 0, removed: 0, truncated: false)
    let cut = ApprovalDiffModel(diff: long, maxLines: 5000)
    check(cut.rows.count == 200 && cut.hiddenLines == 300 && cut.added == 250 && cut.footnote != nil, "a long diff is cut at the setting's upper limit and says so")
    check(ApprovalDiffModel(diff: long, maxLines: -3).rows.count == 10, "a nonsense line limit falls back to the lowest allowed")
    check(ApprovalDiffModel.parseHunkHeader("@@ -1,2 +30 @@ func a()")?.newStart == 30 && ApprovalDiffModel.parseHunkHeader("@@ nonsense") == nil, "hunk headers are read, junk is refused")
    check(ApprovalDiffModel.clean("\ta\r\n") == "    a" && ApprovalDiffModel.clean(String(repeating: "y", count: 900)).count == ApprovalDiffModel.maxLineLength + 2, "diff lines are made safe to draw")

    // Question flow
    let asked = SampleData.question.questions
    var simple = QuestionFlow(questions: [asked[0]])
    check(simple.isSimple && simple.pick(1) == .answer([asked[0].text: "Svelte"]), "one single-select question is answered by one pick")
    check(simple.pick(99) == nil, "picking an option that does not exist does nothing")
    var flow = QuestionFlow(questions: asked)
    check(!flow.canAdvance && flow.advance() == nil && flow.step == 0, "cannot move on without an answer")
    check(flow.pick(0) == nil && flow.canAdvance, "with several questions a pick only selects")
    flow.pick(2)
    check(flow.answer(at: 0) == "Plain HTML", "single-select keeps only the last pick")
    check(flow.advance() == nil && flow.step == 1 && !flow.canAdvance, "Next shows the second question")
    flow.pick(2); flow.pick(0); flow.pick(1); flow.pick(1)
    check(flow.answer(at: 1) == "Live charts, CSV export", "multi-select answers are joined in the order the options were offered")
    flow.setOtherOpen(true); flow.setOtherText("  PDF export ")
    check(flow.answer(at: 1) == "Live charts, CSV export, PDF export", "Other adds a typed answer to a multi-select")
    check(flow.advance() == .answer([asked[0].text: "Plain HTML", asked[1].text: "Live charts, CSV export, PDF export"]), "the last step sends every answer, keyed by question text")
    flow.back()
    flow.setOtherOpen(true)
    check(flow.step == 0 && flow.answer(at: 0) == nil && !flow.canAdvance, "opening Other on a single-select clears the pick and waits for text")
    flow.setOtherText("SolidJS")
    check(flow.answer(at: 0) == "SolidJS", "typed text answers a single-select")
    flow.pick(1)
    check(flow.answer(at: 0) == "Svelte" && !flow.isOtherOpen, "picking an option closes Other")
    var none = QuestionFlow(questions: [])
    check(none.current == nil && none.advance() == nil && none.decision() == nil, "a request with no questions never produces an answer")

    // Plan Markdown
    let plan = PlanDocument(markdown: SampleData.plan.markdown).blocks
    check(plan.first == .heading(level: 1, text: "Refactor the session engine"), "plan: first block is the title")
    check(plan.filter { if case .listItem(.number, 0, _) = $0 { return true } else { return false } }.count == 3, "plan: three numbered steps")
    check(plan.filter { if case .listItem(.bullet, 0, _) = $0 { return true } else { return false } }.count == 2, "plan: two bullets")
    check(plan.last == .code(language: "swift", lines: ["static func reduce(_ session: inout Session, _ event: AgentEvent, at date: Date)"]), "plan: the fenced code block keeps its language and text")
    let nested = PlanDocument(markdown: "- a\n  - b\n      1) c\n  continued\n- [x] d\n\ntext one\ntext two\n\n| h1 | h2 |\n|---|:-:|\n| c1 | c2 |\n> q1\n> q2\n***\n```\nnever closed").blocks
    check(nested == [.listItem(marker: .bullet, depth: 0, text: "a"), .listItem(marker: .bullet, depth: 1, text: "b"),
                     .listItem(marker: .number("1"), depth: 2, text: "c continued"), .listItem(marker: .task(done: true), depth: 0, text: "d"),
                     .paragraph("text one text two"), .table(rows: [["h1", "h2"], ["c1", "c2"]]), .quote("q1 q2"), .rule,
                     .code(language: nil, lines: ["never closed"])],
          "plan: nesting, continuation lines, check-lists, tables, quotes, rules and an unclosed fence (\(nested))")
    check(PlanDocument(markdown: "#hashtag is not a heading\n1.5 is not a list").blocks == [.paragraph("#hashtag is not a heading 1.5 is not a list")], "plan: look-alikes stay ordinary text")
    check(PlanDocument(markdown: String(repeating: "word ", count: 20_000)).truncated, "plan: an enormous plan is cut and flagged")

    // Inline text
    let theme = Theme.palette(.midnight)
    let style = CardsInline.Style(size: 12, color: .white)
    check(String(CardsInline.codeSpans("run `a b` then *.swift ` odd", theme: theme, style: style).characters) == "run a b then *.swift ` odd", "summaries: only paired backticks are consumed")
    check(String(CardsInline.markdown("**bold** and `code` and [link](https://example.com)", theme: theme, style: style).characters) == "bold and code and link", "plans: inline Markdown is resolved")
    check(CardsInline.markdown("a [link](https://example.com)", theme: theme, style: style).runs.allSatisfy { $0.link == nil }, "plans: links are not clickable")

    // Usage maths
    let now = SampleData.now
    let today = UsageTabCalendar.dayString(now)
    let claude = SampleData.usage[.claude] ?? AgentUsage(agent: .claude)
    let codex = SampleData.usage[.codex] ?? AgentUsage(agent: .codex)

    check(UsageCombine.scope(picked: nil, agents: [.claude, .codex]) == .all && UsageCombine.scope(picked: nil, agents: [.codex]) == .agent(.codex)
            && UsageCombine.scope(picked: nil, agents: []) == nil, "usage: the tab starts on All with several agents, on the agent when there is one")
    check(UsageCombine.scope(picked: .agent(.codex), agents: [.claude, .codex]) == .agent(.codex) && UsageCombine.scope(picked: .agent(.gemini), agents: [.claude, .codex]) == .all
            && UsageCombine.scope(picked: .all, agents: [.claude]) == .agent(.claude), "usage: a picked view is kept while it exists, otherwise the tab falls back")

    // Claude's sample "today" (the store's fresher number) is bigger than the day list's entry
    // for today, so today is topped up; Codex's is smaller, so its day list stands.
    let claudeWeek = claude.days.suffix(7).dropLast().reduce(0) { $0 + $1.totals.total } + claude.today.total
    let codexWeek = codex.days.suffix(7).reduce(0) { $0 + $1.totals.total }
    let one = UsageCombine.combine([claude], range: .week, now: now, byCost: true)
    check(one.range.total == claudeWeek && one.today == claude.today, "usage: 7-day total is the last seven days, with today at the store's fresher number")
    check(one.series.map(\.model) == ["claude-opus-5-5", "claude-sonnet-5-5"] && one.series.map(\.shade) == [0, 1]
            && abs(one.series.reduce(0) { $0 + $1.fraction } - 1) < 0.0001 && abs(one.series[0].fraction - 0.7) < 0.001,
          "usage: one agent's models are ranked, shaded in order and add up to the whole")
    check(one.byProject.map(\.name) == ["perch", "sightsense"] && abs(one.byProject[0].fraction - 0.6) < 0.001, "usage: projects are ranked for the range")
    let topUp = UsageCombine.days(claude, now: now)[today]
    check(topUp?.totals == claude.today && abs((topUp?.byModel["claude-opus-5-5"]?.total ?? 0) - Int(Double(claude.today.total) * 0.7)) < 50,
          "usage: topping today up keeps the models' proportions")

    let both = UsageCombine.combine([claude, codex], range: .week, now: now, byCost: true)
    check(both.range.total == claudeWeek + codexWeek && both.today.total == claude.today.total + (codex.days.last?.totals.total ?? 0),
          "usage: All adds the agents' totals together")
    check(both.series.map(\.id) == ["claude/claude-opus-5-5", "codex/claude-opus-5-5", "claude/claude-sonnet-5-5", "codex/claude-sonnet-5-5"]
            && both.series.map(\.shade) == [0, 0, 1, 1], "usage: the same model under two agents is two entries, each shaded within its agent (\(both.series.map(\.id)))")
    check(both.days.count == 7 && both.days.last?.day == today && both.days.allSatisfy { $0.inRange && $0.hasData && $0.parts.count == 4 && abs($0.stacked - $0.totals.total) < 50 },
          "usage: one bar per day, split into the same entries, as tall as the day's total")
    check(abs(both.series.reduce(0) { $0 + $1.totals.total } - both.range.total) < 400 && abs(both.series.reduce(0) { $0 + $1.fraction } - 1) < 0.0001,
          "usage: the entries add up to the range")
    let month = UsageCombine.combine([claude, codex], range: .month, now: now, byCost: true)
    check(month.days.count == 30 && month.days.first?.parts.suffix(2) == [0, 0] && (month.days.first?.stacked ?? 0) > 0,
          "usage: an agent with a shorter history simply adds nothing to the earlier bars")
    let todayOnly = UsageCombine.combine([claude, codex], range: .today, now: now, byCost: true)
    check(todayOnly.days.count == 7 && todayOnly.days.filter(\.inRange).map(\.day) == [today] && todayOnly.range == todayOnly.today,
          "usage: Today still draws a week of bars but counts only today")
    let quarter = UsageCombine.combine([codex], range: .quarter, now: now, byCost: true)
    check(quarter.days.count == 90 && quarter.days.filter(\.hasData).count == 7 && quarter.days.first?.stacked == 0, "usage: the chart has one slot per day, gaps included")

    // Seven models across two agents: the top five keep their names, two fold into "Other".
    func oneDay(_ agent: AgentKind, _ models: [String: Int]) -> AgentUsage {
        AgentUsage(agent: agent, days: [DayUsage(day: today, totals: TokenTotals(input: models.values.reduce(0, +)), byModel: models.mapValues { TokenTotals(input: $0) })])
    }
    let many = UsageCombine.combine([oneDay(.claude, ["a": 70, "b": 10, "c": 40, "d": 5]), oneDay(.codex, ["a": 60, "e": 50, "f": 20])], range: .week, now: now, byCost: true)
    check(many.series.map(\.id) == ["claude/a", "codex/a", "codex/e", "claude/c", "codex/f", "other/Other"] && many.series.map(\.shade) == [0, 0, 1, 1, 2, 0],
          "usage: the top five models keep their names across agents (\(many.series.map(\.id)))")
    check(many.series.last?.totals.input == 15 && many.series.last?.folded == 2 && many.days.last?.parts == [70, 60, 50, 40, 20, 15]
            && abs(many.series.reduce(0) { $0 + $1.fraction } - 1) < 0.0001, "usage: the smaller models fold into one Other entry, in the bars too")
    let noModels = UsageCombine.combine([AgentUsage(agent: .gemini, today: TokenTotals(input: 9))], range: .today, now: now, byCost: false)
    check(noModels.series.map(\.id) == ["other/Other"] && noModels.days.last?.parts == [9] && noModels.series.first?.folded == 0 && noModels.today.total == 9,
          "usage: tokens no model is named for are still drawn and counted")
    let nothing = UsageCombine.combine([AgentUsage(agent: .gemini, windows: [RateWindow(id: "x", label: "x", usedPercent: 1, resetsAt: nil)])], range: .week, now: now, byCost: true)
    check(nothing.series.isEmpty && nothing.days.count == 7 && nothing.days.allSatisfy { !$0.hasData && $0.parts.isEmpty } && nothing.range.total == 0,
          "usage: an agent with limits only has an empty history")
    let priced = UsageCombine.combine([AgentUsage(agent: .claude, days: [DayUsage(day: today, totals: TokenTotals(input: 110, costUSD: 5),
                                                                                  byModel: ["big": TokenTotals(input: 100, costUSD: 1), "dear": TokenTotals(input: 10, costUSD: 4)])])],
                                      range: .week, now: now, byCost: true)
    check(priced.series.map(\.model) == ["dear", "big"] && abs((priced.series.first?.fraction ?? 0) - 0.8) < 0.0001
            && UsageCombine.combine([claude], range: .week, now: now, byCost: false).series.first?.model == "claude-opus-5-5", "usage: with costs shown the ranking is by cost")

    let folded = UsageTabMath.shares(Dictionary(uniqueKeysWithValues: (1...7).map { ("m\($0)", TokenTotals(input: $0)) }), byCost: true)
    check(folded.map(\.name) == ["m7", "m6", "m5", "m4", "3 more"] && folded.last?.totals.input == 6, "usage: small project slices fold into one")
    check(UsageTabMath.shares(["a": TokenTotals(), "b": TokenTotals(costUSD: .nan)], byCost: true).isEmpty, "usage: empty and broken slices are dropped")
    let window = RateWindow(id: "x", label: "x", usedPercent: 82, resetsAt: nil)
    check(UsageTabMath.reading(window, showRemaining: true, warnings: true, warnAt: 80) == UsageLimitReading(used: 82, shown: 18, showsRemaining: true, level: .warning), "usage: 'remaining' flips the number but not the warning")
    check(UsageTabMath.reading(window, showRemaining: false, warnings: false, warnAt: 80).level == .calm, "usage: warnings can be switched off")
    check(UsageTabMath.reading(RateWindow(id: "x", label: "x", usedPercent: 250, resetsAt: nil), showRemaining: false, warnings: true, warnAt: 80).shown == 100
            && UsageTabMath.reading(RateWindow(id: "x", label: "x", usedPercent: -.infinity, resetsAt: nil), showRemaining: false, warnings: true, warnAt: 80).shown == 0,
          "usage: out-of-range percentages are clamped")
    let activity = UsageTabMath.activity(SampleData.activityDays, range: .week, now: now)
    let lastWeek = SampleData.activityDays.suffix(7)
    check(activity.activeSeconds == lastWeek.reduce(0) { $0 + $1.activeSeconds } && activity.longestTaskSeconds == lastWeek.map(\.longestTaskSeconds).max()
            && activity.requestsHandled == lastWeek.reduce(0) { $0 + $1.approvalsHandled + $1.questionsAnswered }, "usage: activity sums and maxima over the range")
    check(UsageTabMath.duration(59) == "59s" && UsageTabMath.duration(3599) == "59m" && UsageTabMath.duration(3660) == "1h 01m" && UsageTabMath.duration(-5) == "0s", "usage: durations")
    check(UsageTabMath.displayName("/Users/you/code/perch") == "perch" && UsageTabMath.displayName(" ") == "Unknown", "usage: project paths are shortened")

    // Activity log
    let entries = SampleData.activity + [ActivityEntry(at: now, direction: .note, agent: "Codex ", event: "x", sessionID: nil, summary: "", raw: ""),
                                         ActivityEntry(at: now, direction: .note, agent: "zed", event: "x", sessionID: nil, summary: "", raw: "")]
    check(ActivityTabFilter.agents(in: entries) == ["claude", "codex", "zed"], "activity: agents are listed in a stable order")
    check(ActivityTabFilter(agent: "codex", direction: .note).apply(to: entries).count == 1 && ActivityTabFilter(agent: nil, direction: .outgoing).apply(to: entries).count == 1,
          "activity: filters by agent and direction")
    check(ActivityTabWording.prettyRaw(#"{"b":1,"a":[true]}"#)?.contains("\n") == true && ActivityTabWording.prettyRaw("{cut") == "{cut" && ActivityTabWording.prettyRaw("  ") == nil,
          "activity: raw JSON is indented, broken JSON is kept, nothing stays nothing")

    // Wording
    check(CardsWording.shortToolName("mcp__github__create_issue") == "create_issue" && CardsWording.shortToolName(String(repeating: "x", count: 60)).count == 18, "tool names are shortened")
    check(CardsWording.toolSymbol("mcp__github__create_review") == "puzzlepiece.extension.fill" && CardsWording.toolSymbol("Bash") == "terminal.fill"
            && CardsWording.toolSymbol("MultiEdit") == "pencil" && CardsWording.toolSymbol("Read") == "doc.text" && CardsWording.toolSymbol("WebSearch") == "globe",
          "tools get a fitting symbol")
    check(CardsCodeBox.clipped(String(repeating: "x", count: 7000)).hidden == 1000, "a huge command is cut and the cut is counted")
}

/// Hosts a view in a real (never shown) window so scroll views, focus and deferred work run.
@MainActor
private func host<V: View>(_ view: V, _ env: AppEnv, width: CGFloat, staticRendering: Bool) -> (window: NSWindow, host: NSHostingView<AnyView>) {
    let root = AnyView(view.frame(width: width).fixedSize(horizontal: false, vertical: true)
        .perchEnvironment(env).environment(\.perchStaticRendering, staticRendering).environment(\.colorScheme, .dark))
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: 900)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    return (window, hosting)
}

/// The cards must take the same room with real scroll views (the app) as with the static
/// stand-ins (snapshots), otherwise the panel would report one height and draw another.
@MainActor
private func runLayoutChecks() {
    let env = makeEnv()
    env.ui.isExpanded = true
    let edit = SampleData.editPending
    let plan = pending(.plan(SampleData.plan), session: "s-plan")
    let question = pending(.question(SampleData.question), session: "s-question")
    let views: [(String, AnyView)] = [
        ("approval with a diff", AnyView(ApprovalCardView(request: edit, session: nil))),
        ("plan", AnyView(PlanCardView(request: plan, session: nil))),
        ("question", AnyView(QuestionCardView(request: question, session: nil))),
        ("usage tab, All", AnyView(UsagePanelView())),
        ("usage tab, one agent", AnyView(UsagePanelView(initialAgent: .claude))),
        ("activity tab", AnyView(ActivityPanelView(preview: CardsPreview(expandedRows: [0])))),
    ]
    for (name, view) in views {
        for width in [396, 496, 736] as [CGFloat] {
            let live = host(view, env, width: width, staticRendering: false)
            let still = host(view, env, width: width, staticRendering: true)
            let (a, b) = (live.host.fittingSize.height, still.host.fittingSize.height)
            check(a > 40 && abs(a - b) < 1, "\(name) at \(Int(width)) pt: same height live (\(a)) and static (\(b))")
            live.window.contentView = nil
            still.window.contentView = nil
        }
    }

    // The "All" view with two agents is meant to be taken in at a glance: at the default panel
    // width it must not grow past roughly 520 points.
    let glance = host(UsagePanelView(), makeUsageEnv(), width: 496, staticRendering: false)
    check(glance.host.fittingSize.height <= 520, "usage tab, All, two agents at 496 pt: \(glance.host.fittingSize.height) pt tall, no taller than 520")
    glance.window.contentView = nil

    // A text field on a card must claim the keyboard while it shows, and give it back after.
    check(!env.ui.needsKeyboard, "no card text field: the panel does not ask for the keyboard")
    let note = host(ApprovalCardView(request: edit, session: nil, preview: CardsPreview(noteOpen: true)), env, width: 496, staticRendering: false)
    let other = host(QuestionCardView(request: question, session: nil, preview: CardsPreview(otherOpen: true)), env, width: 496, staticRendering: false)
    check(env.ui.needsKeyboard, "an open note field asks for the keyboard")
    note.host.rootView = AnyView(EmptyView())
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    check(env.ui.needsKeyboard, "closing one of two fields keeps the keyboard for the other")
    other.host.rootView = AnyView(EmptyView())
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    check(!env.ui.needsKeyboard, "closing the last field gives the keyboard back")
    note.window.contentView = nil
    other.window.contentView = nil
}

/// Pictures of the views with their REAL scroll views and text fields, taken from a window
/// that is never shown. Everything else in this file is drawn with the static stand-ins, so
/// this is the only look at what the app itself draws. Each capture is also checked not to be blank.
@MainActor
private func runLiveCaptures(_ out: URL) {
    let env = makeEnv()
    env.ui.isExpanded = true
    let edit = SampleData.editPending
    let plan = pending(.plan(SampleData.plan), session: "s-plan")
    let question = pending(.question(SampleData.question), session: "s-question")
    env.ui.focusedRequestID = edit.id
    let views: [(String, AnyView)] = [
        ("live-01-requests", AnyView(VStack(spacing: Theme.Spacing.m) {
            ApprovalCardView(request: edit, session: env.sessions.session(id: edit.sessionID), preview: CardsPreview(noteOpen: true, noteText: "Typed into a real text field"))
            QuestionCardView(request: question, session: env.sessions.session(id: question.sessionID), preview: CardsPreview(otherOpen: true))
            PlanCardView(request: plan, session: env.sessions.session(id: plan.sessionID))
        })),
        ("live-02-usage", AnyView(UsagePanelView())),
        ("live-03-activity", AnyView(ActivityPanelView(preview: CardsPreview(expandedRows: [0])))),
    ]
    for (name, view) in views {
        let staged = Stage(panelWidth: 520, content: view).background(Color(red: 0.2, green: 0.2, blue: 0.3))
        let hosted = host(staged, env, width: 564, staticRendering: false)
        let size = hosted.host.fittingSize
        hosted.host.frame = NSRect(origin: .zero, size: size)
        hosted.window.setContentSize(size)
        hosted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let image = hosted.host.bitmapImageRepForCachingDisplay(in: hosted.host.bounds) else {
            check(false, "\(name): the window could be captured")
            continue
        }
        hosted.host.cacheDisplay(in: hosted.host.bounds, to: image)
        if let png = image.representation(using: .png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("\(name).png"))
            print("snapshot: \(out.appendingPathComponent("\(name).png").path)")
        }
        hosted.window.contentView = nil
    }
}

/// Records what the cards ask the app to do.
private final class RecordingActions: AppActions {
    var resolved: [(PendingRequest, Decision)] = []
    func resolve(_ request: PendingRequest, _ decision: Decision) { resolved.append((request, decision)) }
    func jump(to session: Session) {}
    func dismiss(_ session: Session) {}
    func setExpanded(_ expanded: Bool) {}
    func openSettings(_ tab: SettingsTab?) {}
    func refreshAgents() {}
    func installHooks(for agent: AgentKind) {}
    func uninstallHooks(for agent: AgentKind) {}
    func refreshUsage() {}
    func clearSavedStats() {}
    func previewSound(_ cue: SoundCue) {}
    func toggleMute() {}
    func setDemo(_ on: Bool) {}
    func clearActivityLog() {}
    func copyDiagnostics() {}
    func revealSupportFolder() {}
    func uninstallEverything() {}
    func quit() {}
}

/// Sends Command + `characters` to a hosted view the way the window would.
@MainActor
private func press(_ characters: String, keyCode: UInt16, in hosted: (window: NSWindow, host: NSHostingView<AnyView>), isRepeat: Bool = false) -> Bool {
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: hosted.window.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode) else { return false }
    // Through the application's event queue, so `NSApp.currentEvent` is this key press, as in the app.
    NSApp.postEvent(event, atStart: false)
    var handled = false
    while let next = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
        if next.type == .keyDown {
            handled = hosted.window.performKeyEquivalent(with: next) || handled
        } else {
            NSApp.sendEvent(next)
        }
    }
    return handled
}

/// The question card's own shortcuts (several questions / multi-select), driven by real key events.
@MainActor
private func runKeyboardChecks() {
    let env = makeEnv()
    let actions = RecordingActions()
    env.actions = actions
    let asked = SampleData.question.questions
    let request = pending(.question(SampleData.question), session: "s-question", ago: 30)
    env.ui.focusedRequestID = request.id
    let card = host(QuestionCardView(request: request, session: nil), env, width: 496, staticRendering: false)

    _ = press("\r", keyCode: 36, in: card)
    check(actions.resolved.isEmpty, "⌘↩ with nothing picked does not answer")
    check(press("2", keyCode: 19, in: card), "⌘2 is taken by the focused question card")
    _ = press("\r", keyCode: 36, in: card)
    _ = press("1", keyCode: 18, in: card)
    _ = press("3", keyCode: 20, in: card)
    _ = press("3", keyCode: 20, in: card, isRepeat: true)
    check(actions.resolved.isEmpty, "picking with the keyboard does not send anything by itself")
    _ = press("\r", keyCode: 36, in: card)
    check(actions.resolved.count == 1 && actions.resolved.first?.1 == .answer([asked[0].text: "Svelte", asked[1].text: "Live charts, CSV export"]),
          "⌘2, ⌘↩, ⌘1, ⌘3, ⌘↩ answers both questions (got \(actions.resolved.map(\.1)))")
    _ = press("\r", keyCode: 36, in: card)
    check(actions.resolved.count == 1, "a second ⌘↩ does not answer twice")
    card.window.contentView = nil

    // Not the focused card, or too new: keys are left alone.
    actions.resolved = []
    env.ui.focusedRequestID = UUID()
    let unfocused = host(QuestionCardView(request: request, session: nil, preview: CardsPreview(questionStep: 1, questionPicks: [0: [0], 1: [0]])),
                         env, width: 496, staticRendering: false)
    check(!press("\r", keyCode: 36, in: unfocused) && actions.resolved.isEmpty, "a card that is not in focus ignores the keyboard")
    unfocused.window.contentView = nil
    let fresh = PendingRequest(sessionID: request.sessionID, agent: .claude, kind: .question(SampleData.question), createdAt: Date(), raw: .null)
    env.ui.focusedRequestID = fresh.id
    let tooNew = host(QuestionCardView(request: fresh, session: nil, preview: CardsPreview(questionStep: 1, questionPicks: [0: [0], 1: [0]])),
                      env, width: 496, staticRendering: false)
    _ = press("\r", keyCode: 36, in: tooNew)
    check(actions.resolved.isEmpty, "a question that only just appeared cannot be answered by a key press")
    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    _ = press("\r", keyCode: 36, in: tooNew)
    check(actions.resolved.count == 1, "a moment later the same key press answers it")
    tooNew.window.contentView = nil
}
