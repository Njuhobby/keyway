# OmniParser Fallback — Design Notes

A design draft for wiring the visual path into Keyway. **Not an implementation plan** — a memo of "what we know so far and what we still have to decide."

**Core positioning**: AX is the primary path. AX is fast (steady state ~50ms) and information-rich (it gives you role, enabled, action). OmniParser is **only a fallback for when AX is clearly insufficient**. Fall-through, **not parallel**. Rationale in §4.

The PoC code lives **outside** the repo: `~/Desktop/keyway-omniparser-poc/` (throwaway, untracked).

---

## 1. Origin / Current State

`hint-discovery.md` §5 left a known gap: the ~500ms scan spike after a destructive click, whose root cause is that the target app's AX server sees its per-IPC latency blow up during cleanup. The spec held up the "OmniParser visual path" as a long-term direction: detached from the AX server, the scan is decoupled from its internal state, so the spike disappears naturally.

There's also a same-motivation case: **AX compatibility for Electron / complex web apps** (SPECS.md known gap #2). Apps like WeChat's file list / Wrike's SPA have a large number of AX elements that are `AXGroup` with no action and no label, so the hint path simply can't produce anything. The visual path routes around it.

PoC goal: first verify whether OmniParser's latency and recall on Apple Silicon are enough to carry this path, **then decide** whether to do a proper implementation.

---

## 2. PoC Results

Environment: `uv` + Python 3.11 + torch 2.11 (MPS) + ultralytics 8.4 + transformers 4.57, OmniParser-v2.0 detector (`microsoft/OmniParser-v2.0` HF repo, `icon_detect/model.pt`).

Detection-only data for three full-screen screenshots (2992×1934):

| Screenshot | Content | boxes | detect p50 | detect p90 |
| --- | --- | --- | --- | --- |
| `fullscreen.png` | Clash Verge settings + dock + menu bar mixed | 143 | 142.3 ms | 144.1 ms |
| `wechat.png` | WeChat chat list + desktop + status bar | 174 | 141.1 ms | 146.3 ms |
| `wechat2.png` | Chrome + Wrike SPA (actually a web black hole) | 177 | 111.1 ms | 118.5 ms |

**Key observations**:

- **Steady-state latency 110–145 ms**, well below the 300ms ceiling set in spec §5. p90 - p50 < 10ms; jitter is practically nonexistent.
- **Recall clearly higher than AX**. Wrike's inbox cards, task detail fields, every event in the Activity feed, Wrike's ~25 left-nav items — these are very likely a sea of `AXGroup` in the AX tree, and OmniParser scoops them all back in one shot.
- The WeChat file-list screenshot we tested (the AX = 0 hint view discussed earlier) — that screenshot was accidentally lost during the PoC, so we didn't get formal data, but the high recall on wechat.png from the same source app already corroborates it.
- **Cold-start detector load ~170s** (first-time weight download), subsequent startups 1s. In production the model is resident, so cold start is a one-time cost.

Conclusion per the spec §5 decision tree: **the OmniParser path is technically viable and worth a proper integration** — as a fallback, not a replacement.

The PoC overlay images live in `~/Desktop/keyway-omniparser-poc/screenshots/*_overlay.png`; they're the visual evidence for judging recall.

---

## 3. Captioner: Tried It, Shelved It

`OmniParser-v2.0` ships, alongside the detector, a Florence-2-based **icon captioner** (it emits a natural-language description per box, e.g. "Send button" / "User avatar with name"). **Tried it, hit a three-layer chain of version-incompatibility gotchas**:

1. `transformers==5.x` moved `forced_bos_token_id` out of config → the Florence-2 community modeling code fails to access it
2. Downgrading to 4.57, hit `_supports_sdpa` not being set (the Florence-2 code was written 2024-10, predating SDPA standardization)
3. Adding `attn_implementation="eager"` to route around it, hit `past_key_values[0][0]` being `None` (the KV cache interface changed in transformers 4.45+ to a `Cache` object, but the old code still indexes it as a tuple)

**Why we gave up** (instead of continuing to downgrade transformers to ~4.49 and filling all the holes):

- **Keyway doesn't need semantic captions**: the hint label is a two-letter code **we assign ourselves** (`as`, `af`...), not natural language. The captioner output contributes zero to the step of drawing a hint.
- The only scenario where the captioner could add value: inferring "this is a button / link / text field" from the box, so that under the OmniParser path you can pick the corresponding synthesized action. **But under the fall-through path, OmniParser is only enabled when AX is insufficient** — when AX is good enough, the role signal already came from AX; when AX is insufficient (a black-hole app), just synthesize a uniform mouse click, no further classification needed.
- Caption inference latency: Florence-2 base autoregressing ~20 tokens on MPS is roughly 50-200ms per box. Captioning 100+ boxes full-screen at once is in the seconds range — **it simply can't enter the real-time path**. Even captioning just the one selected box (after commit), by then the click has already happened, too late.

If we ever truly need captions in the future (e.g. for a secondary "clickability" filter on boxes), use an **OCR text probe** (easyOCR / the system Vision framework), which is an order of magnitude faster than a VLM caption. **But whether it's actually useful is, for now, speculation** — see §5.2.

---

## 4. OP-default: OmniParser primary, AX as fallback on a whitelist

> **This section has been rewritten 3 times**. First it was "AX primary, OP black-hole fallback" (fall-through), then "framework-detection routing," and finally it landed on the current "OP-default + AX whitelist." The reason each one was overturned is recorded in the "historical decisions" at the end of §4.4.

### 4.1 Why not parallel fusion

We previously considered "parallel + IoU fusion" — run both paths, merge candidates by IoU. **Vetoed**: parallel fusion introduces the complexity of IoU merging and reconciling the two sets of results, **while for any single app only one path is the real information source** (either AX is information-complete, or AX is information-empty) — fusion can't capture the corresponding value.

### 4.1a Also not "AX-default with OP fallback"

An intermediate version was AX-default: every app runs AX first, and OP only supplements when framework detection says it's AX-bad. This version was broken by WeChat — WeChat is native AppKit (its bundle is AppKit, and standard widgets like `AXTable` `AXRow` `AXColumn` are all in the AX tree), but **the chat message bubbles are custom NSViews, not in the AX tree**. The AX focus walk on WeChat returns ~58 candidates (plenty), yet **misses exactly what the user most wants to click** (messages, files, emoji).

