import Cocoa
import ApplicationServices

/// Continuous window-resize driver for `.window` mode. Tracks which
/// edges (h/j/k/l) are currently held, samples Shift each tick (Shift
/// → shrink instead of expand), and applies the deltas via direct AX
/// writes to `AXPosition` / `AXSize`. The mode-entry gate in
/// `VimSession.enterWindowMode` guarantees both attributes are
/// writable AND the window has a real title bar (`AXWindowOps`'s
/// `isResizable` + `hasTitleBarButton`), so we don't carry a fallback
/// path here.
///
/// Edge math: expanding the top or left edge moves the origin AND
/// grows the size; expanding bottom or right just grows the size.
/// Shrink negates everything. Corner = two edges held — deltas add
/// naturally (top-left expand = origin moves up-left, size grows by
/// step on both axes). Contradictory pairs ({top, bottom},
/// {left, right}) cancel by construction (both ±step on the same
/// axis) — the window doesn't move that tick.
@MainActor
final class WindowController {
    enum Edge { case top, bottom, left, right }

    private let window: AXUIElement
    private(set) var currentRect: CGRect
    private var activeEdges: Set<Edge> = []
    private var timer: Timer?

    private let stepPerTick: CGFloat = 20      // pixels per tick at 60fps
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
        }
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
        activeEdges = []
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
        let shrink = NSEvent.modifierFlags.contains(.shift)
        let s: CGFloat = shrink ? -1 : 1
        let step = stepPerTick

        var newRect = currentRect
        for e in activeEdges {
            switch e {
            case .top:    newRect.origin.y -= step * s; newRect.size.height += step * s
            case .bottom:                               newRect.size.height += step * s
            case .left:   newRect.origin.x -= step * s; newRect.size.width  += step * s
            case .right:                                newRect.size.width  += step * s
            }
        }
        // Soft min guard at our side — the app will clamp anyway, but
        // stopping the write when our intended size goes below sensible
        // keeps the in-memory rect from drifting wildly beneath what the
        // app actually shows.
        if newRect.size.width < minSize.width || newRect.size.height < minSize.height {
            return
        }
        if AXWindowOps.writeRect(window, rect: newRect) {
            currentRect = newRect
            onRectUpdate?(currentRect)
        }
    }
}
