#!/usr/bin/env python3
"""Reference implementation of the Claude usage scanner described in docs/research/claude-usage.md.

It is deliberately small and literal so the Swift version can be checked against it:

    python3 tools/reference_scan.py                    check the fixtures against expected.json
    python3 tools/reference_scan.py --update-expected  also (re)write expected.json's scanDiagnostics
    python3 tools/reference_scan.py --root ~/.claude   print totals for a real Claude folder (read-only)

Only the Python standard library is used. Nothing is written except with --update-expected.
"""
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from decimal import Decimal
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRICING = json.load(open(os.path.join(HERE, "pricing.json")))
PRICE = {m["id"]: m for m in PRICING["models"]}
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TITLE_MAX = 60


# ---------------------------------------------------------------------------- pricing

def normalize_model(model):
    m = model.lower()
    m = re.sub(r"\[1m\]$", "", m)
    m = re.sub(r"^.*/", "", m)                          # gateway form such as anthropic/claude-opus-4-8
    m = re.sub(r"^([a-z0-9-]+\.)?anthropic\.", "", m)
    m = re.sub(r"-v1(:0)?$", "", m)
    m = re.sub(r"[-@]\d{8}$", "", m)
    return m


def cost_of(ev):
    """USD for one API response, or None when the model has no price."""
    p = PRICE.get(normalize_model(ev["model"]))
    if p is None:
        return None
    D = lambda x: Decimal(str(x))
    rates = p
    lc = p.get("long_context")
    prompt = ev["input"] + ev["cacheWrite5m"] + ev["cacheWrite1h"] + ev["cacheRead"]
    if lc and prompt > lc["prompt_tokens_over"]:
        rates = lc                                    # the WHOLE request moves to the higher prices
    usd = (D(ev["input"]) * D(rates["input"]) + D(ev["output"]) * D(rates["output"])
           + D(ev["cacheWrite5m"]) * D(rates["cache_write_5m"]) + D(ev["cacheWrite1h"]) * D(rates["cache_write_1h"])
           + D(ev["cacheRead"]) * D(rates["cache_read"])) / Decimal(1000000)
    if ev["speed"] == "fast":
        usd *= D(p.get("fast_multiplier", 1))
    if ev["geo"] == "us":
        usd *= D(PRICING["inference_geo_us_multiplier"])
    return usd + D(ev["webSearch"]) * D(PRICING["web_search_usd_per_request"])


def context_window_for(model, tokens):
    p = PRICE.get(normalize_model(model))
    window = 200000
    largest = 1000000
    if p:
        largest = p.get("context_window", 200000)
        window = p.get("claude_code_default_context_window", largest)
    if tokens > window:                               # evidence beats the table
        window = max(largest, 1000000)
    return window


# ---------------------------------------------------------------------------- the ledger

