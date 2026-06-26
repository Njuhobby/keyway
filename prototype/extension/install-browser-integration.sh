#!/usr/bin/env bash
# Connect the Keyway browser extension to a PRE-BUILT Keyway.app.
#
# Run this once after you've installed Keyway.app and unzipped this folder. It
# registers the native-messaging host (pointing at the bridge bundled inside
# Keyway.app) for every Chromium-family browser and Firefox it finds, then
# prints how to load the unpacked extension.
#
# Usage:
#     ./install-browser-integration.sh [/path/to/Keyway.app]
# Defaults to /Applications/Keyway.app.
set -euo pipefail

# Fixed extension IDs (Chrome ID is pinned by the "key" in manifest.json;
# Firefox by the gecko id in its manifest), so this script needs no arguments
# beyond the optional app path.
CHROME_EXT_ID="pepjkpbkjlbjchimdcjeplppecgpdpmj"
FIREFOX_EXT_ID="keyway@local"

APP="${1:-/Applications/Keyway.app}"
BRIDGE="$APP/Contents/MacOS/keyway-bridge"
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "$BRIDGE" ]; then
  echo "error: keyway-bridge not found at"
  echo "    $BRIDGE"
  echo
  echo "Install Keyway.app into /Applications first, or pass its path:"
  echo "    $0 /path/to/Keyway.app"
  exit 1
fi

write_host() {           # $1 = host dir, $2 = origins-json line, $3 = label
  local host_dir="$1"
  mkdir -p "$host_dir"
  cat > "$host_dir/com.keyway.bridge.json" <<JSON
{
  "name": "com.keyway.bridge",
  "description": "Keyway extension bridge",
  "path": "$BRIDGE",
  "type": "stdio",
  $2
}
JSON
  echo "  installed: $3"
}

chromium() {             # $1 = browser support dir, $2 = label
  [ -d "$1" ] || return 0      # browser not installed → skip silently
  write_host "$1/NativeMessagingHosts" \
    "\"allowed_origins\": [\"chrome-extension://$CHROME_EXT_ID/\"]" "$2"
}

echo "==> Registering native-messaging host"
echo "    bridge: $BRIDGE"
chromium "$HOME/Library/Application Support/Google/Chrome"                  "Chrome"
chromium "$HOME/Library/Application Support/Google/Chrome Beta"             "Chrome Beta"
chromium "$HOME/Library/Application Support/Google/Chrome Canary"           "Chrome Canary"
chromium "$HOME/Library/Application Support/Chromium"                       "Chromium"
chromium "$HOME/Library/Application Support/Microsoft Edge"                 "Edge"
chromium "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"    "Brave"
if [ -d "$HOME/Library/Application Support/Mozilla" ] || command -v firefox >/dev/null 2>&1; then
  write_host "$HOME/Library/Application Support/Mozilla/NativeMessagingHosts" \
    "\"allowed_extensions\": [\"$FIREFOX_EXT_ID\"]" "Firefox"
fi

cat <<EOF

==> Done. Now load the extension (one-time, per browser):

  Chrome / Edge / Brave / Chromium
    1. open  chrome://extensions   (edge://extensions, brave://extensions)
    2. turn on  Developer mode  (top-right toggle)
    3. click  Load unpacked  and choose:
         $DIR/chrome-extension
       (it loads with the fixed ID $CHROME_EXT_ID)

  Firefox
    1. open  about:debugging#/runtime/this-firefox
    2. click  Load Temporary Add-on…  and choose:
         $DIR/firefox-extension/manifest.json

Make sure Keyway.app is running, then open any web page and press Caps Lock.

Note: unpacked (Chrome) and temporary (Firefox) extensions are dropped when the
browser restarts — repeat the "load" step each session. Without the extension,
web pages still work through Keyway's on-device vision fallback.
EOF
