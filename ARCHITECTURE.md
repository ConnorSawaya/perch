# Perch — architecture

Perch is a menu-bar app that lives in the MacBook notch and shows what your AI coding agents are
doing. It is original code with no third-party dependencies, no analytics, no network calls and no
access to anyone's login or keychain.

## 1. The whole idea in one picture

```
 coding agent (claude, codex, ...)            Perch.app
 ───────────────────────────────             ─────────────────────────────────────────────
  fires a hook on every event
        │ JSON on stdin
        ▼
  perch-hook  (tiny helper) ── one line ──►  HookServer          (Unix socket)
        ▲                                        │ HookEnvelope
        │ one line back (only for                ▼
        │ blocking requests)                  AgentAdapter       (per agent: translate)
        │                                        │ NormalizedEvent
        │                                        ▼
        └────── HookReply ◄── AgentAdapter ◄── SessionEngine ──► SessionStore ──► SwiftUI views
                              (encode)        (state + pending)   (plain data)     (notch panel)
```

- **Helper** (`Sources/Helper`): forwards an event and, for blocking requests, waits for the answer.
- **Adapter** (`Sources/Core/Adapters/<Agent>`): the only place that knows an agent's formats.
- **Engine** (`Sources/Core/Engine`): turns normalized events into session state.
- **Stores** (`Sources/Contract/Stores.swift`): plain observable data the views draw.
- **Views** (`Sources/App`): draw stores, call `AppActions`.

## 2. Folder map and ownership

`Sources/Contract/**` is **frozen**: shared types, stores, protocols, settings, sample data. Read it
first; do not edit it. If something is missing, work around it inside your own module and list the
gap in your final report.

| Folder | Module | Provides (fixed names — other modules rely on them) |
|---|---|---|
| `Sources/Helper/` | runtime | `perch-hook` command-line tool (Foundation only; compiled with `Sources/Contract/Wire.swift` alone) |
| `Sources/Core/Runtime/` | runtime | `final class HookServer: HookServing` — `init(socketURL: URL = PerchPaths.socketURL)`; `enum HelperInstaller { static func install(from bundledHelper: URL) throws; static var isInstalled: Bool }` |
| `Sources/Core/Engine/` | engine | `final class SessionEngine: SessionEngineProtocol` — `init(store: SessionStore, settings: AppSettings, adapters: [AgentKind: AgentAdapter], sounds: SoundPlaying?, jumper: TerminalJumping?, usage: UsageEngineProtocol?, notifier: SystemNotifying?)` |
| `Sources/Core/Adapters/Claude/` | claude | `final class ClaudeAdapter: AgentAdapter` — `init()` |
| `Sources/Core/Adapters/Codex/` | others | `final class CodexAdapter: AgentAdapter` — `init()` |
| `Sources/Core/Adapters/Antigravity/` | others | `final class AntigravityAdapter: AgentAdapter` — `init()` |
| `Sources/Core/Adapters/Gemini/` | others | `final class GeminiAdapter: AgentAdapter` — `init()` |
| `Sources/Core/Usage/` | usage | `final class UsageEngine: UsageEngineProtocol` — `init(store: UsageStore, settings: AppSettings)` |
| `Sources/Core/System/` | system | `final class TerminalJumper: TerminalJumping` — `init()`; `final class SoundEngine: SoundPlaying` — `init(settings: AppSettings)`; `final class SystemNotifier: SystemNotifying` — `init(settings: AppSettings)`; `enum LoginItem { static func setEnabled(_ on: Bool) -> Bool; static var isEnabled: Bool }`; `enum ProcessProbe` (pid alive, pid → tty, parent chain, frontmost app) |
| `Sources/App/Shell/` | shell | `final class NotchWindowController` — `init(env: AppEnv, content: AnyView)`, `show()`, `hide()`; `final class StatusItemController` — `init(env: AppEnv)`; `final class ShortcutMonitor` — `init(env: AppEnv)`; `final class SettingsWindowController` — `init(env: AppEnv, content: AnyView)`, `show(tab: SettingsTab?)` |
| `Sources/App/Design/` | design | `struct Theme` + `Theme.current(_ settings: AppSettings)`, shared components (see §7) |
| `Sources/App/Panel/` | design | `struct IslandRootView: View` (`init()`): the pill and the expanded panel |
| `Sources/App/Cards/` | cards | `ApprovalCardView(request:session:)`, `QuestionCardView(request:session:)`, `PlanCardView(request:session:)`, `UsagePanelView()`, `ActivityPanelView()` |
| `Sources/App/Settings/` | settings | `struct SettingsRootView: View` (`init()`), including the "How it works" tab |
| `Sources/App/Demo/` | settings | `final class DemoDirector` — `init(env: AppEnv)`, `start()`, `stop()`; `enum SnapshotRunner { @MainActor static func run(outputDir: URL) }` |
| `Sources/App/Main/` | integration | `PerchApp` (`@main`), `AppController: AppActions` — wires everything together |
| `Tests/` | each module | `<Name>Tests.swift` defining `func run<Name>Tests(_ t: TestRunner)`; `<Name>Snapshots.swift` for views |

