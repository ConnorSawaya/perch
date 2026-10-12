#!/bin/bash
# typecheck.sh — fast "does it compile?" check for part of the app.
#
# Usage: scripts/typecheck.sh [file-or-folder ...]
# Always includes Sources/Contract. Paths may be absolute or relative to the project root.
# Example: scripts/typecheck.sh Sources/Core/Engine

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
add_sources Sources/Contract "$@"
exec swiftc "${SWIFTFLAGS[@]}" -typecheck -parse-as-library "${FILES[@]}"
