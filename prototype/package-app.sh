#!/usr/bin/env bash
# Package Keyway into a distributable .app bundle with the proper icon.
# Produces build/Keyway.app. For the dev inner loop use run.sh instead.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"               # release | debug
VERSION="${KEYWAY_VERSION:-0.1.0}"   # CI injects this from the git tag
BUILD="${KEYWAY_BUILD:-1}"
APP="build/Keyway.app"
ICNS="branding/Keyway.icns"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BINDIR=".build/$CONFIG"
BIN="$BINDIR/Keyway"
RESBUNDLE="$BINDIR/Keyway_Keyway.bundle"   # SwiftPM-copied resources (CoreML model)

[ -f "$BIN" ]    || { echo "missing binary: $BIN"; exit 1; }
[ -f "$ICNS" ]   || { echo "missing icon: $ICNS (run branding/gen_icon.py + iconutil)"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Keyway"
cp "$ICNS" "$APP/Contents/Resources/Keyway.icns"
# The CoreML resource bundle goes in Contents/Resources so codesign seals it
# cleanly. OmniParserModel.locateModelPackage() finds it there via
# Bundle.main.resourceURL (we deliberately avoid SwiftPM's Bundle.module — its
# executableTarget accessor resolves to the .app root, which breaks signing).
[ -d "$RESBUNDLE" ] && cp -R "$RESBUNDLE" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Keyway</string>
    <key>CFBundleDisplayName</key>     <string>Keyway</string>
    <key>CFBundleExecutable</key>      <string>Keyway</string>
    <key>CFBundleIdentifier</key>      <string>com.keyway.app</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$BUILD</string>
    <key>CFBundleIconFile</key>        <string>Keyway</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key> <string>Keyway — AGPL-3.0</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign (TCC requires a stable signature)"
codesign --force --deep --sign - "$APP"

echo "==> done: $APP"
