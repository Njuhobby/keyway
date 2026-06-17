# Modes & Key Bindings

Complete definition of the mode state machine, the command palette, and every key binding.

Related files: `VimSession.swift`, `KeyCode.swift`.

---

## 1. Conceptual model

```swift
enum Mode {
    case tap(HintMode)            // hint click + hjkl cursor move + bare c click + (sub-states: drag / search)
    case scroll(ScrollController) // keyboard scroll (multi-area picker) + hjkl move + bare c click + (sub-states: drag / search)
    case window(WindowController)     // whole-window resize
    case windowMove(WindowMoveController)  // whole-window pan
    // TAP sub-states: TapSub.normal / .dragging / .searchTyping / .searchSearching / .searchPicking
    // SCROLL sub-states: ScrollSub.normal / .dragging / .searchTyping / .searchSearching / .searchPicking
}

var paletteBuffer: String? = nil   // nil = palette closed
var sticky: Bool = false           // valid inside TAP mode
```

- **Mode** describes "what the user is currently doing". The current two: `.tap` (hint click, also includes hjkl cursor move + bare `c` click) and `.scroll` (keyboard scroll). The cursor-move keys **hjkl are unified across the two modes** (eliminating cognitive switching between modes). The click key **bare `c` is unified across TAP/SCROLL**—avoiding Enter, which often has its own semantics inside an app (menu confirm, form submit) and would get eaten.
- **paletteBuffer** is the command palette's input buffer. Opening the palette does **not** change the underlying mode; closing the palette returns to the original mode and continues.
- **sticky** is used only inside TAP mode and indicates whether the mode is kept after a click (to click multiple targets in a row).

The trigger key **Caps Lock** (remapped to F19 via hidutil) always goes through the **arm mechanism**: pressing it does not act immediately, it waits for release or for a chord (see §2.1). This lets one key carry several jobs: single click enters TAP / toggles sticky / SCROLL→TAP, hold+jk enters SCROLL.

---

## 2. State transition diagram

```
                      ┌──────── Caps Lock release (no chord) ────────┐
                      │                                          ▼
[OFF] ──Caps Lock release (no chord)──> [TAP] ──Caps Lock release──> [TAP sticky]
   │                                  │  ▲                        │
   │                                  │  └── Caps Lock release ────┘ (toggle)
   │                                  │
   └─ Caps Lock hold + d ───┐        ├─ hint letter    → click (commit)
                            │        ├─ h/j/k/l        → move cursor (vim hjkl, Shift to accelerate)
   [TAP] Caps Lock hold+d ──┤        ├─ bare `c`       → left single-click at cursor position (Enter passed through to app)
                            ▼        ├─ Shift+; (:)    → command palette
                        [SCROLL] ◄───┘ Caps Lock hold+d
                            │
                            ├─ d / u        → scroll down/up (hold for continuous, Shift to accelerate)
                            ├─ h/j/k/l      → move cursor (same as TAP, Shift fast / Option slow)
                            ├─ number keys  → switch scroll area
                            ├─ Caps Lock release → switch back to TAP
                            └─ Esc          → OFF

Any mode: Esc → deactivate back to OFF
```

### The unified semantics of Caps Lock (arm)

Caps Lock(F19) in **any mode** first **arms** (does nothing on press); on release it branches:

- **j/k was pressed while held** (chord) → enter SCROLL (from any mode)
- **no chord pressed, released directly** → execute the current mode's default: OFF→enter TAP, TAP→toggle sticky, SCROLL→switch back to TAP, palette open→close palette

So **pressing Caps Lock twice in a row = enter TAP + toggle sticky = straight to TAP sticky**. The cost: every Caps Lock single-click action takes effect only on **release** (~50ms, imperceptible). See §2.1.

**Esc always deactivates**—returning to OFF (hide hints, clear sticky, close palette, exit scroll), but the **process does not exit** (Keyway is still in the menu bar, Caps Lock is still F19). To actually quit the process, use menu bar Quit (see §3.1).

To only close the palette and return to TAP without deactivating: press Backspace on an empty buffer, or press Caps Lock.

### 2.1 arm mechanism (chord vs tap disambiguation)

For one key to serve both "single click" and "hold + combination", you can't tell them apart at the moment of press (the second key of the chord hasn't arrived yet), so on press it **does nothing and records an armed flag**, then waits for the next step:

```
Caps Lock pressed → f19Armed = true (standby, do nothing yet)
   ├─ j/k pressed meanwhile → chord: enterScroll(), mark chordUsed
   └─ Caps Lock released → if no chordUsed → handleTriggerTap() (dispatch default action by mode)
```

See `HotkeyTap.swift` (arm state machine) + `VimSession.handleTriggerTap()` for the implementation. arm covers all modes, not just OFF—this is the root of both behaviors "Caps Lock+d to enter SCROLL even inside TAP" and "consecutive Caps Lock to enter sticky".

---

## 3. Enter / exit

The trigger key is **Caps Lock** (a physical key; after being remapped to F19 via hidutil, what CGEventTap receives is an F19 keyDown, see `event-pipeline.md` §3).

### 3.1 Three levels, don't confuse them

Keyway state has **three levels**, and what "exit" means differs depending on which level:

| Level | menu bar icon | hidutil remap | How to enter | How to leave |
| --- | --- | --- | --- | --- |
| **Process not running** | none | reverted | not yet launched / user menu bar Quit | launch Keyway |
| **Process running · OFF** | `M●` | active | launch / Esc out of a mode | Caps Lock to enter TAP / Caps Lock+d to enter SCROLL / menu bar Quit |
| **Process running · TAP/SCROLL** | `M●` + overlay | active | see §2 | Esc / menu bar Quit |

**Esc only "deactivates" within the level—back to OFF, it does not exit the process.** Caps Lock is still F19, press it once more and you're immediately back in TAP. To actually quit the process (so Caps Lock reverts to the normal toggle), use menu bar Quit or Cmd+Q—that path triggers `applicationWillTerminate` → `TriggerRemap.revertAtQuit()`.

### 3.2 Caps Lock behavior in each state (unified arm)

| Operation | OFF | TAP | TAP sticky | SCROLL | WINDOW | MOVE | palette open |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Caps Lock single click (release with no chord) | enter TAP | toggle sticky / exit sub-state* | switch back to non-sticky / exit sub-state* | switch back to TAP | switch back to TAP | switch back to TAP | close palette |
| Caps Lock + d | enter SCROLL† | enter SCROLL | enter SCROLL | (re-enter SCROLL) | enter SCROLL | enter SCROLL | — |
| Caps Lock + w | enter WINDOW | enter WINDOW | enter WINDOW | enter WINDOW | (already in WINDOW, no-op) | enter WINDOW | — |
| Caps Lock + m | enter MOVE | enter MOVE | enter MOVE | enter MOVE | enter MOVE | (already in MOVE, no-op) | — |
| `Esc` | — | deactivate / exit sub-state* | deactivate / exit sub-state* | deactivate | deactivate | deactivate | deactivate |
| menu bar Quit / Cmd+Q | quit process | quit process | quit process | quit process | quit process | quit process | quit process |

\* DRAG and `/`-search are **sub-states** of TAP rather than independent modes (see §6 / §6.5). Pressing Caps Lock single-click inside a TAP sub-state first **cleans up the sub-state** (drag → drop at cursor; search → close the search overlay and restore hints) and then returns to TAP normal; Esc in the search sub-state means "cancel the search, back to TAP normal", in the dragging sub-state it means "drop at cursor then deactivate back to OFF", and only in TAP normal does it deactivate directly.

† **Browser exception**: when the foreground is a browser and the current tab is a real web page with the content script injected (http/https, etc.), Caps Lock + d **does not enter SCROLL, it is swallowed with no effect**—because on such a page d/u can already **scroll mode-lessly** (see §5.1). The decision is based on the `scroll_gate` live flag pushed by the extension (`VimSession.browserHandlesScroll()`). Pages with no content script such as chrome:// / Web Store / PDF still enter SCROLL normally (fallback).

Caps Lock + Shift/Cmd/Ctrl/Option (modifier keys) → not armed, passed through to the system/user.

**Caps Lock always responds**: WINDOW / MOVE do not "swallow" Caps Lock. `teardownCurrentMode()` cleans up before switching—WINDOW/MOVE stop the timer + close the overlay. Inside TAP, pressing Caps Lock is handled by the sub-state itself (dragging releases mouseDown, search closes the search overlay), and the overall logic is consistent with mode switching.

`VimSession.enter()`: **synchronously** sets `mode = .tap(h)` (eliminates the consecutive-press race, see §2.1), then asynchronously `h.activate()` scans + shows the overlay. When all three sources are empty it shows "no hints here" and exits.

---

## 4. TAP mode key bindings

