#!/bin/bash
# e2e.sh — proves the plumbing end to end, from the real hook helper to the real built app.
#
# Usage: scripts/e2e.sh            (build first with scripts/build.sh)
#        KEEP=1 scripts/e2e.sh     keep the temporary folder afterwards, to look at logs
#
# What it does: starts build/Perch.app with all of its files in a temporary folder (PERCH_HOME),
# feeds it the hook payloads captured from real agents (Fixtures/) through the real `perch-hook`
# program, and asks the app what it now believes through its debug channel:
#
#     perch-hook --agent perch --channel debug --wait      → one line of JSON
#
# Nothing real is touched: no login item (PERCH_NO_LOGIN_ITEM), no real preferences (they live in
# $PERCH_HOME/preferences.plist), and the agents' config folders are pointed at empty temporary
# folders. The island may show in the notch for the few seconds the test runs. Every process the
# script starts is gone when it ends.
#
# The checks, in order:
#   1. the helper is silent and exits 0 while the app is not running
#   2. the app starts, listens, installs the helper
#   3. a whole Claude Code turn: the session appears and its state follows every event
#   4. a blocking PermissionRequest waits, shows as a request, and is answered
#   5. a helper that disconnects clears its request
#   6. an unknown agent gets an immediate "no opinion"
#   7. a Codex turn and an Antigravity turn from their fixtures
#   8. a second copy of the app steps aside for the first
#   9. the app quits cleanly and leaves no socket; "deny" is answered as deny on a second run

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

APP="$ROOT/build/Perch.app"
BIN="$APP/Contents/MacOS/Perch"
BUNDLED_HOOK="$APP/Contents/Helpers/perch-hook"
FIX="$ROOT/Fixtures"
[ -x "$BIN" ] || { echo "build/Perch.app is missing: run scripts/build.sh first" >&2; exit 2; }

# A Unix socket path may be at most 103 bytes, so the temporary folder must be a short one.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/perch-e2e.XXXXXX")"
if [ "${#WORK}" -gt 80 ]; then rmdir "$WORK"; WORK="$(mktemp -d /tmp/perch-e2e.XXXXXX)"; fi
export PERCH_HOME="$WORK/home"
HOOK="$PERCH_HOME/bin/perch-hook"      # the copy the app installs at launch
SOCKET="$PERCH_HOME/perch.sock"
mkdir -p "$PERCH_HOME" "$WORK/agents/claude" "$WORK/agents/codex" "$WORK/agents/gemini-home" "$WORK/out"

APP_PID=""
PASSED=0
FAILED=0

