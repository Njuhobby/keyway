# Hint Rendering & Click Commit

Label generation, user input through to click commit, overlay drawing, HUD prompts.

Related files: `HintMode.swift` (generation + commit + synth click), `HintOverlay.swift`, `HUD.swift`.

---

## 1. Label generation

`HintMode.alphabet`:
```swift
static let alphabet: [Character] = [
    "a","s","d","f","g","e","r","u","i","w","t","n","m",
]
```
13 letters. **Excludes h/j/k/l/v/c/o/p** — h/j/k/l are the hjkl cursor-movement keys in both TAP and SCROLL, `v` is the "enter DRAG sub-state" trigger key in TAP normal, `c` is the "click at current cursor position" trigger key; pressing any of them bare already has a dedicated meaning and they can't double as hint labels (see `modes.md` §4 / §6). `o`/`p` are dropped because reaching out with the right pinky is too awkward — and in the two-letter tier the generator pairs every key with every other key, so `o`/`p` would appear frequently as both the first *and* the second character, which is exactly where the pinky suffers most. Every other comfortable letter besides these eight is included. The order is hand-feel-front-loaded (left-hand home row `a s d f g` first), because single-letter labels take a `prefix` slice and the shortest labels commit fastest.

**History**: the pool capacity has bounced between 16/17/15/13 over several rounds. `v` was briefly included (17 letters, back when DRAG was either still a separate mode entered via a `Caps Lock + v` chord); after DRAG was absorbed into a TAP sub-state and bare `v` was repurposed as the enter-DRAG trigger key, it was removed again (16). The `c` round: originally Enter was the click key and `c` stayed in the pool; Enter frequently collided with an app's menu confirmation / form submission (swallowed by Keyway), so after letting Enter pass through and moving the click onto bare `c`, `c` was also removed from the pool (15). The most recent round: `o`/`p` were dropped because the right-pinky reach feels bad (13), at the cost of dropping the ultra-dense-screen capacity from 225 to 169 (`maxTargets` lowered to 169 to match).

**Letter group** (shared by the focused app + menu extras), all labels in a single scan are **equal length** — mixing lengths causes prefix collisions ("aa" is a prefix of "aaa", so typing "aa" stalls waiting for a third character):
- count ≤ 13: single letter
- 14–169: two letters (13 × 13)
- 170+: three letters — **actually unreachable**: `maxTargets` is 169 = 13², so any single scan lands in ≤2 letters. The three-letter branch exists only as a safety net for when the pool/cap changes.

**Number group** (Dock-exclusive):
- count ≤ 10: single character `0, 1, ..., 9`
- count > 10: two characters `00, 01, ..., 99`

The benefit of independent letter / number spaces: typing `a` immediately locks in the letter group, typing `1` immediately locks in the Dock, and prefixes never collide.

The benefit of two-letter / two-number labels: the first character filters once, the second character commits; on a mis-press the prefix doesn't match and `.ignored` swallows it (no false trigger, and no exit).

**Label assignment = cross-scan rect identity matching + spatial-order fallback (label stability)**: each pool (Dock numbers / everything-else letters) runs two passes (candidates are first sorted by quantized (y, x) reading order, guaranteeing determinism):
1. **preserve**: each candidate looks for the **geometrically nearest** target in the previous scan's targets (center-point distance ≤ `posTol=8px` and each side's dimension within ±`sizeTol=25%`); on a match it **reuses that old label**. This is the real source of label stability — if the element hasn't moved it keeps its label, even if everything else on screen changed.
2. **fill (fallback)**: those that didn't match (first scan / genuinely newly appeared elements) take the remaining labels in spatial reading order.

