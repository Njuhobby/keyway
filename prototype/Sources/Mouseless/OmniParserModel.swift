import Cocoa
import CoreML
import Vision

/// CoreML wrapper around the OmniParser-v2.0 `icon_detect` YOLO11m model.
///
/// **Inference path**:
///   1. Lazy-load `icon_detect.mlpackage` on first call (1-1.5s cold cost).
///   2. Vision framework's `VNCoreMLRequest` handles image preprocessing
///      (resize CGImage → 1280×1280 via `.scaleFill`).
///   3. Model outputs two MLMultiArrays:
///         coordinates  (N, 4)   [cx, cy, w, h] normalized in [0,1]
///         confidence   (N, 80)  per-COCO-class confidence (we take max)
///      The 80 classes are inherited from YOLO11's COCO pretraining but
///      meaningless for OmniParser's UI-detection fine-tune — we treat
///      all 80 as "is this an interactive UI element" and take the max.
///   4. NMS is **already baked into the .mlpackage** (`yolo export
///      ... nms=True` from P1 spike), so no NMS in Swift.
///
/// See `omniparser-fallback-design.md` §5 + the P1 walkthrough at
/// `~/Desktop/mouseless-p1-walkthrough.md`.
@MainActor
enum OmniParserModel {
    /// One detection from the model. `rect` is in **normalized [0,1]**
    /// coordinates relative to the model's 1280×1280 input space (same
    /// as the original image space once `.scaleFill` is undone — see
    /// `OmniParserPath` for the screen-space translation).
    struct Detection {
        let rect: CGRect    // [0,1] × [0,1], top-left origin, top-left corner
        let confidence: Float
    }

    enum ModelError: Error, CustomStringConvertible {
        case modelNotFound
        case loadFailed(String)
        case inferenceFailed(String)
        case malformedOutput(String)

        var description: String {
            switch self {
            case .modelNotFound:           return "icon_detect.mlpackage not in app bundle"
            case .loadFailed(let s):       return "CoreML load failed: \(s)"
            case .inferenceFailed(let s):  return "Vision inference failed: \(s)"
            case .malformedOutput(let s):  return "Output parse failed: \(s)"
            }
        }
    }

    private static var cachedModel: VNCoreMLModel?

    /// Pre-warm the model in the background at app launch. Mouseless is a
    /// menu bar app that runs all the time — pre-loading at launch
    /// trades a small (invisible) startup cost for a snappy first OP
    /// trigger. Without this, the first Caps Lock on an AX-bad app
    /// would block for ~1-1.5s while CoreML maps the .mlpackage.
    ///
    /// Safe to call multiple times — re-uses the cached load.
    /// Errors are logged but not thrown — Mouseless continues without
    /// the OP path if model load fails, AX path remains functional.
    static func preload() {
        // Stay on @MainActor — `cachedModel` is @MainActor and
        // `VNCoreMLModel` isn't Sendable (so detached tasks can't
        // touch it). CoreML model loading internally does I/O off the
        // main thread anyway, so this doesn't block the UI; what we
        // pay on main is just the synchronous setup wiring.
        Task { @MainActor in
            let t0 = Date()
            do {
                _ = try loadModel()
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                print("[mouseless] OmniParser model preloaded in \(ms)ms")
            } catch {
                print("[mouseless] OmniParser preload failed: \(error)")
            }
        }
    }

    /// Run detection on `image`. Returns detections with **normalized**
    /// rects (the caller maps to screen-space using its own knowledge of
    /// the captured window's screen rect).
    /// First call eagerly loads the model (~1-1.5s); subsequent calls hit
    /// the cache.
    static func infer(image: CGImage) async throws -> [Detection] {
        let tStart = Date()
        let model = try loadModel()
        let tLoad = Date()

        let request = VNCoreMLRequest(model: model)
        // `.scaleFill` distorts aspect ratio to match the model's
        // expected 1280×1280 input. For UI detection this is fine — the
        // detector finds boxes at the distorted positions, and our
        // screen-space mapping uses the SAME .scaleFill scaling (we just
        // multiply normalized coords by the window's pixel dimensions),
        // so any distortion cancels out cleanly. `.centerCrop` (default)
        // would chop off the sides of wide / tall windows — unacceptable.
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ModelError.inferenceFailed(error.localizedDescription)
        }
        let tInfer = Date()

