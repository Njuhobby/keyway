#!/usr/bin/env bash
# Assemble a Firefox-loadable extension directory from the shared sources.
#
# Chrome and Firefox both expect a `manifest.json` at the extension root,
# but the two manifests differ (Chrome: background.service_worker; Firefox:
# background.scripts + browser_specific_settings.gecko). Rather than fork
# the JS, we keep ONE copy of background.js / content_script.js / detector.js
# and just stamp the right manifest. This script copies the shared files +
# `manifest.firefox.json` (renamed to manifest.json) into `dist-firefox/`.
#
# Usage:
#     ./build-firefox.sh
# Then in Firefox: about:debugging#/runtime/this-firefox →
#     "Load Temporary Add-on…" → pick dist-firefox/manifest.json
#
# (Temporary add-ons are removed on Firefox restart — rerun "Load
# Temporary Add-on" each session, same as Chrome's unpacked dev load.)

set -euo pipefail

EXT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$EXT_DIR/dist-firefox"

rm -rf "$OUT"
mkdir -p "$OUT"

cp "$EXT_DIR/manifest.firefox.json" "$OUT/manifest.json"
cp "$EXT_DIR/background.js"     "$OUT/"
cp "$EXT_DIR/content_script.js" "$OUT/"
cp "$EXT_DIR/detector.js"       "$OUT/"
cp -R "$EXT_DIR/vendor"         "$OUT/"

echo "built: $OUT"
echo "  manifest ← manifest.firefox.json (gecko id: mouseless@local)"
echo ""
echo "next:"
echo "  1. ./install_dev_host_firefox.sh   (register the native host for Firefox)"
echo "  2. Mouseless main process running (./run.sh from prototype/)"
echo "  3. Firefox → about:debugging#/runtime/this-firefox"
echo "     → \"Load Temporary Add-on…\" → pick $OUT/manifest.json"
echo "  4. click the Mouseless toolbar icon to trigger the first native ping"
