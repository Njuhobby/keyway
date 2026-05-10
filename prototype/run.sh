#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# 1. Build
swift build

# 2. Replace linker-signed signature with proper ad-hoc, otherwise TCC rejects.
BIN=.build/arm64-apple-macosx/debug/Mouseless
codesign --force --sign - "$BIN"

# 3. Kill any old instance, then launch fresh.
pkill -f Mouseless 2>/dev/null || true
exec "$BIN"