Matching is **purely geometric** — it doesn't look at role or source, so the OP path (where all boxes share the constant role `"AXOmni"` and have no meaningful role) and AX are treated identically. `posTol=8px` is enough to absorb the few-pixel jitter OP produces each time, yet far smaller than list row spacing (WeChat ~70px), so adjacent rows won't be mismatched. Screen-absolute coordinates (not window-relative) suffice: sticky rehint fires ~100ms after the click while the window hasn't moved, so a stationary element's absolute rect is a stable anchor (if the window is dragged its contents re-emit labels, a graceful degradation; OP also has no window ref to convert against).

> **History**: it once used spatial sorting only (no identity matching). The failure cause was precisely that label = the Nth position in reading order ⇒ the Nth position depends on "how many elements are sorted ahead of it." After opening another conversation in WeChat **the left conversation list didn't move by a single pixel**, but the right message area swapped in a screen's worth of bubbles; the bubbles' y values interleave with the left column's rows, so a full-screen one-pass label assignment shoved all downstream labels (including the unmoved left column) out of position and reshuffled them. Spatial sorting can't cure "something elsewhere changed and dragged the unchanged along with it" — only pinning unmoved elements back to their old labels by rect works. Spatial sorting was therefore **demoted** from a "stability mechanism" to "giving new elements that have no prior to match against a deterministic dealing order" (otherwise new elements fall back to OmniParser's non-deterministic confidence order and jitter again).

>
> **Passing prior across instances**: sticky rehint goes through `rehintSticky`, which `new`s a fresh `HintMode` and needs to be fed the old scan. Gotcha: hint commit in `handle()` **first calls `deactivate()` (clearing `targets`), then** 100ms later calls `scheduleStickyRehint`, so by the time the rehint runs the live `targets` are long gone. So a separate copy `lastScanTargets` is kept (written at the end of each `applyCollected`, and **`deactivate()` does not clear it**, same lifecycle as `lastCommittedTarget`); `snapshotTargets()` returns it, `seedPriorTargets()` seeds it into the new instance, so the preserve pass has a prior to match against (on app switch `fromAppSwitch` it is **not** seeded — the old app's rects are unrelated to the new app). `refreshInPlace` is the same instance and doesn't need it — `self.targets` is already the prior.

Dock targets enter the `targets` array first, non-Dock after; drawing is positioned entirely by each target's own rect (the array order only affects the typing-filter traversal, not position).

---

## 2. Typing → Commit state machine

`HintMode.handle(char:action:)`:

```swift
let next = typed + String(char)
let matches = targets.filter { $0.label.hasPrefix(next) }
if matches.isEmpty {
    return .ignored          // mis-press: swallow, typed unchanged, stay in TAP
}
if matches.count == 1 && matches[0].label == next {
    if moveArmed {                         // `'` prefix armed move-only
        commit(target: matches[0], action: .move)   // warp, no click
        typed = ""; moveArmed = false; renderOverlay()
        return .moved                      // stay in TAP, hints not dismissed
    }
    commit(target: matches[0], action: action)
    deactivate()
    return .committed
}
typed = next
renderOverlay()
return .pending
```

The four return values are handled by `VimSession.handleTap`:
- `.pending` — do nothing, wait for the next key
- `.committed` — check sticky: if true, re-scan into a new HintMode; if false, exit
- `.ignored` — mis-press (doesn't match any hint prefix): swallow without exiting, `typed` keeps its last valid value. Exit is only via Esc. (There's also `backspace()` to undo already-typed prefix characters.)
- `.moved` — move-only pick (`'` prefix, see `modes.md` §4.3.5): the cursor has already warped, hints stay, and **regardless of sticky it stays in TAP** (move is navigation, not a terminal action). Since nothing changed after the move → no rescan, the same batch of targets is instantly re-displayed.

---

## 3. Commit: pure synthesized mouse event

