import Cocoa
import ApplicationServices

/// Continuous window translation driver for `.windowMove` mode.
/// Mirror of `WindowController`'s structure but for *position only*:
/// the timer writes `AXPosition` each tick (one IPC vs writeRect's
/// two, since size doesn't change). Direction encoding is the same
/// as MouseMover / SCROLL / WINDOW resize (h=left, j=down, k=up,
/// l=right), so the user's muscle memory carries over.
///
/// Three speeds (read live from `NSEvent.modifierFlags` each tick, so
/// toggling a modifier mid-hold switches gears without releasing
/// hjkl), Option > Shift in priority — same pattern as
/// `MouseMover.moveSpeed`:
///
///   - bare: normal (20pt/tick)
///   - **Shift**: fast (80pt/tick) — cross-screen reposition
///   - **Option**: slow (5pt/tick) — precision alignment to other
///     windows / screen edges
///
/// Diagonal motion is implicit: holding two compatible directions
/// (e.g. h + j) just sums the per-axis deltas (window moves down-
/// left). Opposite holds (h + l, j + k) cancel naturally.
///
/// The entry gate in `VimSession.enterWindowMove` already filtered
/// out Desktop / fullscreen / AX-not-writable windows, so this
/// controller doesn't carry a fallback path.
@MainActor
final class WindowMoveController {
    enum Direction { case left, right, up, down }

    private let window: AXUIElement
    private(set) var currentRect: CGRect
    private var activeDirections: Set<Direction> = []
    private var timer: Timer?

    private let normalStep: CGFloat = 20    // pixels per tick at 60fps
    private let fastStep: CGFloat = 80      // Shift held → fast (4×)
    private let slowStep: CGFloat = 5       // Option held → slow (precision)
    private let tickInterval: TimeInterval = 1.0 / 60.0

    /// Called every tick after currentRect changes — VimSession wires
    /// this to the overlay so the blue border tracks the move.
    var onRectUpdate: ((CGRect) -> Void)?

    init(window: AXUIElement, initialRect: CGRect) {
        self.window = window
        self.currentRect = initialRect
    }

    /// Start (or re-up) continuous move in `direction`. Idempotent
    /// under OS key-repeat. Speed (Shift fast / bare normal) is
    /// sampled live each tick.
    func startDirection(_ direction: Direction) {
        activeDirections.insert(direction)
        ensureTimer()
    }

    func stopDirection(_ direction: Direction) {
        activeDirections.remove(direction)
        if activeDirections.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
        activeDirections = []
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
        guard !activeDirections.isEmpty else { return }
        let flags = NSEvent.modifierFlags
        // Option > Shift (same precedence as MouseMover.moveSpeed) so
        // a panicked Shift+Option still goes slow, not fast.
        let step: CGFloat
        if flags.contains(.option) { step = slowStep }
        else if flags.contains(.shift) { step = fastStep }
        else { step = normalStep }

        var dx: CGFloat = 0
        var dy: CGFloat = 0
        for d in activeDirections {
            switch d {
            case .left:  dx -= step
            case .right: dx += step
            case .up:    dy -= step    // AX top-left origin: up = -y
            case .down:  dy += step
            }
        }
        var newRect = currentRect
        newRect.origin.x += dx
        newRect.origin.y += dy
        if AXWindowOps.writePosition(window, origin: newRect.origin) {
            currentRect = newRect
            onRectUpdate?(currentRect)
        }
    }
}
