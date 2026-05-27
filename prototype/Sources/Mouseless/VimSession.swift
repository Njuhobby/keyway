import Cocoa

/// Owns the active interaction mode + an optional command-palette overlay.
///
/// `mode` describes what the user is actually doing:
///   .tap      — default. Hints visible, picking one performs a click.
///   (future)  — .selectText(...), .drag(...), etc.
///
/// `paletteBuffer` is independent: when non-nil, the command palette is
/// open and intercepts keystrokes. The underlying mode is *unchanged* —
/// closing the palette returns you to the same mode you were already in.
@MainActor
final class VimSession {
    enum Mode {
        case tap(HintMode)
        case scroll(ScrollController)
        // Future: case selectText(...), case drag(...), case rightClick(...)
    }

    private var mode: Mode? = nil
    private var paletteBuffer: String? = nil   // nil = palette closed
    private var sticky: Bool = false           // toggled by trigger key in TAP

    var isActive: Bool { mode != nil }

    // MARK: - Lifecycle

    /// Chord (Caps Lock + j/k) pressed → enter SCROLL mode. No hint
    /// scan — scroll is independent of hints. async to match enter()'s
    /// shape and because S3 will do an AX walk for scroll areas (off the
    /// event-tap hot path via the caller's Task).
    /// See `specs/scroll-mode-design.md`.
    func enterScroll() async {
        guard mode == nil else { return }
        let controller = ScrollController()
        controller.enter()   // S2: warp cursor to focused window center
        mode = .scroll(controller)
        paletteBuffer = nil
        sticky = false
        // S3: AX scroll-area detection. S4: numbered-area overlay.
        HUD.shared.show("SCROLL")
        print("[mouseless] enter SCROLL mode")
    }

    /// Trigger key pressed → enter TAP mode (hints visible).
    /// async because the OmniParser path (P5+) involves ScreenCaptureKit
    /// and CoreML inference, both inherently async. Caller (HotkeyTap)
    /// dispatches via Task — keyboard event handler stays sync.
    func enter() async {
        guard mode == nil else { return }
        // The cache survives in memory across Mouseless on/off cycles, but
        // it has no visibility into what the user did with the mouse while
        // Mouseless was off (clicks, scrolls, tab switches). Start every
        // session with an empty cache — first activate scans fresh, then
        // sticky rescans within the session can reuse.
        HintWindowCache.shared.clear()
        let h = HintMode()
        guard await h.activate() else {
            HUD.shared.show("no hints here")
            return
        }
        mode = .tap(h)
        paletteBuffer = nil
        sticky = false
        renderModeHUD()
        print("[mouseless] enter TAP mode")

        // P3 debug: log the routing decision (AX whitelist vs OP) for
        // the focused app.
        logFocusedAppRouting()

        // Diagnostic overlay (/tmp/mouseless-focused.png) is now written
        // inside OmniParserPath.collect() — only on OP-routed scans, and
        // includes the model's bounding boxes so you can see what was
        // detected vs filtered. AX-routed apps don't produce one (no OP
        // analysis to visualize). See OmniParserPath.saveDebugOverlay.
    }

    /// P3 debug: print whether the currently focused app would route
    /// to AX or OP for its focused-app subtree.
    private func logFocusedAppRouting() {
        // Frontmost app via NSWorkspace — AXFocusedApplication was flaky
        // on Electron apps (returned nil for VS Code). See FocusedApp.swift.
        guard let (_, pid) = FocusedApp.current() else {
            print("[mouseless] route: no frontmost app")
            return
        }
        guard let running = NSRunningApplication(processIdentifier: pid),
              let bundleID = running.bundleIdentifier
        else {
            print("[mouseless] route: frontmost app has no bundleID (pid=\(pid))")
            return
        }
        let useAX = AppRegistry.shouldUseAXForFocused(bundleID: bundleID)
        print("[mouseless] route: \(bundleID) -> \(useAX ? "AX walk (whitelist)" : "OmniParser (default)")")
    }

    func exit() {
        if case .tap(let h) = mode {
            h.deactivate()
        }
        if case .scroll(let controller) = mode {
            controller.stop()
            // S4: also hide the scroll-area overlay here.
        }
        mode = nil
        paletteBuffer = nil
        sticky = false
        HUD.shared.hide()
        print("[mouseless] exit")
    }

    // MARK: - Event entry point