```swift
private func commit(target: HintTarget, action: ClickAction) {
    let center = CGPoint(x: target.rect.midX, y: target.rect.midY)
    switch action {
    case .left:
        synthesizeClick(at: center, button: .left,  count: 1)
    case .right:
        synthesizeClick(at: center, button: .right, count: 1)
    case .double:
        synthesizeClick(at: center, button: .left,  count: 2)
    case .move:
        MouseSynth.warp(to: center)   // move cursor only, no click (`'` prefix, see modes.md §4.3.5)
    }
}
```

**The single universal commit mechanism = synthesize a mouse event to the rect center**. Simple, predictable, and consistent with the user's mental model ("press hint = click the mouse here"). `.move` is the exception: `MouseSynth.warp` (a synthesized `.mouseMoved`) moves the cursor over without clicking, treating the hint as a cursor-teleport anchor. A `.move` from an OP source likewise OCR-refines first, then warps.

### 3.1 Why not AX actions

The early implementation was "AXPress first / synth fallback." **Abandoned** — AX actions are unreliable enough that they don't belong on the main path:

- **AX metadata is reliable** (element existence, rect, role, label — these are the bedrock of how a hint target is found in the first place).
- **AX actions are unreliable**: many controls expose `AXPress` in their actions list but the handler is a no-op or has the wrong semantics — NSBrowser cells, NSTableRowView, custom NSViews, Electron's AX bridge all fall into this category. **Only after enough observed "hint appeared, pressed it, nothing happened" cases was the decision made to cut it.**
- `AXShowMenu` has the same problem — some elements expose it but calling it doesn't pop a menu.
- `AXOpen` (used by Finder desktop icons) has the same problem — a synthesized single click + Finder's double-click habit is enough, it isn't needed.

### 3.2 Trade-offs of cutting AX actions

| Dimension | Old AX-first path | New synth-only path |
| --- | --- | --- |
| Standard control (Button / Link) | AXPress hits | synth single click hits (a real mouse click does work) |
| Custom / complex control | AXPress fails silently → unpredictable fallback | synth single click, same effect as a real mouse click |
| Occluded / off-screen element | AX can click it | can't be clicked |
| Mouse cursor | AX path doesn't move it; synth path does | **always moves to the click point** |
| Failure mode | two of them (AX hit no effect / synth hit no effect), hard to diagnose | one (synth hit no effect, a hit-test problem in the element itself) |

Occluded elements are lost — but our `onScreen` filter already keeps only visible elements to begin with. That theoretical benefit doesn't apply.

The cursor moving — is a **good thing**, not a downside, consistent with "press hint = put the mouse there and click once."

`.double` is the same as before — AX has no double-click action, so it has always gone through the synthesis path.

---

## 4. Synthesized-click implementation

```swift
private static func synthesizeClick(at point: CGPoint,
                                    button: CGMouseButton,
                                    count: Int) {
    let src = CGEventSource(stateID: .privateState)
    let downType: CGEventType = (button == .left) ? .leftMouseDown : .rightMouseDown
    let upType: CGEventType = (button == .left) ? .leftMouseUp : .rightMouseUp

    for clickIdx in 1...count {
        let down = CGEvent(mouseEventSource: src, mouseType: downType,
                           mouseCursorPosition: point, mouseButton: button)!
        let up = CGEvent(mouseEventSource: src, mouseType: upType,
                         mouseCursorPosition: point, mouseButton: button)!
        for ev in [down, up] {
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(clickIdx))
            ev.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
            ev.post(tap: .cghidEventTap)
        }
    }
}
```

Key points:
- `.mouseEventClickState` — the critical field for double-click. The first down/up pair sets 1, the second sets 2. The system recognizes the double-click from this.
- `eventSourceUserData = "MOUS"` — lets the HotkeyTap callback pass it through (see `event-pipeline.md`).
- `CGEventSource(stateID: .privateState)` — an isolated event source that doesn't pollute the global modifier flags.

---

## 5. HintOverlay window

```swift
for screen in NSScreen.screens {
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, ...)
    w.level = NSWindow.Level(rawValue: 102)   // CGOverlayWindowLevel, above .popUpMenu = 101
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    w.contentView = HintOverlayView(...)
}
```

**One independent window per screen**. A single window with a cross-screen union frame was tried — it dropped frames / didn't render on non-primary screens. Multiple windows are stable.

**Rebuild on display change**: these per-screen windows are sized/positioned by the screen frame at build time, and built once then cached. The moment the display configuration changes (lid closed, external display plugged/unplugged, resolution changed), the old windows no longer cover the new screens, and the coordinate conversion in `draw` based on `NSScreen.screens.first` + window origin is also misaligned → hint rendering is clipped/offset until restart. On each `show`, `ensureWindows` compares the current `NSScreen.screens.map(\.frame)` against "the screens the windows were last built for" (`builtForScreens`); if they differ, it tears down the old windows and rebuilds — negligible cost (an equality comparison of 1–3 CGRects, far smaller than the preceding AX scan). The HUD doesn't need this; it re-positions against `NSScreen.main` on every `show` and self-corrects.

### Window level

| level | value | who's here |
| --- | --- | --- |
| `.normal` | 0 | ordinary app windows |
| `.modalPanel` | 8 | modal dialogs |
| `.mainMenu` | 24 | top menu bar |
| `.statusBar` | 25 | early overlay used this |
| `.popUpMenu` | 101 | dropdown menus / popovers |
| `CGOverlayWindowLevel` | **102** | **our overlay** + HUD |
| Assistive tech | 1500 | VoiceOver and other accessibility overlays |

The semantics of choosing **102**: above every ordinary UI layer (menu bar, modal, `.popUpMenu` dropdown menus), but below assistive tech, so hint labels are also visible on top of an open dropdown menu — previously when using `.statusBar` (25) the inside-top-left label of an AXMenuItem would be covered by the menu container's background fill (the menu container is at 101, the label is drawn at 25 → overwritten). The cost is that hint labels also draw on top of a modal alert, which is what's wanted in TAP mode (the buttons of a hint-click alert). See §7.2 for details.

`ignoresMouseEvents = true`: the overlay doesn't consume mouse input, so clicks pass through to the underlying app.

`canJoinAllSpaces + stationary + ignoresCycle`: follows Space switches, doesn't appear in Mission Control thumbnails, doesn't participate in Cmd+Tab.

### Show / hide: never `orderOut`

`hide()` does **not** `orderOut` the window — it clears the content (`update(targets: [])`) and leaves the window resident (transparent, click-through, drawing nothing).

This is load-bearing. `orderOut` drops the window's all-spaces registration in the window server; the next `orderFront` can then re-attach it to whichever Space it was *last shown on* rather than the active one, so hints render on the **wrong Space**. Whether that happens is a race against the Space-switch animation (intermittent to trigger). Once it happens the window is stuck there, and it stays stuck: the obvious self-heal — "after `orderFront`, if `!isOnActiveSpace` force re-registration" — never fires, because `isOnActiveSpace` reports `true` for a `canJoinAllSpaces` window even when the server has it pinned to one Space. So re-entering hint mode never recovered; only an app restart did.

Keeping the window resident means the all-spaces registration is never dropped, so it always follows you. An empty overlay draws nothing — no visual or screen-capture effect between sessions. The same "resident, hide by clearing" rule applies to `ScrollOverlay`, `SearchOverlay`, `WindowOpOverlay`, and `HUD` (all previously used `orderOut`; `HUD` also had a no-op `collectionBehavior`-reassert "guard" that never re-registered anything).

---

## 6. Coordinate-system conversion

Three coordinate systems clash:

| System | Origin | Y direction |
| --- | --- | --- |
| AX | top-left of primary screen | downward |
| NSScreen global | bottom-left of primary screen | upward |
| NSView local | bottom-left of the view | upward |

`HintOverlayView.draw` has to convert every target:

```swift
let primaryH = primary.frame.height
let winOrigin = win.frame.origin         // this screen's NSScreen origin
let r = target.rect                      // AX coordinates
let nsGlobalY = primaryH - (r.origin.y + r.size.height)  // AX → NSScreen global Y
let viewX = r.origin.x - winOrigin.x     // NSScreen global → view local X
let viewY = nsGlobalY - winOrigin.y      // NSScreen global → view local Y
```

`winOrigin` is **this** screen's NSScreen origin — it must be subtracted to land in this view's local coordinates.

---

## 7. Four badge layouts

`HintOverlayView.draw` routes by priority: Dock (numeric labels) → AXMenuItem → **rects big enough use inside placement** → everything else a speech bubble. After positions are computed there's one more **de-collision** pass (§7.5) that moves overlapping labels apart.

### 7.1 Dock items (label's first character is a digit)

The badge is a tailed square (20×20), drawn **outside** the icon with the tail pointing back at it. The position depends on the Dock orientation:

```swift
let dockOrientation = UserDefaults(suiteName: "com.apple.dock")?
    .string(forKey: "orientation") ?? "bottom"
