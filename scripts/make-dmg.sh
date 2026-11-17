#!/bin/bash
# Builds a release LayX.app and packages it as build/LayX-<version>.dmg (drag-to-Applications layout).
#   scripts/make-dmg.sh            build, then package
#   scripts/make-dmg.sh --no-build package the existing build/LayX.app
set -euo pipefail
cd "$(dirname "$0")/.."

[ "${1:-}" = "--no-build" ] || scripts/build-app.sh release

APP=build/LayX.app
[ -d "$APP" ] || { echo "build/LayX.app not found" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/LayX-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Lay X.app"
ln -s /Applications "$STAGE/Applications"
# Volume icon = app icon.
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

rm -f "$DMG" build/LayX-rw.dmg
hdiutil create -quiet -volname "Lay X" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov build/LayX-rw.dmg
# Mark the volume as having a custom icon (kHasCustomIcon) when SetFile is available.
if xcrun --find SetFile >/dev/null 2>&1; then
    MOUNT=$(hdiutil attach -nobrowse -noautoopen build/LayX-rw.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')
    xcrun SetFile -a C "$MOUNT" || true
    hdiutil detach -quiet "$MOUNT"
fi
hdiutil convert -quiet build/LayX-rw.dmg -format ULFO -o "$DMG"
rm -f build/LayX-rw.dmg
hdiutil verify -quiet "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
