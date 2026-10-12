#!/bin/bash
# e2e-claude.sh — proves Perch end to end with the REAL Claude Code CLI.
#
# Usage: scripts/e2e-claude.sh           (build first; uses exactly 2 `claude -p` runs on haiku)
#        KEEP=1 scripts/e2e-claude.sh    keep the temporary folder to look at the evidence
#
# What it does:
#   1. starts build/Perch.app with its files in a temporary PERCH_HOME (no login item, no real
#      preferences), answering every request automatically — first "allow", then "deny";
#   2. writes the settings file Perch would install, using the app's own ClaudeAdapter installer,
#      into a throwaway folder (never ~/.claude);
#   3. runs `claude -p` in a throwaway project under .build/, passing that file with --settings and
#      leaving the user's own settings out (--setting-sources project,local), asking for a command
#      that needs permission;
#   4. watches the app's debug channel while Claude runs.
#
# Why it proves something: headless Claude Code refuses a command that needs permission unless
# a hook says yes. So the file existing after the "allow" run means Perch's answer was accepted,
# and the file missing after the "deny" run means its refusal was.
#
# The child `claude` gets a scrubbed environment (docs/research/claude-hooks-live.md §1.1): this
# script may itself be running inside a Claude session, whose variables must not leak in.
# PERCH_HOME is passed on so the hooks' helper finds the test app's socket.
# Claude Code itself writes its usual session files under ~/.claude/projects; that is its doing.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