```

| orientation | badge position | tail direction |
| --- | --- | --- |
| `bottom` | above the icon | points down |
| `left` | right of the icon | points left |
| `right` | left of the icon | points right |

The badge centers its text (the others are left-aligned).

### 7.2 `AXMenuItem` (dropdown menu item) — inside top-left

Goes through the **same inside-top-left placement** as the large rects in §7.3 below (top-left corner inside the rect, 4pt horizontal inset, vertically flush to the top, no tail). An earlier version had a separate "default left, fall back to right, special handling for cascade menus" logic; after unifying on inside, that whole pile of "cascade-probe the left/right sibling columns" code was deleted.

**The premise is that the overlay must be above `.popUpMenu`** (level 102, see §6). The reason: a menu item's visual background is drawn by the **menu container**, that `.popUpMenu` (level 101) window, which includes the strokes between menu items and the selected highlight. Our label is drawn inside the menu item's rect; if the overlay is at the `.statusBar` (25) level, below the menu container, the menu container's background fill covers the label leaving only blank space; once the overlay is raised to 102, the small yellow-backed square of the label floats above the menu container, while the rest of the area (menu text / icon / selected highlight) is drawn by the menu container itself and shows through the overlay's transparent regions, with no conflict.

**`contains` vs `intersects`**: use `viewBounds.contains(rect)` to strictly judge "the badge is fully on screen," not `intersects`. Partially out-of-bounds would be clipped and unreadable.

### 7.3 Inside placement (rect big enough — applies to both AX and OP)

For a non-Dock target, as long as the rect is ≥ **30pt wide × 16pt tall**, the badge is drawn at the rect's **top-left corner inside** (4pt horizontal inset, flush to the top, no tail). AXMenuItem also goes through here (see the special note in §7.2).

Why: the speech bubble (§7.4) + tail, on dense lists (Finder file rows, OP chat bubbles), floats in the gap between adjacent rects with unclear ownership — you can't tell whether the badge belongs to the row above or the row below. Placing it inside the rect makes ownership obvious at a glance, and that small, ugly tail is saved too.

Origin of the threshold: horizontally needs 4pt×2 + 22pt label width = 30pt; vertically flush to the top (0 inset), because the AX rect for Finder's date/size columns is only ~14-16pt tall, and any positive vertical padding would kick them back to a speech bubble (exactly the "floating between rows" problem inside placement is meant to solve). Anything below the threshold (small toolbar icons) falls to §7.4.

### 7.4 Speech bubble (rect too small to fit inside)

A 22×16 badge rectangle + a tail triangle. By default **below** (tail points up); if it doesn't fit, flip **above** (tail points down). Fit is again judged with `contains`. Only targets below the §7.3 threshold go through here.

### 7.5 De-collision

In §7.1-7.4 each label's position is **computed independently, without looking at other labels**, so on a dense page (web toolbars / icon grids / nav bars, most pronounced on Chrome) labels stack on top of each other and become unreadable. The user **reads the label text and then types it**, so a covered label is effectively useless — therefore "readable" takes priority over "precisely hugging the element."

`draw` is therefore split into **three passes**:

1. **Compute positions**: per §7.1-7.4, compute each visible label's `fillRect` (logic unchanged), collected into `[Placed]` (not drawn immediately).
2. **De-collision**: greedy. Maintain `occupied: [NSRect]`, and for each label check whether it collides with "those already placed" (intersection, with a 1pt gap to prevent edge-touching); on a collision, find the nearest free spot nearby and move it there (`nudgeToFree`: an offset grid of radius 3 × (labelW, labelH), sorted by distance from the original position near→far, the first one that's free and on-screen wins; if nothing's found within the radius → give up, accept the overlap, better than flinging the label far away). A moved label **drops its tail** (the connector would point wrong). Append the final position into `occupied` — later labels compare against the **post-move** positions of the earlier ones (greedy rolling, no backtracking).
3. **Draw**.

**Dock labels don't participate in de-collision** (they're outside the icon grid, rarely collide, and moving them away would detach them from their tail, looking worse).

**Performance**: O(n²) (each compares against all before it), but n≤`maxTargets`(169), rendered once (not per frame), and the operation is a cheap rect intersection (a few float comparisons). Measured sub-millisecond; a pathological all-collide case is only ~10ms. If it were ever genuinely slow, spatial bucketing (broad-phase) could bring it down to ~O(n), but at this n that's unnecessary.

---

## 8. Visual details

```swift
let bg = NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 0.95)   // yellow background
let attrsBlack: ... = [NSColor.black, monospaced 11pt bold]        // not-yet-typed part
let attrsDim: ...   = [NSColor.black.withAlphaComponent(0.30), ...] // already-typed prefix
```

- **Background**: yellow α=0.95 (high visibility, low conflict with most macOS UI colors)
- **Font**: monospaced 11pt bold, monospacing ensures a two-character label's width is predictable
- **Already-typed prefix**: 30% black (visually dims the "confirmed" characters), the not-yet-typed part is pure black
- **Corner radius**: badge rectangle xRadius/yRadius = 3
- **Tail**: a triangle, base ~8px, tip ~5px, filled with the same yellow as the badge

How the typed part + rest part are aligned when drawing:
```swift
let typedSize = (typedPart as NSString).size(withAttributes: attrsDim)
let restSize = (restPart as NSString).size(withAttributes: attrsBlack)
let totalW = typedSize.width + restSize.width

