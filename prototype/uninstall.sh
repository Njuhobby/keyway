#!/usr/bin/env bash
# Uninstall Keyway and remove everything it leaves on the system.
#
# Safe to run anytime (idempotent — missing items are skipped). It does NOT
# touch this source repo or the dev `.build/` dir; only the installed app and
# user-level artifacts.
set -u

APP="/Applications/Keyway.app"
BUNDLE_ID="com.keyway.app"

say() { printf '  %s\n' "$1"; }

echo "==> Quitting Keyway"
# Graceful first (lets the app revert the Caps Lock remap itself), then force.
osascript -e 'tell application "Keyway" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -9 -f "Keyway.app"     2>/dev/null && say "killed Keyway" || true
pkill -9 -f "keyway-bridge"  2>/dev/null && say "killed keyway-bridge" || true

echo "==> Restoring Caps Lock"
# Keyway remaps Caps Lock → F19 via hidutil and owns the UserKeyMapping
# property (it clears the whole thing on quit too). A force-quit leaves the
# remap in place until reboot, so clear it here to be safe.
hidutil property --set '{"UserKeyMapping":[]}' >/dev/null 2>&1 \
  && say "Caps Lock restored to normal" || say "hidutil clear skipped"

echo "==> Removing the app"
if [ -d "$APP" ]; then rm -rf "$APP" && say "removed $APP"; else say "no app at $APP"; fi

echo "==> Removing user-level files"
paths=(
  "$HOME/Library/Caches/Keyway"
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/Application Support/Keyway"
  "$HOME/Library/Preferences/Keyway.plist"
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
)
for p in "${paths[@]}"; do
  if [ -e "$p" ]; then rm -rf "$p" && say "removed $p"; fi
done
# Crash reports and diagnostic logs (glob — may be none).
rm -f "$HOME/Library/Application Support/CrashReporter/Keyway_"*.plist 2>/dev/null || true
rm -f "$HOME/Library/Logs/DiagnosticReports/Keyway-"*.ips 2>/dev/null || true

echo "==> Removing browser native-messaging hosts"
hosts=(
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.keyway.bridge.json"
  "$HOME/Library/Application Support/Mozilla/NativeMessagingHosts/com.keyway.bridge.json"
)
for h in "${hosts[@]}"; do
  if [ -e "$h" ]; then rm -f "$h" && say "removed $(basename "$h")"; fi
done

echo "==> Resetting permission grants (TCC)"
tccutil reset Accessibility "$BUNDLE_ID"  >/dev/null 2>&1 && say "reset Accessibility" || true
tccutil reset ScreenCapture "$BUNDLE_ID"  >/dev/null 2>&1 && say "reset Screen Recording" || true

echo
echo "Done. Keyway is fully uninstalled."
echo "Note: the unpacked browser extension (if loaded) must be removed in your"
echo "browser — chrome://extensions or about:debugging."
