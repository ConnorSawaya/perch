#!/bin/bash
# install.sh — build Perch and put it in /Applications.
#
# Usage: scripts/install.sh
# Builds the release app, quits a running copy, copies Perch.app into /Applications and opens it.
# Needs macOS 15 or later on Apple silicon and the Xcode Command Line Tools (`xcode-select --install`).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh" release
osascript -e 'tell application id "local.perch.app" to quit' >/dev/null 2>&1 || true
sleep 1
ditto "$ROOT/build/Perch.app" /Applications/Perch.app
open /Applications/Perch.app
echo "Perch is installed. Open Settings from the bird in the menu bar and click Connect for your agents."
