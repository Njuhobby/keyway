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

# --- Browser-extension bundle (for pre-built users, no checkout needed) ------
# Assemble chrome-extension/ + firefox-extension/ + the installer into one zip.
# install-browser-integration.sh registers the native host against the bridge
# bundled inside Keyway.app, so this works without building from source.
EXTSTAGE="build/keyway-extension"
EXTZIP="build/keyway-extension-v${VERSION}.zip"
echo "==> assembling $EXTZIP"
rm -rf "$EXTSTAGE" "$EXTZIP"
mkdir -p "$EXTSTAGE/chrome-extension"

# Chrome: the shared extension sources minus dev-only helpers.
for f in manifest.json background.js content_script.js detector.js; do
  cp "extension/$f" "$EXTSTAGE/chrome-extension/"
done
[ -d extension/vendor ] && cp -R extension/vendor "$EXTSTAGE/chrome-extension/"

# Firefox: stamp the gecko manifest via the existing build script.
( cd extension && ./build-firefox.sh >/dev/null )
cp -R extension/dist-firefox "$EXTSTAGE/firefox-extension"

cp extension/install-browser-integration.sh "$EXTSTAGE/"
chmod +x "$EXTSTAGE/install-browser-integration.sh"

ditto -c -k --keepParent "$EXTSTAGE" "$EXTZIP"

echo "==> done"
for z in "$ZIP" "$EXTZIP"; do
  ls -lh "$z" | awk '{print "    "$5"  "$9}'
  echo "    sha256: $(shasum -a 256 "$z" | awk '{print $1}')"
done
echo
echo "Next: upload both to a GitHub Release, e.g."
echo "    gh release create v${VERSION} \"$ZIP\" \"$EXTZIP\" --title \"Keyway v${VERSION}\" --generate-notes"