class Ledger:
    """One entry per API response. Entries are only ever added or improved, never removed
    because a file changed or disappeared (transcripts are deleted after 30 days by default)."""

    def __init__(self):
        self.events = {}                # key -> event dict
        self.by_session_message = {}    # (session, messageId) -> set of keys
        self.stats = dict(assistantLines=0, usageLines=0, duplicateLines=0, sidechainReplays=0,
                          syntheticOrErrorLines=0, malformedLines=0, upgrades=0)
        self.naive = dict(input=0, output=0, cacheWrite=0, cacheRead=0)

    @staticmethod
    def key_for(message_id, request_id, session, timestamp):
        if request_id:
            return (message_id, request_id)                    # global: forks copy lines across sessions
        if message_id.startswith("msg_"):
            return (message_id, "", session)                   # real Anthropic id, unique per response
        return (message_id, "", session, timestamp)            # gateway placeholder ids may repeat

    @staticmethod
    def better(candidate, existing):
        if candidate["sidechain"] != existing["sidechain"]:
            return existing["sidechain"]                       # the main-conversation copy wins
        ct, et = total_tokens(candidate), total_tokens(existing)
        if ct != et:
            return ct > et                                     # final usage beats a streaming placeholder
        return candidate["final"] and not existing["final"]

    def _index(self, ev):
        self.by_session_message.setdefault((ev["session"], ev["messageId"]), set()).add(ev["key"])

    def _remove(self, key):
        ev = self.events.pop(key)
        self.by_session_message[(ev["session"], ev["messageId"])].discard(key)

    def upsert(self, cand):
        # 1. sidechain replay: same message id in the same session, one copy main and one sidechain
        for key in list(self.by_session_message.get((cand["session"], cand["messageId"]), ())):
            if key == cand["key"]:
                continue
            other = self.events[key]
            if cand["sidechain"] and not other["sidechain"]:
                self.stats["sidechainReplays"] += 1
                return
            if other["sidechain"] and not cand["sidechain"]:
                self.stats["sidechainReplays"] += 1
                self._remove(key)
        # 2. exact key
        existing = self.events.get(cand["key"])
        if existing is None:
            self.events[cand["key"]] = cand
            self._index(cand)
            return
        self.stats["duplicateLines"] += 1
        first_ts = min(existing["timestamp"], cand["timestamp"])
        if self.better(cand, existing):
            if total_tokens(cand) != total_tokens(existing):
                self.stats["upgrades"] += 1
            self._remove(cand["key"])
            cand["timestamp"] = first_ts
            self.events[cand["key"]] = cand
            self._index(cand)
        else:
            existing["timestamp"] = first_ts


def total_tokens(ev):
    return ev["input"] + ev["output"] + ev["cacheWrite5m"] + ev["cacheWrite1h"] + ev["cacheRead"]


# ---------------------------------------------------------------------------- reading files

SET_ASIDE_RE = re.compile(r"^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
                          r"(\.orphaned-.+\.jsonl|\.jsonl\.superseded-.+)$")


def is_transcript_name(name):
    """Live transcripts and subagent files end in .jsonl. Claude Code also sets older transcripts
    aside as <session>.orphaned-<timestamp>-<suffix>.jsonl and <session>.jsonl.superseded-<timestamp>
    (documented names; contents assumed to be ordinary transcript lines)."""
    if name == "journal.jsonl":
        return False
    return name.endswith(".jsonl") or SET_ASIDE_RE.match(name) is not None


def path_parts(path, projects_root):
    """-> (projectKey, sessionFromPath or None, usageOnly)

    usageOnly is True for subagent files and for set-aside copies of a main transcript: they feed the
    ledger, but session facts (title, first prompt, context) come from the live <session>.jsonl only."""
    rel = os.path.relpath(path, projects_root).split(os.sep)
    project = rel[0]
    session = None
    usage_only = len(rel) > 2
    if len(rel) >= 2:
        set_aside = SET_ASIDE_RE.match(rel[1]) if len(rel) == 2 else None
        if set_aside:
            session, usage_only = set_aside.group(1), True   # never a phantom session named "<uuid>.orphaned-..."
        else:
            stem = rel[1][:-6] if rel[1].endswith(".jsonl") else rel[1]
            if UUID_RE.match(stem):
                session = stem
    return project, session, usage_only


