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

    /// Current cursor position in global display coords (top-left origin —
    /// matches AX rects). NSEvent.mouseLocation would be bottom-left.
    static func cursorPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
