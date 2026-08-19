#!/bin/bash
# Builds a distributable DMG with the classic drag-to-Applications layout.
# Reuses build/WindowSwitcher.app if present (run scripts/make-app.sh first
# for a fresh binary). Finder scripting needs a one-time Automation
# permission; without it the DMG still works, just with default layout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/WindowSwitcher.app"
STAGING="$ROOT/build/dmg-staging"
VOLNAME="WindowSwitcher"

[ -d "$APP" ] || "$ROOT/scripts/make-app.sh"
VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
DMG="$ROOT/build/WindowSwitcher-$VERSION.dmg"
RW_DMG="$ROOT/build/.dmg-rw.dmg"

rm -rf "$STAGING" "$DMG" "$RW_DMG"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
swift "$ROOT/scripts/render-dmg-background.swift" "$STAGING/.background/background.png"

hdiutil create -srcfolder "$STAGING" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -quiet "$RW_DMG"
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" \
    | awk -F'\t' '/\/Volumes\//{print $NF}')

# Window layout: icon view, app left, Applications right, arrow background.
osascript <<EOF || echo "note: Finder layout skipped (Automation permission not granted); DMG still works."
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set background picture of viewOptions to file ".background:background.png"
        set position of item "WindowSwitcher.app" of container window to {150, 160}
        set position of item "Applications" of container window to {450, 160}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "$MOUNT_DIR" -quiet || (sleep 2 && hdiutil detach "$MOUNT_DIR" -force -quiet)
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG"
rm -rf "$RW_DMG" "$STAGING"

echo "Built: $DMG"
