#!/bin/bash
# smoke.sh — start the built app as a brand-new install would see it, for a few seconds, and time a hook.
#
# Usage: scripts/smoke.sh        (build first with scripts/build.sh)
#
# The app gets a temporary PERCH_HOME and no login item, but no seeded preferences, so this is
# a true first run: the Settings window opens with the welcome panel for about six seconds.
# It reads the real agent folders (to report what it detects) and checks afterwards that they
# are unchanged; a PERCH_HOME run cannot change them even if a button is clicked. It then
# measures the cost of one hook (scripts/measure-hook.py), quits the app with SIGTERM and
# prints the log.

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
BIN="$ROOT/build/Perch.app/Contents/MacOS/Perch"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/perch-smoke.XXXXXX")"
export PERCH_HOME="$WORK/home"; mkdir -p "$PERCH_HOME"
md5_before="$(md5 -q "$HOME/.claude/settings.json")"; codex_before="$(ls -la "$HOME/.codex" | md5 -q)"
env -i HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$TMPDIR" PERCH_HOME="$PERCH_HOME" PERCH_NO_LOGIN_ITEM=1 "$BIN" > "$WORK/app.out" 2>&1 &
APP=$!
sleep 6
echo "alive after 6 s: $(kill -0 $APP 2>/dev/null && echo yes || echo NO)"
env -i PERCH_HOME="$PERCH_HOME" "$PERCH_HOME/bin/perch-hook" --agent perch --channel debug --wait --timeout 5 < /dev/null > "$WORK/debug.json"
python3 - "$WORK/debug.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print("server:", d["server"]["running"], "| helper installed:", d["helperInstalled"], "| sessions:", len(d["sessions"]), "| expanded:", d["app"]["expanded"], "| uptime:", d["app"]["uptimeSeconds"])
for a in d["agents"]: print("  agent", a["agent"], a["hookStatus"], a["version"], a["configPath"])
print("  session agents:", sorted(set(s["agent"] for s in d["sessions"])), "from file watchers:", d["counts"]["fromFileWatchers"])
PY
echo "--- overhead (step 7)"
"$ROOT/scripts/measure-hook.py" 300
echo "--- quit"
kill -TERM $APP; for i in $(seq 1 50); do kill -0 $APP 2>/dev/null || break; sleep 0.1; done
wait $APP; echo "exit status: $?  socket left: $([ -e "$PERCH_HOME/perch.sock" ] && echo YES || echo no)"
echo "stdout/stderr bytes: $(wc -c < "$WORK/app.out")"; head -c 600 "$WORK/app.out"
echo "--- log"; cut -c1-230 "$PERCH_HOME/logs/perch.log"
echo "errors in log: $(grep -c ' ERROR ' "$PERCH_HOME/logs/perch.log")"
echo "files:"; (cd "$PERCH_HOME" && find . -maxdepth 2 | sort | head -30)
echo "~/.claude/settings.json unchanged: $([ "$md5_before" = "$(md5 -q "$HOME/.claude/settings.json")" ] && echo yes || echo NO)"
echo "~/.codex listing unchanged: $([ "$codex_before" = "$(ls -la "$HOME/.codex" | md5 -q)" ] && echo yes || echo NO)"
echo "real prefs domain: $(defaults read local.perch.app 2>&1 | tail -1)"
echo "real support folder: $(ls "$HOME/Library/Application Support/Perch")"
echo "crash reports: $(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -ci perch)"
rm -rf "$WORK"
