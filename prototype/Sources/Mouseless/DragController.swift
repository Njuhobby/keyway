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
    /// What the user was in *before* `v` triggered the drag. Needed by
    /// Backspace (cancel) — restores the same mode + sticky state — and
    /// by Enter (commit) to decide sticky re-hint vs exit.
    enum PreMode {
        case tap(sticky: Bool)
        case scroll
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
