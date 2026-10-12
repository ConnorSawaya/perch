#!/bin/bash
# env.sh — shared settings for the build scripts. Source it; do not run it.
#
# Swift Package Manager is broken on this Command Line Tools install, so everything is built by
# calling `swiftc` directly. The SDK is pinned because the newest SDK is ahead of the compiler.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${PERCH_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
# On a Mac without that exact SDK, use whatever the installed tools point at.
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos15.0"
SWIFTFLAGS=(-swift-version 5 -sdk "$SDK" -target "$TARGET")
export PERCH_ROOT="$ROOT"

# add_sources <file-or-dir>... : appends every .swift file to the FILES array (dirs are searched recursively).
FILES=()
add_sources() {
  local item f
  for item in "$@"; do
    case "$item" in /*) ;; *) item="$ROOT/$item" ;; esac
    if [ -d "$item" ]; then
      while IFS= read -r f; do FILES+=("$f"); done < <(find "$item" -name '*.swift' -type f | sort)
    elif [ -f "$item" ]; then
      FILES+=("$item")
    else
      echo "warning: no such file or folder: $item" >&2
    fi
  done
}
