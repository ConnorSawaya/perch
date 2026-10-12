#!/bin/sh
# Perch status feed for the Antigravity CLI (reference implementation, opt-in).
# Antigravity CLI runs the configured statusLine (or title) command whenever the
# agent state changes, with a JSON state payload on stdin, and renders stdout.
#
# This wrapper forwards a copy of that payload to Perch, then behaves exactly
# like the command the user had configured before (if any).
dir=$(dirname "$0")
payload=$(cat)

PERCH_HOOK="__PERCH_HOOK_PATH__"   # replaced with an absolute path at install time
if [ -x "$PERCH_HOOK" ]; then
  # Bounded like hook.sh: a hung perch-hook must not freeze the status line.
  printf '%s' "$payload" | "$PERCH_HOOK" --agent antigravity --event StatusLine >/dev/null 2>&1 &
  feed_pid=$!
  ( sleep 2; kill -9 "$feed_pid" ) >/dev/null 2>&1 &
  watchdog_pid=$!
  wait "$feed_pid" 2>/dev/null
  kill "$watchdog_pid" 2>/dev/null
fi

# The user's previous command, saved verbatim by the installer (file absent or
# empty when there was none). Its output is passed through untouched.
if [ -s "$dir/original-statusline.cmd" ]; then
  printf '%s' "$payload" | /bin/sh -c "$(cat "$dir/original-statusline.cmd")"
fi
exit 0
