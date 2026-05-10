import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var tap: HotkeyTap?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        if ensureAccessibility() {
            startTap()
        } else {
            statusItem.button?.title = "M⚠"
            print("[mouseless] Accessibility not granted.")
            print("           1. Open System Settings → Privacy & Security → Accessibility")
            print("           2. Enable 'Mouseless' (or the swift binary path)")
            print("           3. Fully quit this process and rerun `swift run`")
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "M"

        let menu = NSMenu()
        let header = NSMenuItem(title: "Mouseless prototype · ⌃; to enter vim", action: nil, keyEquivalent: "")
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
            print("[mouseless] running. Press ⌃; to enter vim mode.")
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