APP="$ROOT/build/Perch.app"
BIN="$APP/Contents/MacOS/Perch"
CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
[ -x "$BIN" ] || { echo "build/Perch.app is missing: run scripts/build.sh first" >&2; exit 2; }
[ -x "$CLAUDE" ] || { echo "claude was not found at $CLAUDE" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/perch-cc.XXXXXX")"
if [ "${#WORK}" -gt 80 ]; then rmdir "$WORK"; WORK="$(mktemp -d /tmp/perch-cc.XXXXXX)"; fi
export PERCH_HOME="$WORK/home"
HOOK="$PERCH_HOME/bin/perch-hook"
SOCKET="$PERCH_HOME/perch.sock"
CONFIG="$WORK/claude-config"
PROJECT="$ROOT/.build/e2e-claude/project"
EVIDENCE="$ROOT/.build/e2e-claude/evidence"
rm -rf "$ROOT/.build/e2e-claude"
mkdir -p "$PERCH_HOME" "$CONFIG" "$PROJECT" "$EVIDENCE" "$WORK/agents/codex" "$WORK/agents/gemini-home"
echo "A throwaway project for Perch's end-to-end test." > "$PROJECT/README.md"

APP_PID=""; WATCH_PID=""; PASSED=0; FAILED=0
cleanup() {
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.3; done
    kill -KILL "$APP_PID" 2>/dev/null
  fi
  if [ "${KEEP:-0}" = "1" ]; then echo "(kept $WORK)"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

ok()   { PASSED=$((PASSED + 1)); echo "  ok    $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }
debug() { env -i PERCH_HOME="$PERCH_HOME" "$HOOK" --agent perch --channel debug --wait --timeout 5 < /dev/null; }

cat > "$PERCH_HOME/preferences.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>perch.hasCompletedOnboarding</key><true/>
  <key>perch.showHeadlessSessions</key><true/>
  <key>perch.soundsEnabled</key><false/>
  <key>perch.autoExpandOnAttention</key><false/>
</dict></plist>
EOF

start_app() {
  env -i HOME="$HOME" USER="${USER:-}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" \
      PERCH_HOME="$PERCH_HOME" PERCH_NO_LOGIN_ITEM=1 PERCH_TEST_AUTORESOLVE="$1" PERCH_TEST_AUTORESOLVE_DELAY=0.6 \
      CLAUDE_CONFIG_DIR="$CONFIG" CODEX_HOME="$WORK/agents/codex" GEMINI_CLI_HOME="$WORK/agents/gemini-home" \
      "$BIN" > "$EVIDENCE/app.$1.out" 2>&1 &
  APP_PID=$!
  local tries=0
  while [ ! -S "$SOCKET" ] && [ "$tries" -lt 100 ]; do sleep 0.1; tries=$((tries + 1)); done
  [ -S "$SOCKET" ]
}
stop_app() {
  kill -TERM "$APP_PID" 2>/dev/null
  local tries=0
  while kill -0 "$APP_PID" 2>/dev/null && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
  ! kill -0 "$APP_PID" 2>/dev/null
}

# Records the debug report as fast as it can be asked for while Claude runs (roughly a hundred
# times a second), one JSON line each. It has to be that fast: in a headless run "done" lasts
# only the few milliseconds between Claude's Stop and SessionEnd hooks.
watch_start() { ( while true; do debug; echo; done ) > "$1" 2>/dev/null & WATCH_PID=$!; }
watch_stop()  { kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; WATCH_PID=""; }

# run_claude <name> <prompt>: one headless run with a scrubbed environment.
run_claude() {
  ( cd "$PROJECT" && env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" SHELL=/bin/zsh \
      PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 TERM=xterm-256color \
      PERCH_HOME="$PERCH_HOME" \
      "$CLAUDE" -p "$2" --model haiku --settings "$CONFIG/settings.json" --setting-sources project,local \
      --output-format json < /dev/null > "$EVIDENCE/$1.result.json" 2> "$EVIDENCE/$1.stderr" )
}

# Summarises what the watcher saw for the run's session. Prints key=value lines.
cat > "$WORK/summarise.py" <<'EOF'
import json, sys
states, titles, tools, pending_tools, events = [], [], [], [], []
session_id = None
max_pending = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    for s in d.get("sessions", []):
        if s["agent"] != "claude":
            continue
        session_id = s["id"]
        if not states or states[-1] != s["state"]:
            states.append(s["state"])
        if s["title"] not in titles:
            titles.append(s["title"])
        for tool in s["recentTools"]:
            if tool not in tools:
                tools.append(tool)
        headless = s["isHeadless"]
    max_pending = max(max_pending, len(d.get("pending", [])))
    for p in d.get("pending", []):
        if p["tool"] not in pending_tools:
            pending_tools.append(p["tool"])
    acts = [(a["event"], a["direction"], a["summary"]) for a in reversed(d.get("recentActivity", [])) if a["agent"] == "claude"]
    if len(acts) > len(events):
        events = acts
print("session=" + str(session_id))
print("states=" + ",".join(states))
print("titles=" + " | ".join(titles))
print("tools=" + ",".join(tools))
print("pending_tools=" + ",".join(pending_tools))
print("max_pending=" + str(max_pending))
print("events=" + ",".join(e[0] for e in events))
for e in events:
    if e[1] == "outgoing":
        print("decision=" + e[2])
EOF
field() { grep "^$2=" "$1" | head -1 | cut -d= -f2-; }

# --- settings file ------------------------------------------------------------------------------

echo "0. the settings file Perch would install (written into a throwaway folder)"
check "the app starts (answering allow)" start_app allow
mkdir -p "$ROOT/.build/e2e-claude/tool"
FILES=(); add_sources Sources/Contract Sources/Core/Adapters/Claude Tests/E2ESupport/ClaudeSettingsTool.swift
if swiftc "${SWIFTFLAGS[@]}" -Onone -parse-as-library -o "$ROOT/.build/e2e-claude/tool/claude-settings-tool" "${FILES[@]}" > "$EVIDENCE/tool-build.log" 2>&1; then
  ok "built the installer tool from the app's ClaudeAdapter sources"
else
  fail "built the installer tool" "$(head -5 "$EVIDENCE/tool-build.log")"; exit 1
fi
"$ROOT/.build/e2e-claude/tool/claude-settings-tool" "$CONFIG" "$HOOK" "$PERCH_HOME/backups" > "$EVIDENCE/install.txt" 2>&1
check "the installer ran and reports the hooks as installed" [ $? -eq 0 ]
sed 's/^/        /' "$EVIDENCE/install.txt"
check "it detected Claude Code's version on this Mac" grep -q "detected version: [0-9]" "$EVIDENCE/install.txt"
cp "$CONFIG/settings.json" "$EVIDENCE/settings.json"
check "the settings include a waiting PermissionRequest hook aimed at the test helper" python3 -c '
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
command = hooks["PermissionRequest"][0]["hooks"][0]["command"]
sys.exit(0 if sys.argv[2] in command and command.endswith("--event PermissionRequest --wait") else 1)' "$CONFIG/settings.json" "$HOOK"
echo "        events: $(python3 -c 'import json,sys; print(", ".join(json.load(open(sys.argv[1]))["hooks"].keys()))' "$CONFIG/settings.json")"

# --- run 1: allow -------------------------------------------------------------------------------

echo "1. real Claude Code, Perch answering ALLOW"
watch_start "$EVIDENCE/allow.watch.ndjson"
run_claude allow 'Run exactly this one bash command and nothing else: touch perch-allow-proof.txt   Then reply with the single word done.'
claude_status=$?
sleep 0.5
watch_stop
python3 "$WORK/summarise.py" "$EVIDENCE/allow.watch.ndjson" > "$EVIDENCE/allow.summary.txt"
sed 's/^/        /' "$EVIDENCE/allow.summary.txt"
check "claude exited 0 (was $claude_status)" [ "$claude_status" -eq 0 ]
check "(b) the command really ran: perch-allow-proof.txt exists" [ -f "$PROJECT/perch-allow-proof.txt" ]
check "(a) the session showed up titled with the prompt" grep -q "^titles=.*Run exactly this one bash command" "$EVIDENCE/allow.summary.txt"
check "(a) tool activity: Bash was seen running" grep -q "^tools=.*Bash" "$EVIDENCE/allow.summary.txt"
check "the permission request was shown as a card for Bash" [ "$(field "$EVIDENCE/allow.summary.txt" pending_tools)" = "Bash" ]
check "the session went through needsApproval" grep -q "^states=.*needsApproval" "$EVIDENCE/allow.summary.txt"
check "Perch sent an allow decision" grep -qi "^decision=.*allow" "$EVIDENCE/allow.summary.txt"
check "(d) the turn finishing marked the session done" grep -q "^states=.*done" "$EVIDENCE/allow.summary.txt"
check "the events arrived in order: prompt, tool, request, tool end, stop" python3 -c '
import sys
events = sys.argv[1].split(",")
wanted = ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop"]
position = -1
for name in wanted:
    if name not in events[position + 1:]:
        sys.exit(1)
    position = events.index(name, position + 1)
sys.exit(0)' "$(field "$EVIDENCE/allow.summary.txt" events)"
check "claude reports no permission denials" python3 -c '
import json, sys
sys.exit(0 if not json.load(open(sys.argv[1])).get("permission_denials") else 1)' "$EVIDENCE/allow.result.json"
check "the app quits cleanly" stop_app

# --- run 2: deny --------------------------------------------------------------------------------

echo "2. real Claude Code, Perch answering DENY"
check "the app starts (answering deny)" start_app deny
watch_start "$EVIDENCE/deny.watch.ndjson"
run_claude deny 'Run exactly this one bash command and nothing else: touch perch-deny-proof.txt   If it is refused, do not try anything else; reply with the single word refused.'
claude_status=$?
sleep 0.5
watch_stop
python3 "$WORK/summarise.py" "$EVIDENCE/deny.watch.ndjson" > "$EVIDENCE/deny.summary.txt"
sed 's/^/        /' "$EVIDENCE/deny.summary.txt"
check "(c) the command was refused: perch-deny-proof.txt does not exist" [ ! -e "$PROJECT/perch-deny-proof.txt" ]
check "the permission request was shown as a card" [ "$(field "$EVIDENCE/deny.summary.txt" max_pending)" -ge 1 ]
check "Perch sent a deny decision" grep -qi "^decision=.*den" "$EVIDENCE/deny.summary.txt"
check "the refusal reached Claude as Perch's own message" grep -q "Denied automatically by Perch" "$EVIDENCE/deny.result.json" "$HOME/.claude/projects/"*e2e-claude-project*/*.jsonl 2>/dev/null
check "(d) the turn still finished and the session was marked done" grep -q "^states=.*done" "$EVIDENCE/deny.summary.txt"
echo "        claude's answer: $(python3 -c 'import json,sys; print(repr(json.load(open(sys.argv[1])).get("result", ""))[:120])' "$EVIDENCE/deny.result.json" 2>/dev/null)"
check "the app quits cleanly" stop_app
check "no socket file is left" [ ! -e "$SOCKET" ]
APP_PID=""
if grep -q " ERROR " "$PERCH_HOME/logs/perch.log"; then fail "no errors in the app's log" "$(grep ' ERROR ' "$PERCH_HOME/logs/perch.log" | head -3)"; else ok "no errors in the app's log"; fi
cp "$PERCH_HOME/logs/perch.log" "$EVIDENCE/perch.log"

echo
echo "evidence kept in .build/e2e-claude/evidence/"
if [ "$FAILED" -eq 0 ]; then echo "REAL CLAUDE CODE: all $PASSED checks passed (2 claude runs)"; exit 0; fi
echo "REAL CLAUDE CODE: $PASSED passed, $FAILED FAILED (2 claude runs)"
exit 1