def int_of(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and v > 0 else 0


def event_from_line(o, project, session_from_path):
    """Turns one parsed transcript line into a candidate usage event, or returns a reason to skip it."""
    msg = o.get("message")
    if not isinstance(msg, dict):
        return None, "no-message"
    usage = msg.get("usage")
    if not isinstance(usage, dict):
        return None, "no-usage"
    model = msg.get("model")
    if not isinstance(model, str) or not model or model == "<synthetic>" or o.get("isApiErrorMessage") is True:
        return None, "synthetic"
    ts = o.get("timestamp")
    if not isinstance(ts, str):
        return None, "no-timestamp"
    session = session_from_path or o.get("sessionId") or "unknown"
    message_id = msg.get("id") or ("uuid:" + str(o.get("uuid")))
    request_id = o.get("requestId") or None

    cache_total = int_of(usage.get("cache_creation_input_tokens"))
    breakdown = usage.get("cache_creation")
    if isinstance(breakdown, dict):
        cw5m = int_of(breakdown.get("ephemeral_5m_input_tokens"))
        cw1h = int_of(breakdown.get("ephemeral_1h_input_tokens"))
        cw5m += max(0, cache_total - cw5m - cw1h)          # anything unexplained is priced as a 5-minute write
    else:
        cw5m, cw1h = cache_total, 0                         # old transcripts: no breakdown
    stu = usage.get("server_tool_use") if isinstance(usage.get("server_tool_use"), dict) else {}
    ev = dict(
        key=Ledger.key_for(message_id, request_id, session, ts),
        messageId=message_id, requestId=request_id, session=session, project=project,
        model=model, timestamp=ts,
        input=int_of(usage.get("input_tokens")), output=int_of(usage.get("output_tokens")),
        cacheWrite5m=cw5m, cacheWrite1h=cw1h, cacheRead=int_of(usage.get("cache_read_input_tokens")),
        webSearch=int_of(stu.get("web_search_requests")),
        speed=usage.get("speed") or "standard", geo=usage.get("inference_geo") or "global",
        sidechain=o.get("isSidechain") is True,
        final=("speed" in usage) or ("iterations" in usage) or (msg.get("stop_reason") is not None),
        incomplete=msg.get("stop_reason") is None,
    )
    return ev, None


def prompt_text(o):
    """Text of a line a person typed, or None."""
    if o.get("type") != "user" or o.get("isSidechain") is True or o.get("isMeta") is True or "toolUseResult" in o:
        return None
    if o.get("isCompactSummary") is True or o.get("isVisibleInTranscriptOnly") is True:
        return None                                        # the summary Claude Code writes after a compaction
    origin = o.get("origin")
    if isinstance(origin, dict) and origin.get("kind") not in (None, "human"):
        return None
    content = (o.get("message") or {}).get("content")
    if isinstance(content, list):
        texts = [b.get("text") for b in content if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)]
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content) or not texts:
            return None
        content = texts[0]
    if not isinstance(content, str):
        return None
    text = content.strip()
    if not text or text.startswith("<"):                  # <command-name>, <local-command-stdout>, <system-reminder>...
        return None
    return text


def title_from_prompt(text):
    first_line = next((ln for ln in text.splitlines() if ln.strip()), "")
    collapsed = " ".join(first_line.split())
    if len(collapsed) <= TITLE_MAX:
        return collapsed
    return collapsed[:TITLE_MAX - 1].rstrip() + "…"


class SessionInfo:
    def __init__(self, session, project):
        self.session, self.project = session, project
        self.cwd = self.git_branch = self.entrypoint = self.version = None
        self.custom_title = self.ai_title = self.first_prompt = self.last_prompt = None
        self.first_ts = self.last_ts = None
        self.context = None
        self.last_model = None
        self.cost_state = None          # the last cost-state line (Claude Code's own session total)

    def summary(self):
        if self.custom_title:                               # a name the user chose
            title, source = self.custom_title, "custom-title"
        elif self.ai_title:                                 # the title Claude Code generated
            title, source = self.ai_title, "ai-title"
        elif self.first_prompt:
            title, source = title_from_prompt(self.first_prompt), "first-prompt"
        else:
            title, source = os.path.basename(self.cwd or self.project), "folder"
        first_line = None
        if self.first_prompt:
            first_line = " ".join(next((ln for ln in self.first_prompt.splitlines() if ln.strip()), "").split())
        return {"project": self.project, "cwd": self.cwd, "gitBranch": self.git_branch, "entrypoint": self.entrypoint,
                "version": self.version, "title": title, "titleSource": source, "firstPrompt": first_line,
                "lastPrompt": self.last_prompt, "context": self.context,
                "firstTimestamp": self.first_ts, "lastTimestamp": self.last_ts}


