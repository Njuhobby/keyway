# Event Pipeline

The path events travel from hardware to mode. Covers `HotkeyTap`'s interception strategy, feedback-loop avoidance, and modifier-key pass-through rules.

Related files: `HotkeyTap.swift`, `KeyPoster.swift`, and `synthesizeClick` at the end of `HintMode.swift`.

---

## 1. CGEventTap registration

```swift
let mask = (1 << CGEventType.keyDown.rawValue)
         | (1 << CGEventType.keyUp.rawValue)        // F19 arm resolve + scroll/move stop
         | (1 << CGEventType.flagsChanged.rawValue)
CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,         // can block events, not just observe
    eventsOfInterest: CGEventMask(mask),
    callback: callback,
    userInfo: Unmanaged.passUnretained(self).toOpaque()
)
```

- `cgSessionEventTap` — session-level; events from all apps pass through here.
- `headInsertEventTap` — inserted at the front, so it sees events one step earlier than other taps.
- `.defaultTap` — can return `nil` to swallow the event. **This is the physical mechanism for consuming a key.**
- The callback runs on the thread of the run loop it was registered on. We attach it to the main run loop, so the callback always runs on the main thread, where we can
  safely call main-actor methods via `MainActor.assumeIsolated`.

The most common cause of a startup failure: Accessibility is not authorized. `CGEvent.tapCreate` returns `nil`, and AppDelegate changes the menu-bar icon to `M⚠`.

---

## 2. The callback's three-layer short-circuit

After entering `handle(type:event:)`, the checks run in order, and **the earlier we return, the cheaper it is**:

### Layer 1: Tap self-healing

```swift
if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
    return passUnretained(event)
}
```

The system automatically disables the event tap in two situations:
- **timeout** — the callback runs too slowly (the default ceiling is ~1s)
- **user input race** — the user is still typing while the callback is running

Once disabled, we call `tapEnable` again to re-enable it, and the event itself is passed.

> This is exactly why, in `VimSession.handleTap`, the `x → Finder` path must throw the AX scan into a `Task` instead of running it synchronously: an 80ms sleep plus one full hint collection,
> if executed synchronously inside the callback, would trigger a timeout disable and the tap would die.

### Layer 2: Synthetic-event pass-through (feedback-loop avoidance)

```swift
if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
    return passUnretained(event)
}
// syntheticMarker = 0x4D4F5553  ("MOUS")
```

The events we post ourselves (synthesized clicks, KeyPoster) all carry this marker. The callback recognizes it at a glance and passes immediately —
otherwise it would fall through to the next layer of logic, treat the synthesized letter key as hint input, and intercept it again, forming a loop.

**All future code that synthesizes events must carry this marker.** The marker is defined in `HotkeyTap.syntheticMarker`,
exposed as `nonisolated` so any actor context can use it.

### Layer 3: keyUp handling + pass-through for non-keyDown

```swift
if type == .keyUp {
    // F19 release resolves the arm (see §3); the keyUp of other keys is routed to
    // the session (stop of scroll / hjkl move).
    ...
}
guard type == .keyDown else { return passUnretained(event) }
```

The event mask subscribes to `keyDown` + `keyUp` + `flagsChanged`. keyUp is no longer passed blindly — it must (a) resolve the F19 arm (release dispatch), and (b) hand the release of j/k/i/l etc. to `session.handleKeyUp` (stop continuous scrolling / continuous cursor movement). `flagsChanged` is still passed directly (the mask subscribes to it only to avoid the case where, under certain combinations, macOS does not emit a keyDown).

---

## 3. Trigger-key resolution: the F19 arm mechanism (all modes)

F19 (= Caps Lock) **does not act immediately on press**; instead it **arms** (stands by), waiting for release or for a chord. This lets one key serve multiple roles (a single tap enters TAP / toggles sticky / SCROLL→TAP; hold + jk enters SCROLL). See `modes.md` §2.1 for the full interaction.

```swift
// keyDown
if keyCode == KeyCode.f19 && flags.intersection(modifierMask).isEmpty {
    f19Armed = true; f19ChordUsed = false
    return nil                              // swallow, take no action yet
}
if f19Armed && (keyCode == KeyCode.j || keyCode == KeyCode.k) {
    f19ChordUsed = true
    session.enterScroll()                   // chord → SCROLL (any mode)
    return nil
}
if session.isActive {
    return session.handle(...) ? nil : passUnretained(event)
}
return passUnretained(event)

// keyUp
if keyCode == KeyCode.f19, f19Armed {
    let wasChord = f19ChordUsed
    f19Armed = false; f19ChordUsed = false
    if !wasChord { session.handleTriggerTap() }   // release with no chord → dispatch by mode
    return nil
}
```

**The arm covers all modes, not just OFF** — this is the root of both "Caps Lock+d inside TAP can also enter SCROLL" and "consecutive Caps Lock enters sticky" (the old implementation only armed in OFF, which broke both of these; see that commit).

**Only a bare F19** (without any modifier key) arms. F19 is not a key that physically exists on the keyboard — it relies on `hidutil` to remap the physical **Caps Lock** to F19, **invoked automatically by the app at launch** via `TriggerRemap.applyAtLaunch()` (see `SPECS.md` §2.1). Zero configuration for the user.

