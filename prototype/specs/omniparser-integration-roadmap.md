# OmniParser Integration — Phased Roadmap

A phased implementation plan to bring the design in `omniparser-fallback-design.md` into actual code.

**Overall goal**: Make Mouseless able to scan out hints even in AX black-hole apps (Electron / Catalyst / WKWebView-wrapped web shells), end-to-end wall-clock < 400ms, with no misclick UX regression.

**Whole-project estimate**: 2-4 weeks of focused development + 1 week of tuning on real data. Each phase below gives an independent time estimate and risks.

---

## Overview: phase dependency graph

```
P0 decision  ──→  P1 CoreML inference spike  ──┬─→ P3 framework detection
   │                                            │
   │                                            ├─→ P4 integration seam
   ↓                                            │
P2 screenshot + permission ─────────────────────┘
                                                │
                                                ↓
                                           P5 baseline filtering
                                                │
                                                ↓
                                           P6 OCR refiner
                                                │
                                                ↓
                                           P7 end-to-end testing + data
                                                │
                                                ↓
                                           P8 release packaging
```

P0/P1/P2 can run in parallel (if you have the hands). P3-P8 are serial.

---

## P0 — Architecture decisions (1-2 days)

**Goal**: Lock down the irreversible architecture choices, to avoid rework in later phases.

**Output**: A short decision record (update `omniparser-fallback-design.md` §6 directly), not a new file.

**Open questions**:

1. **Inference process boundary**: CoreML in-Swift vs Python sidecar?
   - Leaning: CoreML (already written into design doc §6.1)
   - Override condition: P1 spike shows CoreML-converted accuracy drops significantly / ANE doesn't support the necessary operators
   - Fallback option: Python sidecar + Unix socket JSON-RPC (the PoC code can be adapted, ~1 extra week)

2. **Model distribution**: bundle in .app vs first-launch download?
   - YOLO weights ~30MB. Bundling into the app — pros: works offline, no network dependency. Cons: app size goes up.
   - Leaning: **bundle** (30MB is still acceptable in a menu bar app)

3. **Screenshot API**: ScreenCaptureKit vs CGWindowList vs CGDisplayCreateImage?
   - Leaning: ScreenCaptureKit (modern API, multi-display friendly, best performance)
   - But it needs Screen Recording permission, which is a new bar beyond AX — see P2