def process_line(raw, project, session_from_path, is_subagent_file, ledger, sessions):
    try:
        o = json.loads(raw)
    except ValueError:
        ledger.stats["malformedLines"] += 1
        return
    if not isinstance(o, dict):
        ledger.stats["malformedLines"] += 1
        return
    kind = o.get("type")
    session = session_from_path or o.get("sessionId") or "unknown"

    if not is_subagent_file:                               # session facts come from the main transcript only
        info = sessions.setdefault(session, SessionInfo(session, project))
        ts = o.get("timestamp")
        if isinstance(ts, str):
            info.first_ts = ts if info.first_ts is None else min(info.first_ts, ts)
            info.last_ts = ts if info.last_ts is None else max(info.last_ts, ts)
        for field, attr in (("cwd", "cwd"), ("gitBranch", "git_branch"), ("entrypoint", "entrypoint"), ("version", "version")):
            if isinstance(o.get(field), str) and o[field]:
                if attr == "cwd" and info.cwd is not None:
                    continue                               # keep the first cwd: it names the project
                setattr(info, attr, o[field])
        if kind == "custom-title" and isinstance(o.get("customTitle"), str) and o["customTitle"].strip():
            info.custom_title = o["customTitle"].strip()
        elif kind == "ai-title" and isinstance(o.get("aiTitle"), str) and o["aiTitle"].strip():
            info.ai_title = o["aiTitle"].strip()
        elif kind == "cost-state" and isinstance(o.get("totalCostUSD"), (int, float)):
            info.cost_state = o
        elif kind == "system" and o.get("subtype") == "compact_boundary":
            meta = o.get("compactMetadata") if isinstance(o.get("compactMetadata"), dict) else {}
            post = meta.get("postTokens")
            if isinstance(post, int) and info.last_model:
                window = context_window_for(info.last_model, post)
                info.context = {"source": "compact-boundary", "messageId": None, "model": info.last_model,
                                "tokens": post, "window": window, "percent": round(post / window * 100, 4)}
            else:
                info.context = None                        # unknown until the next response
        elif kind == "last-prompt" and isinstance(o.get("lastPrompt"), str):
            info.last_prompt = " ".join(o["lastPrompt"].split())
        elif kind == "user" and info.first_prompt is None:
            text = prompt_text(o)
            if text:
                info.first_prompt = text

    if kind != "assistant":
        return
    ledger.stats["assistantLines"] += 1
    ev, why = event_from_line(o, project, session_from_path)
    if ev is None:
        if why == "synthetic":
            ledger.stats["syntheticOrErrorLines"] += 1
        return
    ledger.stats["usageLines"] += 1
    ledger.naive["input"] += ev["input"]
    ledger.naive["output"] += ev["output"]
    ledger.naive["cacheWrite"] += ev["cacheWrite5m"] + ev["cacheWrite1h"]
    ledger.naive["cacheRead"] += ev["cacheRead"]
    if not ev["sidechain"] and not is_subagent_file:
        tokens = ev["input"] + ev["cacheWrite5m"] + ev["cacheWrite1h"] + ev["cacheRead"]
        window = context_window_for(ev["model"], tokens)
        sessions[session].last_model = ev["model"]
        sessions[session].context = {"source": "assistant-usage", "messageId": ev["messageId"], "model": ev["model"],
                                     "tokens": tokens, "window": window, "percent": round(tokens / window * 100, 4)}
    ledger.upsert(ev)


# ---------------------------------------------------------------------------- incremental reading

class FileState:
    """What the scanner remembers about one file between ticks."""

    def __init__(self):
        self.offset = 0          # first byte not yet consumed (always just after a newline)
        self.tail = b""          # hash of the 64 bytes before `offset`, to notice a rewritten file


def read_new_lines(data, state):
    """`data` is the file's current bytes. Returns the complete new lines and updates `state`."""
    tail_now = hashlib.sha256(data[max(0, state.offset - 64):state.offset]).digest() if state.offset else b""
    if len(data) < state.offset or tail_now != state.tail:
        state.offset = 0                                    # truncated or rewritten: start again (the ledger de-dups)
    end = data.rfind(b"\n", state.offset)
    if end < 0:
        return []                                           # no complete new line yet
    chunk = data[state.offset:end]
    state.offset = end + 1
    state.tail = hashlib.sha256(data[max(0, state.offset - 64):state.offset]).digest()
    return [ln for ln in chunk.split(b"\n") if ln.strip()]


