import Cocoa

/// Keyboard-driven cursor movement, active only inside TAP mode
/// (Ctrl+h/j/k/l). Continuous-on-hold via a ~60fps timer, like
/// ScrollController; Shift accelerates. Pairs with the `x` gesture
/// (click at cursor) to form a full keyboard mouse: move → x.
///
/// Moves by synthesizing `.mouseMoved` events (not CGWarp) so hover /
/// mouseEntered state updates as the cursor travels — buttons highlight
/// under it, which helps the user aim before pressing `x`.
@MainActor
final class MouseMover {
    enum Direction { case left, down, up, right }

    /// Pixels per tick. Tuned by feel; expose if needed. Movement needs
    /// to be precise enough to land on a target, so normal is modest.
    private let normalStep: CGFloat = 10
    private let fastStep: CGFloat = 34
    private let tickInterval: TimeInterval = 1.0 / 60.0

    private var timer: Timer?
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0   // top-left origin: +y = down
    private var fast = false
    private var current: CGPoint = .zero

    /// Begin (or redirect) continuous movement. Idempotent under OS
    /// key-repeat: while the timer runs, repeated keyDowns only refresh
    /// direction/speed — they don't add extra steps (the timer is the
    /// sole motion driver).
    func start(direction: Direction, fast: Bool) {
        switch direction {
        case .left:  dx = -1; dy = 0
        case .right: dx =  1; dy = 0
        case .up:    dx = 0; dy = -1
        case .down:  dx = 0; dy =  1
        }
        self.fast = fast
        if timer == nil {
            current = MouseSynth.cursorPosition()
            let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
                MainActor.assumeIsolated { self.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            tick()   // immediate first step
        }
    }

    /// Stop movement. Returns whether it was actually moving — lets the
    /// caller decide whether to consume the triggering keyUp (an h/j/k/l
    /// release that wasn't a move is just a hint key's release).
    @discardableResult
    func stop() -> Bool {
        let wasMoving = timer != nil
        timer?.invalidate()
        timer = nil
        return wasMoving
    }

    private func tick() {
        let step = fast ? fastStep : normalStep
        current.x += dx * step
        current.y += dy * step
        current = Self.clamp(current)
        move(to: current)
    }

    private func move(to p: CGPoint) {
        guard let src = CGEventSource(stateID: .privateState),
              let ev = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                               mouseCursorPosition: p, mouseButton: .left)
        else { return }
        ev.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
        ev.post(tap: .cghidEventTap)
    }

    /// Clamp into the union of all screens (AX top-left coords), with a
    /// 1px inset so the cursor stays on-screen.
    private static func clamp(_ p: CGPoint) -> CGPoint {
        guard let primary = NSScreen.screens.first else { return p }
        let ph = primary.frame.height
        var union = CGRect.null
        for s in NSScreen.screens {
            let f = s.frame
            let ax = CGRect(x: f.minX, y: ph - f.maxY, width: f.width, height: f.height)
            union = union.isNull ? ax : union.union(ax)
        }
        if union.isNull { return p }
        return CGPoint(
            x: min(max(p.x, union.minX + 1), union.maxX - 1),
            y: min(max(p.y, union.minY + 1), union.maxY - 1)
        )
    }
}
