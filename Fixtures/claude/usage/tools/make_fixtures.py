#!/usr/bin/env python3
"""Regenerates the synthetic Claude Code usage fixtures in the parent folder.

    python3 tools/make_fixtures.py        (run from Fixtures/claude/usage)

Everything here is invented. The line shapes copy the KEY NAMES seen in real Claude Code
2.1.295 / 2.1.296 transcripts (see docs/research/claude-usage.md); no real conversation
text, paths or ids are used.

The script writes:
  projects/...            transcript .jsonl files (and one subagent .meta.json)
  incremental/...         three snapshots of one growing file, for the incremental scanner
  statusline/...          status line stdin samples
  set-aside/...           one session whose older transcripts were set aside under the documented
                          names <session>.orphaned-<timestamp>-<suffix>.jsonl and
                          <session>.jsonl.superseded-<timestamp> (kept OUTSIDE projects/)
  sessions/41001.json     a ~/.claude/sessions/<pid>.json sample (idle, named by the user)
  sessions/41002.json     the same for a session that waits on a permission prompt
  expected.json           the totals a correct scanner must produce

The expected numbers are computed here from the list of "true" API responses (TRUTH), NOT by
re-reading the files. tools/reference_scan.py re-reads the files with the documented de-dup
rules and must arrive at the same numbers.
"""
import json
import os
import shutil
from datetime import datetime, timezone
from decimal import Decimal
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRICING = json.load(open(os.path.join(HERE, "pricing.json")))
PRICE = {m["id"]: m for m in PRICING["models"]}

SESSION_A = "11111111-1111-4111-8111-111111111111"
SESSION_B = "22222222-2222-4222-8222-222222222222"
SESSION_C = "33333333-3333-4333-8333-333333333333"
SESSION_D = "44444444-4444-4444-8444-444444444444"
SESSION_E = "55555555-5555-4555-8555-555555555555"
SESSION_F = "66666666-6666-4666-8666-666666666666"      # set-aside/ only

ALPHA_CWD = "/Users/test/dev/alpha"
ALPHA_DIR = "-Users-test-dev-alpha"
BETA_CWD = "/Users/test/dev/beta site"
BETA_DIR = "-Users-test-dev-beta-site"
GAMMA_CWD = "/Users/test/dev/gamma"
GAMMA_DIR = "-Users-test-dev-gamma"

AGENT_1 = "a1b2c3d4e5f60718"
AGENT_ASIDE = "aside00000000001"

TITLE_MAX = 60


# --------------------------------------------------------------------------------------
# small helpers

_uuid_counter = [0]


def new_uuid():
    _uuid_counter[0] += 1
    return "00000000-0000-4000-8000-%012d" % _uuid_counter[0]


