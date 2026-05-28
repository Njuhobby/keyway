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
    private let mover = MouseMover()            // Ctrl+hjkl cursor move in TAP

    var isActive: Bool { mode != nil }

    // MARK: - Lifecycle

    /// F19 (Caps Lock) released with no chord → the trigger's default
    /// action for the current mode. Called from HotkeyTap once the arm
    /// resolves (see scroll-mode-design.md §2.1 — the F19 arm now spans
    /// ALL modes, not just OFF, so the chord can divert to SCROLL from
    /// anywhere and a bare tap does the right per-mode thing):
    ///   OFF    → enter TAP
    ///   TAP    → toggle sticky
    ///   SCROLL → switch to TAP
    func handleTriggerTap() {
        // Palette open → F19 closes it, back to the underlying mode
        // (preserves the pre-arm behavior now that F19 no longer reaches
        // handlePalette).
        if paletteBuffer != nil {
            paletteBuffer = nil
            renderModeHUD()
            return
        }
        switch mode {
        case .none:
            enter()
        case .tap:
            sticky.toggle()
            renderModeHUD()
        case .scroll:
            teardownCurrentMode()
            enter()
        }
    }

    /// Chord (Caps Lock + j/k) → enter SCROLL mode from ANY mode. No
    /// hint scan — scroll is independent of hints. Synchronous: the AX
    /// scroll-area walk runs inline (cheap, ~few ms). See
    /// `specs/scroll-mode-design.md`.
    func enterScroll() {
        teardownCurrentMode()   // no-op from OFF; tears down TAP/SCROLL
        let controller = ScrollController()
        controller.enter()      // detect scroll areas, warp, show overlay
        mode = .scroll(controller)
        paletteBuffer = nil
        sticky = false
        print("[mouseless] enter SCROLL mode")
    }

    /// Enter TAP mode (hints visible). **Sets `mode` synchronously** so a
    /// rapid second Caps Lock is recognized as an in-TAP sticky toggle
    /// rather than racing against an async activation (the old bug where
    /// double-tapping Caps Lock failed to reach sticky). The hint scan —
    /// which on the OmniParser path involves ScreenCaptureKit + CoreML —
    /// runs in a follow-up Task that just fills/redraws the overlay.
    func enter() {
        guard mode == nil else { return }
        HintWindowCache.shared.clear()
        let h = HintMode()
        mode = .tap(h)          // synchronous — no race window
        paletteBuffer = nil
        sticky = false
        print("[mouseless] enter TAP mode")
        logFocusedAppRouting()

        Task { @MainActor in
            // Guard against the mode changing out from under us during
            // the async scan (user hit Esc / chorded into SCROLL).
            guard case .tap(let cur) = self.mode, cur === h else { return }
            if await h.activate() {
                self.renderModeHUD()
            } else {
                HUD.shared.show("no hints here")
                self.exit()
            }
        }
    }

    /// Tear down whatever mode is active (stop mover/scroll, deactivate
    /// hints) and reset to OFF. Used when switching modes.
    private func teardownCurrentMode() {
        mover.stop()
        if case .tap(let h) = mode { h.deactivate() }
        if case .scroll(let c) = mode { c.teardown() }
        mode = nil
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
        mover.stop()
        if case .tap(let h) = mode {
            h.deactivate()
        }
        if case .scroll(let controller) = mode {
            controller.teardown()   // stop scrolling + hide area overlay
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

        // Bare i/j/k/l in TAP mode = move the cursor, IJKL inverted-T
        // (i up, j left, k down, l right — game-style WASD). Shift =
        // fast. Not Ctrl: power users (e.g. HHKB) often remap Ctrl+hjkl
        // to arrows at the system level, so Ctrl is unusable here. These
        // four keys are excluded from the hint-label pool (see
        // HintMode.alphabet) so a bare press is unambiguously "move".
        // Pairs with `x` (click at cursor): ijkl to aim, x to click.
        // Only Shift may accompany (for fast) — Cmd/Ctrl/Option fall
        // through to the system-shortcut passthrough below.
        if case .tap = m, paletteBuffer == nil,
           flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
           let dir = Self.moveDirection(for: keyCode) {
            mover.start(direction: dir, fast: flags.contains(.maskShift))
            return true
        }

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

    /// SCROLL mode keystrokes. (Esc exits to OFF; Caps Lock → TAP are
    /// both handled in HotkeyTap's F19 arm layer, not here.) j/k drive
    /// the ScrollController (continuous on hold); number keys switch
    /// the selected area.
    private func handleScroll(controller: ScrollController, keyCode: Int, flags: CGEventFlags) -> Bool {
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

        // Number keys 1-9 → switch the selected scroll area.
        if let digit = Self.digit(for: keyCode), digit >= 1 {
            controller.selectArea(number: digit)
            return true
        }

        // Scroll mode is modal — swallow everything else. Esc already
        // exited above.
        return true
    }

    /// Key release handler — routed from HotkeyTap. j/k release stops the
    /// continuous scroll. (The chord's own j/k keyUp also lands here and
    /// harmlessly stops a timer that was never started.)
    func handleKeyUp(keyCode: Int) -> Bool {
        if case .scroll(let controller) = mode {
            if keyCode == KeyCode.j || keyCode == KeyCode.k {
                controller.stop()
                return true
            }
            return false
        }
        if case .tap = mode {
            // i/j/k/l release stops cursor movement. These aren't hint
            // chars, so always consume their release while in TAP.
            if keyCode == KeyCode.i || keyCode == KeyCode.j
                || keyCode == KeyCode.k || keyCode == KeyCode.l {
                mover.stop()
                return true
            }
            return false
        }
        return false
    }

    private static func moveDirection(for keyCode: Int) -> MouseMover.Direction? {
        switch keyCode {
        case KeyCode.i: return .up
        case KeyCode.j: return .left
        case KeyCode.k: return .down
        case KeyCode.l: return .right
        default: return nil
        }
    }

    /// US-ANSI digit key codes → 0-9. nil for non-digit keys.
    private static func digit(for keyCode: Int) -> Int? {
        switch keyCode {
        case 29: return 0
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }

    // MARK: - TAP mode

    private func handleTap(hint: HintMode, keyCode: Int, flags: CGEventFlags) -> Bool {
        // (Caps Lock → sticky toggle is handled in HotkeyTap's F19 arm
        // layer — bare F19 release with no chord → handleTriggerTap →
        // sticky toggle. Not handled here.)
        let modMask: CGEventFlags = [.maskShift, .maskControl,
                                     .maskCommand, .maskAlternate]

        // Bare `x` — single left click at the current cursor position.
        // Combined with the future keyboard mouse-move feature this
        // becomes "move the cursor anywhere → x clicks there", which is
        // why x is defined as a plain click rather than a special
        // gesture.
        //
        // This replaced an older "dismiss all open menus + rescan"
        // gesture (AXCancel + focus switch). A plain click can mis-fire
        // if the cursor happens to sit on a control — accepted. And
        // until keyboard mouse-move ships, x lands wherever the cursor
        // already happens to be — an intentional interim state.
        //
        // After-click behavior mirrors a hint commit: sticky → rescan +
        // stay in TAP; otherwise → exit to OFF.
        if keyCode == KeyCode.x && flags.intersection(modMask).isEmpty {
            hint.deactivate()
            MouseSynth.click(at: MouseSynth.cursorPosition(), button: .left, count: 1)
            if sticky {
                Task { @MainActor in
                    let next = HintMode()
                    if await next.activate() {
                        self.mode = .tap(next)
                        self.renderModeHUD()
                    } else {
                        self.exit()
                    }
                }
            } else {
                exit()
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
        // i/j/k/l are IJKL cursor-move keys, not hint chars. e/r/u
        // backfill the pool (must match HintMode.alphabet).
        case KeyCode.e: return "e"
        case KeyCode.r: return "r"
        case KeyCode.u: return "u"
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
