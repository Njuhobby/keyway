// Mouseless extension — background service worker.
//
// Persistent native-messaging connection to `com.mouseless.bridge`.
// The Mouseless main process sends `{cmd:"list_hints"}` over the port
// whenever the user enters TAP on a browser window; we forward to the
// active tab's content script, get the hint list back, and ship it
// over the port. The SW also pings every 20s — keeps the port alive
// AND prevents the SW itself from being culled under MV3's idle rule.
//
// MV3 SWs are non-persistent: any event listener (port.onMessage,
// alarms, runtime.onStartup) wakes them. Idle timeout is ~30s. With
// keepalive activity every 20s the SW survives indefinitely while a
// browser window is open. If the port DOES die (network error, OS
// suspend, etc.) we reconnect with exponential backoff.

const HOST = "com.mouseless.bridge";
const KEEPALIVE_MS = 20_000;
const RECONNECT_BASE_MS = 1_000;
const RECONNECT_MAX_MS = 30_000;

// Tell Mouseless which browser binary this extension lives in. Keep
// in sync with `browserKeyForBundleID` in BridgeServer.swift.
function detectBrowser() {
  const ua = navigator.userAgent || "";
  if (/Edg\//.test(ua))   return "edge";
  if (/OPR\//.test(ua))   return "opera";
  if (/Brave\//.test(ua)) return "brave";
  // Arc identifies as Chrome in UA — there's no reliable browser-side
  // distinction. Fall through to chrome. Mouseless's bundleID guard
  // still routes Arc-frontmost queries correctly because both
  // com.google.Chrome and company.thebrowser.Browser map to "chrome"
  // / "arc" respectively — we leave it as chrome here and accept that
  // Arc will be misrouted away from Arc; not a real concern yet.
  if (/Chrome\//.test(ua))  return "chrome";
  if (/Safari\//.test(ua))  return "safari";
  return "unknown";
}
const BROWSER = detectBrowser();

let port = null;
let keepaliveTimer = null;
let reconnectDelay = RECONNECT_BASE_MS;

function disconnectPort(reason) {
  if (keepaliveTimer) { clearInterval(keepaliveTimer); keepaliveTimer = null; }
  if (port) {
    try { port.disconnect(); } catch (e) { /* already dead */ }
    port = null;
  }
  if (reason) console.log("[mouseless-bg] disconnected:", reason);
}

function scheduleReconnect() {
  const wait = Math.min(reconnectDelay, RECONNECT_MAX_MS);
  reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
  console.log("[mouseless-bg] reconnect in", wait + "ms");
  setTimeout(connect, wait);
}

function connect() {
  if (port) return;
  console.log("[mouseless-bg] connecting to", HOST);
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    console.warn("[mouseless-bg] connectNative threw:", e.message);
    scheduleReconnect();
    return;
  }

  port.onMessage.addListener(handleFromNative);
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    disconnectPort(err ? err.message : "clean");
    scheduleReconnect();
  });

  // Send an initial ping so Mouseless knows we're alive and to
  // confirm the link end-to-end. Reset backoff once we have a port —
  // future disconnects start their own escalation. The `browser`
  // field is what Mouseless's bundleID-routing guard matches against.
  reconnectDelay = RECONNECT_BASE_MS;
  port.postMessage({ cmd: "ping", note: "extension SW connected", browser: BROWSER });
  console.log("[mouseless-bg] connected, sent initial ping (browser=" + BROWSER + ")");

  // Immediately tell Mouseless if this profile happens to be the
  // currently-focused one. SW startup doesn't trigger windows.onFocus-
  // Changed — that's CHANGE-driven — so we have to probe explicitly
  // for the boot case where Mouseless launches AFTER Chrome and the
  // user's already in a focused Chrome window.
  chrome.windows.getLastFocused().then((w) => {
    if (w && w.focused) reportActive("initial focus check");
  }).catch(() => { /* no windows yet — fine, will fire on first focus */ });

  // Inject content scripts into tabs that were already open before
  // this SW load. Chrome's content_scripts manifest only inject on
  // tab navigation AFTER extension install/reload — pre-existing
  // tabs are otherwise left without our scripts, and tabs.sendMessage
  // fails with "Receiving end does not exist". Auto-refreshing them
  // here removes the "reload extension → must manually refresh every
  // open tab" footgun.
  refreshExistingTabs();

  keepaliveTimer = setInterval(() => {
    if (!port) return;
    try {
      port.postMessage({ cmd: "keepalive", at: Date.now() });
    } catch (e) {
      console.warn("[mouseless-bg] keepalive write failed:", e.message);
      disconnectPort("keepalive write failed");
      scheduleReconnect();
    }
  }, KEEPALIVE_MS);
}

// Mouseless → extension router. The only inbound message we currently
// handle from native is `{cmd:"list_hints"}` (Mouseless wants the
// active tab's clickable list). pong / keepalive_ack ignored.
async function handleFromNative(msg) {
  if (!msg || typeof msg !== "object") {
    console.log("[mouseless-bg] recv non-object from native:", msg);
    return;
  }
  if (msg.cmd === "list_hints") {
    try {
      // Find the user-visible active tab. `lastFocusedWindow: true` is
      // the precise filter most of the time, but occasionally (e.g.,
      // DevTools popped out, sw just woke) it returns empty even with
      // the user squarely on a normal tab. Fall back through cheaper
      // queries before giving up.
      let tab = (await chrome.tabs.query({ active: true, lastFocusedWindow: true }))[0];
      if (!tab) tab = (await chrome.tabs.query({ active: true, currentWindow: true }))[0];
      if (!tab) {
        const win = await chrome.windows.getLastFocused({ populate: true }).catch(() => null);
        tab = win?.tabs?.find((t) => t.active);
      }
      if (!tab) tab = (await chrome.tabs.query({ active: true }))[0];
      if (!tab || !tab.id) {
        console.warn("[mouseless-bg] list_hints: no active tab found via any query");
        port?.postMessage({ type: "hints", url: null, hints: [], error: "no_active_tab" });
        return;
      }
      let resp;
      try {
        // frameId: 0 — explicit top frame only. With all_frames: true
        // in the manifest, every frame has a content script loaded;
        // without frameId we'd be asking every frame, but only the
        // top one (gated in content_script.js) actually responds.
        // Being explicit makes the intent clear and skips dispatch
        // to inner frames.
        resp = await chrome.tabs.sendMessage(tab.id, { type: "list_hints" }, { frameId: 0 });
      } catch (e) {
        // chrome:// and Web Store pages don't allow content scripts.
        console.warn("[mouseless-bg] list_hints: tabs.sendMessage failed:", e.message);
        port?.postMessage({
          type: "hints", url: tab.url, hints: [],
          error: "content_script_unavailable",
        });
        return;
      }
      if (!resp || resp.type !== "hints") {
        console.warn("[mouseless-bg] list_hints: bad cs response:", resp);
        port?.postMessage({ type: "hints", url: tab.url, hints: [], error: "bad_response" });
        return;
      }
      port?.postMessage({
        type: "hints",
        url: resp.url,
        viewport: resp.viewport,
        ms: resp.ms,
        hints: resp.hints,
      });
      console.log("[mouseless-bg] list_hints →", resp.hints.length, "hints, sent to native");
    } catch (e) {
      console.warn("[mouseless-bg] list_hints handler threw:", e);
    }
    return;
  }
  // Other server-initiated messages (future: invalidate caches, etc.).
  console.log("[mouseless-bg] recv from native:", msg);
}

// "I'm active" tells Mouseless that THIS profile/browser is currently
// the user's focused window — Mouseless routes outbound list_hints to
// whichever client most recently reported this. Multiple Chrome
// profiles each have their own SW + bridge, so without this Mouseless
// can't tell them apart.
function reportActive(reason) {
  if (!port) return;
  try {
    port.postMessage({ type: "i_am_active" });
  } catch (e) {
    console.warn("[mouseless-bg] reportActive failed:", e.message);
    return;
  }
  console.log("[mouseless-bg] reported i_am_active:", reason);
}

async function refreshExistingTabs() {
  if (!chrome.scripting) {
    console.warn("[mouseless-bg] no chrome.scripting (missing permission?) — skipping refresh");
    return;
  }
  let tabs = [];
  try {
    tabs = await chrome.tabs.query({});
  } catch (e) {
    console.warn("[mouseless-bg] tabs.query failed:", e.message);
    return;
  }
  let injected = 0, skipped = 0, failed = 0;
  for (const tab of tabs) {
    if (!tab.id) { skipped++; continue; }
    // url may be undefined without "tabs" permission, but chrome://,
    // chrome-extension://, edge://, file:// without permission, etc.
    // would all fail anyway — let executeScript reject and count.
    try {
      await chrome.scripting.executeScript({
        target: { tabId: tab.id, allFrames: true },
        files: ["detector.js", "content_script.js"],
      });
      injected++;
    } catch (e) {
      // chrome:// pages, Web Store, error pages, and the like —
      // executeScript throws. Not actually an error.
      failed++;
    }
  }
  console.log("[mouseless-bg] refreshed existing tabs:",
              injected, "injected,", failed, "rejected (chrome:// etc),", skipped, "skipped");
}

chrome.windows.onFocusChanged.addListener((winId) => {
  // WINDOW_ID_NONE fires when user switches AWAY from any of this
  // profile's windows (cross-app, or cross-profile to another Chrome
  // profile). We don't send `i_am_inactive` — the new active profile's
  // SW will overwrite activeFD via its own report. Sending an explicit
  // "inactive" risks racing the other profile's "active" and leaving
  // activeFD = -1 in the gap.
  if (winId === chrome.windows.WINDOW_ID_NONE) return;
  reportActive("windows.onFocusChanged winId=" + winId);
});

// Content script → bg → native: page_changed signal forwarded as-is.
// Coalescing is the receiver's job (Mouseless cooldown), so we don't
// debounce here — the content script only sends when it has actually
// detected a new clickable element appearing.
chrome.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || typeof msg !== "object") return;
  if (msg.type !== "page_changed") return;
  if (!port) return;
  try {
    port.postMessage({ type: "page_changed", url: msg.url, frameId: sender?.frameId });
  } catch (e) {
    console.warn("[mouseless-bg] page_changed forward failed:", e.message);
  }
});

// Open the port the first time the SW wakes for any reason. Re-fired
// on each cold start.
chrome.runtime.onInstalled.addListener(connect);
chrome.runtime.onStartup.addListener(connect);

// Action click: still useful as a manual "kick the connection" — if
// the user thinks the bridge is wedged, clicking the toolbar icon
// forces a reconnect.
chrome.action.onClicked.addListener(() => {
  console.log("[mouseless-bg] action.onClicked — forcing reconnect");
  disconnectPort("manual reconnect");
  connect();
});

// SW could load mid-flight (e.g., chrome resumed from sleep, event
// fired). If no port exists by the time module top-level runs,
// connect now too.
if (!port) connect();
