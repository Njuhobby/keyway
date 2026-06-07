# axdump

A standalone macOS dev tool that dumps an app's **complete, unfiltered
Accessibility (AX) tree** to stdout. It's the ground-truth instrument for
Mouseless's **AX-coverage** work.

## Why it exists / why it's separate

Mouseless serves clickable elements from three sources: AX walk (whitelist
apps), the browser extension (DOM), and OmniParser (vision) for everything
else. To widen the moat we want to reclaim "AX-weak" apps (Slack, Discord,
VS Code, WeChat, …) — but the right fix differs per app:

- the element **is** in the AX tree, the hint walker just doesn't reach it
  (wrapped in unmarked `AXGroup`s, action-less but clickable rows) →
  fixable with a per-app AX predicate rule;
- the element is **genuinely absent** from the AX tree → AX rules can't
  help; must stay on OmniParser.

The design docs *disagree* on which case Slack is. So before building
anything, **measure**: dump the real tree and look. This tool does only
that. It lives in its own SwiftPM project (not inside the Mouseless app) so
it adds zero runtime cost / no trigger-key, and builds to a stable path you
grant Accessibility once.

Unlike Mouseless's `HintMode` walk, axdump applies **no filtering** — no
role allow-list, no visibility/size pruning, no depth cap. Every node is
printed so wrapped/irregular elements are visible.

## Build

```bash
cd axdump
swift build
```

Binary: `.build/arm64-apple-macosx/debug/axdump` (also `.build/debug/axdump`).

## One-time Accessibility grant

AX queries require the calling process to be trusted. On first real run a
system prompt appears; or add it manually:

> System Settings → Privacy & Security → Accessibility → **+** → select
> `axdump/.build/arm64-apple-macosx/debug/axdump`

The `.build` path is stable across rebuilds, so you only grant it once.
(`--list` / `--help` work without the grant; only the actual dump needs it.)

## Usage

```bash
# By app name or bundle-id substring (case-insensitive):
.build/debug/axdump Slack > /tmp/slack.txt
.build/debug/axdump com.microsoft.VSCode > /tmp/vscode.txt

# Frontmost app after a countdown (switch to it meanwhile):
.build/debug/axdump --frontmost 4 > /tmp/whatever.txt

# See what's running (no AX grant needed):
.build/debug/axdump --list
```

Output goes to stdout (redirect to a file); progress/errors go to stderr.

## Output format

A summary header, then every window's tree, one node per line:

```
# AX dump — Slack (com.tinyspeck.slackmacgap, pid 1234)
# windows: 1
# nodes: 3812, with AXPress/AXOpen: 274
# roles: AXGroup×2901, AXStaticText×410, AXButton×120, …
# format: <indent><role>[<subrole>] "label" actions=[…] rect=(x,y w×h) en=N id=… SELECTED

== window[0] "Slack — general" ==
AXWindow "Slack — general" rect=(0,0 1440×900)
  AXGroup rect=(...)
    AXButton "Compose" actions=[AXPress] rect=(...)
    ...
```

Reading it for AX-coverage decisions:
- **`actions=[…]` with `AXPress`/`AXOpen`** is the key signal — an element
  the AX layer considers clickable. If the thing you want to click shows up
  with `AXPress`, a per-app rule can surface it.
- An element present but with **no actions and no meaningful label**, buried
  under `AXGroup`s, often still corresponds to a clickable control → a
  per-app predicate (by subrole / identifier / position) can claim it.
- If the control you want **doesn't appear at all** anywhere in the tree,
  AX can't serve it — that app stays on OmniParser.
