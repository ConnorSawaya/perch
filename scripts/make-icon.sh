#!/bin/bash
# make-icon.sh — draw the app icon and pack it as Resources/AppIcon.icns.
#
# Usage: scripts/make-icon.sh
# The icon is drawn in code by scripts/make-icon.swift (no artwork files). This script compiles
# that drawing program, lets it write every PNG size into a temporary .iconset folder, and has
# macOS's `iconutil` pack the folder into the .icns file that scripts/build.sh copies into the app.
# Run it again after changing the drawing; the .icns file is kept in the project.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
WORK="$ROOT/.build/icon"
ICONSET="$WORK/AppIcon.iconset"
rm -rf "$WORK"
mkdir -p "$ICONSET" "$ROOT/Resources"

swiftc "${SWIFTFLAGS[@]}" -O -o "$WORK/make-icon" "$ROOT/scripts/make-icon.swift"
"$WORK/make-icon" "$ICONSET"
iconutil --convert icns --output "$ROOT/Resources/AppIcon.icns" "$ICONSET"
# A large preview for looking at the result.
cp "$ICONSET/icon_512x512@2x.png" "$WORK/AppIcon-1024.png"
cp "$ICONSET/icon_32x32.png" "$WORK/AppIcon-32.png"
echo "wrote $ROOT/Resources/AppIcon.icns (preview: .build/icon/AppIcon-1024.png)"
