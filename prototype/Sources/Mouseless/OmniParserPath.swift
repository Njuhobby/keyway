import Cocoa

/// OmniParser visual hint candidates for the focused window.
///
/// **Pipeline** (called when `AppRegistry.shouldUseAXForFocused` returns
/// false for the focused app):
///
///   1. `ScreenCapture.captureFocusedWindow()` — grab the window's
///      pixel content + its screen-space rect (points).
///   2. `OmniParserModel.infer(image:)` — CoreML YOLO11m inference,
///      returns normalized `[0,1]` box detections with confidences.
///   3. `applyBaselineFilters(...)` — §5.1 of the design doc:
///      confidence threshold, min size, max size. NMS is already
///      baked into the .mlpackage (`yolo export ... nms=True`).
///   4. Normalized rect → screen-space rect using the window's
///      origin + size from step 1.
///
/// See `omniparser-fallback-design.md` §4.2 / §5.1.
@MainActor
enum OmniParserPath {
    /// Final-shape candidate produced by the visual path.
    struct OmniCandidate {
        let rect: CGRect       // AX screen-space (top-left origin), points
        let confidence: Float  // 0.0–1.0
    }

    /// Collect visual candidates for the currently focused window.
    /// Returns `[]` on any failure (no permission, capture failure,
    /// model load failure, etc.). The caller treats this as "no OP
    /// candidates this scan" and continues with the AX sources that
    /// run regardless (dock / menubar / extras).
    static func collect() async -> [OmniCandidate] {
        let tStart = Date()

        guard let captured = await ScreenCapture.captureFocusedWindow() else {
            print("[mouseless] OP: ScreenCapture returned nil — skipping inference")
            return []
        }
        let tCapture = Date()

        let detections: [OmniParserModel.Detection]
        do {
            detections = try await OmniParserModel.infer(image: captured.image)
        } catch {
            print("[mouseless] OP: inference error: \(error)")
            return []
        }
        let tInfer = Date()

        let filtered = applyBaselineFilters(detections, screenRect: captured.screenRect)
        let tFilter = Date()

        // Map normalized rect → screen-space rect using the window's
        // origin + size from the capture. `.scaleFill` distortion (model
        // input is 1280×1280 regardless of the actual window aspect)
        // cancels out because we multiply normalized [0,1] by the same
        // dimensions in both axes that the model saw.
        let windowRect = captured.screenRect
        let candidates: [OmniCandidate] = filtered.map { det in
            let r = det.rect
            return OmniCandidate(
                rect: CGRect(
                    x: windowRect.origin.x + r.minX * windowRect.width,
                    y: windowRect.origin.y + r.minY * windowRect.height,
                    width: r.width * windowRect.width,
                    height: r.height * windowRect.height
                ),
                confidence: det.confidence
            )
        }
        let tMap = Date()

        let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
        print("[mouseless] OP timings: capture=\(ms(tStart, tCapture))ms infer=\(ms(tCapture, tInfer))ms filter=\(ms(tInfer, tFilter))ms map=\(ms(tFilter, tMap))ms total=\(ms(tStart, tMap))ms raw=\(detections.count) → \(candidates.count)")
        return candidates
    }

    // MARK: - Baseline filtering (design doc §5.1)

    /// Rejects boxes by confidence + size.
    /// NMS is **not** here — model has it baked in.
    /// Filters operate in the model's normalized [0,1] coordinate space;
    /// `screenRect` provides the actual window dimensions for the size
    /// thresholds (8px min, 25% area max).
    private static func applyBaselineFilters(
        _ detections: [OmniParserModel.Detection],
        screenRect windowRect: CGRect
    ) -> [OmniParserModel.Detection] {
        // §5.1.1: confidence threshold. 0.3 is the design doc default;
        // P7 will tune from real-world data.
        let CONF_THRESHOLD: Float = 0.30
        // §5.1.2: minimum 8×8 pixels. Window dimensions are in points
        // but on retina that's a ~16-pixel floor — well below any real
        // UI element. Same threshold as the AX path uses.
        let MIN_SIDE_POINTS: CGFloat = 8
        // §5.1.3: maximum 25% of the window area. Detector occasionally
        // emits "the whole panel is a UI element" boxes — those aren't
        // useful targets and would dominate hint labels. NMS doesn't
        // remove them (see design doc §5.1.4's IoU math).
        let MAX_AREA_FRAC: CGFloat = 0.25
        let windowArea = windowRect.width * windowRect.height
        let maxAreaInPixels = windowArea * MAX_AREA_FRAC

        return detections.filter { det in
            guard det.confidence >= CONF_THRESHOLD else { return false }
            let widthInPoints = det.rect.width * windowRect.width
            let heightInPoints = det.rect.height * windowRect.height
            guard widthInPoints >= MIN_SIDE_POINTS,
                  heightInPoints >= MIN_SIDE_POINTS
            else { return false }
            let areaInPoints = widthInPoints * heightInPoints
            guard areaInPoints <= maxAreaInPixels else { return false }
            return true
        }
    }
}
