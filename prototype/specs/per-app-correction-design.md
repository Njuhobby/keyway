# Per-App Correction Layer Design (AX walker overrides as the primary mechanism)

> **Status: design draft, not yet implemented**. An **important standalone module** planned for after OmniParser integration (P0-P6), and also Mouseless's main **moat**. This doc locks in the design reasoning + the rejected/downgraded approaches, so that when the priority comes up we can implement it directly from here.
>
> Related: `omniparser-fallback-design.md` (the OP visual-path body), `browser-support-design.md` (browsers go through the extension DOM, which is this same line of thinking applied to the browser domain).
>
> **§11 is the key to scale** — a template auto-generation pipeline (AX dump × visual × walker three-way diff → LLM/heuristic synthesized patch), rather than relying on writing rules one at a time by hand.

---

## 0. TL;DR — three lines of defense

```
1. per-app AX walker overrides (primary)  —— 80%+ of long-tail apps, declarative JSON rules, ~1-5ms
2. OmniParser visual path (fallback) —— true AX black-hole apps (pure canvas / custom-drawn), implemented
3. pattern exclude / threshold override (auxiliary) —— OP/AX false positives and tuning
```

**Moat = a community-built library of per-app AX adaptation rules** — translating each app's quirky accessibility tree into precise clickable elements. Pure text, diffable, reviewable, zero model maintenance, with a contribution barrier so low that anyone who can poke around with AX Inspector can submit a PR.

NCC template matching was **downgraded from the early design's "primary mechanism" to an appendix** (§A1) — after re-analysis, its applicable surface gets squeezed out from above by AX overrides and covered from below by OP, leaving it wedged in the middle with almost no place to stand. **Not implemented in v1, and most likely never implemented.**

---

## 1. Motivation: AX-bad ≠ AX-absent

The fundamental problem once the OmniParser path went live: OP is not 100% accurate (misses icon-only buttons, mislabels title-bar text), the confidence threshold isn't universal, and boxes are anonymous (it doesn't know whether something is a camera or a folder). So a mature Mouseless must have **per-app personalized correction**.

But the key secondary insight (the one that determines the primary mechanism): **the vast majority of "OP-bad" apps actually do have AX — it just isn't "absent," it's "non-standard."**

Example — Slack's Compose button in the AX tree is:

```
AXGroup (subrole=nil, action=nil)
  └── AXGroup
        └── AXImage (action=AXPress, title="Compose")   ← here!
```

When our generic walker runs its role whitelist + depth limit, it skips this kind of element — "wrapped in two layers of AXGroup, role is AXImage but carries an AXPress action." **The app has the information; we just didn't read it.**