def scan_tree(root):
    projects_root = os.path.join(root, "projects")
    files = []
    for dirpath, _dirs, names in os.walk(projects_root):
        for name in names:
            if is_transcript_name(name):
                files.append(os.path.join(dirpath, name))
    files.sort()                                            # fixtures: path order == creation order
    ledger, sessions = Ledger(), {}
    for path in files:
        project, session_from_path, is_sub = path_parts(path, projects_root)
        state = FileState()
        with open(path, "rb") as fh:
            for raw in read_new_lines(fh.read(), state):
                process_line(raw, project, session_from_path, is_sub, ledger, sessions)
    return ledger, sessions, files


# ---------------------------------------------------------------------------- aggregation

def local_day(ts, tzname):
    ts = ts.replace("Z", "+00:00")
    dt = datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(ZoneInfo(tzname)).strftime("%Y-%m-%d")


def empty():
    return dict(messages=0, input=0, output=0, cacheWrite5m=0, cacheWrite1h=0, cacheWrite=0, cacheRead=0,
                webSearchRequests=0, costUSD=Decimal(0))


def add(t, ev, usd):
    t["messages"] += 1
    t["input"] += ev["input"]
    t["output"] += ev["output"]
    t["cacheWrite5m"] += ev["cacheWrite5m"]
    t["cacheWrite1h"] += ev["cacheWrite1h"]
    t["cacheWrite"] += ev["cacheWrite5m"] + ev["cacheWrite1h"]
    t["cacheRead"] += ev["cacheRead"]
    t["webSearchRequests"] += ev["webSearch"]
    t["costUSD"] += usd


def money(x):
    return float(Decimal(x).quantize(Decimal("0.0000000001")))


def finish(t):
    t = dict(t)
    t["totalTokens"] = t["input"] + t["output"] + t["cacheWrite"] + t["cacheRead"]
    t["costUSD"] = money(t["costUSD"])
    return t


def group(keyfn, priced):
    out = {}
    for ev, usd in priced:
        add(out.setdefault(keyfn(ev), empty()), ev, usd)
    return {k: finish(v) for k, v in sorted(out.items())}


def aggregate(ledger, timezones=("America/Los_Angeles", "UTC")):
    priced, unpriced = [], set()
    for ev in ledger.events.values():
        usd = cost_of(ev)
        if usd is None:
            unpriced.add(normalize_model(ev["model"]))
            usd = Decimal(0)
        priced.append((ev, usd))
    total = empty()
    for ev, usd in priced:
        add(total, ev, usd)
    days = {}
    for tz in timezones:
        per = {}
        for day in sorted({local_day(ev["timestamp"], tz) for ev, _ in priced}):
            sub = [(ev, usd) for ev, usd in priced if local_day(ev["timestamp"], tz) == day]
            t = empty()
            for ev, usd in sub:
                add(t, ev, usd)
            per[day] = {"totals": finish(t),
                        "byModel": group(lambda e: normalize_model(e["model"]), sub),
                        "byProject": group(lambda e: e["project"], sub),
                        "bySession": group(lambda e: e["session"], sub)}
        days[tz] = per
    return {
        "allTime": finish(total),
        "unpricedModels": sorted(unpriced),
        "byModel": group(lambda e: normalize_model(e["model"]), priced),
        "byProject": group(lambda e: e["project"], priced),
        "bySession": group(lambda e: e["session"], priced),
        "bySidechain": group(lambda e: "sidechain" if e["sidechain"] else "main", priced),
        "days": days,
    }, priced


# ---------------------------------------------------------------------------- checks

FAILURES = []


def check(label, got, want):
    if got != want:
        FAILURES.append(label)
        print("MISMATCH", label)
        print("   got :", json.dumps(got, sort_keys=True)[:600])
        print("   want:", json.dumps(want, sort_keys=True)[:600])


def close(a, b):
    return abs(a - b) < 1e-9


