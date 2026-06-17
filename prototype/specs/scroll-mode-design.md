# Scroll Mode Design

> Keyboard-driven scrolling, modeled on Homerow's scroll. A second interaction mode, independent of hint (TAP) mode.

Related files (after implementation): `ScrollAreaDetector.swift`, `ScrollOverlay.swift`, `ScrollController.swift`, `HotkeyTap.swift` (chord detection), `VimSession.swift` (mode state machine).

## 1. Goals

- Press a key to enter scroll mode, **d/u to scroll down/up** the focused app (vertical, wheel1)
- **`b`/`f` to scroll left/right** (horizontal, wheel2) — Finder column view, wide tables, Notion DB, Figma canvas, calendar week view, and similar scenarios
- Hold d/u/b/f to scroll continuously, Shift+ any of them to accelerate
- When there are multiple scrollable areas, be able to pick which one to scroll
- Move the cursor with hjkl (unified with TAP), without relying on the mouse — pure keyboard

## 2. Entry model: chord vs tap

Caps Lock (already remapped to F19 via hidutil) is a single key carrying two entry paths:

```
OFF
 ├─ Caps Lock single click (press → release, no d in between) → TAP mode (scan + hints)
 └─ Caps Lock held + d                                        → SCROLL mode (no scan, no hints)
```

**Why chord entry instead of "press a key inside TAP"**: scroll mode **has no hints** (hints are only scanned out in TAP mode). The chord goes straight to SCROLL, **without triggering any AX/OP scan at all** — saves 100-200ms, and doesn't flash hints for a moment.

**Why the chord key is `d`**: in SCROLL, `d` means "scroll down". Using `d` for the chord makes the entry key and the primary action key consistent (Caps Lock+d to enter, then d to start scrolling), which is easy to remember. Early on it was `j/k`, but once hjkl was unified as the cursor-move keys, j/k freed up, and the chord switched to `d`.

### 2.1 Key mechanism: TAP entry timing moved from keyDown to keyUp

To distinguish "single click" from "chord", when F19 is pressed down we **can't enter TAP immediately** — we have to wait and see whether a d follows:

```
F19 keyDown (bare, no other modifier keys):
    armed = true, chordUsed = false
    consume (return nil)

d keyDown during armed period:   # F19 still held
    enter SCROLL mode
    chordUsed = true
    consume

F19 keyUp:
    if armed:
        if !chordUsed: enter TAP mode (only now scan + show hints)
        armed = false
    consume
```

**Cost**: TAP is now entered when F19 is released, which is one "hold duration" later than now (entered on press down) — about 50ms for a single click, imperceptible.

