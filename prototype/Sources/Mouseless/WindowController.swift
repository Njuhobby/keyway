import Cocoa
import ApplicationServices

/// Continuous window-resize driver for `.window` mode. Tracks which
/// edges (h/j/k/l) are currently held AND each held edge's direction
/// (expand outward vs shrink inward). Each tick reads modifier flags
/// live and applies the deltas via direct AX writes to `AXPosition` /
/// `AXSize`:
///
///   - bare hjkl: **expand** that edge outward, normal step (20pt/tick).
///   - **double-tap** (jj/kk/hh/ll): **shrink** that edge inward —
///     reversal is per-edge and detected upstream in `VimSession`
///     (last-keyUp time vs current keyDown < 300ms = double-tap).
///     `startEdge(_:reversed:)`'s `reversed` parameter carries the
///     verdict in.
///   - **Shift**: fast step (80pt/tick, 4×) — mirrors MOVE / hjkl
///     in TAP, where Shift is the standard "accelerate" modifier.
///   - **Option**: precision step (5pt/tick) — same as everywhere else.
///   - **Shift + Option**: Option wins (slow) — matches
///     `MouseMover.moveSpeed` / `WindowMoveController`'s precedence:
///     a panicked Shift+Option goes slow, not fast.
///
/// The mode-entry gate in `VimSession.enterWindowMode` guarantees both
/// AX attrs are writable AND the window has a real title bar
/// (`AXWindowOps`'s `isResizable` + `hasTitleBarButton`), so we don't
/// carry a fallback path here.
///
/// Edge math: expanding the top or left edge moves the origin AND
/// grows the size; expanding bottom or right just grows the size.
/// Shrink negates everything (per edge — `reversedEdges` membership
/// flips `s` from +1 to -1 for that edge only). Corner = two edges
/// held — deltas add naturally (top-left expand = origin moves
/// up-left, size grows by step on both axes). Contradictory pairs
/// ({top, bottom}, {left, right}) cancel by construction (both
/// ±step on the same axis) — the window doesn't move that tick.
///
/// **Why double-tap instead of Shift for reverse**: Shift = accelerate
/// is the standing convention across TAP-hjkl, SCROLL-d/u, and
/// MOVE-hjkl. Earlier this mode broke that — Shift meant "reverse" —
/// which (a) felt foreign next to the rest of the app, (b) forfeited
/// any way to actually accelerate resize. Per-edge double-tap encodes
/// reversal directionally (the user thinks "this edge: out vs back")
/// and keeps Shift free for fast.
@MainActor
final class WindowController {
    enum Edge { case top, bottom, left, right }

    private let window: AXUIElement
    private(set) var currentRect: CGRect
    private var activeEdges: Set<Edge> = []
    /// Edges that should shrink instead of expand this hold. Set on
    /// `startEdge(_:reversed: true)` (caller detected double-tap),
    /// cleared on `stopEdge`. Per-edge so a user can hold k expanding
    /// and double-tap j to shrink the bottom — they don't have to
    /// share a global "reverse" flag.
    private var reversedEdges: Set<Edge> = []
    /// Sticky clamp memory: once we detect that an anchored origin
    /// write was held back (top edge hit the menu bar / left edge hit
    /// the screen-left), remember the clamped y/x. Subsequent ticks
    /// see the user trying to grow past it and skip the whole
    /// 3-phase write dance, which otherwise produces a per-tick
    /// visible flicker (writeSize bigger → writePosition clamped →
    /// writeSize trimmed back, all in one tick × 60/sec). Cleared
    /// when the corresponding edge releases, so a re-press gets a
    /// fresh attempt (the user may have moved the window externally).
    private var clampedOriginY: CGFloat? = nil
    private var clampedOriginX: CGFloat? = nil
    private var timer: Timer?

    private let normalStep: CGFloat = 20   // pixels per tick at 60fps
    private let fastStep: CGFloat = 80     // Shift → 4× (matches MOVE / TAP-hjkl)
    private let slowStep: CGFloat = 5      // Option → precision (smaller step)
    private let tickInterval: TimeInterval = 1.0 / 60.0
    private let minSize: CGSize = CGSize(width: 200, height: 120)

    /// Called every tick after currentRect changes — VimSession wires
    /// this to the overlay so the blue border tracks the resize.
    var onRectUpdate: ((CGRect) -> Void)?

