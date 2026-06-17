# Hint Discovery

Which UI elements can get a hint, and how we find them.

Related files: `HintMode.swift` (`collectAll`, `walk`, `walkMenuBar`, `batchFetch`, `collectDirectMenuExtras`), `HintWindowCache.swift`, `MenuExtraCache.swift`.

---

## 1. Three sources

`HintMode.collectAll()` scans three groups serially and returns the results bucketed — the bucket determines the label character set (digits / letters).

```swift
struct CollectedElements {
    let focused: [ElementCandidate]        // clickable elements inside the focused app
    let dock: [ElementCandidate]           // Dock icons
    let menuBarExtras: [ElementCandidate]  // status icons on the right side of the menu bar
}
```

Timing log (printed on every trigger, including IPC counts and cache hits):
```
[keyway] collect timings: focused=53ms (270 IPC, 0 window cache hit) dock=5ms (38 IPC) extras=31ms
```

Steady-state total time < 100ms. Known spike: after a destructive click (closing a dialog / closing a sheet), the first sticky rescan lands in the target app's AX cleanup window, and per-IPC latency jumps from ~0.2ms to ~40ms — see §5 for details.

---

## 2. Focused app (`focused`)

Entry point:
```swift
let sys = AXUIElementCreateSystemWide()
AXUIElementCopyAttributeValue(sys, "AXFocusedApplication" as CFString, &ref)
```

Get the focused app's root AX element, then recurse depth-first over `AXChildren`.

### 2.1 walk + batched attribute fetch

`walk()` recurses depth-first and sends **only one IPC per element**: it uses
`AXUIElementCopyMultipleAttributeValues` to grab 10 attributes at once
(role / enabled / position / size / title / description / help / value /
subrole / children), packed into a `BatchedAttrs` struct used in memory. See
`HintMode.batchFetch` for details.

This was the core change in the last round of performance work. The **old path**
made 9+ separate `AXUIElementCopyAttributeValue` calls per element, which for
apps like WeChat / Slack with hundreds of nodes in their AX tree meant thousands
of cross-process RPCs (focused-app scan ~840ms); after switching to batching,
the same tree is a few hundred (~200ms).

Constraints:

- `maxDepth = 12` — deep nesting (Slack / web pages) will exceed it; skip what we can.
- `maxTargets = 200` — hard cap per scan.
- `skipRoles = {AXStaticText, AXImage, AXProgressIndicator}` — the element itself
  is still evaluated as a candidate (Finder desktop files are `AXImage`), **we just
  don't descend into** the subtree. Subtrees of these roles almost never contain
  clickable elements, and recursing into them is expensive.
- **AXMenu subtree**: when role == `AXMenu` and its parent `AXMenuBarItem`'s
  `AXSelected` is false (a closed menu-bar dropdown) → return. Only the
  Dock right-click menu still triggers this; the focused app's menu bar goes
  through the separate `walkMenuBar` fast path (§2.4).
- **subtree bounds cull**: if a container's bounds are non-empty and don't
  intersect any screen → return. Zero bounds / missing bounds are not culled
  (the "unknown" sentinel for buggy SwiftUI/Electron containers).

### 2.2 Inclusion conditions

Candidate filters are ordered "cheap before expensive," because
`AXUIElementCopyActionNames` cannot be folded into batchFetch (it's not an
attribute query) and is an extra IPC for unknown roles. All cheap filters use the
batchFetch result, with the expensive one placed last:

1. `AXEnabled == true` (or the attribute is missing — most controls don't set it explicitly).
2. Rect ≥ 8×8 (pseudo-element filter).
3. Rect intersects the screen union (`onScreen`).
4. **Rect falls within the source window** (`withinWindow`, only effective for the
   focused-app walk). The walk entry point (`depth == 0` and `sourceWindow != nil`)
   grabs the window's own rect as `effectiveBounds` and passes it down through the
   recursion; every candidate must intersect it. **Why this is needed**: AX
   occasionally reports "rows scrolled out of the viewport" (typically: the Tags
   section under the Finder sidebar, the bottom half of a long table) whose rect is
   within the screen geometry but is actually below the window — `onScreen` doesn't
   filter it out, so the hint label gets pasted onto the content of the window
   behind it (observed in practice: Finder in front + Chrome behind, where the Tags
   section's virtual rows scattered hints onto Chrome's page). Dock / menubar /
   extras take the `sourceWindow == nil` path and skip this (they don't live in a
   "window"). Zero extra IPC: the bound simply reuses the `batchFetch` the root call
   was already going to do.
5. **Has a recognizable label** (`hasMeaningfulLabel`): any of `AXTitle / AXDescription /
   AXHelp / AXValue / AXSubrole` is non-empty.
   - Exception: `AXDockItem / AXMenuBarItem / AXMenuExtra` skip this
     (they're identifiable from position and role alone).
   - Without this filter, AX reports a lot of "phantom" elements — all labels
     empty, the app actually drew nothing — causing hints to appear on blank space.
6. **role is in `clickableRoles`**:
   ```
   AXButton, AXLink, AXMenuItem, AXMenuBarItem, AXMenuButton,
   AXCheckBox, AXRadioButton, AXPopUpButton, AXTab,
   AXDisclosureTriangle, AXDockItem, AXMenuExtra
   ```
   or `AXUIElementCopyActionNames` returns something containing `AXPress` / `AXOpen`.
   `AXOpen` is the action Finder desktop `AXImage` elements actually expose (instead of `AXPress`);
   without including it there's no way to click desktop files / folders.

#### Source-list `AXRow` fallback

Apple's NSOutlineView source lists (Finder / Mail / Notes / Music /
System Settings / Calendar sidebars, etc.) have a quirk: **the whole row is the
click target** (clicking triggers selection, the app writes `AXSelectedRows`), but
the row itself is neither in `clickableRoles` nor exposes `AXPress` / `AXOpen` — so
condition 6 fails, and walk by default **misses the entire sidebar column** (Finder
was like this early on: the sidebar had no hints at all).

Fix: after `walk()` finishes recursing an element's subtree, **if the role is
`AXRow` and nobody in the subtree became a candidate** (diff `out.count` before and
after entering the subtree), add the row itself as a candidate — a synth click to
its center selects that item.

Why "don't add the row when the subtree has a clickable descendant"? To avoid
double hints: in Finder's **main** file list, each row's `AXImage` child has
`AXOpen` and enters candidates via condition 6; in that case `out.count` has
already grown, the fallback skips the row, and the whole row keeps only the icon's
single hint.

Zero extra IPC: pure `out.count` comparison + one recheck of conditions 4-5
(cheap). One change made it all work — all the source-list app sidebars mentioned
above light up together.

### 2.3 Screen union computation

AX uses a top-left origin with Y increasing downward; NSScreen uses a bottom-left origin with Y increasing upward. `totalScreenSpan()` flips Y on each screen's NSScreen frame and takes the union:
```swift
let axRect = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
```
`primaryH = NSScreen.screens.first.frame.height`.

Returning `nil` (no screens) means all elements count as "on screen" — a degraded behavior rather than a crash.

### 2.4 Focused-app collect topology

The focused app's collect is not a single `walk(app)`, but processes the root's two
child sources separately, each via its cheapest path:

```swift
collect focused app:
  syncFocusedApp(pid)                    // switching apps clears the cache
  windows = read AXWindows attr
  cache.pruneTo(windows)                 // AXWindows diff
  for window in windows:
    if cache hit → reuse cached targets  // §2.5
    else        → walk(window), cache.store()
  menubar = read AXMenuBar attr
  walkMenuBar(menubar)                   // §2.6 fast path
```

We don't take `AXChildren` to grab all of the root's children directly, because we
want to handle the two kinds of child differently: windows go through the cache,
the menubar goes through the fast path, and dock / extras don't come from the
focused app at all (they take their own paths, §3 / §4).

> **Hints for right-click / popup menus are not supported.** Tried it: to hint a
> context menu popped up by right-click, you first have to find that `AXMenu` in
> AX. But in practice the **Finder desktop right-click menu simply isn't in
> Finder's AX tree** — neither the system-wide nor the app's `AXFocusedUIElement`
> is it, `AXChildren` doesn't contain it, and digging into the subtree (depth≤4)
> doesn't find it either. It's a system-level menu in a separate process, and AX
> can't reach it via the Finder path. So this feature was dropped (see that revert
> in the git history).

### 2.5 AXWindow cache (`HintWindowCache`)

**Problem**: a sticky rescan (the automatic rescan after clicking a hint) always
re-walks the focused app's entire AX tree. But a typical user action — say, closing
a dialog — only destroys one NSWindow; the AX subtrees of the other windows haven't
changed at all, so rescanning them is wasted.

**Cache model**: cache the scan result of each `AXWindow`'s subtree, keyed by its
ref. `AXUIElement` is a CF type, with identity via `CFEqual / CFHash`, so we wrap it
in a `WindowKey: Hashable` to feed a `Dictionary`. Each entry stores:

```swift
struct CachedTarget {
    let element: AXUIElement
    let offsetFromWindow: CGPoint   // target.origin - window.origin (at scan time)
    let size: CGSize
    let role: String
}

struct Entry {
    var targets: [CachedTarget]
    var dirty: Bool
}
```

**Coordinates stored window-local**: at scan time we record
`target_screen_origin - window_screen_origin`, not the absolute screen coordinate.
On reuse, read that window's current `AXPosition` once (1 IPC) and add back the
offset to get the latest screen coordinate. **A user dragging the window needs no
invalidation** — it's handled naturally.

**Three layers of invalidation** (cheapest to most expensive):

1. **`syncFocusedApp(pid)`**: the focused app changed → full clear. We can't observe
   an app's changes while it isn't focused, so the cache's trust level drops to zero.
2. **AXWindows diff**: each collect reads the AXApplication's `AXWindows` attribute
   once (1 IPC) and compares against the cache's keys. Anything not in the new list →
   drop. The "window destroyed" case (closing a dialog) is caught here.
3. **commit triggers dirty**: after `HintMode.commit` does AXPress, it calls
   `markDirty(window:)` keyed by the `sourceWindow` on the target. Semantics: **the
   user clicked something in this window, the window's content may have changed, so
   the next reuse of it must rescan**. Other untouched windows keep their cache
   valid. dock / menu extras / menu bar items have a nil `sourceWindow`, so commit
   doesn't trigger dirty for them.

**There is no AX observer watching for content changes**. Reasons:

- The AX notification layer's semantics are unstable (many apps don't send, or drop,
  layout / value changes).
- Commit-driven dirty already covers every "user actively changed the UI" case in the
  sticky flow — during a sticky session the user's only input is hint clicks, and
  every click marks dirty.
- If the user changed the UI with a real mouse **while Keyway was off** →
  `VimSession.enter()` calls `cache.clear()` as a fallback, so every re-entry into
  Keyway starts from scratch.

**Reuse cost**: 1 IPC to read the window's AXPosition + adding the offset in memory.
Hitting a window saves the entire batchFetch of that window's subtree (on the order
of hundreds of IPC).

**Applicable scenarios** (verified effective):
- Sticky rescan after closing a dialog: the dialog is pruned, the main window's cache hits.
- Repeated sticky within a session: each time only the windows that actually changed are rescanned.

**Non-applicable scenarios** (cache misses outright / has no effect):
- Focused app switch: full clear.
- The user clicked something in the focused window: that window is marked dirty and rescanned.
  This is "correct," not a cache failure.

### 2.6 AXMenuBar fast path (`walkMenuBar`)

**Problem**: the focused app's menu bar (the File / Edit / View ... row) is walked
on every collect. The cost of the generic `walk()` handling it is:

- batchFetch each AXMenuBarItem itself: 1 IPC
- each item hangs a **closed-state AXMenu** below it (macOS keeps this node in the
  AX tree even when the dropdown isn't expanded), batchFetch it once: 1 IPC
- the `axMenuIsOpen` check (AXParent + parent's role + parent's AXSelected):
  3 IPC

That's **~5 IPC per menubar item**. 10 items = ~50 IPC, all wasted — because 99% of
the time when we scan, the menu bar has no dropdown expanded at all.

**Fast path**: at the AXMenuBar level, first read `AXSelectedChildren` once (1 IPC).
The returned array:

- **empty** → no menu is expanded (the vast majority of cases). Just batchFetch each
  top-level AXMenuBarItem as a candidate, **without drilling in**. ~12 IPC total.
- **non-empty** → a dropdown is expanded. Fall back to the generic `walk()`,
  ensuring the `AXMenuItem`s inside the dropdown can still get hints.

```swift
walkMenuBar(menubar):
  if AXSelectedChildren(menubar) is non-empty:
    walk(menubar)         // slow path, covers the open dropdown
    return
  for item in menubar.AXChildren:    // fast path
    if isCandidate(item): append
    // don't descend into item.AXChildren
```

Measured reduction: total IPC per collect ~270 → ~13 (when the cache hit after
closing a dialog and the fast path both kick in together).

---

## 3. Dock (`dock`)

```swift
if let dockApp = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock").first {
    let dock = AXUIElementCreateApplication(dockApp.processIdentifier)
    walk(element: dock, depth: 0, into: &dockOut, screenSpan: screenSpan)
}
```

Reuses the same `walk()`. The Dock doesn't depend on focus, so it's always scanned.

Dock items all have role = `AXDockItem`, which is matched by `clickableRoles`, and `hasMeaningfulLabel` is waived for them.
So Dock separators / Recents placeholders are also collected (the user's sense is that these two are usually useless and could be filtered in the future).

Labels use the digits `0..9` (see `hint-rendering.md` for details).

---

## 4. Menu bar extras (`menuBarExtras`)

The status icons on the right side of the menu bar. **This is the source with the deepest gotchas.**

### 4.1 War stories

Why we can't use other, more direct APIs:

| Method tried | Reason it failed |
| --- | --- |
| `NSStatusBar.system.statusItems` | Only exposes **your own app's** items, can't see other apps |
| `CGWindowListCopyWindowInfo` filtered to the menu-bar region | On Sonoma+, menu-bar rendering is **consolidated into the Control Center process**, so third-party status items don't appear in the WindowServer list. Even granting Screen Recording doesn't help. |
| Hard-coded whitelist of common menu-extra bundle IDs | Misses third parties (Bartender, Dropbox, various status apps) |
| Iterating all running apps and querying AX on every trigger | Measured 5479ms, unacceptable |

Final approach: **`MenuExtraCache` maintains, in the background, a set of PIDs of "which PIDs have menu extras," and on trigger we only query those PIDs.**

### 4.2 MenuExtraCache design

**Warm-up (once at launch, in the background):**
```swift
DispatchQueue.global(qos: .userInitiated).async {
    let allPIDs = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy != .prohibited
                  && $0.processIdentifier != ownPID }
        .map { $0.processIdentifier }
    DispatchQueue.concurrentPerform(iterations: allPIDs.count) { i in
        if appHasMenuExtras(pid: allPIDs[i]) { bag.add(allPIDs[i]) }
    }
    self.pids = bag.snapshot()
}
```

- **Parallel**: `concurrentPerform` distributes ~100 AX queries across cores, finishing in ~500ms.
- **Background**: `userInitiated` priority, doesn't block the UI.
- **Timing**: AppDelegate kicks this off immediately after the Accessibility authorization check passes, long before the user first presses the trigger key.
- **Worst case**: the user presses the trigger before warm-up finishes → that collect gets an incomplete extras set. The next one is normal.

**Incremental maintenance (NSWorkspace notifications, zero polling):**
```swift
nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, ...) {
    self?.probeAndMaybeAdd(pid: app.processIdentifier, delay: 1.0)
}
nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, ...) {
    self?.remove(pid: app.processIdentifier)
}
```

- After a new process launches, **wait 1s** before probing — the AX bridge needs time to come up, probing immediately gives a false negative.
- On process exit, remove from the set immediately.

**`appHasMenuExtras(pid)` — cheap existence check:**

```swift
private static func appHasMenuExtras(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    var extrasRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
       extrasRef != nil {
        return true
    }
    // Legacy form: AXMenuExtra hangs directly off the root AXChildren
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXChildren" as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement]
    else { return false }
    for child in children {
        if let role = roleOf(child), role == "AXMenuExtra" { return true }
    }
    return false
}
```

Only checks **whether** extras exist, doesn't enumerate the specific elements — enumeration is left to `HintMode.collectDirectMenuExtras` on each trigger.

### 4.3 Trigger time: `collectDirectMenuExtras`

```swift
for pid in MenuExtraCache.shared.currentPIDs() {
    let app = AXUIElementCreateApplication(pid)
    collectDirectMenuExtras(from: app, into: &extrasOut, screenSpan: screenSpan)
}
```

Only queries the ~10 PIDs in the cache, and each AX query is fast. Serial total time ~10–30ms.

`collectDirectMenuExtras` accepts both AX tree forms:

**Modern form (common on Sonoma+):**
```
appRoot.AXExtrasMenuBar (a separate attribute, not in AXChildren)
    └── AXChildren
        ├── AXMenuBarItem  ← Apple's own agents / Control Center
        └── AXMenuExtra    ← some third parties
```

```swift
var extrasRef: CFTypeRef?
if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
   let extras = extrasRef {
    let bar = extras as! AXUIElement
    // read its AXChildren, collect both role == AXMenuBarItem || AXMenuExtra
}
```

**Legacy form:**
```
appRoot.AXChildren
    ├── AXMenuBar
    └── AXMenuExtra   ← hangs directly off the root
```

Only check this path when `AXExtrasMenuBar` is missing.

> **Key gotcha**: `AXExtrasMenuBar` **does not appear in `AXChildren`**. The initial implementation assumed all menu extras were children of the root, and as a result missed them all on Sonoma+ — because Sonoma+ moved them into a separate attribute. Both paths must be queried.

No recursion — menu extras are all top-level status icons; the submenu (which expands after clicking) only enters the AX tree once the user clicks.

---

## 5. Known performance spike: the app AX cleanup window

**Symptom**: the user clicks to close a window (the red close button on a dialog,
or a close-sheet button), a sticky rescan happens immediately, and the focused scan
time jumps to ~500ms, **even though `HintWindowCache` and `walkMenuBar` both hit the
optimal path**.

**Measured**:

```
the scan right after closing a dialog:  focused=535ms (13 IPC, 1 window cache hit)
the very next scan:                     focused=53ms (270 IPC, 0 window cache hit)
```

13 IPC is already the theoretical floor (AXFocusedApplication + AXWindows +
1 readScreenOrigin + AXMenuBar + AXSelectedChildren + AXMenuBar
batchFetch + ~7 menubar items) — there's nothing left to cut. **The problem is that
per-IPC latency rose from 0.2ms to ~40ms**; the 500ms is almost entirely the
accumulation of 13 × ~40ms.

**Root cause**: the instant the user clicks, the app begins internal cleanup
(destroying the NSWindow, recomputing focus, clearing AX subtrees, possibly with a
layout reflow), and that wall-clock time is the app's internal cost (measured at
about 400-600ms for WeChat). Our IPC queries go out during this window, and each is
queued behind the app's AX server's cleanup work, so the per-unit price rises from
0.2ms to ~40ms. **Optimizing the IPC count has no effect on the per-unit price** —
any path needs at least ~10 IPC to finish a minimal scan, and at 40ms each that's
400ms minimum.

**Failed approaches tried**:

| Direction | Why it doesn't work |
| --- | --- |
| Compress the IPC count further (below 5) | Several core queries (AXWindows, AXMenuBar root, the AXPosition used by cache reuse) are required; cutting them degrades or breaks scanning |
| Lower the AX message timeout globally | Already abandoned historically; it would cause normal-but-slow apps to fail to return data (see `event-pipeline.md`) |
| Event-driven, wait for AX to stabilize before scanning (`kAXFocusedWindowChangedNotification`, etc.) | The notification's arrival timing is uncontrollable: it might fire exactly when cleanup ends, at which point total wall-clock time ≈ the current 535ms (or slightly worse, with an extra idle wait); if it fires early, the scan still lands mid-cleanup, with no improvement. Would need real measurement to know; not yet attempted |

**Accepted state**:

- The spike only appears in that one instant of "destructive click immediately followed by a sticky rescan."
- The next scan immediately returns to ~50ms (AX server recovered + cache still warm).
- 535ms is still faster than the 840ms baseline before the last round of optimization.

**Long-term direction**: Electron apps' (the wedge vs Homerow) AX compatibility is
inherently poor (many clickable `<div>`s are exposed as AXGroup with no action and
no label, so hint hit rate is low), and we'll eventually introduce an
**OmniParser / visual ML** path to recognize clickable elements. That path is
entirely decoupled from the AX server — feed a screenshot to a model → get back
coordinates. Scanning becomes decoupled from the app's internal AX state, and **this
spike disappears naturally**. We'll come back and fix this when that path lands.

---

## 6. Concurrency safety

The background warm-up's `concurrentPerform` runs AX queries, which means these functions must be able to run off the main thread:

- `MenuExtraCache.appHasMenuExtras` — static function, stateless, naturally OK.
- `HintMode.collectDirectMenuExtras`, `appendIfValid`, `roleOf`, `boundsOf`, `enabled`, `onScreen` — all marked `nonisolated`, because they only do AX IPC + local `inout` writes and don't touch main-actor state.

`ElementCandidate` holds an `AXUIElement` (a CF type, refcounted + thread-safe), but Swift can't tell, so it's marked `@unchecked Sendable`.

`MenuExtraCache` protects `pids: Set<pid_t>` with an `NSLock` and the class is marked `@unchecked Sendable`:
```swift
func currentPIDs() -> [pid_t] {
    lock.lock(); defer { lock.unlock() }
    return Array(pids)
}
```

Returns an array rather than exposing the `Set` directly — the caller gets a snapshot, iterates without the lock, and a new process can enter the cache at any time.

---

## 7. Debugging

`debugDumpAXTree(element, depth, maxDepth)` is a static function that recursively prints any AX element's subtree: role + rect + actions.
When the scan result is wrong ("why does this button have no hint?", "why are menu extras 0?"), wire it into `collectAll` and call it once manually to see the tree structure.

For example:
```swift
if let (focused, pid) = focusedApplication() {
    debugDumpAXTree(focused, depth: 0, maxDepth: 4)
}
```
