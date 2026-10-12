#!/bin/bash
# test.sh — compile and run one test suite.
#
# Usage: scripts/test.sh <Name> [source-file-or-folder ...]
# Compiles Sources/Contract + the given sources + Tests/Harness.swift + Tests/<Name>Tests.swift,
# then runs `run<Name>Tests(_:)`, which Tests/<Name>Tests.swift must define.
# Example: scripts/test.sh Engine Sources/Core/Engine

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
NAME="$1"; shift || { echo "usage: scripts/test.sh <Name> [sources...]" >&2; exit 2; }
OUT="$ROOT/.build/tests/$NAME"
mkdir -p "$OUT"
cat > "$OUT/main.swift" <<EOF
let runner = TestRunner()
run${NAME}Tests(runner)
runner.finish()
EOF
add_sources Sources/Contract "$@" Tests/Harness.swift "Tests/${NAME}Tests.swift" "$OUT/main.swift"
swiftc "${SWIFTFLAGS[@]}" -Onone -o "$OUT/tests" "${FILES[@]}" || exit 1
exec "$OUT/tests"
