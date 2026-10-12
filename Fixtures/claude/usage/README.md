# Claude usage fixtures

Synthetic Claude Code data for testing Perch's usage scanner, cost estimate, context
estimate, session titles and status line parsing. The spec they test is
`docs/research/claude-usage.md`.

**Everything here is invented.** The line shapes copy the *key names and key order* seen in
real Claude Code 2.1.295 / 2.1.296 transcripts and status line payloads; no real prompt,
path, id or number is reused, except three token/cost vectors that reproduce cost figures
Claude Code itself wrote (see "Golden vectors").

```
pricing.json                 price table (USD per million tokens) + model id rules
expected.json                every number a correct implementation must produce
projects/                    a fake ~/.claude/projects tree (6 transcript files)
incremental/                 3 snapshots of one growing file
statusline/                  status line stdin samples + one perch-hook envelope
set-aside/                   one session whose older transcripts were set aside (2 extra file names)
sessions/41001.json          a ~/.claude/sessions/<pid>.json sample: idle, named by the user
sessions/41002.json          the same for a session waiting on a permission prompt
tools/make_fixtures.py       regenerates all of the above except pricing.json (expected.json comes from its TRUTH list)
tools/reference_scan.py      small reference scanner; re-reads the files and checks expected.json
```

Regenerate and check (Python 3.9+, standard library only):

```
cd Fixtures/claude/usage
python3 tools/make_fixtures.py
python3 tools/reference_scan.py --update-expected   # refreshes expected.json's scanDiagnostics
python3 tools/reference_scan.py                     # must print: OK: fixtures match expected.json
```

Test rules:

* Compare costs with a tolerance of `1e-9`.
* Inject the time zone. `expected.json` has days for `America/Los_Angeles` and for `UTC`.
* Ingest files in ascending path order (session `1111…` before its fork `2222…`). The
  result must also be the same if a file is scanned twice.
* Totals come from transcripts only. `cost-state` is reported per session and is not added.

## The sessions

| Session | Project dir | What it is |
| :- | :- | :- |
| `1111…` (A) | `-Users-test-dev-alpha` | Terminal session, 2.1.296. Has 2 subagent files. |
| `2222…` (B) | `-Users-test-dev-alpha` | A fork of A: starts with copies of A's first lines, then continues. |
| `3333…` (C) | `-Users-test-dev-beta-site` | Desktop-app session, 2.1.295, with the odd cases. cwd has a space. |
| `5555…` (E) | `-Users-test-dev-beta-site` | One response, then a compaction, then a `cost-state` line. |
| `4444…` (D) | `incremental/` only | Not part of the totals below. |
| `6666…` (F) | `set-aside/` only | Not part of the totals below. See "Set-aside transcripts". |

## The 18 API responses ("events")

37 `assistant` lines are in `projects/`; they describe 18 real API responses.
in / out / w5m / w1h / read are tokens; day columns are the local day of the response's
**first** line.

