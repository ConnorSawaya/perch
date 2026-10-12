// AntigravityShim.swift — the small shell script Antigravity runs for each of Perch's hooks.
//
// Why a script instead of calling `perch-hook` directly: Antigravity's hooks FAIL CLOSED. A
// "before tool" hook that prints nothing, exits non-zero, or is killed at its timeout makes
// Antigravity refuse the tool call. So the thing Antigravity runs must give a valid answer no
// matter what state Perch is in: not running, crashed, hung, or deleted.
//
// The script therefore (1) prints Antigravity's answer first, (2) only then hands the event to
// `perch-hook` in the background, with a two-second watchdog so the script always exits in time,
// and (3) always exits 0. It lives next to Antigravity's hooks.json rather than inside Perch, so
// it keeps answering even if Perch is dragged to the Trash without uninstalling.
//
// The logic is the reference shim in Fixtures/antigravity/config/hook.sh, which was exercised with
// missing, hanging and normal stand-ins for `perch-hook` (never under a real Antigravity; see
// docs/research/antigravity.md §9.2). Tests/OtherAdaptersTests.swift runs it the same way.

import Foundation

enum AntigravityShim {

    /// What the shim prints for a "before tool" hook: hand the decision back to Antigravity's own
    /// permission system. ("allow" would switch prompts off the day Antigravity honours it.)
    static let preToolUseAnswer = "{\"decision\":\"ask\"}"
    /// What it prints for every other event: an observer with nothing to add.
    static let observerAnswer = "{}"

    static func script(helperPath: String) -> String {
        """
        #!/bin/sh
        # Perch hook shim for Google Antigravity. Installed by Perch; safe to delete after removing
        # the "perch" block from hooks.json and closing running Antigravity sessions.
        #
        # Antigravity runs:  /bin/sh <this file> <EventName>   with the event JSON on stdin.
        # 1. Answer Antigravity FIRST. A PreToolUse hook that prints nothing, exits non-zero or
        #    times out makes Antigravity refuse the tool call, so Perch must never be able to matter.
        # 2. Then pass the event to Perch in the background, for at most 2 seconds.
        # 3. Always exit 0.
        event="${1:-unknown}"
        case "$event" in
          PreToolUse) printf '%s' '\(preToolUseAnswer)' ;;
          *)          printf '%s' '\(observerAnswer)' ;;
        esac

        PERCH_HOOK=\(ShellQuote.single(helperPath))
        if [ -x "$PERCH_HOOK" ]; then
          # "<&0" is needed: a background job in a non-interactive sh otherwise gets /dev/null as stdin.
          "$PERCH_HOOK" --agent antigravity --event "$event" <&0 >/dev/null 2>&1 &
        else
          # Perch is gone: swallow the payload so the writer sees no broken pipe.
          cat <&0 >/dev/null 2>&1 &
        fi
        reader_pid=$!
        ( sleep 2; kill -9 "$reader_pid" ) >/dev/null 2>&1 &
        watchdog_pid=$!
        wait "$reader_pid" 2>/dev/null
        kill "$watchdog_pid" 2>/dev/null
        exit 0

        """
    }
}
