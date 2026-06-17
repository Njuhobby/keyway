#!/usr/bin/env bash
# Install the Chrome Native Messaging host manifest for the Keyway
# extension. One-time dev setup — run after building Keyway and
# loading the extension unpacked, before clicking the extension icon
# for the first time.
#
# Usage:
#     ./install_dev_host.sh <extension-id>
#
# Where <extension-id> is the 32-char string shown under your
# "Keyway (dev)" card at chrome://extensions/.
#
# Writes:
#     ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/
#         com.keyway.bridge.json
#
# pointing at this checkout's `keyway-bridge` binary, with
# allowed_origins locked to the supplied extension ID. Idempotent —
# rerun to update the path or the ID.

set -euo pipefail

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  cat <<EOF
usage: $0 <extension-id>

Find your extension ID at chrome://extensions/ — it's the 32-character
string under the "Keyway (dev)" extension card (after enabling
Developer mode). Example:
    abcdefghijklmnopqrstuvwxyzabcdef
EOF
  exit 1
fi

EXT_ID="$1"
EXT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTOTYPE_DIR="$(cd "$EXT_DIR/.." && pwd)"

# Locate the bridge binary. SwiftPM's per-arch subdirectory makes the
# debug path arch-dependent, so try both common ones.
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

HOST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$HOST_DIR"
HOST_JSON="$HOST_DIR/com.keyway.bridge.json"

cat > "$HOST_JSON" <<EOF
{
  "name": "com.keyway.bridge",
  "description": "Keyway extension bridge (dev)",
  "path": "$BRIDGE_BIN",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$EXT_ID/"
  ]
}
EOF

echo "installed: $HOST_JSON"
echo "  bridge  → $BRIDGE_BIN"
echo "  allowed → chrome-extension://$EXT_ID/"
echo ""
echo "next:"
echo "  1. Keyway main process must be running (./run.sh from prototype/)"
echo "  2. at chrome://extensions/, click the reload icon on \"Keyway (dev)\""
echo "  3. click \"inspect views: service worker\" on its card to open DevTools"
echo "  4. click the Keyway toolbar icon to trigger a ping"
echo "  5. SW console should show:"
echo "       [keyway-bg] action.onClicked — connecting to com.keyway.bridge"
echo "       [keyway-bg] sent: {cmd: 'ping', ...}"
echo "       [keyway-bg] recv from native: {type: 'pong', echo: {...}, from: 'keyway-main'}"
