import Cocoa

/// State for a `.drag` mode session. Created when the user presses `v`
/// in TAP/SCROLL — `VimSession` synthesizes a `leftMouseDown` at the
/// current cursor position and stores the state needed to:
///
///   1. Tell the in-mode `MouseMover` to post `.leftMouseDragged` events
///      (held in `MouseMover.dragHeld`, not here — this controller's
///      sole state is the bookkeeping for completion).
///   2. Restore the pre-drag mode on a Backspace cancel (`startPoint`
///      to warp back to + release at, `preMode` to re-enter).
///   3. Re-hint with the correct sticky flag on Enter commit when
///      the pre-drag mode was sticky TAP.
///
/// Logic (entry / dispatch / completion) lives in `VimSession`. This is
/// just the value type. See `modes.md` §6 for the full state machine.
@MainActor
final class DragController {
    /// What the user was in *before* the Caps Lock + v chord triggered
    /// the drag. Backspace (cancel) restores `.tap` / `.scroll`; `.other`
    /// (came from OFF / WINDOW / MOVE) just exits OFF on cancel — those
    /// modes are either irrelevant (OFF) or complex to rebuild after a
    /// drag (WINDOW/MOVE held a specific window's state). Enter (commit)
    /// uses the same flag to decide sticky re-hint vs exit.
    enum PreMode {
        case tap(sticky: Bool)
        case scroll
        case other   // OFF / WINDOW / MOVE — no restore on cancel
    }

    /// Where `leftMouseDown` was posted. Backspace warps back here and
    /// posts `leftMouseUp` at the same point: the target app sees a
    /// stationary press+release (a click with zero drag distance), so
    /// no drop is registered.
    let startPoint: CGPoint
    let preMode: PreMode

    init(startPoint: CGPoint, preMode: PreMode) {
        self.startPoint = startPoint
        self.preMode = preMode
    }
}