Truly visual, zero-AX apps (WeChat's custom-drawn chat area, Figma canvas, web games) are **a minority**. Slack / Notion / Linear / Discord / Cursor / most Electron and SwiftUI apps all have a fair amount of AX — it's just structurally weird.

**Conclusion: for deep adaptation of long-tail apps, "customizing AX rules" is a better path than "patching the gaps visually"** — all rules can be expressed as text, are cheap, are resilient to app upgrades, and are community-contributable. Only when an app's AX truly has nothing at all do we fall back to OP.

---

## 2. Why not per-app model fine-tuning

The intuitive idea of "fine-tune an OP model for each app, teach it that the camera is clickable" — **rejected**.

| Dimension | per-app model fine-tuning |
| --- | --- |
| Labeling | Manually box every clickable element across all of an app's UI states, hundreds to thousands of images per app |
| Training | GPU + pipeline + tuning, redone per app |
| Size | ~38MB each, 100 apps = **3.8 GB** |
| Maintenance | **The moment an app updates its UI the model goes stale** → re-label + re-train |
| The irony | The box you labeled "camera is clickable" was **available for free from AX all along** (the walker just didn't collect it) |

Fine-tuning is the last resort for "no structured information whatsoever, can only learn from pixels." For the vast majority of apps we have a cheaper information source (the AX tree itself). If we really were going to train a model, it should be training a stronger **generic** detector on **aggregated** UI data to replace OmniParser — not one model per app.

---

## 3. Core insight: self-gating, sidestepping window classification

The first deadlock for the correction approach: **an app has more than one window layout** (WeChat has the main window, contacts, Moments, settings, image preview…). A "there's a camera in the bottom-left corner" rule, applied to the settings window, fabricates a hint out of thin air.

Trying to build a "window classifier" (judging the layout by title/size/AXIdentifier) is a deadlock: titles change, users resize, and many apps don't set an AXIdentifier.

**The breakthrough: don't classify windows. Anchor a rule to a decidable condition, and let "whether the condition holds" itself act as the gate.** This is especially clean for AX overrides — a rule is "an element satisfying the predicate exists in the AX tree," and if the predicate matches nothing the rule silently does nothing, with zero false positives. The settings window doesn't contain that Compose structure → the rule naturally produces no hint. **The window-classification step simply disappears.**

---

## 4. AX walker overrides: the primary mechanism

What we're rescuing is "**the element IS in the AX tree, the generic walker just didn't collect it**." An override = a declarative JSON file telling the walker to **additionally** treat elements satisfying certain conditions as clickable in a given app.

### 4.1 Data shape

One `patch.json` per app + an optional README:

```
patches/com.tinyspeck.slackmacgap/
├── patch.json
└── README.md          # maintainer notes (which version it was taught against, screenshot examples)
```

`patch.json` (schema draft):

```jsonc
{
  "schema_version": 1,
  "bundle_id": "com.tinyspeck.slackmacgap",
  "app_name": "Slack",
  "maintainer": "@njuhobby",
  "verified_against": ["4.36.x", "4.37.x"],

  "additional_clickable": [
    {
      "role": "AXImage",
      "must_have_action": "AXPress",
      "comment": "sidebar Compose / Threads / Mentions icon"
    },
    {
      "role": "AXGroup",
      "must_have_subrole": "AXButton",
      "comment": "custom button wrapped in a group"
    }
  ],

  "exclude": [
    { "role": "AXStaticText", "title_equals_window": true,
      "comment": "title-bar text" }
  ],

  "fallback_op": false
}
```

**Format decisions (locked in for v1)**:

- **JSON not YAML** — native Foundation parsing, zero dependencies, easy to write CI tooling for. Readability is good enough for this kind of flat structure.
- **Predicates are flat, no role_path** — fields within a rule are AND'd (role=AXImage and has AXPress); multiple rules are OR'd together. Ancestor chains ("only AXGroup → AXGroup → AXImage counts") are not supported. A flat predicate is enough for the vast majority of cases; if path precision is genuinely needed to prevent mismatches, add it in v2.
- **Binary decision, no score** — a rule `matches → clickable`, purely boolean. Text rules have no need to dress up with decimals.
- **`fallback_op` defaults to false** — the existence of a patch signals "this app is self-consistent through AX and doesn't need OP." Set it to true only to layer OP on top after the AX collection to patch gaps (for hybrid apps where "AX gets most of it + dynamic content like chat bubbles needs a visual fallback"). Defaulting to false avoids the developer forgetting to turn it off and paying OP's ~95ms for nothing.

Available predicate fields (v1): `role` / `subrole` / `must_have_action` ("AXPress"/"AXShowMenu") / `must_not_have_action` / `title_matches` (regex), etc., extended as needed.

### 4.2 Hooking into the existing walker

Current routing (`HintMode.collectAll`):

```
frontmost.bundleID
   ├─ isBrowserApp → BrowserProvider (extension DOM)
   ├─ shouldUseAXForFocused → AX walk (hardcoded whitelist)
   └─ otherwise → OmniParser
```

After adding patches it becomes:

```swift
if let patch = AppPatchRegistry.shared.patch(for: bundleID) {
    walker.run(window: focusedWindow, augmentedBy: patch)   // AX walk + extra rules
    if patch.fallbackOP { mergeOP(...) }                    // off by default
} else if AppRegistry.shouldUseAXForFocused(bundleID) {
    walker.run(window: focusedWindow)                       // original generic walk
} else {
    OmniParserPath.collect()                                // no patch + not whitelisted → OP
}
```

When the walker decides "is this element clickable," it makes an extra pass over the patch's `additional_clickable` rules:

```swift
func isClickable(element, patch) -> Bool {
    if defaultClickableHeuristics(element) { return true }   // existing generic decision
    if let patch, patch.additionalClickable.contains(where: { $0.matches(element) }) {
        return true                                          // app-specific addition
    }
    return false
}
```

Simple forward-chaining, zero black magic. The original `AX_FOCUSED_WHITELIST` semantics are preserved — that means "this app trusts the generic walker **without a patch**" (well-behaved a11y apps like Finder / Mail / Notes). **The binary split (AX whitelist vs OP) becomes a three-way split (patch app / vanilla whitelist app / OP-only app)**, with the vast majority of long-tail apps migrating from OP to patches.

### 4.3 The teach loop (capturing an AX predicate)

```
teaching (once per rule):
  1. User is in Slack, the Compose button has no hint
  2. Trigger teach (menu bar "Teach a missing hint…" option)
  3. User points the mouse at the Compose button
  4. Mouseless uses AXUIElementCopyElementAtPosition to grab that element
  5. Read its role / subrole / actions → generate a candidate predicate
     ("role=AXImage, must_have_action=AXPress")
  6. Save into the local patch.json
runtime: load patch → apply during walk → match → synthesize hint
```

The teach output **changes from "screenshot an icon PNG" to "capture an AX predicate"** — this is the key change in teach once the primary mechanism switches to AX overrides. Lower barrier, the PR is a few lines of JSON instead of PNG+JSON, review is faster, and there's no "the template breaks when the icon is redesigned."

The teach entry point is a **menu bar dropdown option** ("Teach a missing hint…"), not a chord — a one-off operation isn't worth occupying a key.

---

## 5. exclude / threshold override (auxiliary)

**exclude** — remove OP/AX false positives (title-bar text labeled as a hint). Prefer pattern-based (works across layouts):

```jsonc
{ "role": "AXStaticText", "title_equals_window": true }   // remove text == window title
```

The "title-bar text == window title" rule is universal across all layouts, so it doesn't need per-layout config. exclude is easier than include — it operates on **existing** candidates and can do pattern matching.

**threshold override** — when some app's default OP confidence of 0.3 is wrong, tune one line in the patch. Pure config, ~0 cost. Only meaningful for apps with `fallback_op: true` or OP-only apps.

---

## 6. Distribution flywheel: L0 → L1 → L2

For the moat to spin up, it relies on community co-building. Progressing by complexity, **do L0→L1→L2, skip L3**:

| Stage | Mechanism | Consumption barrier | Contribution barrier | Flywheel |
|---|---|---|---|---|
| **L0** bundled curated | patches for the top ~30 apps packaged into the .app | 0 actions | (we hand-write them) | doesn't grow |
| **L1** GitHub repo + auto pull | `Njuhobby/mouseless-patches` public repo, pull latest on launch + local cache + offline fallback | 0 actions | knows PRs | slow flywheel |
| **L2** one-click share | after teaching in-app, click "share" → GitHub OAuth auto-opens a PR (patch.json + screenshot) | 0 actions | **0 friction** | true flywheel |
| L3 marketplace | VS Code-extension-store-like (search/install/rate) | fully consumption-only | — | strong but high engineering effort, **not doing it** |

L3 is too much engineering effort and the payoff doesn't match the current scale. L2 already lets any macOS user (who doesn't know git) contribute.

repo structure: `patches/<bundleID>/{patch.json, README.md}`.

---

## 7. Governance / noise resistance / privacy

| Risk | Mitigation |
|---|---|
| **Stale rules** (Slack v5 changed its AX structure) | `verified_against` records versions; when the app version changes, flag in the UI "may need re-teaching." AX role names are usually very stable, far more upgrade-resistant than PNG templates |
| **Mismatches** (predicate too broad, labels things that shouldn't be clicked as clickable) | the predicate generated during teach carries constraints where possible (role + action together); PR review pairs it with a screenshot for a human eyeball check; CI can run a "did the match count blow up" heuristic on the reference screenshot |
| **Uneven quality** | CI auto-validates the patch.json schema + runs the rules against the maintainer-provided reference AX dump and counts matches |
| **Traffic attacks** | GitHub Actions + CODEOWNERS standard protection |
| **Privacy** | what teach captures is AX role/action/title text, which may contain user data (e.g. a person's name in a window title) → the teach UI lets the user preview + edit before saving/submitting; screenshots (only when sharing at L2) force the user to redact sensitive regions |

**Trust tiers**: patches for high-risk apps (banks, 1Password, password managers) go through manual review; ordinary apps can merge once CI passes. As contributions grow, introduce trusted contributors (users who've submitted high-quality PRs are granted merge rights).

---

## 8. Bootstrapping (chicken-and-egg)

**0-user stage (we seed)**: manually teach ~30 high-frequency apps — Slack / Discord / Notion / Linear / Figma / Zoom / Spotify / Music / Mail / Calendar / Notes / Telegram / Bear / Obsidian / Cursor / Warp / iTerm / Postman / Things / Excel / Numbers / Keynote / Pages / Sketch / TablePlus and the like. This batch is day-1 product value (the main apps just work right after install).

**100-user stage**: activate L2 one-click PRs, we review a few each day, the catalog goes from 30 → 100+.

**1000+-user stage**: trusted contributors + CI automation (schema validation, staleness detection, match regression).

---

## 9. Moat

- **Data moat**: a per-app AX rule library accumulated through use — others have to accumulate adaptations for a thousand apps from scratch
- **Its form is structured text, not model weights**: pure JSON predicates, diffable / reviewable / hand-editable, fix one line when stale; no training + re-training + size cost
- **Extremely low contribution barrier**: teach one-click captures a predicate → PR a few lines of JSON, anyone who can use AX Inspector can contribute
- **A loop that gets more accurate with use**: teach → PR → the bundled library gets stronger → new users get it out of the box
- Benchmarking against Vimium: its real moat isn't technology, it's 15 years of accumulated per-site handling details. We're the **OS-layer** counterpart — per-app AX adaptation. A competitor wanting to catch up has to accumulate from scratch.
- Homerow is pure AX and does no per-app adaptation at all; our differentiation is **taming every app's AX quirks**.

---

## 10. v1 scope

Do:

- `AppPatchRegistry` — load + index patch.json (bundleID → patch)
- AX walker wired to `additional_clickable` predicates (flat, binary, AND/OR)
- `exclude` (pattern-based, start with title_equals_window)
- `fallback_op` switch (defaults to false)
- teach flow: menu bar entry → `AXUIElementCopyElementAtPosition` grabs the element → generate predicate → write local patch
- L0 curated bundle (~30 apps) + L1 GitHub pull scaffolding

Defer:

- L2 one-click PR (get the flywheel running with L1 manual PRs first)
- threshold override (only fallback_op apps need it, build it once there's measured demand)
- role_path path-based predicate (add it once flat isn't enough)
- **NCC template matching + OCR-landmark + geometric-gap detection** (see Appendix §A, most likely never)

---

## 11. The template auto-generation pipeline (the key to scale)

Writing predicates purely by hand isn't realistic. But **generating patches is itself highly automatable**, because we hold ground truth that the walker doesn't use.

### 11.1 Core insight: three datasets to compare, the walker only used the first

| Data | Used by walker? | Tells us |
|---|---|---|
| **walker output** (current hints) | ✅ | "what got collected right now" |
| **full AX tree dump** (all role/action/subrole/rect, unfiltered) | ❌ | "what's **actually in** the AX" |
| **visual** (screenshot + clickable boxes detected by OmniParser/VLM) | ❌ | "which things on screen are **actually** clickable" (ground truth) |

**Generating a template = diffing these three**: visual says "this is clickable" + AX dump says "there's an AXImage+AXPress here" + walker says "I didn't collect it" → automatically derive an include rule.

### 11.2 Layered automation (zero ML → fully automatic)

**Tier 0: pure AX heuristics (zero ML, covers the majority)**

Dump the full AX tree → filter for "elements with a clickable signal (AXPress/AXOpen action, or button-class subrole) but rejected by the walker" → cluster by `(role, action)` signature → propose one include rule per cluster. The Slack `AXImage+AXPress` case **can be auto-proposed with zero ML** as `{role: AXImage, must_have_action: AXPress}`. Estimated to solve 60-70% of AX-irregular apps.

**Tier 1: AX × visual cross-validation (filter false positives + decide fallback_op)**

Tier 0 risk: a decorative `AXImage+AXPress` (no-op handler) gets collected and becomes a false positive. Validate with the visual layer: the candidate element's rect overlaps some visual clickable box → confirmed as a real button, keep it; doesn't overlap → drop it. The reverse: a visual clickable box that has **no corresponding AX element at all** → this region is a true AX black hole → auto-mark it for OP fallback (`fallback_op: true`), it's not something an include can rescue.

**Tier 2: AI synthesis (runnable right now, no self-trained model needed)**

Add a debug command to Mouseless that one-click exports a bundle from the problem app: `{full AX tree JSON, screenshot PNG, walker output, OP output}`. Hand the bundle to a vision-capable LLM (during development = Claude); it looks at the screenshot + AX dump + walker gap and **writes patch.json directly** — finding patterns in structured data + judging "should-be-clickable vs decorative" is exactly the kind of synthesis task LLMs are good at. The loop: hit the hotkey in the problem app → export bundle → LLM produces patch → verify → commit.

**Tier 3: bake synthesis into the app (ultimate scale)**

Replace Tier 2's synthesis with an in-app VLM call (API or local model): the user clicks "auto-generate adaptation" in any app → the app dumps + calls the model + produces a patch + verifies locally on its own. Fully self-service, the AI-powered version of the §6 L2 flywheel.

### 11.3 Verification harness (generation is only half)

Score each Tier's candidate patch with the same objective function:

```
apply candidate patch → re-run walker:
  recall    = fraction of visual clickable boxes covered ↑ (were the misses fixed)
  precision = total hint count didn't blow up ↑ (didn't over-match and collect a pile of junk)
```

With this objective function, we can even **automatically search predicate variants** (add a region to tighten / switch the action constraint) and pick the best recall/precision tradeoff, with a human only needing to approve at the end.

### 11.4 Boundaries (honest)

- Visual box bbox precision is limited → leave a tolerance for AX-rect matching
- True canvas apps (the Figma canvas) have nothing in AX → no predicate can rescue them, the pipeline auto-exposes them as "OP-only," which is the correct result, not a failure
- Over-generalization (one rule collects compose + 50 emoji) → the verification harness's precision term specifically catches this

### 11.5 Implementation order

Do three zero-ML, mutually independent things first: **① bundle export tool ② Tier 0 heuristic generator ③ verification harness**. Once those three are done, you can immediately use an LLM as the Tier 2 engine to run the complete "problem app → patch.json" loop. Tier 3 (in-app VLM) waits until the loop is verified to work before investing. These three are also a natural superset of the teach flow (§4.3) in the v1 implementation — teach is "a human points at one element," the pipeline is "automatically find all the elements that should be pointed at."

---

## Appendix A: cut / downgraded approaches

### A1. NCC template matching — from "primary mechanism" to "appendix footnote"

The early design treated NCC visual template matching as the include primary mechanism (teach one icon PNG, at runtime NCC-match it in the screenshot to patch hints). After re-analysis it was **cut**:

The only scenario where NCC holds up is "**the target is visible and clickable, but the node simply doesn't exist in the AX tree at all**." But this scenario:
- gets squeezed out from above by **AX overrides** (if there's a node in AX, the override handles it, no visual needed)
- gets covered from below by **OmniParser** (if AX genuinely doesn't have it, OP's generic visual detection already catches it)

What NCC wants to occupy is the triple intersection of "AX doesn't have it + OP misses it too + but it's a visually stable fixed icon" — **a tiny area**. Originally it was "patching OP's miss-detections," but OP itself has retreated to being a fallback (serving only true black-hole apps), so NCC becomes the fallback's fallback, and the cost-benefit doesn't hold up.

A side benefit: cutting NCC makes the moat data purer (all text JSON, no PNG library), smaller in size, with a lower contribution barrier and no "the template breaks when the icon is redesigned" maintenance burden.

(The design of the NCC technique itself — Accelerate vImage implementation, normalization for dark-mode resistance, region-limited ~5ms, DPR scaling — if we ever do hit a must-do canvas-app icon scenario, the full reasoning is recoverable from git history.)

### A2. OCR-text-landmark — defer

"The clickable element is to the right of the text 'Search'," locating it via region-limited OCR to find the text landmark. Cost is the weak point (running region OCR ~5-10ms per collect). It's only meaningful when AX overrides also can't handle it (the element isn't in AX, its appearance changes, but there's stable text nearby) — rare, defer.

### A3. OP-relative anchoring — rejected

"The camera is to the right of the folder icon": OP's boxes are anonymous, it doesn't know which one is the folder, so it can't resolve "relative to some box with an identity." The only identity-free form is pure geometric gap detection (in an evenly-spaced icon row, infer "there's a hole in the middle → one is missing"), but it's both narrow and risky (the gap might be an intentional separator → false positive), most likely not doing it.

### A4. Window classifier — deadlock

See §3. There's no reliable signal for judging "which layout am I in" from title/size/AXIdentifier. Replaced by self-gating.

---

## Appendix B: decision history (to avoid retreading dead ends)

1. **per-app fine-tuned model** → rejected (astronomical labeling/training/maintenance/size cost, no need to make a model learn what AX gives for free)
2. **correction JSON + window classifier** → deadlock (many layouts, no reliable classification signal) → changed to **self-gating**
3. **NCC template matching as the include primary mechanism** → after repositioning, **downgraded to the appendix** (squeezed from above by AX overrides, covered from below by OP, tiny intersection)
4. **primary mechanism changed to per-app AX walker overrides** → the key insight "AX-bad is mostly AX-irregular, not AX-absent," most long-tail apps have AX that's just structurally weird, and declarative rules are cheaper/more stable/easier to contribute than patching the gaps visually

When you want per-app precision, the first instinct should be **"write an AX predicate override,"** not "train a model" / "build a window classifier" / "store icon templates."