        // Vision auto-recognizes the model as an object detector
        // (because the .mlpackage was exported with `nms=True`, which
        // adds the detection metadata coreml uses to pick this path).
        // Each observation is a `VNRecognizedObjectObservation` with
        // a pre-parsed `boundingBox` (normalized, BOTTOM-LEFT origin)
        // and a `confidence` already aggregated across classes. We
        // just need to flip Y → top-left origin.
        guard let observations = request.results as? [VNRecognizedObjectObservation]
        else {
            let actual = request.results.map { String(describing: type(of: $0)) } ?? "nil"
            throw ModelError.malformedOutput("unexpected results type: \(actual)")
        }

        var detections: [Detection] = []
        detections.reserveCapacity(observations.count)
        for obs in observations {
            // VNRecognizedObjectObservation uses **bottom-left origin**
            // normalized coordinates (Vision's quirky convention for
            // image-space rects). Top-left origin is what we use
            // everywhere else (AX, ScreenCapture, hint rendering).
            // Flip Y around the unit square.
            let bb = obs.boundingBox
            let rectTopLeft = CGRect(
                x: bb.minX,
                y: 1.0 - bb.maxY,
                width: bb.width,
                height: bb.height
            )
            detections.append(Detection(rect: rectTopLeft, confidence: obs.confidence))
        }
        let tParse = Date()

        let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
        print("[mouseless] OmniParser inference: load=\(ms(tStart, tLoad))ms infer=\(ms(tLoad, tInfer))ms parse=\(ms(tInfer, tParse))ms detections=\(detections.count)")
        return detections
    }

    // MARK: - Model loading

    /// Lazy-load + cache. The first inference eats the load cost; all
    /// subsequent inferences reuse this.
    ///
    /// CoreML runtime can't directly load an `.mlpackage` (the source
    /// format from `coremltools` / `yolo export`). It needs an
    /// `.mlmodelc` (compiled). `MLModel.compileModel(at:)` does the
    /// compile to a temp directory; the returned URL is good for the
    /// process's lifetime (system may purge `/tmp` on reboot, but we
    /// re-compile next launch). Production builds could pre-compile at
    /// build time via `xcrun coremlcompiler`, but for SwiftPM this
    /// runtime path is the simpler shape.
    private static func loadModel() throws -> VNCoreMLModel {
        if let cached = cachedModel { return cached }
        guard let mlpackageURL = Bundle.module.url(
            forResource: "icon_detect", withExtension: "mlpackage"
        ) else {
            throw ModelError.modelNotFound
        }

        let compiledURL: URL
        do {
            compiledURL = try MLModel.compileModel(at: mlpackageURL)
        } catch {
            throw ModelError.loadFailed("compileModel: \(error.localizedDescription)")
        }

        let mlConfig = MLModelConfiguration()
        // P1 spike measured Metal GPU at 29ms vs ANE at 42ms — for
        // conv-heavy YOLO networks GPU beats ANE 30%. Pin computeUnits
        // explicitly so the runtime doesn't default to .all (which
        // sometimes picks ANE).
        mlConfig.computeUnits = .cpuAndGPU
        do {
            let mlModel = try MLModel(contentsOf: compiledURL, configuration: mlConfig)
            let vn = try VNCoreMLModel(for: mlModel)
            cachedModel = vn
            return vn
        } catch {
            throw ModelError.loadFailed(error.localizedDescription)
        }
    }
}