    /// Returns `true` if the event was consumed.
    func handle(keyCode: Int, flags: CGEventFlags) -> Bool {
        guard let m = mode else { return false }

        // Cmd / Ctrl held → system shortcut. Pass through so things like
        // Cmd+Shift+4 (screenshot), Cmd+Space (Spotlight), Cmd+Tab, and
        // Ctrl+Up (Mission Control) still work while Mouseless is active.
        // Shift / Option are reserved for hint click-action modifiers
        // (Shift = double-click, Option = right-click), so they stay.
        if !flags.intersection([.maskCommand, .maskControl]).isEmpty {
            return false
        }

        // Palette open? It intercepts everything until closed.
        if let buffer = paletteBuffer {
            return handlePalette(buffer: buffer, keyCode: keyCode, flags: flags)
        }

        // Esc deactivates the active mode — back to OFF. The process
        // keeps running (M● in menu bar, Caps Lock still remapped). To
        // fully quit, use the menu bar Quit item (which reverts the
        // Caps Lock remap on its way out). See SPECS §2.1.
        if keyCode == KeyCode.escape {
            exit()
            return true
        }
        // Shift+; (= ":") — open the command palette over the current mode.
        if keyCode == KeyCode.semicolon && flags.contains(.maskShift) {
            paletteBuffer = ""
            HUD.shared.show(":")
            return true
        }

        // Otherwise dispatch to the active mode.
        return handleMode(mode: m, keyCode: keyCode, flags: flags)
    }

    private func handleMode(mode: Mode, keyCode: Int, flags: CGEventFlags) -> Bool {
        switch mode {
        case .tap(let hint):
            return handleTap(hint: hint, keyCode: keyCode, flags: flags)
        case .scroll(let controller):
            return handleScroll(controller: controller, keyCode: keyCode, flags: flags)
        }
    }

    // MARK: - SCROLL mode

    /// SCROLL mode keystrokes. (Esc is handled before handleMode → exits
    /// to OFF.) j/k drive the ScrollController (continuous on hold);
    /// Caps Lock switches to TAP. Number-key area switching lands in S4.
    private func handleScroll(controller: ScrollController, keyCode: Int, flags: CGEventFlags) -> Bool {
        let modMask: CGEventFlags = [.maskShift, .maskControl,
                                     .maskCommand, .maskAlternate]

        // Caps Lock (F19) → switch to TAP mode (scan + hints). Explicit
        // rescan; releasing j/k never auto-rescans (design §3.1).
        if keyCode == KeyCode.f19 && flags.intersection(modMask).isEmpty {
            controller.stop()
            mode = nil            // clear so enter() proceeds
            HUD.shared.hide()
            Task { @MainActor in await self.enter() }
            return true
        }

        // j / k → start continuous scroll down / up. Shift = fast.
        // Held-key OS repeats just refresh direction/speed (idempotent).
        if keyCode == KeyCode.j {
            controller.start(directionDown: true, fast: flags.contains(.maskShift))
            return true
        }
        if keyCode == KeyCode.k {
            controller.start(directionDown: false, fast: flags.contains(.maskShift))
            return true
        }

        // Scroll mode is modal — swallow everything else (number keys for
        // area switching wire up in S4). Esc already exited above.
        return true
    }

    /// Key release handler — routed from HotkeyTap. j/k release stops the
    /// continuous scroll. (The chord's own j/k keyUp also lands here and
    /// harmlessly stops a timer that was never started.)
    func handleKeyUp(keyCode: Int) -> Bool {
        guard case .scroll(let controller) = mode else { return false }
        if keyCode == KeyCode.j || keyCode == KeyCode.k {
            controller.stop()
            return true
        }
        return false
    }

    // MARK: - TAP mode

