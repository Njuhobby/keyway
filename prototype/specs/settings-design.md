# Settings / User Configuration Design

> **Status: design draft, not implemented**. Before shipping, users need to be able to adjust at least the most painful few items (speed, colors, trigger). This doc locks down the configuration-item tiers + storage + the approach for making hardcoded constants configurable + v1 scope.

---

## 0. TL;DR + Principles

```
Add "Settings…" to the menu bar (Cmd+,) → config panel → store in UserDefaults → controllers read it (with defaults, live-apply)
```

**Configuration is a double-edged sword**: too much config = maintenance burden + test-matrix explosion + new users drowning. So **tier it**, putting only items that "vary a lot between people and that I've repeatedly tweaked while daily-driving" into v1, and defer the complex ones (custom key mappings). Homerow having a config panel is the right call, but don't pile it full from day one.

---

## 1. Storage: UserDefaults + Central Settings

A `Settings.shared` thin wrapper around `UserDefaults`, **with a default for every key** (never configured = current hardcoded value, behavior unchanged):

```swift
@MainActor final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var cursorNormalStep: CGFloat { d.object(forKey: "cursorNormalStep") as? CGFloat ?? 6 }
    var cursorFastStep:   CGFloat { d.object(forKey: "cursorFastStep")   as? CGFloat ?? 18 }
    // ... the rest follow the same pattern
    func reset() { /* clear all keyway.* keys */ }
}
```

**live-apply**: controllers read `Settings.shared.xxx` in `start()` or each tick (reading a cached value at 60fps is free) → changing a setting takes effect immediately, no restart needed. Theme-color-type settings (which affect rendering) post a `Settings.didChange` notification to make the overlay repaint.

---

## 2. Config Panel

- Menu bar "Settings…" (macOS convention, **not called Configure**; bound to Cmd+,)
- One NSWindow (or SwiftUI `Settings` scene), split into tabs: **General / Speed / Appearance / Trigger**
- Each item writes to UserDefaults immediately
- "Reset to Defaults" button

---

## 3. Configuration-Item Tiers

| Item | Current hardcoded value | Tier |
|---|---|---|
| **Cursor move speed** slow/normal/fast | MouseMover 2 / 6 / 18 px/tick | **v1 must-have** |
| **Scroll speed** normal/fast | ScrollController 30 / 90 px/tick | **v1 must-have** |
| **Window resize/move speed** slow/normal/fast | Window(Move)Controller 5 / 20 / 80 px/tick | **v1 must-have** |
| **Double-click threshold** | hjkl jump `hjklJumpTapWindow` 0.10s; WINDOW reverse + Shift double-click `windowReverseTapWindow` 0.15s | **v1 must-have** (typing speed varies a lot between people) |
| **Jump distance** | jumpCursor 0.25 / 0.5 screen | v1 must-have |
| **hint label theme color** | yellow `1.0,0.84,0` / move-armed `1.0,0.95,0.70` | **v1 should-have** |
| **label font size** | 11pt | v1 should-have |
| **trigger key** | Caps Lock→F19 (hardwired via hidutil) | **v1 should-have** (not everyone accepts Caps Lock) |
| **launch-at-login** | none | v1 should-have (LaunchAgent / SMAppService) |
| **sticky default toggle** | default off | v1 should-have |
| **fully custom key mapping** (rebind hjkl, hint letter pool, chord keys) | hardcoded | **v2** (see §6) |

> Offering "slow/medium/fast" presets is friendlier than raw numbers; advanced users can expand to fill in exact values.

---

## 4. Making Hardcoded Constants Configurable

The current state is `private let normalStep: CGFloat = 6` inside each controller. The fix:

1. Read values from `Settings.shared` at controller construction or in `start()` (replacing the `let` constants)
2. Speed-type values are read each tick (a timer is already running, reading a cached value is free) → live-apply
3. Theme color: `HintOverlay` reads `Settings.shared.hintColor` when rendering; the `Settings.didChange` notification triggers `needsDisplay`
4. Double-click thresholds (VimSession) → read from Settings: `hjklJumpTapWindow` (hjkl jump, 0.10s) and `windowReverseTapWindow` (WINDOW reverse + Shift double-click, 0.15s) are currently two constants. The hjkl jump is tighter than the others because it shares the same key as "normal single-step movement" and is the easiest to misjudge a fast double-tap as a jump; WINDOW/Shift has no such single-step ambiguity, so it keeps 0.15s. These can each be exposed separately, or combined into a single "double-click sensitivity" slider that scales both proportionally.

Zero-risk migration: each key's default = the current hardcoded value, so behavior is completely unchanged for users who never configured it.

---

## 5. Trigger Key (heavier than value-type config)

Currently `TriggerRemap` uses hidutil to globally remap Caps Lock → F19. Making the trigger configurable isn't just changing a number:

- **Simple version (v1 should-have)**: offer **a few presets** (Caps Lock / Right Cmd / Right Option / F19 direct), no arbitrary keys. Switching presets = changing the hidutil mapping target + updating the keycode the arm logic recognizes.
- **Arbitrary key**: complex (modifier keys can't serve as the trigger, conflicts need handling), defer to v2.

---

## 6. Custom Key Mapping — Pushed to v2 (can of worms)

Letting users remap hjkl to something else, change the hint letter pool, or change the chord keys is a big pit, tied to the longstanding **non-QWERTY keyboard layout** problem from `SPECS.md` Future-work #1:

- Currently `KeyCode.swift` assumes ANSI physical key positions, which already breaks on Dvorak/international keyboards
- Custom key mapping first requires refactoring the keyCode↔character mapping (`UCKeyTranslate`)
- It also requires handling conflict validation for cases like "the user changes the hint letters to something like hjkl"

**So v1 only does value-type + theme + trigger presets; key mapping waits to be done together with the keyboard-layout refactor.**

---

## 7. v1 scope

Do:
- `Settings.shared` (UserDefaults wrapper, every key has a default = current hardcoded value)
- Controllers switched to read Settings (speed-type values live-apply)
- Settings window (Cmd+,): Speed (cursor/scroll/window, slow-medium-fast presets + exact values), Appearance (theme color + label font size), Trigger (preset list), General (launch-at-login, sticky default)
- Reset to Defaults

Later (v2):
- Fully custom key mapping (paired with the keyboard-layout refactor)
- Arbitrary trigger key
- Config import/export, cross-device sync (iCloud)

---

## 8. Decision Record

1. **Tier it, don't pile it full** — config is a double-edged sword; v1 only includes items that vary a lot between people (speed/threshold/color/trigger presets)
2. **UserDefaults + default = current hardcoded value** — zero-risk migration, behavior unchanged when never configured
3. **Menu called "Settings…" + Cmd+,** — macOS convention (not called Configure)
4. **Trigger offers presets, not arbitrary keys** (v1); **custom key mapping pushed to v2** (tied to the non-QWERTY refactor)
5. **live-apply** — changes take effect immediately, no restart
