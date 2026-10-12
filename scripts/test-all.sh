#!/bin/bash
# test-all.sh — run every test suite and say plainly which passed.
#
# Usage: scripts/test-all.sh [--no-views] [SuiteName ...]
#   no arguments     every suite
#   SuiteName ...    only those (e.g. scripts/test-all.sh Engine Runtime)
#   --no-views       skip the three view suites (Panel, Cards, Settings), which draw pictures
#
# Two kinds of suite are run:
#   1. Tests/<Name>Tests.swift      through scripts/test.sh, with the sources that module needs
#   2. Tests/<Name>Snapshots.swift  through scripts/snapshot.sh; besides drawing PNGs these check
#                                   view behaviour (clicks, heights, wording) and fail on a bad check
#
# Each suite's full output goes to .build/tests/<Name>/output.log. The script exits non-zero if
# any suite fails to compile, fails a check, or crashes.
#
# Housekeeping: some suites keep their pretend preferences in throwaway system preference
# domains (local.perch.tests.<random>). Any that appear during this run are removed again at the
# end, so running the tests leaves nothing behind in ~/Library/Preferences.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$ROOT"

# The demo's own files, without SnapshotRunner.swift (which needs every view in the app).
DEMO_FILES=()
while IFS= read -r f; do DEMO_FILES+=("${f#"$ROOT"/}"); done \
  < <(find "$ROOT/Sources/App/Demo" -name '*.swift' ! -name 'SnapshotRunner.swift' | sort)

# Everything in the app except the file that holds the program's entry point.
APP_FILES=(Sources/Core)
while IFS= read -r f; do APP_FILES+=("${f#"$ROOT"/}"); done \
  < <(find "$ROOT/Sources/App" -name '*.swift' ! -name 'PerchApp.swift' | sort)

# sources_for <Name>: fills SOURCES with what that suite is compiled with.
sources_for() {
  case "$1" in
    Contract)       SOURCES=() ;;
    Runtime)        SOURCES=(Sources/Core/Runtime Sources/Helper/HookClient.swift) ;;
    Engine)         SOURCES=(Sources/Core/Engine) ;;
    ClaudeAdapter)  SOURCES=(Sources/Core/Adapters/Claude) ;;
    OtherAdapters)  SOURCES=(Sources/Core/Adapters/Codex Sources/Core/Adapters/Antigravity Sources/Core/Adapters/Gemini Sources/Core/Adapters/Shared) ;;
    Usage)          SOURCES=(Sources/Core/Usage) ;;
    System)         SOURCES=(Sources/Core/System) ;;
    Shell)          SOURCES=(Sources/App/Shell) ;;
    Demo)           SOURCES=("${DEMO_FILES[@]}") ;;
    E2EApp)         SOURCES=("${APP_FILES[@]}") ;;
    Panel)          SOURCES=(Sources/App/Design Sources/App/Panel Sources/App/Cards) ;;
    Cards)          SOURCES=(Sources/App/Design Sources/App/Cards) ;;
    Settings)       SOURCES=(Sources/App/Design Sources/App/Settings "${DEMO_FILES[@]}") ;;
    *)              return 1 ;;
  esac
}

VIEW_SUITES=" Panel Cards Settings "
WITH_VIEWS=1
WANTED=()
for arg in "$@"; do
  if [ "$arg" = "--no-views" ]; then WITH_VIEWS=0; else WANTED+=("$arg"); fi
done

if [ "${#WANTED[@]}" -eq 0 ]; then
  for file in Tests/*Tests.swift; do
    name="$(basename "$file" Tests.swift)"
    WANTED+=("$name")
  done
  if [ "$WITH_VIEWS" -eq 1 ]; then
    for file in Tests/*Snapshots.swift; do WANTED+=("$(basename "$file" Snapshots.swift)"); done
  fi
fi

prefs_snapshot() { ls "$HOME/Library/Preferences" 2>/dev/null | grep '^local\.perch\.' | sort; }
PREFS_BEFORE="$(prefs_snapshot)"

# The Runtime suite runs the real helper as a child process.
echo "==> building the hook helper"
if ! scripts/build-helper.sh > "$ROOT/.build/build-helper.log" 2>&1; then
  echo "FAILED to build the hook helper (see .build/build-helper.log)"
  exit 1
fi

FAILED=()
PASSED=0
for name in "${WANTED[@]}"; do
  if ! sources_for "$name"; then
    echo "FAIL  $name — test-all.sh does not know which sources this suite needs; add it to sources_for"
    FAILED+=("$name")
    continue
  fi
  log_dir="$ROOT/.build/tests/$name"
  mkdir -p "$log_dir"
  log="$log_dir/output.log"
  started=$(date +%s)
  if [[ "$VIEW_SUITES" == *" $name "* ]]; then
    scripts/snapshot.sh "$name" ${SOURCES[@]+"${SOURCES[@]}"} > "$log" 2>&1
    status=$?
    summary="$(grep -c '^check ok' "$log") view checks ok, $(grep -c 'CHECK FAILED' "$log") failed, $(grep -c '^snapshot: ' "$log") pictures"
    # A suite that prints a failed check must not count as passed, whatever its exit status says.
    if grep -q 'CHECK FAILED\|snapshot failed' "$log"; then status=1; fi
  else
    scripts/test.sh "$name" ${SOURCES[@]+"${SOURCES[@]}"} > "$log" 2>&1
    status=$?
    summary="$(grep -E '^[0-9]+ checks passed, [0-9]+ failed$' "$log" | tail -1)"
    # The harness always prints its tally last; no tally means it never got that far.
    if [ -z "$summary" ]; then summary="no result line (did not compile, or crashed)"; status=1; fi
  fi
  seconds=$(( $(date +%s) - started ))
  if grep -q 'warning:' "$log"; then summary="$summary, COMPILER WARNINGS"; fi
  if [ "$status" -eq 0 ]; then
    echo "ok    $name — $summary (${seconds}s)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL  $name — $summary (${seconds}s) — see .build/tests/$name/output.log"
    grep -E '^  FAIL |^  - |CHECK FAILED|error:' "$log" | head -15 | sed 's/^/        /'
    FAILED+=("$name")
  fi
done

# Remove the throwaway preference domains this run created.
REMOVED=0
while IFS= read -r file; do
  [ -z "$file" ] && continue
  if ! grep -qxF "$file" <<< "$PREFS_BEFORE"; then
    defaults delete "${file%.plist}" > /dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$file"
    REMOVED=$((REMOVED + 1))
  fi
done <<< "$(prefs_snapshot)"
[ "$REMOVED" -gt 0 ] && echo "(removed $REMOVED throwaway preference files the tests created)"

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "ALL $PASSED SUITES PASSED"
  exit 0
fi
echo "$PASSED passed, ${#FAILED[@]} FAILED: ${FAILED[*]}"
exit 1
