#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# 1. Build
swift build

# 2. Replace linker-signed signature with proper ad-hoc, otherwise TCC rejects.
BIN=.build/arm64-apple-macosx/debug/Keyway
codesign --force --sign - "$BIN"

# 3. Kill any old instance, then launch fresh.
pkill -f Keyway 2>/dev/null || true

# Dev convenience: enable the OmniParser debug overlay
# (/tmp/keyway-focused.png with kept/rejected boxes drawn). Off by
# default in production .app launches. Unset for a quick "what does
# steady-state cost look like without diagnostics" measurement.
export KEYWAY_DEBUG_OVERLAY=1

exec "$BIN"
