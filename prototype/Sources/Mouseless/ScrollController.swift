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

    private var areas: [ScrollAreaDetector.Area] = []
    private var selectedIndex = 0

    /// Called on entering SCROLL mode. Detects scroll areas, picks the
    /// one nearest the cursor, warps the cursor into it, and shows the
    /// numbered picker overlay. Falls back to the focused window center
    /// when AX exposes no scroll areas (zero-AX apps).
    ///
    /// Returns `false` if there's **no focused window at all** (no
    /// scroll areas AND no window rect) — most often when the user
    /// just Cmd+Tab'd to an app whose windows are all minimized /
    /// hidden / on another Space. The caller should HUD-note + exit
    /// rather than leaving SCROLL active on a target-less state.
    @discardableResult
    func enter() -> Bool {
        areas = ScrollAreaDetector.detect()
        if areas.isEmpty {
            // Fallback: window center, no overlay (nothing to pick).
            if let center = Self.focusedWindowCenter() {
                CGWarpMouseCursorPosition(center)
                print("[mouseless] scroll: no AXScrollArea — fallback to window center")
                return true
            } else {
                print("[mouseless] scroll: no scroll area and no window rect")
                return false
            }
        }
        selectedIndex = Self.nearestAreaIndex(areas, to: Self.cursorPoint())
        warpToSelected()
        ScrollOverlay.shared.show(areas: areas.map { $0.rect }, selected: selectedIndex)
        print("[mouseless] scroll: \(areas.count) area(s), selected #\(selectedIndex + 1)")
        return true
    }

    /// Switch the active scroll area (number-key press). 1-based `number`.
    func selectArea(number: Int) {
        let idx = number - 1
        guard idx >= 0, idx < areas.count else { return }
        selectedIndex = idx
        warpToSelected()
        ScrollOverlay.shared.show(areas: areas.map { $0.rect }, selected: selectedIndex)
    }

    /// Hide the overlay + stop scrolling. Called on mode exit.
    func teardown() {
        stop()
        ScrollOverlay.shared.hide()
    }

    /// Hide the scroll-picker overlay WITHOUT tearing down state. Used
    /// when entering a SCROLL sub-state (e.g. `/`-search) that wants
    /// to draw a different overlay over the same screen real estate;
    /// `showOverlay()` restores the picker on sub-state exit.
    func hideOverlay() {
        ScrollOverlay.shared.hide()
    }

    /// Re-show the scroll-picker overlay using current `areas` +
    /// `selectedIndex`. No-op if there are no detected areas (the
    /// zero-AX-app fallback path didn't draw anything to begin with).
    func showOverlay() {
        guard !areas.isEmpty else { return }
        ScrollOverlay.shared.show(areas: areas.map { $0.rect }, selected: selectedIndex)
    }

    private func warpToSelected() {
        guard selectedIndex < areas.count else { return }
        let r = areas[selectedIndex].rect
        CGWarpMouseCursorPosition(CGPoint(x: r.midX, y: r.midY))
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

    /// gg / G — jump the selected area to top / bottom. One huge pixel
    /// delta; the app clamps it at the content edge. 200k px is well
    /// past any real content height. Scrolls the area under the cursor
    /// (already warped to the selected area).
    func jumpToTop()    { postScroll(deltaY:  200_000) }   // +y = up
    func jumpToBottom() { postScroll(deltaY: -200_000) }   // -y = down

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

    // MARK: - Cursor + nearest-area

    private static func cursorPoint() -> CGPoint {
        // CGEvent location is global display coords, top-left origin —
        // matches AX rects. (NSEvent.mouseLocation would be bottom-left.)
        return CGEvent(source: nil)?.location ?? .zero
    }

    /// Index of the area nearest `point`: 0 distance if the point is
    /// inside an area, else the area with the smallest edge distance.
    private static func nearestAreaIndex(_ areas: [ScrollAreaDetector.Area], to point: CGPoint) -> Int {
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, a) in areas.enumerated() {
            let dx = max(0, max(a.rect.minX - point.x, point.x - a.rect.maxX))
            let dy = max(0, max(a.rect.minY - point.y, point.y - a.rect.maxY))
            let d = dx * dx + dy * dy
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    // MARK: - Focused window center (fallback when no AXScrollArea)

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
