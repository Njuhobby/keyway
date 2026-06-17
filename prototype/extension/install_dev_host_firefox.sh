#!/usr/bin/env bash
# Install the Firefox Native Messaging host manifest for the Keyway
# extension. Firefox differs from Chrome in two ways here:
#   1. the manifest lives under Mozilla's, not Google's, support dir;
#   2. it allows the add-on by its gecko ID via `allowed_extensions`,
#      NOT by a chrome-extension:// origin.
# The gecko ID is fixed in manifest.firefox.json (keyway@local), so —
# unlike the Chrome installer — this needs no argument.
#
# Usage:
#     ./install_dev_host_firefox.sh
#
# Writes:
#     ~/Library/Application Support/Mozilla/NativeMessagingHosts/
#         com.keyway.bridge.json
# pointing at this checkout's `keyway-bridge` binary. The SAME bridge
# binary + stdio protocol as Chrome — only the host-manifest location and
# the allow-list key differ. Idempotent.

set -euo pipefail

GECKO_ID="keyway@local"   # keep in sync with manifest.firefox.json

EXT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTOTYPE_DIR="$(cd "$EXT_DIR/.." && pwd)"

# Locate the bridge binary (SwiftPM's per-arch debug path).
for candidate in \
    "$PROTOTYPE_DIR/.build/arm64-apple-macosx/debug/keyway-bridge" \
    "$PROTOTYPE_DIR/.build/x86_64-apple-macosx/debug/keyway-bridge" \
    "$PROTOTYPE_DIR/.build/debug/keyway-bridge"; do
  if [ -x "$candidate" ]; then
    BRIDGE_BIN="$candidate"
    break
  fi
done

if [ -z "${BRIDGE_BIN:-}" ]; then
  echo "error: keyway-bridge binary not found under $PROTOTYPE_DIR/.build/"
  echo "       run \`swift build\` from the prototype/ directory first"
  exit 1
fi

HOST_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
mkdir -p "$HOST_DIR"
HOST_JSON="$HOST_DIR/com.keyway.bridge.json"

cat > "$HOST_JSON" <<EOF
{
  "name": "com.keyway.bridge",
  "description": "Keyway extension bridge (dev)",
  "path": "$BRIDGE_BIN",
  "type": "stdio",
  "allowed_extensions": [
    "$GECKO_ID"
  ]
}
EOF

echo "installed: $HOST_JSON"
echo "  bridge  → $BRIDGE_BIN"
echo "  allowed → $GECKO_ID (gecko id)"
echo ""
echo "next:"
echo "  1. Keyway main process must be running (./run.sh from prototype/)"
echo "  2. ./build-firefox.sh, then load dist-firefox/ in about:debugging"
echo "  3. click the Keyway toolbar icon to trigger the first ping"