Why not listen for Caps Lock directly: macOS treats Caps Lock as a **modifier** rather than an ordinary key. In the event stream, Caps Lock only emits a `flagsChanged` event that changes the `.maskAlphaShift` flag; it does not emit a `keyDown`. The "Caps Lock pressed" that CGEventTap receives is a flag change, **with no keyCode to match**, and Caps Lock's toggle semantics (press once to lock, press again to unlock) also do not fit the "instantaneous trigger" requirement.

What the hidutil remap changes is the **HID usage code** (before the event enters macOS's modifier-handling logic), so after remapping the system sees an ordinary F19 keyDown, which travels the standard keyboard event stream, is visible to the event tap, and has no toggle state.

The modifier-mask check is left in place to reserve room for future users to bind something else to "Shift+F19 / Cmd+F19". F19 itself is used by no app — it falls in the "Hyper key" category.

Both the keyDown and keyUp of F19 are **consumed** — they are not delivered down to the lower app, otherwise the lower app would receive an orphan F19 keypress.

---

## 4. Event flow after activation

```swift
return session.handle(keyCode: keyCode, flags: flags)
    ? nil                                   // consume
    : passUnretained(event)                 // pass
```

The return value of `session.handle` decides whether the event is delivered down to the lower app. The two pass rules live at the top of `VimSession.handle()`:

### 4.1 Cmd / Ctrl pass-through

```swift
if !flags.intersection([.maskCommand, .maskControl]).isEmpty {
    return false
}
```

Events carrying Cmd or Ctrl are **always passed**. This guarantees:
- Cmd+Space → Spotlight
- Cmd+Tab → app switching
- Cmd+Shift+4 → screenshot
- Cmd+Q → quit app
- Ctrl+↑ → Mission Control
- Cmd+W → close window

A pitfall hit in the past: while Mouseless was active, Cmd+Space stopped working and the user was locked inside the mode.

### 4.2 Shift / Option do not pass through

These two are **consumed**, because they carry hint click-action semantics:
- `Shift + last char of label` → right-click (`AXShowMenu` or synthesized right-click)
- `Option + last char of label` → double-click (synthesize two mouseDown/Up pairs, `mouseEventClickState` = 1, 2)

---

## 5. Synthetic events

Two exits: `HintMode.synthesizeClick` (mouse) and `KeyPoster.post` (keyboard).

The shared recipe:

```swift
let src = CGEventSource(stateID: .privateState)
// ... build down / up ...
for ev in [down, up] {
    ev.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
    ev.post(tap: .cghidEventTap)
}
```

Key points:
- `CGEventSource(stateID: .privateState)` — independent event state, does not pollute the system-global modifier flags.
- `setIntegerValueField(.eventSourceUserData, ...)` — stamp the `"MOUS"` marker.
- `.post(tap: .cghidEventTap)` — inject at the very front of the HID layer, so all taps (including our own) can see it.

The key to a double-click: the `.mouseEventClickState` field, set to 1 for the first pair and 2 for the second. The system uses this to recognize a double-click.

`KeyPoster` is not currently used on the main path. The API is reserved for a future select-text mode (synthesizing arrow keys).

## 7. Async event waiting (`AXWait`)

The `x` path needs to wait for `finder.activate()` to actually take effect (focus switches to Finder) — instead of a fixed sleep, it goes through `AXWait.appActivated`:

```swift
AXWait.appActivated(bundleID:timeoutMs:) async -> Bool       // NSWorkspace notification
```

Under the hood it uses `withCheckedContinuation` to bridge `NSWorkspace.didActivateApplicationNotification` to async/await. Returns `true` = notification fired, `false` = timeout fallback. If the app is already frontmost, it returns true immediately and does not suspend.

Implementation details (`AXWait.swift`):
- `OneShot` — prevents a double-resume crash of the continuation caused by the callback and the timeout resuming at the same time
- `Box<T>` — an `@unchecked Sendable` reference cell that lets the `@Sendable` callback and the `@MainActor` timeout Task share the observer reference (both run on the main thread, but Swift's type system can't see that)

The fallback timeout is a safety belt **against silent failure**, not the main line of the path — in extreme cases the OS occasionally fails to send the notification (a known long-standing macOS issue), and the timeout keeps the Task from hanging forever. See `modes.md` §4.3 for details.

> History: an early version also had `AXWait.axNotification(_:on:pid:)`, used to wait for the Dock menu's `kAXUIElementDestroyedNotification`. It was later found that the Dock simply does not send this notification under the "focus-switch closes the menu" path (the element is left alive); we switched to `AXUIElementPerformAction(menu, kAXCancelAction)` to directly and synchronously trigger the Dock's full cleanup path, after which this helper was no longer needed and has been deleted.

---

## 6. AX calls and timeout

Not on the main path of the event pipeline, but related:

- The default AX message timeout is 6s. A hung app will slow down the scan.
- **Do not** use `AXUIElementSetMessagingTimeout` to globally lower it — a historical decision: it would cause apps that are normal but slow to fail to return data.
  The correct optimization path is to reduce the total number of elements that need to be queried (see the MenuExtraCache design in `hint-discovery.md`).
