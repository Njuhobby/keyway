// Mouseless extension — background service worker.
//
// Two trigger paths to the native host:
//   - `onInstalled` / `onStartup` — one ping, sanity check that the
//     bridge is reachable.
//   - `action.onClicked` — ask the active tab's content script for
//     a hint list (via chrome.tabs.sendMessage → detector.js → result),
//     then forward to the native host. This is what P2 actually
//     validates: clickable hints flow from DOM → Mouseless main
//     process in <100ms.
//
// MV3 service workers are non-persistent. We open a fresh
// `connectNative` per trigger rather than keeping a long-lived port —
// good enough for P1/P2 testing; P3 wraps this in a connection manager
// with reconnect.

const HOST = "com.mouseless.bridge";

function postOnce(payload, reason) {
  console.log("[mouseless-bg]", reason, "— connecting to", HOST);
  const port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener((msg) => {
    console.log("[mouseless-bg] recv from native:", msg);
  });
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    if (err) console.warn("[mouseless-bg] port disconnected:", err.message);
    else console.log("[mouseless-bg] port disconnected cleanly");
  });
  port.postMessage(payload);
  console.log("[mouseless-bg] sent:", payload);
}

chrome.runtime.onInstalled.addListener(() => {
  postOnce({ cmd: "ping", note: "onInstalled" }, "onInstalled");
});

chrome.runtime.onStartup.addListener(() => {
  postOnce({ cmd: "ping", note: "onStartup" }, "onStartup");
});

// On user click: query the active tab for hints, ship them off.
chrome.action.onClicked.addListener(async (tab) => {
  if (!tab || !tab.id) {
    console.warn("[mouseless-bg] action.onClicked but no active tab");
    return;
  }
  console.log("[mouseless-bg] action.onClicked — requesting hints from tab", tab.id);
  let response;
  try {
    response = await chrome.tabs.sendMessage(tab.id, { type: "list_hints" });
  } catch (e) {
    console.warn("[mouseless-bg] tabs.sendMessage failed:", e.message,
      "(content script not injected on this page? chrome:// / store pages are off-limits)");
    return;
  }
  if (!response || response.type !== "hints") {
    console.warn("[mouseless-bg] unexpected response shape:", response);
    return;
  }
  console.log("[mouseless-bg] got", response.hints.length, "hints in",
    response.ms + "ms — forwarding to native");
  postOnce({
    cmd: "hints",
    url: response.url,
    viewport: response.viewport,
    ms: response.ms,
    hints: response.hints,
  }, "action.onClicked");
});
