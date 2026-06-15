import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var tap: HotkeyTap?
    private var session: VimSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        // Both are HARD requirements (prompt both so neither short-
        // circuits the other). Accessibility: the event tap. Screen
        // Recording: the OmniParser fallback AND the content-settle watch
        // (low-res fingerprints) both capture the screen — without it
        // OP-routed apps get no hints and rehints fall back to blind
        // delays, so we gate startup on it rather than lazily prompting.
        let axOK = ensureAccessibility()
        let screenOK = ensureScreenRecording()
        if axOK && screenOK {
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

            // Browser-extension bridge. Incoming messages:
            //   - cmd:"ping"           → reply with pong (sanity check)
            //   - cmd:"keepalive"      → no reply (silent ack, just keeps
            //                            the SW + port alive)
            //   - type:"hints"         → consumed by BridgeServer's
            //                            awaitResponse path before this
            //                            handler sees it (BrowserProvider)
            //   - type:"page_changed"  → extension's MutationObserver
            //                            detected new clickable
            //                            element(s) appeared (async
            //                            load, SPA re-render).
            //   - type:"tab_changed"   → user switched active tab
            //                            within the focused Chrome
            //                            window (Cmd+1/2/3, click on
            //                            tab strip, browser back/
            //                            forward). Same UX response
            //                            as page_changed — refresh
            //                            the hint overlay to point
            //                            at the new tab's elements.
            // Active browser bridge dropped → stop any in-flight page scroll
            // (the content script's "stop" can no longer reach us).
            BridgeServer.shared.onActiveClientDisconnect = { [weak self] in
                Task { @MainActor in self?.session?.stopPageScroll() }
            }
            BridgeServer.shared.start { [weak self] msg, reply in
                let cmd = msg["cmd"] as? String
                let type = msg["type"] as? String
                if cmd == "keepalive" { return }
                if type == "page_changed" || type == "tab_changed" {
                    Task { @MainActor in
                        self?.session?.handlePageChanged()
                    }
                    return
                }
                // type:"scroll_gate" → extension reports whether the
                // focused tab has a live content script handling d/u/gg/G
                // scrolling itself. Gates Caps Lock+d (suppress → SCROLL
                // on real web pages; keep it on chrome:// / Web Store).
                if type == "scroll_gate" {
                    let live = (msg["live"] as? Bool) ?? false
                    let browser = (msg["browser"] as? String) ?? ""
                    Task { @MainActor in
                        self?.session?.setBrowserScrollGate(live: live, browser: browser)
                    }
                    return
                }
                // type:"page_scroll" → content script detected d/u/gg/G on a
                // real web page (no Mouseless mode). Post a real wheel event
                // at the cursor. Only start/stop/jump arrive, not per-frame.
                if type == "page_scroll" {
                    let action = (msg["action"] as? String) ?? ""
                    let dir = msg["dir"] as? String
                    let fast = (msg["fast"] as? Bool) ?? false
                    let to = msg["to"] as? String
                    Task { @MainActor in
                        self?.session?.handlePageScroll(action: action, dir: dir, fast: fast, to: to)
                    }
                    return
                }
                reply([
                    "type": "pong",
                    "echo": msg,
                    "from": "mouseless-main"
                ])
            }
        } else {
            statusItem.button?.title = "M⚠"
            print("[mouseless] Required permissions not granted:")
            if !axOK {
                print("  • Accessibility — System Settings → Privacy & Security → Accessibility")
            }
            if !screenOK {
                print("  • Screen Recording — System Settings → Privacy & Security → Screen Recording")
            }
            print("  Enable 'Mouseless' (or the swift binary path) for the above,")
            print("  then fully quit this process and rerun `swift run`.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore normal Caps Lock behavior on graceful quit. Force-quit
        // and crashes leave the remap in place until next reboot or next
        // Mouseless launch (which reapplies — idempotent).
        TriggerRemap.revertAtQuit()
        BridgeServer.shared.stop()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "M"

        let menu = NSMenu()
        let header = NSMenuItem(title: "Mouseless prototype · Caps Lock to enter vim", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let recheck = NSMenuItem(title: "Re-check permissions", action: #selector(recheckPermissions), keyEquivalent: "r")
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

    @discardableResult
    private func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Not granted — fire the system TCC prompt. The grant only takes
        // effect after a restart (macOS caches screen-recording status per
        // process), so this launch still returns false; the user enables
        // it, quits, and reruns — same flow as Accessibility.
        CGRequestScreenCaptureAccess()
        return false
    }

    private func startTap() {
        let newSession = VimSession()
        let newTap = HotkeyTap(session: newSession)
        if newTap.start() {
            session = newSession
            tap = newTap
            statusItem.button?.title = "M●"
            print("[mouseless] running. Press Caps Lock to enter vim mode.")
        } else {
            statusItem.button?.title = "M⚠"
        }
    }

    @objc private func recheckPermissions() {
        guard tap == nil else { return }
        // Accessibility can flip live; Screen Recording is cached per
        // process, so granting it needs a restart (see ensureScreenRecording).
        // This re-check mainly recovers the Accessibility-only case.
        if ensureAccessibility() && ensureScreenRecording() {
            startTap()
        }
    }
}
