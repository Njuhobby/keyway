#!/usr/bin/env bash
# Install the Chrome Native Messaging host manifest for the Mouseless
# extension. One-time dev setup — run after building Mouseless and
# loading the extension unpacked, before clicking the extension icon
# for the first time.
#
# Usage:
#     ./install_dev_host.sh <extension-id>
#
# Where <extension-id> is the 32-char string shown under your
# "Mouseless (dev)" card at chrome://extensions/.
#
# Writes:
#     ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/
#         com.mouseless.bridge.json
#
# pointing at this checkout's `mouseless-bridge` binary, with
# allowed_origins locked to the supplied extension ID. Idempotent —
# rerun to update the path or the ID.

set -euo pipefail

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  cat <<EOF
usage: $0 <extension-id>

Find your extension ID at chrome://extensions/ — it's the 32-character
string under the "Mouseless (dev)" extension card (after enabling
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
    "$PROTOTYPE_DIR/.build/arm64-apple-macosx/debug/mouseless-bridge" \
    "$PROTOTYPE_DIR/.build/x86_64-apple-macosx/debug/mouseless-bridge" \
    "$PROTOTYPE_DIR/.build/debug/mouseless-bridge"; do
  if [ -x "$candidate" ]; then
    BRIDGE_BIN="$candidate"
    break
  fi
done

if [ -z "${BRIDGE_BIN:-}" ]; then
  echo "error: mouseless-bridge binary not found under $PROTOTYPE_DIR/.build/"
  echo "       run \`swift build\` from the prototype/ directory first"
  exit 1
fi

HOST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$HOST_DIR"
HOST_JSON="$HOST_DIR/com.mouseless.bridge.json"

cat > "$HOST_JSON" <<EOF
{
  "name": "com.mouseless.bridge",
  "description": "Mouseless extension bridge (dev)",
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
echo "  1. Mouseless main process must be running (./run.sh from prototype/)"
echo "  2. at chrome://extensions/, click the reload icon on \"Mouseless (dev)\""
echo "  3. click \"inspect views: service worker\" on its card to open DevTools"
echo "  4. click the Mouseless toolbar icon to trigger a ping"
echo "  5. SW console should show:"
echo "       [mouseless-bg] action.onClicked — connecting to com.mouseless.bridge"
echo "       [mouseless-bg] sent: {cmd: 'ping', ...}"
echo "       [mouseless-bg] recv from native: {type: 'pong', echo: {...}, from: 'mouseless-main'}"
