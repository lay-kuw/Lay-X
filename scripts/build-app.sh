#!/bin/bash
# Builds Lay X and assembles build/LayX.app.
#   scripts/build-app.sh [debug|release]     (default: release)
#   LAYX_NO_MLX=1 scripts/build-app.sh       UI-only build without the MLX engine
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1)
[ -n "$XCODE" ] || { echo "Xcode.app not found in /Applications" >&2; exit 1; }
export DEVELOPER_DIR="$XCODE/Contents/Developer"

swift build -c "$CONFIG" --product LayX
BIN_DIR=$(swift build -c "$CONFIG" --product LayX --show-bin-path)

APP=build/LayX.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp App/Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/LayX" "$APP/Contents/MacOS/LayX"

# SwiftPM resource bundles (mlx-swift_Cmlx.bundle carries default.metallib, swift-transformers carries
# tokenizer data, …). Bundle.module looks next to the executable's bundle and in Contents/Resources.
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
    cp -R "$b" "$APP/Contents/Resources/"
done

# App icon: Sources/LayXIcon/LX.png → AppIcon.icns
ICON_SRC=Sources/LayXIcon/LX.png
if [ -f "$ICON_SRC" ]; then
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    MASTER="$(dirname "$ICONSET")/master.png"
    # Normalise to the macOS icon grid (transparent corners, 824 px body, shadow).
    swift scripts/make-icon.swift "$ICON_SRC" "$MASTER"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

codesign --force --sign - --options runtime --entitlements App/LayX.entitlements "$APP" >/dev/null
echo "Built $(pwd)/$APP"

if [ "${LAYX_NO_MLX:-0}" != "1" ]; then
    echo -n "MLX self-test: "
    "$APP/Contents/MacOS/LayX" --mlx-selftest
fi
