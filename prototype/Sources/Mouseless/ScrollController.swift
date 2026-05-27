import Cocoa
import ApplicationServices

/// Drives synthesized scrolling for SCROLL mode.
///
/// macOS delivers scroll-wheel events to the view under the **cursor**,
/// not the keyboard-focused element — so before scrolling we warp the
/// cursor onto the target region. S2 targets the focused window's
/// center; S3 will replace that with the chosen AXScrollArea.
///
/// Continuous scroll is driven by our own ~60fps timer (smooth, fires
/// immediately) rather than the OS key-repeat (which has a startup
/// delay and a chunky cadence). keyDown starts the timer, keyUp stops it.
///
/// See `specs/scroll-mode-design.md` §6.
@MainActor
final class ScrollController {
    /// Pixels scrolled per tick. Tuned by feel; expose later if needed.
    private let normalDelta = 30
    private let fastDelta = 90
    private let tickInterval: TimeInterval = 1.0 / 60.0

    private var timer: Timer?
    private var directionDown = true   // true = scroll page down (see lower content)
    private var fast = false

    /// Called on entering SCROLL mode. Warps the cursor onto the target
    /// region so subsequent scroll events route there. S2: focused
    /// window center.
    func enter() {
        guard let center = Self.focusedWindowCenter() else {
            print("[mouseless] scroll: no focused window rect — cursor not warped")
            return
        }
        CGWarpMouseCursorPosition(center)
        print("[mouseless] scroll: warped cursor to window center (\(Int(center.x)),\(Int(center.y)))")
    }

    /// Begin (or update) continuous scrolling. Idempotent under OS
    /// key-repeat — repeated keyDowns just refresh direction/speed.
    func start(directionDown: Bool, fast: Bool) {
        self.directionDown = directionDown
        self.fast = fast
        if timer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
                MainActor.assumeIsolated { self.tick() }
            }
            // .common so it keeps firing during tracking loops.
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        tick()   // immediate first scroll, no wait for the first interval
    }

    /// Stop continuous scrolling (j/k released, or mode exit).
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let magnitude = fast ? fastDelta : normalDelta
        // wheel1 sign: negative scrolls the page DOWN (reveals lower
        // content) in the default convention. If j/k feel inverted on
        // some setup, flip here.
        let deltaY = directionDown ? -magnitude : magnitude
        postScroll(deltaY: deltaY)
    }

    private func postScroll(deltaY: Int) {
        guard let src = CGEventSource(stateID: .privateState),
              let ev = CGEvent(scrollWheelEvent2Source: src,
                               units: .pixel, wheelCount: 1,
                               wheel1: Int32(deltaY), wheel2: 0, wheel3: 0)
        else { return }
        // Mark synthetic so HotkeyTap's callback ignores it (no feedback).
        ev.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
        ev.post(tap: .cghidEventTap)
    }

    // MARK: - Focused window center (S2 placeholder for S3's area pick)

    private static func focusedWindowCenter() -> CGPoint? {
        guard let (app, _) = FocusedApp.current() else { return nil }
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &winRef) == .success,
              let win = winRef else { return nil }
        let windowEl = win as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowEl, "AXPosition" as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(windowEl, "AXSize" as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }
}