    init(window: AXUIElement, initialRect: CGRect) {
        self.window = window
        self.currentRect = initialRect
    }

    /// Start (or re-up) continuous resize for `edge`. Idempotent under
    /// OS key-repeat. `reversed: true` means shrink this edge instead
    /// of expand — caller (`VimSession.handleWindow`) sets this when
    /// the keyDown is the second of a double-tap (jj/kk/hh/ll within
    /// 300ms).
    ///
    /// **Reversed state is latched on the first keyDown of a hold.**
    /// OS key-repeat fires repeated keyDowns while the user holds
    /// (typically every ~30ms after a ~500ms initial delay); each one
    /// re-enters `VimSession.handleWindow` which re-computes
    /// `reversed` from `now - lastWindowEdgeKeyUp[edge]`. By the time
    /// the first repeat fires, that delta is well past the 300ms
    /// double-tap window, so the caller's `reversed` arg becomes
    /// `false` — and the user's deliberate "shrink this edge" hold
    /// would silently flip back to "grow" mid-press. The fix is here,
    /// not at the caller: only honor `reversed` when this is a NEW
    /// edge press (not already in `activeEdges`).
    func startEdge(_ edge: Edge, reversed: Bool) {
        let isFirstPress = !activeEdges.contains(edge)
        activeEdges.insert(edge)
        if isFirstPress {
            if reversed { reversedEdges.insert(edge) }
            else        { reversedEdges.remove(edge) }
        }
        // Else: OS key-repeat — preserve whatever reversed state we
        // latched on the first press for this hold.
        ensureTimer()
    }

