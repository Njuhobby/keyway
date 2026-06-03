// Mouseless content script.
//
// Two roles:
//   1. On document_idle, call the detector and `console.log` the hint
//      count + sample. Lets you eyeball detection quality just by
//      reloading any page (page DevTools, no extension involved).
//   2. Listen for `chrome.runtime` messages from the background SW.
//      On `{type: "list_hints"}` run the detector and respond with the
//      hint array. Background then forwards over native messaging to
//      the Mouseless main process.
//
// All real classification + visibility + occlusion logic lives in
// `detector.js`, which the manifest loads earlier in the same content
// script array. (Same execution context, so `window.MouselessDetector`
// is set by then.)

(function () {
  "use strict";

  function runDetector() {
    if (!window.MouselessDetector) {
      console.warn("[mouseless cs] detector not loaded — check manifest order");
      return null;
    }
    const t0 = performance.now();
    const hints = window.MouselessDetector.listHints();
    const ms = (performance.now() - t0).toFixed(1);
    return { hints, ms };
  }

  // (1) Auto-log on page idle.
  const result = runDetector();
  if (result) {
    console.log(
      "[mouseless cs]",
      result.hints.length,
      "hints on", location.host,
      "in", result.ms + "ms",
      result.hints
    );
  }

  // (2) Respond to background SW.
  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg && msg.type === "list_hints") {
      const r = runDetector();
      sendResponse({
        type: "hints",
        url: location.href,
        viewport: { w: innerWidth, h: innerHeight, dpr: devicePixelRatio },
        ms: r ? r.ms : null,
        hints: r ? r.hints : [],
      });
      // sendResponse was called synchronously, no need to return true.
    }
  });
})();
