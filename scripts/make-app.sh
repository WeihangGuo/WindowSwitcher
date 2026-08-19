#!/bin/bash
# Builds WindowSwitcher.app from the SwiftPM executable.
# Usage: scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/WindowSwitcher.app"

cd "$ROOT"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/WindowSwitcher"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$BIN" "$APP/Contents/MacOS/WindowSwitcher"

# Ad-hoc sign with a stable identifier so the Accessibility (TCC) grant
# has the best chance of surviving rebuilds.
codesign --force --sign - --identifier dev.window-manager.WindowSwitcher "$APP"

echo "Built: $APP"
echo "Run:   open '$APP'"
