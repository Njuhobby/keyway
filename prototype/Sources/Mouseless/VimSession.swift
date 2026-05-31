import Cocoa
import Vision   // VNRecognizedTextObservation, for the TAP /-search sub-state

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
        case window(WindowController)
        case windowMove(WindowMoveController)
        // Future: case selectText(...), case rightClick(...)
    }

    /// TAP-only sub-state. DRAG and `/`-search are **features inside
    /// TAP**, not separate modes — they're available only when the user
    /// is already in TAP (or sticky TAP). Only meaningful when
    /// `mode == .tap`; reset to `.normal` whenever the top-level mode
    /// changes (see `teardownCurrentMode` / `exit`).
    enum TapSub {
        case normal
        case dragging(DragController)
        case searchTyping(buffer: String)
        case searchSearching   // transient: OCR in flight after Enter
        case searchPicking(matches: [SearchMatch], typed: String)
    }

    /// One text match from the search OCR pass.
    struct SearchMatch {
        let label: String   // hint-style label (e.g. "a", "as", …)
        let rect: CGRect    // screen rect (AX coords, top-left origin) of the matched substring
        let text: String    // the matched substring (for debug logging)
    }

    private var mode: Mode? = nil
    private var tapSub: TapSub = .normal       // only meaningful when mode == .tap
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
            // In TAP, a Caps Lock tap toggles sticky — but only when
            // we're in the normal sub-state. While a drag is held or
            // a search is running, the chord still works as a "switch
            // mode" trigger (uniform with other modes); teardown
            // releases the held mouseDown / clears search.
            if case .normal = tapSub {
                sticky.toggle()
                renderModeHUD()
            } else {
                teardownCurrentMode()
                enter()
            }
        case .scroll, .window, .windowMove:
            // Caps Lock single tap from any of these → switch to TAP.
            // teardownCurrentMode handles the cleanup uniformly:
            // window/windowMove stop their timer + hide the blue
            // overlay, scroll hides its picker.
            teardownCurrentMode()
            enter()
        }
    }

    /// Chord (Caps Lock + d) → enter SCROLL mode from ANY mode. No
    /// hint scan — scroll is independent of hints. Synchronous: the AX
    /// scroll-area walk runs inline (cheap, ~few ms). See
    /// `specs/scroll-mode-design.md`.
    func enterScroll() {
        // Caps Lock + d works from any mode — teardownCurrentMode
        // handles drag's mouseUp release, window/move timer stop +
        // overlay hide, tap deactivation. Idempotent if we're already
        // in SCROLL (just re-detects areas).
        teardownCurrentMode()
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
        if case .window = mode { return }     // already here, chord is a no-op
        // Other modes (drag / scroll / tap / windowMove): teardown
        // cleanly switches over. Drag releases its held mouseDown at
        // the current cursor (same as Esc); window/move overlays hide.
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
        if case .windowMove = mode { return } // already here, chord is a no-op
        // Other modes (drag / scroll / tap / window): teardown cleanly
        // switches over. Drag releases its held mouseDown at the
        // current cursor; window/move overlays hide.
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
        if case .window(let c) = mode {
            c.teardown()                // stops the resize timer
            WindowOpOverlay.shared.hide()
        }
        if case .windowMove(let c) = mode {
            c.teardown()                // stops the move timer
            WindowOpOverlay.shared.hide()
        }
        // TAP sub-state cleanup. Drag has a held mouseDown that must
        // be released so we don't leave a stuck button across mode
        // switches; search has an overlay to hide. Done BEFORE
        // setting mode = nil so the resync paths see the right state.
        cleanupTapSub()
        mode = nil
    }

    /// Reset TAP sub-state to .normal, performing any cleanup the
    /// current sub-state needs (release held mouseDown, hide search
    /// overlay). Used both on exit and on intra-TAP transitions
    /// (e.g. drag → normal after Enter drop).
    private func cleanupTapSub() {
        switch tapSub {
        case .normal:
            break
        case .dragging:
            // Release the held mouseDown wherever the cursor is — same
            // unavoidable "drop side-effect" as Esc-during-drag. The
            // normal completion paths (Enter / Backspace) release
            // explicitly before calling this; the catch-all here is
            // for mode-switch chords mid-drag.
            MouseSynth.dragUp(at: MouseSynth.cursorPosition())
        case .searchTyping, .searchSearching, .searchPicking:
            SearchOverlay.shared.hide()
        }
        tapSub = .normal
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

    /// Re-hint in sticky TAP after a delay. Two callers:
    ///
    /// 1. **Same-window commit** (default `isolateApp: false`): our
    ///    synthesized click is async — re-hinting now would
    ///    scan/screenshot the pre-click frame (stale). 100ms lets the
    ///    click land and the content re-render settle.
    ///
    /// 2. **App switch** (`isolateApp: true`, from
    ///    `startAppSwitchFollow`): `didActivateApplication` fires
    ///    when the OS *marks* the new app active, but the AX tree
    ///    isn't necessarily readable yet and ScreenCaptureKit may
    ///    catch a half-drawn frame. 100ms lets the new app settle
    ///    enough that the scan finds its real elements instead of
    ///    coming back empty (which used to silently `exit()` the
    ///    whole session). `isolateApp` propagates to the capture so
    ///    the Cmd+Tab switcher HUD doesn't bleed into the OP pass.
    ///
    /// A second call during the wait cancels the pending item
    /// (latest wins); exiting / switching mode cancels it too.
    /// Tradeoff for case 1: an update that lands >100ms later
    /// re-hints stale; re-trigger to refresh.
    private func scheduleStickyRehint(isolateApp: Bool = false) {
        pendingStickyRehint?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.sticky else { return }
            self.rehintSticky(isolateApp: isolateApp)
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
                guard let self, case .tap(let h) = self.mode, self.sticky else { return }
                print("[mouseless] app switch in sticky TAP → re-hint new app (100ms delay)")
                // 1. Hide the stale overlay right now — it's drawn for
                //    the OLD app at the OLD coords; leaving it visible
                //    during the 100ms wait would be confusing.
                h.deactivate()
                // 2. Schedule the rescan 100ms out. Earlier we ran this
                //    immediately, but `didActivateApplication` fires
                //    before the new app's AX tree is fully readable /
                //    its window is fully drawn, so the immediate scan
                //    often came back empty → silent `exit()`. The
                //    same-window scheduleStickyRehint already uses
                //    100ms for a similar "let things settle" reason,
                //    just for a different cause (click effect vs app
                //    activation). isolateApp=true so the capture
                //    excludes the Dock process (drops the Cmd+Tab
                //    switcher HUD bleed-in).
                self.scheduleStickyRehint(isolateApp: true)
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
        if case .window(let c) = mode {
            c.teardown()
            WindowOpOverlay.shared.hide()
        }
        if case .windowMove(let c) = mode {
            c.teardown()
            WindowOpOverlay.shared.hide()
        }
        // TAP sub-state cleanup (mouseUp held drag, hide search overlay).
        cleanupTapSub()
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
        case .tap:
            // In TAP normal / dragging hjkl moves the cursor (drag flips
            // event type via dragHeld). In search sub-states hjkl is
            // suppressed — let handleTap route it instead so search
            // can swallow it cleanly (no stray cursor motion mid-type).
            switch tapSub {
            case .normal:
                allowsMoveHere = true; dragHeld = false
            case .dragging:
                allowsMoveHere = true; dragHeld = true   // mover posts .leftMouseDragged
            case .searchTyping, .searchSearching, .searchPicking:
                allowsMoveHere = false; dragHeld = false
            }
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

        // (DRAG mode is now entered via the Caps Lock + v chord from
        // any mode — handled in HotkeyTap, not here. The earlier
        // bare-v-from-TAP-or-SCROLL trigger was removed: forcing the
        // user to first enter TAP/SCROLL just to drag was unnecessary
        // friction.)

        // Cmd / Ctrl held → system shortcut. Pass through so things like
        // Cmd+Shift+4 (screenshot), Cmd+Space (Spotlight), Cmd+Tab, and
        // Ctrl+Up (Mission Control) still work while Mouseless is active.
        // Shift / Option are reserved for hint click-action modifiers
        // (Shift = double-click, Option = right-click), so they stay.
        if !flags.intersection([.maskCommand, .maskControl]).isEmpty {
            return false
        }

        // ↑↓←→ arrow keys → always pass through, in any mode and with
        // any modifier combo. Mouseless uses hjkl for its own cursor /
        // scroll / window motion; the arrow keys are left for the
        // focused app's native navigation (scroll a list, move the
        // text caret, walk a menu, etc.). Without this, the active
        // mode would swallow them — the user couldn't, say, page
        // through a list while sticky TAP keeps hints up. Symmetric
        // with the Cmd/Ctrl passthrough above.
        if keyCode == KeyCode.arrowLeft || keyCode == KeyCode.arrowRight
            || keyCode == KeyCode.arrowUp || keyCode == KeyCode.arrowDown {
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
        //
        // Exception: in TAP's **search** sub-states Esc cancels the
        // search (back to TAP normal with the hint overlay re-shown),
        // rather than exiting all the way out. Drag sub-state still
        // exits — that matches the existing "Esc-in-drag = drop at
        // cursor + exit" semantic.
        if keyCode == KeyCode.escape {
            switch tapSub {
            case .searchTyping, .searchSearching, .searchPicking:
                cancelSearch()
            default:
                exit()
            }
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

    // MARK: - TAP sub-state: drag

    /// Start dragging from TAP normal. Synth `mouseDown` at the current
    /// cursor and switch to `.dragging`. Bare `v` in TAP normal calls
    /// this (handled in `handleTap`).
    private func startDragFromTap() {
        guard case .tap = mode, case .normal = tapSub else { return }
        // Cancel any pending re-hint (e.g. from a recent click commit
        // or search-match commit) so it doesn't fire mid-drag and
        // replace the hidden overlay with a fresh scan.
        pendingStickyRehint?.cancel()
        pendingStickyRehint = nil
        let cursor = MouseSynth.cursorPosition()
        tapSub = .dragging(DragController(at: cursor))
        // Hide the TAP hint overlay while dragging — the labels would
        // distract; user is focused on dragging.
        if case .tap(let h) = mode { h.hideOverlay() }
        renderModeHUD()
        print("[mouseless] DRAG (TAP sub-state) start at \(Int(cursor.x)),\(Int(cursor.y))")
    }

    /// Drag committed (Enter). MouseUp at the current cursor; sticky-
    /// aware exit (sticky → schedule a re-hint; non-sticky → exit OFF
    /// — same shape as a normal hint commit).
    private func dragDrop() {
        guard case .dragging = tapSub else { return }
        mover.stop()
        MouseSynth.dragUp(at: MouseSynth.cursorPosition())
        tapSub = .normal
        if sticky {
            // Re-scan: the drop probably changed the UI (selection
            // moved, list reloaded, etc.). schedulesStickyRehint
            // handles the timing.
            scheduleStickyRehint()
        } else {
            exit()
        }
    }

    /// Drag cancelled (Backspace). Warp cursor back to the drag's
    /// startPoint and release mouseUp there — the target app sees a
    /// zero-distance click and registers no drop. Return to TAP
    /// normal: cursor is back where we started, so the existing hints
    /// (still cached in HintMode) are still valid → just re-show them
    /// instead of re-scanning.
    private func dragCancel() {
        guard case .dragging(let c) = tapSub else { return }
        mover.stop()
        CGWarpMouseCursorPosition(c.startPoint)
        MouseSynth.dragUp(at: c.startPoint)
        tapSub = .normal
        if case .tap(let h) = mode { h.showOverlay() }
        renderModeHUD()
    }

    // MARK: - TAP sub-state: search (`/`)

    /// Bare `/` in TAP normal → enter the search-typing sub-state.
    /// Hide the TAP hint overlay (the label pool is about to be
    /// reused for search matches; visual collision otherwise).
    private func startSearch(hint: HintMode) {
        guard case .tap = mode, case .normal = tapSub else { return }
        // Same reason as startDragFromTap: any pending re-hint from a
        // prior click/search-commit would fire mid-search and surface
        // the hint overlay we just hid.
        pendingStickyRehint?.cancel()
        pendingStickyRehint = nil
        hint.hideOverlay()
        tapSub = .searchTyping(buffer: "")
        renderModeHUD()
    }

    /// `.searchTyping` keystrokes. Letter chars (a-z) append to the
    /// buffer; Backspace removes the last (empty buffer + Backspace =
    /// cancel back to TAP normal); Enter kicks off OCR; Esc cancels
    /// (handled in `handle()`'s Esc branch via cancelSearch).
    private func handleTapSearchTyping(buffer: String, keyCode: Int, flags: CGEventFlags) -> Bool {
        // Two modifier masks:
        //   bareModifiers — strict, no modifiers at all (used by Backspace).
        //   typingMods    — allow Shift (for uppercase letters), block
        //                   Cmd/Ctrl/Option (those are system / future
        //                   actions, not buffer content).
        let strictMask: CGEventFlags = [.maskCommand, .maskControl,
                                        .maskShift, .maskAlternate]
        let bareModifiers = flags.intersection(strictMask).isEmpty
        let typingBlockMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        let typingModsOK = flags.intersection(typingBlockMask).isEmpty

        if keyCode == KeyCode.return {
            // Kick off OCR (asynchronous) on the focused window.
            // Trim — empty buffer = no-op (don't fire OCR on nothing).
            let trimmed = buffer.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            kickoffSearch(query: trimmed)
            return true
        }
        if keyCode == KeyCode.delete && bareModifiers {
            if buffer.isEmpty {
                cancelSearch()
            } else {
                var next = buffer
                next.removeLast()
                tapSub = .searchTyping(buffer: next)
                renderModeHUD()
            }
            return true
        }
        // Letter / digit / space goes into the buffer. Shift+letter →
        // uppercase letter (so the user can type "Google" and see "G"
        // in the HUD); findMatches lowercases both sides for matching,
        // so case is purely a visual-feedback affordance — the user
        // gets to type as they would in any normal search box.
        if typingModsOK, let ch = Self.searchTypingChar(for: keyCode) {
            let actual: Character
            if flags.contains(.maskShift) && ch.isLetter {
                actual = Character(ch.uppercased())
            } else {
                actual = ch
            }
            tapSub = .searchTyping(buffer: buffer + String(actual))
            renderModeHUD()
            return true
        }
        // Anything else: swallow (don't leak typing into the focused app).
        return true
    }

    /// Whitelisted keys for search buffer input: a-z + digits. Symbols
    /// (`-` `.` `/` ...) intentionally excluded for v1 — the buffer is
    /// matched as a literal substring, so users searching exact symbols
    /// are rare and we avoid edge cases with weird keycodes.
    private static func searchTypingChar(for keyCode: Int) -> Character? {
        if let ch = letterChar(for: keyCode) { return ch }
        switch keyCode {
        case 18: return "1"; case 19: return "2"; case 20: return "3"
        case 21: return "4"; case 23: return "5"; case 22: return "6"
        case 26: return "7"; case 28: return "8"; case 25: return "9"
        case 29: return "0"
        case KeyCode.space: return " "
        default: return nil
        }
    }

    /// Trigger OCR + match discovery. Switches to `.searchSearching`
    /// transient state, kicks off an async Task that captures the
    /// focused window, runs Vision OCR, finds substring matches, and
    /// transitions to `.searchPicking` (or back to `.normal` if no
    /// matches).
    private func kickoffSearch(query: String) {
        tapSub = .searchSearching
        renderModeHUD()
        print("[mouseless] search: query=\"\(query)\" — capturing + OCR'ing focused window")
        Task { @MainActor in
            let tStart = Date()
            guard let captured = await ScreenCapture.captureFocusedWindow() else {
                searchFailed(reason: "no focused window")
                return
            }
            // Guard against the user cancelling / mode-switching while
            // OCR is in flight.
            guard case .searchSearching = tapSub else {
                print("[mouseless] search: cancelled during capture")
                return
            }
            let observations = OCRRefiner.recognizeText(in: captured.image)
            guard case .searchSearching = tapSub else {
                print("[mouseless] search: cancelled during OCR")
                return
            }
            let matches = Self.findMatches(query: query,
                                           observations: observations,
                                           windowRect: captured.screenRect)
            let tEnd = Date()
            let ms = Int(tEnd.timeIntervalSince(tStart) * 1000)
            print("[mouseless] search: \(observations.count) obs → \(matches.count) matches in \(ms)ms")
            if matches.isEmpty {
                searchFailed(reason: "no matches for \"\(query)\"")
                return
            }
            // Cap to alphabet² so labels stay ≤2 chars even on huge results.
            let cap = HintMode.alphabet.count * HintMode.alphabet.count
            let capped = Array(matches.prefix(cap))
            let labels = HintMode.generateLabels(count: capped.count)
            let labeled = zip(labels, capped).map { (label, m) in
                SearchMatch(label: label, rect: m.rect, text: m.text)
            }
            tapSub = .searchPicking(matches: labeled, typed: "")
            let overlayMatches = labeled.map { SearchOverlay.Match(label: $0.label, rect: $0.rect) }
            SearchOverlay.shared.show(matches: overlayMatches, typed: "")
            renderModeHUD()
        }
    }

    /// OCR returned nothing usable. Show a brief HUD note, then return
    /// to TAP normal with the hint overlay re-shown.
    private func searchFailed(reason: String) {
        print("[mouseless] search failed: \(reason)")
        cancelSearch()
        HUD.shared.show("no matches")
    }

    /// One raw OCR-derived match before label assignment.
    private struct RawMatch {
        let text: String
        let rect: CGRect    // AX screen coords
    }

    /// Substring-search across all OCR observations. Case-insensitive.
    /// For each observation we look up every occurrence of `query` (so
    /// the same line with multiple matches gets multiple labels), and
    /// use Vision's `boundingBox(for: range)` to get the substring's
    /// normalized rect inside the captured image. Convert to screen
    /// coords using the window's rect.
    private static func findMatches(query: String,
                                    observations: [VNRecognizedTextObservation],
                                    windowRect: CGRect) -> [RawMatch] {
        var out: [RawMatch] = []
        let needle = query.lowercased()
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let haystack = candidate.string
            let haystackLC = haystack.lowercased()
            var searchStart = haystackLC.startIndex
            while searchStart < haystackLC.endIndex,
                  let range = haystackLC.range(of: needle, range: searchStart..<haystackLC.endIndex) {
                // Map the lowercased range back to the original string
                // by offsets (the lowercased string has the same length
                // for our supported scripts).
                let lo = haystackLC.distance(from: haystackLC.startIndex, to: range.lowerBound)
                let hi = haystackLC.distance(from: haystackLC.startIndex, to: range.upperBound)
                if let origLo = haystack.index(haystack.startIndex, offsetBy: lo, limitedBy: haystack.endIndex),
                   let origHi = haystack.index(haystack.startIndex, offsetBy: hi, limitedBy: haystack.endIndex),
                   let box = try? candidate.boundingBox(for: origLo..<origHi) {
                    // box.boundingBox is normalized in image-space,
                    // BOTTOM-LEFT origin (Vision quirk). Convert to
                    // screen-space top-left coords.
                    let bb = box.boundingBox
                    let cropW = windowRect.width
                    let cropH = windowRect.height
                    let x = windowRect.origin.x + bb.minX * cropW
                    let yFromTop = windowRect.origin.y + (1.0 - bb.maxY) * cropH
                    let rect = CGRect(x: x, y: yFromTop,
                                      width: bb.width * cropW,
                                      height: bb.height * cropH)
                    out.append(RawMatch(text: String(haystack[origLo..<origHi]),
                                        rect: rect))
                }
                // Advance past this occurrence to find the next.
                searchStart = range.upperBound
            }
        }
        return out
    }

    /// `.searchPicking` keystrokes. Letter (a-z) extends `typed`; if
    /// uniquely identifies a label, commit (warp cursor + return to
    /// TAP normal). Backspace removes last `typed` char, or goes back
    /// to `.searchTyping` if empty (re-edit query). Enter swallowed
    /// (commit happens by typing the full label).
    private func handleTapSearchPicking(matches: [SearchMatch], typed: String,
                                        keyCode: Int, flags: CGEventFlags) -> Bool {
        let modMask: CGEventFlags = [.maskCommand, .maskControl,
                                     .maskShift, .maskAlternate]
        let bareModifiers = flags.intersection(modMask).isEmpty

        if keyCode == KeyCode.delete && bareModifiers {
            if typed.isEmpty {
                // Step back to typing the query (preserve buffer so the
                // user can edit it). For simplicity v1: just clear buffer
                // and go back; storing buffer across the OCR call would
                // require more state.
                tapSub = .searchTyping(buffer: "")
                SearchOverlay.shared.hide()
                renderModeHUD()
            } else {
                var next = typed
                next.removeLast()
                tapSub = .searchPicking(matches: matches, typed: next)
                SearchOverlay.shared.updateTyped(next)
                renderModeHUD()
            }
            return true
        }
        guard bareModifiers,
              let ch = Self.hintChar(for: keyCode)
        else {
            // Enter / Shift+letter / etc.: swallow.
            return true
        }
        let next = typed + String(ch)
        let candidates = matches.filter { $0.label.hasPrefix(next) }
        if candidates.isEmpty {
            // No label matches that prefix — misfire, swallow (preserve
            // current typed). Same UX as hint commit's .ignored case.
            return true
        }
        if candidates.count == 1, candidates[0].label == next {
            commitSearchMatch(candidates[0])
            return true
        }
        tapSub = .searchPicking(matches: matches, typed: next)
        SearchOverlay.shared.updateTyped(next)
        renderModeHUD()
        return true
    }

    /// User picked a match — warp cursor to a point just inside the
    /// matched text's glyph area, then return to TAP normal with a
    /// fresh hint re-scan (cursor moved → hover state may have
    /// changed; existing hint targets may no longer be exactly
    /// where they were).
    ///
    /// **Inset choice** (`x += 2`, `y` at 60% down from rect top):
    /// the OCR rect is a coarse pixel box around the substring's
    /// glyphs — its edges don't necessarily map to caret positions
    /// the text view considers "inside this line". Landing exactly
    /// on `(minX, midY)` sometimes hit-tests to the line above (left
    /// padding) or the gap between lines (vertical center between
    /// inter-line spacing). Pushing 2pt right past the leading
    /// padding and dropping 10% below mid (so y biases toward the
    /// glyph baseline, away from upper line spacing) keeps the
    /// click inside the visible text. Empirically tuned for Mail's
    /// rich-text content where the bug was first seen; small enough
    /// that the caret still lands at the **start** of the matched
    /// text (between the first and second character at worst).
    private func commitSearchMatch(_ match: SearchMatch) {
        let landing = CGPoint(
            x: match.rect.minX + 2,
            y: match.rect.minY + match.rect.height * 0.6
        )
        print("[mouseless] search commit: label=\(match.label) text=\"\(match.text.prefix(40))\" rect=(\(Int(match.rect.minX)),\(Int(match.rect.minY)),\(Int(match.rect.width))x\(Int(match.rect.height))) → cursor (\(Int(landing.x)),\(Int(landing.y)))")
        SearchOverlay.shared.hide()
        CGWarpMouseCursorPosition(landing)
        tapSub = .normal
        // Re-hint so the user can interact with whatever's now under
        // the new cursor position (sticky-aware: same logic as a hint
        // commit). Even non-sticky re-scans here — the user just did
        // a search, presumably they want to keep going (maybe drag
        // the text with bare v next).
        scheduleStickyRehint()
    }

    /// Esc inside search or empty-buffer Backspace → cancel back to
    /// TAP normal with the hint overlay restored.
    private func cancelSearch() {
        guard case .tap(let h) = mode else { return }
        SearchOverlay.shared.hide()
        tapSub = .normal
        h.showOverlay()
        renderModeHUD()
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

        // bare `c` → click at the current cursor position, stay in
        // SCROLL. Modifier picks the kind: bare single-left / Shift
        // double / Option right. Pairs with hjkl: move the cursor,
        // `c` to click. Same swap from Enter→c as TAP normal (see
        // handleTapNormal): Enter has app-level semantics we want to
        // preserve.
        if keyCode == KeyCode.c {
            let (button, count) = Self.clickKind(from: flags)
            MouseSynth.click(at: MouseSynth.cursorPosition(), button: button, count: count)
            return true
        }
        // Enter → pass through (same reason as TAP normal).
        if keyCode == KeyCode.return {
            return false
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
            // chars, so always consume their release while in TAP —
            // including the dragging sub-state (the timer is the
            // mover; the held mouseDown stays held until Enter / Esc /
            // Backspace releases it explicitly).
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
        // TAP routes keys based on the active sub-state. Esc / Caps Lock
        // chord / hjkl are all intercepted earlier in handle(), so we
        // see letters / digits / Enter / Backspace / `/` / `v` here.
        switch tapSub {
        case .normal:
            return handleTapNormal(hint: hint, keyCode: keyCode, flags: flags)
        case .dragging:
            return handleTapDragging(keyCode: keyCode, flags: flags)
        case .searchTyping(let buffer):
            return handleTapSearchTyping(buffer: buffer, keyCode: keyCode, flags: flags)
        case .searchSearching:
            return true   // transient — OCR in flight, swallow input
        case .searchPicking(let matches, let typed):
            return handleTapSearchPicking(matches: matches, typed: typed,
                                          keyCode: keyCode, flags: flags)
        }
    }

    private func handleTapNormal(hint: HintMode, keyCode: Int, flags: CGEventFlags) -> Bool {
        let modMask: CGEventFlags = [.maskShift, .maskControl,
                                     .maskCommand, .maskAlternate]
        let bareModifiers = flags.intersection(modMask).isEmpty

        // bare `v` → start drag at current cursor. (v is no longer in
        // the hint pool, so this doesn't collide with a hint commit.)
        if keyCode == KeyCode.v && bareModifiers {
            startDragFromTap()
            return true
        }

        // bare `/` → enter search-typing sub-state.
        if keyCode == KeyCode.slash && bareModifiers {
            startSearch(hint: hint)
            return true
        }

        // bare `c` — click at the current cursor position. Modifier
        // picks the click kind, same mapping as hint commits: bare =
        // single left, Shift = double, Option = right. Pairs with
        // hjkl move: move the cursor, `c` to click. `c` is removed
        // from the hint pool so this can never collide with a hint
        // label that ends in `c`.
        //
        // **Why not Enter** (the prior binding): Enter has app-level
        // semantics — e.g. arrow-key through a menu in the focused
        // app then Enter to confirm, or Enter to submit a form. With
        // arrow keys now passing through, eating Enter would block
        // exactly the workflows the arrow-passthrough was meant to
        // enable. Enter falls through to the explicit passthrough
        // below.
        //
        // After-click behavior mirrors a hint commit: sticky → rescan +
        // stay in TAP; otherwise → exit to OFF.
        if keyCode == KeyCode.c {
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

        // Enter → pass through. Lets the focused app handle confirm /
        // submit / menu-select semantics, which the user reaches via
        // the arrow-key passthrough (see VimSession.handle()).
        if keyCode == KeyCode.return {
            return false
        }

        // Backspace — undo the last typed hint character (e.g. pressed a
        // wrong first letter). Empty typed → no-op (don't exit; Esc does
        // that). Works in sticky too.
        if keyCode == KeyCode.delete && bareModifiers {
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

    /// `.dragging` keystrokes. hjkl is handled by the early intercept
    /// (with dragHeld true so MouseMover posts `.leftMouseDragged`).
    /// Here we handle the two completion paths; everything else is
    /// swallowed to keep stray keys out of the focused app while a
    /// mouseDown is held.
    private func handleTapDragging(keyCode: Int, flags: CGEventFlags) -> Bool {
        let modMask: CGEventFlags = [.maskShift, .maskControl,
                                     .maskCommand, .maskAlternate]
        let bareModifiers = flags.intersection(modMask).isEmpty

        if keyCode == KeyCode.return {
            dragDrop()
            return true
        }
        if keyCode == KeyCode.delete && bareModifiers {
            dragCancel()
            return true
        }
        // bare `v` while dragging: idempotent no-op (already grabbed).
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
        case .tap:
            // TAP label depends on the active sub-state.
            switch tapSub {
            case .normal:
                label = sticky ? "TAP · sticky" : "TAP"
            case .dragging:
                label = sticky ? "TAP · sticky · dragging" : "TAP · dragging"
            case .searchTyping(let buffer):
                // Search HUD shows the buffer prefixed with `/` (vim-style).
                // Skip the suffix — the slash + buffer IS the HUD content.
                label = "/" + buffer
            case .searchSearching:
                label = "/ … searching"
            case .searchPicking(_, let typed):
                label = typed.isEmpty ? "/ pick label" : "/ pick: \(typed)"
            }
        case .scroll: label = "SCROLL"
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