def check_totals(label, got, want):
    for k in set(got) | set(want):
        g, w = got.get(k), want.get(k)
        ok = close(g, w) if isinstance(g, float) or isinstance(w, float) else g == w
        if not ok:
            FAILURES.append(label + "." + k)
            print("MISMATCH %s.%s got %r want %r" % (label, k, g, w))


def check_groups(label, got, want):
    check(label + " keys", sorted(got), sorted(want))
    for k in want:
        if k in got:
            check_totals("%s[%s]" % (label, k), got[k], want[k])


def run_incremental(expected):
    ledger, sessions, state = Ledger(), {}, FileState()
    for step in ("step1", "step2", "step3"):
        spec = expected[step]
        data = open(os.path.join(HERE, spec["file"]), "rb").read()
        check("incremental.%s.fileBytes" % step, len(data), spec["fileBytes"])
        if step == "step2":
            check("incremental.step2.resumeFromByte", state.offset, spec["resumeFromByte"])
        for raw in read_new_lines(data, state):
            process_line(raw, "-Users-test-dev-alpha", expected["session"], False, ledger, sessions)
        check("incremental.%s.consumedBytes" % step, state.offset, spec["consumedBytes"])
        got = sorted(ledger.events.values(), key=lambda e: e["messageId"])
        want = spec["events"]
        check("incremental.%s.messageIds" % step, [e["messageId"] for e in got], [e["messageId"] for e in want])
        for g, w in zip(got, want):
            for k in ("input", "output", "cacheWrite5m", "cacheWrite1h", "cacheRead"):
                check("incremental.%s.%s.%s" % (step, w["messageId"], k), g[k], w[k])
            if not close(money(cost_of(g)), w["costUSD"]):
                check("incremental.%s.%s.costUSD" % (step, w["messageId"]), money(cost_of(g)), w["costUSD"])
        agg, _ = aggregate(ledger, timezones=("UTC",))
        t = agg["allTime"]
        check_totals("incremental.%s.totals" % step,
                     {k: t[k] for k in ("messages", "input", "output", "cacheWrite", "cacheRead", "costUSD")}, spec["totals"])


def run_set_aside(spec):
    """Older transcripts of one session, set aside under the documented names (see README)."""
    ledger, sessions, files = scan_tree(os.path.join(HERE, spec["root"]))
    check("setAside.files", sorted(os.path.relpath(f, os.path.join(HERE, spec["root"])) for f in files), sorted(spec["files"]))
    check("setAside.messageIds", sorted(e["messageId"] for e in ledger.events.values()), sorted(spec["messageIds"]))
    check("setAside.sessions (ledger)", sorted({e["session"] for e in ledger.events.values()}), spec["sessions"])
    check("setAside.sessions (records)", sorted(sessions), spec["sessions"])
    check("setAside.projects", sorted({e["project"] for e in ledger.events.values()}), [spec["project"]])
    agg, _ = aggregate(ledger, timezones=("UTC",))
    t = agg["allTime"]
    check_totals("setAside.totals", {k: t[k] for k in ("messages", "input", "output", "cacheWrite", "cacheRead", "costUSD")},
                 spec["totals"])
    info = sessions.get(spec["session"])
    got = info.summary() if info else {}
    check("setAside.title", got.get("title"), spec["title"])
    check("setAside.firstPrompt", got.get("firstPrompt"), spec["firstPrompt"])
    for k in ("tokens", "window", "percent"):
        check("setAside.context." + k, (got.get("context") or {}).get(k), spec["context"][k])