| # | Session | Model | First line (UTC) | in | out | w5m | w1h | read | Cost USD | Day LA | Day UTC | What it exercises |
| :- | :- | :- | :- | -: | -: | -: | -: | -: | -: | :- | :- | :- |
| a1 | A | claude-opus-5-5 | 10-10 06:50:00 | 3 | 420 | 0 | 12000 | 0 | 0.104412 | 10-09 | 10-10 | 3 lines for 3 content blocks, each with the same final usage. Copied into B. |
| a2 | A | claude-opus-5-5 | 10-10 06:59:58 | 2 | 900 | 0 | 1500 | 12000 | 0.032408 | 10-09 | 10-10 | 2 lines that straddle local midnight (23:59:58 and 00:00:03 LA). Copied into B. |
| a3 | A | claude-opus-5-5 | 10-10 07:10:00 | 2 | 150 | 0 | 800 | 13500 | 0.032108 | 10-10 | 10-10 | 2 web searches (+$0.02). Replayed in a sidechain file with another requestId. |
| a4 | A | claude-opus-5-5 | 10-10 07:12:00 | 2 | 2 | 0 | 300 | 14300 | 0.005308 | 10-10 | 10-10 | Interrupted: only placeholder lines exist (`stop_reason` null). Counted as is. |
| a6 | A | claude-haiku-5-5 | 10-10 18:00:00 | 4 | 120 | 0 | 9000 | 30000 | 0.0021604 | 10-10 | 10-10 | Model switch. Prompt 39,004 tokens: normal Haiku prices. |
| a7 | A | claude-haiku-5-5 | 10-10 18:05:00 | 10 | 500 | 0 | 2000 | 120000 | 0.009255 | 10-10 | 10-10 | Prompt 122,010 tokens (over 100,000): long-context Haiku prices for the whole request. |
| a8 | A | claude-opus-5-5 | 10-10 18:10:00 | 5 | 1000 | 0 | 0 | 50000 | 0.06004 | 10-10 | 10-10 | `speed: "fast"`: 2x. Last response of A, so it sets A's context. |
| s1 | A (subagent) | claude-haiku-5-5 | 10-10 07:11:00 | 2 | 380 | 11000 | 0 | 19000 | 0.0017552 | 10-10 | 10-10 | Sidechain. 2 placeholder lines (output 6), a foreign line in between, then the final line. 5-minute cache write. |
| s2 | A (subagent) | claude-haiku-5-5 | 10-10 07:11:30 | 2 | 210 | 3000 | 0 | 30000 | 0.0007802 | 10-10 | 10-10 | Sidechain. Placeholder (output 5), then final. |
| q1 | A (sidechain) | claude-opus-5-5 | 10-10 07:10:30 | 2 | 60 | 0 | 0 | 14000 | 0.004008 | 10-10 | 10-10 | A sidechain response with its own id: counted. |
| b1 | B | claude-sonnet-5-5 | 10-11 02:00:00 | 6 | 254 | 0 | 12100 | 56850 | 0.056637 | 10-10 | 10-11 | 2 lines. Local day differs from UTC day. |
| b2 | B | claude-sonnet-5-5 | 10-11 02:01:00 | 3 | 4 | 0 | 500 | 69000 | 0.008946 | 10-10 | 10-11 | Still streaming at end of file: one placeholder line. Sets B's context. |
| c1 | C | claude-fable-5-1 | 10-11 19:00:00 | 8 | 2000 | 0 | 40000 | 100000 | 0.92508 | 10-11 | 10-11 | 2 lines, and the second line is written twice (same uuid). |
| c4 | C | claude-sonnet-5-5 | 10-11 19:10:00 | 1000 | 2000 | 10000 | 0 | 50000 | 0.0572 | 10-11 | 10-11 | `inference_geo: "us"`: 1.1x. 5-minute cache write on a main line. |
| c3 | C | claude-next-9 | 10-11 19:20:00 | 10 | 10 | 0 | 0 | 0 | 0 | 10-11 | 10-11 | Unknown model: tokens counted, cost 0, listed in `unpricedModels`. |
| c8 | C | claude-sonnet-5-5 | 10-11 19:30:00 | 50 | 50 | 0 | 0 | 0 | 0.0006 | 10-11 | 10-11 | No `requestId`; 2 lines for one response. |
| c2 | C | claude-opus-4-5-20251101 | 10-11 19:40:00 | 100 | 300 | 5000 | 0 | 20000 | 0.04925 | 10-11 | 10-11 | Dated model id, old usage shape (no `cache_creation` object), a legacy `costUSD: 9.99` that must be ignored. 200K context window. |
| e1 | E | claude-opus-5-5 | 10-11 21:00:00 | 10 | 3000 | 0 | 20000 | 580000 | 0.33604 | 10-11 | 10-11 | Followed by a `compact_boundary` line. |

Lines that must NOT become events:

| Where | Line | Why |
| :- | :- | :- |
| A | `model: "<synthetic>"`, `isApiErrorMessage: true`, zero usage | Not an API response. |
| A's `agent-aside00000000001.jsonl` | replay of a3: same `message.id`, `requestId` `req_01FIXTUREa3replay`, `isSidechain: true` | A sidechain copy of a main-conversation response. |
| B | the first 5 `assistant` lines | Copies of a1 and a2 (same `message.id` + `requestId`). They stay attributed to A. |
| C | `{this line is not valid JSON…` | Malformed line: skip it, keep going. |