This leads to: **framework ≠ AX quality**. Apps in the same pattern include QQ / DingTalk / Feishu / NetEase's family — a whole class of "**native AppKit but AX black hole**" that simply cannot be identified by bundle detection. The blacklist path would balloon without end.

See the "historical decisions" at the end of §4.4 for details.

### 4.2 Fall-through Flow

#### The AX walk is not one action, it's 4 independent sources

`HintMode.collectAll()` currently runs 4 AX sources simultaneously:

| Source | AX behavior | Can OP replace it? | Notes |
| --- | --- | --- | --- |
| **Focused app's child element tree** (in-window buttons / list items etc.) | Bad on Electron/WebContent/Catalyst | ✅ Yes — what OP captures from the focused window is exactly this layer | This is the **only** part that needs OP fallback |
| **Dock items** | Always good (Apple's native AX) | ❌ No — the dock isn't inside the focused window, OP's screenshot can't see it | Always provided by AX |
| **Focused app's AXMenuBar** | Always good (AppKit/SwiftUI rendered) | ❌ Same as above, the menu bar isn't inside the focused window | Always provided by AX |
| **Menu bar extras** (status icons) | Always good (Apple's native AX) | ❌ Same as above | Always provided by AX |

**Key insight**: the OP path **only replaces the first row**. The other 3 sources **keep doing the AX walk** under the OP path — they're both fast (dock + extras + menubar total ~50ms) and accurate (Apple-native, 100% coverage), and OP physically can't see them (the screenshot only covers the focused window).

#### Full flow

```
collectAll:
    # always run (OP can't see these 3 sources — dock/menubar/extras aren't inside the focused window)
    dock_targets       = AX walk: Dock                       // ~6ms
    menubar_targets    = AX walk: focused app's AXMenuBar    // ~7ms
    extras_targets     = AX walk: menu extras                // ~44ms

    # focused app's child element tree: OP-default, a few apps go AX
    if app.bundleID in AX_FOCUSED_WHITELIST:
        focused_targets = AX walk: focused app children      // ~150-200ms
    else:
        # default path — any app not in the whitelist
        screenshot      = capture focused window             // ~60ms warm
        visual_boxes    = OmniParser detect(screenshot)      // ~30ms
        focused_targets = apply_baseline_filters(visual_boxes)   // §5.1, ~5ms

    return dock_targets ∪ menubar_targets ∪ extras_targets ∪ focused_targets
```

**`AX_FOCUSED_WHITELIST`** is in `Sources/Keyway/AppRegistry.swift`. Initial contents: Apple's own AppKit apps (Finder, Mail, Safari, Pages, Xcode...), 10-15 entries. A third-party app must be empirically verified to have good AX coverage before it gets in.

#### Latency analysis (M3 Max, measured numbers)

**Whitelist path** (Finder / Mail / Xcode / ... the AX-excellent ones):

```
thread A: dock + menubar + extras AX walk    ~50ms
thread B: AX walk focused app subtree         150-200ms

user-facing = max(A, B) = 150-200ms
```

**OP-default path** (WeChat / Slack / VS Code / Tauri apps / anything not in the whitelist):

```
thread A: dock + menubar + extras AX walk    ~50ms
thread B: screencap + OP infer + filter      60 + 30 + 5 = 95ms warm

user-facing = max(A, B) = ~95ms
```

**Counterintuitive**: OP-default is **even faster** than the whitelist path — because the AX focus walk (150-200ms) is Keyway's heaviest operation, and once OP replaces it, wall-clock actually drops. The AX walk's speed advantage was in fact long since erased by modern ScreenCaptureKit + CoreML on Metal GPU (see the 29ms inference numbers from the P1 spike `omniparser-coreml-spike` + the 60ms warm screencap from P2's `ScreenCapture.swift`).

The whitelist is, performance-wise, **only equal/slightly worse**; the real reasons for its existence are different:
- Doesn't depend on the Screen Recording permission (only meaningful to users who genuinely don't want to grant it)
- AX elements carry role / label / state, which future mode expansions (selectText, drag) might use
- AX click precision is 100% (the box center is always clickable), so it doesn't need the OCR refiner of §4.6

After weighing it, we chose OP-default because: **universal coverage + simple decision (one set lookup) + faster on most apps**. The whitelist's two advantages aren't actually used by the current hint mode; they're for future expansion if needed.

### 4.3 Commit behavior per target class

| Source | sourceWindow | how to click on commit |
| --- | --- | --- |
| AX target | yes | Synthesize a mouse event to the rect center (see `hint-rendering.md` §3 — the AX action path is deprecated, everything goes through synthesis) |
| OmniParser-only target | no | Synthesize a mouse event to the box center (see §4.6 with the OCR refiner) |

The commit mechanism for the two paths is **completely unified**; the only difference is how the click point is computed (AX has a ready-made rect; OP needs the OCR refiner to handle the container-nesting problem).

The sticky rescan / `HintWindowCache` logic is retained — AX is the primary path, so the cache is valuable. The OmniParser branch re-runs detection every time (140ms steady state, not worth the caching complexity).

### 4.4 Path selection: OP-default + AX whitelist

**Decision**: bundle ID in `AX_FOCUSED_WHITELIST` → AX focus walk; everything else → OP path. The Dock / menubar / extras AX walk always runs (§4.2).

The implementation is in `Sources/Keyway/AppRegistry.swift`:

```swift
@MainActor
enum AppRegistry {
    static let axFocusedWhitelist: Set<String> = [
        "com.apple.finder",
        "com.apple.mail",
        "com.apple.Safari",
        "com.apple.TextEdit",
        "com.apple.Preview",
        "com.apple.calculator",
        "com.apple.Terminal",
        "com.apple.Console",
        "com.apple.ActivityMonitor",
        "com.apple.Pages", "com.apple.Keynote", "com.apple.Numbers",
        "com.apple.iCal",
        "com.apple.dt.Xcode",
        "com.apple.Notes",
    ]

    static func shouldUseAXForFocused(bundleID: String) -> Bool {
        return axFocusedWhitelist.contains(bundleID)
    }
}
```

#### Maintenance principles

- **Conservative admission**: a third-party app gets in only after empirical testing + subjective confirmation that "the AX-path hint experience in this app is clearly better than the OP path." The default is OP.
- **Errors are harmless either way**: the whitelist misses an AX-good app → spend an extra ~80ms running OP (OP can also give good hints), no impact on functional correctness. The whitelist wrongly admits an AX-bad app → the user directly observes "hints in this app are missing key things," and you just remove it. **Neither error direction is fatal, but missing is cheaper than wrongly admitting**.
- **No reliance on auto-detection**: the previous design round tried framework detection to auto-classify (Catalyst / Electron / WKWebView / self-rendered), but WeChat broke the "native = AX-good" assumption (see the third round in the "historical decisions" below), proving auto-detection unreliable. **Manual whitelist + cheap errors = the right tradeoff**.

#### Whether to refine per-view (not for now)

Ideally:

- Safari → chrome (AppKit, good) + web view (per-site varies)
- Xcode → editor (good) + integrated doc viewer (WebKit)
- VS Code → menu bar (native, good) + editor (Monaco) + bottom panel

Strictly speaking it should be judged per-view. **The first version is good enough at the app granularity for 80/20**. Whichever app truly needs per-view splitting gets handled separately.

#### Historical decisions

This section **went through three reversals**:

**Round 1 (overturned)**: it was originally written as "count threshold is the primary signal" — trigger OP when the AX candidate count is < N. Found it inaccurate at both ends: AX-bad apps often return a falsely high count (menu bar / dock / sidebar add up to 30+ but the actual content area = 0), and AX-good apps occasionally have a legitimate low count (an empty Finder window, a simple dialog). **Changed to "framework detection first + count as a safety net."**

**Round 2 (overturned)**: the first version of framework detection only used bundle-layout (Catalyst Info.plist / Electron Framework path), missing WKWebView-wrapped web shells (New Outlook, Teams, the new OneNote). **Changed to "two-layer detection: bundle fast path + AXWebArea BFS fallback"** — Layer 2 BFS to depth 5 hits the vast majority of web-kernel apps (Clash Verge / Tauri etc. also covered).

**Round 3 (overturned — this time)**: empirical testing of WeChat broke the core assumption "**non-native = AX-bad / native = AX-good**." WeChat is genuine native AppKit (its bundle contains swift dylibs and .nib resources, and the AX tree has AppKit-standard widgets like `AXTable` `AXRow` `AXScrollArea`), but **the chat message bubbles are custom NSViews, completely invisible to AX** — the AX focus walk returns 58 candidates (plenty), yet all of them are sidebar and nav, with **0 candidates for the message content the user actually wants to click**.

WeChat is not an isolated case: QQ / DingTalk / Feishu / NetEase's family — a whole class of native apps from large Chinese vendors — all follow this pattern. Once "framework ≠ AX quality," the entire framework-detection routing loses its foundation — the blacklist path is unsustainable.

**Changed to "OP-default + explicit AX whitelist"**:

- The OP path **works for all apps** (including AX black holes like WeChat that are "native + self-rendered")
- The OP performance data (screencap 60ms warm + CoreML inference 29ms = ~95ms parallel with AX 50ms = max 95ms wall-clock) is **already faster than the AX focus walk** (the AX focus walk alone takes 150-200ms). The cost of OP-default is only the Screen Recording permission requirement and slightly lower click precision (compensated with the OCR refiner, §4.6).
- The decision mechanism is simplified to a single `Set<String>` lookup, with **no auto-detection, no cache, no BFS, no fallback chain**.

`FrameworkDetector.swift` has already been deleted from the codebase (preserved in git commit `04f57f4` for future reference).

This history is kept to **warn future readers**: the reflex on every wall hit was "add one more layer of heuristic detection to make it smarter," but in reality **a manual whitelist is cheaper, more controllable, and more explainable than auto-detection**. Before you next want to "auto-detect AX-bad apps," first ask "why don't we just maintain a whitelist?"

### 4.5 Relationship to the AX stall spike (hint-discovery.md §5)

The ~500ms AX cleanup period after a destructive click:

- Now: the sticky rescan runs into the cleanup period, the per-IPC unit cost spikes to 40ms, and the scan takes 500ms.
- After wiring in OmniParser: fall-through by itself doesn't relieve the spike, **because the AX candidate count is still high** (the AX return value during cleanup doesn't necessarily shrink). You'd need to separately detect an "AX is busy" signal to switch to the OmniParser fallback.
- The more likely actual fix: **wait for AX to stabilize** (the event-driven wait-for-notification approach mentioned in hint-discovery.md §5) + **OmniParser is still only used for AX black-hole scenarios**. The two solve different problems.

OmniParser is **not** a silver bullet for the AX cleanup spike. It's the fallback for AX black-hole scenarios. In the last version of SPECS.md I said "once OmniParser lands, this spike disappears naturally" — that was wrong; that spike has to be fixed separately.

### 4.6 The precision problem of OmniParser commit

The AX path's commit is coordinate-independent — `AXUIElementPerformAction(element, "AXPress")` dispatches by element reference, and the element's on-screen position doesn't matter. The OmniParser path **has no element**; commit can only synthesize a mouse event to an `(x, y)` coordinate, and **that coordinate must land inside the truly clickable region**.

This introduces to the OP path a class of failure that doesn't exist under the AX path: **the hint appears, the user presses, the synthesized click succeeds, but the clicked position misses the actual click handler, and the UI doesn't change**.

#### The click point and the hint label's visual position are two different things

Don't conflate them. We reuse the AX path's current label layout logic (the badge next to the element, not occluding content, cascading when dense, etc., see `hint-rendering.md`), but **the target coordinate of the synthesized click on commit is not the same as the label's visual position**:

```swift
// wrong:
synthesizeClick(at: target.labelPosition, ...)

// right:
synthesizeClick(at: target.clickPoint, ...)
// where clickPoint is a genuinely clickable pixel inside the box
```

How `clickPoint` is computed is below.

#### Failure modes of the click point

The box center is **not always** a clickable pixel. 5 classes:

1. **Box framed with an offset**: the detector output has edge jitter, and the geometric center lands in the padding or outside the border.
2. **Clickable region ≠ visual region**: in a web app the click handler is on an outer `<div>` and the visible button is a `<span>`, or vice versa; OmniParser only sees visuals and can't see the hit-test boundary.
3. **Transparent overlay intercepts**: a click-eating layer covers a modal, and the click lands on it instead of the target underneath.
4. **HiDPI coordinate system**: the screenshot is in physical pixels, but the synthesized event uses logical points. **Get the conversion wrong and you click thin air.** This is the implementation side's life-or-death must-get-right.
5. **Container nesting**: a big box wraps a small box (both kept when IoU is below the NMS threshold), the big box's geometric center lands inside the small box's region, and pressing the outer hint instead triggers the inner target's click handler.

Class 4 is an engineering problem (must be correct); classes 1-3 + 5 are the OP path's **inherent probabilistic failures** — completely nonexistent under the AX path. The refiner below **only handles class 5** (container nesting) — it's the only class that can be cheaply detected without OCR and where the OCR fix has clear payoff. For classes 1 and 2 (box offset / clickable ≠ visual), the box-center hit rate is already high enough in practice, and blindly applying OCR introduces new errors instead (see "historical decisions" below); classes 3 and 4 the refiner can't handle.

#### The implemented version: fast-path first, OCR only when the center conflicts

> Implementation in `Sources/Keyway/OCRRefiner.swift`. **The early draft (preserved in the "historical decisions" below this section) was "blind OCR first" — empirical testing overturned it, and it's now "first judge whether the center really has a problem, OCR only when there is one."**

Observation: **clicking text almost always hits the click handler** (text is inside the visible region, close to center). But **"OCR out some text and click the text center" is wrong** — empirically, on WeChat chat rows:

- A chat row is "the whole row is clickable" — clicking any pixel in the row triggers selection
- The box center already works
- But OCR only recognizes the corner "21:52" timestamp (missing the Chinese name / message), and the refiner instead drags the click **from the row's center to the top-right "21:52"** — worse

Lesson: **the OCR refiner should only step in when the box center "really has a problem."** How do you judge there's a problem?

Of the 5 misclick classes listed in §4.6, only **class 5 (container nesting) can be cheaply detected without OCR** — just check `box center ∈ some inner box`. Class 1 (box framing offset) is rare, and the risk of OCR misjudgment outweighs its payoff. So:

```
refine(B, inner_boxes):
    center = B's geometric center

    # Fast path: center isn't in any inner box → use center directly
    # Covers the vast majority (chat rows, list items, un-nested buttons).
    # Zero screencap, zero OCR, zero extra latency.
    if center ∉ any inner_box:
        return center

    # Slow path: center lands in some inner box → clicking it triggers the inner box's
    # handler rather than B's own. Re-screencap + OCR B's crop, find a point
    # "inside B, but avoiding all inner boxes."
    text_regions = OCR(B.crop)        # .accurate + explicit Chinese languages

    # Step 1: own_text = text whose center isn't inside any inner box
    own_text = [t for t in text_regions if t.center ∉ any inner_box]
    if own_text is non-empty:
        return the center of the longest own_text segment

    # Step 2: no own_text (all text belongs to inner boxes) → find own_region
    #   candidates = [B center, midpoints of B's four edges]
    #   filter out candidates that land in an inner box
    #   take the one among the rest farthest from all inner boxes
    candidates = [B.center, top_mid, bottom_mid, left_mid, right_mid]
    outside = [c for c in candidates if c ∉ any inner_box]
    if outside is non-empty:
        return the one in outside farthest from inner boxes
    # Step 3: all candidates are in inner boxes (pathological, B is almost fully covered by inner)
    return B.center
```

The design principle is unchanged (**two hints = two independent targets, the outer click must avoid the inner box's coverage area**), but **the trigger condition is tightened**: it's not "use it whenever there's OCR text," but "only invoke OCR when the center really collides with an inner box."

#### The concrete handling for each case

| Scenario | Which path it takes |
| --- | --- |
| Chat row / list item / plain button (no inner box, or center doesn't collide with inner) | **fast path** → click the box center, no OCR |
| Big box wraps a small box, the small box contains text, **and the big box's center happens to rest on the small box** | slow path: OCR → Step 1 own_text (the big box's own text) or Step 2 own_region |
| Big box's center rests on a small box + the big box has its own title "Tech Backlog" | slow path → own_text = ["Tech Backlog"] → click its center |
| Big box's center rests on a small box + the big box has no text of its own | slow path → own_text empty → Step 2 own_region (the edge midpoint farthest from inner) |
| Big box's center does **not** rest on the small box (the small box is off to one side) | fast path → click the big box's center (the center is already the big box's own region) |

The key distinction: **only "the big box's center happens to rest on the small box" enters the slow path**. "Big box wraps a small box but the small box is off in a corner" → the big box's center is still in its own region → fast path.

#### CJK OCR configuration (an implementation detail, but load-bearing)

The slow-path OCR must be able to recognize non-Latin characters, otherwise the containment algorithm fails on Chinese/Japanese/Korean UIs:

```swift
request.recognitionLevel = .accurate         // .fast is a Latin-biased character detector, misses CJK
request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]  // explicit, otherwise follows the system locale
request.usesLanguageCorrection = false       // UI text isn't sentences
```

`.fast` empirically only recognizes things like the digits "21:52" on WeChat, missing CJK text (names, message content) entirely. With `.accurate` + explicit Chinese languages configured, that CJK text is recognized too. The cost is ~20-40ms, but the slow path is rare to begin with.

#### The simplified implementation of own_region

The full version `own_region = B.rect minus union(inner_boxes.rects)` (axis-aligned rectangle subtraction, result is an L-shape / frame shape) is more precise in theory but complex to implement. We currently use an **edge-midpoint approximation**: candidates = {B center + four edge midpoints}, filter out those that land in an inner box, take the one farthest from inner. ~10 lines, behaves correctly for most cases. Upgrade to full polygon subtraction once a boundary case is observed failing.

#### The failure modes this path handles

Back to the 5 misclick classes listed earlier in §4.6:

- **Class 1** (offset box): not handled under the fast path (accept the box center, rare and OCR risk > payoff)
- **Class 2** (clickable region ≠ visual): same as above, fast path accepts the box center
- **Class 3** (transparent overlay intercepts): the refiner is powerless ✗
- **Class 4** (HiDPI coordinate system): an engineering problem, unrelated to the refiner ✗
- **Class 5** (container nesting causing the outer hint to mis-click the inner target): **the slow path handles it specifically** ✓

Note the difference from the early draft: the draft claimed the refiner handled classes 1 and 2 ("click text, avoid padding"), but empirical testing found **the new errors introduced by blind OCR (chat rows dragged to the timestamp) outnumber the class 1 and 2 cases it fixes**, so it was tightened to handle only class 5. Classes 1 and 2 are left to the box center — empirically, most OP box centers are clickable.

#### Historical decisions

The §4.6 refiner algorithm went through one empirical reversal:

**Draft version (discarded)**: on commit, **blindly** OCR the box → Step 1 take the center of the longest own_text → Step 2 own_region → Step 3 box center. The rationale was "clicking text always hits the handler."

**Empirical reversal**: WeChat chat rows — OCR in `.fast` mode only recognized the "21:52" timestamp (missing the Chinese), and the refiner dragged the click from the row's center to the top-right timestamp, **worse than just clicking the box center**. Even if CJK recognition is fixed (`.accurate`), blindly taking "the longest text" on a multi-text row isn't necessarily the position the user wants to click.

**Revised version (current)**: fast-path first — if `box center ∉ any inner box`, use the center directly (covers the vast majority), and **only invoke OCR when the center really collides with an inner box (the class-5 container nesting)**. This both saves 60-90ms (most clicks do no screencap/OCR) and avoids OCR misjudgments.

Lesson: **a "theoretically more precise scheme" (blind OCR) can be empirically worse** — OCR itself has a probability of recognition failure / incompleteness, and putting it in the critical path of every click means stacking its failure probability on top. Using it only when "not using it is sure to be wrong" (the center colliding with an inner box) is the more robust engineering choice.

#### Deliberately not handled: partial overlap

The condition under which NMS (§5.1.4) lets two boxes both survive is `IoU < 0.5`; containment is just one special case of that — in theory two boxes could also partial-overlap (not containing each other, but intersecting), with both centers landing in the intersecting text.

In the three PoC images we **did not observe** the detector outputting this partial-overlap shape — containment is common (a conversation row wrapping an avatar/name), partial overlap is almost absent, because visual UI elements shouldn't be mutually misaligned and overlapping in the first place.

The algorithm could in theory be generalized in one line (replace `b.rect ⊂ B.rect` with `intersects(b.rect, B.rect)`, with the own_region computation applying as-is), but **we don't add it ahead of time for an unobserved case** — same discipline as §5.2.

If later, after wiring it into the prototype, we actually see partial-overlap-caused misclicks in the commit log, then literally change `inner_boxes` to `overlapping_boxes`, leaving the algorithm skeleton untouched.

#### Why OCR is grounded here (vs the OCR-as-filter of §5.2)

In the earlier §5.2 draft, OCR was used as a filter ("box with no text → drop"), which was speculation — a pure-icon button has no text but is genuinely clickable, and dropping it loses it.

OCR as a **click-point refiner** is a different trade-off:

| Dimension | OCR-as-filter | OCR-as-refiner |
| --- | --- | --- |
| Trigger timing | collect path (runs on every scan) | commit path (runs only on the one box the user selected) |
| Full-screen cost | 50-200ms / full screen | a few ms / single box |
| Consequence of OCR failure | drops a clickable box by mistake, **the user never even sees the hint** | degrades to the box center as fallback, **equivalent to not using OCR** — lossless |
| Consequence of OCR misrecognition | affects the filtering decision | at most affects "click text A or text B," both of which are inside the box, both safer than the edge |

The refiner usage is **never worse than not using it under any circumstance**. This is the fundamental difference from the filter usage.

#### Implementation details

- macOS Vision framework: `VNRecognizeTextRequest`, hardware accelerated, no external ML dependency
- crop region: crop the box out of the full-screen screenshot (the screenshot itself was already taken in the collect phase; reuse the same one at commit)
- single-box OCR wall-clock: in the few-ms range, the extra latency on the commit path is negligible
- if there are multiple text segments inside the box, take the center of the longest one (usually the button label, closer to the click handler than short ancillary text like a hint/tooltip)

#### User-perceived comparison

| Failure mode | AX path | OP path (without OCR refiner) | OP path (with OCR refiner) |
| --- | --- | --- | --- |
| element has no hint at all | user switches back to mouse | user switches back to mouse | same |
| clicked, no response | almost never | occasional (box offset / clickable ≠ visual) | markedly reduced (clicking text ≈ certain to hit clickable) |

The OCR refiner pulls the OP path's "hint appears ≠ definitely effective" closer to the AX path's "hint appears ≈ definitely effective."

#### An observable affordance after commit

Even with the OCR refiner added, misclicks can still happen. Consider briefly highlighting the click point after commit — to at least let the user know "the system clicked this position." If the UI doesn't respond, the user knows it's a precision problem of the OP path (vs suspecting Keyway didn't receive the key) and can switch to the mouse and retry. It's a small UX investment that's meaningful for both debugging and trust.

---

## 5. Filtering design for the OmniParser path

The AX path relies on `clickableRoles` + `hasMeaningfulLabel` + `skipRoles` to compress the candidates down to 50-100. The OmniParser detector output is unfiltered — 174 boxes on wechat.png — and **making hints for all of them produces label inflation** (the screen carpeted with yellow labels).

Filtering is mandatory. But **which filter rules are reliable and which are guesses** must be kept distinct.

### 5.1 Baseline: standard CV post-processing (verified, safe to use)

This group of filters is independent of UI semantics; it's standard object-detection post-processing, already validated by the ML community on tens of millions of images. **These are must-adds at ship time.**

Four of them:

1. **YOLO confidence threshold**
2. **Size minimum** (≥ 8×8)
3. **Size maximum** (occupies < N% of the screen)
4. **NMS dedup** (IoU-based deduplication)

Each is expanded below.

#### 5.1.1 YOLO confidence threshold

Each box comes out of the detector with a `[0, 1]` confidence score, representing the model's certainty that "this is an interactive UI element."

- Implementation: `box.confidence >= threshold`, threshold typically 0.3-0.5.
- Effect: cuts the detections the model itself isn't sure about, which are mostly false positives.
- How to set the threshold: **this value needs to be swept on UI screenshots** — 0.3 too loose misses some low-conf but actually-clickable elements, 0.5 too strict drops some half-visible legitimate targets. **The PoC stage ran with loose values like 0.05 ~ 0.3** (the 100-180 boxes in the PoC data are a product of the loose threshold); for actual ship, decide based on "the box hit rate on AX black-hole apps."

#### 5.1.2 Size minimum

- Implementation: `rect.width >= 8 && rect.height >= 8`.
- Effect: cuts the few-pixel detection noise.
- Same condition as the AX path (`hint-discovery.md` §2.2, the 2nd admission condition).
- This one almost never mistakenly kills a real UI element — even the smallest icon button is a dozen-plus pixels.

#### 5.1.3 Size maximum

- Implementation: `rect.width * rect.height <= MAX_SIZE_FRAC * screen.area`, with `MAX_SIZE_FRAC` set to 0.25 ~ 0.5.
- Effect: cuts the big boxes the detector outputs when it mistakes a whole panel / sidebar / window for an interactive element.
- **Why a separate rule is needed**: intuitively "NMS should dedup away the big box that covers a small box," but **in fact it won't** — see the NMS-meaning explanation after §5.1.4.
- Empirically, the three PoC images didn't have such big boxes, but **we can't assume it'll never happen**: edge UIs the training data doesn't cover, the model hallucinating the container layer for certain web apps, or future detector-version changes could all produce them. **A geometric sanity check costs almost nothing to add, and the cost of missing it is one more useless, large-area-covering hint label on the screen.**
- Note: this rule doesn't distinguish "fills the whole screen" from "takes up 30% of the sidebar" — both are size levels a user would almost never click as a hint target. If we later find some legitimate UI (e.g. a full-screen dialog) being mistakenly killed by it, then tune frac or add a role-aware exception.

#### 5.1.4 NMS dedup (**with an NMS behavior explanation**)

- Implementation: standard Non-Maximum Suppression. Compute the IoU between every pair of boxes; for a pair with IoU above the threshold (typically 0.5), keep the higher-confidence one and suppress the lower-confidence one.
- Effect: the detector sometimes outputs two adjacent boxes for the same UI element (typical example: an icon + its adjacent label each getting a box, or one element detected twice with overlapping output). NMS dedups these "near-coincident" ones, keeping one representative.

**Here we need to make clear one counterintuitive thing: NMS does not dedup "containment" overlaps**, i.e. the scenario where a big box fully wraps a small box. The reason is that NMS uses **IoU** (Intersection over Union), and IoU is:

```
IoU = intersection area of the two boxes / union area of the two boxes
```

Consider a big box fully wrapping a small box:

```
big box:  1000×800 = 800,000 px²
small box:  50×30  =   1,500 px²

Intersection = 1,500 px²        (the small box's own area, since it's entirely inside the big box)
Union        = 800,000 px²      (≈ the big box's area, the small box being a subset of it)
IoU          = 1,500 / 800,000 = 0.0019
```

IoU ≈ 0, far below the NMS threshold of 0.5, so **NMS won't touch these two boxes — both are kept**.

This is why §5.1.3 must exist: **NMS doesn't guard against big boxes polluting the candidate set**. The two rules each cover one side:

- NMS handles "two roughly equal-sized boxes overlapping by ~50% or more" (dedup).
- Size maximum handles "a box too big to be an interactive element" (rejecting giant false positives).

The two don't overlap, and neither is dispensable.

#### How much these four together can compress to

Empirically, all three PoC images are in the 100-180-box range of **unfiltered** output. Adding these four usually compresses to 60-100, **without introducing any UI heuristic** — pure ML / geometric post-processing. The remaining filtering (if still needed) can only rely on the exploratory signals of §5.2, which need data to back them up.

### 5.2 Exploratory: UI heuristics (need data, currently speculation)

The rules below **sound reasonable**, but **whether they're actually effective on real UIs is, for now, unknown**. We need to wire OmniParser into the prototype, run it across a number of AX black-hole apps, and look at the data before deciding:

| Candidate rule | Intuition | Question to validate |
| --- | --- | --- |
| **Size × confidence combination**: small boxes kept only when conf is high | a big box + low conf is mostly a false-positive container | What threshold? Is the same rule consistent across web apps vs native apps? |
| **Aspect ratio filter**: extremely wide / extremely tall boxes → drop | decorative horizontal lines / dividers | A wide-span toolbar is also extremely wide; how do you distinguish them? |

**Conclusion**: at ship time, use **only the §5.1 baseline filtering**. These exploratory ones — decide whether to add them once we actually have data from OmniParser-on-AX-bad-apps. **Don't preset rules ahead of time without data.**

> **OCR is not in this section** — it was indeed initially listed among the exploratory filters ("box with no text → drop"), but after analysis it was moved to the §4.6 commit-time refiner position. See the comparison table in §4.6 for the difference. In short: the filter usage is speculation, the refiner usage is grounded.

---

## 6. Open questions for integration

To be answered before a proper implementation:

### 6.1 Process boundary

OmniParser is a PyTorch model; there's no way to cram it into the Swift process. Three candidate architectures:

| Scheme | Pros | Cons |
| --- | --- | --- |
| **Python helper process + XPC** | OmniParser runs natively, no model conversion needed; can be upgraded independently | hand-roll the Swift ↔ Python IPC; ship the Python runtime + venv alongside the .app; slow startup |
| **CoreML conversion + Swift inference** | single binary, fast startup, Apple Neural Engine acceleration | YOLO → CoreML is feasible (ultralytics has an export tool), but Florence-2 → CoreML is hard; at least the detector part can convert |
| **subprocess (python script) + stdio** | crude and simple | spawn Python on every detect? or a long-resident worker + stdio protocol, about as complex |

#### P1 spike experiment result ✅ CoreML selected

`~/Desktop/keyway-omniparser-coreml-spike/` got the PyTorch → CoreML conversion + inference benchmark working. Conclusion: **the CoreML path is far better than expected.**

**The conversion process** (a few pins to get right):

- `yolo export model=icon_detect.pt format=coreml nms=True` directly is a dead end — hits a coremltools `_int` operator bug
- root cause: numpy 2.x removed the implicit conversion of multi-element arrays to a Python scalar, but coremltools 8.x's torch frontend code is still written for numpy 1.x
- fix: pin `numpy<2.0` + `coremltools>=8.0,<9.0` + `torch>=2.2,<2.5` + `ultralytics>=8.2,<8.4`
- the ONNX intermediate path is **dead**: coremltools 8.x completely removed the ONNX frontend, no longer supported
- summary: the toolchain must follow the pins above at export time, but the **runtime has no Python dependency**

**Inference latency** (M3 Max, 1280×1280 input, pure CoreML.framework calls, ultralytics wrapper stripped):

| compute_units | p50 latency |
| --- | --- |
| CPU_ONLY | 145ms |
| CPU_AND_NE (ANE) | 42ms |
| ALL (runtime auto-selects) | 43ms |
| **CPU_AND_GPU (Metal)** | **29ms** 🏆 |

For reference: the PoC reported PyTorch + MPS at 110-140ms. **CoreML + GPU is 4-5x faster than PyTorch MPS**, 10x faster than the design target of 300ms.

**Surprising finding**: **GPU is 30% faster than ANE**. This is consistent with the practical engineering experience that "YOLO is a convolution-heavy network, the Metal GPU pipeline is highly efficient, and ANE is better suited to attention-heavy networks (like Transformers)." The production implementation should use `MLModelConfiguration.computeUnits = .cpuAndGPU`, **not** the default `.all` or an explicit `.cpuAndNeuralEngine`.

**Recall quality**:

- CoreML raw output has 30-40% fewer boxes than PyTorch (fullscreen 143→83, wechat 174→112, wechat2 177→133)
- reason: `nms=True` export bakes a conf threshold of ~0.25 into the model, filtering out low-conf detections
- those cut low-conf boxes **were the ones the §5.1.1 conf>0.3 baseline filter would drop anyway** — production impact = 0
- after adding the conf>0.3 baseline filter, CoreML's final output is 75/111/126 boxes, almost aligned with PyTorch + conf>0.3
- visual overlay spot-check: chat list, menu bar, dock, message bubbles, desktop icons each got boxes, quality consistent with the PoC

**Model output schema**: the CoreML model has two tensor outputs —

```
coordinates: (N, 4)   // [cx, cy, w, h], normalized to the [0,1] of the 1280×1280 input space
confidence:  (N, 80)  // confidence across 80 classes for each box
```

YOLO11m is multi-class trained (80 classes, COCO standard), but the OmniParser fine-tune data all collapses to one class. Production code takes `confidence.max(axis=1)` as the box's conf, **not caring about the specific class**. Coordinates must be multiplied by the original image size to restore to screen space.

**Decision**: choose #2 (CoreML in Swift). The rationale isn't just "single-binary deployment," but "absurdly fast + an order of magnitude simpler than #1's IPC + Python runtime." Full roadmap in [`omniparser-integration-roadmap.md`](./omniparser-integration-roadmap.md) P2/P4/P8.

The PoC v2 throwaway spike is in `~/Desktop/keyway-omniparser-coreml-spike/`, `rm -rf`-able any time — production doesn't need it.

### 6.2 Model resident vs on-demand load

The model weights are ~30MB (detector). Resident ANE/MPS memory is ~200-500MB.

- **Resident**: load when the menu bar app starts, infer directly on every trigger. Lowest latency.
- **On-demand**: load on first trigger, possibly a 1-2s stall; resident thereafter.

**Fall-through changes this trade-off**: OmniParser isn't used every time; the user may not trigger it at all most of the time. 500MB resident memory is wasted 99% of the time.

Leaning toward: **load on first need + resident thereafter** (lazy load + don't unload). A slight stall the first time on an AX-bad app is acceptable, then back to steady-state latency.

### 6.3 Trigger decision

`AX_USEFUL_THRESHOLD` was already discussed in §4.4. Here we just reiterate: **this decision needs data**. At ship time, use the most conservative `N=0` first, run it for a while to see how often "OmniParser actually gets triggered," then tune.

### 6.4 Screenshot source + scope (decided)

#### Scope: **only capture the focused window** (not the full screen, not the focused screen)

During discussion we considered three scopes:

| Scheme | Pros | Cons |
| --- | --- | --- |
| Full screen | simplest API | overlaps with the AX path on the Dock / menu bar, producing label conflicts; after 3000×2000 → 1280² resize, small icons approach the model's recognition floor, discounting recall; privacy-wise it feeds content unrelated to the user's current task into the ML pipeline |
| Focused screen | filters out other screens in a multi-display scenario | still includes the Dock / menu bar / desktop / other windows, the overlap and recall problems unsolved |
| **Focused window** | clean division of labor with the AX path; a 1500×900 window → 1280² resize gives small icons a scale of ~0.85 for higher recall; privacy-wise it only looks at the user's current window | slightly more complex API (first AX to get the windowID, then ScreenCaptureKit to capture the specific window) |

**Decision: focused window**. Rationale — the AX path is **always good** on the Dock / menu bar / menu extras (these Apple-native AX have 100% coverage), so there's no need for OmniParser to redundantly recognize them. OmniParser **precisely** supplements the AX black-hole problem — **the child elements inside the focused window** — so the screenshot scope is complementary to, not overlapping with, the AX path.

> **Note: the implementation block below is outdated.** The actual `ScreenCapture.captureFocusedWindow` uses "capture the whole display, then crop by the window rect" (reading the already-composited framebuffer, faster than `desktopIndependentWindow`'s forced re-render), no longer using `_AXUIElementGetWindow` / CGWindowID. It also carries an `isolateApp` switch: the rescan after a sticky app switch uses `SCContentFilter(display:excludingApplications:[dockApp])` to **exclude the Dock process**, removing the Cmd+Tab switcher HUD (a window owned by Dock) from the screenshot — otherwise OP would recognize the app icons on the switcher as hints. See `modes.md` §4.2 for details.

#### Can AXFocusedWindow be obtained on AX-bad apps too? ✅ Yes

The AX tree has two layers:

- **The top-level window skeleton** (AXApplication → AXWindow → AXPosition / AXSize / AXTitle): **correct on any app** — the macOS system framework registers it automatically when the NSWindow is created, not dependent on the app's own AX implementation quality
- **The in-window child element tree** (AXChildren recursive): **this is the layer that becomes an AXGroup black hole on Electron / WKWebView / Catalyst**

The OmniParser path only reads the top level (where the window is, how big, the CGWindowID), and **never touches the child element tree** — so it works equally on AX-bad apps. From this angle OmniParser is "an excellent client of the AX top-level metadata + a replacement for the child element tree."

Edge cases:

| Scenario | Handling |
| --- | --- |
| The focused app has no window (a menu bar agent app) | `AXFocusedWindow` = nil → OmniParser doesn't trigger, the AX path handles the menu bar |
| Multiple windows visible at once (several Finders) | The first version only captures `AXFocusedWindow`; decide by observation whether to extend to all AXWindows |
| The focused window is partially occluded by other windows | ScreenCaptureKit's `desktopIndependentWindow` mode ignores occlusion and draws the full window content — exactly what we need |
| Full-screen games (self-rendered, bypassing NSWindow) | Rare. The whole of Keyway can't work in a game to begin with, a known limitation |

#### Implementation path: ScreenCaptureKit per-window

```swift
// 1. AX gets the focused window element
guard let focusedWindow = focusedApp.attribute("AXFocusedWindow") as? AXUIElement
else { return .axOnly }   // no window, OP doesn't trigger

// 2. Get the CGWindowID (private API but stable: _AXUIElementGetWindow)
var windowID: CGWindowID = 0
guard _AXUIElementGetWindow(focusedWindow, &windowID) == .success
else { return .axOnly }

// 3. ScreenCaptureKit captures it
let content = try await SCShareableContent.current
guard let scWindow = content.windows.first(where: { $0.windowID == windowID })
else { return .axOnly }
let filter = SCContentFilter(desktopIndependentWindow: scWindow)
let image = try await SCScreenshotManager.captureImage(
    contentFilter: filter,
    configuration: SCStreamConfiguration()
)
```

**Comparison of API candidates**:

- ✅ **ScreenCaptureKit (`SCScreenshotManager`)**: modern API, native per-window support, automatically handles multi-display / HiDPI / window z-order
- ⚠️ `CGWindowListCreateImage`: legacy, can do per-window but marked deprecated since macOS 14+
- ❌ `CGDisplayCreateImage`: full-screen only, doesn't fit our need

Choose ScreenCaptureKit.

#### Screen Recording permission

**This is one more authorization gate added on top of AX** — the permission model is "AX + Screen Recording."

Permission-request strategy (**changed from lazy to a hard startup gate**):

- Early on it was lazy: don't request at startup, pop the `CGPreflightScreenCaptureAccess()` prompt the first time you land in an OP app, and if not granted the OP path degrades to "no candidates" (the AX candidates are still available).
- **Now it's a hard requirement** (`AppDelegate.ensureScreenRecording()`, alongside `ensureAccessibility()`): both permissions are checked at startup, both prompts are popped, and **the app only launches once both are satisfied** (otherwise `M⚠` + lists which is missing + a prompt to grant and restart). The reason for the change: Screen Recording is now used by more than just OP — the **content settle watch** (`WindowFingerprinter` low-resolution thumbnail, see mechanisms 1/2 in `modes.md`) also relies on it; without it, OP-routed apps get no hints at all, and every app-switch/commit rescan falls back to a blind delay. OP is core value, not worth keeping a half-crippled experience for "users who only want to grant AX."
- Screen Recording authorization is **cached in-process**; after granting, a **restart** is needed for it to take effect (`CGRequestScreenCaptureAccess()` still returns false in the current run) — consistent with macOS's behavior for other apps. The runtime capture still keeps a `CGPreflightScreenCaptureAccess()` guard (in case the user revokes it in Settings while running); if revoked, capture returns nil and degrades gracefully.

#### Coordinate-system alignment

The boxes OmniParser outputs are normalized coordinates (0-1) within the window screenshot. To restore them to screen coordinates for synthesizing a click:

```
screen_x = window.origin.x + box.cx_normalized * window.size.width
screen_y = window.origin.y + box.cy_normalized * window.size.height
```

`window.origin` / `window.size` come straight from the AX `AXPosition` / `AXSize` from the earlier step. **Exactly the same coordinate system as the AX path** — no special handling needed for OP-sourced boxes when synthesizing a click.

#### Multiple displays

OmniParser only looks at the focused window — which screen the window is on doesn't matter. **The multi-display scenario is automatically correct**, no special code needed.

---

## 7. Next steps

See [`omniparser-integration-roadmap.md`](./omniparser-integration-roadmap.md).

That document maps the decisions scattered across this design (§4.4 framework detection, §4.6 OCR refiner, §5.1 baseline filtering, §6 open questions) into 9 independently acceptance-testable implementation phases (P0 decision → P8 release), with time estimates, risks, degradation paths, and out-of-scope boundaries. **Update that document in sync when changing this design.**

---

## 8. References

- OmniParser repo: `github.com/microsoft/OmniParser`
- Weights: `huggingface.co/microsoft/OmniParser-v2.0` (`icon_detect/model.pt` is YOLOv8)
- PoC source code: `~/Desktop/keyway-omniparser-poc/` (throwaway, `rm -rf`-able any time)
- Related specs:
  - `SPECS.md` known gap #2 (Electron / web compatibility) ← OmniParser mainly solves this
  - `SPECS.md` known gap #3 + `hint-discovery.md` §5 (AX cleanup spike) ← OmniParser does **not** solve this, fix it separately
