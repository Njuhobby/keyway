import Cocoa

/// Synthesizes mouse click events. Shared by HintMode (click a hint
/// target's point) and VimSession (the `x` gesture = click at the
/// cursor). Will also back the future keyboard-mouse-move feature's
/// click action.
///
/// Every event is stamped with HotkeyTap.syntheticMarker so our own
/// CGEventTap callback ignores it (no feedback loop). Posted at
/// `.cghidEventTap` so it reaches session taps including the focused app.
enum MouseSynth {
    static func click(at point: CGPoint, button: CGMouseButton = .left, count: Int = 1) {
        let src = CGEventSource(stateID: .privateState)
        let downType: CGEventType = (button == .left) ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = (button == .left) ? .leftMouseUp : .rightMouseUp

        for clickIdx in 1...count {
            guard
                let down = CGEvent(mouseEventSource: src, mouseType: downType,
                                   mouseCursorPosition: point, mouseButton: button),
                let up = CGEvent(mouseEventSource: src, mouseType: upType,
                                 mouseCursorPosition: point, mouseButton: button)
            else { return }
            for ev in [down, up] {
                ev.setIntegerValueField(.mouseEventClickState, value: Int64(clickIdx))
                ev.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
                ev.post(tap: .cghidEventTap)
            }
        }
    }

    /// Press a mouse button at `point` without releasing — opens a drag.
    /// Pair with `dragUp(at:)` after moving the cursor. The in-between
    /// move events should be `.leftMouseDragged` (see MouseMover's
    /// `dragHeld` mode), not `.mouseMoved`, otherwise the target app
    /// sees a stationary click instead of a drag.
    static func dragDown(at point: CGPoint, button: CGMouseButton = .left) {
        let src = CGEventSource(stateID: .privateState)
        let downType: CGEventType = (button == .left) ? .leftMouseDown : .rightMouseDown
        guard let down = CGEvent(mouseEventSource: src, mouseType: downType,
                                 mouseCursorPosition: point, mouseButton: button)
        else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
        down.post(tap: .cghidEventTap)
    }

    /// Release a held mouse button at `point` — closes a drag opened by
    /// `dragDown(at:)`. Caller decides the drop point (current cursor for
    /// commit / Esc, or warped back to source for backspace cancel).
    static func dragUp(at point: CGPoint, button: CGMouseButton = .left) {
        let src = CGEventSource(stateID: .privateState)
        let upType: CGEventType = (button == .left) ? .leftMouseUp : .rightMouseUp
        guard let up = CGEvent(mouseEventSource: src, mouseType: upType,
                               mouseCursorPosition: point, mouseButton: button)
        else { return }
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
        up.post(tap: .cghidEventTap)
    }

    /// Current cursor position in global display coords (top-left origin —
    /// matches AX rects). NSEvent.mouseLocation would be bottom-left.
    static func cursorPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
