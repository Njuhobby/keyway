import Cocoa

/// State for a `.drag` mode session. Two sub-states distinguished by
/// `startPoint`:
///
///   - **armed** (`startPoint == nil`): just entered via the Caps Lock
///     + v chord. No `leftMouseDown` has been synthesized yet — the
///     user moves the cursor with hjkl (regular `.mouseMoved` events)
///     to aim, then presses bare `v` to commit the grab.
///   - **dragging** (`startPoint != nil`): bare `v` was pressed,
///     `MouseSynth.dragDown` posted at the cursor (saved as
///     `startPoint`), and hjkl now generates `.leftMouseDragged`
///     events. Enter releases the button; Backspace warps back to
///     `startPoint` and releases there (zero-distance click → no
///     drop registered, true cancel).
///
/// The two-state design lets the user position the cursor first
/// without committing to a drag — Caps Lock + v alone is harmless.
/// Logic (entry / dispatch / completion) lives in `VimSession`. See
/// `modes.md` §6 for the full state machine.
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

    let preMode: PreMode

    /// Set by `beginDrag(at:)` when the user presses bare `v`. nil while
    /// the controller is still in the armed sub-state.
    private(set) var startPoint: CGPoint?

    /// True iff we've synthesized `leftMouseDown` — i.e., the user has
    /// pressed bare `v` to commit the grab.
    var isDragging: Bool { startPoint != nil }

    init(preMode: PreMode) {
        self.preMode = preMode
    }

    /// Transition armed → dragging: synthesize `leftMouseDown` at
    /// `point` and remember it as the start (for Backspace cancel
    /// warp-back). Idempotent — a second bare-`v` press does nothing.
    func beginDrag(at point: CGPoint) {
        guard startPoint == nil else { return }
        MouseSynth.dragDown(at: point)
        startPoint = point
    }
}