4. **Scope of the `HintMode.swift` rework**: edit in place vs build a new `HintSource` abstraction layer?
   - Leaning: introduce `enum HintSource { case ax(...); case omni(...) }`, with `HintTarget` holding the union internally
   - Rationale: commit() is already a pure synthesized click, so the path is unified; the only branch is cache invalidation (OP doesn't write the cache)

**Risk**: a wrong decision isn't exposed until P4, so rework is costly. Mitigation: don't lock the other decisions until the P1 spike is done.

---

## P1 — CoreML inference spike (2-3 days)

**Goal**: Verify whether the YOLOv8 → CoreML conversion preserves recall, and whether ANE inference latency beats the PoC's MPS Python.

**Output**:
- A throwaway Swift command-line tool: input image path → output JSON box list
- The converted `.mlpackage` model file
- A performance data table (compared against the PoC's MPS Python numbers)

**Steps**:
1. Use the official ultralytics export tool to convert `icon_detect/model.pt` to CoreML:
   ```bash
   yolo export model=icon_detect/model.pt format=coreml nms=True
   ```
   Note: `nms=True` puts NMS into the graph, saving a hand-written one on the Swift side
2. Write a ~150-line Swift CLI (`omniparser-coreml-spike/`, outside the repo):
   - Load the `.mlpackage`, run single-image inference
   - Output `[{x, y, w, h, confidence}, ...]` JSON
3. Run it on the PoC's three screenshots, and verify:
   - **Recall**: the converted box count deviates < 10% from MPS Python (showing the conversion didn't lose accuracy)
   - **Latency**: ANE p50 < 100ms (the theoretical target; beating MPS counts as acceptable)
4. Run a visualization overlay once, and compare against the PoC's output images

**Risks**:
- **YOLOv8 operators not supported on ANE**: some operators (dynamic NMS, specific activations) force a fallback to CPU. Mitigation: start with GPU compute units, verify it works, then optimize ANE.
- **Accuracy loss**: CoreML quantization may drop small targets. Mitigation: start with FP16, fall back to FP32 if needed.
- **Conversion failure**: fall back to the Python sidecar option, +1 week.

**Decision point**: after the spike, confirm "the CoreML path is viable"; otherwise switch to the Python sidecar.

---

## P2 — Screenshot + permission flow (1-2 days)

**Goal**: Close the loop on the independent sub-problem of "how to get a screenshot of the focused window in Swift."

**Scope decision**: **only capture the focused window**, not the focused screen, not the full screen. See the discussion in `omniparser-fallback-design.md` §6.4 — the core rationale: the AX path always works well on the Dock / menu bar / menu extras, OmniParser precisely fills the "AX black hole among sub-elements inside the focused window" problem, the screenshot scope is complementary to and non-overlapping with the AX path + recall is higher (a window ~1500×900 → 1280² resize gives better recall than full screen 3000×2000 → 1280²).

**Output**:
- `Sources/Mouseless/ScreenCapture.swift`: `focusedWindowImage() async throws -> CGImage?` (nil means the focused app has no window)
- Permission request UI: lazy prompt (only pops the first time the OP path is taken)
- Window detection that cooperates with AX: use `AXFocusedWindow` + `_AXUIElementGetWindow` to get the CGWindowID

**Steps**:
1. **Get the focused window via AX**:
   - `AXFocusedApplication` → app element
   - `app.attribute("AXFocusedWindow")` → window element
   - `_AXUIElementGetWindow(window, ...)` → CGWindowID (a private but stable API)
   - any step fails → return nil, and the path degrades to AX-only
2. **ScreenCaptureKit per-window screenshot**:
   - `SCShareableContent.current.windows.first { $0.windowID == cgWindowID }` to find the corresponding SCWindow
   - `SCContentFilter(desktopIndependentWindow: scWindow)` (the key mode: ignore occlusion, draw the complete window content)
   - `SCScreenshotManager.captureImage(...)` → CGImage
3. **Permission handling**:
   - At launch, do **not** request Screen Recording
   - On the first OP-path trigger, detect `CGPreflightScreenCaptureAccess()`; if there's no permission, pop the native authorization prompt
   - If not authorized: the OP path for that invocation degrades to "no candidates" (consistent with the current experience on AX black-hole apps), without blocking Mouseless as a whole
4. **AX-bad app verification**: run it once on AX black-hole apps like WeChat / Slack / VS Code, and confirm `AXFocusedWindow` ✅ is obtainable, CGWindowID ✅ is obtainable, ScreenCaptureKit ✅ produces an image. **The AX black hole is only a sub-element-layer problem; the top-level window skeleton is available for all apps**.
5. **Verify latency**: typically < 30ms on M-series.

**Risks**:
- **Abrupt permission UX**: the user switches to Slack, presses Caps Lock, and an authorization box popping up is surprising. Mitigation: show a one-time hint in the banner: "Enabling Electron support requires Screen Recording permission."
- **Screenshot latency over 50ms**: anything over that eats into the OP path's budget. If it happens, investigate the difference between a continuous `SCStream` and a single-shot screenshot.
- **`_AXUIElementGetWindow` is a private API**: Apple may break it someday. Fallback option: use `CGWindowListCopyWindowInfo` matching by PID + window title (slower but public). Use the private API in the first version, and switch only if problems arise.

---

## P3 — Routing decision (0.5 day)

**Goal**: Implement OP-default + AX whitelist routing (see design doc §4.4).

> **History**: P3 was originally "two-layer framework detection" — entirely overturned after hitting WeChat. WeChat is native AppKit but an AX black hole, which shows that framework ≠ AX quality. Changed to an explicit whitelist. The `FrameworkDetector.swift` implementation was committed in commit `04f57f4` and deleted in `b0e4...` (this P3 pivot).

**Output**:
- `Sources/Mouseless/AppRegistry.swift`: `AX_FOCUSED_WHITELIST: Set<String>` + `shouldUseAXForFocused(bundleID:) -> Bool`
- Initial whitelist: ~15 Apple-built AppKit apps (Finder, Mail, Safari, Pages, Xcode, etc.)
- Add a routing decision log to VimSession.enter() (for debugging)

**Steps**:

1. **Create `AppRegistry.swift`**: a `Set<String>` is enough for the whitelist, O(1) lookup
2. **Add a log to VimSession.enter()**: get the bundleID from `AXFocusedApplication`, call `shouldUseAXForFocused`, and log `route: <bundleID> -> AX walk (whitelist) | OmniParser (default)`
3. **Don't change the real routing split**: the actual collectAll split is wired in at P4. P3 only does "the decision mechanism + log," verifying the whitelist hits as expected

**Risk**: very low. One set lookup.

---

## P4 — Integration seam: HintTarget rework + routing (2-3 days)

**Goal**: Wire the OP path into `collectAll()`, keeping the commit() / cache logic compatible.

**Output**: a refactored `HintMode.swift` + a new `OmniParserPath.swift` stub (returns empty for now, filled in at P5).

**Steps**:

1. **`HintTarget` rework**:
   ```swift
   enum HintSource {
       case ax(element: AXUIElement, sourceWindow: AXUIElement?)
       case omni(box: CGRect, confidence: Float)
   }
   struct HintTarget {
       let label: String
       let rect: CGRect       // screen-space, used by both sources
       let role: String       // AX role or "AXOmni" (placeholder for the OP source)
       let source: HintSource // replaces the original element + sourceWindow
   }
   ```
2. **`commit()` adaptation**:
   - Currently already a synthesized click on `rect.midX/midY`, **no change needed to the click logic**
   - `HintWindowCache.markDirty` is only called for the `.ax` source:
     ```swift
     if case .ax(_, let win?) = target.source {
         HintWindowCache.shared.markDirty(window: win)
     }
     ```
3. **`collectAll()` routing**: split the AX walk into "focused app sub-elements" vs "the other 3 AX sources," with OP replacing the former on the default path. See `omniparser-fallback-design.md` §4.2/§4.4.
   ```swift
   // Always runs — the dock/menubar/extras AX walk runs in parallel with the focused-app branch below
   async let dockTargets = walkDock(...)
   async let menubarTargets = walkMenuBar(...)
   async let extrasTargets = walkMenuExtras(...)

   // The focused-app sub-elements branch: OP-default + AX whitelist
   async let focusedTargets: [HintTarget] = {
       if AppRegistry.shouldUseAXForFocused(bundleID: bundleID) {
           // Whitelist path: AX walk the focused app's sub-elements
           return walkFocusedApp(...)
       } else {
           // Default path: OP (screenshot + inference + baseline filtering)
           return await runOmniParser()
       }
   }()

   return await (dockTargets + menubarTargets + extrasTargets + focusedTargets)
   ```

   **Key point**: use `async let` to make the 4 branches truly parallel, instead of running sequentially. **On the OP path**, user-facing latency ≈ `max(50ms AX other sources, 95ms OP) = 95ms`. **On the whitelist path**, latency ≈ `max(50ms, 150-200ms focused AX walk) = 150-200ms`. **OP is even faster than the whitelist** — this is the actual result of ScreenCaptureKit + Metal GPU outrunning the AX walk (see P1/P2 data).
4. **hint label assignment**: currently `dock(numeric) + (focused + extras)(letters)`. OP candidates merge into the letter pool, sharing the space with focused.
5. **`OmniParserPath.swift` stub**:
   ```swift
   func runOmniParser() -> [HintTarget] {
       // returns [] until P5
       return []
   }
   ```

**Risks**:
- **The HintTarget rework's blast radius**: grep `target.element` / `target.sourceWindow`, which will touch HintOverlay, VimSession, etc. Mitigation: grep and list everything first, then refactor it all in one pass.
- **Routing decision overhead in collectAll()**: one Set lookup, < 1us. OK.

---

## P5 — Baseline filtering (§5.1) (1 day)

**Goal**: Compress the OP detector's output of 100-180 boxes down to 60-100.

**Output**: `OmniParserPath.applyBaselineFilters(boxes: [...]) -> [...]`

**Steps**:

1. Confidence threshold: `box.confidence >= 0.3` (tuned with P7 data)
2. Minimum size: `width >= 8 && height >= 8`
3. Maximum size: `width * height <= 0.25 * screen.area`
4. NMS dedup: in pairs with IoU > 0.5, keep the higher-conf one
   - Note: if P1 exported with `nms=True`, NMS is already done in the model; just skip it here
5. Log a count for each filter (filtered out N) to ease debugging

**Risk**: low. Pure geometry + ML post-processing.

---

## P6 — OCR refiner (§4.6) (2-3 days)

**Goal**: Implement containment-aware click point refinement, to avoid mis-clicking containers.

**Output**: in the `commit()` path, call the OCR refiner for the `.omni` source to decide the real click point.

**Steps**:

1. **Vision OCR wrapper**:
   ```swift
   func ocrTextRegions(in image: CGImage) -> [(text: String, rect: CGRect)]
   ```
   Use `VNRecognizeTextRequest`, `recognitionLevel = .fast` (accurate is twice as slow, and we don't need correct spelling)
2. **crop reuse**: the collect stage already captured the full-screen image; at commit time, crop the current box directly out of that image (avoiding a re-screenshot)
3. **containment detection**:
   ```swift
   let innerBoxes = allOmniTargets.filter {
       $0 != current && current.rect.contains($0.rect)
   }
   ```
4. **Algorithm implementation** (simplified version of design doc §4.6):
   - Step 1: OCR out the `text_regions`, filtering out any whose `region.center in any innerBox.rect`
   - Step 1 non-empty: click the geometric center of the longest text segment
   - Step 1 empty + innerBoxes non-empty:
     - Use the simplified version: check whether `B.center` falls inside some innerBox
     - Doesn't fall in → use `B.center`
     - Falls in → take the midpoints of B's four edges, pick the one farthest from all innerBoxes
   - Full fallback: `B.center`
5. **Latency budget**: a single-box OCR is a few ms; adding 5-10ms to the commit path is acceptable
6. **logging**: log the refiner's decision path ("used own_text" / "used own_region midpoint" / "fallback center")

**Risks**:
- **Vision OCR Y-axis flip**: Vision uses a bottom-left origin, AX uses top-left. Mitigation: do the explicit coordinate-system conversion before cropping.
- **OCR misrecognition**: treating an icon as text. Doesn't matter — on the refiner path, any decision is no worse than box.center.

---

## P7 — End-to-end testing + data collection (3-5 days)

**Goal**: Verify the OP path is effective on real AX black-hole apps, tune parameters, and discover edge cases the design doc didn't cover.

**Test app matrix**:

| App | Framework | Expected path | Key check |
| --- | --- | --- | --- |
| Finder | appkit | AX-only | OP shouldn't trigger |
| Slack | electron | OP | hints cover the sidebar + message list |
| WeChat | electron | OP | the file list scans out |
| Wrike (Chrome) | webContent (via Safari/Chrome) | OP | inbox cards are clickable |
| New Outlook | webContent (Layer 2) | OP | the mail list is clickable |
| Music | catalyst | OP | the left-side playlists scan |
| System Settings | appkit | AX-only + FALLBACK | shouldn't accidentally trigger OP |
| VS Code | electron | OP (unless added to the whitelist) | editor/sidebar are clickable |

**End-to-end metrics**:

| Metric | Target |
| --- | --- |
| Cold start (first OP trigger, including model load) | < 1.5s (a one-time user-visible stutter is acceptable) |
| Hot path (OP already warm) | screencap + infer + filter + render < 400ms |
| Misclick rate | clicks with no response on the OP path < 10% (0 not required) |

**Data collection**:
- On each OP trigger, log details: `[mouseless] OP: bundle=<X> screencap=<Xms> infer=<Xms> boxes_raw=<N> boxes_filtered=<N> render=<Xms>`
- After a day or two of use, review the logs and look for:
  - false triggers (an appkit app going to OP)
  - missed detections (cases where the user falls back to the mouse)
  - misclicks (clicked with no response)
- Tune based on the data:
  - `confidence threshold` (default 0.3, may need 0.2 to pull recall up, or 0.4 to reduce false detections)
  - `AX_FOCUSED_WHITELIST` (add/remove apps based on hint quality observations)
  - whether the §5.2 exploratory filtering is needed

**Risks**:
- **Data takes time to accumulate**: 3-5 days may not be enough, but it can get 80% of the signal
- **OP slow enough for the user to notice**: if cold start > 2s, consider preloading (warm the model when idle after launch)

---

## P8 — Release packaging (1-2 days)

**Goal**: Fold the extra assets and permissions the OP path needs into the release pipeline.

**Output**: a releasable signed + notarized .app.

**Steps**:

1. **Model file bundling**: put the `.mlpackage` into `.app/Contents/Resources/`, and code signing covers it automatically
2. **Info.plist update**:
   - `NSScreenCaptureUsageDescription`: fill in something like "Mouseless needs to take screenshots on apps that don't support accessibility to identify clickable elements"
3. **Notarization verification**: the CoreML model won't trigger issues (Apple's own format); run `notarytool` once to confirm
4. **Settings panel update** (if there is one):
   - Show the routing decision for the current app (AX whitelist vs OP default)
   - Provide manual whitelist editing (add/remove bundleIDs)
   - Show the Screen Recording permission status
5. **README update**: explain that Electron support requires Screen Recording permission

**Risk**: low. A standard macOS app release process.

---

## Cross-phase concerns

### Error handling boundaries

Every new component must clearly define "what to do on failure":

| Component | Failure mode | Handling |
| --- | --- | --- |
| ScreenCapture | no permission / call failure | return nil, the OP path degrades to "no candidates," AX candidates are still available |
| CoreML inference | model load failure | log error, the OP path degrades to "no candidates," **Mouseless as a whole is still usable** |
| OCR | Vision call failure | the refiner falls back to `box.center` |

**Core principle**: if any link in the OP path goes down, **it only affects the focused-app sub-elements source** — the dock/menubar/extras AX sources keep working, and the user can at least hint to those.

### Telemetry / debugging

- Prefix all OP-path-related logs with `[mouseless OP]` for easy grep
- Debug mode (environment variable `MOUSELESS_OP_DEBUG=1`): dump the screenshot + box overlay image to `/tmp`
- Log the routing decision on each trigger (AX whitelist vs OP default + bundleID)

### Out of scope (not doing for now)

Explicitly state what **this version won't do**, to avoid scope creep:

- **Per-view AX/OP hybrid** (the Safari chrome + web view mentioned at the end of design doc §4.4): the first version is per-app only
- **Captioner** (design doc §3): not needed
- **§5.2 exploratory filtering**: add it only if P7 data shows a need
- **Caching OP candidates**: rerun detection every time (PoC data says a steady-state 140ms isn't worth the caching complexity)
- **Multi-display parallel scan**: the first version is focused-screen only
- **The "click point flash" affordance after CGEvent post** (end of design doc §4.6): a UX improvement, do it in the second version

### Configuration toggles

The release version needs at least two user-visible toggles (both on by default):

- `Enable OmniParser fallback`: the master switch (when off, it degrades to current behavior)
- `Show OmniParser hint badge` (debug): whether hints from the OP source are marked in a different color

---

## Acceptance checklist (the bar for all phases being done)

- [ ] On Slack / WeChat / Wrike / New Outlook, pressing Caps Lock shows hints, pressing a hint letter clicks the corresponding element, with a misclick rate < 10%
- [ ] On Finder / Mail / System Settings, the Caps Lock behavior is unchanged (OP shouldn't be triggered)
- [ ] Cold start first OP trigger < 1.5s, hot path < 400ms
- [ ] When Screen Recording permission is denied, the AX path still works and the OP path degrades gracefully
- [ ] The app passes notarization, with no console errors
- [ ] Docs updated: SPECS.md removes the Electron known gap, and the Caps Lock-triggered Electron apps are documented

---

## Rough timeline

| Phase | Estimate | Cumulative |
| --- | --- | --- |
| P0 decisions | 1-2 d | 2 d |
| P1 CoreML spike | 2-3 d | 5 d |
| P2 screenshot + permission | 1-2 d | 7 d |
| P3 framework detection | 2 d | 9 d |
| P4 integration seam | 2-3 d | 12 d |
| P5 baseline filtering | 1 d | 13 d |
| P6 OCR refiner | 2-3 d | 16 d |
| P7 end-to-end + data | 3-5 d | 21 d |
| P8 release packaging | 1-2 d | 23 d |

**~3-4 weeks of focused development**. Risk-adjusted (CoreML spike failing forces a switch to a Python sidecar): +1 week to ~5 weeks.

P0/P1/P2 can run in parallel (if you have the hands), compressing to ~3 weeks.

---

## Decision points (review at the end of each phase)

- **End of P1**: Is CoreML viable? If not → switch to a Python sidecar, adjust the P4 design
- **End of P3**: Is the framework detection hit rate reasonable? Every app in the test matrix should be classified correctly
- **End of P4**: After the merge, is there a regression in the commit path on AX-only apps?
- **End of P7**: Do the misclick rate / cold start / hot path all meet target? If not, review which step needs optimizing

---

## After P8: per-app correction layer (an important standalone module)

Once the OP path ships, it will expose that "there's no universal strongest standard" — OP isn't 100% accurate, the confidence threshold isn't universal, and missed detections / false positives vary by app. The solution is **per-app personalized correction** (possibly a product moat), with the design already locked in at
[`per-app-correction-design.md`](per-app-correction-design.md).

Core: **template matching to fill the fixed chrome icons that OP misses** (teach-by-example, self-gating, no model training needed) + pattern-based excludes to remove false positives + per-app confidence override. It is **not** per-app fine-tuning of the model (astronomical size/maintenance cost, already rejected).

Not implemented yet; kick it off once P7 data confirms this is a high-frequency pain point.