def dump(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


def cache_creation(cw5m, cw1h):
    return {"ephemeral_1h_input_tokens": cw1h, "ephemeral_5m_input_tokens": cw5m}


def usage_final(inp, out, cw5m, cw1h, cr, thinking=0, web_search=0, web_fetch=0,
                speed="standard", geo="global", tier="standard"):
    """The usage object on a finished response (keys in the order Claude Code 2.1.296 writes them)."""
    return {
        "input_tokens": inp,
        "cache_creation_input_tokens": cw5m + cw1h,
        "cache_read_input_tokens": cr,
        "output_tokens": out,
        "output_tokens_details": {"thinking_tokens": thinking},
        "server_tool_use": {"web_search_requests": web_search, "web_fetch_requests": web_fetch},
        "service_tier": tier,
        "cache_creation": cache_creation(cw5m, cw1h),
        "inference_geo": geo,
        "iterations": [{
            "input_tokens": inp, "output_tokens": out, "cache_read_input_tokens": cr,
            "cache_creation_input_tokens": cw5m + cw1h, "cache_creation": cache_creation(cw5m, cw1h),
            "type": "message",
        }],
        "speed": speed,
        "fallback_credit": None,
    }


def usage_placeholder(inp, out, cw5m, cw1h, cr, geo="global"):
    """The usage object on a line written while the response is still streaming."""
    return {
        "input_tokens": inp,
        "cache_creation_input_tokens": cw5m + cw1h,
        "cache_read_input_tokens": cr,
        "cache_creation": cache_creation(cw5m, cw1h),
        "output_tokens": out,
        "service_tier": "standard",
        "inference_geo": geo,
    }


def usage_legacy(inp, out, cache_creation_total, cr):
    """Older transcripts: no cache_creation breakdown, no server_tool_use."""
    return {
        "input_tokens": inp,
        "cache_creation_input_tokens": cache_creation_total,
        "cache_read_input_tokens": cr,
        "output_tokens": out,
        "service_tier": "standard",
    }


BLOCKS = {
    "thinking": {"type": "thinking", "thinking": "", "signature": "c2lnbmF0dXJl"},
    "text": {"type": "text", "text": "ok"},
    "tool_use": {"type": "tool_use", "id": "toolu_01FIXTURE", "name": "Read",
                 "input": {"file_path": "/Users/test/dev/example.txt"}},
}


class Ctx:
    """The fields every line of one transcript file shares.

    Key ORDER follows real 2.1.296 lines: on assistant lines the top-level "type" comes AFTER the
    (large) "message" object, so a parser must not expect it near the start of the line.
    """

    def __init__(self, session, cwd, branch, version, entrypoint, sidechain=False, agent_id=None):
        self.session, self.cwd, self.branch = session, cwd, branch
        self.version, self.entrypoint = version, entrypoint
        self.sidechain, self.agent_id = sidechain, agent_id
        self.parent = None

    def head(self):
        return {"parentUuid": self.parent, "isSidechain": self.sidechain}

    def tail(self):
        t = {"userType": "external", "entrypoint": self.entrypoint, "cwd": self.cwd,
             "sessionId": self.session, "version": self.version, "gitBranch": self.branch}
        if self.sidechain:
            t["slug"] = "quiet-fixture-slug"
        return t


def assistant(ctx, ts, msg_id, req_id, model, block_index, block, usage, stop_reason,
              uuid=None, extra=None):
    uuid = uuid or new_uuid()
    line = ctx.head()
    if ctx.agent_id:
        line["agentId"] = ctx.agent_id
    line["message"] = {
        "model": model, "id": msg_id, "type": "message", "role": "assistant",
        "content": [BLOCKS[block]], "container": None,
        "stop_reason": stop_reason, "stop_sequence": None, "stop_details": None,
        "usage": usage, "input_transformations": [], "diagnostics": None, "context_management": None,
    }
    if block == "thinking":
        line["thinkingDurationMs"] = 1200
    line["apiBlockIndex"] = block_index
    if req_id is not None:
        line["requestId"] = req_id
    line["requestedModel"] = model
    if ctx.sidechain:
        line["attributionAgent"] = "Explore"
    line.update({"type": "assistant", "uuid": uuid, "timestamp": ts,
                 "advisorModel": "", "effort": "medium", "perTurnEffort": "medium"})
    line.update(ctx.tail())
    if extra:
        line.update(extra)
    ctx.parent = uuid
    return line


def user_prompt(ctx, ts, text, as_array=False, extra=None):
    uuid = new_uuid()
    line = ctx.head()
    line["promptId"] = new_uuid()
    if ctx.agent_id:
        line["agentId"] = ctx.agent_id
    line.update({"type": "user",
                 "message": {"role": "user", "content": [{"type": "text", "text": text}] if as_array else text},
                 "uuid": uuid, "timestamp": ts,
                 "permissionMode": "default", "origin": {"kind": "human"}, "promptSource": "typed"})
    line.update(ctx.tail())
    if extra:
        line.update(extra)
    ctx.parent = uuid
    return line


def tool_result(ctx, ts):
    uuid = new_uuid()
    line = ctx.head()
    line["promptId"] = new_uuid()
    if ctx.agent_id:
        line["agentId"] = ctx.agent_id
    line.update({"type": "user",
                 "message": {"role": "user", "content": [
                     {"type": "tool_result", "tool_use_id": "toolu_01FIXTURE", "content": "ok", "is_error": False}]},
                 "uuid": uuid, "timestamp": ts})
    if not ctx.sidechain:                       # real subagent tool results usually have no toolUseResult key
        line["toolUseResult"] = {"type": "text"}
    line["sourceToolAssistantUUID"] = ctx.parent
    line.update(ctx.tail())
    ctx.parent = uuid
    return line


def write_jsonl(rel, lines, trailing=""):
    path = os.path.join(HERE, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        for line in lines:
            fh.write(line if isinstance(line, str) else dump(line))
            fh.write("\n")
        fh.write(trailing)
    return path


def write_json(rel, obj):
    path = os.path.join(HERE, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


# --------------------------------------------------------------------------------------
# pricing (the same rules the doc specifies)

def normalize_model(model):
    import re
    m = model.lower()
    m = re.sub(r"\[1m\]$", "", m)
    m = re.sub(r"^.*/", "", m)                          # gateway form such as anthropic/claude-opus-4-8
    m = re.sub(r"^([a-z0-9-]+\.)?anthropic\.", "", m)
    m = re.sub(r"-v1(:0)?$", "", m)
    m = re.sub(r"[-@]\d{8}$", "", m)
    return m


def cost_of(model, inp, out, cw5m, cw1h, cr, web_search=0, speed="standard", geo="global"):
    p = PRICE.get(normalize_model(model))
    if p is None:
        return None
    rates = p
    lc = p.get("long_context")
    if lc and (inp + cw5m + cw1h + cr) > lc["prompt_tokens_over"]:
        rates = lc
    D = lambda x: Decimal(str(x))
    tokens = (D(inp) * D(rates["input"]) + D(out) * D(rates["output"])
              + D(cw5m) * D(rates["cache_write_5m"]) + D(cw1h) * D(rates["cache_write_1h"])
              + D(cr) * D(rates["cache_read"])) / Decimal(1000000)
    if speed == "fast":
        tokens *= D(p.get("fast_multiplier", 1))
    if geo == "us":
        tokens *= D(PRICING["inference_geo_us_multiplier"])
    return tokens + D(web_search) * D(PRICING["web_search_usd_per_request"])


# --------------------------------------------------------------------------------------
# TRUTH: one entry per real API response. `owner` is the session the usage belongs to.

TRUTH = []


def truth(name, session, project, model, ts, inp, out, cw5m, cw1h, cr, **kw):
    e = dict(name=name, messageId="msg_01FIXTURE" + name, requestId="req_01FIXTURE" + name,
             session=session, project=project, model=model, timestamp=ts,
             input=inp, output=out, cacheWrite5m=cw5m, cacheWrite1h=cw1h, cacheRead=cr,
             webSearch=kw.get("web_search", 0), speed=kw.get("speed", "standard"),
             geo=kw.get("geo", "global"), sidechain=kw.get("sidechain", False),
             incomplete=kw.get("incomplete", False))
    if kw.get("no_request_id"):
        e["requestId"] = None
    TRUTH.append(e)
    return e


def final_usage_of(e, **kw):
    return usage_final(e["input"], e["output"], e["cacheWrite5m"], e["cacheWrite1h"], e["cacheRead"],
                       web_search=e["webSearch"], speed=e["speed"], geo=e["geo"], **kw)


def placeholder_of(e, out):
    return usage_placeholder(e["input"], out, e["cacheWrite5m"], e["cacheWrite1h"], e["cacheRead"], geo=e["geo"])


# --------------------------------------------------------------------------------------
# Session A  (project alpha, terminal CLI) --------------------------------------------

def build_session_a():
    ctx = Ctx(SESSION_A, ALPHA_CWD, "main", "2.1.296", "cli")
    L = []
    L.append({"type": "mode", "mode": "normal", "sessionId": SESSION_A})
    L.append({"type": "permission-mode", "permissionMode": "default", "sessionId": SESSION_A})
    first_prompt = user_prompt(ctx, "2026-10-10T06:49:50.000Z", "Refactor the alpha parser")
    L.append(first_prompt)

    # A1: three content blocks -> three lines, every line already carries the FINAL usage
    a1 = truth("a1", SESSION_A, ALPHA_DIR, "claude-opus-5-5", "2026-10-10T06:50:00.100Z", 3, 420, 0, 12000, 0)
    a1_lines = [
        assistant(ctx, "2026-10-10T06:50:00.100Z", a1["messageId"], a1["requestId"], a1["model"], 0, "thinking", final_usage_of(a1, thinking=200), "tool_use"),
        assistant(ctx, "2026-10-10T06:50:02.400Z", a1["messageId"], a1["requestId"], a1["model"], 1, "text", final_usage_of(a1, thinking=200), "tool_use"),
        assistant(ctx, "2026-10-10T06:50:05.900Z", a1["messageId"], a1["requestId"], a1["model"], 2, "tool_use", final_usage_of(a1, thinking=200), "tool_use"),
    ]
    L += a1_lines
    tr1 = tool_result(ctx, "2026-10-10T06:50:06.500Z")
    L.append(tr1)

    # A2: two lines that straddle local midnight in America/Los_Angeles (23:59:58 -> 00:00:03).
    a2 = truth("a2", SESSION_A, ALPHA_DIR, "claude-opus-5-5", "2026-10-10T06:59:58.000Z", 2, 900, 0, 1500, 12000)
    a2_lines = [
        assistant(ctx, "2026-10-10T06:59:58.000Z", a2["messageId"], a2["requestId"], a2["model"], 0, "thinking", final_usage_of(a2, thinking=500), "end_turn"),
        assistant(ctx, "2026-10-10T07:00:03.000Z", a2["messageId"], a2["requestId"], a2["model"], 1, "text", final_usage_of(a2, thinking=500), "end_turn"),
    ]
    L += a2_lines
    L.append({"type": "custom-title", "customTitle": "Alpha refactor", "sessionId": SESSION_A})
    L.append({"type": "agent-name", "agentName": "Alpha refactor", "sessionId": SESSION_A})
    L.append(user_prompt(ctx, "2026-10-10T07:09:50.000Z", "Now look up the grammar online"))

    # A3: one line, two billed web searches
    a3 = truth("a3", SESSION_A, ALPHA_DIR, "claude-opus-5-5", "2026-10-10T07:10:00.000Z", 2, 150, 0, 800, 13500, web_search=2)
    a3_line = assistant(ctx, "2026-10-10T07:10:00.000Z", a3["messageId"], a3["requestId"], a3["model"], 0, "text", final_usage_of(a3), "end_turn")
    L.append(a3_line)

    # A4: interrupted response. Only streaming placeholders were ever written (stop_reason null).
    a4 = truth("a4", SESSION_A, ALPHA_DIR, "claude-opus-5-5", "2026-10-10T07:12:00.000Z", 2, 2, 0, 300, 14300, incomplete=True)
    L.append(assistant(ctx, "2026-10-10T07:12:00.000Z", a4["messageId"], a4["requestId"], a4["model"], 0, "thinking", placeholder_of(a4, 2), None))
    L.append(assistant(ctx, "2026-10-10T07:12:00.020Z", a4["messageId"], a4["requestId"], a4["model"], 1, "thinking", placeholder_of(a4, 2), None))

    # A locally generated error message: model "<synthetic>", zero usage. Must be skipped.
    synth = assistant(ctx, "2026-10-10T07:12:05.000Z", "5d0f6c1e-0000-4000-8000-00000000a5a5", None, "<synthetic>", 0, "text",
                      {"input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
                       "server_tool_use": {"web_search_requests": 0, "web_fetch_requests": 0}, "service_tier": None,
                       "cache_creation": cache_creation(0, 0)}, "stop_sequence",
                      extra={"isApiErrorMessage": True})
    L.append(synth)

    L.append(user_prompt(ctx, "2026-10-10T17:59:50.000Z", "Summarise the test output"))
    # A6: Haiku 5.5, prompt 39,004 tokens (at or under 100,000 -> normal prices)
    a6 = truth("a6", SESSION_A, ALPHA_DIR, "claude-haiku-5-5", "2026-10-10T18:00:00.000Z", 4, 120, 0, 9000, 30000)
    L.append(assistant(ctx, "2026-10-10T18:00:00.000Z", a6["messageId"], a6["requestId"], a6["model"], 0, "text", final_usage_of(a6), "end_turn"))
    # A7: Haiku 5.5, prompt 122,010 tokens (over 100,000 -> long-context prices for the whole request)
    a7 = truth("a7", SESSION_A, ALPHA_DIR, "claude-haiku-5-5", "2026-10-10T18:05:00.000Z", 10, 500, 0, 2000, 120000)
    L.append(assistant(ctx, "2026-10-10T18:05:00.000Z", a7["messageId"], a7["requestId"], a7["model"], 0, "text", final_usage_of(a7), "end_turn"))
    # A8: Opus 5.5 in fast mode (2x), two lines
    a8 = truth("a8", SESSION_A, ALPHA_DIR, "claude-opus-5-5", "2026-10-10T18:10:00.000Z", 5, 1000, 0, 0, 50000, speed="fast")
    L.append(assistant(ctx, "2026-10-10T18:10:00.000Z", a8["messageId"], a8["requestId"], a8["model"], 0, "thinking", final_usage_of(a8, thinking=300), "end_turn"))
    L.append(assistant(ctx, "2026-10-10T18:10:04.000Z", a8["messageId"], a8["requestId"], a8["model"], 1, "text", final_usage_of(a8, thinking=300), "end_turn"))

    L.append({"type": "custom-title", "customTitle": "Alpha refactor v2", "sessionId": SESSION_A})
    L.append({"type": "agent-name", "agentName": "Alpha refactor v2", "sessionId": SESSION_A})
    L.append({"type": "last-prompt", "lastPrompt": "Summarise the test output", "leafUuid": ctx.parent, "sessionId": SESSION_A})
    write_jsonl("projects/%s/%s.jsonl" % (ALPHA_DIR, SESSION_A), L)
    return first_prompt, a1_lines, tr1, a2_lines, a3_line


def build_session_a_subagents(a3_line):
    # Subagent transcript: isSidechain true, 5-minute cache writes, lines written WHILE streaming:
    # early lines carry a placeholder (tiny output_tokens, stop_reason null), the last line the final usage.
    ctx = Ctx(SESSION_A, ALPHA_CWD, "main", "2.1.296", "cli", sidechain=True, agent_id=AGENT_1)
    L = [user_prompt(ctx, "2026-10-10T07:10:55.000Z", "Find the parser entry points", extra={"promptSource": "sdk"})]
    L[0].pop("origin")
    s1 = truth("s1", SESSION_A, ALPHA_DIR, "claude-haiku-5-5", "2026-10-10T07:11:00.000Z", 2, 380, 11000, 0, 19000, sidechain=True)
    L.append(assistant(ctx, "2026-10-10T07:11:00.000Z", s1["messageId"], s1["requestId"], s1["model"], 0, "thinking", placeholder_of(s1, 6), None))
    L.append(assistant(ctx, "2026-10-10T07:11:00.300Z", s1["messageId"], s1["requestId"], s1["model"], 1, "tool_use", placeholder_of(s1, 6), None))
    L.append(tool_result(ctx, "2026-10-10T07:11:00.900Z"))   # a foreign line in the middle of the group
    L.append(assistant(ctx, "2026-10-10T07:11:02.000Z", s1["messageId"], s1["requestId"], s1["model"], 2, "tool_use", final_usage_of(s1, thinking=90), "tool_use"))
    L.append(tool_result(ctx, "2026-10-10T07:11:02.500Z"))
    s2 = truth("s2", SESSION_A, ALPHA_DIR, "claude-haiku-5-5", "2026-10-10T07:11:30.000Z", 2, 210, 3000, 0, 30000, sidechain=True)
    L.append(assistant(ctx, "2026-10-10T07:11:30.000Z", s2["messageId"], s2["requestId"], s2["model"], 0, "thinking", placeholder_of(s2, 5), None))
    L.append(assistant(ctx, "2026-10-10T07:11:31.200Z", s2["messageId"], s2["requestId"], s2["model"], 1, "text", final_usage_of(s2, thinking=40), "end_turn"))
    write_jsonl("projects/%s/%s/subagents/agent-%s.jsonl" % (ALPHA_DIR, SESSION_A, AGENT_1), L)
    write_json("projects/%s/%s/subagents/agent-%s.meta.json" % (ALPHA_DIR, SESSION_A, AGENT_1),
               {"agentType": "Explore", "description": "Find parser entry points", "toolUseId": "toolu_01FIXTUREagent",
                "spawnDepth": 1, "requestShape": "background", "requestNonInteractive": True})

    # Side-question ("/btw") style sidechain: it REPLAYS parent message A3 (same message id, a different
    # request id, isSidechain true) and then adds one response of its own (Q1).
    ctx2 = Ctx(SESSION_A, ALPHA_CWD, "main", "2.1.296", "cli", sidechain=True, agent_id=AGENT_ASIDE)
    replay = json.loads(dump(a3_line))
    replay["isSidechain"] = True
    replay["agentId"] = AGENT_ASIDE
    replay["requestId"] = "req_01FIXTUREa3replay"
    replay["uuid"] = new_uuid()
    L2 = [replay]
    ctx2.parent = replay["uuid"]
    L2.append(user_prompt(ctx2, "2026-10-10T07:10:25.000Z", "Quick side question", extra={"promptSource": "sdk"}))
    q1 = truth("q1", SESSION_A, ALPHA_DIR, "claude-opus-5-5", "2026-10-10T07:10:30.000Z", 2, 60, 0, 0, 14000, sidechain=True)
    L2.append(assistant(ctx2, "2026-10-10T07:10:30.000Z", q1["messageId"], q1["requestId"], q1["model"], 0, "text", final_usage_of(q1), "end_turn"))
    write_jsonl("projects/%s/%s/subagents/agent-%s.jsonl" % (ALPHA_DIR, SESSION_A, AGENT_ASIDE), L2)


# --------------------------------------------------------------------------------------
# Session B  (fork of A: the history is COPIED, then it continues on its own) -------------

def build_session_b(first_prompt, a1_lines, tr1, a2_lines):
    L = []
    for src in [first_prompt] + a1_lines + [tr1] + a2_lines:
        copy = json.loads(dump(src))          # same uuid, message.id, requestId and timestamp...
        copy["sessionId"] = SESSION_B          # ...but the copy lives in (and names) the new session
        L.append(copy)
    ctx = Ctx(SESSION_B, ALPHA_CWD, "main", "2.1.296", "cli")
    ctx.parent = L[-1]["uuid"]
    L.append(user_prompt(ctx, "2026-10-11T01:59:50.000Z", "Add retry logic to the uploader"))
    b1 = truth("b1", SESSION_B, ALPHA_DIR, "claude-sonnet-5-5", "2026-10-11T02:00:00.000Z", 6, 254, 0, 12100, 56850)
    L.append(assistant(ctx, "2026-10-11T02:00:00.000Z", b1["messageId"], b1["requestId"], b1["model"], 0, "thinking", final_usage_of(b1, thinking=100), "end_turn"))
    L.append(assistant(ctx, "2026-10-11T02:00:03.000Z", b1["messageId"], b1["requestId"], b1["model"], 1, "text", final_usage_of(b1, thinking=100), "end_turn"))
    L.append({"type": "ai-title", "aiTitle": "Uploader retries", "sessionId": SESSION_B})
    L.append({"type": "last-prompt", "lastPrompt": "Add retry logic to the uploader", "leafUuid": ctx.parent, "sessionId": SESSION_B})
    L.append({"type": "ai-title", "aiTitle": "Uploader retries", "sessionId": SESSION_B})
    L.append(user_prompt(ctx, "2026-10-11T02:00:50.000Z", "Also add a test"))
    L.append({"type": "ai-title", "aiTitle": "Retry logic for the uploader", "sessionId": SESSION_B})
    # B2: still streaming when the fixture was "captured": one placeholder line at end of file.
    b2 = truth("b2", SESSION_B, ALPHA_DIR, "claude-sonnet-5-5", "2026-10-11T02:01:00.000Z", 3, 4, 0, 500, 69000, incomplete=True)
    L.append(assistant(ctx, "2026-10-11T02:01:00.000Z", b2["messageId"], b2["requestId"], b2["model"], 0, "thinking", placeholder_of(b2, 4), None))
    write_jsonl("projects/%s/%s.jsonl" % (ALPHA_DIR, SESSION_B), L)


# --------------------------------------------------------------------------------------
# Session C  (project beta, desktop app; odd cases) --------------------------------------

C_PROMPT = "Build the landing page hero section with a responsive layout and dark mode support"


def build_session_c():
    ctx = Ctx(SESSION_C, BETA_CWD, "feature/x", "2.1.295", "claude-desktop")
    L = []
    L.append({"type": "queue-operation", "operation": "enqueue", "timestamp": "2026-10-11T18:59:40.000Z",
              "sessionId": SESSION_C, "content": "queued"})
    L.append({"type": "queue-operation", "operation": "dequeue", "timestamp": "2026-10-11T18:59:40.010Z",
              "sessionId": SESSION_C})
    L.append(user_prompt(ctx, "2026-10-11T18:59:41.000Z", "<local-command-caveat>ignore</local-command-caveat>",
                         extra={"isMeta": True}))
    L.append(user_prompt(ctx, "2026-10-11T18:59:42.000Z", "<command-name>/model</command-name>"))
    L.append(user_prompt(ctx, "2026-10-11T18:59:50.000Z", "  " + C_PROMPT + "\n\nSecond paragraph that must not be part of the title.",
                         as_array=True, extra={"promptSource": "sdk"}))

    c1 = truth("c1", SESSION_C, BETA_DIR, "claude-fable-5-1", "2026-10-11T19:00:00.000Z", 8, 2000, 0, 40000, 100000)
    c1_first = assistant(ctx, "2026-10-11T19:00:00.000Z", c1["messageId"], c1["requestId"], c1["model"], 0, "thinking", final_usage_of(c1, thinking=900), "end_turn")
    c1_second = assistant(ctx, "2026-10-11T19:00:20.000Z", c1["messageId"], c1["requestId"], c1["model"], 1, "text", final_usage_of(c1, thinking=900), "end_turn")
    L += [c1_first, c1_second]
    L.append(json.loads(dump(c1_second)))   # the very same line written twice (same uuid)

    # C4: Sonnet 5.5 with US-only inference (1.1x on every token price), 5-minute cache write
    c4 = truth("c4", SESSION_C, BETA_DIR, "claude-sonnet-5-5", "2026-10-11T19:10:00.000Z", 1000, 2000, 10000, 0, 50000, geo="us")
    L.append(assistant(ctx, "2026-10-11T19:10:00.000Z", c4["messageId"], c4["requestId"], c4["model"], 0, "text", final_usage_of(c4), "end_turn"))

    # C3: a model id that is not in the price table -> tokens counted, cost 0, reported as unpriced
    c3 = truth("c3", SESSION_C, BETA_DIR, "claude-next-9", "2026-10-11T19:20:00.000Z", 10, 10, 0, 0, 0)
    L.append(assistant(ctx, "2026-10-11T19:20:00.000Z", c3["messageId"], c3["requestId"], c3["model"], 0, "text", final_usage_of(c3), "end_turn"))

    L.append("{this line is not valid JSON and must be skipped")

    # C8: no requestId at all (seen behind some gateways); two lines for one response
    c8 = truth("c8", SESSION_C, BETA_DIR, "claude-sonnet-5-5", "2026-10-11T19:30:00.000Z", 50, 50, 0, 0, 0, no_request_id=True)
    L.append(assistant(ctx, "2026-10-11T19:30:00.000Z", c8["messageId"], None, c8["model"], 0, "thinking", final_usage_of(c8), "end_turn"))
    L.append(assistant(ctx, "2026-10-11T19:30:01.000Z", c8["messageId"], None, c8["model"], 1, "text", final_usage_of(c8), "end_turn"))

    # C2: a dated model id from an older Claude Code: no cache_creation breakdown (treat as 5-minute
    # writes) and a legacy per-line costUSD that Perch ignores.
    c2 = truth("c2", SESSION_C, BETA_DIR, "claude-opus-4-5-20251101", "2026-10-11T19:40:00.000Z", 100, 300, 5000, 0, 20000)
    L.append(assistant(ctx, "2026-10-11T19:40:00.000Z", c2["messageId"], c2["requestId"], c2["model"], 0, "text",
                       usage_legacy(100, 300, 5000, 20000), "end_turn", extra={"costUSD": 9.99}))
    L.append({"type": "last-prompt", "lastPrompt": C_PROMPT, "leafUuid": ctx.parent, "sessionId": SESSION_C})
    write_jsonl("projects/%s/%s.jsonl" % (BETA_DIR, SESSION_C), L)


# --------------------------------------------------------------------------------------
# Session E  (project beta, terminal CLI): a compaction, then nothing; and a cost-state line ---

E_COST_STATE = {}


def build_session_e():
    ctx = Ctx(SESSION_E, BETA_CWD, "feature/x", "2.1.296", "cli")
    L = [{"type": "mode", "mode": "normal", "sessionId": SESSION_E}]
    L.append(user_prompt(ctx, "2026-10-11T20:59:50.000Z", "Tidy the build scripts"))
    e1 = truth("e1", SESSION_E, BETA_DIR, "claude-opus-5-5", "2026-10-11T21:00:00.000Z", 10, 3000, 0, 20000, 580000)
    L.append(assistant(ctx, "2026-10-11T21:00:00.000Z", e1["messageId"], e1["requestId"], e1["model"], 0, "text", final_usage_of(e1), "end_turn"))
    # /compact: the summarising request itself is NOT written as an assistant line (observed on 2.1.296).
    boundary_uuid = new_uuid()
    L.append({"parentUuid": None, "logicalParentUuid": ctx.parent, "isSidechain": False, "type": "system",
              "subtype": "compact_boundary", "content": "Conversation compacted", "level": "info",
              "compactMetadata": {"trigger": "manual", "preTokens": 603010, "postTokens": 12000,
                                  "cumulativeDroppedTokens": 591010, "durationMs": 6921,
                                  "preservedSegment": {"headUuid": ctx.parent, "anchorUuid": ctx.parent, "tailUuid": ctx.parent},
                                  "preservedMessages": {"anchorUuid": ctx.parent, "uuids": [ctx.parent], "allUuids": [ctx.parent]}},
              "uuid": boundary_uuid, "timestamp": "2026-10-11T21:05:00.000Z", "userType": "external", "entrypoint": "cli",
              "cwd": BETA_CWD, "sessionId": SESSION_E, "version": "2.1.296", "gitBranch": "feature/x"})
    ctx.parent = boundary_uuid
    L.append(user_prompt(ctx, "2026-10-11T21:04:59.900Z", "This session is being continued from a previous conversation. Summary: tidy build scripts.",
                         extra={"isCompactSummary": True, "isVisibleInTranscriptOnly": True}))
    L[-1].pop("origin")
    L[-1].pop("promptSource")
    L.append({"type": "last-prompt", "lastPrompt": "Tidy the build scripts", "leafUuid": ctx.parent, "sessionId": SESSION_E})
    # cost-state: Claude Code's own running total for the session. It also counts requests that never
    # appear as assistant lines: here the compaction request (Opus) and a title request (Haiku).
    opus_extra = dict(inp=3, out=1500, cr=600010)
    haiku_extra = dict(inp=300, out=20)
    opus_cost = cost_of("claude-opus-5-5", 10 + opus_extra["inp"], 3000 + opus_extra["out"], 0, 20000, 580000 + opus_extra["cr"])
    haiku_cost = cost_of("claude-haiku-5-5", haiku_extra["inp"], haiku_extra["out"], 0, 0, 0)
    total = opus_cost + haiku_cost
    L.append({"type": "cost-state", "sessionId": SESSION_E, "totalCostUSD": float(total), "totalAPIDuration": 41200,
              "totalAPIDurationWithoutRetries": 41200, "totalToolDuration": 0, "totalLinesAdded": 0, "totalLinesRemoved": 0,
              "totalDuration": 330000, "startTime": 1791700000000,
              "modelUsage": {
                  "claude-opus-5-5": {"inputTokens": 10 + opus_extra["inp"], "outputTokens": 3000 + opus_extra["out"], "thinkingTokens": 0,
                                      "cacheReadInputTokens": 580000 + opus_extra["cr"], "cacheCreationInputTokens": 20000,
                                      "webSearchRequests": 0, "costUSD": float(opus_cost)},
                  "claude-haiku-5-5": {"inputTokens": haiku_extra["inp"], "outputTokens": haiku_extra["out"], "thinkingTokens": 0,
                                       "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0,
                                       "webSearchRequests": 0, "costUSD": float(haiku_cost)}},
              "hasUnknownModelCost": False})
    write_jsonl("projects/%s/%s.jsonl" % (BETA_DIR, SESSION_E), L)
    transcript = cost_of("claude-opus-5-5", 10, 3000, 0, 20000, 580000)
    E_COST_STATE.update({"totalCostUSD": money(total), "transcriptCostUSD": money(transcript),
                         "backgroundCostUSD": money(total - transcript)})


# --------------------------------------------------------------------------------------
# Incremental snapshots of one growing file (kept OUTSIDE projects/ so the totals above ignore it)

def build_incremental():
    ctx = Ctx(SESSION_D, ALPHA_CWD, "main", "2.1.296", "sdk-cli", sidechain=False)
    d1 = dict(name="d1", messageId="msg_01FIXTUREd1", requestId="req_01FIXTUREd1", model="claude-opus-5-5",
              timestamp="2026-10-11T20:00:00.000Z", input=2, output=13, cacheWrite5m=0, cacheWrite1h=9560, cacheRead=24253,
              webSearch=0, speed="standard", geo="global")
    d2 = dict(name="d2", messageId="msg_01FIXTUREd2", requestId="req_01FIXTUREd2", model="claude-opus-5-5",
              timestamp="2026-10-11T20:01:00.000Z", input=2, output=40, cacheWrite5m=0, cacheWrite1h=100, cacheRead=33813,
              webSearch=0, speed="standard", geo="global")
    d3 = dict(name="d3", messageId="msg_01FIXTUREd3", requestId="req_01FIXTUREd3", model="claude-opus-5-5",
              timestamp="2026-10-11T20:02:00.000Z", input=2, output=25, cacheWrite5m=0, cacheWrite1h=50, cacheRead=33913,
              webSearch=0, speed="standard", geo="global")
    prompt = user_prompt(ctx, "2026-10-11T19:59:55.000Z", "Say hello")
    d1_placeholder = assistant(ctx, "2026-10-11T20:00:00.000Z", d1["messageId"], d1["requestId"], d1["model"], 0, "thinking", placeholder_of(d1, 7), None)
    d1_final = assistant(ctx, "2026-10-11T20:00:01.000Z", d1["messageId"], d1["requestId"], d1["model"], 1, "text", final_usage_of(d1), "end_turn")
    d2_line = assistant(ctx, "2026-10-11T20:01:00.000Z", d2["messageId"], d2["requestId"], d2["model"], 0, "text", final_usage_of(d2), "end_turn")
    d3_line = assistant(ctx, "2026-10-11T20:02:00.000Z", d3["messageId"], d3["requestId"], d3["model"], 0, "text", final_usage_of(d3), "end_turn")

    complete = [dump(prompt), dump(d1_placeholder)]
    half = dump(d1_final)
    half = half[: len(half) // 2]                       # a line cut off mid-write: no newline yet
    p1 = write_jsonl("incremental/step1.jsonl", complete, trailing=half)
    p2 = write_jsonl("incremental/step2.jsonl", complete + [dump(d1_final), dump(d2_line)])
    p3 = write_jsonl("incremental/step3-rewritten.jsonl", [dump(d2_line), dump(d3_line)])

    consumed1 = sum(len(s.encode("utf-8")) + 1 for s in complete)

    def ev(e, out=None):
        o = e["output"] if out is None else out
        return dict(messageId=e["messageId"], requestId=e["requestId"], input=e["input"], output=o,
                    cacheWrite5m=e["cacheWrite5m"], cacheWrite1h=e["cacheWrite1h"], cacheRead=e["cacheRead"],
                    costUSD=money(cost_of(e["model"], e["input"], o, e["cacheWrite5m"], e["cacheWrite1h"], e["cacheRead"])))

    def tot(events):
        return dict(messages=len(events), input=sum(e["input"] for e in events), output=sum(e["output"] for e in events),
                    cacheWrite=sum(e["cacheWrite5m"] + e["cacheWrite1h"] for e in events),
                    cacheRead=sum(e["cacheRead"] for e in events),
                    costUSD=money(sum(Decimal(str(e["costUSD"])) for e in events)))

    s1 = [ev(d1, 7)]
    s2 = [ev(d1), ev(d2)]
    s3 = [ev(d1), ev(d2), ev(d3)]
    return {
        "about": "Feed the three files to ONE scanner state as if they were successive versions of the same path.",
        "session": SESSION_D,
        "step1": {"file": "incremental/step1.jsonl", "fileBytes": os.path.getsize(p1), "consumedBytes": consumed1,
                  "note": "The last line has no newline yet, so it is NOT consumed. d1 is known only from its placeholder.",
                  "events": s1, "totals": tot(s1)},
        "step2": {"file": "incremental/step2.jsonl", "fileBytes": os.path.getsize(p2), "consumedBytes": os.path.getsize(p2),
                  "resumeFromByte": consumed1,
                  "note": "Same bytes as step1 up to consumedBytes, then more. d1 is UPGRADED (output 7 -> 13), d2 is new.",
                  "events": s2, "totals": tot(s2)},
        "step3": {"file": "incremental/step3-rewritten.jsonl", "fileBytes": os.path.getsize(p3), "consumedBytes": os.path.getsize(p3),
                  "note": "The file got SHORTER than the saved offset (rewritten). Rescan from byte 0. Nothing already "
                          "counted is removed: d1 stays, d2 is recognised as a duplicate, d3 is new.",
                  "events": s3, "totals": tot(s3)},
    }


# --------------------------------------------------------------------------------------
# Set-aside transcripts (kept OUTSIDE projects/ so the totals above ignore them)
#
# The file NAMES follow https://code.claude.com/docs/en/claude-directory ("a previous transcript for
# the session that Claude Code set aside instead of overwriting or deleting it"). No such file
# existed on the research machine: the timestamp and suffix formats and the contents are ASSUMED.

def build_set_aside():
    ctx = Ctx(SESSION_F, GAMMA_CWD, "main", "2.1.296", "cli")

    def resp(name, ts, out, cw1h, cr):
        return dict(name=name, messageId="msg_01FIXTURE" + name, requestId="req_01FIXTURE" + name,
                    model="claude-sonnet-5-5", timestamp=ts, input=3, output=out, cacheWrite5m=0,
                    cacheWrite1h=cw1h, cacheRead=cr, webSearch=0, speed="standard", geo="global")

    g0 = resp("g0", "2026-10-11T22:00:00.000Z", 100, 8000, 0)
    g1 = resp("g1", "2026-10-11T22:01:00.000Z", 200, 400, 8000)
    g2 = resp("g2", "2026-10-11T22:02:00.000Z", 300, 600, 8400)
    g3 = resp("g3", "2026-10-11T22:03:00.000Z", 400, 800, 9000)

    def line(e):
        return assistant(ctx, e["timestamp"], e["messageId"], e["requestId"], e["model"], 0, "text",
                         final_usage_of(e), "end_turn")

    old_prompt = user_prompt(ctx, "2026-10-11T21:59:55.000Z", "Old first prompt in the superseded file")
    superseded = [old_prompt, line(g0), line(g1),
                  {"type": "ai-title", "aiTitle": "Stale title from a set-aside file", "sessionId": SESSION_F}]
    orphaned = [line(g1), line(g2)]
    live = [user_prompt(ctx, "2026-10-11T22:01:55.000Z", "Wire up the gamma exporter"), line(g2), line(g3),
            {"type": "ai-title", "aiTitle": "Gamma exporter", "sessionId": SESSION_F}]
    base = "set-aside/projects/%s/%s" % (GAMMA_DIR, SESSION_F)
    names = [base + ".jsonl", base + ".jsonl.superseded-1791756000000", base + ".orphaned-1791756060000-k3x9.jsonl"]
    write_jsonl(names[0], live)
    write_jsonl(names[1], superseded)
    write_jsonl(names[2], orphaned)

    def tot(events):
        costs = [cost_of(e["model"], e["input"], e["output"], e["cacheWrite5m"], e["cacheWrite1h"], e["cacheRead"]) for e in events]
        return dict(messages=len(events), input=sum(e["input"] for e in events), output=sum(e["output"] for e in events),
                    cacheWrite=sum(e["cacheWrite5m"] + e["cacheWrite1h"] for e in events),
                    cacheRead=sum(e["cacheRead"] for e in events), costUSD=money(sum(costs)))

    return {
        "about": "One session whose earlier transcripts were set aside. Scan all three files: every response is "
                 "counted once, all of them belong to ONE session, and the session facts (title, first prompt, "
                 "context) come from the live <session>.jsonl only.",
        "assumed": "File names follow the Claude Code documentation; the timestamp/suffix formats and the "
                   "contents are invented (no such file was available to inspect).",
        "root": "set-aside",
        "files": [n[len("set-aside/"):] for n in names],
        "session": SESSION_F,
        "project": GAMMA_DIR,
        "sessions": [SESSION_F],
        "messageIds": [e["messageId"] for e in (g0, g1, g2, g3)],
        "totals": tot([g0, g1, g2, g3]),
        "liveFileOnlyTotals": tot([g2, g3]),
        "title": "Gamma exporter",
        "firstPrompt": "Wire up the gamma exporter",
        "context": {"fromMessage": "g3", "tokens": 3 + 800 + 9000, "window": 1000000,
                    "percent": round((3 + 800 + 9000) / 1000000 * 100, 4)},
    }


# --------------------------------------------------------------------------------------
# expected totals

def money(x):
    return float(Decimal(x).quantize(Decimal("0.0000000001")))


def local_day(ts, tzname):
    dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
    return dt.astimezone(ZoneInfo(tzname)).strftime("%Y-%m-%d")


def empty():
    return dict(messages=0, input=0, output=0, cacheWrite5m=0, cacheWrite1h=0, cacheWrite=0, cacheRead=0,
                webSearchRequests=0, costUSD=Decimal(0))


def add(t, e, cost):
    t["messages"] += 1
    t["input"] += e["input"]
    t["output"] += e["output"]
    t["cacheWrite5m"] += e["cacheWrite5m"]
    t["cacheWrite1h"] += e["cacheWrite1h"]
    t["cacheWrite"] += e["cacheWrite5m"] + e["cacheWrite1h"]
    t["cacheRead"] += e["cacheRead"]
    t["webSearchRequests"] += e["webSearch"]
    t["costUSD"] += cost


def finish(t):
    t = dict(t)
    t["totalTokens"] = t["input"] + t["output"] + t["cacheWrite"] + t["cacheRead"]
    t["costUSD"] = money(t["costUSD"])
    return t


def group(keyfn, events_with_cost):
    out = {}
    for e, c in events_with_cost:
        add(out.setdefault(keyfn(e), empty()), e, c)
    return {k: finish(v) for k, v in sorted(out.items())}


def build_expected(incremental):
    ewc = []
    unpriced = set()
    events = []
    for e in TRUTH:
        c = cost_of(e["model"], e["input"], e["output"], e["cacheWrite5m"], e["cacheWrite1h"], e["cacheRead"],
                    web_search=e["webSearch"], speed=e["speed"], geo=e["geo"])
        if c is None:
            unpriced.add(normalize_model(e["model"]))
            c = Decimal(0)
        ewc.append((e, c))
        row = {k: e[k] for k in ("name", "messageId", "requestId", "session", "project", "model", "timestamp",
                                 "input", "output", "cacheWrite5m", "cacheWrite1h", "cacheRead", "webSearch",
                                 "speed", "geo", "sidechain", "incomplete")}
        row["modelKey"] = normalize_model(e["model"])
        row["costUSD"] = money(c)
        row["day"] = {tz: local_day(e["timestamp"], tz) for tz in ("America/Los_Angeles", "UTC")}
        events.append(row)

    total = empty()
    for e, c in ewc:
        add(total, e, c)

    days = {}
    for tz in ("America/Los_Angeles", "UTC"):
        per_day = {}
        for day in sorted({local_day(e["timestamp"], tz) for e in TRUTH}):
            sub = [(e, c) for e, c in ewc if local_day(e["timestamp"], tz) == day]
            t = empty()
            for e, c in sub:
                add(t, e, c)
            per_day[day] = {"totals": finish(t),
                            "byModel": group(lambda e: normalize_model(e["model"]), sub),
                            "byProject": group(lambda e: e["project"], sub),
                            "bySession": group(lambda e: e["session"], sub)}
        days[tz] = per_day

    title_c = C_PROMPT if len(C_PROMPT) <= TITLE_MAX else C_PROMPT[:TITLE_MAX - 1].rstrip() + "…"
    sessions = {
        SESSION_A: {"project": ALPHA_DIR, "cwd": ALPHA_CWD, "gitBranch": "main", "entrypoint": "cli", "version": "2.1.296",
                    "title": "Alpha refactor v2", "titleSource": "custom-title", "firstPrompt": "Refactor the alpha parser",
                    "lastPrompt": "Summarise the test output",
                    "context": {"fromMessage": "a8", "source": "assistant-usage", "model": "claude-opus-5-5", "tokens": 5 + 0 + 50000, "window": 1000000,
                                "percent": round((5 + 50000) / 1000000 * 100, 4)},
                    "costState": None,
                    "firstTimestamp": "2026-10-10T06:49:50.000Z", "lastTimestamp": "2026-10-10T18:10:04.000Z"},
        SESSION_B: {"project": ALPHA_DIR, "cwd": ALPHA_CWD, "gitBranch": "main", "entrypoint": "cli", "version": "2.1.296",
                    "title": "Retry logic for the uploader", "titleSource": "ai-title", "firstPrompt": "Refactor the alpha parser",
                    "lastPrompt": "Add retry logic to the uploader",
                    "costState": None,
                    "context": {"fromMessage": "b2", "source": "assistant-usage", "model": "claude-sonnet-5-5", "tokens": 3 + 500 + 69000, "window": 1000000,
                                "percent": round((3 + 500 + 69000) / 1000000 * 100, 4),
                                "note": "taken from a streaming placeholder line: its input-side counts are already final"},
                    "firstTimestamp": "2026-10-10T06:49:50.000Z", "lastTimestamp": "2026-10-11T02:01:00.000Z"},
        SESSION_C: {"project": BETA_DIR, "cwd": BETA_CWD, "gitBranch": "feature/x", "entrypoint": "claude-desktop", "version": "2.1.295",
                    "title": title_c, "titleSource": "first-prompt", "firstPrompt": C_PROMPT,
                    "lastPrompt": C_PROMPT,
                    "context": {"fromMessage": "c2", "source": "assistant-usage", "model": "claude-opus-4-5-20251101", "tokens": 100 + 5000 + 20000, "window": 200000,
                                "percent": round((100 + 5000 + 20000) / 200000 * 100, 4)},
                    "costState": None,
                    "firstTimestamp": "2026-10-11T18:59:40.000Z", "lastTimestamp": "2026-10-11T19:40:00.000Z"},
        SESSION_E: {"project": BETA_DIR, "cwd": BETA_CWD, "gitBranch": "feature/x", "entrypoint": "cli", "version": "2.1.296",
                    "title": "Tidy the build scripts", "titleSource": "first-prompt", "firstPrompt": "Tidy the build scripts",
                    "lastPrompt": "Tidy the build scripts",
                    "context": {"fromMessage": "compact_boundary", "source": "compact-boundary", "model": "claude-opus-5-5",
                                "tokens": 12000, "window": 1000000, "percent": 1.2,
                                "note": "after a compaction the next request starts from compactMetadata.postTokens"},
                    "costState": dict(E_COST_STATE),
                    "firstTimestamp": "2026-10-11T20:59:50.000Z", "lastTimestamp": "2026-10-11T21:05:00.000Z"},
    }

    return {
        "about": "Totals a correct scanner must produce for Fixtures/claude/usage/projects. Generated by tools/make_fixtures.py; "
                 "checked by tools/reference_scan.py. Costs are USD at list price; compare with a tolerance of 1e-9.",
        "pricing": "pricing.json",
        "ingestOrder": "files in ascending path order (so session 1111... is seen before its fork 2222...)",
        "counts": {
            "transcriptFiles": 6,
            "assistantLines": None,          # filled in by reference_scan.py --write-counts
            "uniqueResponses": len(TRUTH),
        },
        "allTime": finish(total),
        "unpricedModels": sorted(unpriced),
        "byModel": group(lambda e: normalize_model(e["model"]), ewc),
        "byProject": group(lambda e: e["project"], ewc),
        "bySession": group(lambda e: e["session"], ewc),
        "bySidechain": group(lambda e: "sidechain" if e["sidechain"] else "main", ewc),
        "days": days,
        "events": events,
        "sessions": sessions,
        "projects": {ALPHA_DIR: {"path": ALPHA_CWD, "name": "alpha"}, BETA_DIR: {"path": BETA_CWD, "name": "beta site"}},
        "incremental": incremental,
    }


# --------------------------------------------------------------------------------------
# status line samples

def epoch(iso):
    return int(datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())


def build_statusline():
    """Status line stdin samples. Key ORDER and the extra `scratchpad_dir` key follow real 2.1.296 captures;
    every value is invented."""
    def base(session, cwd, project_dir_name, model_id, display, effort="medium"):
        return {
            "session_id": session,
            "transcript_path": "/Users/test/.claude/projects/%s/%s.jsonl" % (project_dir_name, session),
            "cwd": cwd,
            "scratchpad_dir": "/private/tmp/claude-501/%s/%s/scratchpad" % (project_dir_name, session),
            "effort": {"level": effort},
            "model": {"id": model_id, "display_name": display},
            "workspace": {"current_dir": cwd, "project_dir": cwd, "added_dirs": []},
            "version": "2.1.296",
            "output_style": {"name": "default"},
            "cost": {"total_cost_usd": 0, "total_duration_ms": 474, "total_api_duration_ms": 0,
                     "total_lines_added": 0, "total_lines_removed": 0},
            "context_window": {"total_input_tokens": 0, "total_output_tokens": 0, "context_window_size": 1000000,
                               "current_usage": None, "used_percentage": None, "remaining_percentage": None},
            "exceeds_200k_tokens": False,
            "fast_mode": False,
            "thinking": {"enabled": True},
        }

    def ordered(d):
        """Re-order to the observed layout once the optional keys exist."""
        order = ["session_id", "transcript_path", "cwd", "scratchpad_dir", "prompt_id", "effort", "session_name", "model",
                 "workspace", "version", "output_style", "cost", "context_window", "exceeds_200k_tokens", "prompt_cache",
                 "fast_mode", "thinking", "rate_limits", "vim", "agent", "pr", "worktree"]
        return {k: d[k] for k in order if k in d}

    five = {"used_percentage": 24, "resets_at": epoch("2026-10-10T22:10:00Z")}
    seven = {"used_percentage": 8, "resets_at": epoch("2026-10-16T16:00:00Z")}

    # 1. the very first render of a session, before any API response
    first = base(SESSION_B, ALPHA_CWD, ALPHA_DIR, "claude-sonnet-5-5", "Sonnet 5.5", effort="high")
    write_json("statusline/first-render.json", ordered(first))

    # 2. rate limits can arrive while the context numbers are still null
    early = base(SESSION_B, ALPHA_CWD, ALPHA_DIR, "claude-sonnet-5-5", "Sonnet 5.5", effort="high")
    early["prompt_id"] = "66666666-6666-4666-8666-666666666666"
    early["rate_limits"] = {"five_hour": dict(five), "seven_day": dict(seven)}
    write_json("statusline/limits-before-context.json", ordered(early))

    # 3. a normal mid-session payload for a subscriber (integers, as observed)
    full = base(SESSION_A, ALPHA_CWD, ALPHA_DIR, "claude-opus-5-5", "Opus 5.5")
    full["prompt_id"] = "55555555-0000-4000-8000-555555555555"
    full["session_name"] = "Alpha refactor v2"
    full["workspace"]["repo"] = {"host": "github.com", "owner": "example", "name": "alpha"}
    full["cost"] = {"total_cost_usd": 0.4321, "total_duration_ms": 3600000, "total_api_duration_ms": 95000,
                    "total_lines_added": 156, "total_lines_removed": 23}
    full["context_window"] = {"total_input_tokens": 50005, "total_output_tokens": 1000, "context_window_size": 1000000,
                              "current_usage": {"input_tokens": 5, "output_tokens": 1000,
                                                "cache_creation_input_tokens": 0, "cache_read_input_tokens": 50000},
                              "used_percentage": 5, "remaining_percentage": 95}
    full["prompt_cache"] = {"warm": True, "caching_observed": True, "ttl": "1h", "expires_at": epoch("2026-10-10T19:10:04Z"),
                            "requests": 8, "misses": 1, "expected_rebuilds": 0, "hit_ratio": 0.91,
                            "cache_write_tokens": 25600, "miss_recache_tokens": 9000,
                            "last_miss_at": epoch("2026-10-10T18:00:00Z"), "last_miss_cause": None,
                            "recache_tokens_if_cold": 50005}
    full["fast_mode"] = True
    full["rate_limits"] = {"five_hour": dict(five), "seven_day": dict(seven)}
    full = ordered(full)
    write_json("statusline/full-subscriber.json", full)

    # 4. the documentation's style: fractional percentages
    floats = json.loads(dump(full))
    floats["context_window"]["used_percentage"] = 5.0005
    floats["context_window"]["remaining_percentage"] = 94.9995
    floats["rate_limits"] = {"five_hour": {"used_percentage": 23.5, "resets_at": five["resets_at"]},
                             "seven_day": {"used_percentage": 41.2, "resets_at": seven["resets_at"]}}
    write_json("statusline/fractional-percentages.json", floats)

    # 5. API-key user: there is no rate_limits object at all; a 200K-window model
    api = base(SESSION_C, BETA_CWD, BETA_DIR, "claude-opus-4-5-20251101", "Opus 4.5")
    api["prompt_id"] = "77777777-7777-4777-8777-777777777777"
    api["session_name"] = "landing-page"
    api["cost"]["total_cost_usd"] = 1.2345
    api["context_window"] = {"total_input_tokens": 25100, "total_output_tokens": 300, "context_window_size": 200000,
                             "current_usage": {"input_tokens": 100, "output_tokens": 300,
                                               "cache_creation_input_tokens": 5000, "cache_read_input_tokens": 20000},
                             "used_percentage": 13, "remaining_percentage": 87}
    write_json("statusline/api-key-user.json", ordered(api))

    # 6. the 5-hour window was dropped because its reset time passed; the weekly limit is exhausted
    weekly = json.loads(dump(full))
    weekly["rate_limits"] = {"seven_day": {"used_percentage": 100, "resets_at": seven["resets_at"]}}
    write_json("statusline/weekly-only.json", weekly)

    # 7. behind a gateway with a spend limit
    gateway = json.loads(dump(full))
    gateway["rate_limits"] = {"spend_limit": {"used_percentage": 62.8, "resets_at": epoch("2026-11-01T00:00:00Z"),
                                              "used_usd": 314.12, "limit_usd": 500, "period": "monthly"}}
    write_json("statusline/gateway-spend-limit.json", gateway)

    # 8. right after /compact as OBSERVED on 2.1.296: zeros, not null
    compact = json.loads(dump(full))
    compact["context_window"] = {"total_input_tokens": 0, "total_output_tokens": 0, "context_window_size": 1000000,
                                 "current_usage": {"input_tokens": 0, "output_tokens": 0,
                                                   "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
                                 "used_percentage": 0, "remaining_percentage": 100}
    write_json("statusline/after-compact-observed.json", compact)

    # 9. right after /compact as DOCUMENTED: current_usage null
    compact_doc = json.loads(dump(full))
    compact_doc["context_window"] = {"total_input_tokens": 0, "total_output_tokens": 0, "context_window_size": 1000000,
                                     "current_usage": None, "used_percentage": None, "remaining_percentage": None}
    write_json("statusline/after-compact-documented.json", compact_doc)

    # 10. the envelope perch-hook sends for a status line (one line of JSON)
    envelope = {"v": 1, "agent": "claude", "channel": "statusline", "event": None, "payload": dump(full), "args": [],
                "env": {"TERM_PROGRAM": "Apple_Terminal", "CLAUDE_CODE_ENTRYPOINT": "cli"}, "pid": 41001,
                "tty": "/dev/ttys003", "cwd": ALPHA_CWD, "wantsReply": False,
                "sentAt": epoch("2026-10-10T18:10:04Z") + 0.25}
    with open(os.path.join(HERE, "statusline/envelope.ndjson"), "w", encoding="utf-8") as fh:
        fh.write(dump(envelope) + "\n")

    def window(key, label, src):
        return {"id": key, "label": label, "usedPercent": src["used_percentage"], "resetsAtEpoch": src["resets_at"]}

    both = [window("5h", "5-hour limit", five), window("7d", "Weekly limit", seven)]
    return {
        "about": "What each statusline/*.json sample should normalise to. contextPercent is recomputed from "
                 "current_usage (input + cache_creation + cache_read) / context_window_size * 100 when current_usage "
                 "is present and non-zero; otherwise it is used_percentage; null means unknown.",
        "first-render.json": {"sessionID": SESSION_B, "title": None, "modelID": "claude-sonnet-5-5", "modelName": "Sonnet 5.5",
                              "contextPercent": None, "contextTokens": None, "contextWindow": 1000000, "costUSD": 0,
                              "fastMode": False, "windows": []},
        "limits-before-context.json": {"sessionID": SESSION_B, "title": None, "contextPercent": None, "contextTokens": None,
                                       "contextWindow": 1000000, "costUSD": 0, "windows": both},
        "full-subscriber.json": {"sessionID": SESSION_A, "title": "Alpha refactor v2", "modelID": "claude-opus-5-5",
                                 "modelName": "Opus 5.5", "contextPercent": 5.0005, "contextTokens": 50005,
                                 "contextWindow": 1000000, "costUSD": 0.4321, "fastMode": True, "windows": both},
        "fractional-percentages.json": {"sessionID": SESSION_A, "contextPercent": 5.0005, "contextTokens": 50005,
                                        "windows": [{"id": "5h", "label": "5-hour limit", "usedPercent": 23.5, "resetsAtEpoch": five["resets_at"]},
                                                    {"id": "7d", "label": "Weekly limit", "usedPercent": 41.2, "resetsAtEpoch": seven["resets_at"]}]},
        "api-key-user.json": {"sessionID": SESSION_C, "title": "landing-page", "modelID": "claude-opus-4-5-20251101",
                              "modelName": "Opus 4.5", "contextPercent": 12.55, "contextTokens": 25100, "contextWindow": 200000,
                              "costUSD": 1.2345, "fastMode": False, "windows": []},
        "weekly-only.json": {"sessionID": SESSION_A, "contextPercent": 5.0005,
                             "windows": [{"id": "7d", "label": "Weekly limit", "usedPercent": 100, "resetsAtEpoch": seven["resets_at"]}]},
        "gateway-spend-limit.json": {"sessionID": SESSION_A, "contextPercent": 5.0005,
                                     "windows": [{"id": "spend", "label": "Spend limit", "usedPercent": 62.8,
                                                  "resetsAtEpoch": gateway["rate_limits"]["spend_limit"]["resets_at"],
                                                  "usedUSD": 314.12, "limitUSD": 500, "period": "monthly"}]},
        "after-compact-observed.json": {"sessionID": SESSION_A, "contextPercent": 0, "contextTokens": 0, "windows": both,
                                        "note": "all-zero current_usage: show 0% (or the transcript's compactMetadata.postTokens if known)"},
        "after-compact-documented.json": {"sessionID": SESSION_A, "contextPercent": None, "contextTokens": None, "windows": both},
    }


def build_sessions_file():
    started = epoch("2026-10-10T06:49:48Z")
    write_json("sessions/41001.json", {
        "pid": 41001, "sessionId": SESSION_A, "cwd": ALPHA_CWD, "startedAt": started * 1000 + 512,
        "procStart": datetime.fromtimestamp(started, timezone.utc).strftime("%a %b %d %H:%M:%S %Y"),
        "version": "2.1.296", "peerProtocol": 1, "peerFeatures": ["notify_idle"],
        "kind": "interactive", "entrypoint": "cli", "pidDomain": "darwin",
        "name": "Alpha refactor v2", "nameSource": "user", "nameSince": epoch("2026-10-10T18:10:30Z") * 1000,
        "status": "idle", "updatedAt": epoch("2026-10-10T18:10:04Z") * 1000 + 250,
        "statusUpdatedAt": epoch("2026-10-10T18:10:04Z") * 1000 + 250,
    })
    # A session blocked on a permission prompt, as observed on 2.1.295 (desktop app): status "waiting"
    # plus "waitingFor". The values are the documented ones of `claude agents --json`.
    started = epoch("2026-10-11T18:59:30Z")
    write_json("sessions/41002.json", {
        "pid": 41002, "sessionId": SESSION_C, "cwd": BETA_CWD, "startedAt": started * 1000 + 87,
        "procStart": datetime.fromtimestamp(started, timezone.utc).strftime("%a %b %d %H:%M:%S %Y"),
        "version": "2.1.295", "peerProtocol": 1,
        "peerFeatures": ["notify_idle", "reply_across_default_dirs", "artifact_yield"],
        "kind": "interactive", "entrypoint": "claude-desktop",
        "hostSessionId": "local_00000000-0000-4000-8000-00000c0ffee0", "pidDomain": "darwin",
        "name": "beta site-7q", "nameSource": "derived", "nameSince": started * 1000 + 90,
        "status": "waiting", "updatedAt": epoch("2026-10-11T19:40:02Z") * 1000 + 15,
        "statusUpdatedAt": epoch("2026-10-11T19:40:02Z") * 1000 + 15,
        "waitingFor": "permission prompt",
    })


def main():
    for sub in ("projects", "incremental", "statusline", "sessions", "set-aside"):
        shutil.rmtree(os.path.join(HERE, sub), ignore_errors=True)
    first_prompt, a1_lines, tr1, a2_lines, a3_line = build_session_a()
    build_session_a_subagents(a3_line)
    build_session_b(first_prompt, a1_lines, tr1, a2_lines)
    build_session_c()
    build_session_e()
    incremental = build_incremental()
    expected = build_expected(incremental)
    expected["statusline"] = build_statusline()
    expected["setAside"] = build_set_aside()
    build_sessions_file()
    write_json("expected.json", expected)
    print("wrote fixtures under", HERE)


if __name__ == "__main__":
    main()
