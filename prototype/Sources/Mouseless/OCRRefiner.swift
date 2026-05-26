import Cocoa
import Vision

/// Computes a more reliable click point for an OmniParser-detected box
/// by finding text inside the box via Apple Vision OCR.
///
/// **Why**: OP gives us visual bounding boxes, but their geometric
/// centers aren't always inside the real click handler — the model
/// might frame the box with a few pixels of padding/border, or the
/// visual area might not match the actual hit-test area (common in
/// web UIs), or a larger box might contain a smaller clickable box
/// whose center happens to be exactly where you click. Text labels
/// inside a button or card, on the other hand, are almost always
/// inside the click handler (that's the whole point of UI labels).
/// So: OCR the box, point at the text.
///
/// **Containment-aware**: if box B contains a smaller box b (both
/// detected by OP), the OCR on B will also pick up text from b.
/// Clicking that text would route the click to b's handler — wrong
/// if the user wanted to click B itself. We filter out OCR results
/// whose centers fall inside any contained inner box, leaving only
/// B's "own" text.
///
/// See `omniparser-fallback-design.md` §4.6 for the full algorithm
/// design including failure-mode analysis.
@MainActor
enum OCRRefiner {
    /// Refine the click point for an OP-sourced hint target.
    ///
    /// - Parameters:
    ///   - boxScreenRect: target's box in AX screen coords (points, top-left origin)
    ///   - innerBoxes: other OP boxes that are fully contained in `boxScreenRect`,
    ///     also in screen coords. Used to filter OCR results that belong to
    ///     the contained boxes, not to `boxScreenRect` itself.
    /// - Returns: click point in screen coords. Falls back to box center on
    ///   any failure (screen capture failed, OCR errored, no text found, etc.).
    static func refine(
        boxScreenRect: CGRect,
        innerBoxes: [CGRect]
    ) async -> CGPoint {
        let center = CGPoint(x: boxScreenRect.midX, y: boxScreenRect.midY)

        // Fast path: if box center isn't inside any inner box, the
        // center is already a safe click point. OCR refinement was
        // originally designed for two cases (§4.6):
        //   - box framing offset (model rect slightly off the real
        //     button — center lands on padding)
        //   - container nesting (big box's center happens to fall on
        //     a smaller clickable box inside it)
        // Only the second case is detectable WITHOUT OCR — just check
        // if center ∈ any innerBox. The first case is rare and OCR
        // is more dangerous than helpful when invoked unnecessarily
        // (e.g. on a WeChat chat row OCR may find only the timestamp
        // text and click on it instead of leaving center alone where
        // any position inside the row triggers chat selection).
        // So: only run OCR when there's a real containment conflict.
        // Saves ~60-90ms on the common case + avoids OCR misrouting.
        let centerInInner = innerBoxes.contains { $0.contains(center) }
        if !centerInInner {
            print("[mouseless] OCR refiner: center-no-conflict, skip OCR — point=(\(Int(center.x)),\(Int(center.y)))")
            return center
        }

        // Slow path: center is inside an inner box → clicking it would
        // route to the inner box's handler, not this box's. Run OCR +
        // the §4.6 algorithm to pick a point inside this box but NOT
        // inside any inner box.
        let tStart = Date()
        let fallback = center

        // Re-screencap the focused window so OCR sees what's actually on
        // screen *now*, not what was on screen when hint mode entered —
        // user might have scrolled / switched view between Caps Lock and
        // committing a hint key. Costs ~50-80ms but only on commit
        // (single user-initiated event) and we already accept similar
        // latency on the hint-mode entry path.
        guard let captured = await ScreenCapture.captureFocusedWindow() else {
            print("[mouseless] OCR refiner: screen recapture nil — fallback to box center")
            return fallback
        }
        let image = captured.image
        let windowRect = captured.screenRect
        let tCap = Date()

        // Verify the box is inside the current window. Possible mismatch
        // if user switched focus between collect and commit (e.g. by
        // accidentally clicking another window). Falling back to box
        // center is safer than OCRing the wrong window's pixels.
        guard windowRect.intersects(boxScreenRect) else {
            print("[mouseless] OCR refiner: box outside current window — fallback to box center")
            return fallback
        }

        // Translate box from screen-points to window-pixel coords.
        // ScreenCapture returns retina pixels, so we apply pixelScale to
        // bridge the point→pixel gap. We also clamp to the image bounds
        // so cropping(to:) doesn't fail on partial off-screen rects.
        let pxScaleX = CGFloat(image.width) / windowRect.width
        let pxScaleY = CGFloat(image.height) / windowRect.height
        let boxInPx = CGRect(
            x: (boxScreenRect.minX - windowRect.minX) * pxScaleX,
            y: (boxScreenRect.minY - windowRect.minY) * pxScaleY,
            width: boxScreenRect.width * pxScaleX,
            height: boxScreenRect.height * pxScaleY
        )
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clampedBoxInPx = boxInPx.intersection(imageBounds).integral
        guard let crop = image.cropping(to: clampedBoxInPx) else {
            print("[mouseless] OCR refiner: crop failed (rect=\(clampedBoxInPx)) — fallback")
            return fallback
        }

        // Run Vision OCR on just this box's pixels.
        //
        // `.accurate` not `.fast`: the fast path uses a character-shape
        // detector that's tuned for Latin scripts and routinely misses
        // CJK glyphs (observed: a WeChat chat row OCR'd only the "21:52"
        // timestamp and dropped the Chinese name + message). `.accurate`
        // uses the neural recognizer with proper CJK support. The extra
        // ~20-40ms is fine — this slow path only runs on the rare
        // center-in-inner-box case, which already pays ~50-80ms for the
        // re-screencap.
        //
        // `recognitionLanguages` is explicit because Vision otherwise
        // picks from the system locale's preferred languages — an
        // English-system user would get no Chinese recognition at all.
        // Listing zh first prioritizes CJK while still recognizing the
        // Latin text that Chinese UIs mix in (buttons, IDs, times).
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = false   // UI text isn't sentences

        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("[mouseless] OCR refiner: perform failed (\(error)) — fallback")
            return fallback
        }

