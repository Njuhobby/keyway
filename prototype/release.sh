#!/usr/bin/env bash
# Build a distributable Keyway.app and zip it for a GitHub Release.
# The zip uses `ditto` (not `zip`) so the .app bundle's signature and
# symlinks survive the round-trip. Upload the result to Releases.
set -euo pipefail
cd "$(dirname "$0")"

./package-app.sh release

APP="build/Keyway.app"
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
ZIP="build/Keyway-v${VERSION}.zip"

echo "==> zipping $ZIP (ditto, bundle-safe)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> done"
ls -lh "$ZIP" | awk '{print "    "$5"  "$9}'
echo "    sha256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
echo "Next: upload to a GitHub Release, e.g."
echo "    gh release create v${VERSION} \"$ZIP\" --title \"Keyway v${VERSION}\" --notes \"...\""