    private func handleTap(hint: HintMode, keyCode: Int, flags: CGEventFlags) -> Bool {
        // Bare trigger key (Caps Lock → F19) toggles sticky. While sticky
        // is on, each click re-scans hints instead of exiting.
        let modMask: CGEventFlags = [.maskShift, .maskControl,
                                     .maskCommand, .maskAlternate]
        if keyCode == KeyCode.f19 && flags.intersection(modMask).isEmpty {
            sticky.toggle()
            renderModeHUD()
            return true
        }

        // Bare `x` — "click on empty space" gesture. Two stages, both
        // event-driven (no fixed sleeps):
        //
        // 1. Activate Finder. App menu dropdowns / popovers / status
        //    menus all auto-dismiss when their owning app loses focus.
        //    Wait for `NSWorkspace.didActivateApplicationNotification`
        //    before proceeding so the next Esc lands on Finder, not on
        //    the previously focused app (vim/terminal/dialog).
        //
        // 2. Synth Esc. Dock right-click menus run in a modal tracking
        //    loop inside the Dock process and ignore focus changes —
        //    only a real outside-click or Esc dismisses them. If a
        //    Dock menu was open before we started, wait for the AX
        //    `kAXMenuClosedNotification` on that menu before rescanning,
        //    otherwise the AX tree still reports the menu items at
        //    stale positions (visual close and AX-tree update aren't
        //    synchronized).
        //
        // Both waits have a 300ms timeout fallback so silent AX/NSWS
        // failures don't deadlock the mode — that's defensive only,
        // should never trigger in normal operation.
        if keyCode == KeyCode.x && flags.intersection(modMask).isEmpty {
            hint.deactivate()

            // Capture the Dock context menu BEFORE dismissal — once
            // it's cancelled the AX element is gone from the tree.
            let dockPID = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            let openDockMenu = dockPID.flatMap { Self.findOpenDockMenu(pid: $0) }
            let finder = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.finder").first

            Task { @MainActor in
                // Stage 1a: dismiss the Dock context menu via the
                // AX-native cancel action. Empirically the only way
                // that actually works — synthetic Esc (any routing,
                // including CGEventPostToPid) only closes the menu
                // *visually* and leaves the AXMenu in Dock's tree,
                // so the re-scan picks up "ghost" menu items at the
                // old screen positions. `AXCancel` hits the same
                // cleanup path that a real mouse click outside the
                // menu does — Dock destroys the AXMenu element,
                // re-scan sees a clean tree.
                if let menu = openDockMenu {
                    AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                }

                // Stage 1b: focus switch — dismisses everything else
                // (app menu dropdowns, popovers, status menus all
                // auto-close when their owning app loses focus).
                if let finder = finder, !finder.isActive {
                    finder.activate(options: [])
                    _ = await AXWait.appActivated(
                        bundleID: "com.apple.finder", timeoutMs: 300
                    )
                }
                guard self.isActive else { return }

                // Stage 2: re-scan. No explicit AX-cleanup wait —
                // AXCancel is synchronous enough that the tree is
                // already clean by the time Finder activation
                // returns. If that ever stops being true, ghosts
                // would reappear and we'd add a wait back.
                let next = HintMode()
                if await next.activate() {
                    self.mode = .tap(next)
                    self.renderModeHUD()
                } else {
                    self.exit()
                }
            }
            return true
        }

        guard let ch = Self.hintChar(for: keyCode) else { return true }

        // Modifier on the final hint letter chooses the click action.
        // Shift → double-click, Option → right-click. Rationale: Shift
        // is the more comfortable / frequently-used modifier for Mac
        // users, and double-click (open file, select word, launch app)
        // is a more common action than right-click (context menu). So
        // the high-frequency action gets the easy modifier.
        let action: ClickAction
        if flags.contains(.maskShift) {
            action = .double
        } else if flags.contains(.maskAlternate) {
            action = .right
        } else {
            action = .left
        }

        switch hint.handle(char: ch, action: action) {
        case .pending:
            break
        case .committed:
            if sticky {
                // Re-scan and stay in TAP for the next click. activate()
                // is async (OmniParser path may run), so dispatch.
                hint.deactivate()
                Task { @MainActor in
                    let nextHint = HintMode()
                    if await nextHint.activate() {
                        self.mode = .tap(nextHint)
                        self.renderModeHUD()
                    } else {
                        self.exit()
                    }
                }
            } else {
                exit()
            }
        case .cancelled:
            exit()
        }
        return true
    }

    // MARK: - Palette overlay

    private func handlePalette(buffer: String, keyCode: Int, flags: CGEventFlags) -> Bool {
        // Trigger key (Caps Lock → F19) inside palette: close palette,
        // return to the underlying TAP mode. The mode itself never changed
        // — palette is an independent overlay. Same effect as Backspace
        // on an empty buffer; the two paths exist because Backspace is
        // already the natural "go back" key while editing the buffer.
        let modMask: CGEventFlags = [.maskShift, .maskControl,
                                     .maskCommand, .maskAlternate]
        if keyCode == KeyCode.f19 && flags.intersection(modMask).isEmpty {
            paletteBuffer = nil
            renderModeHUD()
            return true
        }

        switch keyCode {
        case KeyCode.escape:
            // Esc deactivates the active mode (back to OFF). The process
            // keeps running in the menu bar; Caps Lock remap stays in
            // effect. See `SPECS.md` §2.1 for the full state hierarchy.
            exit()
            return true

        case KeyCode.return:
            executeCommand(buffer)
            return true

        case KeyCode.delete:
            // Backspace. Empty buffer + backspace closes the palette and
            // restores the current mode's HUD (mode itself is unchanged).
            if buffer.isEmpty {
                paletteBuffer = nil
                renderModeHUD()
            } else {
                var b = buffer
                b.removeLast()
                paletteBuffer = b
                HUD.shared.show(":\(b)")
            }
            return true

        default:
            // Append a letter; ignore other keys.
            guard let ch = Self.letterChar(for: keyCode) else { return true }
            let next = buffer + String(ch)
            paletteBuffer = next
            HUD.shared.show(":\(next)")
            return true
        }
    }

