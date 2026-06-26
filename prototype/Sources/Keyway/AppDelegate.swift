import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var tap: HotkeyTap?
    private var session: VimSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        // Two HARD requirements: Accessibility (the event tap + synthesized
        // clicks/keys) and Screen Recording (the OmniParser fallback + the
        // content-settle watch). These are NON-prompting status checks — the
        // onboarding window drives the actual TCC prompts and the relaunch.
        // Blind launch-time prompts were the confusing two-round dance (grant
        // one, still red, quit, reopen, get the second prompt) we're removing.
        guard OnboardingController.accessibilityGranted,
              OnboardingController.screenRecordingGranted else {
            setWarningBadge(true)
            OnboardingController.shared.onReady = { [weak self] in self?.start() }
            OnboardingController.shared.present()
            return
        }
        start()
    }

    /// Apply the trigger remap, start the event tap, and bring up the
    /// background services. Runs once both permissions are satisfied — at
    /// launch, or after the onboarding "Restart Keyway".
    private func start() {
        OnboardingController.shared.dismiss()
        do {
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
                Log.debug("[keyway] DEBUG overlay enabled (KEYWAY_DEBUG_OVERLAY=1) — /tmp/keyway-focused.png written on every OP scan, +30-80ms background")
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
                // real web page (no Keyway mode). Post a real wheel event
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
                    "from": "keyway-main"
                ])
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore normal Caps Lock behavior on graceful quit. Force-quit
        // and crashes leave the remap in place until next reboot or next
        // Keyway launch (which reapplies — idempotent).
        TriggerRemap.revertAtQuit()
        BridgeServer.shared.stop()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.statusImage()
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        let header = NSMenuItem(title: "Keyway prototype · Caps Lock to enter vim", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let recheck = NSMenuItem(title: "Re-check permissions", action: #selector(recheckPermissions), keyEquivalent: "r")
        recheck.target = self
        menu.addItem(recheck)

        let quit = NSMenuItem(title: "Quit Keyway", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Append (or clear) a red warning badge beside the brand icon. Used
    /// when a hard requirement is missing — permissions or the event tap.
    private func setWarningBadge(_ on: Bool) {
        guard let button = statusItem.button else { return }
        if on {
            button.attributedTitle = NSAttributedString(
                string: " !",
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.systemFont(ofSize: 11, weight: .bold)])
        } else {
            button.title = ""
        }
    }

    private func startTap() {
        let newSession = VimSession()
        let newTap = HotkeyTap(session: newSession)
        if newTap.start() {
            session = newSession
            tap = newTap
            setWarningBadge(false)
            Log.info("[keyway] running. Press Caps Lock to enter vim mode.")
        } else {
            setWarningBadge(true)
        }
    }

    @objc private func recheckPermissions() {
        guard tap == nil else { return }
        // Accessibility flips live; Screen Recording is cached per process and
        // needs a relaunch. If both already read granted, start for real;
        // otherwise (re)open the onboarding window to guide + offer Restart.
        if OnboardingController.accessibilityGranted && OnboardingController.screenRecordingGranted {
            start()
        } else {
            OnboardingController.shared.present()
        }
    }
}
