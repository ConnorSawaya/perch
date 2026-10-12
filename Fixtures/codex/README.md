# Codex CLI fixtures

Reference version: Codex CLI **0.162.1** (`openai/codex` tag `rust-v0.162.1`, Apache-2.0). Spec: `docs/research/codex.md`.

**None of these files were captured from a live Codex run** — Codex is not installed on the research machine. Provenance per file is stated below as one of:

- **COPIED** — values taken verbatim from upstream source or docs (path given).
- **SYNTHESIZED (schema-checked)** — invented values; the field set, types, enums and required/optional status were machine-validated against the upstream generated JSON Schema for that event (`codex-rs/hooks/schema/generated/<event>.command.{input,output}.schema.json`).
- **SYNTHESIZED (from types)** — invented values; shape written by hand from the Rust type definitions. Not machine-validated. Most likely to differ from reality.

All ids, paths, prompts, commands, token counts and the model slug (`gpt-5.2-codex`) are made up. Replace these fixtures with real captures once a Codex install is available.

**Review (2026-10-11):** a second agent re-validated every `hooks/` and `decisions/` file against the upstream schemas at `rust-v0.162.1` (all pass) and re-checked the rollout shapes against the Rust types. One fixture was wrong and has been fixed: in the paginated rollout, `item_completed` → `CommandExecution.cwd` must be a `file:` URI. Notes below that changed are marked *(review)*.

## `hooks/` — hook stdin payloads (what `perch-hook --agent codex` receives)

One JSON object per file, exactly as Codex writes it to the hook's stdin. All are **SYNTHESIZED (schema-checked)**.

