import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var tap: HotkeyTap?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        if ensureAccessibility() {
            // Caps Lock → F19 remap. The OS doesn't surface Caps Lock as
            // a normal keyDown (it's a modifier), so we rewrite it to F19
            // at the HID layer via hidutil. See TriggerRemap.swift.
            TriggerRemap.applyAtLaunch()
            startTap()
            // Warm the menu-extras PID cache in the background. The
            // scan takes ~500ms; doing it now (well before the user's
            // first trigger key press) keeps every subsequent TAP
            // collect pass essentially free.
            MenuExtraCache.shared.warmUp()

            // Pre-load the OmniParser CoreML model in the background.
            // ~1-1.5s cold load; doing it at launch (invisible — user
            // is presumably busy after pressing Login) makes the first
            // Caps Lock on an AX-bad app feel as snappy as subsequent
            // ones. See `OmniParserModel.preload`.
            OmniParserModel.preload()

            if OmniParserPath.debugOverlayEnabled {
                print("[mouseless] DEBUG overlay enabled (MOUSELESS_DEBUG_OVERLAY=1) — /tmp/mouseless-focused.png written on every OP scan, +30-80ms background")
            }
        } else {
            statusItem.button?.title = "M⚠"
            print("[mouseless] Accessibility not granted.")
            print("           1. Open System Settings → Privacy & Security → Accessibility")
            print("           2. Enable 'Mouseless' (or the swift binary path)")
            print("           3. Fully quit this process and rerun `swift run`")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore normal Caps Lock behavior on graceful quit. Force-quit
        // and crashes leave the remap in place until next reboot or next
        // Mouseless launch (which reapplies — idempotent).
        TriggerRemap.revertAtQuit()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "M"

        let menu = NSMenu()
        let header = NSMenuItem(title: "Mouseless prototype · Caps Lock to enter vim", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let recheck = NSMenuItem(title: "Re-check accessibility", action: #selector(recheckAccessibility), keyEquivalent: "r")
        recheck.target = self
        menu.addItem(recheck)

        let quit = NSMenuItem(title: "Quit Mouseless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @discardableResult
    private func ensureAccessibility() -> Bool {
        // The constant `kAXTrustedCheckOptionPrompt` is a non-Sendable global, so under
        // Swift 6 strict concurrency we use the literal string value directly. It's a
        // stable Apple API constant (defined in <HIServices/AXUIElement.h>).
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func startTap() {
        let session = VimSession()
        let newTap = HotkeyTap(session: session)
        if newTap.start() {
            tap = newTap
            statusItem.button?.title = "M●"
            print("[mouseless] running. Press Caps Lock to enter vim mode.")
        } else {
            statusItem.button?.title = "M⚠"
        }
    }

    @objc private func recheckAccessibility() {
        guard tap == nil else { return }
        if ensureAccessibility() {
            startTap()
        }
    }
}
