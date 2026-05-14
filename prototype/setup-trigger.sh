#!/usr/bin/env bash
# Remap the physical Caps Lock key → F19 so Mouseless can use it as the
# trigger key. F19 is unused by any standard macOS app, so it works as
# a collision-free dedicated key for us.
#
# Two modes:
#   ./setup-trigger.sh             one-shot remap, lasts until reboot
#   ./setup-trigger.sh --persist   install LaunchAgent that re-applies on login
#
# The remap is done via Apple's `hidutil` (no kexts, no root, no third-
# party drivers). Caps Lock's LED stops responding once remapped — that's
# expected; the key is no longer "Caps Lock" from the OS's perspective.
#
# Pair this with macOS System Settings → Keyboard → Modifier Keys →
# "Caps Lock key: No Action" if you want to be extra safe (belt and
# suspenders; the hidutil remap alone is sufficient).

set -euo pipefail

# HID usage codes (USB HID Keyboard/Keypad Page 0x07):
#   Caps Lock = 0x39  →  full usage = 0x700000039
#   F19       = 0x6E  →  full usage = 0x70000006E
REMAP_JSON='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006E}]}'

apply_now() {
    hidutil property --set "$REMAP_JSON" > /dev/null
    echo "✓ Caps Lock → F19 remap applied to current session."
    echo
    echo "Test it: open Mouseless (M● in menu bar), press Caps Lock."
    echo "Hint mode should activate when you press Caps Lock."
}

install_launch_agent() {
    local plist="$HOME/Library/LaunchAgents/com.mouseless.trigger-remap.plist"
    mkdir -p "$(dirname "$plist")"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mouseless.trigger-remap</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/hidutil</string>
        <string>property</string>
        <string>--set</string>
        <string>${REMAP_JSON}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist"
    echo "✓ LaunchAgent installed at: $plist"
    echo "  Remap will re-apply on every login."
    echo
    echo "To remove: launchctl unload \"$plist\" && rm \"$plist\""
}

case "${1:-}" in
    --persist)
        apply_now
        install_launch_agent
        ;;
    "")
        apply_now
        echo
        echo "Note: this remap is lost on reboot. Run with --persist to install"
        echo "a LaunchAgent that re-applies on every login."
        ;;
    *)
        echo "usage: $0 [--persist]" >&2
        exit 1
        ;;
esac