Modules may add as many extra files and private types inside their own folders as they like.

## 3. Rules that apply everywhere

1. **Fail open.** If Perch is closed, crashed or slow, the agent must behave exactly as if Perch
   were not installed. The helper never prints anything unless the app told it to.
2. **Never clobber a config file.** Merge, keep everything that is not ours, write a timestamped
   backup to `PerchPaths.backupsDir` first, write atomically. Uninstall removes only our entries.
3. **No network, no credentials.** Usage comes from files the agents already write and from the
   status line. Never read the keychain or tokens.
4. **Main-thread stores.** Stores are touched on the main thread only (see `Services.swift`).
5. **No global shortcuts.** Keyboard shortcuts work only while the pointer is over the open panel
   (the panel becomes the key window then, without activating Perch or stealing the terminal's focus
   at any other time).
6. **Readable code.** Every file starts with a short plain-English comment saying what it is for.
   Prefer small files and obvious names over cleverness. No dead code, no TODOs.
7. **Original work.** No vendor logos or copied artwork in the project; draw glyphs in code or use
   SF Symbols. The one exception is at run time: `AgentIconProvider` asks macOS for the icon of an
   agent's installed app (as the Dock does) and `AgentBadge` falls back to its drawn monogram.
   No code copied from GPL projects.
8. **Toolchain.** Swift 5 language mode, macOS 15 target, `swiftc` only (no SwiftPM, no Xcode):
   no `#Preview`, no asset catalogs, no XCTest, no `.metal` shaders. Use `if #available(macOS 26, *)`
   for anything newer than macOS 15.

## 4. Commands

Run from the project root (paths may contain spaces — quote them).

```bash
scripts/typecheck.sh Sources/Core/Engine              # Contract + your files: does it compile?
scripts/test.sh Engine Sources/Core/Engine            # compile + run Tests/EngineTests.swift
scripts/snapshot.sh Panel Sources/App/Design Sources/App/Panel   # render Tests/PanelSnapshots.swift to PNGs
scripts/build.sh                                      # whole app -> build/Perch.app
```

Snapshots land in `.build/snapshots/<Name>/*.png`; open them to check your work.

## 5. The helper: `perch-hook`

```
perch-hook --agent <claude|codex|antigravity|gemini> [--channel hook|statusline|notify]
           [--event <Name>] [--wait] [--timeout <seconds>] [-- <extra args>...]
```

1. Read all of stdin (if stdin is not a terminal) into `payload`. Do not parse it.
2. Fill a `HookEnvelope`: agent, channel, event, payload, args after `--`, the whitelisted env
   vars (`HookEnvelope.forwardedEnvKeys`), `pid` (`$CLAUDE_PID` if set, else the parent process
   id), `tty` (the controlling terminal of that pid via `ps -o tty=`; nil for "??"), cwd,
   `wantsReply` (= `--wait`), `sentAt`.
3. Connect to `PerchPaths.socketURL`. **If that fails, exit 0 immediately with no output.**
4. Write the envelope as one JSON line.
5. Without `--wait`: exit 0. With `--wait`: read one line, decode a `HookReply`, write its
   `stdout` text to stdout exactly, exit with its `exitCode`. If the socket closes without a
   reply, or `--timeout` passes, exit 0 with no output.
6. For `--channel statusline` the helper prints nothing (the status line script prints its own text).

It must start and finish in a few milliseconds and never write to stderr in normal operation.

## 6. Engine behaviour

Events → state (per session):

