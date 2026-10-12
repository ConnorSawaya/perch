#!/bin/bash
# build.sh — build Perch.app from source.
#
# Usage: scripts/build.sh [debug|release]      (default: debug)
# Output: build/Perch.app (with the hook helper inside at Contents/Helpers/perch-hook)
#
# Two programs are built:
#   1. perch-hook — the tiny helper agents run on every hook (Wire.swift + Sources/Helper)
#   2. Perch      — the menu-bar app (Sources/Contract + Sources/Core + Sources/App)
# then they are assembled into an .app folder and signed locally.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
MODE="${1:-debug}"
OPT="-Onone"; [ "$MODE" = "release" ] && OPT="-O"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)"
OUT="$ROOT/build"
APP="$OUT/Perch.app"
OBJ="$ROOT/.build/$MODE"
mkdir -p "$OBJ"

echo "==> helper ($MODE)"
FILES=(); add_sources Sources/Contract/Wire.swift Sources/Helper
swiftc "${SWIFTFLAGS[@]}" -O -o "$OBJ/perch-hook" "${FILES[@]}"

echo "==> app ($MODE)"
FILES=(); add_sources Sources/Contract Sources/Core Sources/App
swiftc "${SWIFTFLAGS[@]}" $OPT -parse-as-library -module-name Perch -o "$OBJ/Perch" "${FILES[@]}"

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$OBJ/Perch" "$APP/Contents/MacOS/Perch"
cp "$OBJ/perch-hook" "$APP/Contents/Helpers/perch-hook"
[ -d "$ROOT/Resources" ] && cp -R "$ROOT/Resources/." "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Perch</string>
  <key>CFBundleIdentifier</key><string>local.perch.app</string>
  <key>CFBundleName</key><string>Perch</string>
  <key>CFBundleDisplayName</key><string>Perch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Perch asks your terminal app to bring the right tab to the front when you click a session.</string>
</dict>
</plist>
EOF

echo "==> sign (local, ad-hoc)"
codesign --force --sign - "$APP/Contents/Helpers/perch-hook"
codesign --force --sign - --identifier local.perch.app "$APP"
echo "built $APP"
