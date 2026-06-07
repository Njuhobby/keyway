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

# Cold vs woken — does waking Electron a11y populate the tree?
.build/debug/axdump        "Code" > /tmp/vscode-cold.txt
.build/debug/axdump --wake "Code" > /tmp/vscode-woken.txt

# See what's running (no AX grant needed):
.build/debug/axdump --list
```

### `--wake` — can AX serve an Electron app?

Chromium/Electron apps (VS Code, Slack, Discord, Notion, Obsidian, Spotify)
build their accessibility tree **lazily** — only when an assistive
technology is detected. Cold, their AX is nearly empty (so Mouseless falls
back to OmniParser). `--wake` sets `AXManualAccessibility` (Chromium's flag)
+ `AXEnhancedUserInterface` (AppKit's "an AT is present") on the app, waits
~1.5s for the renderer to build the tree, then dumps.

Compare the `▶ would hint` count cold vs `--wake`: if it jumps from a
handful to "everything you'd click", AX **can** serve that app once woken —
and AX (labelled, precise rects, `AXPress`) beats the OmniParser vision
path. That's the decision input for "wake-then-AX vs OP" per app.

Output goes to stdout (redirect to a file); progress/errors go to stderr.

## Output format

A summary header, then every window's tree, one node per line. The first
column is a **`▶` marker** when Mouseless's *current* hint logic would turn
that node into a hint target (see below):

```
# AX dump — Slack (com.tinyspeck.slackmacgap, pid 1234)
# windows: 1
# nodes: 3812, with AXPress/AXOpen: 274
# ▶ Mouseless would hint: 96  (mirrors HintMode; grep '^▶')
#   approximations: 169-target cap and closed-AXMenu nuance NOT applied
# roles: AXGroup×2901, AXStaticText×410, AXButton×120, …
# format: <▶|·> <indent><role>[<subrole>] "label" actions=[…] rect=(x,y w×h) en=N id=… SELECTED
#         ▶ = Mouseless's current logic would mark this a hint target

== window[0] "Slack — general" ==
   AXWindow "Slack — general" rect=(0,0 1440×900)
     AXGroup rect=(...)
▶      AXButton "Compose" actions=[AXPress] rect=(...)
       AXStaticText "general" rect=(...)
```

### The `▶` marker — "what Mouseless catches"

Each line is tagged `▶` iff Mouseless's hint walker would mark it, mirroring
`HintMode`: reachable (depth < 12, parent not an `AXStaticText`/`AXImage`/
`AXProgressIndicator` it won't recurse into, subtree on-screen + within the
window), enabled, ≥ 8×8, has a meaningful label, and is clickable (role in
the allow-list **or** advertises `AXPress`/`AXOpen`) — plus the `AXRow`
source-list fallback. (Kept in sync with `HintMode.swift`; the 169-target
cap and the menubar-only closed-`AXMenu` nuance are not replicated.)

So the dump shows two things at once:
- `▶` lines = **what Mouseless hints today**.
- un-`▶`'d lines that are clearly interactive = **the gap** — the
  AX-coverage opportunity.

Reading it for AX-coverage decisions (`grep '^▶'` for the caught set):
- A control you want to click that's **un-`▶`'d but has `AXPress`/`AXOpen`**
  (or sits under an `AXImage`/`AXGroup` Mouseless doesn't reach) → a per-app
  rule can surface it.
- A control present with **no actions and no meaningful label**, buried in
  `AXGroup`s, often still maps to something clickable → a per-app predicate
  (by subrole / identifier / position) can claim it.
- A control that **doesn't appear at all** anywhere in the tree → AX can't
  serve it; that app stays on OmniParser.
