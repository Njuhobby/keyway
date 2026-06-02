# Mouseless extension

Bridge between Chrome (Safari later) and the Mouseless desktop app.

See [`../specs/browser-support-design.md`](../specs/browser-support-design.md)
for the architecture and roadmap.

## Phase status

- **P0 — environment PoC**: ✅ load unpacked, content script logs clickable list to dev console.
- **P1 — bridge plumbing**: pending. Native Messaging Host + Mouseless main-process Unix socket + ping/echo.
- **P2 — Vimium detector**: pending.
- **P3 — BrowserProvider in main process**: pending.
- **P4 — click commit + DOM invalidation**: pending.
- **P5 — Safari + store submission**: pending.

## Loading the P0 dev build

1. Open `chrome://extensions/`.
2. Top-right: **Developer mode** ON.
3. Click **Load unpacked**, pick this folder (`prototype/extension/`).
4. Visit any web page (try https://github.com).
5. Open DevTools → Console. Look for a line like:

   ```
   [mouseless P0] 127 hints on github.com (127) [ {tag: 'a', rect: {...}, text: '...'}, ... ]
   ```

If you see it, the environment is healthy and we can proceed to P1.

## Files

| File | Phase | Role |
| --- | --- | --- |
| `manifest.json` | P0 | Manifest V3 with a single content script on `<all_urls>`. No background SW yet (added in P1). |
| `content_script.js` | P0 | Hard-coded clickable selector + visibility filter, `console.log` the hint list. Replaced by `detector.js` (Vimium-derived) in P2. |

## License attribution

In P2 we'll vendor portions of Vimium (MIT, https://github.com/philc/vimium)
under `vendor/vimium/`, preserving its LICENSE and copyright headers.
Currently no third-party code.
