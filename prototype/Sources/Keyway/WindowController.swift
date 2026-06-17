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
        //   - sizeDelta: total width/height change this tick
        //   - top/leftContribution: how much of sizeDelta came from
        //     the corresponding ANCHORED edge specifically (top→height,
        //     left→width). These drive Phase 2 origin movement.
        //
        // The contribution split matters when an anchored and a
        // non-anchored edge on the same axis are both held (e.g.
        // k+j growing both top and bottom). The ORIGIN should move
        // by only the anchored edge's share, not the whole size
        // change — otherwise k's "origin -= step" eats j's "bottom
        // -= step" and the bottom doesn't move.
        //
        // **Clamp-aware skip**: when a top/left edge is GROWING (s=+1)
        // and we've already detected a position clamp on its axis,
        // exclude its contribution. Without this skip, every tick at
        // the ceiling does `writeSize(bigger) → writePosition (clamped)
        // → writeSize(trimmed)` and the size-bigger-then-trimmed pair
        // creates a visible per-frame flicker. The clamp cache is
        // cleared on `stopEdge`, so re-pressing the key re-tries.
        var sizeDelta = CGSize.zero
        var topContribution: CGFloat = 0
        var leftContribution: CGFloat = 0
        for e in activeEdges {
            let s: CGFloat = reversedEdges.contains(e) ? -1 : 1
            // Clamp-suppressed: skip this edge ENTIRELY this tick
            // (don't add to sizeDelta AND don't contribute to origin
            // movement). The "I'm still wanting to move" thinking
            // was wrong — if the edge can't actually move, its
            // origin needs no compensating movement either; pretending
            // otherwise causes Phase 2 to write origin, OS to clamp,
            // Phase 3 to trim size — which would erase OTHER edges'
            // legitimate size growth.
            if e == .top, s > 0,
               let clampY = clampedOriginY,
               currentRect.origin.y <= clampY + 0.5 {
                continue
            }
            if e == .left, s > 0,
               let clampX = clampedOriginX,
               currentRect.origin.x <= clampX + 0.5 {
                continue
            }
            switch e {
            case .top:
                sizeDelta.height += step * s
                topContribution  += step * s
            case .bottom:
                sizeDelta.height += step * s
            case .left:
                sizeDelta.width  += step * s
                leftContribution += step * s
            case .right:
                sizeDelta.width  += step * s
            }
        }
        // Bail if nothing wants to happen on EITHER axis: size unchanged
        // AND no anchored origin movement. Pure-translation cases like
        // k+jj (top up + bottom up = window slides up, size unchanged)
        // still need to proceed even though sizeDelta is zero.
        if sizeDelta == .zero && topContribution == 0 && leftContribution == 0 {
            return
        }

        // Branch on direction. Anchored GROW (h or k pushing outward
        // from the corner away from the origin) needs **position-first**
        // — otherwise apps that constrain "right/bottom edge ≤ X"
        // (e.g. WeChat tying max width to display.right) reject our
        // writeSize because the intermediate state "old origin + new
        // bigger size" pushes the opposite edge past their limit.
        // Writing origin first moves the anchored edge in its intended
        // direction, then the size write keeps the opposite edge at
        // the same position (or moves it consistently with a
        // non-anchored contribution), never overshooting.
        //
        // Anchored SHRINK and non-anchored ops stay on the original
        // size-first path: that flow handles app-side min-size clamps
        // gracefully (writeSize refused → origin doesn't move → "stuck
        // at min", which matches native mouse-drag behavior).
        let anchoredGrowing = topContribution > 0 || leftContribution > 0
        if anchoredGrowing {
            tickPositionFirst(sizeDelta: sizeDelta,
                              topContribution: topContribution,
                              leftContribution: leftContribution)
        } else {
            tickSizeFirst(sizeDelta: sizeDelta,
                          topContribution: topContribution,
                          leftContribution: leftContribution)
        }
        onRectUpdate?(currentRect)
    }

    /// Position-first tick — for anchored grows (h/k or combinations
    /// that include them). Writes origin to where the anchored
    /// edge(s) should go, reads back to learn what the OS actually
    /// allowed (e.g. menu bar clamps origin.y to 23), then writes
    /// size based on **actual** origin movement so the opposite
    /// edge stays put (or moves consistently with non-anchored
    /// contributions). Avoids the intermediate "old origin + new
    /// size" state that some apps reject.
    private func tickPositionFirst(sizeDelta: CGSize, topContribution: CGFloat, leftContribution: CGFloat) {
        // 1. Compute and write the new origin. Only the anchored
        // axes contribute (top/left).
        var newOrigin = currentRect.origin
        if topContribution  != 0 { newOrigin.y = currentRect.origin.y - topContribution }
        if leftContribution != 0 { newOrigin.x = currentRect.origin.x - leftContribution }
        if newOrigin != currentRect.origin {
            AXWindowOps.writePosition(window, origin: newOrigin)
        }
        let postOrigin = AXWindowOps.readRect(window)
            ?? CGRect(origin: newOrigin, size: currentRect.size)

        // 2. How much did the origin actually move? OS may clamp
        // (menu bar, screen-left). Sign matches the contribution's
        // sign (positive contribution → origin moved in negative
        // direction → actualMove > 0).
        let actualTopMove  = currentRect.origin.y - postOrigin.origin.y
        let actualLeftMove = currentRect.origin.x - postOrigin.origin.x

        // 3. Compute target size:
        //    - Anchored contribution to size = actual origin movement
        //      (preserves opposite-edge invariant; if origin was
        //      OS-clamped, size grows by only the achieved movement).
        //    - Non-anchored contribution = its planned size delta
        //      (j/l's share of sizeDelta, which is sizeDelta minus
        //      the anchored portion).
        let bottomContribution = sizeDelta.height - topContribution
        let rightContribution  = sizeDelta.width  - leftContribution
        let newSize = CGSize(
            width:  currentRect.size.width  + actualLeftMove + rightContribution,
            height: currentRect.size.height + actualTopMove  + bottomContribution
        )
        // Soft min guard.
        if newSize.width < minSize.width || newSize.height < minSize.height {
            currentRect = postOrigin
            return
        }
        // Skip writeSize if no change intended (e.g., k+jj pure
        // translation: actualTopMove + bottomContribution = 0).
        let sizeChanged = abs(newSize.width  - currentRect.size.width)  > 0.5
                       || abs(newSize.height - currentRect.size.height) > 0.5
        if sizeChanged {
            AXWindowOps.writeSize(window, size: newSize)
        }
        let postSize = AXWindowOps.readRect(window) ?? CGRect(origin: postOrigin.origin, size: newSize)

        // 4. Clamp memory — let the next tick suppress this edge if
        //    we now know it's stuck against the OS (menu bar /
        //    screen-left). Only set on partial moves; clear on full
        //    moves (user shrunk away from the clamp, room re-appeared).
        if topContribution > 0 {
            if actualTopMove < topContribution - 0.5 {
                clampedOriginY = postOrigin.origin.y
            } else {
                clampedOriginY = nil
            }
        }
        if leftContribution > 0 {
            if actualLeftMove < leftContribution - 0.5 {
                clampedOriginX = postOrigin.origin.x
            } else {
                clampedOriginX = nil
            }
        }

        currentRect = postSize
    }

    /// Size-first tick — original flow, used for shrinks (anchored
    /// or not) and non-anchored grows. The "write size first, then
    /// origin tracking the actual size change" approach handles
    /// app-side min-size clamps cleanly: when writeSize refuses to
    /// shrink further, actualΔ=0 → origin doesn't move → gesture
    /// stops at the wall, mimicking native mouse drag.
    private func tickSizeFirst(sizeDelta: CGSize, topContribution: CGFloat, leftContribution: CGFloat) {
        // Phase 1 — write the SIZE first (if changing), then read back
        // what the app actually accepted.
        var postSize: CGRect = currentRect
        var actualHDelta: CGFloat = 0
        var actualWDelta: CGFloat = 0
        if sizeDelta != .zero {
            let intendedSize = CGSize(
                width:  currentRect.size.width  + sizeDelta.width,
                height: currentRect.size.height + sizeDelta.height
            )
            if intendedSize.width < minSize.width || intendedSize.height < minSize.height {
                return
            }
            guard AXWindowOps.writeSize(window, size: intendedSize) else { return }
            postSize = AXWindowOps.readRect(window) ?? CGRect(origin: currentRect.origin, size: intendedSize)
            actualHDelta = postSize.size.height - currentRect.size.height
            actualWDelta = postSize.size.width  - currentRect.size.width
        }

        // Phase 2 — move the origin by the ANCHORED EDGE's share of
        // the actual size change. Proportional scaling handles app-
        // side size clamps; the contribution is shrinking-direction
        // here (or zero), so origin moves toward the opposite edge.
        var newOrigin = postSize.origin
        if topContribution != 0 {
            let actualTopContribution: CGFloat
            if sizeDelta.height == 0 {
                actualTopContribution = topContribution
            } else {
                actualTopContribution = topContribution * (actualHDelta / sizeDelta.height)
            }
            newOrigin.y = currentRect.origin.y - actualTopContribution
        }
        if leftContribution != 0 {
            let actualLeftContribution: CGFloat
            if sizeDelta.width == 0 {
                actualLeftContribution = leftContribution
            } else {
                actualLeftContribution = leftContribution * (actualWDelta / sizeDelta.width)
            }
            newOrigin.x = currentRect.origin.x - actualLeftContribution
        }
        if newOrigin != postSize.origin {
            AXWindowOps.writePosition(window, origin: newOrigin)
        }
        let postPos = AXWindowOps.readRect(window) ?? CGRect(origin: newOrigin, size: postSize.size)

        // Phase 3 — the INVERSE clamp: position may have been clamped.
        // Trim size by the amount origin was held back so the opposite
        // edge stays anchored. (Mostly relevant in size-first GROW
        // cases — now rare since position-first handles those — but
        // still possible if a shrink's compensating origin write got
        // clamped for some reason.)
        var trimmedSize = postPos.size
        var trimNeeded = false
        if topContribution != 0 {
            let yHeldBack = postPos.origin.y - newOrigin.y
            if yHeldBack > 0.5 {
                trimmedSize.height -= yHeldBack
                trimNeeded = true
                clampedOriginY = postPos.origin.y
            } else if newOrigin.y < currentRect.origin.y - 0.5 {
                clampedOriginY = nil
            }
        }
        if leftContribution != 0 {
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
    }
}