| Event | Effect |
|---|---|
| `sessionStarted` | create the card (or revive it), state `idle`; title falls back to the folder name |
| `promptSubmitted` | state `working`; first prompt becomes the title; `turnCount += 1`; clear error/last message |
| `toolStarted` | state `runningTool`, `currentTool` set, appended to `recentTools` (cap 24), `toolCount += 1` |
| `toolFinished` | mark the tool finished; state `working` |
| `permissionRequested` / `questionAsked` / `planProposed` | add a `PendingRequest`; state `needsApproval` / `needsAnswer` / `planReview`; pulse `.attention`; sound; maybe auto-expand |
| request resolved or withdrawn | remove it; state returns to `working` (or the next pending request's state) |
| `turnFinished` | state `done` (or `working` if `backgroundWork`); `lastMessage` set; pulse `.done`; sound |
| `turnFailed` | state `failed`, `errorText` set; pulse `.failed`; sound |
| `subagentStarted` / `subagentStopped` | adjust `activeSubagents` (never below 0) |
| `compactionStarted` / `compactionFinished` | state `compacting` / back to `working` |
| `usageUpdated`, `metadata` | update fields only |
| `notification` | "permission_prompt"/"idle_prompt" kinds act as fallbacks when no blocking hook is in use |
| `sessionEnded` | withdraw its pending requests; state `ended`; remove the card after a short delay |

An event for an unknown session creates the session first (hooks can arrive mid-session).

Blocking requests:

- A request event that arrives **with** a `ReplyHandle` creates a `PendingRequest` and keeps the
  handle. `resolve(id, decision)` asks the session's adapter to `encode` the decision and replies.
- If the matching setting is off (`approvalsInNotch`, `questionsInNotch`, `planReviewInNotch`),
  or the agent is disabled, reply `HookReply.passthrough` at once.
- `autoAllowReadOnly`: permission requests for read-only tools are allowed at once.
- If the handle disconnects before a decision (the user answered in the terminal, or the agent
  quit), the request is removed and the session goes back to `working`.
- A request event **without** a handle is display-only (no buttons that pretend to work).
- `Decision.passToTerminal` replies with `HookReply.passthrough`.

Housekeeping (timer, every ~3 s): drop sessions whose process id no longer exists; apply
`idleCleanupMinutes`; fire `reminderSeconds` reminders; hide headless / desktop-app sessions
according to settings. Sounds are skipped when `muteWhenTerminalFocused` and the session's tab is
frontmost, and during quiet hours.

Every envelope and every decision is also appended to `SessionStore.activity` (when
`activityLogEnabled`) with a plain-English summary, so the "How it works" screen can show it live.

## 7. Look and feel

Dark, glassy "island" that grows out of the notch. It should feel alive but calm.

- **Pill (collapsed):** hugs the notch; a status glyph on the left of the notch, a small readout
  on the right (count of sessions needing you, or a usage ring). Idle = almost invisible.
- **Panel (expanded):** drops down from the notch with a spring; tabs Sessions / Usage / Activity;
  session cards with state colour, title, folder, elapsed time, current tool, tool sparkline;
  request cards (approval with diff, question, plan) appear above the list.
- **Graphics:** animated mascot/orb that reflects state, a rotating gradient glow when something
  needs you, a particle burst when a task finishes, usage rings, sparklines. All drawn in code
  (Canvas / shapes / gradients). Every effect has a toggle and respects `reduceMotion`.
- **Themes:** `ThemeID` picks the palette. Each agent has an accent colour (`useAgentColors`).
- **Text:** scale all font sizes by `settings.textScale`. Plain words, no jargon.

Sizes shared by the window shell and the views live in `Sources/Contract/Layout.swift`
(`IslandMetrics`): the window is a fixed transparent rectangle pinned top-centre; views draw the
island at its top-centre and report the height they want through `UIState.desiredPanelHeight`.

`Sources/App/Design` owns shared pieces other view modules must reuse instead of reinventing:
`Theme` (colours, fonts, spacing, radii), `PerchButtonStyle`, `Chip`, `StateDot`, `AgentBadge`,
`GlowBorder`, `ProgressRing`, `Sparkline`, `CardBackground`, `SectionHeader`, `KeyHint`.

## 8. Which settings each module honours

- **shell:** displayMode, hideWhenNoSessions, hideInFullScreen, showOnNonNotchDisplays,
  showMenuBarIcon, expandTrigger, hoverDelay, collapseDelay, keepExpandedWhilePending,
  panelWidth, panelMaxHeight, shortcutsEnabled
- **integration (AppController):** autoExpandOnAttention, autoExpandOnDone (by watching `SessionStore.pulse`)
- **engine:** idleCleanupMinutes, showHeadlessSessions,
  showDesktopAppSessions, approvalsInNotch, questionsInNotch, planReviewInNotch,
  autoAllowReadOnly, activityLogEnabled, reminderEnabled, reminderSeconds, agent enable flags
- **system:** soundsEnabled, volume, soundPack, soundOn*, muteWhenTerminalFocused (with engine),
  quiet hours, systemNotifications, launchAtLogin
- **usage:** usageRefreshMinutes, collectActivityStats, showCostEstimates, usageWarnings, warnAtPercent
- **design / cards:** theme, pillStyle, showGlow, showParticles, showMascot, mascotStyle,
  useAgentColors, reduceMotion, textScale, showToolSparkline, showElapsedTime, showGitBranch,
  showModel, showProjectPath, sortMode, showSubagents, showDiffPreview, diffMaxLines,
  showAlwaysAllow, confirmDangerous, showUsageInPill, pillMetric, usageShowRemaining
- **settings:** shows every one of the above, grouped by tab, each with a one-line explanation
