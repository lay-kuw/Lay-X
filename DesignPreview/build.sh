#!/bin/bash
# Builds the preview app and writes the full output to DesignPreview/build.log
cd "$(dirname "$0")"

# SwiftUI macros (@State etc.) need the full Xcode toolchain, not Command Line Tools.
XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1)
if [ -n "$XCODE" ]; then export DEVELOPER_DIR="$XCODE/Contents/Developer"; fi

{
  echo "=== $(date) ==="
  sw_vers 2>/dev/null
  echo "DEVELOPER_DIR=${DEVELOPER_DIR:-<not set: Xcode.app not found in /Applications>}"
  xcodebuild -version 2>&1
  swift --version 2>&1
  echo "=== swift build ==="
  rm -rf .build
  swift build 2>&1
  echo "=== exit: $? ==="
} > build.log 2>&1

if [ -z "$XCODE" ]; then
  echo "Xcode.app was not found in /Applications. Install Xcode from the App Store and run again."
fi
echo "errors: $(grep -c 'error:' build.log)  →  $(pwd)/build.log"
