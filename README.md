<div align="center">

<img src="docs/keyway-icon.png" width="120" alt="Keyway icon">

# Keyway

**Drive your Mac entirely from the keyboard.**

Click anything, scroll anything, move any window — without your hands ever
leaving the home row. Even in Electron apps and web views that other tools
can't see.

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-2b8cff.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-13%2B%20·%20Apple%20Silicon-1a1a1a?logo=apple)
![Status](https://img.shields.io/badge/status-early%20prototype-f59e0b)

<img src="docs/demos/hero.gif" width="720" alt="Keyway in action — hint labels across the whole screen, including an Electron app, the Dock, and the menu bar">

<sub>Hint mode across a Discord window, the Dock, and the menu bar — type a label, it clicks.</sub>

</div>

---

Press **Caps Lock**. Every clickable thing on screen sprouts a short letter
label. Type the label — it clicks. That part isn't new. Three things make
Keyway different from other keyboard-clickers:

- **Coverage.** It finds targets not only in native Cocoa apps (via the
  Accessibility API) but also inside **Electron apps, web views, and arbitrary
  pixels** — by falling back to an on-device vision model — and inside **web
  pages** via a companion browser extension that reads the DOM directly. That
  "AX black hole" (Slack, VS Code, Discord, anything Electron) is exactly
  where keyboard-driven clicking usually falls apart. Keyway covers it.

- **It drives the real cursor, not just clicks.** Labels are the fast path;
  when nothing is labeled exactly where you want, you fall back to *moving the
  pointer itself* — `hjkl` to nudge it (Shift to fly, Option for
  pixel-precision), `'`+label to warp it onto a target without clicking, then
  `c` / `cc` / `Shift+c` for left / double / right click. Plus a **drag** mode
  (grab, move, drop) and a **search** mode (jump to any visible text by typing
  it). Most hint tools can only click what they can label. Keyway can also
  just take the wheel.

- **Sticky, on demand.** Tap **Caps Lock** again to keep hinting click after
  click; tap once more to stop. No preconfigured "chain" mode to set up
  (Homerow needs one) — you flip it on or off live, whenever you want it.

## See it in action

> 🎬 _More clips are being added. The first two are already shown in the hero
> clip above._

### 1 · Hint mode — the core loop
Caps Lock in a native app → labels bloom on every clickable thing → type two
keys → it clicks (left, or right-click with a modifier). _(See the hero above.)_

### 2 · Sticky, on demand ⭐
Tap **Caps Lock** again to keep hinting click after click; it re-hints on its own
as content loads or you switch apps / Spaces. Tap once more to stop. No "chain"
mode to preconfigure the way Homerow needs — you flip it live. _(Also in the
hero above.)_

### 3 · Drive the real cursor ⭐
<!-- <img src="docs/demos/cursor.gif" width="760" alt="Cursor control"> -->
No label exactly where you need it? Move the pointer yourself: `'`+label warps
it onto a target without clicking, `hjkl` nudges it (**Shift** to fly,
**Option** for pixel-precision), then `c` / `cc` / `Shift+c` for left / double /
right click. The fallback hint-only tools don't have.

### 4 · Drag mode ⭐
<img src="docs/demos/drag.gif" width="760" alt="Drag mode">

From TAP (or TAP sticky), press `v` to start a drag — `mouseDown` at the cursor,
`hjkl` to move, drop to release. In the clip the drag selects a paragraph of
text so it can be copied and pasted — a real press-drag-release, no mouse.

### 5 · Search mode ⭐
<img src="docs/demos/search.gif" width="760" alt="Search mode">

From TAP (or TAP sticky), press `/` and type any visible text — Keyway OCRs the
focused window, matches it, and labels the hits so you jump straight to one.

### 6 · Scroll mode
<img src="docs/demos/scroll.gif" width="760" alt="Scroll mode">

**Caps Lock + d** enters scroll mode and outlines every scrollable area with a
number; press that number to pick one. Then `d` / `u` scroll it (hold for
continuous, **Shift** to accelerate) and `gg` / `G` jump to top / bottom.

Web pages are special: with the extension, `d` / `u` / `gg` / `G` scroll the
page **directly, no mode to enter** — Vimium-style. (Caps Lock + d is disabled
there, since modeless scrolling already covers it.)

### 7 · Move & resize windows
<img src="docs/demos/window.gif" width="760" alt="Window move and resize">

**Caps Lock + w** enters resize, **Caps Lock + m** enters move. In resize, grow
any edge with `hjkl` (double-tap an axis to pull the opposite edge inward); in
move, pan the whole window with `hjkl`. Hold **Shift** to fly, **Option** for
fine steps — all from the keyboard, no mouse.

### 8 · Web pages, precisely (Chrome / Firefox)
<img src="docs/demos/web.gif" width="760" alt="Browser extension hints">

With the companion extension, hints come straight from the DOM — pixel-perfect
and iframe-aware on any real page. And in **sticky mode they refresh themselves
as the page changes**: scroll, open a menu, navigate to a new page — the labels
re-scan to match what's on screen, so you keep clicking without pressing Caps
Lock again.

## What it can do

| | |
|---|---|
| 🎯 **Hint mode** | Label every clickable element, type the label to click. The fast path. |
| 🕳️ **Beyond native AX** | Electron (Slack, VS Code, Discord), WebViews and Catalyst apps expose almost nothing to the Accessibility API. Keyway fills that black hole with an on-device [OmniParser](https://github.com/microsoft/OmniParser) vision model. |
| 🖱️ **Drive the real cursor** | When no label sits where you need it, move the pointer yourself: `hjkl` to nudge (Shift to fly, Option for pixel-precision), `'`+label to warp onto a target without clicking, then `c` / `cc` / `Shift+c` for left / double / right click. The fallback hint-only tools don't have. |
| ✊ **Drag mode** | Grab at the cursor, move with `hjkl`, drop — full drag-and-drop without the mouse. |
| 🔎 **Search mode** | Type any visible text to jump to it (OCR + character match), then pick the match with a hint label. |
| 🌐 **Real web pages** | A browser extension reads the DOM directly for precise, iframe-aware hints. |
| 📜 **Scroll & windows** | Keyboard scrolling (multi-area picker) and window move/resize, plus Vimium-style modeless scrolling on web pages. |
| 🧲 **Sticky, on demand** | Tap **Caps Lock** again to keep hinting click after click — and it auto re-hints as content loads or you switch apps/Spaces; tap once more to stop. No "chain" mode to preconfigure (Homerow needs one). |
| 🔒 **Local-only** | Runs entirely on-device. No telemetry, no network calls beyond the local app↔extension socket. |

## How it works

Three hint sources, merged into one overlay:

1. **Accessibility walk** — for native macOS apps, walk the AX tree of the
   focused window and collect clickable elements. Fast and pixel-perfect.
2. **On-device vision fallback** — for AX-black-hole apps (Electron / web
   views), capture the focused window and run a CoreML icon-detection model
   to find clickable regions from pixels alone.
3. **Browser extension** — for Chrome/Firefox, a content script runs a
   Vimium-derived detector over the DOM and streams hint rects to the app
   over a native-messaging bridge. Handles iframes and cross-Space follow.

A couple of pieces that were interesting to build (deep-dives in
[`prototype/specs/`](prototype/specs/)):

- **Cheap "wait for the screen to settle" detection.** Many rehints (after a
  click, an app switch, a cross-Space slide) need to wait until the new
  content has actually rendered — but there's no event for that. Instead of
  guessing a fixed delay, Keyway polls a tiny (64×36) grayscale fingerprint
  of the window and rehints the moment two frames match. One scan, timed to
  the content, not to a guess.
- **Caps Lock as the trigger** without a kext: `hidutil` remaps Caps Lock to
  F19 at the HID layer (macOS doesn't deliver Caps Lock as a normal keyDown),
  applied on launch and reverted on quit.

## Install

### Download a pre-built build

Grab the latest `Keyway-vX.Y.Z.zip` from the
[**Releases**](https://github.com/Njuhobby/keyway/releases) page, unzip it,
and drag **Keyway.app** into `/Applications`.

The build is ad-hoc signed, **not notarized by Apple**, so Gatekeeper blocks
it the first time. Bypass it once:

- **Right-click** `Keyway.app` → **Open** → click **Open** in the dialog.

  …or from Terminal:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Keyway.app
  ```

Then launch it and grant the two permissions below. Because the build isn't
signed with a stable Developer ID, a future version may ask you to re-grant
those permissions.

### Build from source

A self-built app skips the Gatekeeper prompt entirely.

```sh
cd prototype
./run.sh        # swift build + ad-hoc re-sign + (re)launch
```

A key icon appears in the menu bar (a red `!` badge next to it means a
required permission is missing). Press **Caps Lock** to enter hint mode. On
first launch macOS prompts for the two permissions — enable Keyway in
**System Settings → Privacy & Security** for both, fully quit, and rerun.

To produce a distributable `.app` and a release zip:

```sh
cd prototype
./package-app.sh    # → build/Keyway.app  (signed, with icon)
./release.sh        # → build/Keyway-v<version>.zip  (bundle-safe, + sha256)
```

> See [`prototype/SPECS.md`](prototype/SPECS.md) for the full setup, the mode
> reference, and the architecture deep-dives.

#### Browser extension (optional, for web-page hints)

Load `prototype/extension/` as an unpacked extension (Chrome:
`chrome://extensions` → Developer mode → Load unpacked; Firefox: build with
`build-firefox.sh`, then load via `about:debugging`) and install the
native-messaging host with the provided script. Without it, web pages still
work through the vision fallback, just less precisely.

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon
- To build from source: a Swift toolchain (Xcode or the Swift CLT)
- Two permissions, **both required** (granting either needs a restart to take
  effect — macOS caches them per process):
  - **Accessibility** — to read the AX tree and synthesize clicks/keys
  - **Screen Recording** — for the vision fallback and the settle detection

## Permissions & privacy

Keyway runs entirely on your machine. **No telemetry, no network calls**
other than the local socket between the app and the browser extension. The
permissions are used only for what's described above; screen captures are
processed in memory and not written to disk (outside an opt-in debug flag).

## Status

**Early prototype / research project.** It works and is usable daily, but it
is rough, unsigned, and the code lives under `prototype/`. Expect sharp
edges. Built in the open to share the approach.

## License

**[AGPL-3.0-or-later](LICENSE).** Keyway bundles an icon-detection model
derived from [OmniParser](https://github.com/microsoft/OmniParser) (built on
Ultralytics YOLO), whose weights are AGPL-licensed; the AGPL applies to the
combined work, so the whole project is AGPL-3.0. If you run a modified version
as a network service, the AGPL requires you to offer its source.

Third-party attributions are in [NOTICE.md](NOTICE.md).

## Acknowledgements

- [Vimium](https://github.com/philc/vimium) — the browser extension's
  element-detection heuristics are derived from it (MIT).
- [OmniParser](https://github.com/microsoft/OmniParser) — the on-device
  icon-detection model.
- [Homerow](https://homerow.app) — prior art and inspiration for
  keyboard-driven clicking on macOS.
