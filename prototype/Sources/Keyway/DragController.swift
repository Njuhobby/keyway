import Cocoa

/// State for the **drag sub-state** of TAP mode. `VimSession.tapSub`
/// becomes `.dragging(DragController)` when the user presses bare `v`
/// in TAP — the init synthesizes `leftMouseDown` at `startPoint`, and
/// the controller is just a holder for that point (Backspace cancel
/// warps back here + releases at this same spot so the target app
/// sees a zero-distance click and registers no drop).
///
/// All flow control (Enter / Backspace / Esc / Caps Lock chord) lives
/// in `VimSession`. See `modes.md` §6.
@MainActor
final class DragController {
    let startPoint: CGPoint

    init(at startPoint: CGPoint) {
        self.startPoint = startPoint
        MouseSynth.dragDown(at: startPoint)
    }
}
