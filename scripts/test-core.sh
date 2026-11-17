#!/bin/bash
# Runs the UI/MLX-free test suites (no Metal toolchain needed).
# LAYX_CORE_ONLY drops dependencies from the manifest, which makes SwiftPM rewrite Package.resolved;
# the committed (full) Package.resolved is restored afterwards.
set -uo pipefail
cd "$(dirname "$0")/.."
XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1)
export DEVELOPER_DIR="$XCODE/Contents/Developer"
cp Package.resolved /tmp/layx-Package.resolved.$$
LAYX_CORE_ONLY=1 swift test "$@"
status=$?
cp /tmp/layx-Package.resolved.$$ Package.resolved && rm /tmp/layx-Package.resolved.$$
exit $status
