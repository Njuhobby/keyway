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
        case drag(DragController)
        case window(WindowController)
        case windowMove(WindowMoveController)
        // Future: case selectText(...), case rightClick(...)
    }

    private var mode: Mode? = nil
    private var paletteBuffer: String? = nil   // nil = palette closed
    private var sticky: Bool = false           // toggled by trigger key in TAP
    private let mover = MouseMover()            // hjkl cursor move (TAP + SCROLL)
    private var rehintGeneration = 0           // supersede in-flight re-hints
    private var pendingStickyRehint: DispatchWorkItem?  // post-commit delayed re-hint
    private var scrollPendingG = false         // first 'g' of a gg (SCROLL)

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
        // Drag holds a synthesized mouseDown — let it complete via
        // Enter/Esc/Backspace before any mode switch. Caps Lock is
        // swallowed. Same for WINDOW (resize in progress shouldn't be
        // interrupted by an accidental Caps Lock tap).
        if case .drag = mode { return }
        if case .window = mode { return }
        if case .windowMove = mode { return }
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
        case .drag, .window, .windowMove:
            break   // unreachable — guarded above
        }
    }

    /// Chord (Caps Lock + d) → enter SCROLL mode from ANY mode. No
    /// hint scan — scroll is independent of hints. Synchronous: the AX
    /// scroll-area walk runs inline (cheap, ~few ms). See
    /// `specs/scroll-mode-design.md`.
    func enterScroll() {
        // Same reason as handleTriggerTap: don't divert mid-drag — Caps
        // Lock + d chord is swallowed until the drag completes. Same
        // for WINDOW / windowMove.
        if case .drag = mode { return }
        if case .window = mode { return }
        if case .windowMove = mode { return }
        teardownCurrentMode()   // no-op from OFF; tears down TAP/SCROLL
        let controller = ScrollController()
        controller.enter()      // detect scroll areas, warp, show overlay
        mode = .scroll(controller)
        paletteBuffer = nil
        sticky = false
        renderModeHUD()   // show "SCROLL" (was stuck on "TAP" when chorded from TAP)
        print("[mouseless] enter SCROLL mode")
    }

    /// Enter `.window` mode. Triggered by Caps Lock + w chord (HotkeyTap)
    /// from any mode. Two gates must both pass — if either fails we
    /// show a brief HUD note and stay in the current mode:
    ///
    ///   1. **Has a real title bar** (`hasTitleBarButton`): at least one
    ///      of `AXCloseButton` / `AXMinimizeButton` / `AXZoomButton` /
    ///      `AXFullScreenButton`. Rejects the Finder Desktop (which is
    ///      a Finder AX "window" with no chrome — not user-resizable)
    ///      and macOS-fullscreen windows (chrome hidden, also
    ///      unresizable). Robust against AX-poor apps: their outer
    ///      NSWindow chrome is native so the button query works even
    ///      when the inner content's AX is broken.
    ///   2. **AX position+size writable** (`isResizable`): both attrs
    ///      settable via `AXUIElementIsAttributeSettable`. Resize works
    ///      by writing them each tick; if either isn't writable the
    ///      mode is useless, so we refuse rather than silently no-op.
    ///
    /// (Earlier prototype kept a synth-mouse-edge-drag fallback for the
    /// !isResizable case; with the title-bar-button gate handling the
    /// Desktop and macOS-fullscreen cases, real apps that pass the gate
    /// almost always allow AX writes — the fallback's complexity wasn't
    /// earning its keep, so it's gone.)
    func enterWindowMode() {
        if case .drag = mode { return }       // drag mid-flight wins
        if case .window = mode { return }     // already in WINDOW
        if case .windowMove = mode { return } // exit MOVE first
        guard let window = AXWindowOps.frontmostWindow(),
              let rect = AXWindowOps.readRect(window)
        else {
            HUD.shared.show("WINDOW: no frontmost window")
            return
        }
        guard AXWindowOps.hasTitleBarButton(window) else {
            HUD.shared.show("WINDOW: no resizable window")
            print("[mouseless] WINDOW: no title-bar buttons on frontmost window (Desktop / fullscreen / borderless) — refused")
            return
        }
        guard AXWindowOps.isResizable(window) else {
            HUD.shared.show("WINDOW: can't resize this window")
            print("[mouseless] WINDOW: AXPosition/AXSize not writable on this window — refused")
            return
        }
        teardownCurrentMode()   // drop overlays / stop mover from prior mode
        let controller = WindowController(window: window, initialRect: rect)
        WindowOpOverlay.shared.show(rect: rect)
        controller.onRectUpdate = { newRect in
            WindowOpOverlay.shared.update(rect: newRect)
        }
        mode = .window(controller)
        paletteBuffer = nil
        sticky = false
        renderModeHUD()
        print("[mouseless] enter WINDOW mode at \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))")
    }

    /// Enter `.windowMove` mode. Caps Lock + m chord (HotkeyTap). Same
    /// two-gate logic as WINDOW resize but with `isMovable` (just
    /// `AXPosition` settable — looser than `isResizable` which also
    /// requires `AXSize` settable). Overlay is the same blue border
    /// but **without** the edge chips: hjkl here means "move the
    /// window in that direction", not "pull that border", so
    /// border-anchored chips would mislead.
    func enterWindowMove() {
        if case .drag = mode { return }
        if case .window = mode { return }
        if case .windowMove = mode { return }
        guard let window = AXWindowOps.frontmostWindow(),
              let rect = AXWindowOps.readRect(window)
        else {
            HUD.shared.show("MOVE: no frontmost window")
            return
        }
        guard AXWindowOps.hasTitleBarButton(window) else {
            HUD.shared.show("MOVE: no movable window")
            print("[mouseless] MOVE: no title-bar buttons on frontmost window — refused")
            return
        }
        guard AXWindowOps.isMovable(window) else {
            HUD.shared.show("MOVE: can't move this window")
            print("[mouseless] MOVE: AXPosition not writable — refused")
            return
        }
        teardownCurrentMode()
        let controller = WindowMoveController(window: window, initialRect: rect)
        WindowOpOverlay.shared.show(rect: rect, withChips: false)
        controller.onRectUpdate = { newRect in
            WindowOpOverlay.shared.update(rect: newRect)
        }
        mode = .windowMove(controller)
        paletteBuffer = nil
        sticky = false
        renderModeHUD()
        print("[mouseless] enter MOVE mode at \(Int(rect.minX)),\(Int(rect.minY))")
    }

    /// Enter `.drag` mode: synthesize `leftMouseDown` at the current
    /// cursor and switch state. Triggered by bare `v` from TAP or SCROLL
    /// (the "universal" drag UX — the source is wherever you've already
    /// hjkl'd the cursor to, no hint pre-selection). The held mouseDown
    /// is released by Enter (commit), Esc (drop at current + exit), or
    /// Backspace (warp back + release at source — true cancel).
    ///
    /// The pre-drag mode is captured into the controller so Backspace
    /// can restore it (sticky TAP stays sticky, SCROLL re-detects areas),
    /// and Enter knows whether to re-hint or exit on completion.
    /// See `modes.md` §6.
    func enterDrag() {
        let pre: DragController.PreMode
        switch mode {
        case .tap: pre = .tap(sticky: sticky)
        case .scroll: pre = .scroll
        case .drag, .window, .windowMove, .none: return   // already busy / not in a mode
        }
        let cursor = MouseSynth.cursorPosition()
        MouseSynth.dragDown(at: cursor)
        teardownCurrentMode()   // hides prior overlay; sets mode = nil
        let controller = DragController(startPoint: cursor, preMode: pre)
        mode = .drag(controller)
        paletteBuffer = nil
        sticky = false   // sticky is captured in preMode; .drag has no sticky of its own
        renderModeHUD()
        print("[mouseless] enter DRAG mode at \(Int(cursor.x)),\(Int(cursor.y))")
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
        startAppSwitchFollow()   // acts only while sticky (gated in callback)

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
        stopAppSwitchFollow()
        pendingStickyRehint?.cancel()
        pendingStickyRehint = nil
        scrollPendingG = false
        if case .tap(let h) = mode { h.deactivate() }
        if case .scroll(let c) = mode { c.teardown() }
        // Drag has a held mouseDown — release it before tearing down so
        // we never leave the system in a stuck-button state. Defensive:
        // the normal completion paths (Enter/Esc/Backspace) release
        // explicitly; this catches any path that forgets to.
        if case .drag = mode { MouseSynth.dragUp(at: MouseSynth.cursorPosition()) }
        if case .window(let c) = mode {
            c.teardown()                // stops the resize timer
            WindowOpOverlay.shared.hide()
        }
        if case .windowMove(let c) = mode {
            c.teardown()                // stops the move timer
            WindowOpOverlay.shared.hide()
        }
        mode = nil
    }

    // MARK: - Sticky re-hint (+ async-focus recheck)

    /// Re-scan + redraw hints, staying in TAP (the sticky path after a
    /// commit/x). Generation-guarded: a later re-hint (e.g. the focus-
    /// recheck poller firing) bumps the generation so an earlier in-
    /// flight scan, when it finishes, sees it's been superseded and bows
    /// out instead of racing to overwrite `mode`.
    private func rehintSticky(isolateApp: Bool = false) {
        rehintGeneration += 1
        let gen = rehintGeneration
        if case .tap(let h) = mode { h.deactivate() }
        Task { @MainActor in
            let next = HintMode()
            let ok = await next.activate(isolateApp: isolateApp)
            guard gen == self.rehintGeneration else { return }  // superseded
            if ok {
                self.mode = .tap(next)
                self.renderModeHUD()
            } else {
                self.exit()
            }
        }
    }

    /// Re-hint after a sticky commit on the **same window**, delayed
    /// ~100ms. The synthesized click is async, so re-hinting now would
    /// scan/screenshot the pre-click frame (stale). The delay lets the
    /// click land and the content re-render settle first — enough for any
    /// reasonable app (a re-render that can't finish in 100ms is the app
    /// being sluggish), short enough to feel immediate. Tradeoff: an
    /// update that lands >100ms later re-hints stale; re-trigger to
    /// refresh. A second commit during the wait cancels the pending item
    /// (latest click wins); exiting / switching mode cancels it too.
    ///
    /// This is the **focused-window-unchanged** path. App switches don't
    /// come here — they re-hint immediately with an app-isolated capture
    /// (see `startAppSwitchFollow`), because the delay's purpose
    /// (click-content settle) doesn't apply and the isolated capture
    /// already handles the switcher HUD.
    private func scheduleStickyRehint() {
        pendingStickyRehint?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.sticky else { return }
            self.rehintSticky()
        }
        pendingStickyRehint = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    // MARK: - App-switch follow (sticky only)

    /// While in **sticky** TAP, follow app switches: a Cmd+Tab (or any
    /// click that activates another app) makes the current hint overlay
    /// stale — it's drawn for the old app at the old coordinates. Re-hint
    /// the newly-frontmost app so sticky hints follow focus instead of
    /// leaving a frozen overlay.
    ///
    /// App activation is a clean per-switch signal reliable for **all**
    /// apps (NSWorkspace, AX-independent), so this observer runs the whole
    /// TAP session — distinct from the post-commit delayed re-hint, which
    /// only handles same-app changes from our own click. The callback
    /// gates on `sticky`, so non-sticky TAP (one-shot, no point following)
    /// is unaffected. Started in `enter()`, stopped in `exit()` /
    /// `teardownCurrentMode()`.
    private var appSwitchToken: NSObjectProtocol?

    private func startAppSwitchFollow() {
        guard appSwitchToken == nil else { return }
        appSwitchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .tap = self.mode, self.sticky else { return }
                print("[mouseless] app switch in sticky TAP → re-hint new app")
                // Immediate (no delay): the activation already means the
                // new app is frontmost, and the isolated capture drops the
                // Cmd+Tab switcher HUD regardless of whether it's still
                // fading — so there's nothing to wait for. Cancel any
                // pending same-window re-hint (this switch supersedes it).
                self.pendingStickyRehint?.cancel()
                self.pendingStickyRehint = nil
                self.rehintSticky(isolateApp: true)
            }
        }
    }

    private func stopAppSwitchFollow() {
        if let token = appSwitchToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            appSwitchToken = nil
        }
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
        stopAppSwitchFollow()
        pendingStickyRehint?.cancel()
        pendingStickyRehint = nil
        scrollPendingG = false
        if case .tap(let h) = mode {
            h.deactivate()
        }
        if case .scroll(let controller) = mode {
            controller.teardown()   // stop scrolling + hide area overlay
        }
        // Drag: Esc semantic per design — release the held mouseDown at
        // wherever the cursor currently is, then exit to OFF. The drop
        // is unavoidable (we can't leave the button stuck); the cursor
        // stays put (per user spec: "cursor 在哪就在哪，不动").
        if case .drag = mode {
            MouseSynth.dragUp(at: MouseSynth.cursorPosition())
        }
        if case .window(let c) = mode {
            c.teardown()
            WindowOpOverlay.shared.hide()
        }
        if case .windowMove(let c) = mode {
            c.teardown()
            WindowOpOverlay.shared.hide()
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

        // Bare h/j/k/l in TAP or DRAG = move the cursor, vim hjkl (h
        // left, j down, k up, l right). Same move keys as SCROLL —
        // unified so the user doesn't switch mental models between modes.
        // These four are excluded from the hint-label pool (see
        // HintMode.alphabet) so a bare press is unambiguously "move".
        // Pairs with Enter (click/drop at cursor): hjkl to aim, Enter to
        // commit. Shift = fast, Option = slow; Cmd/Ctrl fall through to
        // the system-shortcut passthrough below.
        //
        // In DRAG mode the held mouseDown means each step needs to be
        // posted as `.leftMouseDragged` (not `.mouseMoved`) so the target
        // app sees the drag — MouseMover.start's `dragHeld` flag switches
        // the event type. SCROLL has its own hjkl handler inside
        // handleScroll (gg-pending interaction), not here.
        let allowsMoveHere: Bool
        let dragHeld: Bool
        switch m {
        case .tap:    allowsMoveHere = true;  dragHeld = false
        case .drag:   allowsMoveHere = true;  dragHeld = true
        case .scroll: allowsMoveHere = false; dragHeld = false
        case .window: allowsMoveHere = false; dragHeld = false   // hjkl resizes, handled in handleWindow
        case .windowMove: allowsMoveHere = false; dragHeld = false   // hjkl translates, handled in handleWindowMove
        }
        if allowsMoveHere, paletteBuffer == nil,
           flags.intersection([.maskCommand, .maskControl]).isEmpty,
           let dir = Self.moveDirection(for: keyCode) {
            // Option allowed through (unlike Cmd/Ctrl) because hjkl aren't
            // hint letters, so Option+hjkl can't collide with the Option =
            // right-click hint modifier.
            mover.start(direction: dir, speed: Self.moveSpeed(from: flags), dragHeld: dragHeld)
            return true
        }

        // Bare `v` from TAP or SCROLL → enter DRAG mode (vim-visual
        // analog). `v` isn't a hint letter (not in HintMode.alphabet),
        // not used by SCROLL, not used by palette — so a bare press is
        // unambiguous. `v` from DRAG is ignored (already dragging).
        let isTapOrScroll: Bool = { switch m { case .tap, .scroll: return true; case .drag, .window, .windowMove: return false } }()
        let modMaskV: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
        if isTapOrScroll, keyCode == KeyCode.v, paletteBuffer == nil,
           flags.intersection(modMaskV).isEmpty {
            enterDrag()
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
        case .drag(let controller):
            return handleDrag(controller: controller, keyCode: keyCode, flags: flags)
        case .window(let controller):
            return handleWindow(controller: controller, keyCode: keyCode, flags: flags)
        case .windowMove(let controller):
            return handleWindowMove(controller: controller, keyCode: keyCode, flags: flags)
        }
    }

    // MARK: - windowMove (WINDOW translate)

    /// `.windowMove` keystrokes. hjkl start a direction (controller
    /// adds to its active set + ensures the 60fps timer). Shift is
    /// sampled live each tick (fast vs normal speed), no need to
    /// thread the modifier. Esc handled in `handle()`. Other keys
    /// swallowed.
    private func handleWindowMove(controller: WindowMoveController, keyCode: Int, flags: CGEventFlags) -> Bool {
        if let dir = Self.windowMoveDirection(for: keyCode) {
            controller.startDirection(dir)
            return true
        }
        return true
    }

    /// h/j/k/l → which direction the window moves. Same encoding as
    /// MouseMover (cursor) / SCROLL / WINDOW resize (where j means
    /// "bottom border" which moves "down") — consistent vim layout
    /// across all of Mouseless.
    private static func windowMoveDirection(for keyCode: Int) -> WindowMoveController.Direction? {
        switch keyCode {
        case KeyCode.h: return .left
        case KeyCode.j: return .down
        case KeyCode.k: return .up
        case KeyCode.l: return .right
        default: return nil
        }
    }

    // MARK: - WINDOW mode

    /// `.window` keystrokes. Esc is handled higher up in `handle()` (calls
    /// `exit()`, which tears the controller down). hjkl start/stop edges
    /// on the controller — Shift is sampled live each tick (shrink),
    /// no need to thread the modifier here. Any other key is swallowed
    /// (don't let it hit the focused app).
    private func handleWindow(controller: WindowController, keyCode: Int, flags: CGEventFlags) -> Bool {
        if let edge = Self.windowEdge(for: keyCode) {
            controller.startEdge(edge)
            return true
        }
        return true   // swallow everything else
    }

    /// h/j/k/l → which edge of the window they grab. Matches the chip
    /// labels in `WindowOpOverlay`: `k` = top (`↑`), `j` = bottom (`↓`),
    /// `h` = left (`←`), `l` = right (`→`).
    private static func windowEdge(for keyCode: Int) -> WindowController.Edge? {
        switch keyCode {
        case KeyCode.h: return .left
        case KeyCode.j: return .bottom
        case KeyCode.k: return .top
        case KeyCode.l: return .right
        default: return nil
        }
    }

    // MARK: - DRAG mode

    /// `.drag` keystrokes. Esc is already handled in `handle()` above
    /// (calls `exit()`, which releases the mouseDown at the current
    /// cursor — that's the "exit, drop wherever" semantic). hjkl is
    /// handled by the early intercept (with `dragHeld: true` so
    /// MouseMover posts `.leftMouseDragged`). Here we handle the two
    /// drag-specific completions:
    ///
    ///   Enter      → commit: `mouseUp` at current cursor; if pre-drag
    ///                was sticky TAP, re-hint with sticky preserved;
    ///                else exit to OFF.
    ///   Backspace  → cancel: warp back to `startPoint`, `mouseUp` there
    ///                (target app sees a click with zero drag distance —
    ///                no drop registered). Return to the pre-drag mode
    ///                (sticky TAP stays sticky, SCROLL re-detects areas).
    ///
    /// Any other key is swallowed (return true) to prevent stray side
    /// effects mid-drag — we don't want a stray letter or chord to
    /// trigger something while a mouseDown is held.
    private func handleDrag(controller: DragController, keyCode: Int, flags: CGEventFlags) -> Bool {
        if keyCode == KeyCode.return {
            MouseSynth.dragUp(at: MouseSynth.cursorPosition())
            finishDrag(controller: controller, cancelled: false)
            return true
        }

        let modMask: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
        if keyCode == KeyCode.delete && flags.intersection(modMask).isEmpty {
            CGWarpMouseCursorPosition(controller.startPoint)
            MouseSynth.dragUp(at: controller.startPoint)
            finishDrag(controller: controller, cancelled: true)
            return true
        }

        // Anything else: swallow. Don't let stray keys hit the focused
        // app while a synthesized mouseDown is held.
        return true
    }

    /// After Enter/Backspace, tear down `.drag` and restore the pre-drag
    /// mode appropriately.
    ///   - **Backspace (cancelled)** → re-enter the pre-drag mode (TAP
    ///     with original sticky / SCROLL re-detecting areas). The user
    ///     bailed out, so we put them back where they started.
    ///   - **Enter (committed)** → sticky-aware:
    ///       * pre = TAP sticky → re-hint TAP (sticky preserved).
    ///       * pre = TAP non-sticky → exit (drag was the one action).
    ///       * pre = SCROLL → exit (drop ends the SCROLL session;
    ///         restoring SCROLL after a drag is unusual and we keep
    ///         the rule simple).
    private func finishDrag(controller: DragController, cancelled: Bool) {
        mover.stop()
        mode = nil
        if cancelled {
            switch controller.preMode {
            case .tap(let wasSticky):
                enter()
                sticky = wasSticky
                renderModeHUD()
            case .scroll:
                enterScroll()
            }
            return
        }
        // Committed drop.
        switch controller.preMode {
        case .tap(let wasSticky):
            if wasSticky {
                // Re-enter TAP, restore sticky. enter()'s own async scan
                // gives us fresh hints reflecting the post-drop UI — no
                // need to also call scheduleStickyRehint, that would just
                // double up. (Yes, the OP scan may catch the UI mid-
                // settle — same trade as a regular sticky click.)
                enter()
                sticky = wasSticky
                renderModeHUD()
            } else {
                exit()
            }
        case .scroll:
            exit()
        }
    }

    // MARK: - SCROLL mode

    /// SCROLL mode keystrokes. (Esc exits to OFF; Caps Lock → TAP are
    /// both handled in HotkeyTap's F19 arm layer, not here.) j/k drive
    /// the ScrollController (continuous on hold); number keys switch
    /// the selected area.
    private func handleScroll(controller: ScrollController, keyCode: Int, flags: CGEventFlags) -> Bool {
        // gg / G — vim-style jump to top / bottom of the selected area.
        // Reset the gg-pending flag up front; the bare-g branch re-arms
        // it. So any key other than a second bare g clears a half-typed
        // gg (g alone does nothing).
        let wasPendingG = scrollPendingG
        scrollPendingG = false
        if keyCode == KeyCode.g && flags.contains(.maskShift) {
            controller.jumpToBottom()       // G → bottom
            return true
        }
        if keyCode == KeyCode.g
            && flags.intersection([.maskShift, .maskControl,
                                   .maskCommand, .maskAlternate]).isEmpty {
            if wasPendingG {
                controller.jumpToTop()      // gg → top
            } else {
                scrollPendingG = true       // first g, wait for the second
            }
            return true
        }

        // d / u → start continuous scroll down / up. Shift = fast.
        // (Not j/k — those are unified cursor-move keys now; SCROLL
        // scrolls with d/u, the same letters as the Caps Lock+d entry
        // chord.) Held-key OS repeats just refresh direction/speed.
        if keyCode == KeyCode.d {
            controller.start(directionDown: true, fast: flags.contains(.maskShift))
            return true
        }
        if keyCode == KeyCode.u {
            controller.start(directionDown: false, fast: flags.contains(.maskShift))
            return true
        }

        // h/j/k/l → move the cursor (Shift fast / Option slow) — SAME
        // keys as TAP (unified, vim hjkl). j/k are free for move here
        // because SCROLL scrolls with d/u.
        if let dir = Self.moveDirection(for: keyCode) {
            mover.start(direction: dir, speed: Self.moveSpeed(from: flags))
            return true
        }

        // Enter → click at the current cursor position, stay in SCROLL.
        // Modifier picks the kind: bare single-left / Shift double /
        // Option right. Pairs with hjkl: move the cursor, Enter to click.
        if keyCode == KeyCode.return {
            let (button, count) = Self.clickKind(from: flags)
            MouseSynth.click(at: MouseSynth.cursorPosition(), button: button, count: count)
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

    /// Cursor-move speed from modifiers: Option = slow (precise), Shift
    /// = fast, bare = normal. Option wins if both are held (precision
    /// intent is stronger). Shared by TAP and SCROLL (both use hjkl).
    private static func moveSpeed(from flags: CGEventFlags) -> MouseMover.Speed {
        if flags.contains(.maskAlternate) { return .slow }
        if flags.contains(.maskShift) { return .fast }
        return .normal
    }

    /// (button, count) for an Enter cursor-click from modifiers — same
    /// mapping as hint commits: Shift = double-left, Option = right,
    /// bare = single-left. Shift wins if both held. Shared by TAP/SCROLL.
    private static func clickKind(from flags: CGEventFlags) -> (CGMouseButton, Int) {
        if flags.contains(.maskShift) { return (.left, 2) }       // double
        if flags.contains(.maskAlternate) { return (.right, 1) }  // right
        return (.left, 1)                                         // single
    }

    /// Key release handler — routed from HotkeyTap.
    func handleKeyUp(keyCode: Int) -> Bool {
        if case .scroll(let controller) = mode {
            if keyCode == KeyCode.d || keyCode == KeyCode.u {
                controller.stop()           // stop continuous scroll
                return true
            }
            if Self.moveDirection(for: keyCode) != nil {
                mover.stop()                // stop continuous cursor move (hjkl)
                return true
            }
            return false
        }
        if case .tap = mode {
            // hjkl release stops cursor movement. These aren't hint
            // chars, so always consume their release while in TAP.
            if Self.moveDirection(for: keyCode) != nil {
                mover.stop()
                return true
            }
            return false
        }
        if case .drag = mode {
            // Same as TAP: hjkl release stops the (drag-mode) cursor move.
            // Stopping just kills the timer — the held mouseDown stays
            // held until Enter/Esc/Backspace explicitly releases it.
            if Self.moveDirection(for: keyCode) != nil {
                mover.stop()
                return true
            }
            return false
        }
        if case .window(let controller) = mode {
            // hjkl release stops the corresponding edge resize.
            if let edge = Self.windowEdge(for: keyCode) {
                controller.stopEdge(edge)
                return true
            }
            return false
        }
        if case .windowMove(let controller) = mode {
            if let dir = Self.windowMoveDirection(for: keyCode) {
                controller.stopDirection(dir)
                return true
            }
            return false
        }
        return false
    }

    /// Unified cursor-move keys (vim hjkl), TAP and SCROLL alike.
    private static func moveDirection(for keyCode: Int) -> MouseMover.Direction? {
        switch keyCode {
        case KeyCode.h: return .left
        case KeyCode.j: return .down
        case KeyCode.k: return .up
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

        // Enter — click at the current cursor position. Modifier picks
        // the click kind, same mapping as hint commits: bare = single
        // left, Shift = double, Option = right. Pairs with hjkl move:
        // move the cursor, Enter to click. (Cmd/Ctrl+Enter already
        // passed through up top; palette's Enter is intercepted earlier;
        // hint labels are letters/digits so Enter never collides.)
        //
        // After-click behavior mirrors a hint commit: sticky → rescan +
        // stay in TAP; otherwise → exit to OFF.
        if keyCode == KeyCode.return {
            hint.deactivate()
            let (button, count) = Self.clickKind(from: flags)
            MouseSynth.click(at: MouseSynth.cursorPosition(), button: button, count: count)
            if sticky {
                scheduleStickyRehint()
            } else {
                exit()
            }
            return true
        }

        // Backspace — undo the last typed hint character (e.g. pressed a
        // wrong first letter). Empty typed → no-op (don't exit; Esc does
        // that). Works in sticky too.
        if keyCode == KeyCode.delete && flags.intersection(modMask).isEmpty {
            hint.backspace()
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
        case .pending, .ignored:
            break   // .ignored = misfire, swallowed; stay in TAP
        case .committed:
            if sticky {
                // Re-scan and stay in TAP. Single re-hint ~100ms after the
                // click lands (see scheduleStickyRehint). App switches are
                // handled separately by the always-on app-switch follow.
                scheduleStickyRehint()
            } else {
                exit()
            }
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
        case .drag: label = "DRAG"
        case .window: label = "WINDOW"
        case .windowMove: label = "MOVE"
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
        // h/j/k/l are hjkl cursor-move keys, not hint chars. The rest of
        // the pool backfills around them (must match HintMode.alphabet).
        case KeyCode.e: return "e"
        case KeyCode.r: return "r"
        case KeyCode.u: return "u"
        case KeyCode.i: return "i"
        case KeyCode.o: return "o"
        case KeyCode.p: return "p"
        case KeyCode.w: return "w"
        case KeyCode.t: return "t"
        case KeyCode.n: return "n"
        case KeyCode.m: return "m"
        case KeyCode.c: return "c"
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
