# Keyway extension

Bridge between Chrome / Firefox (Safari later) and the Keyway desktop app.

See [`../specs/browser-support-design.md`](../specs/browser-support-design.md)
for the architecture and roadmap.

## Phase status

- **P0** — env PoC: ✅ load unpacked, content script logs clickable list to dev console.
- **P1** — bridge plumbing:
  - step 1 ✅ BridgeServer + Unix socket
  - step 2 ✅ keyway-bridge CLI relay
  - step 3 ✅ extension ↔ native host ping/pong
- **P2** — Vimium detector port: pending.
- **P3** — BrowserProvider in main process: pending.
- **P4** — click commit + DOM invalidation: pending.
- **P5** — Safari + store submission: pending.

## Dev setup (one-time)

```bash
cd prototype
swift build                  # produces both Keyway and keyway-bridge
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
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.keyway.bridge.json`
pointing at the bridge binary in `.build/`, locked to your extension ID.

## Dev setup — Firefox

The JS (`background.js` / `content_script.js` / `detector.js`) and the
`keyway-bridge` binary are shared with Chrome. Only the manifest differs
(Firefox uses an event-page `background.scripts` + a `gecko` id instead of
Chrome's `background.service_worker`), and the native host is registered
under Mozilla's dir keyed by the add-on id, not a `chrome-extension://`
origin. Two helper scripts handle both:

```bash
cd prototype/extension
./build-firefox.sh             # assembles dist-firefox/ (shared JS + Firefox manifest)
./install_dev_host_firefox.sh  # registers the native host for Firefox (gecko id keyway@local)
```

Then load it: Firefox → `about:debugging#/runtime/this-firefox` →
**Load Temporary Add-on…** → pick `dist-firefox/manifest.json`. Click the
Keyway toolbar icon to trigger the first native ping. (Temporary add-ons
are dropped on Firefox restart — reload each session, like Chrome's unpacked
dev load. `dist-firefox/` is generated, gitignored — rerun `build-firefox.sh`
after editing the shared JS.)

## Verifying the P1 ping/pong

1. **Run Keyway**: `./run.sh` from `prototype/`. Look for
   ```
   [bridge] listening on /Users/.../Library/Application Support/Keyway/bridge.sock
   ```
2. **At `chrome://extensions/`**: click the **reload icon** on the
   Keyway card, then **"inspect views: service worker"**. A DevTools
   window opens.
3. **Click the Keyway toolbar icon** (in Chrome's extension area).
4. Service-worker console should show:
   ```
   [keyway-bg] action.onClicked — connecting to com.keyway.bridge
   [keyway-bg] sent: {cmd: "ping", ...}
   [keyway-bg] recv from native: {type: "pong", echo: {...}, from: "keyway-main"}
   [keyway-bg] port disconnected cleanly
   ```
5. Keyway terminal should log:
   ```
   [bridge] client connected fd=N
   [bridge] recv fd=N msg=["cmd": ping, ...]
   [bridge] client disconnected fd=N
   ```

If you see `Specified native messaging host not found`, the host
manifest path or extension ID is wrong — re-run `install_dev_host.sh`
with the right ID. If you see `Native host has exited` or similar
without a `recv` line on the Keyway side, the bridge binary
crashed — look in the SW console for `[keyway-bridge]` stderr lines.

## Files

| File | Phase | Role |
| --- | --- | --- |
| `manifest.json` | P0+P1 | Manifest V3 with `nativeMessaging` permission, background SW, action button, content script on `<all_urls>`. |
| `background.js` | P1 | Service worker. On install/startup/action-click: connectNative → ping → log pong. |
| `content_script.js` | P0 | Hard-coded clickable selector + visibility filter, `console.log` the hint list. Replaced by `detector.js` (Vimium-derived) in P2. |
| `install_dev_host.sh` | P1 | Writes Chrome Native Messaging host manifest pointing at the local `keyway-bridge` binary, locked to a specific extension ID. |
| `dev_bridge_ping.swift` | P1 step 1 | Standalone Swift script — opens the Unix socket directly, sends ping, prints pong. Tests the BridgeServer side in isolation. |
| `dev_bridge_drive.swift` | P1 step 2 | Standalone Swift script — spawns the bridge binary as a subprocess, sends ping via stdin, reads pong from stdout. Tests the full stdio↔socket relay without Chrome in the loop. |

## License attribution

In P2 we'll vendor portions of Vimium (MIT, https://github.com/philc/vimium)
under `vendor/vimium/`, preserving its LICENSE and copyright headers.
Currently no third-party code.
