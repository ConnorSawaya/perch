# Antigravity + Gemini CLI fixtures

Sample payloads for the `AntigravityAdapter` and `GeminiAdapter`. The spec they
belong to is `docs/research/antigravity.md`.

**Nothing in this folder was captured from a real Antigravity or Gemini CLI
install.** Neither product is installed on the research machine (checked
2026-10-11: no `agy`, no `gemini`, no `~/.gemini`, no `/Applications/Antigravity*.app`).
Every file is one of three kinds, and the kind is in the file name:

| Marker in file name | Meaning | How much to trust it |
|---|---|---|
| `.docs.` / `docs-example` | Copied verbatim from Google's official documentation (fetched 2026-10-11). Only whitespace was changed. | Shape is authoritative for the documented version. Values are Google's examples. |
| `.src.` | Taken from a permissively licensed open-source project's test data or issue report. Values are that project's synthetic test values. | Shape was good enough for that project to ship against. |
| `.synth.` (and everything under `sequences/`) | Written by hand for Perch from the documented schema. Paths, ids and text are invented. | Shape follows the docs; details such as which keys are present when empty are a best guess. |

Files without a marker (`hooks.perch.*.json`, `hook.sh`, `statusline.sh`,
`*.perch-observer.json`, `gemini-cli/config/settings.hooks.perch.json`) are
**Perch's own proposed config and output**, not something an agent produces.

Replace these with real captures as soon as someone runs Perch against a real
install. The spec has a checklist for that ("Verification checklist").

A second reviewer re-checked this folder on 2026-10-11: every `.docs.` /
`docs-example` file was compared with the live documentation page and is
JSON-equal to the example there; every JSON, NDJSON and JSONL file parses. The
results are in the spec's "Verification log".

## Layout

```
hooks/            stdin JSON that Antigravity pipes to a hook command, one file per example
hook-outputs/     stdout JSON a hook may print back
config/           hooks.json variants, CLI settings.json fragments, Perch's shim scripts
statusline/       JSON the Antigravity CLI pipes to a statusLine/title command
headless/         `agy -p ... --output-format json|stream-json` output, `/usage` report
transcript/       brain/<id>/.system_generated/logs/transcript.jsonl lines
cache/            ~/.gemini/antigravity-cli/cache/last_conversations.json
sequences/        ordered hook events for one turn, for state-machine tests
gemini-cli/       the same idea for Gemini CLI (hooks, settings, session file)
```

## Provenance by file

### `hooks/` (Antigravity hook stdin)

| File | Provenance |
|---|---|
| `PreToolUse.run_command.docs.json` | Verbatim example, https://antigravity.google/docs/hooks ("PreToolUse") |
| `PostToolUse.run_command.error.docs.json` | Verbatim example, same page ("PostToolUse") |
| `PreInvocation.docs.json` | Verbatim example, same page ("PreInvocation") |
| `PostInvocation.docs.json` | Same page says the input is "Same as PreInvocation"; this is that example again |
| `Stop.model_stop.docs.json` | Verbatim example, same page ("Stop") |
| `*.synth.json` | Synthesized. Tool argument names come from the "Supported tools" list on the same page. `ArtifactMetadata` contents, the wording of `error` strings (except the one below) and all paths are invented |
| `PostToolUse.run_command.denied-by-hook.synth.json` | Synthesized, but the `error` text is the message quoted in google-antigravity/antigravity-cli issue #1053. Whether that text really arrives in a PostToolUse `error` field is a guess |

Note that the docs examples use `~` in `transcriptPath` although the field is
described as an absolute path. The synthesized files use absolute paths.

The payload carries **no event name**. The file name is the only place it is
recorded, exactly as in real life where the event name must come from the hook
command's own arguments.

### `hook-outputs/`

| File | Provenance |
|---|---|
| `PreToolUse.docs-example.json`, `PostToolUse.docs-example.json`, `PreInvocation.docs-example.json`, `PostInvocation.docs-example.json`, `Stop.docs-example.json` | Verbatim examples from https://antigravity.google/docs/hooks |
| `PreToolUse.perch-observer.json` | What Perch's shim prints for PreToolUse. Same answer wxtsky/CodeIsland (MIT) ships in `Sources/CodeIslandCore/AntigravityHookContract.swift` |
| `lifecycle.perch-observer.json` | What Perch's shim prints for every other event |
| `PreToolUse.deny.json` | Synthesized from the documented schema. Not used by the recommended design |

### `config/`

