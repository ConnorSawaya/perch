#!/bin/bash
# build-helper.sh — build only the hook helper, `perch-hook`.
#
# Usage: scripts/build-helper.sh
# Output: .build/bin/perch-hook
#
# The helper is the tiny program agents run on every hook event. It is built from
# Sources/Contract/Wire.swift + Sources/Helper with the same flags scripts/build.sh uses, so
# what the runtime tests exercise is the same program that ships inside Perch.app.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
OUT="$ROOT/.build/bin"
# Build in a scratch folder and move the result into place in one step, so a helper that is
# running (or being copied) right now is never seen half-written.
SCRATCH="$OUT/.building.$$"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

FILES=(); add_sources Sources/Contract/Wire.swift Sources/Helper
swiftc "${SWIFTFLAGS[@]}" -O -o "$SCRATCH/perch-hook" "${FILES[@]}"
mv -f "$SCRATCH/perch-hook" "$OUT/perch-hook"
echo "built $OUT/perch-hook"
