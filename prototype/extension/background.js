// Mouseless extension — background service worker.
//
// P1 step 3: connect to the native host `com.mouseless.bridge` and
// exchange one ping/pong each time an event wakes the SW (install,
// browser startup, or user clicking the extension icon). Logs both
// directions to the service-worker console — inspect at
// chrome://extensions → "inspect views: service worker" on the
// Mouseless card.
//
// Note: under Manifest V3 the service worker is non-persistent and
// the native port disconnects when it goes idle. We don't keep a
// long-lived port yet — every ping opens a fresh `connectNative`.
// Persistent connections + reconnect logic arrive in P3 when
// BrowserProvider depends on always-on plumbing.

const HOST = "com.mouseless.bridge";

function tryPing(reason) {
  console.log("[mouseless-bg]", reason, "— connecting to", HOST);
  const port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener((msg) => {
    console.log("[mouseless-bg] recv from native:", msg);
  });
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    if (err) {
      console.warn("[mouseless-bg] port disconnected with error:", err.message);
    } else {
      console.log("[mouseless-bg] port disconnected cleanly");
    }
  });
  const msg = { cmd: "ping", note: `hello from background SW (${reason})` };
  port.postMessage(msg);
  console.log("[mouseless-bg] sent:", msg);
}

chrome.runtime.onInstalled.addListener(() => tryPing("onInstalled"));
chrome.runtime.onStartup.addListener(() => tryPing("onStartup"));
chrome.action.onClicked.addListener(() => tryPing("action.onClicked"));
