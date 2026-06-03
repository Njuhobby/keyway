# Mouseless extension

Bridge between Chrome (Safari later) and the Mouseless desktop app.

See [`../specs/browser-support-design.md`](../specs/browser-support-design.md)
for the architecture and roadmap.

## Phase status

- **P0** — env PoC: ✅ load unpacked, content script logs clickable list to dev console.
- **P1** — bridge plumbing:
  - step 1 ✅ BridgeServer + Unix socket
  - step 2 ✅ mouseless-bridge CLI relay
  - step 3 ✅ extension ↔ native host ping/pong
- **P2** — Vimium detector port: pending.
- **P3** — BrowserProvider in main process: pending.
- **P4** — click commit + DOM invalidation: pending.
- **P5** — Safari + store submission: pending.

## Dev setup (one-time)

```bash
cd prototype
swift build                  # produces both Mouseless and mouseless-bridge
```

Load the extension at `chrome://extensions/`:

1. **Developer mode** toggle ON (top right)
2. **Load unpacked** → pick `prototype/extension/`
3. Note the extension ID under the card (32 lowercase letters)

Register the native host manifest:

```bash
./extension/install_dev_host.sh <your-extension-id>
```

This writes
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.mouseless.bridge.json`
pointing at the bridge binary in `.build/`, locked to your extension ID.

## Verifying the P1 ping/pong

1. **Run Mouseless**: `./run.sh` from `prototype/`. Look for
   ```
   [bridge] listening on /Users/.../Library/Application Support/Mouseless/bridge.sock
   ```
2. **At `chrome://extensions/`**: click the **reload icon** on the
   Mouseless card, then **"inspect views: service worker"**. A DevTools
   window opens.
3. **Click the Mouseless toolbar icon** (in Chrome's extension area).
4. Service-worker console should show:
   ```
   [mouseless-bg] action.onClicked — connecting to com.mouseless.bridge
   [mouseless-bg] sent: {cmd: "ping", ...}
   [mouseless-bg] recv from native: {type: "pong", echo: {...}, from: "mouseless-main"}
   [mouseless-bg] port disconnected cleanly
   ```
5. Mouseless terminal should log:
   ```
   [bridge] client connected fd=N
   [bridge] recv fd=N msg=["cmd": ping, ...]
   [bridge] client disconnected fd=N
   ```

If you see `Specified native messaging host not found`, the host
manifest path or extension ID is wrong — re-run `install_dev_host.sh`
with the right ID. If you see `Native host has exited` or similar
without a `recv` line on the Mouseless side, the bridge binary
crashed — look in the SW console for `[mouseless-bridge]` stderr lines.

## Files

| File | Phase | Role |
| --- | --- | --- |
| `manifest.json` | P0+P1 | Manifest V3 with `nativeMessaging` permission, background SW, action button, content script on `<all_urls>`. |
| `background.js` | P1 | Service worker. On install/startup/action-click: connectNative → ping → log pong. |
| `content_script.js` | P0 | Hard-coded clickable selector + visibility filter, `console.log` the hint list. Replaced by `detector.js` (Vimium-derived) in P2. |
| `install_dev_host.sh` | P1 | Writes Chrome Native Messaging host manifest pointing at the local `mouseless-bridge` binary, locked to a specific extension ID. |
| `dev_bridge_ping.swift` | P1 step 1 | Standalone Swift script — opens the Unix socket directly, sends ping, prints pong. Tests the BridgeServer side in isolation. |
| `dev_bridge_drive.swift` | P1 step 2 | Standalone Swift script — spawns the bridge binary as a subprocess, sends ping via stdin, reads pong from stdout. Tests the full stdio↔socket relay without Chrome in the loop. |

## License attribution

In P2 we'll vendor portions of Vimium (MIT, https://github.com/philc/vimium)
under `vendor/vimium/`, preserving its LICENSE and copyright headers.
Currently no third-party code.
