#!/bin/sh
# Perch hook shim for Google Antigravity (reference implementation).
# See docs/research/antigravity.md, section "Recommended AntigravityAdapter".
#
# Antigravity runs:   /bin/sh <this file> <EventName>
# with the event JSON on stdin, and expects JSON on stdout.
#
# Rules this file enforces:
#   1. Answer Antigravity FIRST. A PreToolUse hook that prints nothing, prints
#      garbage, exits non-zero or times out makes Antigravity refuse the tool
#      call, so Perch being crashed or uninstalled must never matter.
#   2. Bound the time spent on Perch. Printing the answer first is not enough:
#      the hook only "finishes" when this process exits, and a hook Antigravity
#      has to kill at its timeout counts as a denial for PreToolUse. So
#      perch-hook runs in the background with a 2 second watchdog, and this
#      script exits no later than that whatever perch-hook does (hangs, waits
#      on a stdin that never closes, blocks on the socket).
#   3. Print ONLY fields Antigravity documents (its parser is strict).
#   4. Always exit 0.
#   5. No shell features in the hooks.json command line itself (one Antigravity
#      runtime executes hook commands without a shell); all logic lives here.
#      The path to this file must not contain spaces for the same reason.
#
# Verified on the research machine only (macOS 26.6, /bin/sh = bash 3.2 in sh
# mode), with fake perch-hook binaries: normal, missing, hanging, and a stdin
# pipe that is never closed. NOT verified against a real Antigravity.
event="${1:-unknown}"
case "$event" in
  PreToolUse) printf '%s' '{"decision":"ask"}' ;;  # defer to Antigravity's own permission engine
  *)          printf '%s' '{}' ;;                   # observer only: nothing injected, never "continue"
esac

PERCH_HOOK="__PERCH_HOOK_PATH__"   # replaced with an absolute path at install time
if [ -x "$PERCH_HOOK" ]; then
  # perch-hook reads the event JSON from stdin and forwards it to the Perch app
  # over its Unix socket. "<&0" is required: a background job in a
  # non-interactive sh otherwise gets /dev/null as stdin.
  "$PERCH_HOOK" --agent antigravity --event "$event" <&0 >/dev/null 2>&1 &
else
  # Perch is not installed: swallow the payload so the writer sees no broken pipe.
  cat <&0 >/dev/null 2>&1 &
fi
reader_pid=$!
( sleep 2; kill -9 "$reader_pid" ) >/dev/null 2>&1 &   # watchdog
watchdog_pid=$!
wait "$reader_pid" 2>/dev/null
kill "$watchdog_pid" 2>/dev/null
exit 0