## Line accounting

| | Count |
| :- | -: |
| Transcript files | 6 |
| `assistant` lines | 37 |
| ...skipped as synthetic/error | 1 |
| ...usage lines | 36 |
| ...dropped as sidechain replay | 1 |
| ...merged into an existing response (duplicates) | 17 |
| ...of those, replaced a smaller usage (upgrades) | 2 |
| **Unique responses** | **18** |
| Malformed lines | 1 |

If you add up every usage line without de-duplicating you get input 1,329, output 21,633,
cache write 309,900, cache read 1,617,300. A correct scanner must NOT produce those.
"First line wins" de-duplication is also wrong here: it would give s1 and s2 an output of 6
and 5 tokens instead of 380 and 210.

## Expected totals

All time:

| Responses | Input | Output | Cache write 5m | Cache write 1h | Cache read | Total tokens | Web searches | Cost USD |
| -: | -: | -: | -: | -: | -: | -: | -: | -: |
| 18 | 1,221 | 11,360 | 29,000 | 98,200 | 1,178,650 | 1,318,431 | 2 | 1.6859878 |

By model (the key is the normalised model id):

| Model | Responses | Input | Output | Write 5m | Write 1h | Cache read | Cost USD |
| :- | -: | -: | -: | -: | -: | -: | -: |
| claude-fable-5-1 | 1 | 8 | 2,000 | 0 | 40,000 | 100,000 | 0.92508 |
| claude-haiku-5-5 | 4 | 18 | 1,210 | 14,000 | 11,000 | 199,000 | 0.0139508 |
| claude-next-9 (unpriced) | 1 | 10 | 10 | 0 | 0 | 0 | 0 |
| claude-opus-4-5 | 1 | 100 | 300 | 5,000 | 0 | 20,000 | 0.04925 |
| claude-opus-5-5 | 7 | 26 | 5,532 | 0 | 34,600 | 683,800 | 0.574324 |
| claude-sonnet-5-5 | 4 | 1,059 | 2,308 | 10,000 | 12,600 | 175,850 | 0.123383 |

By project:

| Project dir | Path | Responses | Input | Output | Write 5m | Write 1h | Cache read | Cost USD |
| :- | :- | -: | -: | -: | -: | -: | -: | -: |
| -Users-test-dev-alpha | /Users/test/dev/alpha | 12 | 43 | 4,000 | 14,000 | 38,200 | 428,650 | 0.3178178 |
| -Users-test-dev-beta-site | /Users/test/dev/beta site | 6 | 1,178 | 7,360 | 15,000 | 60,000 | 750,000 | 1.36817 |

By session (subagent usage belongs to the parent session):

| Session | Responses | Input | Output | Write 5m | Write 1h | Cache read | Cost USD |
| :- | -: | -: | -: | -: | -: | -: | -: |
| 1111… (A) | 10 | 34 | 3,742 | 14,000 | 25,600 | 302,800 | 0.2522348 |
| 2222… (B) | 2 | 9 | 258 | 0 | 12,600 | 125,850 | 0.065583 |
| 3333… (C) | 5 | 1,168 | 4,360 | 15,000 | 40,000 | 170,000 | 1.03213 |
| 5555… (E) | 1 | 10 | 3,000 | 0 | 20,000 | 580,000 | 0.33604 |

Main conversation vs sidechain: main 15 responses, $1.6794444; sidechain 3 responses, $0.0065434.

By day, `America/Los_Angeles`:

| Day | Responses | Input | Output | Write 5m | Write 1h | Cache read | Cost USD |
| :- | -: | -: | -: | -: | -: | -: | -: |
| 2026-10-09 | 2 | 5 | 1,320 | 0 | 13,500 | 12,000 | 0.13682 |
| 2026-10-10 | 10 | 38 | 2,680 | 14,000 | 24,700 | 416,650 | 0.1809978 |
| 2026-10-11 | 6 | 1,178 | 7,360 | 15,000 | 60,000 | 750,000 | 1.36817 |

By day, `UTC`:

