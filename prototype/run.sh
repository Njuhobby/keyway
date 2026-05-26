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

# Dev convenience: enable the OmniParser debug overlay
# (/tmp/mouseless-focused.png with kept/rejected boxes drawn). Off by
# default in production .app launches. Unset for a quick "what does
# steady-state cost look like without diagnostics" measurement.
export MOUSELESS_DEBUG_OVERLAY=1

exec "$BIN"
