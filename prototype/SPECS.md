# Keyway Prototype — Specs

A macOS keyboard layer that fully replaces the mouse. This is the entry
document for the current prototype implementation.

**Read this one for**: what the project is, how to run it, the top-level
architecture, per-file responsibilities, and the key trade-offs.
**Sub-documents**: implementation details and war stories for each
subsystem — see [§5 Document map](#5-document-map).

Coverage: native AX walk + an OmniParser vision fallback for Electron/WebView
apps + a browser extension for DOM hints. A multi-mode / sub-state
architecture (DRAG + `/`-search + SCROLL + WINDOW resize/move are done;
select-text is future work).

---

## 1. Run / build

```sh
cd prototype
./run.sh           # swift build + ad-hoc re-sign + launch
```

All three steps of `run.sh` are required:

1. `swift build` — Swift 6 strict concurrency, platforms = `.macOS(.v13)`.
2. `codesign --force --sign -` — **overwrite** SwiftPM's linker-signed
   signature with an ad-hoc one. The linker signature makes TCC
   (Accessibility) authorization unstable — every rebuild forces the user to
   re-grant. With an ad-hoc signature the grant is remembered stably.
3. `pkill -f Keyway` — the old instance must be killed before launching a
   new one, otherwise the old event tap is still intercepting events.

After launch a `K` icon appears in the menu bar:
- `K●` = ready, press **Caps Lock** to enter hint mode
- `K⚠` = a required permission is missing

On launch the app runs `hidutil` to remap Caps Lock to F19 (see §2.1), so the
user does **zero setup**. On quit it restores Caps Lock's original behavior.

`main.swift` uses `setActivationPolicy(.accessory)` — no Dock icon, and it
doesn't steal focus.

Logging is quiet by default (errors + warnings only). Set
`KEYWAY_LOG=debug` for the full per-operation diagnostics (scan timings,
AX walk steps, settle-watch polls, …); `info` / `warn` / `error` pick other
thresholds. See `Log.swift`.

---

## 2. Permissions

**Hard dependency on Accessibility + Screen Recording** (both are gated at
startup; missing either means the app won't start). Input Monitoring is not
needed.

- **Accessibility**: read the AX tree + synthesize clicks/keys.
  **Screen Recording**: the OmniParser vision fallback + the low-res
  fingerprint capture of the content-settle watch (see `specs/modes.md`
  mechanisms 1/2 and `specs/omniparser-fallback-design.md`).
- On first launch both permission dialogs appear
  (`AXIsProcessTrustedWithOptions` + `kAXTrustedCheckOptionPrompt`;
  `CGRequestScreenCaptureAccess`).
- After granting you must **fully quit** and restart the process for it to
  take effect (the OS doesn't hot-reload permissions; Screen Recording in
  particular is cached per process).
- When launching `./run.sh` from kitty / iTerm: TCC's responsible process is
  the terminal, so the permission attaches to the terminal; double-clicking
  the `.app` makes Keyway itself the responsible process. During
  development we go through the terminal.

Historical decision: we once tried `CGWindowList` + Screen Recording to
enumerate menu extras. On Sonoma+ the menu bar rendering is consolidated into
the Control Center process, so third-party status items aren't visible — even
with the permission granted it doesn't work. Removed. See
`specs/hint-discovery.md`.

### 2.1 Trigger key (Caps Lock → F19)

The trigger key is **F19** — a "Hyper key" that doesn't exist on a standard
keyboard. The physical Caps Lock is remapped to F19 via `hidutil` and then
intercepted by the CGEventTap.

**The app manages this mapping automatically**, see `TriggerRemap.swift`:

- `applicationDidFinishLaunching` (after AX authorization passes) →
  `TriggerRemap.applyAtLaunch()` calls `/usr/bin/hidutil property --set ...`
- `applicationWillTerminate` → `TriggerRemap.revertAtQuit()` calls
  `hidutil property --set '{"UserKeyMapping":[]}'`

User's view: install, grant, press Caps Lock and it works; after quitting
Keyway, Caps Lock is a normal toggle again — zero residue.

Under the hood it's one line — `hidutil property --set ...` maps HID usage
`0x39` (Caps Lock) → `0x6E` (F19). **No root, no kext required.** The Caps
Lock LED no longer lights on press — which is correct, the key is no longer
Caps Lock.

**Why F19 instead of grabbing Caps Lock directly**: macOS treats Caps Lock
specially — it only emits a `flagsChanged` event toggling the
`.maskAlphaShift` flag, and **no keyDown**, so the CGEventTap never sees a
matchable event. After remapping, the system treats the key as F19 at the HID
layer — a normal keyboard event the event tap can catch, with no toggle state.

**Where the lifecycle isn't perfect**: `applicationWillTerminate` doesn't
always fire on force-quit / crash / system shutdown. In those cases the remap
persists until the next reboot or the next Keyway launch (applyAtLaunch is
idempotent, so re-applying has no side effects). A user who notices can clear
it manually with `hidutil property --set '{"UserKeyMapping":[]}'`.

### 2.2 setup-trigger.sh — for advanced users only

Normal use never touches this script; the app handles everything. It exists
for two scenarios:

```sh
./setup-trigger.sh             # apply the remap manually without launching the app (test/debug)
./setup-trigger.sh --persist   # install a LaunchAgent so the remap applies even when Keyway isn't running
```

The `--persist` use case: a user relies on F19 for **other** tools (e.g. they
bound F19 → some Alfred workflow) and wants Caps Lock = F19 to be **always**
in effect, not just while Keyway runs.

### 2.3 Uninstall

```sh
hidutil property --set '{"UserKeyMapping":[]}'                              # restore for the current session
launchctl unload ~/Library/LaunchAgents/com.keyway.trigger-remap.plist  # unload the LaunchAgent (if installed)
rm ~/Library/LaunchAgents/com.keyway.trigger-remap.plist
```

---

## 3. Top-level architecture

```
NSApplication
└── AppDelegate (main.swift)
    ├── NSStatusItem ("K" menu-bar icon)
    ├── HotkeyTap         ← CGEventTap, intercepts/passes all keyboard events
    │   └── VimSession    ← mode state machine + command-palette buffer
    │       └── HintMode  ← AX scan + label generation + commit click
    │           ├── HintOverlay (full-screen transparent window drawing hint labels)
    │           └── HUD       (bottom-center mode indicator)
    └── MenuExtraCache    ← background set of "which PIDs have menu extras"
```

Control flow:

1. **HotkeyTap** is the single event entry point. It registers a
   `CGEvent.tapCreate` listening for `keyDown` + `keyUp` + `flagsChanged`.
   Each event is first checked for `eventSourceUserData == "MOUS"` — events we
   synthesized ourselves are passed straight through (to avoid a feedback loop).
2. **F19 (= Caps Lock) uses an arm mechanism, in any mode**: pressing it
   doesn't act immediately (arm); on release, if no chord was pressed in
   between → `session.handleTriggerTap()` (dispatched by the current mode:
   OFF→enter TAP / TAP→toggle sticky / SCROLL→switch to TAP / palette→close);
   pressing `d` while armed → `session.enterScroll()`. See `modes.md` §2.1.
3. **Other keys**, when a mode is active, go to `VimSession.handle()`.
   Returning `true` = consumed, `false` = passed through (so system shortcuts
   like Cmd+Space / Cmd+Tab keep working).
4. `VimSession` dispatches by mode (`.tap` / `.scroll`) and palette state; the
   mode decides hint / move-cursor / scroll / exit internally.
5. Committing a click **always synthesizes a mouse event** (the AX semantic
   actions AXPress/AXShowMenu are deprecated — unreliable, see
   `hint-rendering.md` §3). Synthesized events are all tagged `"MOUS"`.

---

## 4. File responsibilities

**Core**:

| File | Responsibility |
| --- | --- |
| `main.swift` | NSApp bootstrap, accessory activation policy |
| `AppDelegate.swift` | Menu bar, permission checks, start HotkeyTap, `MenuExtraCache.warmUp()`, `OmniParserModel.preload()`, `TriggerRemap` lifecycle |
| `HotkeyTap.swift` | CGEventTap registration (keyDown/keyUp/flagsChanged) + feedback-loop avoidance + F19 arm/chord dispatch |
| `VimSession.swift` | Mode state machine (`.tap`/`.scroll`), arm dispatch (`handleTriggerTap`/`enterScroll`), palette, key routing |
| `HintMode.swift` | Collect 4 sources (focused-window AX **or** OP / Dock / menubar / extras) → generate labels → typing → commit (synthesized click) |
| `HintWindowCache.swift` | Per-`AXWindow` cache for the focused app. A sticky rescan reuses window subtrees that didn't change |
| `MenuExtraCache.swift` | Background set of "which PIDs have menu extras" |
| `HintOverlay.swift` | One borderless transparent window per screen, drawing hint labels (large rects use inside placement) |
| `HUD.swift` | Bottom-center mode indicator. Window width auto-fits the text (min 100pt, 16pt padding on each side), recomputed and re-centered on every `show()` — avoids clipping longer HUD text like `WINDOW: no resizable window` |
| `KeyCode.swift` | `kVK_ANSI_*` physical key-code constants (incl. `f19=80`; ANSI layout, wrong on non-QWERTY) |
| `FocusedApp.swift` | Resolve the frontmost app via `NSWorkspace.frontmostApplication` (more reliable than AXFocusedApplication on Electron) |
| `MouseSynth.swift` | Synthesize mouse click + drag down/up + get cursor position (shared by hint commit, bare `c` click, DRAG) |
| `TriggerRemap.swift` | On launch, shell out to `hidutil` to map Caps Lock → F19; restore on quit |
| `KeyPoster.swift` | Synthetic keyboard-event helper (unused on the main path; reserved for a future select-text mode) |

**Mouse move / scroll**:

| File | Responsibility |
| --- | --- |
| `MouseMover.swift` | Continuous hjkl cursor movement, **shared by TAP + SCROLL** (60fps timer; in TAP's dragging sub-state, with `dragHeld=true`, the event type becomes `.leftMouseDragged`) |
| `ScrollController.swift` | SCROLL-mode scroll synthesis + continuous + acceleration + area selection + cursor warp |
| `DragController.swift` | DRAG sub-state (inside TAP) state container, single segment: `init(at: CGPoint)` immediately synthesizes a mouseDown and records `startPoint` (triggered by bare `v` in TAP normal); Backspace-cancel warps back to `startPoint` + mouseUp there; holds no "preMode" — drop / cancel both return to TAP normal, converged by `VimSession.tapSub` (see `modes.md` §6) |
| `SearchOverlay.swift` | Visual layer for TAP's `/`-search sub-state: per-NSScreen borderless transparent NSWindow drawing yellow highlight boxes + label chips (label pool reuses `HintMode.alphabet`, chip to the left of the text); dynamically dims labels that don't match `typed`. See `modes.md` §6.5 |
| `ScrollAreaDetector.swift` | AX-walk the focused window to find `AXScrollArea`/`AXWebArea` (doesn't depend on OP routing) |
| `ScrollOverlay.swift` | Scroll-area picker: blue glow border + numeric markers |
| `WindowController.swift` | WINDOW resize state machine + 60fps timer: tracks the currently-held set of hjkl edges, computes a resize delta each tick and writes it straight to the focused window via AX (no fallback path — the entry gate guarantees AX is writable). Reads `NSEvent.modifierFlags` live each tick: Shift = shrink, Option = 5pt fine step, the two orthogonal and combinable. See `modes.md` §7 |
| `WindowMoveController.swift` | WINDOW MOVE state machine + 60fps timer: tracks the held direction set (`enum Direction { left, right, up, down }`), writes only `AXPosition` each tick (one IPC, one fewer than resize). Modifiers: bare 20pt / Shift 80pt fast / Option 5pt slow (Option > Shift priority, mirroring `MouseMover.moveSpeed`). See `modes.md` §8 |
| `WindowOpOverlay.swift` | Shared by WINDOW resize / MOVE: blue border + optional 4 edge chips (`↑k / ↓j / ←h / →l`). `show(rect:withChips:)` controls whether chips are drawn — resize draws them (edge-binding hint), MOVE doesn't (hjkl is direction, not edge-bound). Follows the per-NSScreen borderless-window pattern of `HintOverlay` / `ScrollOverlay`; when computing a chip position, skip drawing if it isn't fully contained in the current screen (user requirement: don't draw off-screen) |
| `AXWindowOps.swift` | Window AX helpers: `frontmostWindow()`, `isResizable()` (probe that `AXPosition`+`AXSize` are both settable), `isMovable()` (probe `AXPosition` only — MOVE doesn't need `AXSize`), `hasTitleBarButton()` (decides "real window": has at least one of Close/Min/Zoom/FullScreen — `AXSubrole` is unreliable on AX-black-hole apps, but title-bar buttons are queryable on any shell NSWindow chrome), `readRect()` / `writeRect()` (two IPCs, pos+size) / `writePosition()` (one IPC, origin only, for MOVE) |

**OmniParser vision path** (focused-window hints for AX-bad apps, see
`omniparser-fallback-design.md`):

| File | Responsibility |
| --- | --- |
| `AppRegistry.swift` | `AX_FOCUSED_WHITELIST` — the routing decision of whether the focused window goes AX or OP; `browserBundleIDs` — browser apps go to BrowserProvider |
| `ScreenCapture.swift` | ScreenCaptureKit capture of the focused window (display capture + crop, with a display cache) |
| `OmniParserModel.swift` | CoreML YOLO detector (icon_detect.mlpackage, preloaded at launch) |
| `OmniParserPath.swift` | screenshot → inference → §5.1 baseline filtering → screen-coordinate candidates; debug overlay |
| `OCRRefiner.swift` | OP click precision: when the center lands inside an inner box, re-locate it with Vision OCR (incl. CJK). Also exposes a `recognizeText(in:)` helper for TAP's `/`-search sub-state (same `.accurate` + zh/en config) |

**Browser path** (focused-window hints for Chrome / Safari, see
`browser-support-design.md`):

| File | Responsibility |
| --- | --- |
| `BridgeServer.swift` | Unix-domain socket server in the Keyway main process (`~/Library/Application Support/Keyway/bridge.sock`). Concurrent multi-client; `activeFD` bound to the `i_am_active` signal (multi-profile / multi-browser routing); `sendToActive(_, expectingBrowserBundleID:)` for proactive outbound requests + refuses on bundleID mismatch; `awaitResponse(ofType:timeout:)` async send-one-receive-one waiting for the extension's reply |
| `BrowserProvider.swift` | Hint source for `HintMode`'s browser branch. Three async APIs: `fetchHints()` → pull the hint list (incl. a `navigates` field marking anchor links); `findText(query:)` → `/`-search uses a DOM TreeWalker in browsers instead of OCR; `findFirstInputRect()` → app-switch cursor park uses the DOM (`document.activeElement` / first visible input) instead of AX. **The browser path is self-contained: no fallback to OP** — whatever the extension returns is it (even if zero) |
| `Sources/keyway-bridge/main.swift` | Second SwiftPM target, builds the `keyway-bridge` binary. Chrome Native Messaging host: launched by Chrome, bidirectional raw byte forwarding stdio ↔ Unix socket (no parsing); if the socket can't connect, writes a `bridge_error` frame to stdout so the extension can see it |
| `extension/manifest.json` | Chrome extension Manifest V3: declares `nativeMessaging` + `scripting` permissions + `host_permissions: <all_urls>`, content scripts injected into all frames |
| `extension/background.js` | Extension service worker. Persistent native port + keepalive; listens to `windows.onFocusChanged` to send `i_am_active`; `tabs.onActivated` to send `tab_changed`; `tabs.onUpdated status=complete` to send `page_changed (navigation_complete)`; forwards native's `list_hints` / `find_text` / `find_first_input` to the active tab's content script; on SW connect, proactively injects the scripts into already-open tabs via `scripting.executeScript` |
| `extension/content_script.js` | Runs in every frame: the top frame handles bg's `list_hints` / `find_text` / `find_first_input` requests; any frame handles its parent's `keyway_hints_request` / `keyway_text_request` (recursively postMessages iframes, merging viewport coordinates); a MutationObserver watches for "new clickable appeared" → sends `page_changed` |
| `extension/detector.js` | DOM-level hint / text / input detection: three exported functions. `listHints()` — clickable-element detection rewritten from Vimium's rules (selector + ARIA roles + jsaction + ng-click + visibility + 5-point occlusion + shadow-DOM recursion, each hint carries a `nav` flag for anchor links). `findTextMatches(query)` — TreeWalker + Range.getClientRects to find character-level substring matches within the viewport (browser path for `/`-search). `findFirstInput()` — `document.activeElement` first / fallback to the first visible input/textarea/contenteditable (browser path for app-switch cursor park). All take a `viewportOriginInScreen` parameter so iframes use the coordinates their parent computed |
| `extension/install_dev_host.sh` | Writes `~/Library/.../NativeMessagingHosts/com.keyway.bridge.json`, binding the extension ID to the local bridge binary path |
| `extension/vendor/vimium/MIT-LICENSE.txt` + `NOTICE.md` | Vimium attribution (the detection rules derive from Vimium, rewritten as clean JS, MIT license retained) |

**Scripts**:

| File | Responsibility |
| --- | --- |
| `setup-trigger.sh` | For advanced users. `--persist` installs a LaunchAgent so the F19 mapping is independent of Keyway's lifecycle |

---

## 5. Document map

Per-subsystem details, design trade-offs, and war stories live under
`specs/`:

| Document | Contents |
| --- | --- |
| [`specs/event-pipeline.md`](specs/event-pipeline.md) | HotkeyTap registration, the callback's three-layer short-circuit, the `"MOUS"` feedback-loop tag, modifier pass-through policy (Cmd/Ctrl passed, Shift/Option consumed) |
| [`specs/modes.md`](specs/modes.md) | Mode state machine (`.tap`/`.scroll`), the F19 arm mechanism, palette, sticky, hjkl cursor movement (unified across TAP+SCROLL) + bare `c` click (Enter passed to the app), **the full keymap tables**, KeyCode constants, adding a new mode |
| [`specs/scroll-mode-design.md`](specs/scroll-mode-design.md) | **Full SCROLL-mode design**: chord entry (Caps Lock + d), AXScrollArea/AXWebArea detection, multi-area picker, d/u scroll synthesis, gg/G jump to top/bottom, hjkl cursor movement + bare `c` click, the zero-AX Electron limitation |
| [`specs/hint-discovery.md`](specs/hint-discovery.md) | The three AX sources (focused / Dock / menu extras), `walk()` inclusion criteria, screen-union computation, **the menu-extras war story + `MenuExtraCache` design**, concurrency safety |
| [`specs/hint-rendering.md`](specs/hint-rendering.md) | Label generation, typing → commit, **the unified synthesized click** (AX actions abandoned), `HintOverlay`'s multi-screen windows, coordinate-system conversion, badge layout (inside / Dock / cascade), HUD |
| [`specs/omniparser-fallback-design.md`](specs/omniparser-fallback-design.md) | **Implemented (P5-P6)**: the OP vision path, OP-default + AX-whitelist routing (not fall-through); baseline filtering; the OCR click-point refiner (§4.6); PoC data; the captioner shelved |
| [`specs/omniparser-integration-roadmap.md`](specs/omniparser-integration-roadmap.md) | **Implementation roadmap**: P0-P6 done (CoreML spike → capture → routing → integration → end-to-end → OCR refiner), P7 (data tuning) / P8 (release) pending |
| [`specs/per-app-correction-design.md`](specs/per-app-correction-design.md) | **Design draft, not implemented**: per-app **AX-walker overrides** (declarative JSON predicates that translate long-tail apps' weird AX trees into clickable elements) as the primary mechanism, OP as fallback, NCC template matching demoted to an appendix (likely never built). Includes an L0→L2 community flywheel + governance + teach loop |
| [`specs/browser-support-design.md`](specs/browser-support-design.md) | **P0–P4 implemented** (Chrome): extension + Native Messaging Host + `BridgeServer`/`BrowserProvider` deliver DOM-level hints; multi-profile / multi-browser routing + `tab_changed` + async-load `page_changed` all live; the browser path is self-contained, **no fallback to OP**. P5 Safari + store submission pending |
| [`specs/settings-design.md`](specs/settings-design.md) | **Design draft, not implemented**: a menu-bar "Settings…" (Cmd+,) config panel. v1 covers value-type settings (cursor/scroll/window speed, double-click threshold, jump distance) + theme color + trigger presets + launch-at-login; stored in UserDefaults (defaults = the current hardcoded constants, zero-risk), live-applied. Custom keymaps deferred to v2 (non-QWERTY rebinding refactor) |

---

## 6. Key design trade-offs (speed-read)

| Trade-off | Choice | Reason |
| --- | --- | --- |
| Per-element AX attribute fetch | `AXUIElementCopyMultipleAttributeValues` to grab 10 attributes at once | per-element IPC cut from 9+ to 1; focused-app scan dropped from ~840ms to ~200ms |
| Sticky rescan reuse | per-`AXWindow` cache + `AXWindows` diff + commit-driven dirty | the common "destroy one window, leave the rest" op (e.g. closing a dialog) skips a rescan |
| Menu bar fast path | read `AXSelectedChildren` once on AXMenuBar; if empty, don't descend | 99% of the time the menu bar isn't open, skipping N×4 axMenuIsOpen probes |
| Menu-extras discovery | background PID cache + NSWorkspace deltas | < 30ms at trigger time; the warm-up cost is invisible to the user |
| Click implementation | **unified synthesized mouse event** (no AX actions) | AX actions (AXPress/AXShowMenu) silently fail on NSBrowser cells / custom views / Electron; a synthesized click is predictable and matches the user's mental model |
| bare `c` click | synthesize a click at the current cursor position (Shift double-click / Option right-click) | pairs with hjkl cursor movement (move→click loop); replaces the old Enter-as-click, freeing Enter to pass to the app (menu confirm, form submit keep app semantics) |
| Cursor move / scroll use bare keys, not Ctrl | hjkl move cursor (unified TAP+SCROLL), d/u scroll | power users (HHKB) often map Ctrl+hjkl to arrow keys system-wide, which would conflict |
| Focused-window hint routing | AX whitelist → AX walk; everything else → OmniParser | framework ≠ AX quality (WeChat is native but an AX black hole); OP works on all apps and at ~95ms is no slower than an AX walk |
| Scroll-area detection | AX only (`AXScrollArea`/`AXWebArea`), not OP | a scroll area is a container with no visual features, OP can't recognize it; structural AX is reliable even when content AX is bad |
| Number of overlays | one window per screen | a single window spanning screens renders unreliably on macOS |
| Overlay level | `CGOverlayWindowLevel` (102) | above all normal UI layers (menu bar / modal / `.popUpMenu` = 101), so an AXMenuItem's inside-top-left label isn't covered by the dropdown's background fill. An early version used `.statusBar` (25) and hit exactly this |
| "Waiting" for async ops | AX / NSWorkspace observers + async/await + timeout backstop | no fixed sleep guessing the time. Leave early if the OS notification fires before the empirical estimate; on the slow path wait until AX has synced. The timeout backstop keeps a Task from hanging on a silent failure |
| Cmd/Ctrl pass-through | not consumed | preserve Spotlight, Mission Control, screenshot, and other system features |
| Shift/Option | consumed | used for the hint click action (Shift=double-click / Option=right-click) |
| Label character set | 9 home-row letters + 10 digits | digits go to the Dock exclusively, the letter pool is left for other sources |
| KeyCode abstraction | physical `kVK_ANSI_*` constants | simple; cost: misalignment on non-QWERTY layouts (a known gap) |

---

## 7. Known gaps / future work

By priority:

1. **Electron / AX-bad app coverage** — **OmniParser vision path implemented
   (P5-P6)**. Background: what the Chromium bridge exposes depends on the
   app's ARIA hygiene; bad ones (WeChat, domestic SaaS) are a sea of AXGroups
   with no actions; and framework ≠ AX quality (WeChat is native AppKit but
   self-renders chat content, an AX black hole). Approach: **OP-default +
   AX-whitelist routing** — a focused window whose app isn't in
   `AppRegistry.AX_FOCUSED_WHITELIST` goes through OP (ScreenCaptureKit
   capture + CoreML YOLO + baseline filtering + OCR click-refine), ~95ms, no
   slower than an AX walk. Remaining: P7 data tuning (confidence threshold /
   whitelist edits) and the per-app correction layer (template matching). See
   [`specs/omniparser-fallback-design.md`](specs/omniparser-fallback-design.md).
2. **Scan spikes during an app's AX cleanup** — closing a dialog / sheet lands
   a sticky rescan inside the target app's ~500ms cleanup window, where
   per-IPC latency rises from ~0.2ms to ~40ms. IPC count is already at its
   floor of 13 (cache + walkMenuBar in tandem), so optimization room on this
   path is exhausted. An event-driven "wait until AX is stable, then scan"
   approach hasn't been tried — notification timing is uncontrollable, and the
   theoretical wall-clock time might not drop. **Independent of OmniParser
   routing** — OP only solves AX-black-hole apps; under a cleanup spike AX can
   still return candidates (just slowly), and only whitelisted apps take the
   AX walk. See `specs/hint-discovery.md` §5 +
   [`specs/omniparser-fallback-design.md`](specs/omniparser-fallback-design.md) §4.5.
3. **New modes / sub-states** — the `Mode` enum already has extension points:
   select-text, a right-click command mode (WINDOW resize `specs/modes.md` §7
   / WINDOW MOVE §8 are done; TAP's internal sub-states DRAG `specs/modes.md`
   §6 / `/`-search §6.5 are done). The wiring path is in `specs/modes.md` §12.
4. **`/`-search supporting Chinese input** — the current search-typing
   sub-state only accepts ASCII (`VimSession.searchTypingChar` whitelists a-z
   + 0-9 + space). Chinese pages **can be OCR'd** (`OCRRefiner.recognizeText`
   is configured for zh-Hans / zh-Hant) but **can't be typed into**. Root
   cause: the CGEventTap intercepts keyDown before the IME, so the IME never
   gets the raw key and can't compose. Three candidate paths:
   - **(a) pop a modal NSPanel to receive input** (recommended) — on bare `/`,
     show a small borderless panel that temporarily holds focus so the IME can
     work in the panel's NSTextField; restore focus when the sub-state exits.
     The cleanest state isolation.
   - **(b) steal focus to a hidden NSTextField + NSTextInputClient** — no
     panel, but be careful that the sticky-rescan frontmost-app observer will
     be perturbed by the focus-stealing action.
   - **(c) allow Cmd+V to paste the clipboard** — zero code risk but requires
     the user to type the text elsewhere first and copy it.

   English-only is fine for the MVP; when building this, first evaluate
   whether (a) visually conflicts with the existing SearchOverlay.
5. **Label-space collision across hint sources** — when the focused app has
   many elements it eats the whole letter pool, pushing menu extras to
   `lj/lk/ll`. Candidate fixes: give menu extras a separate prefix (e.g. `;a`,
   `;s` …) or a separate letter pool.
6. **Dock separator / Recents placeholder filtering** — the Dock currently
   collects every `AXDockItem`, including separators. Low-value hints waste
   labels.
7. **Settings config panel** — a menu-bar "Settings…" (Cmd+,). v1 covers
   value-type settings (slow/medium/fast for cursor/scroll/window speed,
   double-click threshold, jump distance) + theme color + label font size +
   trigger-key presets + launch-at-login + sticky default. Stored in
   UserDefaults (defaults = the current hardcoded constants, so unconfigured
   behavior is unchanged), live-applied. The `private let normalStep`-style
   constants in each controller switch to reading `Settings.shared`. Custom
   keymaps deferred to v2 (the non-QWERTY layout rebinding refactor).
   See [`specs/settings-design.md`](specs/settings-design.md).
8. **Rename** — the name "Keyway" is already taken by another project; a
    unique name should be settled before a wider release (repo / domain /
    searchability, not drowned out by a generic word).
9. **Packaging & distribution** — code signing + notarization (Developer ID,
    to avoid Gatekeeper blocking an unsigned app), shipped as a `.dmg` or a
    Homebrew cask; optionally a simple landing page with a **demo video**.
    Notarization / Developer ID signing requires the Apple Developer Program
    ($99/yr).