| Day | Responses | Input | Output | Write 5m | Write 1h | Cache read | Cost USD |
| :- | -: | -: | -: | -: | -: | -: | -: |
| 2026-10-10 | 10 | 34 | 3,742 | 14,000 | 25,600 | 302,800 | 0.2522348 |
| 2026-10-11 | 8 | 1,187 | 7,618 | 15,000 | 72,600 | 875,850 | 1.433753 |

`expected.json` also has the per-day breakdown by model, project and session.

## Session facts

| Session | Title | Title comes from | Context tokens | Window | Context % | Context comes from |
| :- | :- | :- | -: | -: | -: | :- |
| A | `Alpha refactor v2` | the last `custom-title` line | 50,005 | 1,000,000 | 5.0005 | a8 (last main-conversation response) |
| B | `Retry logic for the uploader` | the last `ai-title` line | 69,503 | 1,000,000 | 6.9503 | b2, a streaming placeholder line |
| C | `Build the landing page hero section with a responsive layou…` | first typed prompt, cut to 60 characters | 25,100 | 200,000 | 12.55 | c2 |
| E | `Tidy the build scripts` | first typed prompt | 12,000 | 1,000,000 | 1.2 | `compactMetadata.postTokens` |

* Context tokens = `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of
  the last non-sidechain response in the main transcript. Output tokens are not included.
* C's title skips an `isMeta` line and a `<command-name>…` line, takes the first non-empty
  line of the prompt, collapses spaces, and cuts to 59 characters plus `…`.
* E's `cost-state` line says $0.486094; its transcript adds up to $0.33604. The difference,
  $0.150054, is the compaction request and a title request, which Claude Code counts but
  does not write as `assistant` lines.

## Incremental snapshots

Feed the three files to one scanner state, as successive versions of the same path.

| Step | File | File bytes | Bytes consumed after the step | Ledger after the step |
| :- | :- | -: | -: | :- |
| 1 | `incremental/step1.jsonl` | 2,254 | 1,555 | d1 only, from its placeholder: output 7, cost 0.0814786 |
| 2 | `incremental/step2.jsonl` | 4,349 | 4,349 | d1 upgraded to output 13 (cost 0.0815986) + d2. Total 0.0899692 |
| 3 | `incremental/step3-rewritten.jsonl` | 2,786 | 2,786 | d1 kept, d2 unchanged, d3 added. Total 0.0976598 |

* Step 1 ends with half a line and no newline. That half line must not be consumed.
* Step 2 is byte-identical to step 1 up to byte 1,555, so the scanner resumes there.
* Step 3 is shorter than the saved offset. The scanner must start again from byte 0 and
  must not remove d1, which is no longer in the file.

## Set-aside transcripts

Claude Code can set an older transcript of a session aside under two documented names
(<https://code.claude.com/docs/en/claude-directory>):

```
<session>.orphaned-<timestamp>-<suffix>.jsonl      ends in .jsonl, so a *.jsonl sweep finds it
<session>.jsonl.superseded-<timestamp>             does NOT end in .jsonl
```

`set-aside/projects/-Users-test-dev-gamma/` holds one session (F) in three files. Scan
`set-aside/` as its own root.

| File | Holds |
| :- | :- |
| `6666….jsonl` (live) | a prompt, g2, g3, an `ai-title` line |
| `6666….jsonl.superseded-1791756000000` | an older prompt, g0, g1, a stale `ai-title` line |
| `6666….orphaned-1791756060000-k3x9.jsonl` | g1, g2 |

| Must hold | Value |
| :- | :- |
| Responses | 4 (g0, g1, g2, g3), each counted once |
| Sessions | exactly one: `66666666-6666-4666-8666-666666666666`. Not a second session named `6666….orphaned-…` |
| Totals | input 12, output 1,000, cache write 9,800, cache read 25,400, cost 0.051764 |
| Title, first prompt | `Gamma exporter`, `Wire up the gamma exporter`: from the live file only |
| Context | 9,803 tokens of 1,000,000 (g3): from the live file only |

A scanner that reads only the live file gets 2 responses and 0.014352 (`liveFileOnlyTotals`
in `expected.json`): an undercount, because g0 and g1 were real API responses.

## Session registry samples

`sessions/41001.json` and `sessions/41002.json` copy the keys of real
`~/.claude/sessions/<pid>.json` files (2.1.295 and 2.1.296). `41002.json` shows a session
blocked on a permission prompt: `"status": "waiting"` plus `"waitingFor": "permission prompt"`,
a `derived` name (folder name, `-`, two characters) and the desktop app's `hostSessionId`.
The `status` and `waitingFor` values are the ones documented for `claude agents --json`
(<https://code.claude.com/docs/en/agent-view>).

## Status line samples

| File | What it shows | Context % | Rate windows |
| :- | :- | -: | :- |
| `first-render.json` | Before any API response: usage fields are null; no `rate_limits`, `prompt_cache`, `session_name`, `prompt_id`. | unknown | none |
| `limits-before-context.json` | `rate_limits` present while context fields are still null. | unknown | 5h 24%, 7d 8% |
| `full-subscriber.json` | Normal payload for a subscriber. Integer percentages, as observed. | 5.0005 | 5h 24%, 7d 8% |
| `fractional-percentages.json` | Same, with fractional percentages as in the documentation's example. | 5.0005 | 5h 23.5%, 7d 41.2% |
| `api-key-user.json` | No `rate_limits` object. 200K window. `used_percentage` is the rounded 13. | 12.55 | none |
| `weekly-only.json` | Only `seven_day` (the 5-hour window was dropped), at 100%. | 5.0005 | 7d 100% |
| `gateway-spend-limit.json` | Only `spend_limit`, with dollar fields. | 5.0005 | spend 62.8% |
| `after-compact-observed.json` | Right after `/compact`, as seen on 2.1.296: `current_usage` all zeros, `used_percentage` 0. | 0 | 5h 24%, 7d 8% |
| `after-compact-documented.json` | Right after `/compact`, as documented: `current_usage` null. | unknown | 5h 24%, 7d 8% |
| `envelope.ndjson` | The single line `perch-hook` sends: a `HookEnvelope` with `channel: "statusline"` and the payload as a string. | | |

Context % is recomputed as `(input + cache_creation + cache_read) / context_window_size * 100`
when `current_usage` is present; `used_percentage` is only a whole number.

## Golden vectors

These three reproduce `costUSD` values that Claude Code 2.1.296 wrote in `cost-state` lines
on the research machine. They prove the price table and formula, not just self-consistency.

| Model | in | out | write 1h | read | Cost USD | Used as |
| :- | -: | -: | -: | -: | -: | :- |
| claude-opus-5-5 | 2 | 13 | 9,560 | 24,253 | 0.0815986 | d1 in `incremental/` |
| claude-sonnet-5-5 | 6 | 254 | 12,100 | 56,850 | 0.056637 | b1 |
| claude-haiku-5-5 | 4 | 279 | 6,449 | 30,532 | 0.00173502 | not in a file; assert it in a unit test |

`pricing.json` is written by hand, not by `make_fixtures.py`. Its four retired Claude 3
rows (Sonnet 3.7, Sonnet 3.5, Haiku 3, Opus 3) are no longer on the live pricing page;
their prices were read from the archived official page of 2025-08-30 (`legacy_source`).

Claude Code's own cost figures depend on the price table built into each version. 2.1.295
and earlier price Sonnet 5.5 cache reads at $0.20 per million tokens; 2.1.296 uses $0.10
(Claude Code changelog). A `cost-state` or status line cost written by an older version can
therefore differ from these fixtures' prices without any background request being involved.

## What is assumed, not observed

* Set-aside transcripts (`set-aside/`): only the two file-name patterns are documented. The
  timestamp and suffix formats and the contents are invented.

* The sidechain replay of a3 (same message id, different request id) comes from the ccusage
  project's notes on issue #913. It was not seen on the research machine.
* A fork's copied lines carry the fork's `sessionId` here. Real forks were not available to
  inspect. The de-dup key does not depend on it.
* `costUSD` on a line and a response without `requestId` are shapes from older or proxied
  setups, taken from ccusage's parser.
* `after-compact-documented.json` follows the documentation; the observed payload differed.
