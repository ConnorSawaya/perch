// DemoScript.swift — the story demo mode plays, written as plain data.
//
// A script is a list of steps. Each step has a name, a pause before it happens, and one or more
// actions ("this session starts a tool", "that one asks a question"). DemoDirector walks through
// the list on a timer and starts again at the top when it reaches the end; DemoStage knows how
// each action changes what the notch shows.
//
// To change the story, edit `steps` below. Nothing else needs to know.

import Foundation

/// One thing that happens to one pretend session.
enum DemoAction {
    /// A new session card appears.
    case startSession(DemoRole)
    /// The user sent this session a prompt: it starts working.
    case prompt(DemoRole, String)
    /// The session starts running a tool. `summary` is the line shown on the card.
    case startTool(DemoRole, name: String, summary: String)
    /// The tool it was running finishes.
    case finishTool(DemoRole, succeeded: Bool)
    /// The session stops and waits for the user: a permission, a question or a plan.
    case ask(DemoRole, RequestKind)
    /// If the user still has not answered the session's request, the demo answers it for them.
    case autoResolve(DemoRole)
    /// The session finishes its turn with this closing message.
    case finish(DemoRole, message: String)
    /// The session's turn ends with an error.
    case fail(DemoRole, error: String)
    /// Back to the opening scene: late arrivals leave, everyone else starts over.
    case restart
}

struct DemoStep {
    /// What happens, in a few words. Tests and logs use it.
    let name: String
    /// Seconds to wait after the previous step before this one happens.
    let wait: TimeInterval
    let actions: [DemoAction]

    init(_ name: String, wait: TimeInterval, _ actions: [DemoAction]) {
        self.name = name
        self.wait = wait
        self.actions = actions
    }
}

enum DemoScript {
    /// Happens once, the moment the demo starts (and again each time the story starts over):
    /// a permission request is already waiting, so there is something to try straight away.
    static let opening: [DemoAction] = [
        .ask(.cleaner, .permission(SampleData.bashPermission)),
    ]

    /// The loop. About 80 seconds from top to bottom.
    static let steps: [DemoStep] = [
        DemoStep("builder's build finishes and it starts editing", wait: 2.5, [
            .finishTool(.builder, succeeded: true),
            .startTool(.builder, name: "Edit", summary: "Edit Sources/App/Settings/ThemePicker.swift"),
        ]),
        DemoStep("explainer reads a file", wait: 2.5, [
            .startTool(.explainer, name: "read_file", summary: "Read src/cache/store.ts"),
        ]),
        DemoStep("tester finishes", wait: 3, [
            .finishTool(.tester, succeeded: true),
            .finish(.tester, message: "All 42 tests pass. I added coverage for nested arrays and malformed input, "
                + "and fixed an off-by-one in `advance()`."),
        ]),
        DemoStep("explainer goes back to thinking", wait: 2.5, [
            .finishTool(.explainer, succeeded: true),
        ]),
        DemoStep("dashboard session starts", wait: 3, [
            .startSession(.dashboard),
            .prompt(.dashboard, "Set up the web dashboard"),
        ]),
        DemoStep("builder runs the tests", wait: 3, [
            .finishTool(.builder, succeeded: true),
            .startTool(.builder, name: "Bash", summary: "swift test"),
        ]),
        DemoStep("cleaner's permission request resolves itself", wait: 4, [
            .autoResolve(.cleaner),
            .startTool(.cleaner, name: "Bash", summary: "rm -rf build && scripts/test.sh Engine"),
        ]),
        DemoStep("dashboard asks a question", wait: 3, [
            .ask(.dashboard, .question(SampleData.question)),
        ]),
        DemoStep("builder's tests fail and it fixes them", wait: 3, [
            .finishTool(.builder, succeeded: false),
            .startTool(.builder, name: "Edit", summary: "Edit Tests/ThemeTests.swift"),
        ]),
        DemoStep("planner session starts", wait: 3, [
            .startSession(.planner),
            .prompt(.planner, "Refactor the session engine"),
            .startTool(.planner, name: "Read", summary: "Read Sources/Core/Engine/SessionEngine.swift"),
        ]),
        DemoStep("cleaner finishes", wait: 3, [
            .finishTool(.cleaner, succeeded: true),
            .finish(.cleaner, message: "The build folder is clean and all 128 tests pass."),
        ]),
        DemoStep("dashboard's question answers itself", wait: 4, [
            .autoResolve(.dashboard),
            .startTool(.dashboard, name: "Bash", summary: "npm create vite@latest dashboard"),
        ]),
        DemoStep("planner proposes a plan", wait: 3, [
            .finishTool(.planner, succeeded: true),
            .ask(.planner, .plan(SampleData.plan)),
        ]),
        DemoStep("explainer finishes", wait: 3, [
            .finish(.explainer, message: "The cache has two levels: a small in-memory map in front of a disk store. "
                + "Entries expire after ten minutes, and writes go to both levels."),
        ]),
        DemoStep("migrator session starts", wait: 3, [
            .startSession(.migrator),
            .prompt(.migrator, "Migrate the database schema"),
            .startTool(.migrator, name: "Bash", summary: "npm run migrate -- --dry-run"),
        ]),
        DemoStep("builder asks to edit a file", wait: 3.5, [
            .finishTool(.builder, succeeded: true),
            .ask(.builder, .permission(SampleData.editPermission)),
        ]),
        DemoStep("planner's plan approves itself", wait: 4, [
            .autoResolve(.planner),
            .startTool(.planner, name: "Edit", summary: "Edit Sources/Core/Engine/SessionReducer.swift"),
        ]),
        DemoStep("migrator hits a rate limit", wait: 3, [
            .finishTool(.migrator, succeeded: false),
            .fail(.migrator, error: "Rate limit reached. Resets at 3:00 PM."),
        ]),
        DemoStep("builder's edit request resolves itself", wait: 4, [
            .autoResolve(.builder),
            .startTool(.builder, name: "Edit", summary: "Edit Sources/App/Shell/NotchPanel.swift"),
        ]),
        DemoStep("tester gets a new prompt", wait: 3, [
            .prompt(.tester, "Now add property-based tests"),
            .startTool(.tester, name: "shell", summary: "cargo test parser::properties"),
        ]),
        DemoStep("builder finishes", wait: 3, [
            .finishTool(.builder, succeeded: true),
            .finish(.builder, message: "The settings screen is in: six themes, a live preview, and the choice is "
                + "saved between launches."),
        ]),
        DemoStep("prototype wakes up", wait: 3, [
            .prompt(.prototype, "Prototype the onboarding flow"),
            .startTool(.prototype, name: "view_file", summary: "Read app/onboarding/Welcome.tsx"),
        ]),
        DemoStep("dashboard finishes", wait: 3.5, [
            .finishTool(.dashboard, succeeded: true),
            .finish(.dashboard, message: "The dashboard is scaffolded with your choices. Run `npm run dev` to see it."),
        ]),
        DemoStep("planner finishes", wait: 3, [
            .finishTool(.planner, succeeded: true),
            .finish(.planner, message: "The engine is split into a reducer and a coordinator. All tests pass."),
        ]),
        DemoStep("the story starts over", wait: 6, [
            .restart,
        ]),
    ]
}