    // MARK: - Command dispatch

    private func executeCommand(_ cmd: String) {
        switch cmd {
        // Future modes plug in here, e.g.:
        // case "st": switchTo(.selectText(...))
        // case "dr": switchTo(.drag(...))

        default:
            // Unknown command — clear the buffer, leave the palette open
            // so the user can type another command without reopening it.
            // There's deliberately no built-in `:q` command — Esc already
            // deactivates the mode, and quitting the Mouseless process is
            // a menu-bar action, not a hint-mode command (see SPECS §2.1).
            paletteBuffer = ""
            HUD.shared.show(":")
        }
    }

    // MARK: - HUD

    private func renderModeHUD(suffix: String = "") {
        guard let m = mode else { return }
        let label: String
        switch m {
        case .tap: label = sticky ? "TAP · sticky" : "TAP"
        case .scroll: label = "SCROLL"
        }
        HUD.shared.show(label + suffix)
    }

    // MARK: - Dock menu discovery

    /// If the Dock currently has an open context menu (right-click on
    /// an icon), return its `AXMenu` element. Used by the `x` handler
    /// to know whether to wait for `kAXMenuClosedNotification` after
    /// sending Esc — without the handle there's nothing to observe.
    /// Returns nil when no menu is open.
    ///
    /// Dock's AX tree puts context menus **under the specific
    /// `AXDockItem` that was right-clicked**, not at the app root:
    ///
    ///     AXApplication (Dock)
    ///       AXList
    ///         AXDockItem ...
    ///         AXDockItem (right-clicked)
    ///           AXMenu        ← here
    ///             AXMenuItem
    ///             ...
    ///
    /// So we walk app → AXList → AXDockItem and check each item's
    /// children for an AXMenu. Only one item has one at any time.
    private static func findOpenDockMenu(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let lists = childrenOf(app) else { return nil }
        for list in lists {
            guard roleOf(list) == "AXList",
                  let items = childrenOf(list) else { continue }
            for item in items {
                guard let candidates = childrenOf(item) else { continue }
                if let menu = candidates.first(where: { roleOf($0) == "AXMenu" }) {
                    return menu
                }
            }
        }
        return nil
    }

    private static func childrenOf(_ el: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXChildren" as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return nil }
        return arr
    }

    private static func roleOf(_ el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXRole" as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }



    // MARK: - Key code → character

    /// Used while a mode is active (no palette). Accepts homerow letters and
    /// digits — both are valid hint labels (letters for app/menu hints,
    /// digits for Dock hints).
    private static func hintChar(for keyCode: Int) -> Character? {
        switch keyCode {
        case KeyCode.a: return "a"
        case KeyCode.s: return "s"
        case KeyCode.d: return "d"
        case KeyCode.f: return "f"
        case KeyCode.g: return "g"
        case KeyCode.h: return "h"
        case KeyCode.j: return "j"
        case KeyCode.k: return "k"
        case KeyCode.l: return "l"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        default: return nil
        }
    }

    /// Used in the command palette — letters only.
    private static func letterChar(for keyCode: Int) -> Character? {
        switch keyCode {
        case KeyCode.a: return "a"
        case KeyCode.s: return "s"
        case KeyCode.d: return "d"
        case KeyCode.f: return "f"
        case KeyCode.g: return "g"
        case KeyCode.h: return "h"
        case KeyCode.j: return "j"
        case KeyCode.k: return "k"
        case KeyCode.l: return "l"
        case KeyCode.q: return "q"
        case KeyCode.w: return "w"
        case KeyCode.e: return "e"
        case KeyCode.r: return "r"
        case KeyCode.t: return "t"
        case KeyCode.y: return "y"
        case KeyCode.u: return "u"
        case KeyCode.i: return "i"
        case KeyCode.o: return "o"
        case KeyCode.p: return "p"
        case KeyCode.z: return "z"
        case KeyCode.x: return "x"
        case KeyCode.c: return "c"
        case KeyCode.v: return "v"
        case KeyCode.b: return "b"
        case KeyCode.n: return "n"
        case KeyCode.m: return "m"
        default: return nil
        }
    }
}