**Benefit**: the scroll chord triggers no scan at all (it won't enter TAP and scan once before switching away).

We need to add **keyUp handling + F19 held state tracking** to the event tap (keyUp is needed for continuous scrolling anyway).

### 2.2 The hint letter pool excludes h/j/k/l

hjkl are the **unified cursor-move keys** for both TAP and SCROLL; a bare press always means "move", so they can't double as hint letters (otherwise pressing j is ambiguous). `v` and `c` are also taken in TAP normal — bare `v` enters the DRAG sub-state, bare `c` clicks at the current cursor position. So `HintMode.alphabet` excludes h/j/k/l/v/c, and the remaining handy letters give **15** → **a s d f g e r u i o p w t n m** (15² = 225 > maxTargets 200, so 2-letter labels are the cap and 3-letter labels never appear).

(History: initially, when chord entry was used, j/k were still hint letters and the pool was `a s d f g h j k l`; after TAP added IJKL for cursor movement, j/k/l were removed and e/r/u added; after hjkl was unified, h was removed and i added, making 9 keys; expanded to 16 keys so that 2-letter labels are the cap; when DRAG was changed from bare `v` to a `Caps Lock + v` chord, `v` was briefly added into the pool (17 keys); when DRAG was then folded into a TAP sub-state and bare `v` became the "enter DRAG" trigger key, `v` was removed again (16 keys); finally, Enter-to-click was changed to bare `c` click (Enter now passes through to the app), and `c` was removed again, becoming 15 keys. See `modes.md` §4 / §6 / §4.3 for details.)

### 2.3 The chord only enters, it does not scroll

Caps Lock+d is **only "enter SCROLL mode"**, it **does not trigger scrolling**. After entering the mode, you must **press d/u again** to start scrolling.

### 2.4 Real web pages in the browser: Caps Lock+d disabled, d/u scrolls directly without a mode

**Exception**: when the foreground is a browser and the current tab is a real web page with the content script injected, **Caps Lock+d does not enter SCROLL (it's just swallowed with no effect)** — because on these pages d/u/gg/G can already **scroll without a mode** (Vimium-style), so entering SCROLL would be pointless. The determination relies on the `scroll_gate` live flag pushed by the extension (`VimSession.browserHandlesScroll()`: the browser key that the foreground bundle maps to == the browser whose gate is live, and the connection is online). Pages without a content script — chrome:// / Web Store / PDFs, etc. — still enter SCROLL normally (fallback).

Mode-free scrolling itself **is not part of SCROLL mode**: it is implemented by the extension content script detecting keystrokes and the native side using a long-lived `ScrollController` (no enter / no warp / no overlay) to post real wheel events at the cursor position. See [`browser-support-design.md`](browser-support-design.md) §4.11 for the full design, and [`modes.md`](modes.md) §5.1 for the key bindings.

## 3. SCROLL mode state machine

```
SCROLL mode:
    show scroll overlay (see §5)
    d / u held → scroll down/up continuously, stop on release   (Shift accelerates)
    h/j/k/l held → move cursor left/down/up/right   (vim hjkl, unified with TAP; Shift fast / Option slow, see §3.3)
    gg / G     → jump to top / bottom of the selected area (vim-style, see §3.2)
    c           → left single-click at the current cursor position, stay in SCROLL (pairs with hjkl: move → click; Shift double-click / Option right-click)
    v           → enter drag sub-state (mouseDown at cursor position): hjkl to drag, d/u/b/f to scroll while dragging, Enter to drop, Backspace to cancel (see §3.4 / modes.md §6)
    Enter       → pass through to the focused app (menu confirm / form submit, not eaten by SCROLL)
    number keys 1-9 → switch the selected area
    Caps Lock   → switch to TAP mode (only now scan + show hints)
    Esc         → exit to OFF
```

### 3.2 gg / G —— jump to top / bottom

Synthesize one huge pixel scroll delta (±200k); the app clamps it at the content boundary, and the effect is an instant jump to the top/bottom of the selected area. `gg` uses a pending-flag to detect two consecutive g presses (the first g sets the flag, the second g triggers; pressing any other key in between cancels it — a lone g does nothing), and `G` = a single Shift+g press triggers it. See the implementation in `ScrollController.jumpToTop/jumpToBottom` + `scrollPendingG` in `VimSession.handleScroll`.

### 3.3 hjkl cursor movement + bare `c` click

SCROLL can also move the cursor + click via keyboard, sharing **the same hjkl + bare `c`** as TAP, reusing the same `MouseMover` / `MouseSynth` and the same `VimSession.moveDirection(for:)` mapping.

**Cursor-move keys unified with TAP as hjkl**: early on SCROLL used SDFE and TAP used IJKL, and the two sets of movement keys forced the user to switch muscle memory between modes — a real cognitive burden. They are now unified as vim hjkl (h left / j down / k up / l right), so "move the cursor" is the same everywhere. The cost is that scrolling moved from `j/k` to **`d` (down) / `u` (up)** — but `d` lines up exactly with the entry chord, so it's actually smoother. Three speed tiers: bare normal / Shift fast / Option slow (fine-grained).

`c` = left single-click at the current cursor position (Shift double-click / Option right-click); after clicking, you stay in SCROLL (unlike TAP, there's no sticky/exit dispatch — in scroll it's just continuous operation). It was originally Enter; changing it to `c` lets Enter pass through to the focused app (see `modes.md` §4.3 for details).

> Before unification, the two modes had different cursor-move keys (TAP=IJKL, SCROLL=SDFE), a compromise under each one's key-binding constraints; after unifying on hjkl the cognitive burden is gone. Down the line we'll let users customize the key bindings.

### 3.4 drag sub-state (`ScrollSub.dragging`)

SCROLL can also drag, mirroring TAP's drag (`modes.md` §6), but with one extra capability — **scroll while dragging** — which is exactly what makes "dragging in SCROLL" valuable over "dragging in TAP": while holding the drag you can keep scrolling with `d/u` (vertical) / `b/f` (horizontal), the mouse button stays down, and you can **drag-select across viewports** (hold here, scroll down with `d` to select a large span beyond the screen, Enter to drop).

- Enter: bare `v` in SCROLL normal (`v` is otherwise unused in SCROLL) → stop continuous scrolling + mouseDown at cursor position + hide the area picker, HUD `SCROLL · dragging`;
- `hjkl` drags the cursor (posts `.leftMouseDragged`); `d/u/b/f` scroll while dragging;
- `Enter` drop / `Backspace` cancel (cancel warps back to the start point) → restore the picker, return to SCROLL normal (**does not exit**, SCROLL has no sticky/exit concept);
- `Esc` / switch mode → cleanup posts the missing mouseUp to release the button.

Implementation: `VimSession.startDragFromScroll` / `handleScrollDragging` / `scrollDragDrop` / `scrollDragCancel`, sharing `DragController` / `MouseMover` (dragHeld) with TAP.

### 3.1 Releasing d/u does not auto-rescan

Scrolling **triggers no rescan**. After scrolling, if you want to hint-click, press **Caps Lock to explicitly switch to TAP** (scans the current position + shows hints). A rescan is always user-initiated (Caps Lock), never automatic. `d/u` keyUp only stops the continuous-scroll timer, and `hjkl` keyUp only stops cursor movement.

## 4. Scroll area detection: AX only

### 4.1 Why only AXScrollArea (+ AXWebArea)

A scroll area is a **container** with no reliable visual signature — OP (which finds clickable elements) can't recognize it. Window center / visual heuristics are all unreliable. **The only reliable thing is AX's `AXScrollArea`** (+ `AXWebArea` for web content).

Key point: **scroll area detection always goes through AX, regardless of the "AX vs OP for clickable elements" routing**. Even an app like WeChat that routes to OP still has its scroll container (NSScrollView) as `AXScrollArea`, visible to AX — the structure is reliable in AX, only the content is blind in AX (see the same logic in `omniparser-fallback-design.md` §4.2).

| app | scroll area AX role | detectable |
| --- | --- | --- |
| native (WeChat / Finder / Mail) | `AXScrollArea` | ✓ |
| Safari / WKWebView | `AXWebArea` | ✓ |
| Electron (with renderer accessibility enabled, e.g. VS Code) | `AXWebArea` / `AXScrollArea` | ✓ |
| Electron (with AX off by default) / games / pure self-rendered | none | ✗ |

### 4.2 What to do when it can't be recognized: rely on the future "keyboard-pan the mouse"

Areas that AX can't recognize (zero-AX Electron / games) get **no fallback hack**. In the future there will be a "keyboard-pan the mouse" feature — the user manually moves the cursor onto the target area, then d/u still posts scroll commands (the scroll event routes to the view under the cursor).

So for v1: **whatever AXScrollArea can recognize is recognized precisely, and whatever it can't is left for future manual handling**. In the current implementation, when nothing is recognized (**Chrome web content is exactly this case — renderer accessibility is off by default, so `AXWebArea`/`AXScrollArea` isn't detected**) it falls back to the focused window: **the cursor is already inside the window → don't move it** (the wheel lands under the cursor, which is enough; it's already on the page so there's no need to warp, otherwise it's jarring); only when the cursor is outside the window (another screen / Dock) do we warp it to the window center. No overlay is drawn.

