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

    /// SCROLL mode sub-states. Currently only hosts the `/`-search
    /// sub-states (mirrors TapSub's search cases) — SCROLL has its
    /// own `.normal` for d/u scrolling + hjkl cursor + c click + gg/G
    /// jumps + number-key area picker. Reset to `.normal` on exit /
    /// mode change (see `cleanupScrollSub`).
    ///
    /// **Why** search belongs in SCROLL too: search is "precise
    /// cursor teleport"; SCROLL already exposes cursor movement
    /// (hjkl) and cursor-position click (bare `c`); adding `/` is
    /// the natural extension so users can scroll a long page, spot a
    /// keyword, jump to it, click — all without leaving SCROLL. The
    /// search machinery itself (OCR + label rendering + matching) is
    /// host-agnostic and reused via `setSearchPhase` / `searchPhase`
    /// helpers.
    enum ScrollSub {
        case normal
        case searchTyping(buffer: String)
        case searchSearching
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
    private var scrollSub: ScrollSub = .normal // only meaningful when mode == .scroll
    private var paletteBuffer: String? = nil   // nil = palette closed
    private var sticky: Bool = false           // toggled by trigger key in TAP
    private let mover = MouseMover()            // hjkl cursor move (TAP + SCROLL)
    private var rehintGeneration = 0           // supersede in-flight re-hints
    private var pendingStickyRehint: DispatchWorkItem?  // post-commit delayed re-hint
    /// Pending work item for the "re-apply current mode on the newly-
    /// activated app" flow — see `reapplyOnCurrentFrontmost`. Separate from
    /// `pendingStickyRehint` because the two have different semantics
    /// (this one fires regardless of sticky / mode, that one is for
    /// post-commit same-window settle). Both get cancelled by user
    /// actions that supersede them (Esc, mode chord, etc.).
    private var pendingAppSwitchReenter: DispatchWorkItem?
    private var scrollPendingG = false         // first 'g' of a gg (SCROLL)

    /// Mode without its associated value — captured at app-switch time
    /// so the delayed re-enter knows which mode to reapply, even if
    /// `self.mode` mutates during the 100ms settle gap.
    private enum ModeKind { case tap, scroll, window, windowMove }
    private var currentModeKind: ModeKind? {
        switch mode {
        case .tap:        return .tap
        case .scroll:     return .scroll
        case .window:     return .window
        case .windowMove: return .windowMove
        case nil:         return nil
        }
    }

    /// Host-agnostic projection of whichever sub-state enum corresponds
    /// to the current mode. Lets the search machinery (`kickoffSearch`,
    /// `handleSearchTyping`, `handleSearchPicking`, etc.) read /
    /// write the search state without knowing whether the host is TAP
    /// or SCROLL.
    private enum SearchPhase {
        case typing(buffer: String)
        case searching
        case picking(matches: [SearchMatch], typed: String)
    }
    private var searchPhase: SearchPhase? {
        switch mode {
        case .tap:
            switch tapSub {
            case .searchTyping(let b): return .typing(buffer: b)
            case .searchSearching: return .searching
            case .searchPicking(let m, let t): return .picking(matches: m, typed: t)
            default: return nil
            }
        case .scroll:
            switch scrollSub {
            case .searchTyping(let b): return .typing(buffer: b)
            case .searchSearching: return .searching
            case .searchPicking(let m, let t): return .picking(matches: m, typed: t)
            default: return nil
            }
        default:
            return nil
        }
    }
    /// Write a search sub-state on whichever host (TAP / SCROLL) is
    /// active. Pass `nil` to exit search entirely (returns the host
    /// to its `.normal` sub-state). No-op if `mode` isn't a host
    /// that supports search.
    private func setSearchPhase(_ phase: SearchPhase?) {
        switch mode {
        case .tap:
            switch phase {
            case nil: tapSub = .normal
            case .typing(let b): tapSub = .searchTyping(buffer: b)
            case .searching: tapSub = .searchSearching
            case .picking(let m, let t): tapSub = .searchPicking(matches: m, typed: t)
            }
        case .scroll:
            switch phase {
            case nil: scrollSub = .normal
            case .typing(let b): scrollSub = .searchTyping(buffer: b)
            case .searching: scrollSub = .searchSearching
            case .picking(let m, let t): scrollSub = .searchPicking(matches: m, typed: t)
            }
        default:
            return
        }
    }
    /// Per-edge timestamp of the last hjkl keyUp in `.window` mode,
    /// used to detect a double-tap (jj/kk/hh/ll) for "shrink this
    /// edge instead of expanding". A keyDown within
    /// `windowReverseTapWindow` of the recorded keyUp is the second
    /// tap → reversed hold. CFAbsoluteTime (monotonic-ish, simple)
    /// rather than Date to avoid surprises if the wall clock jumps.
    ///
    /// **150ms**, tuned down from the initial 300ms. 300ms caught a
    /// lot of "tap, look at result, tap again to grow more" patterns
    /// as false-positive double-taps; 200ms was the first cut but
    /// still let some natural pauses slip through. 150ms is a tight
    /// "deliberately fast" window — a real double-tap gesture lands
    /// in 80-130ms, so 150ms still has comfortable margin, but the
    /// "look-and-decide-then-press-again" pattern (250ms+) is out.
    private var lastWindowEdgeKeyUp: [WindowController.Edge: CFAbsoluteTime] = [:]
    private let windowReverseTapWindow: CFAbsoluteTime = 0.15

    /// Same-as-WINDOW double-tap detection for **TAP cursor jump**:
    /// `hh` / `jj` / `kk` / `ll` released-then-pressed within 150ms
    /// teleports the cursor 1/4 of the containing screen in that
    /// direction. Holding the second tap chains jumps via OS
    /// key-repeat (each repeated keyDown re-triggers because we
    /// refresh the timestamp on every jump). Single press still
    /// starts the existing continuous `mover.start`.
    ///
    /// Threshold tracks `windowReverseTapWindow` (150ms) so muscle
    /// memory is one rhythm across modes. Cleared on TAP exit and
    /// on commit.
    private var lastTapHjklKeyUp: [MouseMover.Direction: CFAbsoluteTime] = [:]

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
        case .tap(let h):
            // In TAP, a Caps Lock tap toggles sticky — but only when
            // we're in the normal sub-state. While a drag is held or
            // a search is running, the chord still works as a "switch
            // mode" trigger (uniform with other modes); teardown
            // releases the held mouseDown / clears search.
            if case .normal = tapSub {
                let wasSticky = sticky
                sticky.toggle()
                // Re-hint **only on the sticky→non-sticky direction**
                // — that's where the user originally asked for
                // refresh ("about to make my final click, give me
                // up-to-date hints before I commit"). The other
                // direction (non-sticky→sticky) was added for
                // symmetry, but it conflicts with the common rapid
                // Caps-Lock-double-tap gesture "OFF → TAP → TAP
                // sticky": typical double-tap interval (~200ms) is
                // longer than the initial scan duration (~80ms), so
                // by the time of the second Caps Lock the initial
                // hints are already showing and a second scan
                // produces a visible flash. Asymmetric semantics is
                // also cleaner: toggling INTO sticky is "I want
                // continuous mode going forward" — next commit
                // refreshes hints — no immediate refresh needed.
                // The `h.isActive` guard remains for the case where
                // the user toggles sticky off WHILE the initial scan
                // is still in flight (very fast double-tap from a
                // pre-existing TAP sticky — uncommon but possible).
                if wasSticky, h.isActive {
                    rehintSticky()
                }
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
        let ready = controller.enter()      // detect scroll areas, warp, show overlay
        guard ready else {
            // No focused window at all — common when reached via the
            // app-switch re-apply path and the new app has its
            // windows minimized / hidden / on another Space. Surface
            // it instead of leaving SCROLL mode active on an empty
            // controller (user would press d/u and nothing useful
            // would happen).
            HUD.shared.show("SCROLL: no frontmost window")
            print("[mouseless] enter SCROLL: aborted — no focused window")
            return
        }
        mode = .scroll(controller)
        paletteBuffer = nil
        sticky = false
        renderModeHUD()   // show "SCROLL" (was stuck on "TAP" when chorded from TAP)
        startFollowingFrontmost()   // re-apply SCROLL on app activation
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
        startFollowingFrontmost()   // re-apply WINDOW resize on app activation
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
        startFollowingFrontmost()   // re-apply WINDOW MOVE on app activation
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
        startFollowingFrontmost()   // acts only while sticky (gated in callback)

        Task { @MainActor in
            // Guard against the mode changing out from under us during
            // the async scan (user hit Esc / chorded into SCROLL).
            guard case .tap(let cur) = self.mode, cur === h else { return }
            if await h.activate() {
                self.renderModeHUD()
                // Park cursor on focused window's title bar if not
                // already inside that window — helper returns false
                // if no frontmost window, in which case we show a
                // HUD note but stay in TAP (Dock / menu bar / menu
                // extras hints from `activate` are still usable, so
                // exiting OFF would be too aggressive).
                if !(await self.parkCursorOnFrontmostWindowIfOutside()) {
                    HUD.shared.show("TAP: no frontmost window")
                }
            } else {
                HUD.shared.show("no hints here")
                self.exit()
            }
        }
    }

    /// Tear down whatever mode is active (stop mover/scroll, deactivate
    /// hints) and reset to OFF. Used when switching modes.
    ///
    /// **NOT** responsible for `stopFollowingFrontmost` — the app-switch
    /// observer's lifecycle is session-level (active vs OFF), not
    /// mode-level. Transitioning between modes (e.g., TAP → SCROLL via
    /// Caps Lock + d) should keep the observer alive so the new mode
    /// can also reapply itself on app activation. The observer is
    /// stopped only in `exit()` (the true return to OFF).
    private func teardownCurrentMode() {
        mover.stop()
        pendingStickyRehint?.cancel()
        pendingStickyRehint = nil
        pendingAppSwitchReenter?.cancel()
        pendingAppSwitchReenter = nil
        scrollPendingG = false
        if case .tap(let h) = mode { h.deactivate() }
        if case .scroll(let c) = mode { c.teardown() }
        if case .window(let c) = mode {
            c.teardown()                // stops the resize timer
            lastWindowEdgeKeyUp.removeAll()   // forget stale double-tap timestamps
            WindowOpOverlay.shared.hide()
        }
        lastTapHjklKeyUp.removeAll()    // forget stale double-tap timestamps (TAP jump)
        if case .windowMove(let c) = mode {
            c.teardown()                // stops the move timer
            WindowOpOverlay.shared.hide()
        }
        // TAP / SCROLL sub-state cleanup. Drag has a held mouseDown
        // that must be released so we don't leave a stuck button
        // across mode switches; search (either host) has a SearchOverlay
        // to hide. Done BEFORE setting mode = nil so the resync paths
        // see the right state.
        cleanupTapSub()
        cleanupScrollSub()
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

    /// Reset SCROLL sub-state to .normal. Currently only cleans up
    /// the SearchOverlay if a `/`-search sub-state was active when a
    /// mode-switch chord was pressed.
    private func cleanupScrollSub() {
        switch scrollSub {
        case .normal:
            break
        case .searchTyping, .searchSearching, .searchPicking:
            SearchOverlay.shared.hide()
        }
        scrollSub = .normal
    }

    // MARK: - Sticky re-hint (+ async-focus recheck)

    /// Re-scan + redraw hints, staying in TAP (the sticky path after a
    /// commit/x). Generation-guarded: a later re-hint (e.g. the focus-
    /// recheck poller firing) bumps the generation so an earlier in-
    /// flight scan, when it finishes, sees it's been superseded and bows
    /// out instead of racing to overwrite `mode`.
    private func rehintSticky(isolateApp: Bool = false, fromAppSwitch: Bool = false) {
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
                // App-switch path nuance: `ok` is `true` whenever ANY
                // of the 4 sources produced targets. In practice Dock
                // and menu-extras (and the focused app's own MENU BAR
                // via walkMenuBar — File/Edit/View/... go into
                // `collected.focused`) usually have items even when
                // the user's actual target — a window — is missing.
                // So check `AXFocusedWindow` directly: if the new app
                // has no frontmost window (all minimized / hidden /
                // on another Space), surface that to the user. The
                // existing hints on Dock / menu bar / menu extras
                // remain visible — we deliberately don't exit OFF,
                // since those hints are still useful interaction
                // targets.
                if fromAppSwitch {
                    if !(await self.parkCursorOnFrontmostWindowIfOutside()) {
                        HUD.shared.show("TAP: no frontmost window")
                    }
                }
            } else {
                // All 4 sources came back empty — rare (would need
                // Dock and menu extras to be empty too, e.g. during a
                // transient OS state right after activation).
                HUD.shared.show("no hints here")
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
    ///    `startFollowingFrontmost`): `didActivateApplication` fires
    ///    when the OS *marks* the new app active, but the AX tree
    ///    isn't necessarily readable yet and ScreenCaptureKit may
    ///    catch a half-drawn frame. 100ms lets the new app settle
    ///    enough that the scan finds its real elements instead of
    ///    coming back empty (which used to silently `exit()` the
    ///    whole session). `isolateApp` propagates to the capture so
    ///    the Cmd+Tab switcher HUD doesn't bleed into the OP pass.
    ///
    /// A second call during the wait cancels the pending item
    /// Last time `handlePageChanged` actually refreshed hints. Cooldown
    /// gate to keep dynamic pages (Gmail / Slack / Twitter — DOM
    /// mutates many times per second) from making the overlay churn.
    /// MutationObserver in the extension already filters to "new
    /// clickable element appeared," but a fast async load can produce
    /// several such events in a row.
    private var lastPageChangedRehintAt: CFAbsoluteTime = 0

    /// Extension reported a browser-side content change that requires
    /// rescanning the active tab. Two triggers fan into here:
    ///
    ///   - `page_changed` — MutationObserver detected new clickable
    ///     element(s) in the current tab (async lazy-load, SPA re-
    ///     render, infinite scroll).
    ///   - `tab_changed` — user switched active tab inside the focused
    ///     Chrome window (Cmd+1/2/3, click on tab strip, navigation
    ///     back/forward). Mouseless can't detect this from macOS AX
    ///     because the NSWindow doesn't change — only the extension
    ///     sees it via `chrome.tabs.onActivated`.
    ///
    /// Both result in an in-place hint overlay refresh — no deactivate
    /// flash — so the new clickables become hint-able without the user
    /// having to exit and re-enter TAP.
    ///
    /// Gates (all required):
    ///   - session active AND in TAP mode
    ///   - not in a TAP sub-state (drag / search) — those own the keys
    ///   - frontmost app is a browser (so the in-flight hints came
    ///     from the extension, not AX/OP)
    ///   - typed prefix is empty — user not mid-label-selection; we
    ///     refuse to reshuffle labels under their fingers
    ///   - ≥ 500ms since last page_changed refresh — cooldown
    func handlePageChanged() {
        guard isActive else { return }
        guard case .tap(let h) = mode else { return }
        guard case .normal = tapSub else { return }
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              AppRegistry.isBrowserApp(bundleID: bid) else { return }
        guard h.typedPrefix.isEmpty else {
            // User is committing a hint — don't reshuffle out from under
            // them. They'll see the eventually-fresh state after commit.
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPageChangedRehintAt >= 0.5 else { return }
        lastPageChangedRehintAt = now

        rehintGeneration += 1
        let gen = rehintGeneration
        Task { @MainActor in
            // Use refreshInPlace — re-scan + repaint same overlay window
            // with new targets, NO hide-then-show cycle. Old labels stay
            // visible until the new set lands, so the visual transition
            // is just "labels shift to current positions / new ones
            // appear" — no black-frame flash.
            await h.refreshInPlace()
            guard gen == self.rehintGeneration else { return }
            print("[mouseless] page_changed → refreshed in-place")
        }
    }

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
    private var spaceChangeToken: NSObjectProtocol?

    /// Polls `AXFocusedWindow` while the session is active. `NSWorkspace.didActivateApplication`
    /// (above) doesn't fire on intra-app window changes (Cmd+W close,
    /// Cmd+M minimize, Cmd+` window cycle, Cmd+N new window) —
    /// different notification scope.
    ///
    /// `kAXFocusedWindowChangedNotification` was the textbook fit but
    /// emission is the app's responsibility, and non-native frameworks
    /// (WeChat, Electron, Qt apps) commonly skip it — leaving our
    /// overlays stuck pointing at a destroyed window. Polling is
    /// universal: same AX read we'd do anyway, ~7 IPC/sec at 150ms,
    /// trivial vs the 60fps tick paths in WindowController/ScrollController.
    /// Worst-case latency = poll interval; 150ms is below the threshold
    /// the eye notices a hint label sticking around after Cmd+W.
    ///
    /// `CFEqual` compares AX elements by their internal (pid, cookie)
    /// pair — two reads returning refs to the same logical window
    /// compare equal even though they're different Swift wrappers.
    private var focusedWindowPollTimer: Timer?
    private var lastSeenFocusedWindow: AXUIElement?

    private func startFollowingFrontmost() {
        if appSwitchToken == nil {
            appSwitchToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reapplyOnCurrentFrontmost()
                }
            }
        }
        // Also listen for Space changes. There's no public macOS
        // notification for "Space is currently animating" or "about
        // to switch Space" — only `activeSpaceDidChange`, which
        // fires *after* the slide animation completes. Used in two
        // ways:
        //   1. **Accelerate** a pending app-switch re-enter that was
        //      delayed because the new app's window was on another
        //      Space — the animation just finished, retry now.
        //   2. **Trigger fresh re-apply** for user-driven Space
        //      switches (Ctrl+arrow / three-finger swipe) where no
        //      app activation happens but the focused window
        //      effectively changes.
        if spaceChangeToken == nil {
            spaceChangeToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleSpaceChanged()
                }
            }
        }
        startFocusedWindowPoll()
    }

    private func startFocusedWindowPoll() {
        focusedWindowPollTimer?.invalidate()
        lastSeenFocusedWindow = Self.currentFocusedWindow()
        let t = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollFocusedWindow()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        focusedWindowPollTimer = t
    }

    private func stopFocusedWindowPoll() {
        focusedWindowPollTimer?.invalidate()
        focusedWindowPollTimer = nil
        lastSeenFocusedWindow = nil
    }

    private func pollFocusedWindow() {
        guard isActive else { return }
        let current = Self.currentFocusedWindow()
        let cached = lastSeenFocusedWindow
        let changed: Bool
        switch (current, cached) {
        case (nil, nil):
            changed = false
        case let (c?, l?):
            changed = !CFEqual(c, l)
        default:
            changed = true
        }
        guard changed else { return }
        lastSeenFocusedWindow = current
        print("[mouseless] focused window change detected (poll) → re-apply")
        reapplyOnCurrentFrontmost()
    }

    private static func currentFocusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref)
        guard r == .success, let win = ref else { return nil }
        return (win as! AXUIElement)
    }

    /// `NSWorkspace.didActivateApplication` fired and we're in some
    /// active mode. Strategy: **re-apply the current mode on the new
    /// frontmost app**. The user implicitly told us they want to
    /// operate on the just-activated app — Cmd+Tab or window-click is
    /// "I want to do <current operation> on this app instead".
    ///
    /// Per mode:
    /// - **TAP** (sticky OR non-sticky): rescan hints on new app. Same
    ///   for both — sticky/non-sticky only diverges *after* a commit
    ///   (sticky restays, non-sticky exits); rescanning here is
    ///   correct for both.
    /// - **SCROLL**: re-detect scroll areas on new app, warp cursor to
    ///   closest, redraw overlay.
    /// - **WINDOW resize / MOVE**: find new frontmost window, re-check
    ///   gates. Pass → new controller on new window. Fail → HUD note
    ///   + exit OFF (the new app doesn't support this mode).
    ///
    /// **Variable settle delay**:
    /// - **100ms** when the just-activated app already has a window
    ///   on the current Space (the common case). Long enough for
    ///   the AX tree / pixels to stabilize after activation.
    /// - **500ms** when the activated app has NO on-screen window
    ///   (`CGWindowListCopyWindowInfo` returns no entry for its
    ///   PID). Two sub-cases collapsed: (a) Cmd+Tab to an app on
    ///   another Space — the slide animation takes 250-400ms and a
    ///   100ms scan would catch a mid-animation black-fill state;
    ///   (b) the app genuinely has no visible window (all hidden /
    ///   minimized) — the longer wait just delays the "no frontmost
    ///   window" HUD slightly, no harm. If (a), `activeSpaceDidChange`
    ///   fires when the animation completes — its handler calls
    ///   `reapplyOnCurrentFrontmost` again, which cancels the 500ms pending
    ///   and reschedules with the short 100ms (since by then the
    ///   window IS on the current Space).
    private func reapplyOnCurrentFrontmost() {
        guard isActive else { return }
        let kind = currentModeKind

        // Re-baseline the poll cache so the NSWorkspace path (which
        // also routes here) and a coincidentally-fired poll don't
        // both schedule a re-enter for the same change.
        lastSeenFocusedWindow = Self.currentFocusedWindow()

        // See doc comment above for the rationale.
        let onScreen = Self.frontmostAppHasOnScreenWindow()
        let delay: TimeInterval = onScreen ? 0.1 : 0.5
        print("[mouseless] app/space changed → re-apply \(kind.map { "\($0)" } ?? "?") in \(Int(delay * 1000))ms (onScreen=\(onScreen))")

        // Cancel any in-flight same-window operation (post-click
        // re-hint, etc.) — this app switch supersedes it. Also cancel
        // any prior pending app-switch re-enter (rapid Cmd+Tab through
        // multiple apps: latest wins; cross-Space switch where the
        // 500ms delay gets short-circuited by activeSpaceDidChange).
        pendingStickyRehint?.cancel()
        pendingStickyRehint = nil
        pendingAppSwitchReenter?.cancel()

        // Hide stale overlays immediately. They were drawn at the OLD
        // app's coordinates; leaving them up during the 100ms settle
        // would visually attach them to the wrong app.
        // (We deliberately do NOT teardown the underlying controllers
        // here — that would leave us with `mode != nil` but an inert
        // controller, and a user input in the 100ms gap would route to
        // an unusable state. Letting the timer keep ticking briefly is
        // the lesser of two evils; the re-enter 100ms later does a
        // full `teardownCurrentMode + new controller`.)
        switch mode {
        case .tap(let h):
            h.deactivate()
        case .scroll:
            ScrollOverlay.shared.hide()
        case .window, .windowMove:
            WindowOpOverlay.shared.hide()
        case nil:
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If user has Esc'd or chorded into a different mode in
            // the 100ms gap, respect that action — don't override.
            // (The chord paths cancel `pendingAppSwitchReenter` via
            // `teardownCurrentMode` so we shouldn't even fire, but
            // this guard is belt-and-suspenders.)
            guard self.isActive, self.currentModeKind == kind else { return }
            switch kind {
            case .tap?:
                // `rehintSticky` handles deactivate + async AX/OP
                // scan + mode assignment. `isolateApp: true` drops
                // the Cmd+Tab switcher HUD from the capture.
                // `fromAppSwitch: true` enables the "new app has no
                // visible window" HUD if focused-window targets are
                // empty (even when Dock / extras saved us from a
                // total `ok=false` exit).
                self.rehintSticky(isolateApp: true, fromAppSwitch: true)
            case .scroll?:
                // enterScroll's own teardownCurrentMode at the top
                // tears down the stale .scroll(oldController) before
                // creating the new one — no pre-teardown needed.
                self.enterScroll()
            case .window?, .windowMove?:
                // WINDOW resize / MOVE entry has an "already in this
                // mode → no-op" early-return guard for the manual
                // chord case (Caps+w while in WINDOW). In the
                // app-switch path we ARE still in .window /
                // .windowMove (we only hid the overlay; controllers
                // weren't torn down — see the comment above). Clear
                // the stale mode first so enterX runs fresh on the
                // NEW app's frontmost window. If the new app fails
                // the gates (no resizable / movable window), enterX
                // shows HUD + leaves mode = nil (OFF), instead of
                // leaving the user in a stale .window(oldController)
                // pointing at the previous app's AX ref.
                self.teardownCurrentMode()
                if kind == .window {
                    self.enterWindowMode()
                } else {
                    self.enterWindowMove()
                }
            case nil:
                return
            }
        }
        pendingAppSwitchReenter = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func stopFollowingFrontmost() {
        if let token = appSwitchToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            appSwitchToken = nil
        }
        if let token = spaceChangeToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            spaceChangeToken = nil
        }
        stopFocusedWindowPoll()
    }

    /// `activeSpaceDidChange` handler. Just delegates back into
    /// `reapplyOnCurrentFrontmost`, which will detect "on-screen window now
    /// present" (Space animation completed → frontmost app's window
    /// is now visible) and use the short delay. If a 500ms pending
    /// re-enter from a prior `didActivateApplication` is still in
    /// flight, the cancel+reschedule pattern in `reapplyOnCurrentFrontmost`
    /// replaces it with the shorter post-animation delay.
    private func handleSpaceChanged() {
        reapplyOnCurrentFrontmost()
    }

    /// Is the currently-frontmost app's window visible on the
    /// **current Space**? Used by `reapplyOnCurrentFrontmost` to predict
    /// whether a Space-switch animation is likely in progress: when
    /// the OS reports an app as "activated" but its windows are
    /// nowhere in the on-screen list, the user almost certainly just
    /// Cmd+Tab'd to a cross-Space app and the slide animation is
    /// running.
    ///
    /// `CGWindowListCopyWindowInfo(.optionOnScreenOnly, ...)`
    /// deliberately excludes windows on other Spaces, minimized
    /// windows, and hidden windows — so "no on-screen window for
    /// this PID" covers all three cases. We can't distinguish
    /// "cross-Space animation" from "genuinely no visible window"
    /// up front; `reapplyOnCurrentFrontmost` resolves the ambiguity by
    /// using a longer delay AND letting `activeSpaceDidChange`
    /// short-circuit if it fires.
    private static func frontmostAppHasOnScreenWindow() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = app.processIdentifier
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return raw.contains { dict in
            guard let ownerPID = dict[kCGWindowOwnerPID as String] as? Int32
            else { return false }
            return ownerPID == pid
        }
    }

    /// When entering TAP (either via initial Caps Lock or via app-switch
    /// re-apply), park the cursor on the focused window's title-bar
    /// midpoint — BUT only if the cursor isn't already inside that
    /// window. Skip-when-inside protects the case where the user was
    /// just looking at something specific in the focused app; an
    /// unconditional warp would feel intrusive ("Mouseless moved my
    /// cursor away from where I was looking"). When the cursor is
    /// outside the window (or on a different app), the warp is a
    /// useful nudge — places the cursor at a known good spot
    /// (title-bar: double-click to maximize, drag to move, +/- buttons
    /// nearby).
    ///
    /// Returns `true` if the focused app has a frontmost window
    /// (regardless of whether the cursor was actually moved), `false`
    /// otherwise — caller can then show "TAP: no frontmost window"
    /// HUD on `false`.
    @discardableResult
    private func parkCursorOnFrontmostWindowIfOutside() async -> Bool {
        guard let window = AXWindowOps.frontmostWindow(),
              let rect = AXWindowOps.readRect(window)
        else { return false }
        let cursor = MouseSynth.cursorPosition()
        if rect.contains(cursor) {
            // Cursor already in the focused window — leave it where
            // the user had it.
            return true
        }
        // Outside the window. Preferred landing: a text input the
        // user was last interacting with. Two paths:
        //   - Browser: ask extension (DOM `document.activeElement`,
        //     then first visible input). Chrome's AX is unreliable
        //     for web content focus state.
        //   - Native AX-walkable app: read `AXFocusedUIElement`,
        //     filter to text-input roles.
        // Both fall back to title-bar midpoint when no input found.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isBrowser = bundleID.map { AppRegistry.isBrowserApp(bundleID: $0) } ?? false
        var inputRect: CGRect? = nil
        if isBrowser {
            if let r = await BrowserProvider.findFirstInputRect(),
               rect.intersects(r) {
                inputRect = r
            }
        } else {
            // Native AX path. If the app exposes AXFocusedUIElement
            // (well-behaved native apps + WeChat-style apps), great —
            // we land in the input. If not (Electron apps like Slack /
            // Discord / VS Code where AXFocusedUIElement is empty),
            // accept the title-bar fallback. No deeper AX tree walking
            // — the marginal complexity isn't worth handful of apps it
            // might salvage.
            inputRect = Self.focusedTextInputRect(inside: rect)
        }
        if let inputRect {
            MouseSynth.warp(to: CGPoint(x: inputRect.midX, y: inputRect.midY))
            return true
        }
        let landing = CGPoint(x: rect.midX, y: rect.minY + 6)
        MouseSynth.warp(to: landing)
        return true
    }

    /// If the frontmost app's `AXFocusedUIElement` is a text-input-like
    /// element AND its rect intersects the focused window, returns its
    /// rect (screen coords, AX top-left origin). Returns nil otherwise
    /// — caller should fall back to title-bar landing.
    ///
    /// Two detection paths (either is sufficient):
    ///   1. Role allow-list match (AXTextField, AXTextArea, AXSearchField,
    ///      AXComboBox) — standard well-behaved native apps.
    ///   2. `AXValue` is settable — heuristic for Electron-ish apps
    ///      whose text-input controls report weird roles (e.g.,
    ///      AXGenericElement / AXGroup) but whose values are
    ///      programmatically writable, i.e., it's accepting keyboard input.
    ///
    /// Logs the observed role/subrole so when this fails to detect a
    /// real input on a new app we can extend the rules.
    private static func focusedTextInputRect(inside windowRect: CGRect) -> CGRect? {
        guard let (app, _) = FocusedApp.current() else {
            print("[mouseless] focusedInput: no frontmost app")
            return nil
        }
        var focusedRef: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(
            app, "AXFocusedUIElement" as CFString, &focusedRef
        )
        guard readResult == .success, let raw = focusedRef else {
            print("[mouseless] focusedInput: AXFocusedUIElement read failed (err=\(readResult.rawValue))")
            return nil
        }
        let element = raw as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &roleRef)
        let role = (roleRef as? String) ?? "?"
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXSubrole" as CFString, &subroleRef)
        let subrole = (subroleRef as? String) ?? "nil"

        let textInputRoles: Set<String> = [
            "AXTextField",       // single-line NSTextField, HTML <input type="text">
            "AXTextArea",        // multi-line NSTextView, HTML <textarea>, contenteditable
            "AXSearchField",     // NSSearchField, HTML <input type="search">
            "AXComboBox",        // editable popup; mostly text input semantics
        ]
        let matchedByRole = textInputRoles.contains(role)

        // Fallback: AXValue is settable → some kind of editable. Catches
        // Electron / Web Components / custom inputs that don't advertise
        // a standard role. Filter out buttons by also requiring there
        // to be an AXValue attribute at all (buttons usually don't have
        // it; text inputs do).
        var valueSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &valueSettable)
        var hasValue: CFTypeRef?
        let hasValueResult = AXUIElementCopyAttributeValue(
            element, "AXValue" as CFString, &hasValue
        )
        let matchedByEditableValue =
            valueSettable.boolValue && hasValueResult == .success

        guard matchedByRole || matchedByEditableValue else {
            print("[mouseless] focusedInput: skipped role=\(role) subrole=\(subrole) " +
                  "valueSettable=\(valueSettable.boolValue) hasValue=\(hasValueResult == .success)")
            return nil
        }

        guard let rect = AXWindowOps.readRect(element) else {
            print("[mouseless] focusedInput: role=\(role) matched but no rect")
            return nil
        }
        guard windowRect.intersects(rect) else {
            print("[mouseless] focusedInput: role=\(role) rect outside window (input=\(rect) window=\(windowRect))")
            return nil
        }
        guard rect.width >= 4, rect.height >= 4 else {
            print("[mouseless] focusedInput: role=\(role) rect too small (\(rect.width)x\(rect.height))")
            return nil
        }
        let how = matchedByRole ? "role" : "editable-value"
        print("[mouseless] focusedInput: match via \(how) — role=\(role) subrole=\(subrole) rect=\(rect)")
        return rect
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
        let isBrowser = AppRegistry.isBrowserApp(bundleID: bundleID)
        let useAX = AppRegistry.shouldUseAXForFocused(bundleID: bundleID)
        let label: String
        if isBrowser {
            label = "Browser extension (DOM)"
        } else if useAX {
            label = "AX walk (whitelist)"
        } else {
            label = "OmniParser (default)"
        }
        print("[mouseless] route: \(bundleID) -> \(label)")
    }

    func exit() {
        mover.stop()
        stopFollowingFrontmost()
        pendingStickyRehint?.cancel()
        pendingStickyRehint = nil
        pendingAppSwitchReenter?.cancel()
        pendingAppSwitchReenter = nil
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
        // TAP / SCROLL sub-state cleanup (mouseUp held drag, hide search overlay).
        cleanupTapSub()
        cleanupScrollSub()
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
            // Double-tap detection (TAP normal here; SCROLL uses the
            // same helper in handleScrollNormal — hjkl is unified
            // across both modes so the jump gesture must be too).
            // In the drag sub-state the jump rides the held button:
            // `dragHeld` makes jumpCursor post `.leftMouseDragged`, so
            // the teleport drags the grabbed object 1/4-screen rather
            // than dropping it — same gesture, drag-aware.
            if maybeJumpOnDoubleTap(direction: dir, flags: flags, dragHeld: dragHeld) {
                return true
            }
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
        // Exception: in **search** sub-states (TAP or SCROLL host) Esc
        // cancels the search and returns to the host's `.normal` with
        // the host's main overlay re-shown — rather than exiting all
        // the way out. Drag sub-state still exits — that matches the
        // existing "Esc-in-drag = drop at cursor + exit" semantic.
        // `searchPhase` reads whichever host sub-state is active.
        if keyCode == KeyCode.escape {
            if searchPhase != nil {
                cancelSearch()
            } else {
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
            // Double-tap detection: if this edge's previous keyUp
            // happened within `windowReverseTapWindow` (150ms), this
            // keyDown is the second of a jj/kk/hh/ll pair → shrink.
            // Otherwise normal expand. OS key-repeat fires keyDown
            // without a matching keyUp, so it can't accidentally
            // trigger reverse (lastWindowEdgeKeyUp[edge] stays the
            // old value, but the press is part of the same hold).
            let now = CFAbsoluteTimeGetCurrent()
            let reversed: Bool = {
                guard let last = lastWindowEdgeKeyUp[edge] else { return false }
                return (now - last) < windowReverseTapWindow
            }()
            controller.startEdge(edge, reversed: reversed)
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

    // MARK: - Search sub-state (`/`) — shared between TAP and SCROLL

    /// Bare `/` in TAP normal → enter the search-typing sub-state.
    /// Hide the TAP hint overlay (the label pool is about to be
    /// reused for search matches; visual collision otherwise).
    private func startTapSearch(hint: HintMode) {
        guard case .tap = mode, case .normal = tapSub else { return }
        // Same reason as startDragFromTap: any pending re-hint from a
        // prior click/search-commit would fire mid-search and surface
        // the hint overlay we just hid.
        pendingStickyRehint?.cancel()
        pendingStickyRehint = nil
        hint.hideOverlay()
        setSearchPhase(.typing(buffer: ""))
        renderModeHUD()
    }

    /// Bare `/` in SCROLL normal → enter search-typing sub-state.
    /// Hide the scroll-area picker overlay; restored on commit / cancel.
    /// SCROLL's search has the same semantics as TAP's: type query,
    /// Enter to OCR, pick label, cursor warps to match. After commit,
    /// user is back in SCROLL normal and can press `c` to click, `d/u`
    /// to scroll, etc. — i.e., search is a precise teleport followed
    /// by the user's normal SCROLL interactions.
    private func startScrollSearch(controller: ScrollController) {
        guard case .scroll = mode, case .normal = scrollSub else { return }
        controller.hideOverlay()
        setSearchPhase(.typing(buffer: ""))
        renderModeHUD()
    }

    /// `.searchTyping` keystrokes. Letter chars (a-z) append to the
    /// buffer; Backspace removes the last (empty buffer + Backspace =
    /// cancel back to host's .normal); Enter kicks off OCR; Esc cancels
    /// (handled in `handle()`'s Esc branch via cancelSearch).
    /// Host-agnostic — works for TAP and SCROLL alike via `setSearchPhase`.
    private func handleSearchTyping(buffer: String, keyCode: Int, flags: CGEventFlags) -> Bool {
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
                setSearchPhase(.typing(buffer: next))
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
            setSearchPhase(.typing(buffer: buffer + String(actual)))
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

    /// Trigger match discovery for the user's query. **Routes** by
    /// frontmost app:
    ///   - browser app → ask the extension's DOM-level
    ///     `findTextMatches` (≈5-20ms, exact text, no OCR errors)
    ///   - everything else → existing Vision OCR pipeline
    ///     (ScreenCapture + recognizeText + findMatches)
    /// Switches to `.searchSearching` transient state during the
    /// async work, transitions to `.searchPicking` (or back to
    /// `.normal` if no matches).
    private func kickoffSearch(query: String) {
        setSearchPhase(.searching)
        renderModeHUD()
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let useBrowser = bundleID.map { AppRegistry.isBrowserApp(bundleID: $0) } ?? false
        if useBrowser {
            print("[mouseless] search: query=\"\(query)\" — DOM match via extension")
            kickoffSearchViaBrowser(query: query)
        } else {
            print("[mouseless] search: query=\"\(query)\" — capturing + OCR'ing focused window")
            kickoffSearchViaOCR(query: query)
        }
    }

    private func kickoffSearchViaBrowser(query: String) {
        Task { @MainActor in
            let tStart = Date()
            let raw = await BrowserProvider.findText(query: query)
            // Cancel guard, same pattern as OCR path.
            guard case .searching = self.searchPhase else {
                print("[mouseless] search: cancelled during DOM match")
                return
            }
            let tEnd = Date()
            let ms = Int(tEnd.timeIntervalSince(tStart) * 1000)
            print("[mouseless] search: DOM → \(raw.count) matches in \(ms)ms")
            if raw.isEmpty {
                searchFailed(reason: "no matches for \"\(query)\"")
                return
            }
            let cap = HintMode.alphabet.count * HintMode.alphabet.count
            let capped = Array(raw.prefix(cap))
            let labels = HintMode.generateLabels(count: capped.count)
            let labeled = zip(labels, capped).map { (label, m) in
                SearchMatch(label: label, rect: m.rect, text: m.text)
            }
            setSearchPhase(.picking(matches: labeled, typed: ""))
            let overlayMatches = labeled.map { SearchOverlay.Match(label: $0.label, rect: $0.rect) }
            SearchOverlay.shared.show(matches: overlayMatches, typed: "")
            renderModeHUD()
        }
    }

    private func kickoffSearchViaOCR(query: String) {
        Task { @MainActor in
            let tStart = Date()
            guard let captured = await ScreenCapture.captureFocusedWindow() else {
                searchFailed(reason: "no focused window")
                return
            }
            guard case .searching = self.searchPhase else {
                print("[mouseless] search: cancelled during capture")
                return
            }
            let observations = OCRRefiner.recognizeText(in: captured.image)
            guard case .searching = self.searchPhase else {
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
            let cap = HintMode.alphabet.count * HintMode.alphabet.count
            let capped = Array(matches.prefix(cap))
            let labels = HintMode.generateLabels(count: capped.count)
            let labeled = zip(labels, capped).map { (label, m) in
                SearchMatch(label: label, rect: m.rect, text: m.text)
            }
            setSearchPhase(.picking(matches: labeled, typed: ""))
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
    /// host's .normal). Backspace removes last `typed` char, or goes
    /// back to `.searchTyping` if empty (re-edit query). Enter
    /// swallowed (commit happens by typing the full label).
    /// Host-agnostic — shared between TAP and SCROLL.
    private func handleSearchPicking(matches: [SearchMatch], typed: String,
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
                setSearchPhase(.typing(buffer: ""))
                SearchOverlay.shared.hide()
                renderModeHUD()
            } else {
                var next = typed
                next.removeLast()
                setSearchPhase(.picking(matches: matches, typed: next))
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
        setSearchPhase(.picking(matches: matches, typed: next))
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
        // Synthesized .mouseMoved instead of CGWarpMouseCursorPosition
        // so the destination view sees the move and updates the
        // cursor shape (I-beam over text) + hover state (button
        // highlight / link underline / tooltip). CGWarp would move
        // the pixel but skip the event pipeline, leaving the view
        // still rendering the previous-location cursor.
        MouseSynth.warp(to: landing)
        setSearchPhase(nil)   // back to host's .normal

        // Host-specific follow-up:
        switch mode {
        case .tap:
            // Re-hint: cursor moved → hover state may have changed,
            // hint targets may no longer be exactly where they were.
            // Even non-sticky re-scans here — the user just did a
            // search, presumably they want to keep going (maybe drag
            // the text with bare v next).
            scheduleStickyRehint()
        case .scroll(let c):
            // Restore the scroll-area picker overlay. Cursor warp may
            // have moved out of the previously-selected area; the
            // existing controller state still points at the old area
            // index, which is fine — user can press a number key to
            // switch if they want, or scroll where the cursor now is.
            c.showOverlay()
            renderModeHUD()
        default:
            break
        }
    }

    /// Esc inside search or empty-buffer Backspace → cancel back to
    /// host's `.normal` with the host's main overlay restored.
    /// Host-agnostic — works for TAP (restores hint overlay) and
    /// SCROLL (restores scroll-area picker).
    private func cancelSearch() {
        SearchOverlay.shared.hide()
        setSearchPhase(nil)
        switch mode {
        case .tap(let h):
            h.showOverlay()
        case .scroll(let c):
            c.showOverlay()
        default:
            break
        }
        renderModeHUD()
    }

    // MARK: - SCROLL mode

    /// SCROLL mode keystrokes. (Esc exits to OFF; Caps Lock → TAP are
    /// both handled in HotkeyTap's F19 arm layer, not here.) j/k drive
    /// the ScrollController (continuous on hold); number keys switch
    /// the selected area.
    private func handleScroll(controller: ScrollController, keyCode: Int, flags: CGEventFlags) -> Bool {
        // SCROLL routes keys based on the active sub-state, mirroring
        // TAP's structure. Search sub-states use the shared
        // host-agnostic handlers; .normal has SCROLL's own keymap
        // (d/u scroll, hjkl cursor, c click, gg/G jump, numbers area).
        switch scrollSub {
        case .normal:
            return handleScrollNormal(controller: controller, keyCode: keyCode, flags: flags)
        case .searchTyping(let buffer):
            return handleSearchTyping(buffer: buffer, keyCode: keyCode, flags: flags)
        case .searchSearching:
            return true   // transient — OCR in flight, swallow input
        case .searchPicking(let matches, let typed):
            return handleSearchPicking(matches: matches, typed: typed,
                                       keyCode: keyCode, flags: flags)
        }
    }

    private func handleScrollNormal(controller: ScrollController, keyCode: Int, flags: CGEventFlags) -> Bool {
        // bare `/` → enter the search-typing sub-state. Same gesture
        // and semantics as TAP's `/`: type query, Enter, pick label,
        // cursor warps to match. Cursor warp is precise teleport —
        // ideal companion to SCROLL's coarse d/u scrolling.
        let modMask: CGEventFlags = [.maskShift, .maskControl,
                                     .maskCommand, .maskAlternate]
        if keyCode == KeyCode.slash && flags.intersection(modMask).isEmpty {
            startScrollSearch(controller: controller)
            return true
        }

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
            controller.start(axis: .vertical, positive: true, fast: flags.contains(.maskShift))
            return true
        }
        if keyCode == KeyCode.u {
            controller.start(axis: .vertical, positive: false, fast: flags.contains(.maskShift))
            return true
        }
        // b / f → horizontal scroll left / right. Same `Axis` machinery
        // in ScrollController, just driving wheel2 instead of wheel1.
        // Mirrors the d/u letter rhythm on left-hand home row. Use
        // case: Finder column view, wide spreadsheets, Notion DB
        // tables, infinite-canvas tools (Figma, Miro) — scenarios
        // where horizontal pan was previously trackpad-only.
        if keyCode == KeyCode.b {
            controller.start(axis: .horizontal, positive: false, fast: flags.contains(.maskShift))
            return true
        }
        if keyCode == KeyCode.f {
            controller.start(axis: .horizontal, positive: true, fast: flags.contains(.maskShift))
            return true
        }

        // h/j/k/l → move the cursor (Shift fast / Option slow) — SAME
        // keys as TAP (unified, vim hjkl). j/k are free for move here
        // because SCROLL scrolls with d/u. Double-tap → 1/4-screen
        // jump goes through the same helper as TAP so the gesture is
        // consistent across modes.
        if let dir = Self.moveDirection(for: keyCode) {
            if maybeJumpOnDoubleTap(direction: dir, flags: flags) { return true }
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
            if keyCode == KeyCode.d || keyCode == KeyCode.u
                || keyCode == KeyCode.b || keyCode == KeyCode.f {
                controller.stop()           // stop continuous scroll (vertical or horizontal)
                return true
            }
            if let dir = Self.moveDirection(for: keyCode) {
                mover.stop()                // stop continuous cursor move (hjkl)
                // Record keyUp for double-tap → jump detection. Shared
                // dictionary with TAP (`lastTapHjklKeyUp`); 150ms window
                // naturally filters cross-mode chaining (Caps Lock chord
                // to switch modes always takes >150ms).
                lastTapHjklKeyUp[dir] = CFAbsoluteTimeGetCurrent()
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
            if let dir = Self.moveDirection(for: keyCode) {
                mover.stop()
                // Record keyUp time for double-tap → jump detection
                // (only in normal sub-state; drag wants every press
                // to extend the drag, not jump).
                if case .normal = tapSub {
                    lastTapHjklKeyUp[dir] = CFAbsoluteTimeGetCurrent()
                }
                return true
            }
            return false
        }
        if case .window(let controller) = mode {
            // hjkl release stops the corresponding edge resize and
            // records the timestamp for the next keyDown's double-
            // tap check.
            //
            // **Don't record the timestamp if the released press was
            // itself reversed** (it was the second tap of an hh/kk
            // pair). Otherwise: hh release at t=400, h press at
            // t=500 → 500-400=100 < 150ms window → wrongly treated
            // as a THIRD reverse tap chaining the previous hh.
            // Clearing the timestamp on a reversed release means the
            // next press falls outside the window and starts fresh.
            // Read isReversed BEFORE stopEdge (stopEdge clears it).
            if let edge = Self.windowEdge(for: keyCode) {
                let wasReversed = controller.isReversed(edge)
                controller.stopEdge(edge)
                if wasReversed {
                    lastWindowEdgeKeyUp[edge] = nil
                } else {
                    lastWindowEdgeKeyUp[edge] = CFAbsoluteTimeGetCurrent()
                }
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

    /// `hh` / `jj` / `kk` / `ll` (release-then-press within
    /// `windowReverseTapWindow` = 150ms) → discrete 1/4-screen jump
    /// in that direction. Returns true if a jump fired (caller skips
    /// the regular continuous mover.start). Refreshes the timestamp
    /// so OS key-repeat from a held second tap chains more jumps.
    ///
    /// Called from both TAP (handle's early intercept) and SCROLL
    /// (handleScrollNormal) so the gesture matches the modes.md §4/§5
    /// "hjkl unified across TAP and SCROLL" promise.
    private func maybeJumpOnDoubleTap(direction: MouseMover.Direction,
                                      flags: CGEventFlags = [],
                                      dragHeld: Bool = false) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard let lastUp = lastTapHjklKeyUp[direction],
              now - lastUp < windowReverseTapWindow else {
            return false
        }
        // Shift held during the second tap → **half-screen jump**;
        // unshifted → quarter-screen. Lets users dial big vs small
        // teleport off one gesture (Shift+hh = far, hh = medium)
        // without learning new keys. Option / Cmd / Ctrl don't
        // modify the jump distance — they have other semantics
        // elsewhere and would overload poorly here.
        let fraction: CGFloat = flags.contains(.maskShift) ? 0.5 : 0.25
        jumpCursor(direction: direction, fraction: fraction, dragHeld: dragHeld)
        lastTapHjklKeyUp[direction] = now
        return true
    }

    /// Teleport the cursor by `fraction` of the containing screen's
    /// dimension in the given direction. Uses the screen the cursor
    /// is currently on so multi-display setups jump within their
    /// active monitor (not a fixed reference). Clamps to that
    /// screen's bounds so we don't overshoot off-screen.
    ///
    /// Synthesizes `.mouseMoved` (via MouseSynth.warp) rather than
    /// a raw `CGWarpMouseCursorPosition` so the destination view
    /// sees an event and updates cursor shape / hover state — same
    /// reasoning as `/`-search commit.
    private func jumpCursor(direction: MouseMover.Direction, fraction: CGFloat,
                            dragHeld: Bool = false) {
        let current = MouseSynth.cursorPosition()
        // Pick the screen containing the cursor. Fallback to main
        // when cursor sits exactly on a boundary or off all screens.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(current) })
                    ?? NSScreen.main
                    ?? NSScreen.screens.first
        guard let s = screen else { return }
        let frame = s.frame
        var next = current
        switch direction {
        case .left:  next.x -= frame.width  * fraction
        case .right: next.x += frame.width  * fraction
        case .up:    next.y -= frame.height * fraction
        case .down:  next.y += frame.height * fraction
        }
        // Clamp to screen bounds. NSScreen.frame uses bottom-left
        // origin in screen coords, but MouseSynth.warp / cursor
        // position use top-left (CG convention). We're using NSScreen
        // only as a "what dimensions do I get to play with" measure,
        // so the orientation doesn't matter — both axes have the
        // same range. Clamp to a tight inset (3pt) so the cursor
        // never lands on the literal edge pixel.
        next.x = max(frame.minX + 3, min(frame.maxX - 3, next.x))
        next.y = max(frame.minY + 3, min(frame.maxY - 3, next.y))

        // Edge-case: cursor was already past the inset on this axis,
        // so the clamp pulled `next` back toward (or past) `current`.
        // Without this guard we'd warp REVERSE 1-2 px, producing the
        // "press jj near screen bottom and cursor jitters in place"
        // bug. Treat "didn't actually advance in the requested
        // direction" as no-op — gesture quietly maxes out at the edge.
        let advanced: Bool
        switch direction {
        case .left:  advanced = next.x < current.x - 0.5
        case .right: advanced = next.x > current.x + 0.5
        case .up:    advanced = next.y < current.y - 0.5
        case .down:  advanced = next.y > current.y + 0.5
        }
        guard advanced else {
            print("[mouseless] jumpCursor: at screen edge, no-op (direction=\(direction))")
            return
        }
        MouseSynth.warp(to: next, dragging: dragHeld)
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
            return handleSearchTyping(buffer: buffer, keyCode: keyCode, flags: flags)
        case .searchSearching:
            return true   // transient — OCR in flight, swallow input
        case .searchPicking(let matches, let typed):
            return handleSearchPicking(matches: matches, typed: typed,
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
            startTapSearch(hint: hint)
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
                //
                // **Skip the 100ms rehint on browser anchor commits**: a
                // `<a href>` click triggers a full-page navigation, the
                // new page's content script doesn't inject until
                // ~document_idle (200ms-2s later), and a list_hints at
                // 100ms would race that and hit content_script_unavailable
                // — leaving the user with just Dock + menubar hints
                // until the next signal. The extension's
                // `chrome.tabs.onUpdated status=complete` fires when nav
                // completes, sending page_changed → refreshInPlace; that's
                // the path that delivers the correct refresh. Same-page
                // anchors (#section), javascript: URLs, target=_blank,
                // and non-anchor hints aren't flagged `navigates` so they
                // still get the 100ms rehint.
                let isNavigating: Bool
                if case .browser(let nav)? = hint.lastCommittedTarget?.source, nav {
                    isNavigating = true
                } else {
                    isNavigating = false
                }
                if isNavigating {
                    print("[mouseless] sticky: skip 100ms rehint (link navigation, awaiting tabs.onUpdated)")
                } else {
                    scheduleStickyRehint()
                }
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
        case .scroll:
            // SCROLL label depends on the active sub-state, mirroring
            // TAP's layout. `/`-search shows the same `/`-prefixed
            // buffer / pick HUD so the search UX is identical across
            // hosts. Without this case dispatch, the user pressing
            // `/` in SCROLL gets no visible feedback (HUD stuck at
            // "SCROLL") and assumes nothing happened.
            switch scrollSub {
            case .normal:
                label = "SCROLL"
            case .searchTyping(let buffer):
                label = "/" + buffer
            case .searchSearching:
                label = "/ … searching"
            case .searchPicking(_, let typed):
                label = typed.isEmpty ? "/ pick label" : "/ pick: \(typed)"
            }
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
