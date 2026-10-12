#!/bin/bash
# snapshot.sh — render views to PNG files so their look can be checked without launching the app.
#
# Usage: scripts/snapshot.sh <Name> [source-file-or-folder ...]
# Compiles Sources/Contract + the given sources + Tests/<Name>Snapshots.swift, which must define
#   @MainActor func run<Name>Snapshots(_ out: URL)
# and writes PNGs (via Snapshot.write) into .build/snapshots/<Name>/.
# Example: scripts/snapshot.sh Panel Sources/App/Design Sources/App/Panel Sources/App/Cards

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
NAME="$1"; shift || { echo "usage: scripts/snapshot.sh <Name> [sources...]" >&2; exit 2; }
BUILD="$ROOT/.build/snapshot-build/$NAME"
OUT="$ROOT/.build/snapshots/$NAME"
mkdir -p "$BUILD" "$OUT"
cat > "$BUILD/main.swift" <<EOF
import Foundation
import AppKit
MainActor.assumeIsolated {
    _ = NSApplication.shared
    run${NAME}Snapshots(URL(fileURLWithPath: CommandLine.arguments[1]))
}
EOF
add_sources Sources/Contract "$@" "Tests/${NAME}Snapshots.swift" "$BUILD/main.swift"
swiftc "${SWIFTFLAGS[@]}" -Onone -o "$BUILD/snapshots" "${FILES[@]}" || exit 1
exec "$BUILD/snapshots" "$OUT"