if isDockLabel {
    textX = fillRect.midX - totalW / 2   // centered
} else {
    textX = fillRect.minX + 3            // left-aligned + 3px padding
}
```

---

## 9. HUD

A standalone bottom-right mode-indicator window (not part of the overlay).

```swift
let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 44), ...)
w.level = .statusBar       // same as overlay
w.hasShadow = true         // overlay has no shadow, HUD does
w.ignoresMouseEvents = true
// position: bottom-center of the primary screen's visibleFrame
w.setFrameOrigin(NSPoint(x: f.midX - 80, y: f.minY + 80))
```

The text is computed centrally in `VimSession.renderModeHUD()`:
- TAP mode → `"TAP"` or `"TAP · sticky"`
- Command palette → `":"`, `":q"`, `":xx"`

Style: semi-transparent black background (alpha 0.78), white text 14pt monospaced semibold, corner radius 10px.

`orderFrontRegardless()`, **not** `makeKeyAndOrderFront` (the latter would steal focus → the currently focused app loses focus → AX can no longer get the target element).

---

## 10. Cross-screen elements

If a target's rectangle isn't within the current view's bounds (e.g., the focused app is on another screen), each branch will `continue` and skip drawing.
This is exactly why there's one independent HintOverlayView per screen: each view only draws the hints that land on its own screen, routing automatically.

The check:
```swift
if !self.bounds.intersects(fillRect) { continue }
```
Note it's `intersects`, not `contains` — an element straddling the screen boundary, drawn as half on each of two screens, is better than not drawn at all.
