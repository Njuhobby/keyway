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

    /// Which physical axis we're driving this tick. d/u keys drive
    /// vertical (wheel1); b/f drive horizontal (wheel2).
    enum Axis { case vertical, horizontal }

    private var timer: Timer?
    private var axis: Axis = .vertical
    /// Direction along the active axis:
    ///   vertical   true = scroll page DOWN  (see lower content)
    ///   horizontal true = scroll page RIGHT (see right content)
    private var positiveDirection = true
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
        let cursor = Self.cursorPoint()
        areas = ScrollAreaDetector.detect()
        if areas.isEmpty {
            // Fallback: no AX scroll area (common on Chrome — web content
            // AX is off by default). Scroll wheel events route to the view
            // under the cursor, so we only need the cursor somewhere inside
            // the scrollable window. **If it's already inside the focused
            // window, leave it where it is** — warping to center when the
            // user's cursor is already on the page is jarring and
            // pointless. Only warp (to center) when the cursor is outside
            // the window (e.g. on another monitor / over the Dock).
            guard let rect = Self.focusedWindowRect() else {
                Log.debug("[mouseless] scroll: no scroll area and no window rect")
                return false
            }
            if rect.contains(cursor) {
                Log.debug("[mouseless] scroll: no AXScrollArea — cursor already in window, no warp")
            } else {
                CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
                Log.debug("[mouseless] scroll: no AXScrollArea — warp to window center (cursor was outside)")
            }
            return true
        }
        selectedIndex = Self.nearestAreaIndex(areas, to: cursor)
        // nearestAreaIndex returns the containing area at distance 0 when
        // the cursor is inside one — so "cursor already inside the
        // selected area" means don't warp; scrolling works wherever it is.
        if !areas[selectedIndex].rect.contains(cursor) {
            warpToSelected()
        }
        ScrollOverlay.shared.show(areas: areas.map { $0.rect }, selected: selectedIndex)
        Log.debug("[mouseless] scroll: \(areas.count) area(s), selected #\(selectedIndex + 1)")
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
    /// key-repeat — repeated keyDowns just refresh axis/direction/speed.
    /// Switching axis mid-scroll (e.g., releasing `d` and pressing `f`)
    /// is supported — same timer reused.
    func start(axis: Axis, positive: Bool, fast: Bool) {
        self.axis = axis
        self.positiveDirection = positive
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
    func jumpToTop()    { postScroll(deltaY:  200_000, deltaX: 0) }   // +y = up
    func jumpToBottom() { postScroll(deltaY: -200_000, deltaX: 0) }   // -y = down

    private func tick() {
        let magnitude = fast ? fastDelta : normalDelta
        switch axis {
        case .vertical:
            // wheel1 sign: negative = page DOWN (reveal lower content)
            let deltaY = positiveDirection ? -magnitude : magnitude
            postScroll(deltaY: deltaY, deltaX: 0)
        case .horizontal:
            // wheel2 sign: negative = page RIGHT (reveal right content),
            // matching wheel1's "negative = forward direction" convention.
            let deltaX = positiveDirection ? -magnitude : magnitude
            postScroll(deltaY: 0, deltaX: deltaX)
        }
    }

    private func postScroll(deltaY: Int, deltaX: Int) {
        guard let src = CGEventSource(stateID: .privateState),
              let ev = CGEvent(scrollWheelEvent2Source: src,
                               units: .pixel, wheelCount: 2,
                               wheel1: Int32(deltaY),
                               wheel2: Int32(deltaX),
                               wheel3: 0)
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

    // MARK: - Focused window rect (fallback when no AXScrollArea)

    private static func focusedWindowRect() -> CGRect? {
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
        return CGRect(origin: origin, size: size)
    }
}