| File | Event | Notes |
|---|---|---|
| `SessionStart.startup.json` | SessionStart | `source: startup`. Fires with the first turn, not when the TUI opens. |
| `SessionStart.resume.json` | SessionStart | `source: resume`. |
| `UserPromptSubmit.json` | UserPromptSubmit | |
| `PreToolUse.Bash.json` | PreToolUse | shell command; `tool_input.command` is a string. |
| `PostToolUse.Bash.json` | PostToolUse | `tool_response` is the command output string. Also sent for commands that exit non-zero; not sent while a backgrounded command is still running *(review)*. |
| `PreToolUse.apply_patch.json` | PreToolUse | file edit; patch text is in `tool_input.command`. |
| `PostToolUse.apply_patch.json` | PostToolUse | `tool_response` starts with `Exit code: 0` (shape from upstream test `core/tests/suite/hooks.rs`; exact text invented). |
| `PreToolUse.mcp.json` | PreToolUse | `tool_name` = `mcp__<server>__<tool>`, `tool_input` = raw arguments. |
| `PreToolUse.request_user_input.json` | PreToolUse | Codex asking the user a question. `tool_input` is the model's raw arguments; shape from the model-facing tool schema in `codex-rs/core/src/tools/handlers/request_user_input_spec.rs` (`questions[].{id, header, question, options[].{label, description}}`). That this tool emits PreToolUse is read from source (handler does not override the default hook payload) but **has not been observed** *(review)*. |
| `PreToolUse.update_plan.json` | PreToolUse | plan/todo update. `tool_input` shape from `codex-rs/protocol/src/plan_tool.rs` (`explanation?`, `plan[].step`, `plan[].status` ∈ `pending\|in_progress\|completed`). The hooks docs name `update_plan` as a tool covered by PreToolUse; **not observed** *(review)*. |
| `PermissionRequest.Bash.json` | PermissionRequest | with `tool_input.description` (model's justification). No `tool_use_id` on this event. |
| `PermissionRequest.Bash.no-description.json` | PermissionRequest | `description` absent. |
| `PermissionRequest.network.json` | PermissionRequest | network approval: `description` = `network-access <target>` (format from `core/src/tools/approvals.rs`). |
| `PermissionRequest.apply_patch.json` | PermissionRequest | |
| `PermissionRequest.mcp.json` | PermissionRequest | |
| `PermissionRequest.subagent.json` | PermissionRequest | from a spawned subagent: carries `agent_id` (the subagent's own thread id) / `agent_type`. `session_id` is the parent/root session id (docs: "Subagent hooks use the parent session id"; source: `Session::session_id`); `transcript_path` is the subagent's rollout *(review: no longer an assumption, still not observed)*. |
| `Stop.json` | Stop | end of a turn. |
| `Interrupt.json` | Interrupt | user interrupted the turn. |
| `SessionEnd.json` | SessionEnd | `reason` is always `other`; this event has no `model` field. |
| `SubagentStart.json` | SubagentStart | `transcript_path` = the subagent's own rollout; `session_id` = parent/root session id *(review)*. |
| `SubagentStop.json` | SubagentStop | `transcript_path` = parent rollout, `agent_transcript_path` = subagent rollout. |
| `PreCompact.json`, `PostCompact.json` | Pre/PostCompact | `trigger: auto`; no `permission_mode` field. |

## `decisions/` — hook stdout for `PermissionRequest`

| File | Provenance | Meaning |
|---|---|---|
| `PermissionRequest.allow.stdout.json` | SYNTHESIZED (schema-checked); shape matches the docs example at https://learn.chatgpt.com/docs/hooks | approve, skip Codex's prompt |
| `PermissionRequest.deny.stdout.json` | SYNTHESIZED (schema-checked) | reject; `message` is shown to the model |
| `PermissionRequest.no-decision.stdout.txt` | intentionally **empty** | exit 0 with no output = "let Codex ask in the terminal" |

## `notify/` — legacy `notify` program argument

| File | Provenance |
|---|---|
| `agent-turn-complete.json` | **COPIED** from `codex-rs/hooks/src/legacy_notify.rs`, test helper `expected_notification_json()` (Apache-2.0). This JSON arrives as the last argv argument, not on stdin. |

## `config/` — what Perch writes / reads

| File | Provenance | Notes |
|---|---|---|
| `hooks.perch-only.json` | SYNTHESIZED (from types); format per https://learn.chatgpt.com/docs/hooks and `codex-rs/config/src/hook_config.rs` | `$CODEX_HOME/hooks.json` when the user had none. The helper path is a placeholder. |
| `hooks.merged-with-user-hooks.json` | SYNTHESIZED (from types) | expected result of merging into a file that already has user hooks: Perch's group is **appended last** in each event array; `description` and the user's entries are untouched. Use as the golden file for installer tests. |
| `config.hooks-state.example.toml` | SYNTHESIZED (from types); key format from `codex-rs/hooks/src/lib.rs` `hook_key` | what **Codex** writes to `config.toml` after the user trusts hooks. Hash strings are placeholders. Perch only reads this, never writes it. |

## `rollout/` — session transcripts

| File | Provenance | Notes |
|---|---|---|
| `rollout-2026-10-10T09-15-02-019a9d1e-….jsonl` | SYNTHESIZED (from types) | **paginated** history mode (default for new non-ephemeral threads in 0.162.1, and already at 0.158.0): has `ordinal`, `item_completed` events, no `user_message`/`agent_message` events. Two turns: one completed (exec + apply_patch + 3 `token_count`), one aborted (`turn_aborted`, reason `interrupted`). |
| `legacy/rollout-2026-10-10T09-15-02-019a9d1e-….jsonl` | SYNTHESIZED (from types); the `session_meta` / `response_item` / `user_message` line shapes follow the upstream test helper `codex-rs/app-server/tests/common/rollout.rs` | same conversation in **legacy** mode: no `ordinal`, `user_message` / `agent_message` events instead of `item_completed`. |
| `session_index.jsonl` | SYNTHESIZED (from types), struct `SessionIndexEntry` in `codex-rs/rollout/src/session_index.rs` | `$CODEX_HOME/session_index.jsonl` thread-name index. |

Rollout caveats:

- Filename timestamp and directory date are local time; line `timestamp` is UTC. The fixture pretends the machine is in UTC-7.
- `token_count.rate_limits` uses `resets_at` (Unix seconds). Codex ≤ 0.47 wrote `resets_in_seconds` *(review: was "≤ 0.46")*; no fixture for that variant.
- `turn_context` and `session_meta` payloads are trimmed to the fields Perch reads; real lines contain more (base instructions, sandbox details, permission profiles…).
- `parsed_cmd`, `item` ids and the exec output text format are illustrative.
- In `item_completed` → `CommandExecution`, `cwd` is a `file:` URI (`file:///Users/alex/code/acme-api`), because the Rust type is `PathUri`. Everywhere else in the rollout (`session_meta.cwd`, `turn_context.cwd`) and in hook payloads `cwd` is a plain path *(review: fixture corrected)*.
- Compressed rollouts (`.jsonl.zst`, files older than 7 days) only exist when the user enabled the under-development flag `features.local_thread_store_compression`, which is off by default in 0.162.1 *(review: the original said this always happens)*; no compressed fixture is included.

## Regenerating / validating

The generator and the schema validator used to produce these files are throwaway scripts kept outside the repo. To re-validate by hand, fetch the schemas from
`https://raw.githubusercontent.com/openai/codex/rust-v0.162.1/codex-rs/hooks/schema/generated/` and check each `hooks/<Event>.*.json` against `<event-kebab-case>.command.input.schema.json`.
