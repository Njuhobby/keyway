# Mouseless

> Drive your Mac entirely from the keyboard.

Mouseless is a macOS keyboard layer that lets you do with the keyboard what
you'd normally reach for the mouse: click anything, scroll, drag, move and
resize windows — without your hands leaving the home row.

Press a trigger key, every clickable thing on screen gets a short letter
label, you type the label, it clicks. The twist is **coverage**: Mouseless
finds targets not just in native Cocoa apps (via the Accessibility API) but
also inside Electron apps, web views and arbitrary pixels — by falling back
to an on-device vision model — and inside web pages via a companion browser
extension reading the DOM directly.

> **Status: early prototype / research project.** It works and is usable
> daily, but it is rough, unsigned, and the code lives under `prototype/`.
> Expect sharp edges. Built in the open to share the approach.

<!-- TODO: demo GIF here — the single most important thing to add before sharing. -->

## What it can do

- **Hint mode** — label every clickable element, type the label to click
  (left click, or right click with a modifier). The core interaction.
- **Coverage beyond native AX** — Electron (Slack, VS Code, Discord),
  WebViews and Catalyst apps expose almost nothing useful to the
  Accessibility API. Mouseless fills that "AX black hole" with an on-device
  [OmniParser](https://github.com/microsoft/OmniParser) vision model, and
  hints web pages through a browser extension that reads the DOM.
- **Scroll, window move/resize, drag** — separate keyboard modes, plus
  Vimium-style modeless `d`/`u`/`gg`/`G` scrolling on real web pages.
- **Follows you** — sticky mode re-hints as content loads, you switch apps,
  or you change Spaces, by watching for the screen to settle.

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

A couple of pieces that were interesting to build (see `prototype/specs/`):

- **Cheap "wait for the screen to settle" detection.** Many rehints (after a
  click, an app switch, a cross-Space slide) need to wait until the new
  content has actually rendered — but there's no event for that. Instead of
  guessing a fixed delay, Mouseless polls a tiny (64×36) grayscale
  fingerprint of the window and rehints the moment two frames match. One
  scan, timed to the content, not to a guess.
- **Caps Lock as the trigger** without a kext: `hidutil` remaps Caps Lock to
  F19 at the HID layer (macOS doesn't deliver Caps Lock as a normal keyDown),
  applied on launch and reverted on quit.

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon
- A Swift toolchain (Xcode or the Swift command-line tools)
- Two permissions, **both required** (granting either needs a restart to
  take effect — macOS caches them per process):
  - **Accessibility** — to read the AX tree and synthesize clicks/keys
  - **Screen Recording** — for the vision fallback and the settle detection

## Build & run

```sh
cd prototype
./run.sh        # swift build + ad-hoc re-sign + (re)launch
```

A `M` icon appears in the menu bar: `M●` ready, `M⚠` a permission is
missing. Press **Caps Lock** to enter hint mode.

On first launch macOS prompts for the two permissions. Enable Mouseless in
**System Settings → Privacy & Security** for both, fully quit, and rerun.

> `run.sh` ad-hoc re-signs the binary so the permission grant survives
> rebuilds, and Mouseless auto-remaps Caps Lock → F19 on launch and restores
> it on quit. See [`prototype/SPECS.md`](prototype/SPECS.md) for the full
> setup, the mode reference, and the architecture deep-dives under
> `prototype/specs/`.

### Browser extension (optional, for web-page hints)

Load `prototype/extension/` as an unpacked extension (Chrome:
`chrome://extensions` → Developer mode → Load unpacked; Firefox: build with
`build-firefox.sh`, then load via `about:debugging`) and install the
native-messaging host with the provided script. Without it, web pages still
work through the vision fallback, just less precisely.

## Permissions & privacy

Mouseless runs entirely on your machine. **No telemetry, no network calls**
other than the local socket between the app and the browser extension. The
permissions are used only for what's described above; screen captures are
processed in memory and not written to disk (outside an opt-in debug flag).

## License

**[AGPL-3.0-or-later](LICENSE).** Mouseless bundles an icon-detection model
derived from [OmniParser](https://github.com/microsoft/OmniParser) (built on
Ultralytics YOLO), whose weights are AGPL-licensed; the AGPL applies to the
combined work, so the whole project is AGPL-3.0. If you run a modified
version as a network service, the AGPL requires you to offer its source.

Third-party attributions are in [NOTICE.md](NOTICE.md).

## Acknowledgements

- [Vimium](https://github.com/philc/vimium) — the browser extension's
  element-detection heuristics are derived from it (MIT).
- [OmniParser](https://github.com/microsoft/OmniParser) — the on-device
  icon-detection model.
- [Homerow](https://homerow.app) — prior art and inspiration for
  keyboard-driven clicking on macOS.