cleanup() {
  # Children first: helpers that are still waiting, then the app.
  pkill -P $$ -f "perch-hook" 2>/dev/null
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.3; done
    kill -KILL "$APP_PID" 2>/dev/null
  fi
  if [ "${KEEP:-0}" = "1" ]; then echo "(kept $WORK)"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# --- small tools ------------------------------------------------------------------------------

# Evaluates a Python expression against the app's debug report (read from stdin).
#   d = the whole report; s("8596") = the session whose id contains that text (or {});
#   pending = the request cards; counts / server = those parts of the report.
cat > "$WORK/q.py" <<'EOF'
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    d = {}
if "server" not in d:
    # No report at all (the app did not answer). Nothing may count as true then, not even
    # "there are no sessions".
    sys.exit(1)
def s(part):
    for session in d.get("sessions", []):
        if part in session["id"]:
            return session
    return {}
pending = d.get("pending", [])
counts = d.get("counts", {})
server = d.get("server", {})
value = eval(sys.argv[1])
if len(sys.argv) > 2 and sys.argv[2] == "print":
    print(value)
sys.exit(0 if value else 1)
EOF

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# Runs the helper the way an agent would, with nothing inherited from this shell: the shell may
# itself be running inside an agent, whose variables would otherwise leak into the events.
#   hook <agent> <payload-file> [more helper options...]
hook() {
  local agent="$1" payload="$2"; shift 2
  env -i PERCH_HOME="$PERCH_HOME" "$HOOK" --agent "$agent" --pid $$ "$@" < "$payload"
}

debug() { env -i PERCH_HOME="$PERCH_HOME" "$HOOK" --agent perch --channel debug --wait --timeout 5 < /dev/null; }

ok()   { PASSED=$((PASSED + 1)); echo "  ok    $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }

# expect "<what>" '<python expression>': true within 3 seconds (events are applied a moment
# after the helper has handed them over), otherwise a failure that shows what the app reported.
expect() {
  local what="$1" expression="$2" report="" tries=0
  while [ "$tries" -lt 30 ]; do
    report="$(debug)"
    if python3 "$WORK/q.py" "$expression" <<< "$report"; then ok "$what"; return 0; fi
    tries=$((tries + 1)); sleep 0.1
  done
  fail "$what" "expected: $expression"
  echo "        sessions: $(python3 "$WORK/q.py" '[(x["id"][:22], x["state"], x["currentTool"]) for x in d.get("sessions", [])]' print <<< "$report")"
  echo "        pending:  $(python3 "$WORK/q.py" '[(x["kind"], x["tool"]) for x in pending]' print <<< "$report")"
  return 1
}

# check "<what>" <command...>: passes when the command succeeds.
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }

seed_preferences() {
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
}

# start_app <allow|deny> <delay seconds>
start_app() {
  env -i HOME="$HOME" USER="${USER:-}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" \
      PERCH_HOME="$PERCH_HOME" PERCH_NO_LOGIN_ITEM=1 PERCH_TEST_AUTORESOLVE="$1" PERCH_TEST_AUTORESOLVE_DELAY="$2" \
      CLAUDE_CONFIG_DIR="$WORK/agents/claude" CODEX_HOME="$WORK/agents/codex" GEMINI_CLI_HOME="$WORK/agents/gemini-home" \
      "$BIN" > "$WORK/out/app.$1.out" 2>&1 &
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

# --- 1. helper with no app --------------------------------------------------------------------

echo "1. the helper while Perch is not running"
started=$(now_ms)
output="$(env -i PERCH_HOME="$PERCH_HOME" "$BUNDLED_HOOK" --agent claude --event PermissionRequest --wait < "$FIX/claude/hooks/PermissionRequest.Write.json" 2>&1)"
status=$?
elapsed=$(( $(now_ms) - started ))
check "exits 0 (status $status)" [ "$status" -eq 0 ]
check "prints nothing, not even to stderr" [ -z "$output" ]
check "returns at once even with --wait (${elapsed} ms including Python's own start-up)" [ "$elapsed" -lt 1000 ]

# --- 2. start ---------------------------------------------------------------------------------

echo "2. starting the app (automatic answer: allow after 1 s)"
seed_preferences
check "the app starts and opens its socket" start_app allow 1.0
check "the helper was copied to $HOOK" [ -x "$HOOK" ]
check "the installed helper is the bundled one" cmp -s "$HOOK" "$BUNDLED_HOOK"
expect "debug channel: listening, helper installed, no sessions yet" \
  'server["running"] and d["helperInstalled"] and d["sessions"] == [] and pending == [] and d["app"]["autoResolve"] == "allow"'
expect "debug channel: login item handling is off for this run" 'd["app"]["loginItemHandling"] == False'
expect "debug channel: files live in the temporary folder" "d['app']['supportDir'] == '$PERCH_HOME'"

# --- 3. a whole Claude Code turn ---------------------------------------------------------------

echo "3. a whole Claude Code turn (captured payloads, session 8596e483)"
C="$FIX/claude/hooks"
hook claude "$C/SessionStart.startup.headless.json" --event SessionStart
expect "SessionStart: the session appears, idle, titled after its folder" \
  's("8596e483").get("state") == "idle" and s("8596e483")["title"] == "demo" and s("8596e483")["agent"] == "claude"'
hook claude "$C/UserPromptSubmit.json" --event UserPromptSubmit
expect "UserPromptSubmit: working, and the prompt becomes the title" \
  's("8596e483").get("state") == "working" and s("8596e483")["title"].startswith("Do exactly two tool calls") and s("8596e483")["turnCount"] == 1'
hook claude "$C/PreToolUse.Bash.json" --event PreToolUse
expect "PreToolUse(Bash): running a tool" 's("8596e483").get("state") == "runningTool" and s("8596e483")["currentTool"] == "Bash"'
hook claude "$C/PostToolUse.Bash.json" --event PostToolUse
expect "PostToolUse(Bash): back to working" 's("8596e483").get("state") == "working" and s("8596e483")["currentTool"] is None'
hook claude "$C/PreToolUse.Read.json" --event PreToolUse
expect "PreToolUse(Read): running a tool again" 's("8596e483").get("state") == "runningTool" and s("8596e483")["currentTool"] == "Read"'
hook claude "$C/PostToolUseFailure.Read.json" --event PostToolUseFailure
expect "PostToolUseFailure(Read): working, two tools counted" \
  's("8596e483").get("state") == "working" and s("8596e483")["toolCount"] == 2 and s("8596e483")["recentTools"] == ["Bash", "Read"]'
hook claude "$C/Stop.json" --event Stop
expect "Stop: done, with the agent's last message" 's("8596e483").get("state") == "done" and s("8596e483")["lastMessage"] == "done"'
hook claude "$C/SessionEnd.other.json" --event SessionEnd
expect "SessionEnd: the session is marked ended" 's("8596e483").get("state") == "ended"'
sleep 5
expect "…and its card is removed a few seconds later" 's("8596e483") == {}'

# --- 4. a blocking request --------------------------------------------------------------------

echo "4. a blocking PermissionRequest (session 17b84d42, Write)"
hook claude "$C/PreToolUse.Write.json" --event PreToolUse
started=$(now_ms)
( hook claude "$C/PermissionRequest.Write.json" --event PermissionRequest --wait > "$WORK/out/allow.stdout" 2> "$WORK/out/allow.stderr"
  echo $? > "$WORK/out/allow.status" ) &
waiter=$!
expect "the request shows as a card and the session needs approval" \
  'len(pending) == 1 and pending[0]["tool"] == "Write" and s("17b84d42").get("state") == "needsApproval" and server["waitingHelpers"] == 1'
check "the helper is still waiting (nothing printed yet)" [ ! -s "$WORK/out/allow.stdout" ]
wait "$waiter"
elapsed=$(( $(now_ms) - started ))
check "the helper exits 0 after the answer" [ "$(cat "$WORK/out/allow.status")" = "0" ]
check "it waited for the answer (${elapsed} ms; the automatic answer comes after 1000 ms)" [ "$elapsed" -ge 900 ]
check "it printed Claude Code's allow decision" python3 -c '
import json, sys
out = json.load(open(sys.argv[1]))["hookSpecificOutput"]
sys.exit(0 if out == {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}} else 1)' "$WORK/out/allow.stdout"
check "nothing on stderr" [ ! -s "$WORK/out/allow.stderr" ]
expect "afterwards: no request left, session working again" \
  'pending == [] and s("17b84d42").get("state") == "working" and server["waitingHelpers"] == 0'
hook claude "$C/PostToolUse.Write.json" --event PostToolUse

# --- 5. a helper that disconnects ---------------------------------------------------------------

echo "5. a helper that goes away before the answer (session 35ba84ce, Bash)"
env -i PERCH_HOME="$PERCH_HOME" "$HOOK" --agent claude --pid $$ --event PermissionRequest --wait \
  < "$C/PermissionRequest.Bash.session-suggestions.json" > "$WORK/out/gone.stdout" 2>&1 &
gone=$!
expect "the request is waiting" 'len(pending) == 1 and pending[0]["tool"] == "Bash" and s("35ba84ce").get("state") == "needsApproval"'
kill -TERM "$gone" 2>/dev/null
wait "$gone" 2>/dev/null
expect "after the helper is killed the request is gone and the session is working" \
  'pending == [] and s("35ba84ce").get("state") == "working" and server["waitingHelpers"] == 0 and server["connections"] <= 1'
check "the killed helper printed nothing" [ ! -s "$WORK/out/gone.stdout" ]
sleep 1.3   # past the moment the automatic answer would have come
expect "the automatic answer for the vanished request did no harm" 'pending == [] and s("35ba84ce").get("state") == "working"'
check "the app is still running" kill -0 "$APP_PID"

# --- 6. an unknown agent ------------------------------------------------------------------------

echo "6. an agent Perch does not know"
before="$(python3 "$WORK/q.py" 'counts["turnedAway"]' print <<< "$(debug)")"
started=$(now_ms)
output="$(env -i PERCH_HOME="$PERCH_HOME" "$HOOK" --agent nosuchagent --event PermissionRequest --wait < "$C/PermissionRequest.Write.json" 2>&1)"
status=$?
elapsed=$(( $(now_ms) - started ))
check "an immediate reply instead of a wait (${elapsed} ms including Python's own start-up)" [ "$elapsed" -lt 700 ]
check "no opinion: nothing printed, exit 0" [ -z "$output" -a "$status" -eq 0 ]
expect "the app counted it as turned away and made no session or request" \
  "counts['turnedAway'] == ${before:-0} + 1 and pending == [] and not any(x['agent'] not in ('claude',) for x in d['sessions'])"

# --- 7. other agents ----------------------------------------------------------------------------

echo "7a. a Codex turn (fixtures, session 019a9d1e)"
X="$FIX/codex/hooks"
hook codex "$X/SessionStart.startup.json"
expect "Codex SessionStart: the session appears" 's("019a9d1e").get("agent") == "codex" and s("019a9d1e")["state"] == "idle"'
hook codex "$X/UserPromptSubmit.json"
expect "Codex UserPromptSubmit: working, titled by the prompt" \
  's("019a9d1e").get("state") == "working" and s("019a9d1e")["title"].startswith("Bump the API version")'
hook codex "$X/PreToolUse.Bash.json"
expect "Codex PreToolUse: running a tool" 's("019a9d1e").get("state") == "runningTool"'
hook codex "$X/PostToolUse.Bash.json"
( hook codex "$X/PermissionRequest.Bash.json" --wait > "$WORK/out/codex.stdout" 2>&1; echo $? > "$WORK/out/codex.status" ) &
waiter=$!
expect "Codex PermissionRequest: a card, and the session needs approval" \
  'len(pending) == 1 and pending[0]["agent"] == "codex" and s("019a9d1e").get("state") == "needsApproval"'
wait "$waiter"
check "the helper printed Codex's allow decision (same JSON as Fixtures/codex/decisions)" python3 -c '
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$WORK/out/codex.stdout" "$FIX/codex/decisions/PermissionRequest.allow.stdout.json"
hook codex "$X/Stop.json"
expect "Codex Stop: done" 's("019a9d1e").get("state") == "done" and pending == []'

echo "7b. an Antigravity turn (synthetic fixture sequence, conversation 7b0e7f0a)"
python3 - "$FIX/antigravity/sequences/turn.with-pretooluse.synth.ndjson" "$WORK/out" <<'EOF'
import json, sys
for index, line in enumerate(open(sys.argv[1])):
    entry = json.loads(line)
    open(f"{sys.argv[2]}/agy-{index:02d}-{entry['event']}.json", "w").write(json.dumps(entry["payload"]))
EOF
seen_busy=0
for payload in "$WORK"/out/agy-*.json; do
  event="$(basename "$payload" .json)"; event="${event#agy-??-}"
  hook antigravity "$payload" --event "$event"
  if [ "$event" = "PreToolUse" ]; then
    expect "Antigravity PreToolUse: running a tool" 's("7b0e7f0a").get("agent") == "antigravity" and s("7b0e7f0a")["state"] == "runningTool"' && seen_busy=1
  fi
done
check "the Antigravity session was seen running its tool" [ "$seen_busy" -eq 1 ]
expect "Antigravity Stop: done" 's("7b0e7f0a").get("state") == "done"'
expect "three agents' sessions are on show together" 'sorted(set(x["agent"] for x in d["sessions"])) == ["antigravity", "claude", "codex"]'

# --- 8. single instance -------------------------------------------------------------------------

echo "8. a second copy of the app"
started=$(now_ms)
env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" PERCH_HOME="$PERCH_HOME" PERCH_NO_LOGIN_ITEM=1 \
    "$BIN" > "$WORK/out/second.out" 2>&1 &
second=$!
tries=0
while kill -0 "$second" 2>/dev/null && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
if kill -0 "$second" 2>/dev/null; then
  fail "the second copy quits by itself"; kill -KILL "$second" 2>/dev/null
else
  wait "$second"; status=$?
  check "the second copy quits by itself with status 0 (after $(( $(now_ms) - started )) ms)" [ "$status" -eq 0 ]
fi
check "the first copy still owns the socket" [ -S "$SOCKET" ]
expect "the first copy still answers and kept its sessions" 'server["running"] and len(d["sessions"]) >= 3'
check "the log says why" grep -q "another Perch is already running" "$PERCH_HOME/logs/perch.log"

# --- 9. quitting --------------------------------------------------------------------------------

echo "9. quitting"
env -i PERCH_HOME="$PERCH_HOME" "$HOOK" --agent claude --pid $$ --event PermissionRequest --wait \
  < "$C/PermissionRequest.Bash.addRules-suggestion.json" > "$WORK/out/atquit.stdout" 2>&1 &
atquit=$!
expect "a helper is waiting when the app is told to quit" 'server["waitingHelpers"] == 1'
check "the app quits on SIGTERM" stop_app
wait "$APP_PID" 2>/dev/null; app_status=$?
check "…with exit status 0 (was $app_status)" [ "$app_status" -eq 0 ]
check "no socket file is left" [ ! -e "$SOCKET" ]
wait "$atquit"; status=$?
check "the waiting helper was let go: exit 0, nothing printed" [ "$status" -eq 0 -a ! -s "$WORK/out/atquit.stdout" ]
check "the log records a tidy stop" grep -q "Perch stopped" "$PERCH_HOME/logs/perch.log"
if grep -q " ERROR " "$PERCH_HOME/logs/perch.log"; then
  fail "no errors in the log" "$(grep ' ERROR ' "$PERCH_HOME/logs/perch.log" | head -3)"
else
  ok "no errors in the log"
fi
check "the app wrote nothing to stdout or stderr" [ ! -s "$WORK/out/app.allow.out" ]
output="$(hook claude "$C/Stop.json" --event Stop 2>&1)"; status=$?
check "with the app gone the helper is silent again and exits 0" [ -z "$output" -a "$status" -eq 0 ]

echo "9b. a second run answering deny"
check "the app starts again on the same folder" start_app deny 0.2
output="$(hook claude "$C/PermissionRequest.Write.json" --event PermissionRequest --wait 2>/dev/null)"
check "the helper printed Claude Code's deny decision with a message" python3 -c '
import json, sys
decision = json.loads(sys.argv[1])["hookSpecificOutput"]["decision"]
sys.exit(0 if decision["behavior"] == "deny" and decision["message"] else 1)' "$output"
expect "the denied session carries on (the agent decides what next)" 'pending == [] and s("17b84d42").get("state") == "working"'
check "the app quits" stop_app
check "no socket file is left" [ ! -e "$SOCKET" ]
APP_PID=""

echo
if pgrep -f "$BIN" > /dev/null; then fail "no Perch process is left running"; else ok "no Perch process is left running"; fi
echo
if [ "$FAILED" -eq 0 ]; then echo "END TO END: all $PASSED checks passed"; exit 0; fi
echo "END TO END: $PASSED passed, $FAILED FAILED"
exit 1
