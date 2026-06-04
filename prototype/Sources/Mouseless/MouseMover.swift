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

    enum Speed { case slow, normal, fast }

    /// Pixels per tick. Tuned by feel.
    ///   slow (Option)  = 2 px/tick  ≈  120 px/s   fine aim
    ///   normal (bare)  = 6 px/tick  ≈  360 px/s   short hops
    ///   fast (Shift)   = 18 px/tick ≈ 1080 px/s   medium runs
    /// **For cross-screen movement use the double-tap jump (hh/jj/
    /// kk/ll) — Shift+double-tap teleports 1/2 screen.** With the
    /// jump available, continuous Shift no longer has to do the
    /// heavy lifting alone, so this speed is tuned for controlled
    /// fine-grained traversal rather than blink-and-cursor-on-the-
    /// other-monitor velocity.
    private let slowStep: CGFloat = 2
    private let normalStep: CGFloat = 6
    private let fastStep: CGFloat = 18
    private let tickInterval: TimeInterval = 1.0 / 60.0

    private var timer: Timer?
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0   // top-left origin: +y = down
    private var speed: Speed = .normal
    private var current: CGPoint = .zero
    private var dragHeld: Bool = false   // DRAG mode → post .leftMouseDragged

    /// Begin (or redirect) continuous movement. Idempotent under OS
    /// key-repeat: while the timer runs, repeated keyDowns only refresh
    /// direction/speed — they don't add extra steps (the timer is the
    /// sole motion driver).
    ///
    /// `dragHeld`: caller is inside `.drag` mode (mouseDown is held), so
    /// each step posts `.leftMouseDragged` instead of `.mouseMoved` —
    /// the target app needs to see the drag, not a hover. Every call
    /// re-sets this flag; TAP/SCROLL pass the default `false`.
    func start(direction: Direction, speed: Speed, dragHeld: Bool = false) {
        switch direction {
        case .left:  dx = -1; dy = 0
        case .right: dx =  1; dy = 0
        case .up:    dx = 0; dy = -1
        case .down:  dx = 0; dy =  1
        }
        self.speed = speed
        self.dragHeld = dragHeld
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
        let step: CGFloat
        switch speed {
        case .slow:   step = slowStep
        case .normal: step = normalStep
        case .fast:   step = fastStep
        }
        current.x += dx * step
        current.y += dy * step
        current = Self.clamp(current)
        move(to: current)
    }

    private func move(to p: CGPoint) {
        let type: CGEventType = dragHeld ? .leftMouseDragged : .mouseMoved
        guard let src = CGEventSource(stateID: .privateState),
              let ev = CGEvent(mouseEventSource: src, mouseType: type,
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
