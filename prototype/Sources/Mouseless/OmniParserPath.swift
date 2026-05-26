import Cocoa

/// OmniParser visual hint candidates for the focused window.
///
/// **P4 status**: STUB. `collect()` returns `[]` so the integration
/// seam compiles + the routing decision (`AppRegistry.shouldUseAXForFocused`)
/// can flow through `collectAll()` without `HintMode` knowing about
/// OP internals.
///
/// **P5 plan**: wire `ScreenCapture.captureFocusedWindow()` →
/// CoreML model inference → §5.1 baseline filters → return real
/// `OmniCandidate`s.
@MainActor
enum OmniParserPath {
    /// Final-shape candidate produced by the visual path. Carries
    /// just the rect (in screen-space, points) and the model's
    /// confidence — no AX element, no source window. Cache (`HintWindowCache`)
    /// doesn't apply because there's no element identity to key on.
    struct OmniCandidate {
        let rect: CGRect       // AX screen-space (top-left origin), points
        let confidence: Float  // 0.0–1.0 from the YOLO detector
    }

    /// Collect visual candidates for the currently focused window.
    /// Returns `[]` in the P4 stub — actual ScreenCaptureKit + CoreML
    /// integration lands in P5/P6.
    ///
    /// Caller invariant: only called when the routing decision
    /// (`AppRegistry.shouldUseAXForFocused`) returns `false`. The
    /// whitelist path runs the AX focused walk instead.
    static func collect() -> [OmniCandidate] {
        // P4 stub. P5 fills.
        return []
    }
}
