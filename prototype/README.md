# Mouseless prototype (Day 1-2)

Menu-bar agent with a global vim-mode toggle. No Dock icon, no window — just a
status item and a HUD that appears when vim mode is active.

## Build & run

```sh
cd prototype
swift run
```

First run: macOS will pop the Accessibility permission dialog.

1. Open **System Settings → Privacy & Security → Accessibility**
2. Find the entry (it'll be the path under `.build/...`) and toggle it on
3. **Fully quit** the running process (Ctrl-C in terminal) and `swift run` again

> The TCC database keys permission to the binary's path + signature. Each
> rebuild changes that path, which means re-prompts during dev. To minimise
> this, build once with `swift build -c debug` and re-run `.build/debug/Mouseless`
> directly between code changes — only re-grant when you change the source.

## Try it

1. Open TextEdit, write any sentence, click into the text.
2. Press **Ctrl+;** — HUD shows `VIM`.
3. Move with `h j k l`. (These post arrow keys to the focused app.)
4. Press `v` — HUD shows `VIM · SEL`. Now movement extends a selection.
5. Press `y` to copy + exit vim mode. Or `Esc` to exit without copying.

## Status

- [x] Menu-bar agent skeleton
- [x] Global hotkey via CGEventTap
- [x] Vim mode state machine: `h j k l v y Esc`
- [x] HUD overlay (non-focus-stealing)
- [x] Synthetic-event feedback-loop guard
- [ ] Day 3-4: AX direct manipulation of `kAXSelectedTextRangeAttribute`
- [ ] Day 3-4: word motions (`w b e`), line motions (`0 $`), doc motions (`gg G`)
- [ ] Day 5: more polish, maybe `f<char>` and `d`/`c` operators
- [ ] Day 6: 30-second demo video
- [ ] Day 7: ship the X post

## Architecture

```
main.swift          NSApplication bootstrap
AppDelegate         Menu bar + permission check
HotkeyTap           CGEventTap → forwards to VimSession
VimSession          State machine (active? selecting?)
KeyPoster           Synthesized arrow / Cmd+C events
KeyCode             US-ANSI virtual key constants
HUD                 Borderless overlay window
```

Threading: everything runs on the main actor. The CGEventTap callback is a
`@convention(c)` function pointer; we use `MainActor.assumeIsolated` to call
back into actor-isolated state, since we know the run-loop source is on main.

## Known limitations (this is Day 1-2, not the product)

- Movement is fake: we just post arrow keys, so motion is exactly what arrow
  keys would do (no word-aware, no `f<char>`). Day 3-4 swaps in real AX-driven
  cursor manipulation.
- Non-US keyboard layouts: `KeyCode` constants are physical positions, so the
  letters they match are wrong on Dvorak / AZERTY. Fix later.
- No way to rebind `Ctrl+;`. Hardcoded for the spike.
- Electron apps (Slack, VS Code, Discord) won't respond to AX selection writes.
  We'll detect and fall back to keystroke posting in those.

## After Day 2: contact Dexter Leng

See `../README.md` and `../business-plan.md` §11. Once the demo works, draft the
email — that conversation is worth more than another week of code.