def main():
    args = sys.argv[1:]
    if "--root" in args:
        root = os.path.expanduser(args[args.index("--root") + 1])
        ledger, sessions, files = scan_tree(root)
        agg, _ = aggregate(ledger, timezones=("UTC",))
        print(json.dumps({"files": len(files), "stats": ledger.stats, "naive": ledger.naive, "allTime": agg["allTime"],
                          "byModel": agg["byModel"], "unpricedModels": agg["unpricedModels"]}, indent=2))
        return 0

    expected_path = os.path.join(HERE, "expected.json")
    expected = json.load(open(expected_path))
    ledger, sessions, files = scan_tree(HERE)
    agg, priced = aggregate(ledger)

    check("transcriptFiles", len(files), expected["counts"]["transcriptFiles"])
    check("uniqueResponses", len(ledger.events), expected["counts"]["uniqueResponses"])
    check_totals("allTime", agg["allTime"], expected["allTime"])
    check("unpricedModels", agg["unpricedModels"], expected["unpricedModels"])
    for name in ("byModel", "byProject", "bySession", "bySidechain"):
        check_groups(name, agg[name], expected[name])
    for tz, per in expected["days"].items():
        check("days[%s] keys" % tz, sorted(agg["days"][tz]), sorted(per))
        for day, want in per.items():
            got = agg["days"][tz].get(day)
            if got is None:
                continue
            check_totals("days[%s][%s].totals" % (tz, day), got["totals"], want["totals"])
            for name in ("byModel", "byProject", "bySession"):
                check_groups("days[%s][%s].%s" % (tz, day, name), got[name], want[name])

    by_id = {ev["messageId"]: (ev, usd) for ev, usd in priced}
    for want in expected["events"]:
        got = by_id.get(want["messageId"])
        if got is None:
            check("event " + want["name"], None, want["messageId"])
            continue
        ev, usd = got
        for k in ("requestId", "session", "project", "model", "timestamp", "input", "output", "cacheWrite5m",
                  "cacheWrite1h", "cacheRead", "webSearch", "speed", "geo", "sidechain", "incomplete"):
            check("event %s.%s" % (want["name"], k), ev[k], want[k])
        if not close(money(usd), want["costUSD"]):
            check("event %s.costUSD" % want["name"], money(usd), want["costUSD"])

    for sid, want in expected["sessions"].items():
        got = sessions[sid].summary() if sid in sessions else None
        if got is None:
            check("session " + sid, None, "present")
            continue
        for k in ("project", "cwd", "gitBranch", "entrypoint", "version", "title", "titleSource", "firstPrompt",
                  "lastPrompt", "firstTimestamp", "lastTimestamp"):
            check("session %s.%s" % (sid[:8], k), got[k], want[k])
        for k in ("source", "model", "tokens", "window", "percent"):
            check("session %s.context.%s" % (sid[:8], k), (got["context"] or {}).get(k), want["context"][k])
        cs = sessions[sid].cost_state
        if want.get("costState") is None:
            check("session %s.costState" % sid[:8], cs, None)
        else:
            transcript = agg["bySession"][sid]["costUSD"]
            got_cs = {"totalCostUSD": money(Decimal(str(cs["totalCostUSD"]))), "transcriptCostUSD": transcript,
                      "backgroundCostUSD": money(max(Decimal(0), Decimal(str(cs["totalCostUSD"])) - Decimal(str(transcript))))}
            check_totals("session %s.costState" % sid[:8], got_cs, want["costState"])

    run_incremental(expected["incremental"])
    run_set_aside(expected["setAside"])

    diagnostics = {"scan": ledger.stats, "naiveSumOfEveryUsageLine": ledger.naive,
                   "note": "naiveSumOfEveryUsageLine is what you get WITHOUT de-duplication; it must differ from allTime."}
    if "--update-expected" in args:
        expected["counts"]["assistantLines"] = ledger.stats["assistantLines"]
        expected["scanDiagnostics"] = diagnostics
        with open(expected_path, "w", encoding="utf-8") as fh:
            json.dump(expected, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        print("expected.json updated with scanDiagnostics")
    else:
        check("counts.assistantLines", ledger.stats["assistantLines"], expected["counts"]["assistantLines"])
        check("scanDiagnostics", diagnostics, expected.get("scanDiagnostics"))

    print(json.dumps({"files": len(files), "stats": ledger.stats, "naive": ledger.naive, "allTime": agg["allTime"]}, indent=2))
    if FAILURES:
        print("FAILED: %d mismatches" % len(FAILURES))
        return 1
    print("OK: fixtures match expected.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