        // Each observation has a normalized boundingBox in BOTTOM-LEFT
        // origin (Vision's quirky convention for image-space rects).
        // We translate each into screen-space TOP-LEFT coords so the
        // containment check matches the rest of our pipeline.
        let observations = (request.results ?? []) as [VNRecognizedTextObservation]
        struct TextRegion {
            let text: String
            let screenRect: CGRect
        }
        let textRegions: [TextRegion] = observations.compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string,
                  !text.isEmpty
            else { return nil }
            let bb = obs.boundingBox
            // bb is normalized in the crop's image-space, BL origin.
            // Convert to a screen-space rect in points, TL origin.
            let cropW = boxScreenRect.width
            let cropH = boxScreenRect.height
            let xInCrop = bb.minX * cropW
            // Flip Y around unit square, then scale.
            let yInCropFromTop = (1.0 - bb.maxY) * cropH
            let w = bb.width * cropW
            let h = bb.height * cropH
            let screenRect = CGRect(
                x: boxScreenRect.minX + xInCrop,
                y: boxScreenRect.minY + yInCropFromTop,
                width: w,
                height: h
            )
            return TextRegion(text: text, screenRect: screenRect)
        }
        let tOCR = Date()

        // §4.6 algorithm:
        //   Step 1: own_text = text whose centers don't fall inside any inner box.
        //           Non-empty → click longest own_text's center.
        //   Step 2: no own_text but inner_boxes non-empty → click box's own
        //           region (B minus innerBoxes). Simplified via edge midpoints.
        //   Step 3: no text and no inner_boxes → click box center.

        let ownText = textRegions.filter { region in
            let center = CGPoint(x: region.screenRect.midX, y: region.screenRect.midY)
            return !innerBoxes.contains { $0.contains(center) }
        }

        let clickPoint: CGPoint
        let mode: String
        if let longest = ownText.max(by: { $0.text.count < $1.text.count }) {
            // Step 1
            clickPoint = CGPoint(
                x: longest.screenRect.midX,
                y: longest.screenRect.midY
            )
            mode = "own_text(\(longest.text.prefix(20)))"
        } else if !innerBoxes.isEmpty {
            // Step 2: simplified own_region.
            // Box center is the obvious first candidate; if it's inside
            // an inner box, walk the four edge midpoints and pick the
            // one farthest from any inner box.
            let candidates: [CGPoint] = [
                CGPoint(x: boxScreenRect.midX, y: boxScreenRect.midY),
                CGPoint(x: boxScreenRect.midX, y: boxScreenRect.minY + 4),
                CGPoint(x: boxScreenRect.midX, y: boxScreenRect.maxY - 4),
                CGPoint(x: boxScreenRect.minX + 4, y: boxScreenRect.midY),
                CGPoint(x: boxScreenRect.maxX - 4, y: boxScreenRect.midY),
            ]
            let outside = candidates.filter { pt in
                !innerBoxes.contains { $0.contains(pt) }
            }
            if let best = outside.max(by: { p1, p2 in
                distanceToNearestInner(p1, innerBoxes) <
                distanceToNearestInner(p2, innerBoxes)
            }) {
                clickPoint = best
                mode = "own_region"
            } else {
                // Pathological: all candidates inside inner boxes.
                // Means B is essentially fully covered by inner boxes —
                // just point at center (will trigger some inner box).
                clickPoint = fallback
                mode = "own_region_collapsed"
            }
        } else {
            // Step 3
            clickPoint = fallback
            mode = "no_text_no_inner"
        }
        let tEnd = Date()

        let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
        print("[mouseless] OCR refiner: cap=\(ms(tStart, tCap))ms ocr=\(ms(tCap, tOCR))ms total=\(ms(tStart, tEnd))ms regions=\(textRegions.count) mode=\(mode) point=(\(Int(clickPoint.x)),\(Int(clickPoint.y)))")
        return clickPoint
    }

    private static func distanceToNearestInner(_ point: CGPoint, _ inners: [CGRect]) -> CGFloat {
        return inners.map { distance(point, $0) }.min() ?? .greatestFiniteMagnitude
    }

    /// Distance from `point` to nearest edge of `rect`. Zero if inside.
    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
        let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }
}