| Key | Behavior |
| --- | --- |
| `a s d f g e r u i w t n m` | type a hint label letter (13 of them; **note: excludes h/j/k/l/v/c/o/p**) |
| `0–9` | type a hint label digit (Dock-only) |
| `Shift + last character` | **right-click** |
| (double-click some hinted element) | `'`+label moves cursor to it → `cc` double-click (double-click is uniformly `cc`, labels no longer have a dedicated double-click gesture, see §4.4) |
| `'` (apostrophe) then type a label | **move only, no click**—the cursor warps to the target, **does not click** (treats hints as cursor teleport anchors). See §4.3.5 |
| `h / j / k / l` (bare) | **move cursor** left/down/up/right (vim hjkl, hold for continuous, normal speed) |
| `Shift + hjkl` | accelerated cursor move |
| `Option + hjkl` | fine cursor move (slow, to precisely land on a small icon) |
| `c` (bare) | **left single-click** at the current cursor position (delayed ~150ms for disambiguation; paired with hjkl: move into place → `c` to click) |
| `cc` (quick double-tap of `c`, within 150ms) | **double-click** at the current cursor position |
| `Shift + c` | **right-click** at the current cursor position (immediate) |
| `Enter` | **passed through** to the focused app (menu confirm, form submit, etc. are not eaten by Keyway) |
| `v` (bare) | **enter the DRAG sub-state**—immediately `mouseDown` at the cursor position, hjkl to drag, Enter to drop, Backspace to cancel (see §6) |
| `/` (bare) | **enter the `/`-search sub-state**—OCR the focused window, character-level match, reuse the hint label pool to mark results (see §6.5) |
| `Backspace` | TAP normal: undo the last typed hint character (no-op when typed is empty); sub-states have their own semantics |
| `Shift + ;` (= `:`) | open the command palette |
| `↑↓←→` / `Cmd / Ctrl + any key` | **passed through**, not consumed (preserves system shortcuts + the app's native navigation) |

Why the hint pool has no h/j/k/l/v/c/o/p: h/j/k/l are the hjkl cursor-move keys, v is the bare key to enter the DRAG sub-state, c is the bare key for clicking, and pressing any of them bare has a dedicated meaning so they can't double as hint letters (otherwise ambiguity); `o`/`p` are dropped because the right pinky stretch feels bad. Apart from these eight, every other comfortable letter is usable, and `HintMode.alphabet` takes **13**: `a s d f g e r u i w t n m`. 13² = 169 = `maxTargets`(169), so **no single scan will ever produce a 3-letter label** (2 letters is the cap). The order is ergonomics-first (left-hand home row first; single-letter labels use `prefix` to take a prefix, and the shortest labels commit fastest). See §4.3 and `hint-rendering.md`.

Why not use Ctrl for movement: power users (e.g. HHKB) often map Ctrl+hjkl to arrow keys at the system layer, which conflicts with us. Bare hjkl avoids Ctrl entirely.

### 4.1 Label input

On each keypress:
1. `next = typed + char`
2. Filter `targets` where `label.hasPrefix(next)`:
   - 0 matches → `.ignored`, **swallow, do not exit** (mis-press; typed keeps the previous valid value, only Esc exits)
   - 1 and complete match → normal = `.committed` (after the commit click, decide the next step based on sticky); move-armed = `.moved` (warp cursor, no click, stay in TAP, see §4.3.5)
   - multiple → `.pending`, refresh the overlay to show the remaining candidates

See the commit section of `hint-rendering.md` for the implementation of committing a click.

### 4.2 Sticky and following app switches / in-app content changes

- On entering TAP, `sticky = false`.
- Caps Lock single click (release with no chord) toggles sticky—it goes through the arm mechanism of §2.1 + `handleTriggerTap()`, not inside `handleTap`.
- On a TAP hint `.committed` when sticky: `deactivate()` the current HintMode → construct a new `HintMode()` → `activate()`, the whole hint set rescans (the focused app may have changed because of the click). A non-sticky `.committed` directly `exit()`s back to OFF.

**Problem: a screen change (caused by the click or by switching apps) invalidates the overlay / mode state.** The overlay is drawn for a particular app's layout (`.statusBar` level, across all spaces, `orderFrontRegardless`, **does not follow focus**); the mode controller (WindowController / ScrollController) holds AX references to the original app. Two things can invalidate it:

1. **App switch** (Cmd+Tab, or clicking to open another app)—the overlay still sits on the old app's coordinates covering the new app; the controller's AX references still point to the old app's window. **Every active mode hits this problem**, not just sticky TAP.
2. **In-app content change** (list selection → detail panel reload, expanding a disclosure, in-place navigation, popover, opening a new window)—the synthesized click is asynchronous, so when `rehintSticky()` runs immediately it walks the **pre-click** tree, and the rescan still produces the old screen (confirmed by users in testing). **Only this sticky-TAP path needs this mechanism** (other modes have no concept of "keep operating after commit").

This is covered by **two mechanisms**. **The key distinction is whether the focused window changed**:

**Mechanism 1 — the focused window changed (app switch **or** switching windows within the same app): the old overlay is hidden immediately + the current mode is re-applied on the new frontmost 100ms later + the screenshot contains only the new app.** The entire active session (TAP / SCROLL / WINDOW / MOVE all count) hooks signals, and the first three fan into `reapplyOnCurrentFrontmost`:

| Signal | Trigger scenario | Delay / handling |
|---|---|---|
| `NSWorkspace.didActivateApplication` | Cmd+Tab app switch / single-clicking another app | ~0ms → reapply |
| `NSWorkspace.activeSpaceDidChange` | swiping across Spaces (Ctrl+arrow / three-finger swipe), or the cross-Space app-switch animation finishing | ~0ms → reapply |
| 150ms `focusedWindowPollTimer` | **within the same app** the focused window changed: Cmd+W close window / Cmd+M minimize / Cmd+\` switch window / Cmd+N open a new window | at worst 150ms → reapply |
| `NSWorkspace.didTerminateApplication` | any app quits (the **right-click Dock icon → Quit a background app** scenario: frontmost didn't change, the first three don't fire, but the Dock icon is gone → the overlay's Dock hint is stale) | see "Dock-change-only refresh" below |

A fan-in design of the first three + a single handler. The handler doesn't care who called it; it does one thing: **read the current frontmost app / window and redraw on that state**. The same logical event may fire across multiple lines at once (e.g.: on cross-Space Cmd+Tab, didActivateApplication fires immediately, activeSpaceDidChange fires again 300ms later, and the poll may also see the window change in between)—each time `reapplyOnCurrentFrontmost` re-enters it `cancel`s the previously pending reapply DispatchWorkItem and re-schedules, so **setup runs N times but the actual re-enter runs only once** (the last one wins). It also refreshes the poll's cached `lastSeenFocusedWindow` on entry, so late-arriving signals see no change and stop triggering.

> **Why poll instead of an AX observer**. `kAXFocusedWindowChangedNotification` is the more "on-point" event—an AXObserver registered on the frontmost app's PID, ~0ms latency. Tried it, cut it. The reason: emission of an AX notification is **the app's own responsibility**, and non-native frameworks (WeChat, Electron, Qt-style) widely don't emit them—the observer is like air on those apps. Polling is "I go read it myself", independent of whether the app is compliant, and is **universal**. The cost is ~7 IPC/sec (a `AXUIElementCopyAttributeValue` every 150ms, 8× cheaper than the 60fps WindowController tick) + at worst 150ms latency, acceptable. The AX observer's ~80 lines of `@convention(c)` callback + Unmanaged refcon + AXObserver/runloop source management are also avoided.

> **Dock-change-only refresh (didTerminate takes a separate lightweight path, doesn't go through reapply)**. Apps quit countless times a day—a dockless background agent (updater, helper) quitting has nothing to do with what's drawn on screen, **and should neither rescan nor flicker**. So `handleAppTerminated` does not call reapply, and instead: ① gate only in TAP (only TAP has Dock hints that can go stale); ② debounce, scheduling a `pendingDockCheck` @ +500ms (the Dock removing an icon is a ~few-hundred-ms animation, comparing immediately would false-negative; consecutive quits also coalesce into one); ③ `checkDockChangedAndRefresh` compares the **currently displayed Dock hint rects** (`HintMode.currentDockRects`, i.e. the numeric-label targets) vs **a fresh walk of the Dock's rects now** (`HintMode.collectDockRects()`, ~5ms)—essentially "does the displayed Dock still agree with the actual Dock". Only if the signature (rect rounded and sorted) differs does it `refreshInPlace` (swap targets in place, **zero flicker**); if identical, ignore. Quitting a dockless agent → Dock set unchanged → ignore; quitting an app with a Dock icon (including "temporarily has an icon while running" ones) → icon removed, reflow → set changed → refresh once. **Whether the Dock itself changed is the answer**, no need to judge whether the app is foreground/background/dockless, and no reliance on the `AXDockItem → app` mapping (that AX attribute isn't necessarily stable across versions). The gate also includes `tapSub == .normal` + `typed` empty (don't reshuffle while the user is mid-typing a label). `pendingDockCheck` is canceled in `exit()`. Cost: an irrelevant quit also wastes one Dock walk (~5ms, imperceptible), in exchange for "absolutely reliable judgment".

The observer's lifecycle is bound to "user is in an active state": every `enterX()` registers (idempotent), `exit()` unregisters; switching between modes (e.g. TAP ↔ SCROLL) does **not** unregister—`teardownCurrentMode` leaves the observer alone. Any signal trigger → immediately hide the old overlay + cancel pending operations, then re-enter according to `currentModeKind`. **TAP goes through the content settle watch (measured, replacing the fixed delay—see below); SCROLL / WINDOW / MOVE still use the fixed delay** (100ms same Space / 500ms cross Space):

- `.tap` → **after the settle watch stabilizes** `rehintSticky(isolateApp: true, fromAppSwitch: true)`: each frame `makeWindowFingerprinter(quiet:)` re-parses the new app's focused-window fingerprint (`runSettleLoop`, reusing the §4.3.2 machinery), scanning only after 2 consecutive stable frames; window not yet present/absent → `.noWindow` persists → also calls `rehintSticky`, which internally shows the no-window HUD as usual. **Both sticky and non-sticky rescan.**
- `.scroll` → after the fixed delay `enterScroll()` (re-detect the new app's scroll areas, warp, draw the overlay)
- `.window` / `.windowMove` → after the fixed delay `enterWindowMode()` / `enterWindowMove()` (re-pass the gate; if not, HUD + exit to OFF)

> Early versions had this follow only for sticky TAP, and every other mode's app switch left an overlay residue + operations still aimed at the original app (broken). After unifying it to "any active mode + app switch = re-apply on the new app", the UX aligns with user intuition: switching apps = "I now want to continue what I was just doing, on this app".

> **Why wait (history + current state)**: early versions rescanned **immediately** on receiving the notification, naively assuming "notification fired = the new app is already frontmost = nothing to wait for". In practice there's some probability of getting an empty result—`didActivateApplication` fires when the OS *marks* the app active, but during the window when the AX tree isn't filled yet / ScreenCaptureKit is still capturing a half-painted frame, the scan returns 0 targets, which then triggers `rehintSticky`'s `else { exit() }` to silently kill the whole session, and what the user sees is "after switching apps, Keyway seems gone". So a fixed delay was added to wait for the AX tree + pixels to be ready. **Now the TAP path no longer guesses with a fixed delay—it uses a settle watch to directly measure "is the content ready"** (re-parse the new window's fingerprint each frame, scan only after 2 consecutive stable frames), and the 100/500ms fixed delays below now apply **only to SCROLL / WINDOW / MOVE** (these three don't scan pixel-dense hints and aren't as timing-sensitive, not yet migrated). `isolateApp: true` is still kept (during the actual scan the screenshot excludes the Dock process and filters out the Cmd+Tab switcher HUD; the settle watch's fingerprint itself doesn't isolate, which instead lets the HUD fade-out count as a "change" that gets waited out).

> **Extra delay when switching apps across Spaces (SCROLL/WINDOW/MOVE still use it, TAP no longer needs it)**: when the user Cmd+Tabs to an app on **another Space**, macOS runs a 250-400ms slide animation—under a fixed 100ms delay the scan lands right in the middle of the animation and captures a black transition frame (hit in practice). macOS has **no public API** to tell us "currently switching Space" or "about to switch Space"—there's only `activeSpaceDidChangeNotification`, which fires only **after** the animation completes ("Did" is past tense). So a heuristic is used: when `didActivateApplication` fires, `CGWindowListCopyWindowInfo(.optionOnScreenOnly, ...)` checks whether the activated app has a window visible on the current Space—if **not** (cross-Space switch / all minimized / all hidden all manifest as this), stretch the delay from 100ms to **500ms**; meanwhile subscribe to `activeSpaceDidChangeNotification`, and if it fires within 500ms (meaning it was a cross-Space switch and the animation just finished), cancel the pending 500ms and re-schedule 100ms (the window is now visible on the current Space). If no Space change within 500ms, the app genuinely has no visible window, the original 500ms fires + HUD `SCROLL/WINDOW/MOVE: no frontmost window`.
>
> **TAP no longer needs this heuristic**: the settle watch watches pixels directly—during the slide animation that region keeps changing (in practice switching to Slack on another Space: `diff=89.8` → drops to `0.0/0.4` after the animation/render finishes → settle, hint correct), so **the animation is naturally waited out, no need to guess 100/500, no reliance on the timing of `activeSpaceDidChange`**. "No visible window" also folds into the same loop: a persistent `.noWindow` (`null==null` is itself a stable state) → `onNoWindow`, with no separate `CGWindowListCopyWindowInfo` pre-check. A cross-Space switch often fires several notifications together (didActivate + spaceChange + poll), each cancel+restarts the watch—**the last watch lands after the animation and settles cleanly**, no false settle in practice.

> **`activeSpaceDidChange` is also subscribed directly**, used as two kinds of signal: (1) the cross-Space acceleration described above; (2) the user actively switching Space (Ctrl+arrow / three-finger swipe), with no app activation but the focused app changed, also needs to re-apply on the new Space. Both go through `handleSpaceChanged` → `reapplyOnCurrentFrontmost`, and the pending cancel+re-schedule mechanism naturally dedups.

> **`isolateApp` —— exclude the entire Dock process when capturing the screenshot.** A normal screenshot is "composite the whole screen then crop", so the **Cmd+Tab switcher HUD** (which is a **Dock** window) gets captured in, and OP recognizes the whole row of app icons up there as hints (confirmed by users: after switching over, the drawn hints are the switcher icons, not the new app's UI). The switcher takes a few hundred ms to fade out, while the notification arrives **the moment** the switch happens—relying on "wait out a delay" is neither precise nor able to tell Cmd+Tab (HUD present) from a single click (no HUD) apart. Changed to `SCContentFilter(display:excludingApplications:[dockApp])` to **exclude the Dock process**: the HUD is owned by the Dock and gets excluded; the Dock itself is excluded too (doesn't matter, the OP path never hints the Dock anyway, that's handled by AX walk). Independent of whether it's present or when it disappears—the timing problem just vanishes. Cost: a fresh `SCShareableContent` query (the apps list isn't cached) + re-composition, roughly a few tens of ms extra, paid only on this infrequent app-switch path. AX-whitelist apps are unaffected—they go through AX walk to read the target app's AX tree, and the HUD is a Dock window, not in that tree.
>
> **Why not `including:[focusedApp]` (tighter isolation)?** Tried it, but Apple didn't clearly document the **canvas anchoring semantics** of the `including:` filter—where the (0,0) of the image it generates anchors in the display's global coordinates is unclear, and in practice the crop came out with a big black strip on the right half (meaning the anchoring isn't what I assumed). Getting it right would require logging across multiple models to reverse-engineer the real semantics. `excludingApplications:[dock]` is a **display-based filter** (the canvas is the display, the origin equals `display.frame.origin`, documented clearly), so the crop math is directly correct. The cost is that it doesn't exclude other apps' floating windows / notification banners—if that turns out to be a problem in practice, it's not too late to then poke at the `including:` anchoring behavior; the current bug (Cmd+Tab HUD) comes only from the Dock, and exclude-Dock is the minimal sufficient precise solution.

**Mechanism 2 — in-app content change (focused window unchanged): a single rescan after commit driven by the "content settle watch" (non-browser, non-Dock).** On commit, `deactivate()` has already hidden the overlay. A **non-browser, non-Dock** commit no longer uses a fixed 100ms, and instead starts `startContentSettleWatch()`: every ~100ms it captures a **64×36 grayscale thumbnail** (`WindowFingerprinter`—reads the already-composited frame buffer, doesn't run OP/YOLO), comparing the **per-pixel mean absolute difference** between two adjacent frames; **2 consecutive frames < threshold (settle)** triggers one scan, draws the hints, and stops.

Why no longer a fixed delay: a fixed delay is a **blind guess** of when the content finishes refreshing. Too early (the old 100ms) scans stale—Slack switching channels, the right panel repaints a few hundred ms later, the 100ms scan gets the old content, the new content never gets a hint, and you have to press Caps Lock again; waiting too long slows down the common "content didn't change" click. The thumbnail is **more precise** than a fixed delay: a static click is stable from the first frame → ~2 frames (~200ms) to recover; a click that refreshes content stays > threshold and doesn't count as stable → it waits until settle and scans **once** (no more "scan stale first then patch up" double-scan, only one OP the whole way). The overlay is hidden the entire time, so the thumbnail has none of our own chips; 64×36 averages out caret blink / sub-pixel jitter, and only a big content change crosses the threshold.

- **Cap ~1.2s**: a never-settling case (spinner / video) force-scans once at the cap, guaranteeing the hints always recover.
- **Fallback**: can't get a fingerprint (no screen recording permission—an AX-whitelist app may never have been granted it; or AX/display query failure) → fall back to a fixed 100ms (`scheduleStickyRehint`).
- **Still using a fixed 100ms**: a non-navigation commit inside a browser (late-arriving content is covered by the extension's `page_changed`), a Dock commit (covered by the app-switch follow), and the watch fallback above.
- **Cost (a deliberate tradeoff)**: content that **still hasn't changed in the first 2 frames after the click and then "lazily starts" rendering** will settle on stale frames and be missed, requiring a re-trigger—we chose the "single scan" side, in exchange for no double-scan and no stale flicker. To achieve both "fast recovery" and "catch lazily-loaded content" you must tolerate one wasted scan, which we didn't take.
- App switch / exit / entering drag/search all `cancelContentSettleWatch()`; more specific signals (app-switch, focused-window-change) have higher priority than the watch and will cancel it.

> **The TAP branch of the app-switch path (Mechanism 1 / `reapplyOnCurrentFrontmost`) has been moved onto this watch** (`runSettleLoop` is the generic primitive extracted from here)—each frame re-parses the new app's focused window, scanning only after settle, replacing the 100/500ms blind delay. In practice, cross-Space switching to Slack: `diff=89.8` (animation/screen change) → `0.0/0.4` → settle, hint correct, no false settle. SCROLL / WINDOW / MOVE still use the fixed delay (not timing-sensitive, not yet migrated). See Mechanism 1.

> **Historical gotcha.** Early on we wanted an AX notification watcher to cover same-app async changes, and hit two problems: ① even for an AX app, an immediate rescan races with the click; ② "goes through OP routing" ≠ "doesn't emit AX notifications"—WeChat's native AppKit does emit `kAXValueChanged`, it's just that the chat content is self-drawn and AX walk can't reach it so it goes through OP. Hooking a watcher to it → notification rescan + delayed rescan = **double re-hint** (confirmed with WeChat). We also rejected "screenshot polling" back then, on the grounds that "one screenshot ~50ms ≈ one OP inference, polling is more expensive than 2~3 extra rescans"—**that judgment holds for "rescan" but not for "thumbnail"**: today's watch polls a **low-resolution frame buffer read + downscale to 64×36 grayscale** (far smaller than OP's full-resolution screenshot, and doesn't run YOLO), while the expensive OP runs **once** only at the moment of settle. So "cheap thumbnail to probe settle, OP scans only once" sidesteps that old cost conclusion.

### 4.3 Cursor auto-jump rules (cursor auto-park)

**Trigger**: entering TAP / the reapply triggered by sticky follow / app-switch follow / focused-window-change all enter `parkCursorOnFrontmostWindowIfOutside`.

**Three-step decision**:

```
Step 1: read the frontmost app's focused window rect
        - no frontmost app / no visible window → skip the whole park, HUD "no frontmost window"

Step 2: is the cursor already inside that window?
        - yes: do nothing (respect the position the user deliberately let it stay at)
        - no: proceed to Step 3 to decide the landing point

Step 3: pick an input rect, fall back to the title bar on failure
        ┌─ is frontmost a browser (Chrome/Safari/Brave/Arc/Edge)?
        │   yes → BrowserProvider.findFirstInputRect (DOM)
        │        - the extension detector.js looks for:
        │          1. document.activeElement (the one the user last clicked)
        │          2. the first visible input/textarea/contenteditable
        │        - browser has no extension / not connected / chrome:// pages → null
        │   no → AXFocusedUIElement (native AX)
        │        - role whitelist: AXTextField/AXTextArea/AXSearchField/AXComboBox
        │        - or AXValue is writable (covers Electron-style elements that return a non-standard role but are genuinely editable)
        │        - also requires the rect to intersect the window + be at least 4×4
        │
        └─ got a rect → warp to the rect center (MouseSynth.warp, .mouseMoved synthesized event)
           got null → fallback:
             - browser → window **content center** (rect.midX, rect.midY)
             - other apps → title bar midpoint (rect.midX, rect.minY + 6pt)
```

> **Why the browser fallback lands at the content center rather than the title bar**: the browser page's d/u/gg/G mode-less scrolling **sends a real scroll wheel at the cursor** (see §5.1), so landing on the title bar parks the cursor on a non-scrollable bar and you can't scroll right after switching over; landing at the content center sits right on the page so you can scroll immediately (it's also a decent starting position for a hint). Other apps still land on the title bar (handy for double-click maximize / drag / window buttons nearby).

**Actual behavior per app type**:

| App type | Last focus | Landing point |
|---|---|---|
| Browser (extension installed) | focus on some input | `document.activeElement` center |
| Browser | never clicked any input | first visible input center on the page |
| Browser | page has no input / chrome:// | window **content center** (so you can d/u scroll right after switching over) |
| AX-friendly native (Mail / Notes / WeChat / TextEdit) | focus on a text input | that input's center |
| AX-friendly native | focus on a button / link / list item | title bar (role not in whitelist, safe) |
| Electron / weak AX (Slack / Discord / VS Code) | — | title bar midpoint (`AXFocusedUIElement` returns `kAXErrorNoValue`) |
| Finder Desktop (no window) | — | skip the whole park |

**Design principles**:

1. **Don't move the cursor if it's already in the window** —— the Step 2 short-circuit preserves the position the user deliberately chose (e.g. the mouse was already moved somewhere with hjkl during sticky TAP)
2. **Only jump to text-type inputs** —— don't jump to button / link / menu item, to avoid accidentally triggering an unexpected action after Cmd+Tab
3. **Don't force what AX doesn't expose** —— Electron-style apps simply accept the title bar fallback, no deep AX subtree walk (we tried a walker fallback + role-survey diagnostics before, the complexity wasn't worth the payoff, reverted). Once the per-app patch route is started, we could write a hardcoded rule for Slack like "compose is 80pt from the window bottom"
4. **Observable** —— each branch logs `[keyway] focusedInput: ...` (match via role / via editable-value / read failed / rect too small / rect outside window / skipped role=...), so when some app doesn't take effect, one line shows which gate stopped it
5. **`.mouseMoved` rather than `CGWarp`** —— same as the §6.5 search commit reasoning, so the target view receives the event and updates the cursor shape (I-beam) + hover state

**The cursor after committing a Dock hint**: clicking a Dock icon's hint synthesizes a real mouse click, and the cursor **stays on the Dock icon**—awkward for what follows (especially if you want to scroll the just-opened app). Handled in two ways:

- **sticky TAP**: after the click switches apps, sticky's "follow frontmost" (`reapplyOnCurrentFrontmost`) automatically re-parks to the new app's window (browser→content center), nothing extra to do.
- **non-sticky** (normal, after the click `exit()` back to OFF): a dedicated **one-shot `didActivateApplication` observer** (`scheduleDockActivationPark`). After the new app activates, **it copies sticky's settle model**—`frontmostAppHasOnScreenWindow()` on screen 0.1s / not on screen (cold start) 0.5s, then `parkCursorOnFrontmostWindowIfOutside` **parks once** (browser→content center).

  Gating: the park is bound to "the pid of the app that activated", and if at the moment of park the foreground is no longer it (switched away right after the click) → **don't move the cursor** (leave it on the Dock); 2s with no activation at all (clicked an icon already in the foreground / launch failed) → discard the observer; entering any mode (`teardownCurrentMode`) → cancel the pending park. Only effective for **Dock sources** (`lastCommittedTarget.role == "AXDockItem"`), a normal in-app button click does not move the cursor.

### 4.3.5 `'` prefix —— hint as a cursor teleport anchor (move-only pick)

Upgrades a hint from a "click target" to a "fast cursor jump point". Flow:

```
press ' in TAP    → arm move-only (labels turn light yellow, HUD shows "TAP · move")
  then type a label → cursor warps to target center, **no click**
  after pick        → auto-reset (disarm), hints stay on screen, stay in TAP/sticky
press ' again (before pick) → cancel the arm
```

**Why this trigger** (design tradeoff):

- **No modifier key**: Cmd/Ctrl conflict with system shortcuts; Shift/Option are already taken by double-click/right-click
- **No new mode**: too heavy for the immediate intent of "this one is just a move"
- **The one-shot prefix `'`** is neither —— it's just a bool flag, auto-cleared after the pick or on exit. It's vim's mark "jump to" semantics; `'` isn't in the hint pool, so it won't conflict with a label

**Key behavior: a move pick does not terminate the session**. A click pick is a terminating action (non-sticky exits after commit); a move pick is a **navigation** action, and after moving you should keep working. So:

- After the cursor warps, **stay in TAP** (regardless of sticky) —— `HintResult.moved` rather than `.committed`
- After the move, the content is unchanged and the hint positions are unchanged → **no rescan**, the same batch of targets instantly re-displays (zero latency, no flicker)
- Reset back to normal yellow, and the user can continue: another `'`+label to move elsewhere / type a label to click directly / hjkl to fine-tune / `c` to click / `v` to drag

**Implementation**: `HintMode.moveArmed` is a one-shot flag, `toggleMoveArmed()` is triggered by `'`; when `handle()` hits a unique label and armed, it goes through `commit(action: .move)` → `MouseSynth.warp` (`.mouseMoved` synthesized, updates cursor shape/hover) rather than a click, then keeps the targets + clears typed + disarms + re-renders, returning `.moved`. The overlay's `moveArmed` parameter decides light yellow (`1.0, 0.95, 0.70`) vs normal yellow (`1.0, 0.84, 0.0`).

Combined with the §4.3 hjkl fine-tuning + double-click cross-screen jump, the navigation loop: `'`+label for coarse positioning → hjkl/double-click for fine adjustment → `c`/`v` to operate.

### 4.3.6 Click modifiers: Shift=right-click (double-click is uniformly `cc`)

The click type of a **hint label commit** is decided by the modifier:

| Input | Action |
|---|---|
| bare | left-click |
| Shift held + label | right-click |
| Option | **maps to no click** |

`clickAction(for:)`: `Shift ? .right : .left`, **used only for hint label commit**.

**Double-click has no label gesture**—double-click is **the globally unified `cc`-at-cursor** (see §4.4): to double-click a hinted element, `'`+label teleports the cursor to it (no click, §4.3.5) → `cc` to double-click.

> **Evolution**: the double-click for `c`/label originally used a "Shift press-release-hold" state machine (`shiftDoubleArmed` / `handleShiftFlagsChanged` / `noteKeyWhileShiftHeld`, sharing `windowReverseTapWindow` with the WINDOW resize double-click). Later `c` was changed to the more intuitive `cc` double-click; label double-click is rare, so it was dropped too, making "double-click = `cc`" the only rule. That Shift state machine has been **removed from the code entirely** (`clickAction` only keeps Shift→right-click). Shift's semantics across the project are unified to "accelerate" (cursor move/scroll) + "right-click" (click); Option is freed up for other uses.

### 4.4 bare `c` —— click at cursor position + hjkl cursor move

bare `c` pairs with hjkl to form the "keyboard mouse" inside TAP: **hjkl moves the cursor into alignment, `c` clicks**.

- **`c` (single click)** = synthesize a left single-click at the **current mouse cursor position**. The landing point = wherever the cursor is now. `c` has been removed from the hint pool (same as `v`), so it won't conflict with a hint label. After the click, dispatch by sticky: sticky → rescan and stay in TAP; otherwise → exit.
- **`cc` (quick double-tap of `c`, within 150ms) = double-click**. See `handleBareCClick`: a bare `c` single-click is **delayed ~150ms** (`cDoubleTapWindow`, aligned with `windowReverseTapWindow`)—a second `c` within the window → cancel the single-click, send a **double-click** (`MouseSynth.click(count:2)`, the full down/up×2 sequence); window expires with no second `c` → single-click. **Two `c`s more than 150ms apart are two independent single-clicks, not a double-click.** Cost: a single-click `c` has ~150ms extra latency (the disambiguation cost). Switching modes / switching apps cancels the pending single-click.
- **`Shift+c` = right-click** (immediate, not part of single/double judgment).
  - (The old scheme where the double-click for `c` and label both went through the "Shift press-release-hold" state machine has been **removed entirely**; double-click is now uniformly `cc`, and labels no longer have a dedicated double-click gesture, see §4.3.6.)
- **`h/j/k/l`** = move cursor (vim hjkl: h left, j down, k up, l right), hold for continuous (60fps timer synthesizing `.mouseMoved`, hover state updates), Shift to accelerate / Option to fine. See `MouseMover.swift` for the implementation. **TAP and SCROLL share the same hjkl** (`VimSession.moveDirection(for:)` single mapping).
- **Double-tap `hh` / `jj` / `kk` / `ll`** (release then press again within 100ms, using `hjklJumpTapWindow`, tighter than WINDOW reverse's 150ms) = **the cursor jumps 1/2 the current screen** in that direction in one shot. **Shift+double-tap = jump a whole screen** (long distance in one go). (Originally 1/4 + 1/2; in practice 1/4 was too useless, bumped up a notch.) Holding the second press down → OS key-repeat makes each repeat pass the double-tap window (each jump refreshes the `lastTapHjklKeyUp` timestamp), **jumping continuously** until release. In a multi-screen setup it takes the size of **the screen the cursor is currently on** as the baseline, clamped to that screen's bounds (3pt inset).
  - Uses `MouseSynth.warp` (synthesize `.mouseMoved`) rather than raw `CGWarpMouseCursorPosition`—same reasoning as the `/`-search commit, so the target view receives the event and updates cursor shape / hover state
  - **Disabled** in the drag sub-state (each press must continue the held drag, and a jump would make the drop target unpredictable); the search sub-state already swallows hjkl, so it's naturally unaffected
  - Shift decides 1/2 vs whole screen; Option / Cmd / Ctrl don't affect the jump distance (they have semantics elsewhere, and stacking on a jump is semantically unclear)
- Synthesized clicks/moves all go through `MouseSynth` (HintMode's hint-commit click uses it too).

**Why not Enter**: early versions used `Enter` as the click key, but Enter **often has its own semantics** inside an app—the typical scenario is pressing ↑↓ to nav a menu and then Enter to confirm the selected item. Combined with the arrow-key pass-through of §11, users expect Enter to also pass through to the app. Moving "click" onto `c` makes both work: Enter always passes through, `c` always clicks.

**History**: `x` → `Enter` → `c`. `x` was originally the "dismiss all open menus + rescan" gesture (Dock menu AXCancel + close overlays on focus switch); changing to `Enter` was for intuitiveness (confirm/click) + pairing with hjkl to form the "keyboard mouse" loop; changing to `c` was to pass Enter through to the app. `v` is a product of the same cadence: bare → chord → bare sub-state trigger key. The old `findOpenDockMenu` / `AXCancel` / `AXWait.appActivated` machinery has been removed from the code, and the **menu-closing capability is lost** (clicking on a control with the cursor would mis-trigger it), acceptable.

---

## 5. SCROLL mode key bindings

Keyboard scroll. See [`scroll-mode-design.md`](scroll-mode-design.md) for the full design; this is a key-binding summary.

| Key | Behavior |
| --- | --- |
| `d` / `u` (bare) | scroll down/up **vertically** (hold for continuous, 60fps timer synthesizing scroll wheel event wheel1) |
| `b` / `f` (bare) | scroll left/right **horizontally** (hold for continuous, synthesizing wheel2). Use cases: Finder column view / wide tables / Notion DB tables / Figma infinite canvas / calendar week view, etc. |
| `Shift + d/u/b/f` | accelerated scroll (vertical or horizontal) |
| `gg` (press g twice) | jump to the **top** of the selected area (vim-style, vertical only) |
| `G` (Shift+g) | jump to the **bottom** of the selected area (vertical only) |
| `h/j/k/l` (bare) | move cursor left/down/up/right (vim hjkl, **unified with TAP**, hold for continuous) |
| `Shift + hjkl` / `Option + hjkl` | accelerate / fine cursor move |
| **double-tap** `hh` / `jj` / `kk` / `ll` | jump **1/2** the current screen distance in that direction; **Shift+double-tap = whole screen** (the same double-tap-jump mechanism as TAP §4.3, sharing the `maybeJumpOnDoubleTap` helper + `lastTapHjklKeyUp` dictionary; press twice within 100ms) |
| `c` (bare) | left single-click at the current cursor position (delayed ~150ms for disambiguation, stays in SCROLL); `cc` quick double-tap = double-click |
| `Shift + c` | **right-click** at the current cursor position (immediate) |
| `Enter` | **passed through** to the focused app (unified with TAP normal §4) |
| `/` (bare) | **enter the `/`-search sub-state**—OCR the focused window, character-level match, reuse the hint label pool to mark results; after commit the cursor warps to the left of the matched text and returns to SCROLL normal (the scroll-area picker overlay restores automatically). Shares one mechanism with TAP's §6.5 search |
| `number keys 1-9` | switch the selected scroll area |
| Caps Lock single click | switch back to TAP (see §2.1) |
| `Esc` | search sub-state: cancel back to SCROLL normal; normal: deactivate back to OFF |

**Cursor moves with hjkl, fully unified with TAP**: early SCROLL used SDFE and TAP used IJKL, two sets of movement keys forcing the user to switch muscle memory between modes—a real cognitive burden. Now unified to vim hjkl (`VimSession.moveDirection(for:)` single mapping, shared by both modes), so "move cursor" is the same everywhere, and only scroll/click differ by mode. Scroll therefore moved from `j/k` to **`d`(down)/`u`(up)**—`j/k` are given to cursor move, and `d` also conveniently matches the chord key that enters SCROLL. `c` pairs with hjkl (move→click loop), reusing `MouseMover` / `MouseSynth` (the same set as TAP).

**Horizontal scroll `b`/`f`**: the same left-hand home row cadence as `d`/`u` (`b`=back/left, `f`=forward/right). `ScrollController` uses an `Axis` enum to uniformly drive wheel1 (vertical) or wheel2 (horizontal), reusing a single timer, with no pause when switching axes. The convention is that both wheel1 / wheel2 mean "negative value = scroll in the forward direction" (forward = down / right). `gg` / `G` were not extended to horizontal ("line start/end" isn't a routine need in many scenarios, not worth adding a new chord).

**`/`-search is also supported in SCROLL**: search is essentially "precise cursor teleport"—since SCROLL already supports hjkl relative cursor move + c click, adding `/` absolute jump forms the complete loop of "scroll to roughly the right place → search to pinpoint → c to click", all without leaving SCROLL. The mechanism is exactly the same as TAP's §6.5, the only difference being the host overlay: on entering search, hide the scroll-area picker, and after commit, when the cursor warp is done, restore the picker (not a sticky-rehint like TAP, because SCROLL has no hint concept). The underlying OCR / label generation / SearchOverlay are fully reused; see the `setSearchPhase` / `searchPhase` helper functions for the host-agnostic implementation.

> Before unification, the two modes had different movement keys (TAP=IJKL, SCROLL=SDFE), a compromise under each one's key-binding constraints; after unifying to hjkl the cognitive burden is eliminated. In the future, user-customizable key configuration will be opened up.

To enter: in any mode hold Caps Lock + d (chord). On entry, `ScrollAreaDetector` AX-walks the focused window to find all `AXScrollArea` + `AXWebArea`, `ScrollOverlay` draws a blue glow border + numeric markers, and selects the area closest to the cursor by default. **Cursor already inside the selected area → no warp**; only when outside does it warp to the area center (scroll events route by cursor position, so landing anywhere inside the area is fine, and warping when already inside is redundant and jarring).

A zero-AX app (Electron with a11y off, e.g. Claude; **Chrome web content too—renderer a11y is off by default**) detects no scroll area → falls back to the focused window: if the cursor is already in the window don't move, only warp to the window center when outside, with no area picker. Unrecognized areas are covered by a future "keyboard pan the mouse" / extension DOM scroll-container detection fallback.

### 5.1 Browser mode-less scroll (d/u/gg/G, Vimium-style)

**Only for the case where the foreground is a browser and the current tab is a real web page**: no need to press Caps Lock + d to enter SCROLL first, **just `d`/`u` (Shift to accelerate) for continuous scroll, `gg`/`G` to jump to top/bottom**—just like Vimium. This is also why Caps Lock + d is disabled on such a page (§3.2 †).

The implementation goes through **extension content script detection + native sending a real scroll wheel** in two stages (see [`browser-support-design.md`](browser-support-design.md) §4.11), key points:

- **Key detection is in the web page** (content script, capture phase): when focus is on an editable element (input/textarea/contenteditable, etc.) it passes through to let the user type; with Cmd/Ctrl/Alt it passes through; only bare d/u/gg/G are intercepted (`preventDefault`). The "editable check" reads `document.activeElement` synchronously in JS, which is why it must live on the web-page side rather than the native event tap.
- **The actual scroll is in native**: the content script only sends `page_scroll` (start/stop/jump) commands at gesture boundaries, and native uses a resident `ScrollController` (no enter, no warp, no overlay) to **send a real CGEvent scroll wheel at the cursor**. The benefit: the scroll wheel goes through the browser kernel's scroll-containment logic, so it **scrolls the container under the cursor and doesn't leak to the page** (the YouTube sidebar vs main content interlock can't be solved by JS `scrollBy`, but a real scroll wheel is naturally correct); the 60fps continuous scroll runs locally in native, with IPC only on start/stop/jump.
- **Auto-disabled on entering a mode**: once any Keyway mode is entered, the native event tap swallows d/u before the web page receives the key → the content script doesn't fire → mode-less scroll auto-stops. Zero coordination.
- **Fallback**: entering a mode (`teardownCurrentMode`) and an extension disconnect (`onActiveClientDisconnect`) both stop any in-flight page scroll, preventing "entered a mode before releasing / SW died" from scrolling forever.

Other apps (non-browsers) are unaffected and still need Caps Lock + d to enter SCROLL.

---

## 6. DRAG sub-state (a sub-state of TAP **and** SCROLL, not an independent mode)

Full-keyboard drag, vim-visual style. **Single-stage**: pressing bare `v` in TAP normal **immediately** synthesizes `mouseDown` at the cursor position to enter the dragging sub-state—the user has already aimed the cursor onto the target with hjkl, so there's no need for an extra "armed, press v again" interval. `DragController` only holds `startPoint: CGPoint` (used when Backspace cancels).

**Entry and ownership**: DRAG has **a parallel sub-state in each of TAP and SCROLL** (`TapSub.dragging(DragController)` / `ScrollSub.dragging(DragController)`), both entered from their respective normal via bare `v`. TAP's drag drop/cancel returns to **TAP normal** (sticky → rehint; non-sticky → exit OFF); SCROLL's returns to **SCROLL normal** (SCROLL has no sticky/exit concept, after drop/cancel it stays in SCROLL). There is **no "enter DRAG directly" path** from OFF / WINDOW / MOVE.

| Key | Behavior |
| --- | --- |
| **Enter: bare `v`** (TAP normal only) | immediately `leftMouseDown` at the cursor position → tapSub = dragging; record `startPoint`; hide the hint overlay (labels interfere with the drag sightline), HUD `TAP · DRAG` |
| `h / j / k / l` (held) | move cursor, event type `.leftMouseDragged` (the target app sees the drag track); Shift to accelerate / Option to slow, speed consistent with TAP normal |
| `Enter` | `leftMouseUp` at the current position → drop; return to TAP normal (sticky → `scheduleStickyRehint()`; non-sticky → exit OFF, consistent with a hint commit) |
| `Backspace` | warp the cursor back to `startPoint` → `leftMouseUp` at the start point (the target app sees a zero-displacement click, no drop triggered) → return to TAP normal, restore the hint overlay |
| `Esc` | drop at cursor then deactivate back to OFF (the drop side-effect is unavoidable—the button must be released) |
| `Caps Lock` (single click / + d / + w / + m chord) | before switching, `cleanupTapSub` does a mouseUp release at the current position (drop side-effect, same as Esc), then performs the corresponding mode switch |
| Other keys | swallowed (even more so while mouseDown is held, no stray keys should slip through) |

**Why the earlier two-stage armed/grab was removed**: early on, `Caps Lock + v` chord entered armed (no grab), and only a subsequent bare `v` grabbed, in order to "aim first, then grab". But in TAP, moving the cursor with hjkl is already aiming—the user walks onto the target and then presses v when they want to drag, **already done aiming**, so the extra armed stage instead requires pressing v twice and remembering whether the current state is armed or dragging. Folding DRAG into a TAP sub-state + single-stage: in TAP aim → bare v → grab directly → hjkl to drag → Enter to drop, the simplest cognitive model.

**`v` key choice note**: the counterpart to vim visual. `v` is **removed from the hint pool** (see §4)—in TAP normal a bare v is always "enter DRAG", never conflicting with a hint commit. Cost: the hint pool shrinks from 17 letters back to 16; 16² = 256 still far covers maxTargets = 200, no impact.

**Typical use cases**:
- Drag a file: Caps Lock to enter TAP → hjkl to precisely move the cursor onto the file icon → `v` → hjkl to drag to the target folder (hover highlight + drag indicator) → Enter.
- Select text + copy: (first use `/` search to position the start cursor—see §6.5) → `v` → hjkl to the end point (text along the way gets selected) → Enter (release, **selection retained**) → Cmd+C to copy.
- Drag a divider / slider / timeline trim: hjkl to move the cursor onto the divider → `v` → hjkl to drag → Enter.

**Drag inside SCROLL (`ScrollSub.dragging`)**: mirrors the TAP version, but with one extra dedicated capability—**scroll while dragging**. This is exactly the value of "drag inside SCROLL" over "drag inside TAP": while holding the drag, `d/u` (vertical) / `b/f` (horizontal) keep driving the `ScrollController`, the mouse button isn't released, so you can drag-select across viewports (hold here, `d` to scroll down and select a large chunk of text beyond the screen, Enter to drop).
- Enter: bare `v` in SCROLL normal (`v` is otherwise empty in SCROLL) → `startDragFromScroll()`: `controller.stop()` stops the continuous scroll → `DragController(at: cursor)` synthesizes mouseDown → `scrollSub = .dragging` → `controller.hideOverlay()` hides the area picker → HUD `SCROLL · dragging`.
- `h/j/k/l`: the early-intercept `.scroll` branch detects `.dragging` → `allowsMoveHere=true, dragHeld=true` (still false in normal, goes through handleScrollNormal), so dragging the cursor emits `.leftMouseDragged`.
- `d/u/b/f`: `handleScrollDragging` calls `controller.start(...)` as usual (keyUp stops via the shared `handleKeyUp` scroll path).
- `Enter` drop / `Backspace` cancel → `scrollDragDrop` / `scrollDragCancel`: mouseUp (cancel first warps back to startPoint), `controller.showOverlay()` restores the picker, return to SCROLL normal (**no exit**).
- `Esc` / switch mode: goes through `exit` / `teardownCurrentMode` → the `.dragging` branch of `cleanupScrollSub` adds a mouseUp to release the button (same as `cleanupTapSub`).

**Implementation notes**:
- `startDragFromTap()` / `startDragFromScroll()` immediately `MouseSynth.dragDown(at: cursor)` (synthesized when `DragController(at:)` is constructed), with no intermediate "armed, wait for v" state.
- The early hjkl intercept reads `tapSub` / `scrollSub` to decide `dragHeld` (dragging = `.leftMouseDragged`, other sub-states = `.mouseMoved`).
- The mouseUp in `cleanupTapSub()` / `cleanupScrollSub()` / `exit` is synthesized only in the dragging sub-state (other sub-states have nothing to release).
- On entering TAP DRAG, cancel `pendingStickyRehint` (to avoid the re-hint within the 100ms delay popping up an overlay mid-drag); SCROLL has no sticky-rehint, so it's not needed.

---

## 6.5 `/`-search sub-state (a sub-state of TAP)

Press bare `/` to enter: find all occurrences of the query in the focused window, reuse the hint label pool to mark each match—the user types the query → Enter → sees a cluster of labeled highlight boxes → types a label to commit → cursor warps to the left edge of the matched text (rect.minX, minY + 0.6×height) → back to TAP normal.

**Two match paths** (`kickoffSearch` branches by frontmost bundleID):

- **Browser frontmost** → goes through the extension DOM `KeywayDetector.findTextMatches(query)`: TreeWalker traverses visible text nodes + Range.getClientRects() yields rects within the viewport. **~5-20ms**, character-level 100% accurate. One match per visual line (a multi-line wrap auto-expands into multiple highlight boxes). Off-viewport ones aren't returned (OCR can't see off-screen content either, behavior aligned). **top frame only for v1** (iframe content deferred).
- **All other apps** → the old Vision OCR path: `ScreenCapture.captureFocusedWindow()` + `OCRRefiner.recognizeText` (zh + en bilingual) + `findMatches(query, observations, windowRect)` character-level boundingBox. **80-200ms**, may have OCR misreads ("complete" → "tomplete" and the like).

The terminal log distinguishes the two: `[keyway] search: ... — DOM match via extension` vs `... — capturing + OCR'ing focused window`.

`MouseSynth.warp` uses a `.mouseMoved` synthesized event so the target view receives the event and the cursor flips to I-beam (the same design as the §4.3 cursor park).

**Why build it separately, not reuse the hint pipeline**: hint mode goes through AX walk + OmniParser to find **clickable elements**; search goes through OCR + text matching to find **where some string is**—two completely different retrieval intents. For example, to copy some middle message in a long WeChat chat, hint gives the message row (each row has only one commit point, and after clicking you select the row rather than landing the caret in the text), which can't locate "the start of that text" at all; OCR directly finds the text and gives the pixel position by character-level boundingBox.

**Why it doesn't depend on the AX whitelist**: the user explicitly specified that search should **use OCR for all apps**, with no AX / OP distinction. The hint pool has a whitelist because the clickable elements AX gives are more precise; search is text retrieval, and AX can't get "the pixel position of the 47th character". Going uniformly through OCR is actually the simplest.

**Why character-level boundingBox**: `VNRecognizedText.boundingBox(for: range)` gives the precise pixel rect of the substring in the image, rather than the coarse box of a whole-line OCR observation. The user searching "complete" wants to land in front of the c, not at the start of the whole paragraph.

**Input side currently supports ASCII only**: OCR is bilingual (zh + en) but the search buffer only accepts a-z / 0-9 / space (including **Shift+letter uppercase**—`typingMods` lets Shift through, and on press the character is `.uppercased()`). The reason is that CGEventTap intercepts keyDown before the IME, and the IME can't compose without the raw input. Chinese support is recorded in the `SPECS.md` §7 TODO list.

**Sub-state machine**:

| Sub-state | Meaning | Entry condition |
| --- | --- | --- |
| `.searchTyping(buffer)` | the user is typing the query (buffer not yet OCR'd) | press `/` in TAP normal |
| `.searchSearching` | OCR + match running (async Task) | press Enter in `.searchTyping` with a non-empty buffer |
| `.searchPicking(matches, typed)` | match results have been drawn as labeled highlight boxes, the user is typing a label to select | OCR done and matches non-empty |

On entering `.searchTyping`, **hide** TAP's hint overlay (the label pool is reused, and they can't clash visually); when matches come out, `SearchOverlay` separately draws a yellow highlight box + label chip; on commit, hide the search overlay, warp the cursor, `tapSub = .normal`, `scheduleStickyRehint()` to bring the hint overlay back 100ms later (if the user presses v to enter drag within that 100ms, the pending rehint is canceled by startDragFromTap—see the §6 implementation notes).

**Key bindings**:

| Key | `.searchTyping` | `.searchSearching` | `.searchPicking` |
| --- | --- | --- | --- |
| letter / digit / space | append to buffer, update HUD | swallow (OCR running) | append to typed, filter matching labels; a unique complete hit → commit |
| `Enter` | kickoff OCR (only runs if buffer non-empty) | swallow | swallow (commit is triggered by finishing the label) |
| `Backspace` | delete one character; press again on empty buffer = cancel back to TAP normal | swallow | delete one character; press again on empty typed = back to `.searchTyping("")` to re-enter the query |
| `Esc` | cancel back to TAP normal (restore hint overlay) | cancel back to TAP normal (the OCR task enters the cancellation guard) | cancel back to TAP normal |
| Caps Lock single click / chord | same as dragging: clean up first (close the search overlay, restore hints) then switch mode | same | same |

**Commit landing point**: `(rect.minX, rect.minY + 0.6×height)` —— the **left edge** of the matched text, 60% down vertically from the top. X has no inset (early discussion considered a -2pt offset to put the cursor **outside** the first character, but all macOS text controls hit-test inclusively at minX, so landing at minX is inside the text). Y uses 60% rather than 50%: a character boundingBox usually hugs the text itself, and the vertical center (midY) would land in the character's strokes, and a text view's hit-test sometimes judges that as "inside the character" rather than a "caret gap"; 60% (slightly below midY) lands near the character baseline and is more stable. Right after commit you can press `v` to start a drag (the §6 entry), which is the core workflow of search → drag to select and copy text.

**Synthesize with `.mouseMoved` rather than `CGWarpMouseCursorPosition`**: CGWarp moves the pixels over but **skips the event pipeline**, so the target view doesn't know the mouse came in, and the cursor shape stays as it was before the warp (typical symptom: after landing on a text box the cursor is still an arrow rather than an I-beam, and you have to jiggle the mouse to flip it). Changed to synthesizing one `.mouseMoved` to the same landing point, the view receives a normal event → triggers cursorRect / hover state updates → the I-beam flips over, the button highlights, the link underlines, the tooltip, etc. all come into place. The cost is that one synthesized `CGEvent` is ~1ms more than a direct warp, negligible.

**Why OCR runs against the **whole focused window** rather than a crop like OP's**: the text the user searches for could be anywhere in the window; a crop doesn't know where to crop. A whole-window OCR takes ~80-200ms (depending on character count), and the user has already pressed Enter and can accept this latency (unlike hint mode, which is at the instant of entry).

**Implementation notes**:
- `OCRRefiner.recognizeText(in:)` is extracted for search to use (the same `.accurate` + zh/en config, shared with the OP refiner).
- `findMatches(query, observations, windowRect)`: for each observation find all substring hits (multiple hits on the same line = multiple labels), using `topCandidates(1)[0].boundingBox(for: range)` to get the character-level rect. case-insensitive.
- Labels reuse `HintMode.generateLabels(count:)` (`generateLabels` has been opened up to internal), so search's labels are visually consistent with hint labels and have the same keying habits.
- `SearchOverlay` is another `.statusBar`-level borderless transparent NSWindow (per-NSScreen), drawing a yellow highlight box + label chip (the chip is on the **left** of the matched text, falling back to the inside when it doesn't fit).
- The async OCR Task guards `tapSub == .searchSearching` at every await point, so when the user cancels / switches mode while OCR is running, the task short-circuits itself.

---

## 7. WINDOW mode key bindings

Whole-window resize. `WindowController` holds state + a 60fps timer, and each tick computes the delta and directly AX-writes the focused window's `AXPosition` / `AXSize`, instantaneously and without animation.

| Key | Behavior |
| --- | --- |
| **Enter: `Caps Lock + w` chord** (any mode) | enters only if both gates pass (see below). If either fails → HUD shows the reason, doesn't enter the mode |
| `h` / `j` / `k` / `l` (held) | push the corresponding border **outward** (`k` top up / `j` bottom down / `h` left out / `l` right out), hold for continuous; step 20pt/tick @ 60fps |
| **double-tap** `hh` / `jj` / `kk` / `ll` (press the same key twice within 150ms, holding the second) | **reverse** that edge: push inward = shrink that edge. Each edge is independent—you can hold k to expand the top + double-tap jj to shrink the bottom at the same time |
| `Shift + hjkl` | **accelerate** (80pt/tick = 4×, fast cross-screen reshape). Consistent with the Shift semantics of TAP-hjkl cursor move, SCROLL d/u, MOVE hjkl |
| `Option + hjkl` | **fine** step (5pt/tick instead of the default 20pt/tick), for micro-adjusting when snapping to another window/screen edge |
| `Shift + Option + hjkl` | Option wins → slow (mimicking `MouseMover.moveSpeed` / `WindowMoveController`: a mis-pressed Shift+Option leans toward "slow" rather than "fast") |
| simultaneous (e.g. `h+j`) | combination → corner push/pull, all 4 corners work. The double-tap reverse is also independent—`kk + jj` double-tap held together = top and bottom shrink at the same time |
| conflicting pair (`h+l` or `j+k`) | the deltas naturally cancel (both position and size cancel +/−, the window doesn't change) |
| `Esc` | exit OFF (teardown: stop timer / close overlay) |
| Other keys | swallowed |
| `Caps Lock` (single click / + d / + w / + m chord) | immediately switch to the corresponding mode. `teardownCurrentMode` first stops the timer + closes the overlay before switching; resize leaves no residual state |

**The two gates to enter the mode** (`enterWindowMode`):

1. **`AXWindowOps.hasTitleBarButton(window)`** —— at least one title bar button (`AXCloseButton` / `AXMinimizeButton` / `AXZoomButton` / `AXFullScreenButton`). This is the criterion for "is this a real user window":
   - **Finder Desktop** (the desktop "window" that `AXFocusedWindow` lands on when no Finder window is open): has no title bar buttons → rejected. It was never something the user can resize anyway.
   - **macOS fullscreen state**: the title bar buttons are hidden → rejected. You can't resize in the fullscreen state either.
   - **AX black-hole apps** (Electron, etc.): the shell NSWindow chrome is native, and the title bar buttons can be queried in the AX tree (the AX black hole is the window **content** layer) → passes.
   - **Why this and not `AXSubrole == "AXStandardWindow"`**: AX black-hole apps' subrole is often nil / garbage / not exposed, and a strict subrole check would false-kill. Checking directly whether a title bar button attribute exists is more robust than subrole; at most 4 IPC (returns on a short-circuit hit), one-shot.
2. **`AXWindowOps.isResizable(window)`** —— both `AXPosition` and `AXSize` must be `AXUIElementIsAttributeSettable`. Resize works by writing these two attributes each tick, so if either doesn't go through it simply can't be done.

**Visual** (`WindowOpOverlay`): a blue solid border (3pt) hugging the window's outer edge; 4 **two-line chips** (blue background, white text) hugging the **outer side** of each edge's midpoint:
- First line (large bold): bare key + expand direction, e.g. `↑k`
- Second line (small, slightly faded): double-tap reverse, e.g. `↓kk`

Full mapping: top `↑k / ↓kk`, bottom `↓j / ↑jj`, left `←h / →hh`, right `→l / ←ll`. Corners are **not drawn**—the hjkl combinations are implicit, no extra chip. **Off-screen chips are not drawn**: each chip individually checks whether it's fully contained within some NSScreen's view bounds; when the window is flush against the top of the screen, the top chip would be in the off-screen area, so it's **simply not drawn** (the user explicitly required: don't draw off-screen).

**Why double-tap to reverse, not Shift to reverse**: earlier versions used `Shift+hjkl` for shrink (reverse)—but Shift's fixed semantics across the whole project is "accelerate" (TAP-hjkl cursor move, SCROLL d/u, MOVE-hjkl are all Shift=fast). Having WINDOW use Shift for reverse (a) is inconsistent with other modes, so the user gets confused switching back and forth, and (b) makes resize lose its accelerate ability. After changing to "double-tap the same key to reverse": Shift returns to accelerate, reverse lands on a muscle memory that's already vim-style (double-tap), and each edge's reverse state can be tracked independently (holding k to expand the top + double-tap jj to shrink the bottom can happen at the same time). The double-tap window is 150ms (`windowReverseTapWindow`, shortened twice from the initial 300ms → 200ms → 150ms: 300ms misjudged the natural pause of "press once, glance at the result, press again to expand" as a double-tap; 200ms still had a few boundary cases; 150ms compresses the window to just above the "deliberately fast double-tap" comfort zone of 80-130ms while excluding the entire "glance then press" natural-pause zone of 250ms+). The second press must be held ("double-tap + hold"; releasing the second only shrinks one step).

**HUD**: shows `WINDOW` on entering the mode.

**Why a chord rather than bare `w`**: `w` is in the hint letter pool (`a s d f g e r u i o p w t n m c v`, see §4). Using a chord trigger keeps bare `w` usable as a hint label. It's also consistent with SCROLL's `Caps Lock + d`.

**Why no fallback synthesized edge-drag path is kept**: the prototype originally had a fallback—when AX isn't writable, synthesize `mouseDown` at the window border's midpoint / corner and synthesize `.leftMouseDragged` each tick to push the cursor. Hitting cases like Finder Desktop ("a window in AX, but actually not a user window"), the HUD marked `WINDOW · synth-drag`, but the fallback had no effect on the Desktop either (no resize handle for OS hit-test), becoming confusing UX. After adding the title bar button gate, almost every window that passes the gate allows AX writes—the fallback's complexity is no longer worth it, removed.

**Implementation notes**:
- Trigger: pressing `w` during `HotkeyTap` F19 arm → `session.enterWindowMode()`, mimicking `Caps Lock + d → enterScroll`.
- Focused-window resolution: `AXWindowOps.frontmostWindow()` follows the chain of `ScreenCapture.focusedWindow()` (`AXFocusedWindow` → `AXMainWindow` → `AXWindows[0]`).
- Edge math: `top` expand conceptually = `AXPosition.y -= step, AXSize.height += step`; `bottom` expand = `AXSize.height += step`; left/right are symmetric. shrink flips the sign—each edge's sign is independently decided by `WindowController.reversedEdges`.
- **Write order: anchored grow goes position-first, everything else goes size-first**. AX can only write one attribute at a time (unlike NSWindow's resize handle, which is atomic), and the intermediate state can be rejected by the app.

  *Anchored grow* (top/left expand: `k` / `h` / `kh` / `kl` / `jh`…) goes through `tickPositionFirst`: first `writePosition` to move the origin to the target position → read back the origin the OS actually allowed (the menu bar clamps y, the left screen edge clamps x) → compute the final size from the **actual** displacement + the non-anchored edges' size contribution → `writeSize`.

  *Other cases* (anchored shrink, pure bottom/right, pure pan) go through `tickSizeFirst`: first `writeSize` → read back → move the origin proportionally by actualΔ → readback → reverse clamp trim (when the origin is held by the OS, reclaim some of the size to keep the opposite edge fixed).

  Gotcha: early on it was uniformly size-first, and an app like WeChat with a "right ≤ X" constraint rejected writeSize on an `h` expand (expanding left = top origin unchanged, size widened)—because the intermediate state "old origin + new bigger size" would push the right edge past X. After changing the anchored-grow path to position-first so the origin is in place first, the right edge actually doesn't move when size is written, and the app accepts it. Dragging a window with the mouse can stretch endlessly because NSWindow.resize is atomic; AX writes can't be atomic, so the write order has to work around it.

- **Contribution tracking**: an anchored edge's (top/left) origin move should respond only to **its own share** of the size contribution, not the whole axis's sizeΔ. `topContribution` / `leftContribution` are maintained separately from `sizeDelta`—when `k+j` are pressed together, top contribution = +step, bottom contribution = +step, the whole sizeΔ.height = +2×step; origin.y should only -= step (the top's share), not -= 2×step. An early version used a `topActive: Bool` flag + `actualHDelta` to compute the origin move, and `k+j` would become "top up 2×step, bottom unmoved", a bug.
- **Clamp suppression**: if an anchored edge's origin got clamped by the OS last tick (partial move), it's cached to `clampedOriginY / clampedOriginX`; next tick this edge is simply skipped, participating in neither sizeΔ nor contribution. Otherwise it would repeatedly "write origin → OS clamp → write size grows out → visually the opposite edge drifts". On `stopEdge` (keyUp) the cache is cleared so the user can re-press to retry.
- **Chained misjudgment after a double-tap reverse**: pressing h again within 100ms after releasing hh (double-tap shrink), the original `now - lastKeyUp < 150ms` judges it as a double-tap again = reverse again = still shrinking, and the user feels "h is broken". Fix: on `stopEdge`, if the current state is reversed, clear `lastWindowEdgeKeyUp[edge]` to nil instead of refreshing it to now—the next h press gets no previous timestamp and goes through the "first time" logic (grow).
- Double-tap detection: `VimSession.lastWindowEdgeKeyUp[edge]` stores the `CFAbsoluteTimeGetCurrent()` timestamp of each edge's last keyUp. On the next same-key keyDown, `now - last < 0.15` → this hold is marked reversed, passed to `controller.startEdge(edge, reversed: true)`. OS key-repeat doesn't mis-trigger it (key-repeat doesn't emit keyUp, so the timestamp doesn't update). On exiting WINDOW mode, `lastWindowEdgeKeyUp` is cleared to prevent reading a stale timestamp on the next entry.
- Speed: bare = 20pt/tick, Shift = 80pt/tick (fast), Option = 5pt/tick (slow), Option > Shift priority (same as `MouseMover.moveSpeed`).
- A soft min size of 200×120 prevents the in-memory rect from drifting too far from the actual drag (the app clamps too).

---

## 8. WINDOW MOVE mode key bindings

Whole-window pan (no resize). It's **two independent modes** with WINDOW resize—one moves `AXPosition`, the other moves `AXPosition + AXSize`—and mixing them would instead require hanging extra modifiers on hjkl; keeping them separate is cleaner.

`WindowMoveController` mirrors the `WindowController` structure: a direction set + a 60fps timer + writing `AXPosition` each tick (**writes only position**, single IPC, one fewer IPC than `writeRect`).

| Key | Behavior |
| --- | --- |
| **Enter: `Caps Lock + m` chord** (any mode) | two gates: `hasTitleBarButton` (same as WINDOW resize) + `isMovable` (only checks that `AXPosition` is writable, looser than `isResizable`—move doesn't touch size) |
| `h / j / k / l` (held) | pan the window in the corresponding direction (h=left / j=down / k=up / l=right, the same hjkl direction encoding as cursor / SCROLL / WINDOW resize) |
| `Shift + hjkl` | **fast** (80pt/tick, 4×) —— fast cross-screen move |
| `Option + hjkl` | **slow** (5pt/tick) —— fine alignment to another window/screen edge |
| `Shift + Option + hjkl` | **Option wins → slow** (same priority as `MouseMover.moveSpeed`: a mis-pressed Shift+Option leans toward "slow" rather than "fast") |
| simultaneous (e.g. `h+j`) | diagonal pan (down-left), the two axes' deltas stack independently |
| conflicting pair (`h+l` or `j+k`) | naturally cancel (dx or dy sums to 0, the window doesn't move) |
| `Esc` | exit OFF |
| Other keys | swallowed |
| `Caps Lock` (single click / + d / + w / + m chord) | immediately switch to the corresponding mode. `teardownCurrentMode` first stops the timer + closes the overlay before switching |

**Visual**: shares `WindowOpOverlay` with WINDOW resize, but here `show(rect:withChips:)` passes `false`—**the blue border is still drawn, the 4 edge chips are not**. The reason: resize's chips (`↑k / ↓j / ←h / →l`) imply "push this border that way", an edge-bound semantics; in move, hjkl are directions, not edge-bound, and hanging the same chips would instead make people think it's resize. The border + the HUD `MOVE` label are enough, and the hjkl directions are consistent with other modes so there's no need to relearn each time.

**HUD**: shows `MOVE` on entering the mode.

**Why a chord rather than bare `m`**: `m` is in the hint letter pool (`a s d f g e r u i o p w t n m c v`, see §4). A chord trigger keeps bare `m` as a hint label. It's also consistent with SCROLL's `Caps Lock + d` / WINDOW resize's `Caps Lock + w`.

**Implementation notes**:
- Trigger: pressing `m` during `HotkeyTap` F19 arm → `session.enterWindowMove()`.
- `AXWindowOps` adds `isMovable` (only probes `AXPosition` settable) + `writePosition` (single IPC, writes only origin).
- Controller: `WindowMoveController.swift`, ~70 lines. `enum Direction { left, right, up, down }` + `Set<Direction>` tracks the held directions. The tick adds the step per axis independently to compute `dx, dy`.
- Mode mutual exclusion: while in MOVE, other mode triggers (`enterWindowMode` / `enterScroll` / `enterDrag` / `handleTriggerTap`) are all guarded out, you must Esc first.

---

## 9. Command palette key bindings

| Key | Behavior |
| --- | --- |
| letter a–z | append to buffer |
| `Backspace` on non-empty | delete one character |
| `Backspace` on empty | close the palette, return to the underlying mode |
| Caps Lock (bare) | close the palette, return to the underlying mode (equivalent to empty buffer + Backspace) |
| `Return` | execute the command |
| `Esc` | deactivate Keyway (back to OFF, the process is still in the menu bar) |

Note the palette **only accepts letters** (`letterChar(for:)` explicitly lists only a–z). Digits / symbols are ignored. The reason: all current and future commands are
short letter strings (`st`, `dr`), to make the user think less about "is this key a command".

### Current commands

| Command | Behavior |
| --- | --- |
| any currently-unimplemented letter combination | buffer is cleared, **the palette stays open**, letting the user keep typing |

There is deliberately **no `:q` command**—Esc already deactivates, and quitting the process is a menu bar behavior, a different matter from the command palette inside hint mode (see the three levels in §3.1). Putting "quit process" into the palette would blur the line between "deactivate vs quit".

Future modes are wired in via `executeCommand`:
```swift
case "st": switchTo(.selectText(...))
```

(No `dr` command needed—DRAG has been folded into a TAP sub-state, entered with bare `v`; the palette no longer keeps an opening for sub-states.)

---

## 10. KeyCode constants

Those in `KeyCode.swift` are `kVK_ANSI_*`, **physical key positions**. On Dvorak / international keyboards the letter positions will be wrong.
Migration path: use `UCKeyTranslate` or `CGEventKeyboardGetUnicodeString` to turn keyCode + flags → a character and then match.
The TODO is already left in the header comment of `KeyCode.swift`.

Main constants:

| Name | Code | Description |
| --- | --- | --- |
| `f19` | 80 | **the trigger key**—physical Caps Lock arrives here after being remapped via hidutil |
| `grave` | 50 | `` ` `` / `~` —— a reserved constant, currently not used as a trigger |
| `escape` | 53 | the exit key |
| `semicolon` | 41 | `;` —— after Shift it's `:`, opens the palette |
| `quote` | 39 | `'` —— in TAP normal toggles move-only arm (see §4.3.5) |
| `return` | 36 | execute the command |
| `delete` | 51 | Backspace |
| `tab` | 48 | unused for now |
| `space` | 49 | unused for now |
| `a..l` | 0,1,2,3,5,4,38,40,37 | the 9 home row keys (note the g/h order: g=5, h=4); `h/j/k/l` = hjkl cursor move, `a s d f g` = hint letters |
| `i` | 34 | hint letter (top row, not home row) |
| `q..p` | 12,13,14,15,17,16,32,34,31,35 | top row (`e r u i o p w t` now serve as hint letters) |
| `z..m` | 6,7,8,9,11,45,46 | bottom row (`c=8 n=45 m=46` now serve as hint letters) |
| `1..0` | 18,19,20,21,23,22,26,28,25,29 | digits (note 5=23, 6=22; 7=26, 9=25) |
| `arrow*` | 123–126 | left/right/down/up, for a future select-text mode |

**Key usage quick reference** (TAP mode): `h/j/k/l` = hjkl cursor move; hint letters = `a s d f g e r u i w t n m` (13, excluding hjkl/v/c/o/p); `v` = bare to enter the DRAG sub-state; `c` = bare click (`cc` double-click / `Shift+c` right-click); `/` = bare to enter the search sub-state; `Enter` = pass through to the app; digits = Dock hint / SCROLL area switch.

---

## 11. Modifier key strategy summary

| Key / modifier | Behavior in any mode | Why |
| --- | --- | --- |
| `Cmd` | the whole event passes through | preserves Spotlight / Cmd+Tab / screenshot / close window, etc. |
| `Ctrl` | the whole event passes through | preserves Mission Control / Ctrl+↑, etc.; also because power users use Ctrl+hjkl as arrow keys |
| `↑ / ↓ / ← / →` (any mode, any modifier combination) | the whole event passes through | Keyway uses hjkl for its own cursor / scroll / window move; the arrow keys yield to the focused app's native navigation (scroll a list, move the text caret, walk a menu, etc.). If not passed through, you couldn't page through with the arrow keys in sticky TAP |
| `Enter` (TAP normal / SCROLL) | the whole event passes through | Enter often has its own semantics inside an app—confirm a menu, submit a form, decide an option. Combined with the arrow-key pass-through above, it forms the complete loop of "↑↓ nav a menu + Enter to select". The original Enter-click function moved to bare `c` (see §4 / §5). The dragging sub-state / search-typing / palette still use Enter internally (drop / kickoff OCR / execute), and those scenarios don't conflict with the app's Enter semantics |
| `Shift` | consumed —— hint last character / `c` = **right-click** (held); cursor-move keys (hjkl) = accelerate; hjkl double-tap = jump a whole screen (otherwise 1/2). **Double-click clicking doesn't rely on Shift**, it's uniformly `cc` (§4.4) | Shift subconsciously = "another kind of click" = right-click; double-click is given to the independent `cc` gesture |
| `Option` | consumed —— **click actions no longer use Option** (freed up for other uses); only the cursor-move keys = fine slow speed | the old "Option = right-click" is abolished (not comfortable enough); cursor move isn't a hint letter, no conflict |
| `'` (TAP normal) | consumed —— toggle move-only arm (the next hint pick warps the cursor without clicking, see §4.3.5) | Cmd/Ctrl conflict with the system, Shift/Option are taken, and `'` is a lightweight non-modifier prefix |

Pass-through vs consume is decided at the top of `VimSession.handle()`: first `flags.intersection([.maskCommand, .maskControl]).isEmpty` rules out system shortcuts, then independently checks once whether the keyCode is an arrow key (any modifier combination passes through). hjkl movement additionally requires no Cmd/Ctrl/Option (only Shift to accelerate is allowed).

---

## 12. New mode wiring path

The minimal changes to add a new mode (e.g. select-text):

1. **Add a case to the `Mode` enum**: `case selectText(SelectTextMode)`.
2. **Add a branch to the `handleMode` switch**: dispatch to `handleSelectText(...)`.
3. **Write the `SelectTextMode` class**: mimic `HintMode`'s `activate / deactivate / handle` interface.
4. **Wire the command into `executeCommand`**: `case "st": switchTo(.selectText(SelectTextMode()))`.
5. **A mode-switch function** (if not already present):
   ```swift
   private func switchTo(_ newMode: Mode) {
       if case .tap(let h) = self.mode { h.deactivate() }
       self.mode = newMode
       paletteBuffer = nil
       renderModeHUD()
   }
   ```
6. **HUD text**: add a branch to the `renderModeHUD` switch.

The palette needs no changes, because it's orthogonal to mode.
