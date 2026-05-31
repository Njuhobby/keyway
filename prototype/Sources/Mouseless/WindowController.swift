import Cocoa
import ApplicationServices

/// Continuous window-resize driver for `.window` mode. Tracks which
/// edges (h/j/k/l) are currently held, samples Shift each tick (Shift
/// → shrink instead of expand), and applies the deltas via one of two
/// paths chosen at mode entry:
///
///   - **AX direct write** (`useAX == true`): writes `AXPosition` /
///     `AXSize` each tick. Instant, no animation, predictable. Works
///     on apps whose AX exposes those attributes as writable (most
///     native AppKit).
///   - **Synth mouse-edge drag** (`useAX == false`): synthesizes a
///     leftMouseDown at the relevant border / corner of the window
///     and drives a `.leftMouseDragged` per tick in the resize
///     direction. Slower (the app sees the same events it would for
///     a real mouse-edge drag), but works on apps where AX position/
///     size aren't writable. Re-grabs when the held-edge set changes
///     (single edge ↔ corner) so the OS knows what we're grabbing.
///
/// Edge math is the standard window-resize convention: expanding the
/// top or left edge moves the origin AND grows the size; expanding
/// bottom or right just grows the size. Shrink negates everything.
/// Corner = two edges held — deltas add naturally (top-left expand =
/// origin moves up-left, size grows). Contradictory pairs ({top,
/// bottom}, {left, right}) zero out — windows can't grow two
/// opposite directions at once from one drag; in fallback we just
/// keep the previous anchor and skip the move that tick.
@MainActor
final class WindowController {
    enum Edge { case top, bottom, left, right }

    private let window: AXUIElement
    private let useAX: Bool
    private(set) var currentRect: CGRect
    private var activeEdges: Set<Edge> = []
    private var timer: Timer?

    // Fallback-only state: where the synthesized mouseDown lives + which
    // edge set produced that anchor. When activeEdges changes the anchor
    // may need to move (single edge ↔ corner ↔ other edge), so we
    // mouseUp/mouseDown to re-grab.
    private var dragAnchorEdges: Set<Edge>?
    private var dragCursor: CGPoint = .zero

    private let stepPerTick: CGFloat = 20      // pixels per tick at 60fps
    private let tickInterval: TimeInterval = 1.0 / 60.0
    private let minSize: CGSize = CGSize(width: 200, height: 120)

    /// Called every tick after currentRect changes — VimSession wires
    /// this to the overlay so the blue border tracks the resize.
    var onRectUpdate: ((CGRect) -> Void)?

    init(window: AXUIElement, useAX: Bool, initialRect: CGRect) {
        self.window = window
        self.useAX = useAX
        self.currentRect = initialRect
    }

    var path: String { useAX ? "AX" : "synth-drag" }

    /// Start (or re-up) continuous resize for `edge`. Idempotent under
    /// OS key-repeat. Shrink direction is sampled live from Shift each
    /// tick (`NSEvent.modifierFlags`), so releasing/pressing Shift mid-
    /// hold flips direction without needing to release the hjkl key.
    func startEdge(_ edge: Edge) {
        activeEdges.insert(edge)
        ensureTimer()
    }

    func stopEdge(_ edge: Edge) {
        activeEdges.remove(edge)
        if activeEdges.isEmpty {
            timer?.invalidate()
            timer = nil
            releaseFallbackDrag()
        }
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
        activeEdges = []
        releaseFallbackDrag()
    }

    // MARK: - Tick

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
        let shrink = NSEvent.modifierFlags.contains(.shift)
        let s: CGFloat = shrink ? -1 : 1
        let step = stepPerTick

        if useAX {
            // Direct AX write: position + size deltas.
            var newRect = currentRect
            for e in activeEdges {
                switch e {
                case .top:    newRect.origin.y -= step * s; newRect.size.height += step * s
                case .bottom:                               newRect.size.height += step * s
                case .left:   newRect.origin.x -= step * s; newRect.size.width  += step * s
                case .right:                                newRect.size.width  += step * s
                }
            }
            // Soft min guard at our side — the app will clamp anyway,
            // but stopping the write when our intended size goes below
            // sensible keeps the in-memory rect from drifting wildly
            // beneath what the app actually shows.
            if newRect.size.width < minSize.width || newRect.size.height < minSize.height {
                return
            }
            if AXWindowOps.writeRect(window, rect: newRect) {
                currentRect = newRect
                onRectUpdate?(currentRect)
            }
            return
        }

        // Fallback: synth mouse-edge drag.
        let neededAnchorEdges = anchorEdgeSet(for: activeEdges)
        if let edgesForAnchor = neededAnchorEdges {
            if dragAnchorEdges != edgesForAnchor {
                // Either no drag yet or edge set changed → re-grab.
                releaseFallbackDrag()
                let anchor = anchorPoint(for: edgesForAnchor, in: currentRect)
                CGWarpMouseCursorPosition(anchor)
                MouseSynth.dragDown(at: anchor)
                dragAnchorEdges = edgesForAnchor
                dragCursor = anchor
            }
        } else {
            // Contradictory pair (top+bottom or left+right). Don't move
            // this tick — keep existing anchor for when one side is
            // released and we're back to a sensible edge set.
            return
        }

        var cdx: CGFloat = 0, cdy: CGFloat = 0
        for e in activeEdges {
            switch e {
            case .top:    cdy -= step * s
            case .bottom: cdy += step * s
            case .left:   cdx -= step * s
            case .right:  cdx += step * s
            }
        }
        let newCursor = CGPoint(x: dragCursor.x + cdx, y: dragCursor.y + cdy)
        MouseSynth.dragMove(to: newCursor)
        dragCursor = newCursor

        // Read the actual rect back so the overlay tracks reality (the
        // app decides what the drag did — we can't predict it).
        if let r = AXWindowOps.readRect(window) {
            currentRect = r
            onRectUpdate?(currentRect)
        }
    }

    /// Returns `nil` for contradictory edge sets ({top,bottom} or
    /// {left,right}) — caller skips the move. Otherwise returns the
    /// canonical "anchor edges" we'd grab in fallback mode (subset of
    /// activeEdges that determines the anchor point: just edges that
    /// can co-exist).
    private func anchorEdgeSet(for edges: Set<Edge>) -> Set<Edge>? {
        let top = edges.contains(.top)
        let bottom = edges.contains(.bottom)
        let left = edges.contains(.left)
        let right = edges.contains(.right)
        if top && bottom { return nil }
        if left && right { return nil }
        var out: Set<Edge> = []
        if top { out.insert(.top) }
        if bottom { out.insert(.bottom) }
        if left { out.insert(.left) }
        if right { out.insert(.right) }
        return out
    }

    /// Compute the anchor point: edge midpoint (single edge) or corner
    /// (two compatible edges). The inset keeps us just inside the
    /// window so the OS hit-tests its resize handle, not the desktop
    /// behind.
    private func anchorPoint(for edges: Set<Edge>, in rect: CGRect) -> CGPoint {
        let inset: CGFloat = 4
        let x: CGFloat
        if edges.contains(.left)  { x = rect.minX + inset }
        else if edges.contains(.right) { x = rect.maxX - inset }
        else                            { x = rect.midX }
        let y: CGFloat
        if edges.contains(.top)    { y = rect.minY + inset }
        else if edges.contains(.bottom) { y = rect.maxY - inset }
        else                             { y = rect.midY }
        return CGPoint(x: x, y: y)
    }

    private func releaseFallbackDrag() {
        guard dragAnchorEdges != nil else { return }
        MouseSynth.dragUp(at: dragCursor)
        dragAnchorEdges = nil
    }
}
