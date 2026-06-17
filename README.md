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

<!-- HERO DEMO — replace with docs/demos/hero.gif once recorded -->
<!-- <img src="docs/demos/hero.gif" width="720" alt="Keyway in action"> -->

> ⚠️ _Hero demo coming soon — the single most important thing to record._

</div>

---

Press a trigger key. Every clickable thing on screen sprouts a short letter
label. Type the label — it clicks. That part isn't new. The twist is
**coverage**: Keyway finds targets not only in native Cocoa apps (via the
Accessibility API) but also inside **Electron apps, web views, and arbitrary
pixels** — by falling back to an on-device vision model — and inside **web
pages** via a companion browser extension that reads the DOM directly.

That "AX black hole" — Slack, VS Code, Discord, anything Electron — is where
keyboard-driven clicking usually falls apart. Keyway is built to cover it.

## See it in action

> 🎬 _Demos are being recorded. Each slot below describes exactly what its
> clip will show — drop the GIF into `docs/demos/` and uncomment its line._

<table>
<tr>
<td width="50%" valign="top">

**1 · Hint mode — the core loop**
<!-- <img src="docs/demos/hint-mode.gif" alt="Hint mode"> -->
_Caps Lock in a native app → labels bloom on every button → type two keys →
it clicks. Left-click, and right-click with a modifier._

</td>
<td width="50%" valign="top">

**2 · The Electron black hole** ⭐
<!-- <img src="docs/demos/electron.gif" alt="Electron coverage"> -->
_Slack / VS Code, where the Accessibility API returns almost nothing — yet
every clickable region still gets a label, from the on-device vision model.
This is the wedge._

</td>
</tr>
<tr>
<td width="50%" valign="top">

**3 · Scroll & window management**
<!-- <img src="docs/demos/scroll-windows.gif" alt="Scroll and windows"> -->
_Modeless `d`/`u`/`gg`/`G` scrolling, then move and half-snap a window —
all without the mouse._

</td>
<td width="50%" valign="top">

**4 · It follows you**
<!-- <img src="docs/demos/follow.gif" alt="Sticky re-hinting"> -->
_Switch apps, switch Spaces, or wait for content to load — hints re-appear on
their own the moment the screen settles._

</td>
</tr>
<tr>
<td width="50%" valign="top">

**5 · Web pages, precisely**
<!-- <img src="docs/demos/web.gif" alt="Browser extension hints"> -->
_The browser extension reads the DOM directly — pixel-perfect hints on a real
page, including links inside an iframe._

</td>
<td width="50%" valign="top">



</td>
</tr>
</table>

## What it can do

| | |
|---|---|
| 🎯 **Hint mode** | Label every clickable element, type the label to click (left, or right-click with a modifier). The core interaction. |
| 🕳️ **Beyond native AX** | Electron (Slack, VS Code, Discord), WebViews and Catalyst apps expose almost nothing to the Accessibility API. Keyway fills that black hole with an on-device [OmniParser](https://github.com/microsoft/OmniParser) vision model. |
| 🌐 **Real web pages** | A browser extension reads the DOM directly for precise, iframe-aware hints. |
| 📜 **Scroll · windows · drag** | Separate keyboard modes for scrolling, window move/resize, and dragging — plus Vimium-style modeless scrolling on web pages. |
| 🧲 **Sticky** | Re-hints as content loads, you switch apps, or you change Spaces — by watching for the screen to settle. |
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