    func stopEdge(_ edge: Edge) {
        activeEdges.remove(edge)
        reversedEdges.remove(edge)
        // Clear the per-axis clamp tied to this edge — a fresh press
        // should re-detect (the user may have moved the window or the
        // app's constraints may have changed).
        if edge == .top  { clampedOriginY = nil }
        if edge == .left { clampedOriginX = nil }
        if activeEdges.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Used by `VimSession`'s keyUp handler to know whether the just-
    /// released press was a double-tap (reversed) one. Caller must
    /// query this BEFORE `stopEdge` runs — `stopEdge` clears the
    /// reversed state.
    func isReversed(_ edge: Edge) -> Bool {
        return reversedEdges.contains(edge)
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
        activeEdges = []
        reversedEdges = []
        clampedOriginY = nil
        clampedOriginX = nil
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()   // immediate first step
    }

    private func tick() {
        guard !activeEdges.isEmpty else { return }
        let flags = NSEvent.modifierFlags
        // Speed: Option (slow) > Shift (fast) > none (normal). Option
        // beats Shift on purpose — accidentally hitting both should
        // err on the side of "precise", not "fly off the screen".
        let step: CGFloat
        if flags.contains(.option) { step = slowStep }
        else if flags.contains(.shift) { step = fastStep }
        else { step = normalStep }

        // Decompose the per-edge contributions into:
        //   - sizeDelta: how much width/height should change this tick
        //   - top/leftActive: do the corresponding "anchored" edges
        //     have a position component that needs to track size?
        // Top and left edges anchor on the bottom/right side respectively:
        // when the top edge moves, the bottom must stay put, so origin.y
        // changes in lockstep with size.height. Bottom and right edges
        // are origin-fixed — only size changes.
        //
        // **Clamp-aware skip**: when a top/left edge is GROWING (s=+1)
        // and we've already detected a position clamp on its axis,
        // exclude its contribution. Without this skip, every tick at
        // the ceiling does `writeSize(bigger) → writePosition (clamped)
        // → writeSize(trimmed)` and the size-bigger-then-trimmed pair
        // creates a visible per-frame flicker. The clamp cache is
        // cleared on `stopEdge`, so re-pressing the key re-tries.
        var sizeDelta = CGSize.zero
        var topActive = false
        var leftActive = false
        for e in activeEdges {
            let s: CGFloat = reversedEdges.contains(e) ? -1 : 1
            if e == .top, s > 0,
               let clampY = clampedOriginY,
               currentRect.origin.y <= clampY + 0.5 {
                topActive = true  // still mark "wants to move" for phase 2 logic
                continue          // but contribute 0 to sizeDelta
            }
            if e == .left, s > 0,
               let clampX = clampedOriginX,
               currentRect.origin.x <= clampX + 0.5 {
                leftActive = true
                continue
            }
            switch e {
            case .top:    sizeDelta.height += step * s; topActive  = true
            case .bottom: sizeDelta.height += step * s
            case .left:   sizeDelta.width  += step * s; leftActive = true
            case .right:  sizeDelta.width  += step * s
            }
        }
        // If nothing wants to change anything this tick (all active
        // edges are stuck against clamps and none contribute), bail
        // out entirely — no IPC, no flicker.
        if sizeDelta == .zero { return }
        let intendedSize = CGSize(
            width:  currentRect.size.width  + sizeDelta.width,
            height: currentRect.size.height + sizeDelta.height
        )
        // Soft min guard at our side — the app will clamp anyway, but
        // stopping the write when our intended size goes below sensible
        // keeps the in-memory rect from drifting wildly beneath what the
        // app actually shows.
        if intendedSize.width < minSize.width || intendedSize.height < minSize.height {
            return
        }

        // Phase 1 — write the SIZE first, then read back what the app
        // actually accepted. This is the critical step for clamp-prone
        // apps (DingTalk / Electron / anything with internal min-size
        // constraints): the size write may succeed at the AX layer
        // while the app silently caps the actual visible size.
        guard AXWindowOps.writeSize(window, size: intendedSize) else { return }
        let postSize = AXWindowOps.readRect(window) ?? CGRect(origin: currentRect.origin, size: intendedSize)
        let actualHDelta = postSize.size.height - currentRect.size.height
        let actualWDelta = postSize.size.width  - currentRect.size.width

        // Phase 2 — move the origin by the AMOUNT THE SIZE ACTUALLY
        // CHANGED, not by our intended delta. For top/left active edges
        // this keeps the opposite edge pinned in place even when the
        // app clamps the size. Handles the "shrink past app's min →
        // window slides" bug: actualHDelta is 0 when size clamps →
        // origin doesn't move → gesture stops cleanly.
        var newOrigin = postSize.origin
        if topActive  { newOrigin.y = currentRect.origin.y - actualHDelta }
        if leftActive { newOrigin.x = currentRect.origin.x - actualWDelta }
        if newOrigin != postSize.origin {
            AXWindowOps.writePosition(window, origin: newOrigin)
        }
        let postPos = AXWindowOps.readRect(window) ?? CGRect(origin: newOrigin, size: postSize.size)

        // Phase 3 — the INVERSE clamp: position may have been clamped
        // (top edge hit the menu bar / screen ceiling, left edge hit
        // the screen left). Size grew to intendedSize successfully,
        // but origin couldn't move the full distance to keep the
        // opposite edge anchored → window grows DOWNWARD/RIGHTWARD
        // past where it should. Detect via origin discrepancy, trim
        // size by the amount origin was held back.
        var trimmedSize = postPos.size
        var trimNeeded = false
        if topActive {
            // newOrigin.y is what we asked for; postPos.origin.y is
            // what the OS allowed. If OS held it BACK (higher y =
            // more toward bottom = couldn't go up far enough), the
            // size needs to shrink by that gap.
            let yHeldBack = postPos.origin.y - newOrigin.y
            if yHeldBack > 0.5 {
                trimmedSize.height -= yHeldBack
                trimNeeded = true
                clampedOriginY = postPos.origin.y   // remember for future ticks
            } else if newOrigin.y < currentRect.origin.y - 0.5 {
                // Origin successfully moved up — any prior clamp is
                // stale (e.g., user shrunk first and is now growing
                // again with room to spare).
                clampedOriginY = nil
            }
        }
        if leftActive {
            let xHeldBack = postPos.origin.x - newOrigin.x
            if xHeldBack > 0.5 {
                trimmedSize.width -= xHeldBack
                trimNeeded = true
                clampedOriginX = postPos.origin.x
            } else if newOrigin.x < currentRect.origin.x - 0.5 {
                clampedOriginX = nil
            }
        }
        if trimNeeded {
            AXWindowOps.writeSize(window, size: trimmedSize)
            currentRect = AXWindowOps.readRect(window) ?? CGRect(origin: postPos.origin, size: trimmedSize)
        } else {
            currentRect = postPos
        }
        onRectUpdate?(currentRect)
    }
}
