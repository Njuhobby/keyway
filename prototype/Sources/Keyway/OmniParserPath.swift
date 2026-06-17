import Cocoa
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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

    /// Master switch for the diagnostic overlay dump
    /// (`/tmp/keyway-focused.png` with kept/rejected boxes drawn).
    /// Off in production — the PNG encode of a retina image costs
    /// 30-80ms even on a background queue (mostly disk write + zlib).
    /// Toggle via `KEYWAY_DEBUG_OVERLAY=1` in the env. `run.sh` sets
    /// it automatically so dev runs always see the overlay. Production
    /// `.app` launches without it, paying zero overlay cost.
    static let debugOverlayEnabled: Bool =
        ProcessInfo.processInfo.environment["KEYWAY_DEBUG_OVERLAY"] == "1"

    /// Collect visual candidates for the currently focused window.
    /// Returns `[]` on any failure (no permission, capture failure,
    /// model load failure, etc.). The caller treats this as "no OP
    /// candidates this scan" and continues with the AX sources that
    /// run regardless (dock / menubar / extras).
    static func collect(isolateApp: Bool = false) async -> [OmniCandidate] {
        let tStart = Date()

        guard let captured = await ScreenCapture.captureFocusedWindow(isolateApp: isolateApp) else {
            Log.warn("[keyway] OP: ScreenCapture returned nil — skipping inference")
            return []
        }
        let tCapture = Date()

        let detections: [OmniParserModel.Detection]
        do {
            detections = try await OmniParserModel.infer(image: captured.image)
        } catch {
            Log.error("[keyway] OP: inference error: \(error)")
            return []
        }
        let tInfer = Date()

        let (filtered, rejected) = partitionByBaselineFilters(
            detections, screenRect: captured.screenRect
        )
        let tFilter = Date()

        // Diagnostic overlay — only when explicitly enabled via env
        // var. PNG encode of a retina-sized image is ~30-80ms even on
        // a background queue, so production launches should leave it
        // off. See `debugOverlayEnabled` above.
        if debugOverlayEnabled {
            saveDebugOverlay(image: captured.image,
                             kept: filtered, rejected: rejected,
                             path: "/tmp/keyway-focused.png")
        }

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
        Log.debug("[keyway] OP timings: capture=\(ms(tStart, tCapture))ms infer=\(ms(tCapture, tInfer))ms filter=\(ms(tInfer, tFilter))ms map=\(ms(tFilter, tMap))ms total=\(ms(tStart, tMap))ms raw=\(detections.count) → \(candidates.count)")
        return candidates
    }

    // MARK: - Baseline filtering (design doc §5.1)

    /// Partitions detections into `kept` (passed all filters → become
    /// hints) and `rejected` (dropped by at least one filter → drawn in
    /// red on the debug overlay). NMS is not here — model has it baked.
    /// Filters operate in the model's normalized [0,1] coordinate space;
    /// `windowRect` provides the actual window dimensions for the size
    /// thresholds (8pt min, 25% area max).
    private static func partitionByBaselineFilters(
        _ detections: [OmniParserModel.Detection],
        screenRect windowRect: CGRect
    ) -> (kept: [OmniParserModel.Detection], rejected: [OmniParserModel.Detection]) {
        // §5.1.1: confidence threshold. 0.3 is the design doc default;
        // P7 will tune from real-world data.
        let CONF_THRESHOLD: Float = 0.30
        // §5.1.2: minimum 8pt sides. Same threshold as the AX path uses.
        let MIN_SIDE_POINTS: CGFloat = 8
        // §5.1.3: maximum 25% of the window area. Detector occasionally
        // emits "the whole panel is a UI element" boxes — those aren't
        // useful targets and would dominate hint labels. NMS doesn't
        // remove them (see design doc §5.1.4's IoU math).
        let MAX_AREA_FRAC: CGFloat = 0.25
        let windowArea = windowRect.width * windowRect.height
        let maxAreaInPoints = windowArea * MAX_AREA_FRAC

        var kept: [OmniParserModel.Detection] = []
        var rejected: [OmniParserModel.Detection] = []
        for det in detections {
            let widthInPoints = det.rect.width * windowRect.width
            let heightInPoints = det.rect.height * windowRect.height
            let areaInPoints = widthInPoints * heightInPoints
            let passes = det.confidence >= CONF_THRESHOLD
                      && widthInPoints >= MIN_SIDE_POINTS
                      && heightInPoints >= MIN_SIDE_POINTS
                      && areaInPoints <= maxAreaInPoints
            if passes { kept.append(det) } else { rejected.append(det) }
        }
        return (kept, rejected)
    }

    // MARK: - Debug overlay

    /// Saves the captured window image with bounding boxes drawn for
    /// visual diagnosis:
    ///   - **Yellow thick outline**: detections that passed baseline
    ///     filtering (these become hint labels).
    ///   - **Red thin outline**: detections the model produced but
    ///     baseline filtering dropped (low conf, too small, too large).
    ///
    /// Runs **off the main thread** on a background queue — the PNG
    /// encode of a retina-sized image (~3-4 MP) takes 30-80ms, which
    /// would noticeably bloat the OP path's wall-clock if we did it
    /// synchronously. The overlay is a pure diagnostic, doesn't feed
    /// back into the hint display, so fire-and-forget is fine.
    ///
    /// CGImage and Detection are immutable CF / value types so passing
    /// them across the queue boundary is safe even though Swift 6's
    /// Sendable checker can't see it.
    private static func saveDebugOverlay(
        image: CGImage,
        kept: [OmniParserModel.Detection],
        rejected: [OmniParserModel.Detection],
        path: String
    ) {
        DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            let width = image.width
            let height = image.height

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }

            // No CTM flip. `CGContext.draw(image, in:)` interacts with
            // the bitmap context such that the resulting PNG (where row
            // 0 is the top) comes out right-side up when the context is
            // **un-flipped**. (Counterintuitive to Apple's docs, but
            // empirically verified — flipping the context produces an
            // upside-down PNG.)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            // Box coordinates come in normalized [0,1] with TOP-LEFT
            // origin (same as the rest of our pipeline). The bitmap
            // context however is BOTTOM-LEFT origin, so we flip Y per
            // box to compensate: pxY_bl = height - normY*height -
            // normH*height.
            let Wf = CGFloat(width)
            let Hf = CGFloat(height)
            let denorm = { (r: CGRect) -> CGRect in
                let pxX = r.minX * Wf
                let pxW = r.width * Wf
                let pxH = r.height * Hf
                let pxY_bl = Hf - r.minY * Hf - pxH
                return CGRect(x: pxX, y: pxY_bl, width: pxW, height: pxH)
            }

            // Rejected first (drawn underneath) — red thin outline.
            ctx.setStrokeColor(red: 1.0, green: 0.25, blue: 0.25, alpha: 0.75)
            ctx.setLineWidth(2)
            for det in rejected {
                ctx.stroke(denorm(det.rect))
            }

            // Kept on top — yellow thick outline.
            ctx.setStrokeColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0)
            ctx.setLineWidth(4)
            for det in kept {
                ctx.stroke(denorm(det.rect))
            }

            guard let outImage = ctx.makeImage() else { return }
            let url = URL(fileURLWithPath: path)
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { return }
            CGImageDestinationAddImage(dest, outImage, nil)
            _ = CGImageDestinationFinalize(dest)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Log.debug("[keyway] OP debug overlay: \(ms)ms → \(path)")
        }
    }
}
