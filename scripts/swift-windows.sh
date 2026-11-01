#!/usr/bin/env bash
# Runs the Swift toolchain on Windows from Git Bash without needing it on PATH.
#   scripts/swift-windows.sh build
#   scripts/swift-windows.sh test --filter FolioReaderTests
set -euo pipefail
SWIFT_ROOT="${SWIFT_ROOT:-$LOCALAPPDATA/Programs/Swift}"
VERSION="${SWIFT_VERSION:-$(ls "$SWIFT_ROOT/Toolchains" | sort -V | tail -1 | sed 's/+Asserts//')}"
export PATH="$SWIFT_ROOT/Toolchains/$VERSION+Asserts/usr/bin:$SWIFT_ROOT/Runtimes/$VERSION/usr/bin:$PATH"
export SDKROOT="$SWIFT_ROOT/Platforms/$VERSION/Windows.platform/Developer/SDKs/Windows.sdk/"
exec swift "$@"