| File | Provenance |
|---|---|
| `hooks.docs-example.json` | Verbatim, https://antigravity.google/docs/hooks ("Schema and file format") |
| `hooks.perch.safe.json` | Perch's recommended default install (no PreToolUse) |
| `hooks.perch.with-pretooluse.json` | Perch's experimental install (adds an observing PreToolUse) |
| `hooks.perch.paused.json` | Same as safe, with the documented `"enabled": false` switch |
| `hooks.merged-with-user.json` | What `~/.gemini/config/hooks.json` should look like after Perch installs next to a user's own hook |
| `hooks.broken-nested-stop.src.json` | The shape reported as silently ignored for non-tool events in google-antigravity/antigravity-cli issue #925. Use it to test that Perch's installer never writes this |
| `hook.sh` | Perch's reference shim. `__PERCH_HOOK_PATH__` is a placeholder the installer replaces. Revised in review: `perch-hook` now runs in the background under a 2 second watchdog, because the first version blocked for as long as `perch-hook` did. Tested on the research machine with `/bin/sh` (bash 3.2, macOS 26.6) through both `sh -c` and shell-less exec, with stand-in `perch-hook` binaries that work, are missing, hang, or read a stdin that is never closed. Never run under Antigravity |
| `statusline.sh` | Perch's reference status-feed wrapper (opt-in feature). Same watchdog around the `perch-hook` call. Tested the same way, with and without a saved original command |
| `cli-settings.statusline.docs.json`, `cli-settings.title.docs.json` | Verbatim, https://antigravity.google/docs/cli/statusline and https://antigravity.google/docs/cli/title |
| `cli-settings.example.docs.json` | Verbatim, https://antigravity.google/docs/cli/reference |
| `cli-settings.perch-status-feed.synth.json` | Proposed result of enabling the status feed on a settings file that had two unrelated keys |

### `statusline/`

| File | Provenance |
|---|---|
| `payload.docs-example.json` | Verbatim, https://antigravity.google/docs/cli/statusline ("JSON payload example") |
| `payload.tool-confirmation.synth.json` | Synthesized. Adds fields the same page documents in its table but leaves out of its example (`tool_confirmation_pending`, `pending_input_count`) plus `conversation_title` and `cost`, which are documented only in the CLI changelog (1.1.27 and 1.1.21). The type of `cost` (number) is a guess |

### `headless/`

| File | Provenance |
|---|---|
| `result.docs.json`, `stream.simple.docs.ndjson`, `stream.tool-step.docs.ndjson` | Verbatim, https://antigravity.google/docs/cli/headless |
| `usage-report.src.json` | The synthetic report used in steipete/CodexBar (MIT), `Tests/CodexBarTests/AntigravityCLIUsageReportTests.swift`, for the output of `agy -p /usage --output-format json`. Not an official schema |

### `transcript/`

`transcript.synth.jsonl` is synthesized. The only attested facts are the four
keys `step_index`, `source`, `type`, `content`, the type names `USER_INPUT`,
`PLANNER_RESPONSE`, `RUN_COMMAND`, `VIEW_FILE`, the sources `USER_EXPLICIT` and
`MODEL`, and the `<USER_REQUEST>` / `<ADDITIONAL_METADATA>` wrapping of user
text. All of that comes from thedotmack/claude-mem (Apache-2.0),
`src/shared/transcript-parser.ts`, `src/cli/adapters/antigravity-cli.ts` and
`tests/antigravity-cli-compat.test.ts`. Google does not document this file's
schema. Real lines very likely carry more keys.

### `cache/`

`last_conversations.docs.json` is verbatim from
https://antigravity.google/docs/cli/commands/resume.

### `sequences/`

All synthesized. Each line is `{"event": "<hook name>", "payload": { ...hook stdin... }}`.
The `event` value stands for the event name Perch passes on the hook command
line. This wrapper is a neutral test format, not Perch's wire format.

### `gemini-cli/`

| File | Provenance |
|---|---|
| `hooks/*.synth.json` | Synthesized from the schema in google-gemini/gemini-cli (Apache-2.0) `docs/hooks/reference.md` and `packages/core/src/hooks/hookSystem.ts` (the `details` object of the Notification hook). Titles and messages are plausible, not captured |
| `config/settings.hooks.perch.json` | Perch's proposed block for `~/.gemini/settings.json`. Revised in review: every command ends in `>/dev/null 2>&1; echo '{}'`, because Gemini CLI's source turns a failed command with non-JSON output (for example a deleted binary, exit 127) into a `deny`. The suffix was checked with `bash -c` on the research machine; never run under Gemini CLI |
| `hook-outputs/observer.json` | What Perch prints for every Gemini CLI hook |
| `session/session.synth.jsonl` | Synthesized from the record types in `packages/core/src/services/chatRecordingTypes.ts`. The shape of `thoughts` entries and of `toolCalls[].result` is a guess |
