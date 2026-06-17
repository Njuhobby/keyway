# Browser Support — Chrome / Firefox / Safari Extension + Native Messaging

**Status** (2026-06):

| Phase | Status |
|---|---|
| P0 install PoC | ✅ |
| P1 communication skeleton (BridgeServer / mouseless-bridge CLI / extension long-lived connection) | ✅ |
| P2-A detector (Vimium rule rewrite) | ✅ |
| P2-B iframe cross-frame coordination (postMessage chain) | ✅ |
| P3 `BrowserProvider` wired into HintMode | ✅ |
| P4 async-load `page_changed` triggers in-place rehint (leading+trailing throttle) | ✅ |
| Incremental patch: multi-profile / multi-browser `i_am_active` routing | ✅ |
| Incremental patch: `tab_changed` signal for switching tabs in the same window | ✅ |
| Incremental patch: SW-startup auto-inject of already-open tabs | ✅ |
| Incremental patch: navigation_complete signal (`tabs.onUpdated status=complete`) | ✅ |
| Incremental patch: anchor link commit skips the 100ms post-commit rehint | ✅ |
| Incremental patch: `/`-search in the browser uses DOM TreeWalker instead of OCR | ✅ |
| Incremental patch: app-switch cursor park in the browser uses DOM (`document.activeElement` / first visible input) | ✅ |
| P5 Safari Web Extension + store submission | ⏳ not started |

On Chrome it is **already feature-complete enough to daily-drive**. Safari waits for P5.

Detailed commit chain: `fb2ccde` (P0) → `130297e` (P1.1) → `f08a775` (P1.2) → `3c62077` (P1.3) → `a89caee` (P2-A) → `01a5fa8` (P2-B) → `59d4f54` (P3) → `fd7efa6` (P4) → `afd41bc` (multi-route) → `374ea21` (browser path autonomy) → `0413c85` (auto-inject) → `76dd2a3` (tab_changed) → `ebcb371` (navigation_complete) → `8df297b` (anchor skip 100ms rehint) → `d68a7d5` (DOM /-search) → `1df5c64` (DOM cursor park) → `a614792` (page_changed leading+trailing throttle, fixes rapid tab switching).

---

## 1. Why do this

Mouseless's product thesis is *"press Caps Lock, one mental model across all apps"*—sticky / shift acceleration / hjkl cursor movement / drag / future new modes… all inside one unified interaction model. The moment we say "for the browser, please use Vimium", that thesis immediately collapses:

- **Sticky is unavailable in the browser**—Vimium is a one-shot hint-jump-press-exit flow
- **shift-accelerated scrolling / hjkl cursor drag / DRAG**—mouseEvents dispatched by browser JS aren't real mouse events, so they can't do this. Mouseless uses OS-level `CGEvent` to actually "drag a Figma element / a Google Maps canvas"
- **Future new modes follow automatically**—every time we add a mode we shouldn't have to answer "so what about inside the browser"

**Current state**: neither Chrome nor Safari is in `AppRegistry.AX_FOCUSED_WHITELIST`, so they go through OP (ScreenCaptureKit + YOLO + OCR refiner). Pain points:

- Clickable things on a page aren't just text buttons—many link icons, `<div onclick>`, `[role=button]`, pseudo-buttons rendered by SPA frameworks—the OP visual path has low coverage
- Elements below a collapsed region aren't rendered, so OP can't see them (they're in the DOM)
- The ARIA hygiene of frameworks like React/Vue is uneven, and force-enabling the AX tree (`--force-renderer-accessibility`) doesn't solve the problem either

**`/`-search is already a partial workaround**—users can "click whatever the OCR can see"; it's good enough for plain text links, but not for icon-only buttons / complex SPAs.

---

## 2. Architecture

```
            ┌─────────────────────────────────┐
            │  Chrome / Safari                │
            │  ┌───────────────────────────┐  │
            │  │ Mouseless extension       │  │   JS, runs in the browser sandbox
            │  │  - background.js (SW)     │  │
            │  │  - content_script.js      │  │   per tab / iframe
            │  │  - detector (from Vimium) │  │   ← MIT, core module extracted
            │  └────────┬──────────────────┘  │
            └───────────│─────────────────────┘
                        │ chrome.runtime.connectNative()
                        │ stdin/stdout, length-prefixed JSON
            ┌───────────▼─────────────────────┐
            │ Native Messaging Host           │   Swift CLI binary
            │ (mouseless-bridge)              │   spawned by the browser,
            │                                 │   lifecycle owned by the browser
            └───────────┬─────────────────────┘
                        │ Unix domain socket
                        │ ~/Library/Application Support/Mouseless/bridge.sock
            ┌───────────▼─────────────────────┐
            │ Mouseless main process          │   existing Swift app
            │  - BrowserProvider             │   new: a third hint source alongside
            │  - reuses existing HintMode / Overlay │   AXProvider / OPProvider
            └─────────────────────────────────┘
```

**Responsibility split across the three processes**:

| Process | Responsibility |
|---|---|
| **Extension (per tab)** | Detect clickable elements in the current viewport + assign stable IDs to elements + receive the main process's "click ID=X" command + proactively invalidate on scroll / DOM changes |
| **bridge host** | Bidirectional forward between stdio ↔ Unix socket; auto-launched after the user launches the browser; the process is very lightweight (≈200 LOC Swift) |
| **Mouseless main process** | Detects that the frontmost is Chrome/Safari → goes through BrowserProvider instead of OP; renders the received hint list with the existing `HintOverlay`; after commit tells the extension which ID to click |

---

## 3. Protocol

```jsonc
// Mouseless → extension
{ "cmd": "list_hints",
  "viewport_only": true,           // only the currently visible, to avoid masses of hidden nodes in SPAs
  "include_text": true             // let /-search match against hint text
}

// extension → Mouseless
{ "type": "hints",
  "tab_id": 12,
  "main_frame_rect": { "x": 0, "y": 0, "w": 1440, "h": 800 },   // in the screen coordinate system
  "hints": [
    { "id": "h1", "rect": { "x":120,"y":340,"w":40,"h":20 }, "text": "Sign in", "kind": "link" },
    { "id": "h2", "rect": { "x":200,"y":340,"w":80,"h":20 }, "text": "Sign up", "kind": "button" },
    ...
  ]
}

// Mouseless → extension (commit)
{ "cmd": "activate", "tab_id": 12, "id": "h2", "modifier": "none" }   // none / shift / option
// or:
{ "cmd": "activate_at_cursor" }                                       // CGEvent click already sent, extension does nothing

// extension → Mouseless (DOM changed, proactively invalidate the current hint set)
{ "type": "invalidate", "tab_id": 12, "reason": "scroll" }
```

**Coordinate system**: the rects returned by the extension are already in **macOS screen global coordinates** (top-left origin), computed via `window.screenX/Y + window.devicePixelRatio + el.getBoundingClientRect()`. The Mouseless side receives them without any further transform and feeds them straight to `HintOverlay`.

**Two click-commit paths**:

- Default `activate_at_cursor` — Mouseless has already warped the cursor to the hint center and synthesized a `CGEvent` click. **Using a real mouse event has big upsides**: browsers, `<canvas>`, Flash-likes, and complex SPAs all respond correctly.
- Optional `activate` — let the extension trigger via DOM `.click()`. Used as a fallback in the few cases where the element is outside the viewport but exists in the DOM, or where a real mouse click is stop-propagation'd.

---

## 4. Vimium borrowing checklist

Vimium is **MIT-licensed**, allows commercial use, and requires attribution + keeping the LICENSE.

What we copy is its core: the **hint detection logic inside the content script**—the corner-case handling stomped out over 12 years of iteration is the most valuable part:

| Vimium module | What we use it for | Difficulty |
|---|---|---|
| The clickable selectors in `link_hints.coffee` | Decide which elements are worth hinting | Medium — edge selectors accumulated over years |
| The visibility / occlusion checks in `dom_utils.coffee` | Rule out `visibility:hidden`, `opacity:0`, things occluded by higher z-index | **High** — Vimium's most valuable part |
| Cross-origin iframe coordination | The main frame + each iframe has its own content script; they must coordinate into one hint list | High |
| Shadow DOM traversal | Enumerate visible elements inside a Web Component's shadow root | Medium — but increasingly common |
| scrollable ancestor detection | When j/k scrolling, find the nearest scrollable container (not just window) | Medium — used by SCROLL mode |

What we **don't** use:

- Hint label rendering (it injects `<div>`s into the page; we let Mouseless's `HintOverlay` draw)
- The modal key state machine (Mouseless has its own mode system)
- Browser commands (H back / t new tab / x close—these go through OS browser shortcuts)
- Options UI / help dialog

**License handling**:

- Keep the Vimium copyright header + MIT text at the top of the copied files
- Note in our extension `README.md`: "Hint detection adapted from Vimium (https://github.com/philc/vimium), MIT License"
- Doesn't require our entire project to be open-source, doesn't require contributing changes back

---

## 5. Implementation roadmap (P0 → P5)

### P0 — Proof of concept (half a day) ✅

Minimal demoable: hardcode a single selector (`a, button`) and, on one fixed Chrome test page (e.g. https://github.com):

1. Write a minimal manifest + content script that console.logs the list of clickable elements
2. Don't connect to Mouseless; the goal is only to verify the step "get clickable elements + coordinates inside the browser" works

**Acceptance**: N `{rect, text}` JSON entries printed in the console.

### P1 — Native Messaging Host + protocol stub (1-2 days) ✅

1. Write the `mouseless-bridge` Swift CLI (~200 LOC): read length-prefixed JSON from stdin + write length-prefixed JSON to stdout
2. The Mouseless main process opens a Unix socket listener, and bridge echoes messages back and forth with it
3. Register the host manifest at `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.mouseless.bridge.json`
4. The extension background script does `chrome.runtime.connectNative('com.mouseless.bridge')`, sends a ping, and the main process echoes it back

**Acceptance**: pressing a button in the extension produces a message visible in the Mouseless main-process log, and the reply travels back to the extension and shows in the console.

### P2 — Detection module (2-3 days)

#### P2-A detector rule rewrite ✅

**Deviation from the original plan**: the original plan was "fork Vimium, extract the module"; in reality it became a **rule rewrite based on borrowed knowledge**—Vimium's `LocalHints` depends heavily on 6 Vimium-internal globals (Settings / Utils / DomUtils / Rect / HUD / HintCoordinator), and stubbing them out is more trouble than rewriting. We instead lifted Vimium's factual know-how (selector lists, ARIA roles, jsaction rules, visibility checks, 5-point occlusion probing, shadow DOM recursion) and cleanly rewrote it in `detector.js`. On the license front we keep `vendor/vimium/MIT-LICENSE.txt` + `NOTICE.md` attribution.

#### P2-B iframe coordination ✅

**Deviation from the original plan**: the original plan mentioned "path 1 (recommended) using `chrome.scripting.executeScript({allFrames: true})`" and "path 2 (the Vimium way) the postMessage chain". **In reality we chose the path-2 style**—iframe coordination uses `window.postMessage` to recursively request/respond across the frame tree. Reasons:

- No need to add a new `scripting` permission (at the time)
- Each frame reports its own hints independently, and the parent frame computes "parent origin + iframe.getBoundingClientRect" to give the child frame as its viewport origin → nested iframes recurse for free
- Fewer cross-origin restrictions than `executeScript`

Message types between frames:
- `mouseless_hints_request {id, origin}` → parent asks child to collect
- `mouseless_hints_response {id, hints}` → child returns (hint list in screen coordinates)
- `mouseless_page_changed_inner` → child bubbles up to parent "I have new clickable elements here"
- 250ms timeout fallback (sandboxed / chrome:// iframes don't respond)

### P3 — Mouseless-side BrowserProvider + Overlay rendering (1-2 days) ✅

Implementation points:

- New file `Sources/Mouseless/BrowserProvider.swift`
- `HintSource` gains a new `case .browser` (on commit it shares the same `MouseSynth.click` center-click path as `.ax`, and the browser's own hit-test handles routing automatically)
- `HintMode.collectAll` takes the BrowserProvider branch when `AppRegistry.isBrowserApp(bundleID:)`
- `BridgeServer.sendToActive` writes to the socket → bridge forwards to stdio → extension SW → content_script → detector → flows back in reverse; the Mouseless side waits async with `awaitResponse(ofType:"hints", timeout:0.4)`
- **Deviation from the original plan**: a `fetchHints` timeout does not return nil → fallback OP, but accepts `[]` directly. See §7 "browser path autonomy"

### P3.5 — Multi-profile / multi-browser routing (incremental) ✅

The original plan didn't account for multiple extension clients being connected at the same moment. The actual scenario is common: a user has Chrome Profile A + Profile B open at once (each profile is an independent extension install = independent SW = independent bridge process = independent socket connection to Mouseless).

Getting it wrong is ugly: the user presses Caps Lock in Profile A, Mouseless sends list_hints to the most-recently-connected fd (possibly Profile B), Profile B returns the hints of its own active tab, and they get drawn over Profile A.

**Fix**:

- On the extension side, `chrome.windows.onFocusChanged` listens → the SW sends `{type: "i_am_active"}` to Mouseless. On SW startup it also proactively probes once with `chrome.windows.getLastFocused` (startup-race fallback).
- `BridgeServer.activeFD` is no longer set on accept, but **only switches when an `i_am_active` arrives**.
- The ping carries a `browser` identity field (`"chrome"/"edge"/"brave"/"safari"/...` inferred from the UA).
- `sendToActive(_, expectingBrowserBundleID:)` matches the current frontmost bundleID against the active fd's identity — refuses on mismatch (to avoid "Safari is frontmost but only the Chrome extension is online, so list_hints gets sent to the Chrome bridge, returns Chrome's hints, and draws them over Safari").

### P4 — Async-load-aware hint refresh ✅

**Deviation from the original plan**: the original plan's "scroll / DOM mutation invalidation" scope was too broad. In reality we **cut scroll invalidation**—in Mouseless UX, scrolling must enter SCROLL mode, so the scenario "scrolling during sticky TAP → hints drift to wrong positions" never arises. We **kept DOM mutation**, because that's a daily-use pain point Vimium also never solved (the page is still lazy-loading when the user enters TAP, hints are incomplete; fill them in a few seconds later).

Mechanism:

- **Extension side**: each frame's content_script installs a `MutationObserver`. On "new clickable" the top frame directly `chrome.runtime.sendMessage`s the SW; an iframe uses `mouseless_page_changed_inner` postMessage to the parent, which recursively relays up to the top frame before it goes out.
  - **The extension side throttles too (leading+trailing, 500ms)**: originally the callback used a selector to early-return and filter out mutations with "no new clickable", but a **YouTube video that's actively playing** is the kind of page that **constantly adds/removes clickable elements** (recommendations / player controls), so `hasNewClickable` frequently returns true → dozens of `sendMessage` per second, which both floods the bridge and pins the content script's **main thread**, causing `list_hints` to fail to return within Mouseless's 400ms budget (→ 0 web hints). So the throttle is moved to the very **start** of the observer callback: inside the cooldown window it **returns directly**, skipping even `hasNewClickable` (which is `querySelector`, the part that actually burns the main thread), and only queues one trailing fallback. Key: `lastFireAt` only advances when something was **actually fired** (leading detected a real clickable / trailing), so a page that "keeps changing but never adds clickable elements" never enters the skip branch and never fires spuriously. This layer is complementary to the Mouseless-side throttle—the extension side treats the source (main-thread overload + bridge flooding), the Mouseless side treats "don't over-rescan + multi-source merge (plus iframe / `navigation_complete` / `tab_changed`) + final-state fallback".
- **Mouseless side**: the BridgeServer handler routes `{type: "page_changed"}` → `VimSession.handlePageChanged` → **leading+trailing throttle (500ms)** + 4 gates: in TAP + frontmost is browser + `tapSub == .normal` (not in drag/search sub-state) + `typed` prefix is empty (don't interrupt the user picking a label). All pass → `HintMode.refreshInPlace` — **no deactivate + no hide + no re-activate**, just `applyCollected` re-fetches hints + `HintOverlay.show(targets: new, typed: typed)` replaces targets in place, **zero flicker**.
  - **Why the throttle is leading+trailing rather than pure leading**: pure leading (drop all events within the window) goes wrong for "rapid tab switching" — tab1→tab2→tab3→tab4 in quick succession, the first fire refreshes to tab2, the rest get dropped by cooldown, and the overlay stays on tab2 while the user is on tab4. Switching to leading+trailing: outside the window refresh immediately (leading, preserving streaming timeliness), inside the window queue **one** trailing at the window's end to refresh once more and read the THEN-current tab (final state wins). The frequency ceiling is still nailed down by the 500ms cooldown (trailing doesn't increase frequency, it only fills in the final state), so the goal of preventing Gmail/Slack DOM blowouts only gains, never loses. `performPageChangedRefresh` **re-runs the 4 gates** at actual execution time (state may have changed between scheduling and firing the trailing), so a stale fire is a safe no-op. `pendingPageChangedTrailing` is cancelled in `exit()`.
- **HintMode refactor**: the "label assignment + targets writeback" inside the original `activate` is extracted into a shared `applyCollected(_:)`; both `activate` and the newly added `refreshInPlace(isolateApp:)` go through it. The former clears `typed` + sets `isActiveFlag = true` on first entry; the latter preserves both.

### P4.5 — `tab_changed` for switching tabs in the same window (incremental) ✅

P4 solved "DOM changes within the same tab", but **switching tabs within the same window** (Cmd+1/2/3 / clicking the tab strip / Cmd+\[\] navigation) is another blind spot:

- NSWorkspace.didActivateApplication: doesn't fire (same app)
- activeSpaceDidChange: doesn't fire
- the 150ms `focusedWindowPoll`: AXFocusedWindow is still the same NSWindow → doesn't trigger
- chrome.windows.onFocusChanged: doesn't fire (the window didn't change)
- content_script MutationObserver: usually doesn't fire (tab switching is a visibility switch, the DOM didn't really change)

**Fix**: extension-side `chrome.tabs.onActivated` listener; filter "is this a tab switch within this profile's current focused window"; send `{type: "tab_changed"}` to Mouseless. On the Mouseless side the handler routes `tab_changed` through the same path as `page_changed` (reuses `handlePageChanged()`, UX behavior identical).

### P4.6 — SW-startup auto-inject of already-open tabs (incremental) ✅

The #1 footgun of Chrome extension development: **reloading an extension does not re-inject into already-open tabs**—the manifest's `content_scripts` only inject after a tab navigation. A pre-existing tab has no content script (or an old version), and bg's `tabs.sendMessage` fails with `Receiving end does not exist`.

**Fix**: add `"scripting"` permission + `"host_permissions": ["<all_urls>"]` to the extension manifest. When the SW connects to the native bridge it iterates all tabs and calls `chrome.scripting.executeScript({target: {tabId, allFrames: true}, files: ["detector.js", "content_script.js"]})`. Tabs that don't allow injection (chrome:// / Web Store / etc.) naturally reject (catch + counted as skipped, not an error). Dev iteration no longer requires refreshing every tab on each reload.

### P4.7 — `navigation_complete` signal (incremental) ✅

P4's MutationObserver only watches "clickables newly added to the DOM", but when the **user clicks a link triggering a full-page navigation**, the new page's initial DOM is rendered all at once rather than added incrementally, so the MutationObserver can't fire. At the same time, sticky's 100ms post-commit rehint lands in the middle of navigation, the content script isn't yet injected on the new DOM → receives `content_script_unavailable` → shows 0 web hints.

**Fix**: extension-side `chrome.tabs.onUpdated` listens for `changeInfo.status === "complete"` (page load finished), filters "the active tab of the focused window", and sends `{type: "page_changed", reason: "navigation_complete", url, tabId}` to Mouseless. On the Mouseless side it goes through the ready-made `handlePageChanged` path. The `reason` field is purely for debugging, the handler doesn't distinguish (same 4 gates + refreshInPlace).

### P4.8 — Anchor link commit skips the 100ms post-commit rehint (incremental) ✅

Following on from P4.7: even with the navigation_complete notification added, that 100ms rehint still hits content_script_unavailable **first** and replaces the overlay with an intermediate "only Dock + menubar, 65 hints left" state; the user sees a weird "only the Dock is left" window for a moment before the new page's hints cover it a few hundred milliseconds later. Just **skip this rehint**—simply don't let it run into that failure state.

**Fix is split across extension side + Mouseless side**:

- `detector.js` gives each hint an extra `nav: bool` field. `isLikelyNavigating(el)` decides: tag === "a", href non-empty and not starting with `#`, not starting with `javascript:`, target ≠ `_blank`
- `BrowserProvider.Hint` gains `navigates: Bool`; `HintSource.browser` becomes `case browser(navigates: Bool)` to carry it
- `HintMode` tracks `lastCommittedTarget` (survives `deactivate`), so VimSession can query it after dispatching `.committed`
- `VimSession` in the sticky `.committed` path: `if case .browser(true) = lastCommittedTarget.source` → skip `scheduleStickyRehint`. The page_changed from tabs.onUpdated completion takes over the redraw

**Not affected**: non-anchor browser hints (button / role=button / div+onclick etc.), AX hints, OP hints — these still go through the 100ms rehint after commit (the same-page DOM-change scenario needs it). Same-page `#section` anchors, `javascript:` URLs, `target=_blank` also go through the 100ms rehint (these don't **really** navigate).

### P4.9 — `/`-search in the browser uses DOM (incremental) ✅

`/`-search in the browser also always went through Vision OCR + ScreenCaptureKit (80-200ms, and OCR occasionally misreads)—the extension is already there, the DOM text is trivially available, no reason not to use it.

**Implementation**:

- `detector.js` adds `findTextMatches(query, opts)`: a TreeWalker walks the text nodes of `document.body`, with NodeFilter early-filtering out those that don't contain the needle / `<script>`, `<style>`, `<noscript>` / `display:none` / `visibility:hidden`. Each match uses `Range.getClientRects()` to get the in-viewport rect (multi-line wraps automatically produce one match per line). Out-of-viewport ones aren't returned (aligning with OCR behavior—OCR also only sees on-screen content).
- iframe coordination: a **mirror** of the hints path—`mouseless_text_request` / `mouseless_text_response` (id, query, origin), 250ms timeout, off-viewport iframes culled the same way.
- bg's `find_text` command routes to the active tab's top frame just like `list_hints`, and the response `{type:"text_matches", matches:[{rect, text}], ms, query, url}` goes back to native.
- `BrowserProvider.findText(query:timeout:)` is the Swift-side wrapper + a `BrowserProvider.TextMatch` struct (rect + text).
- `VimSession.kickoffSearch` is split into a router → `kickoffSearchViaBrowser` / `kickoffSearchViaOCR`. When the frontmost is a browser it takes the former; others (including a browser whose extension is unreachable) go OCR. **Note: the browser-path-autonomy principle is preserved—OCR is not a fallback, it's an independent path for a different app type**.

**Performance** ~5-20ms (a typical GitHub PR page ~5ms) vs OCR ~80-200ms, ~10× faster + 100% accurate.

**Known trade-off**: the browser chrome's text (URL bar / tab titles) isn't in the DOM, so `/`-search in the browser can't find URLs / tab titles. Acceptable—these have their own shortcuts (Cmd+L to enter the URL bar, etc.).

### P4.10 — App-switch cursor park in the browser uses DOM (incremental) ✅

After an app switch the cursor warps by default to the midpoint of the focused window's title bar. Changing it to "if the focused window has an input, land inside that input" is a detail that makes Mouseless smoother to daily-drive.

**Native AX path** (regular native apps + AX-good Electron exceptions like WeChat): read `AXFocusedUIElement`, the role is in the whitelist (AXTextField / AXTextArea / AXSearchField / AXComboBox) or `AXValue` is writable (covering Electron-class editable elements that return weird roles), the rect intersects the window + is at least 4×4. See `modes.md` §4.3.

**Browser path** (Chrome-class): AX is untrustworthy (renderer accessibility off by default), so go through the DOM—

- `detector.js` adds `findFirstInput(opts)`: first check whether `document.activeElement` is a text-class input (INPUT excluding hidden/button/submit/checkbox/radio/image/file/color/range; TEXTAREA; contenteditable)—that's what the user last actively focused, a strong signal; fall back to the first visible input/textarea/contenteditable in document order.
- bg's `find_first_input` command routing reuses the list_hints / find_text active-tab resolution; the response `{type:"first_input", rect|null, source}` goes back to native, with source marked `activeElement` / `first_visible` / null.
- `BrowserProvider.findFirstInputRect(timeout:0.3)` is the Swift-side wrapper.
- `VimSession.parkCursorOnFrontmostWindowIfOutside` becomes async (both callers are inside `Task { @MainActor }`), branching by frontmost bundleID.

**Known trade-off**: the main input box inside an iframe (some Notion / Figma / Google Docs widgets live in an iframe) currently isn't hit—top frame only for v1, the same limitation as the iframe coordination of hint detection; we'll extend it once it actually becomes a pain point.

**Electron / AX-weak apps** (Slack / Discord / VS Code): `AXFocusedUIElement` returns `kAXErrorNoValue`, so we honestly fall back to the title bar. Early on we experimented with deep-walking the focused window's AX subtree to fill the gap, and **consciously reverted it**—Slack's compose simply doesn't exist in the AX tree (it's not just a wrong role), and the walker ran 400+ nodes without finding it. The complexity-to-benefit ratio doesn't justify it; leave it to a future per-app patch route ("for Slack, just hardcode compose at 80pt from the bottom of the window").

### P4.11 — Modeless scrolling in the browser (d/u/gg/G, Vimium-style) ✅

When browsing the web frequently, having to first Caps Lock+d into SCROLL every time you scroll is annoying. Vimium can j/k/d/u scroll without entering any mode—we do this for **real browser web pages** too: scroll continuously with `d`/`u` (Shift to accelerate) without entering a mode, and `gg`/`G` to jump to top/bottom. Keybindings see `modes.md` §5.1.

**Key decision: detection on the page, scrolling in native (dispatch real wheel events).** Initially we tried pure JS `scrollBy` in the content script to scroll the DOM (even ported Vimium's `scroller.js`), but it broke on sites like YouTube: a manual mouse wheel only scrolls the container under the cursor, whereas JS `scrollBy` on some inner container drags the **whole page along** (the site syncs inner scrolling to the document; the browser engine has "scroll containment" for real wheel events that JS `scrollBy` can't reproduce). Empirically confirmed: scrolling `#guide-inner-content` also changes `document.scrollTop`. Conclusion—**only dispatching a real OS wheel event matches the manual wheel behavior**, and only native can do that.

Final architecture (option B):

- **content script detects the key press** (capture phase, every frame): when an editable element is focused (input/textarea/select/contenteditable/role=textbox, including shadow DOM) let typing through; with Cmd/Ctrl/Alt let it through; only a bare d/u/gg/G gets `preventDefault`+`stopPropagation`. The editable check reads `document.activeElement` synchronously in JS—**this is the only reason detection must be on the page side rather than a native event tap** (a tap can't get DOM focus synchronously).
- **native dispatches real wheel events**: the content script only sends `page_scroll` at gesture boundaries (start/stop/jump); native uses a resident `ScrollController` (**no enter / no warp / no overlay drawn**, reusing its start/stop/jumpToTop/jumpToBottom wheel-dispatch logic) to dispatch CGEvent wheel events at the **current cursor location**. The wheel naturally lands on the container under the cursor and goes through the browser engine's scroll containment, so "scrolling the sidebar without dragging the main content" is free and correct, and no coordinates need to be sent.
- **communication only at gesture boundaries**: 60fps continuous scrolling runs on a native-local timer, IPC is only start/stop/jump (not per-frame). Latency is just the one-way "press → start scrolling" hop (SW keepalive is warm, single-digit ms, <1 frame).
- **entering a mode auto-disables it**: after entering any Mouseless mode the native tap swallows d/u before the page receives the key → the content script doesn't trigger → modeless scrolling stops. Zero coordination.
- **Caps Lock+d gating**: real web pages disable Caps Lock+d (see `scroll-mode-design.md` §2.4); the decision relies on `scroll_gate`.
- **fallback stop**: `teardownCurrentMode()` (entering a mode), `BridgeServer.onActiveClientDisconnect` (SW died), and the content script's blur/visibilitychange all stop an in-flight page scroll, preventing the cursor from scrolling forever due to entering a mode before releasing / the extension disconnecting.

**Live Shift acceleration**: Shift itself has keydown/keyup, and during a sustained scroll the content script re-sends `start{fast}` accordingly, so pressing/releasing Shift before letting go changes speed instantly.

New protocol messages:

```jsonc
// extension → Mouseless: whether the currently focused tab has a content script injected (gates Caps Lock+d)
// bg pings the active tab's top frame on focus / tab / navigation changes, and only counts it live once it replies
{ "type": "scroll_gate", "live": true, "browser": "chrome" }

// extension → Mouseless: modeless scroll command (content script detected d/u/gg/G)
{ "type": "page_scroll", "action": "start", "dir": "down", "fast": false }
{ "type": "page_scroll", "action": "stop" }
{ "type": "page_scroll", "action": "jump", "to": "top" }    // gg=top / G=bottom

// Mouseless → extension (internal to bg): content-script liveness probe
{ "type": "mouseless_cs_alive" }   // content script replies { type:"cs_alive", alive:true }
```

native side: `VimSession.handlePageScroll` + a resident `pageScroll` controller; `setBrowserScrollGate` / `browserHandlesScroll`; the Caps Lock+d gating in `HotkeyTap`; `AppDelegate` routes `scroll_gate` / `page_scroll`; `BridgeServer.hasActiveBrowserConnection` + `onActiveClientDisconnect`.

**Known v1 boundary**: when the cursor sits on an iframe, the real wheel is still routed by the browser per the cursor's drop point (correct in most cases); the rest is the same top-frame leaning as hint detection. Other non-browser apps are unaffected and still require Caps Lock+d to enter SCROLL.

### P4.12 — Firefox adaptation (incremental) ✅

The first browser beyond Chrome. Conclusion: **cheap**—the JS (`background.js` / `content_script.js` / `detector.js`), the `mouseless-bridge` stdio binary, and the native-side protocol are **all reused**, differing only in manifest shape, native host registration, and a few browser-identification spots.

Actual changes:

- **manifest fork**: Chrome MV3's background only accepts `service_worker`, Firefox MV3 only accepts `background.scripts` (event page), and the two are mutually exclusive → no single manifest can serve both. Keep `manifest.json` (Chrome) + add `manifest.firefox.json` (event page + `browser_specific_settings.gecko.id = mouseless@local` + `strict_min_version`). `build-firefox.sh` assembles the shared JS + the firefox manifest into `dist-firefox/` (gitignored), and Firefox `about:debugging` → Load Temporary Add-on loads it. **The JS doesn't fork**.
- **`chrome.*` → `browser.*` fallback**: `background.js` has lots of `await chrome.tabs.query(...)` etc. Firefox's `browser.*` guarantees a returned promise, whereas the `chrome.*` alias is callback-style in some versions. So both files use `const chrome = globalThis.browser ?? globalThis.chrome;`—on Chrome `browser` is undefined so it's a no-op, on Firefox it takes the promise version. `detector.js` is pure DOM, never touches the extension API, so it needs no change.
  - **gotcha (fixed)**: this `const chrome` is fine in `content_script.js` (it's already inside an IIFE, function scope allows shadowing the global), but putting it at the **top level** of `background.js` blows up—**Chrome MV3's service worker treats `chrome` as a top-level lexical binding**, and a top-level `const chrome` directly causes `SyntaxError: Identifier 'chrome' has already been declared` → **SW registration fails and the entire extension backend dies** (Firefox treats `chrome` as a globalThis property, so a top-level const merely shadows it and doesn't error, which is why it only explodes on Chrome). Fix: **wrap the entire `background.js` in an IIFE** so `const chrome` becomes function-scoped, with no call site needing to change; the IIFE executes synchronously, so MV3's requirement of "register listeners synchronously" is still satisfied.
- **native host registration**: Firefox uses the Mozilla directory (`~/Library/Application Support/Mozilla/NativeMessagingHosts/`) and `allowed_extensions` keyed by add-on id (rather than Chrome's `allowed_origins: chrome-extension://…`). Add `install_dev_host_firefox.sh`; the gecko id is fixed so no argument needs passing. **The bridge binary + stdio protocol + Unix socket are unchanged**.
- **browser identification**: the extension's `detectBrowser()` adds a `Firefox/` branch returning `"firefox"`; native `AppRegistry.browserBundleIDs` and `BridgeServer.browserKeyForBundleID` add `org.mozilla.firefox` (+ developeredition / nightly). This way hint routing, Caps Lock+d gating, `scroll_gate`, and modeless scrolling (§4.11) **all take effect automatically** on Firefox—new features at zero extra cost.

**Not done (fill in as needed)**: official Firefox signing / AMO submission (the counterpart to Chrome's Web Store submission, grouped under the P5/release phase); the edge case of the event page being reclaimed under extreme idle (currently held up by a 20s keepalive + an always-open native port, the same policy as Chrome's SW).

### P4.13 — CSS show/hide toggle detection (pre-rendered modal / dropdown) (incremental) ✅

**Symptom**: under sticky TAP, opening a modal doesn't automatically show hints on it; you have to press Caps Lock again to get them.

**Root cause**: P4's `MutationObserver` only listens for `childList` (node add/remove). But many UIs (modals, dialogs, dropdowns, accordions) are **pre-rendered in the DOM and toggled by CSS** (changing `display`/`visibility`/a class/`hidden`/`aria-hidden`)—their clickable elements are **always in the DOM, just going from hidden to visible**, producing **no childList change at all** → the childList observer never fires → no `page_changed` sent → no auto-rescan. Whereas the `list_hints` triggered by a manual Caps Lock is the full detector with visibility checks, so once the modal is visible it gets scanned. (Log evidence: throughout opening a modal, Mouseless **receives not a single page_changed**; only a manual enter-TAP yields `received N hints`.)

**Fix**: `content_script.js` adds another observer dedicated to **attribute changes** (`attributeFilter: ["style","class","hidden","aria-hidden"]`, `subtree`). But `style` changes every frame, so we can't do work on every change (the same reason the childList path needs `hasNewClickable` to gate), so two gates:

1. **reset debounce (150ms)**: each incoming batch of attribute changes does `clearTimeout` + reschedule; during continuous animation the timer is repeatedly reset and never fires → **zero scans**; the moment a modal stops, 150ms later it actually checks (by which point the modal has settled and is visible).
2. **only fire when "the count of visible clickable elements changed"**: `visibleClickableCount()` = the number of `querySelectorAll(CLICKABLE_SELECTOR)` whose `getBoundingClientRect()` has width and height (`display:none` has 0 width/height, >0 once shown). hover/focus/animation don't change this count → no spurious fire; a modal appearing (count jumps up) / closing (count jumps down) → fire. CSS toggling adds no new DOM, so we can only compare "visible count", not "whether there's a new node" like childList.

Once fired it reuses `notifyPageChangedThrottled()` (shares the 500ms throttle with the childList path), and on the Mouseless side it goes through the ready-made `handlePageChanged` → refreshInPlace.

**Known limitations**: if a modal's clickable elements are **all** plain `<div onClick>` that only heuristics recognize (no button/a/role/tabindex), the cheap `CLICKABLE_SELECTOR` won't count them → won't trigger (with a real button it's fine); if the page is **never idle for 150ms** (continuous animation), the debounce won't fire, and a modal opened during that window waits for the animation to stop; both are rare, and there's a manual Caps Lock fallback.

### P5 — Safari adaptation + packaging & store submission (3-5 days)

1. Safari Web Extension: use Xcode's "Safari Web Extension App" template to wrap a macOS app layer
2. Safari's Native Messaging API differs slightly from Chrome's—mainly the host registration path and the manifest format
3. Apple signing (Developer ID or App Store)
4. Chrome Web Store submission: write a privacy statement, make icons, list permission justifications
5. Add user install instructions to the README

**Acceptance**: usable immediately after installing the extension, without requiring opening the Develop menu or any other manual user setup.

### Total effort estimate

| Stage | Days |
|---|---|
| P0 – P4 (feature-complete MVP, Chrome only) | **5-8 days** |
| P5 Safari + store-submission prep | **3-5 days** |
| Total | **~10 days to usable by users** |

Versus writing from scratch this saves **3-5 days**—mostly saved in P2's detection edge cases that we don't have to crawl through ourselves.

---

## 6. Risks & known gotchas

| Risk | Actual handling |
|---|---|
| **Cross-origin iframe** | postMessage chain protocol: each frame runs the detector itself, and after the child frame receives the parent frame's `mouseless_hints_request` + parent-computed `viewportOriginInScreen` it recursively queries its own iframes → merges and returns. All hints are already in screen coordinates, so the top frame does no further coordinate transform. ✅ implemented |
| **Shadow DOM** | the detector's `getAllElements` recurses `element.shadowRoot`; `isOnTop` using `elementsFromPoint` also recurses shadow roots. ✅ implemented |
| **UI on `<canvas>` (Figma / Google Maps)** | the DOM has only a single `<canvas>` → the detector returns 0 hints. **No downgrade to OP** (see §7)—the user sees 0 web hints, only Dock + menubar remain. **A conscious trade-off**: keep the mental model clean (browser = DOM truth), leaving canvas-only UI to special handling (per-site rule, not done) |
| **Chrome Web Store reviewing the broad permission** | the `<all_urls>` host permission is already declared; passing review will need copy explaining "needed to identify clickable elements on all web pages". **Handled at P5 store submission** |
| **Manifest V3 SW non-resident** | long-lived connection + port.postMessage keepalive at a 20s `keepalive` interval; if the port dies, reconnect with 1-30s exponential backoff. ✅ implemented |
| **Safari extension API not fully aligned with Chrome** | `browser.runtime.connectNative` is equivalent, but the Safari Web Extension API on macOS shares the broad Manifest V3 direction with Chrome. **Verified at P5** |
| **bridge host not installed / extension not installed / main process not running** | `sendToActive` returns false → `BrowserProvider.fetchHints` returns `[]` → the user sees 0 web hints in the browser app (Dock + menubar still present). **No downgrade to OP**—see §7 |
| **Multi-profile / multi-browser routing wrong** | i_am_active signal + bundleID identity verification. ✅ implemented |
| **No content script in already-open tabs after reloading the extension** | on SW startup, proactively inject with `chrome.scripting.executeScript({allFrames:true, files:[...]})`. ✅ implemented |
| **Built-in pages like chrome:// / Web Store forbid injection** | the extension replies `error: content_script_unavailable` → BrowserProvider accepts 0 hints, **no downgrade to OP**. On chrome:// the user pressing Caps Lock only sees Dock + menubar hints, as expected |
| **Switching tabs in the same window doesn't refresh hints** | `chrome.tabs.onActivated` → `tab_changed`. ✅ implemented |
| **Async-loaded content arrives late** | MutationObserver "new clickable appeared" → `page_changed` → in-place refresh. ✅ implemented |

---

## 7. Relationship to the existing OP / AX paths

**Core decision (374ea21)**: **once in the browser branch, it has nothing to do with OP**—whatever the extension returns (including 0 hints) is what you get, no fallback to OP.

Rationale:

1. **A clean mental model**—the user remembers one rule: "Chrome / Safari = DOM truth; other apps = AX or OP"
2. **OP works poorly on web pages**—web OCR both misses icon-only buttons and misreads background text, which is actually more confusing than "0 hints but the user knows why"
3. **The fallback boundary is hard to define**—is `empty hints` because "the page is genuinely empty" or because "the content script wasn't injected"? Both return `[]`, with no way to distinguish; either everything falls back or nothing does

Costs (accepted):

- The user didn't install the extension → no web hints on Chrome. This requires **the extension to be part of the product, not optional**. After P5 store submission, what the user gets is a single installer bundling the extension + Mouseless
- chrome:// / Web Store pages have no web hints. **Reasonable**—few people need Mouseless's help on these pages anyway

**Routing decision point** (`HintMode.collectAll`):

```
frontmost.bundleID
   ├─ AppRegistry.isBrowserApp → BrowserProvider.fetchHints  (no fallback)
   ├─ AppRegistry.shouldUseAXForFocused → AX walk             (whitelist app)
   └─ otherwise → OmniParserPath.collect                       (OP default)
```

The `browserBundleIDs` set: Chrome / Chrome Canary / Chrome Beta / Brave / Edge / Arc / Safari. Safari is still in the set for now but has no extension, so entering the browser branch yields 0 hints — that's the expected behavior before P5.

---

## 8. Follow-ups / derivatives

- **Firefox** —— basically free to follow once Manifest V3 compatible (the V2 era required a polyfill)
- **Arc / Brave / Edge** —— all Chromium-based, so in theory the same extension .crx package installs; but submitting to each store requires its own app-store account
- **Multi-tab hints** —— v1 only hints the current active tab; in the future it could extend to all tabs (so that when Mouseless switches tabs for you it lands directly)
- **Per-site clickable corrections** —— similar to `per-app-correction-design.md`, selector supplements for specific sites (YouTube's video control buttons, Notion's inline buttons, etc.)
- **DOM-level `/`-search** —— the hint list returned by the extension carries text, so `/`-search can fuzzy-match directly, more accurate than OCR