> More thorough Chrome scroll-area detection (going through the extension DOM to find the page's real scroll containers, with a multi-area picker) is a larger feature, not done; the current "don't warp if already inside the window" already eliminates the jarring cursor jump on entering SCROLL.

#### Tried but ineffective: AXManualAccessibility to wake up Electron

Chromium/Electron keeps the AX tree off by default. In theory, setting `AXManualAccessibility = true` on the app's AX element (the standard signal by which assistive technologies wake up Chromium a11y) should make it build a full AX tree. **In practice it had no effect on the Claude desktop app (Electron)** — after setting it and retrying multiple times, the AX role census from the window down was still all `AXGroup`, with no `AXScrollArea`/`AXWebArea` showing up.

Possible reasons: this version of Electron doesn't implement `AXManualAccessibility`, or it needs to be set earlier (at app startup rather than at runtime), or it needs to be combined with `AXEnhancedUserInterface` (but the latter makes the app think VoiceOver is on, which may change behavior / cause bugs, so we don't dare use it lightly).

**Conclusion**: don't rely on this. Recognizing scroll areas in zero-AX Electron is left to the "keyboard-pan the mouse" fallback. **Don't try the AXManualAccessibility path again** (unless there's evidence that some Electron versions respond to it).

Diagnostics: when 0 areas are detected, it logs `[mouseless] scroll: 0 areas — AX role census: ...`, which distinguishes "app is zero-AX" (all AXGroup) vs "our BFS missed it" (there's a scroll role but we didn't catch it).

### 4.3 Detection timing + cost

On entering SCROLL mode, walk the focused window once to find `AXScrollArea` + `AXWebArea`. Only the container roles are sought, without drilling down to enumerate content → a depth-limited BFS, ~10-30 IPC, a few ms. One-time (not per keystroke).

## 5. Multi-area picker overlay

On entering SCROLL mode:

- walk out all scroll areas
- **draw a blue-background number label at the top-left corner of each area** (1, 2, 3...)
- **highlight the border of each area** (so the user clearly sees the area's extent)
- **default to the area nearest the current cursor** (highlighting distinguishes selected vs unselected)
- **cursor already inside the selected area → don't warp** (`nearestAreaIndex` returns distance 0 for a cursor "inside some area" → that area is necessarily selected → contains-check hits → skip the warp). Only warp to the area center when the cursor is **not** inside the selected area. The wheel event just needs to land anywhere inside the area; there's no need to drag it to the exact center, and warping when already inside is redundant and jarring.

User actions:

- d/u directly → scroll the default (nearest) area
- press a number key → switch to that area (**deliberate switch → re-warp** the cursor to the new area's center, update the highlight)

The overlay stays visible until Esc / switching to TAP (so the number keys can switch areas at any time).

## 6. Scroll synthesis

```swift
let scroll = CGEvent(scrollWheelEvent2Source: src,
                     units: .pixel, wheelCount: 2,
                     wheel1: deltaY,   // negative = scroll down, positive = scroll up
                     wheel2: deltaX,   // negative = scroll right, positive = scroll left
                     wheel3: 0)
scroll?.setIntegerValueField(.eventSourceUserData, HotkeyTap.syntheticMarker)  // prevent self-processing
scroll?.post(tap: .cghidEventTap)
```

- **Vertical (wheel1)** vs **horizontal (wheel2)** share the same event framework; `ScrollController` reuses an `Axis` enum + a single timer to switch between them, with a consistent sign convention: "negative = forward direction" (down / right).
- **Continuous scroll**: keyDown starts a timer (~16ms / 60fps), posting a small delta each time → smooth; keyUp stops the timer
- **Shift acceleration**: increase the delta or raise the frequency
- **Cursor positioning**: a scroll event routes to the view under the cursor, so the cursor must land inside the target scroll area. **But only `CGWarpMouseCursorPosition(areaCenter)` when it's not yet inside the area** — if already inside (including the "already inside the window" case for the Chrome web-page fallback), don't move it, to avoid an unnecessary jump. A deliberate area switch via number key is the exception, always warping to the new area's center.

### 6.1 Cursor warp gotcha

After `CGWarpMouseCursorPosition`, there may be a brief mouse-movement freeze / lag in reported position. Our usage (warp then immediately post the scroll) is unaffected, but it's worth knowing. If problems arise, add `CGAssociateMouseAndMouseCursorPosition(true)`.

## 7. Component breakdown

| component | responsibility |
| --- | --- |
| `HotkeyTap` | F19 armed state machine + keyUp + chord detection (Caps Lock + d); dispatch to TAP / SCROLL |
| `VimSession` | Mode enum gains `.scroll`; scroll keystroke dispatch (d/u scroll, hjkl move, gg/G jump, bare `c` click, bare `v` drag, number keys switch area) |
| `ScrollAreaDetector` | AX walk to find AXScrollArea + AXWebArea, returning each one's screen rect |
| `ScrollOverlay` | draw a blue glow border (Homerow-style) + a number badge labeling each area |
| `ScrollController` | scroll synthesis + continuous timer + gg/G jump to top/bottom + cursor warp + area selection state |
| `MouseMover` | hjkl continuous cursor movement (shared by TAP + SCROLL) |
| `MouseSynth` | bare `c` click synthesis (shared with TAP) |

## 8. v1 scope

Done (v1 + subsequent iterations):
- chord entry (F19 armed state machine, Caps Lock + d; TAP changed to keyUp entry)
- AXScrollArea + AXWebArea detection
- multi-area overlay (numbers + glow border + nearest as default)
- hold-to-scroll continuously (d/u) + shift acceleration
- **gg / G jump to top/bottom** (§3.2)
- **hjkl cursor movement** (normal / Shift fast / Option slow fine-grained) **+ bare `c` click** (§3.3, sharing MouseMover/MouseSynth with TAP, unified key bindings; Enter passes through)
- number keys switch area
- Caps Lock → TAP, Esc → OFF
- releasing d/u does not rescan

Deferred (defer):
- keyboard-pan the mouse (fallback for unrecognized areas) — a standalone large feature, done separately
- horizontal scrolling — users only want vertical (h/l are already taken by cursor movement)
- half-page / full-page (space) — d/u + shift + gg/G is enough for now
- smooth momentum / inertial scrolling — constant-speed continuous for now

## 9. Edge cases to confirm at implementation time

- pressing a non-d key during the armed period (e.g. F19+a): v1 leans toward pass-through, tighten if a stray char shows up
- the "nearest" metric for multiple areas: cursor inside some area → distance 0; outside → nearest distance to the edge
- nested areas (scroll area inside scroll area): take the largest? or list them all and let the user pick? v1 lists them all for now, observe
