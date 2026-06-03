// Mouseless content script.
//
// One copy runs in every frame (manifest `all_frames: true`). Three
// jobs split by frame role:
//
//   1. Top frame — listens on `chrome.runtime.onMessage` for the
//      background SW's `list_hints` request. Replies with the union
//      of its own hints and all iframe hints (recursive).
//
//   2. Any frame — listens on `window.message` for a parent's
//      `mouseless_hints_request`. Replies with its own subtree
//      hints (its own DOM + its own iframes, recursive).
//
//   3. Top frame only — on document_idle, run detector once and
//      console.log the count. Dev visibility; doesn't include iframe
//      hints (the bg-driven path does).
//
// Coordinate translation: `window.screenX/Y` in an iframe returns the
// top-level window's position, NOT the iframe's. So child frames
// cannot compute their own screen origin. The parent does it:
// it knows its own origin, calls `iframe.getBoundingClientRect()`,
// and ships `{x: parentX + r.left, y: parentY + r.top}` down via
// postMessage. Recursion naturally handles arbitrarily nested
// iframes — each level adds its iframe's position relative to its
// own viewport.

(function () {
  "use strict";

  const IS_TOP = (window.top === window);
  const HINT_REQ_TIMEOUT_MS = 250;

  // Selector for "new clickable appeared" detection (same vocabulary
  // as detector.js's classifier — kept inline so MutationObserver
  // callbacks can run without going through the full classifier on
  // every mutation). Misses some heuristic-driven cases (jsaction
  // listener, ng-click family) but catches the bulk — the cost of a
  // missed signal is just "Mouseless doesn't refresh this round";
  // user can Caps Lock again. Erring on permissive side.
  const CLICKABLE_SELECTOR = [
    "a[href]", "button", "input", "select", "textarea",
    "[role=button]", "[role=link]", "[role=tab]",
    "[role=menuitem]", "[role=checkbox]", "[role=radio]",
    "[onclick]", "[contenteditable=true]", "[contenteditable='']",
    "[tabindex]:not([tabindex='-1'])",
  ].join(",");

  // ---------- (3) Auto-log on top frame ----------

  if (IS_TOP) {
    if (!window.MouselessDetector) {
      console.warn("[mouseless cs] detector not loaded — check manifest order");
    } else {
      const t0 = performance.now();
      const hints = window.MouselessDetector.listHints();
      const ms = (performance.now() - t0).toFixed(1);
      console.log("[mouseless cs]", hints.length, "hints on", location.host,
                  "in", ms + "ms (top frame only — iframes added on demand)",
                  hints);
    }
  }

  // ---------- (2) Frame role: respond to parent's hints request ----------

  window.addEventListener("message", async (e) => {
    const data = e.data;
    if (!data || typeof data !== "object") return;
    if (data.type !== "mouseless_hints_request") return;
    if (typeof data.id !== "string") return;
    if (!data.origin || typeof data.origin.x !== "number" || typeof data.origin.y !== "number") return;

    let hints = [];
    try {
      hints = await gatherHintsRecursive(data.origin);
    } catch (err) {
      // swallow — return [] so parent isn't stuck
    }
    try {
      e.source.postMessage({
        type: "mouseless_hints_response",
        id: data.id,
        hints,
      }, "*");
    } catch (err) {
      // Parent gone, sandbox blocks postback, etc. — caller is on a
      // 250ms timeout, will resolve to [] on its own.
    }
  });

  // ---------- (1) Top frame: bg → CS bridge entry point ----------

  if (IS_TOP) {
    chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
      if (!msg || msg.type !== "list_hints") return;
      const t0 = performance.now();
      // Top frame computes its own viewport origin in screen coords.
      // Heuristic: window.screenX is the window's left in CSS px;
      // `outerHeight - innerHeight` is the vertical chrome (tab bar +
      // URL bar + bookmarks bar at top; status bar at bottom is usually
      // included in this number too, but small).
      const origin = {
        x: window.screenX,
        y: window.screenY + (window.outerHeight - window.innerHeight),
      };
      gatherHintsRecursive(origin).then((hints) => {
        sendResponse({
          type: "hints",
          url: location.href,
          viewport: { w: innerWidth, h: innerHeight, dpr: devicePixelRatio },
          ms: parseFloat((performance.now() - t0).toFixed(1)),
          hints,
        });
      }).catch((err) => {
        sendResponse({
          type: "hints",
          url: location.href,
          hints: [],
          error: String(err),
        });
      });
      return true;   // async response
    });
  }

  // ---------- Recursive gather ----------
  //
  // Collects this frame's own hints + recursively asks each `<iframe>`
  // for its subtree. Origin is passed in so all hints come back already
  // translated to screen coords; no post-aggregation math needed at
  // the top.

  async function gatherHintsRecursive(origin) {
    if (!window.MouselessDetector) return [];
    const myHints = window.MouselessDetector.listHints({ viewportOriginInScreen: origin });

    const iframes = Array.from(document.querySelectorAll("iframe"));
    if (iframes.length === 0) return myHints;

    const childBatches = await Promise.all(
      iframes.map((f) => askIframeForHints(f, origin))
    );
    return myHints.concat(...childBatches);
  }

  // ---------- (4) DOM-change detection ----------
  //
  // Watch for newly-added clickable elements (async lazy loads, SPA
  // re-renders) and notify Mouseless main process so it can refresh
  // the hint overlay in place. Each frame observes its own DOM.
  // Top frame fires `chrome.runtime.sendMessage` to bg; child frames
  // postMessage to their parent, which relays upward until it reaches
  // the top frame.
  //
  // **Precise**, not throttled — only fires when at least one **new
  // clickable** node enters the DOM (selector match on addedNodes /
  // their subtrees). Heart-beats / animation pulses / chat indicator
  // re-renders are ignored. Mouseless side enforces a 500ms cooldown
  // for UX (overlay refresh rate), so a burst of additions during a
  // page load collapses into one refresh on the receiver.

  function hasNewClickable(mutations) {
    for (const m of mutations) {
      if (m.type !== "childList") continue;
      for (const n of m.addedNodes) {
        if (n.nodeType !== Node.ELEMENT_NODE) continue;
        try {
          if (n.matches && n.matches(CLICKABLE_SELECTOR)) return true;
          if (n.querySelector && n.querySelector(CLICKABLE_SELECTOR)) return true;
        } catch (e) { /* invalid selector on edge nodes — ignore */ }
      }
    }
    return false;
  }

  function notifyPageChanged() {
    if (IS_TOP) {
      try {
        chrome.runtime.sendMessage({ type: "page_changed", url: location.href });
      } catch (e) { /* SW asleep or extension reloading; cooldown side covers gaps */ }
    } else {
      try {
        window.parent.postMessage({ type: "mouseless_page_changed_inner" }, "*");
      } catch (e) { /* sandboxed / cross-frame post fails — drop */ }
    }
  }

  const pageChangeObserver = new MutationObserver((mutations) => {
    if (!hasNewClickable(mutations)) return;
    notifyPageChanged();
  });

  // Wait for documentElement / body to exist (run_at: document_idle
  // guarantees it does, but be defensive).
  const observeTarget = document.body || document.documentElement;
  if (observeTarget) {
    pageChangeObserver.observe(observeTarget, {
      childList: true,
      subtree: true,
    });
  }

  // Relay iframe-originated page_changed signals up the parent chain.
  // (Distinct from the hint-request listener at top of file — keep
  // both registered; they handle different message types.)
  window.addEventListener("message", (e) => {
    if (!e.data || typeof e.data !== "object") return;
    if (e.data.type !== "mouseless_page_changed_inner") return;
    notifyPageChanged();
  });

  // ----------

  function askIframeForHints(iframe, parentOrigin) {
    return new Promise((resolve) => {
      const r = iframe.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) { resolve([]); return; }
      if (!iframe.contentWindow) { resolve([]); return; }

      // Cull off-viewport iframes — Mouseless can only click what
      // the user can see anyway, and waiting 250ms for an iframe
      // that's scrolled off-screen to respond is wasted budget.
      if (r.bottom < 0 || r.right < 0 || r.top > innerHeight || r.left > innerWidth) {
        resolve([]);
        return;
      }

      const childOrigin = {
        x: parentOrigin.x + r.left,
        y: parentOrigin.y + r.top,
      };
      const id = "mh_" + Math.random().toString(36).slice(2) + "_" + Date.now();

      let settled = false;
      const handler = (e) => {
        const d = e.data;
        if (!d || d.type !== "mouseless_hints_response" || d.id !== id) return;
        cleanup();
        resolve(Array.isArray(d.hints) ? d.hints : []);
      };
      const timeoutId = setTimeout(() => {
        cleanup();
        resolve([]);   // iframe didn't respond — non-Mouseless content (chrome://, sandboxed, error page, etc.)
      }, HINT_REQ_TIMEOUT_MS);
      const cleanup = () => {
        if (settled) return;
        settled = true;
        window.removeEventListener("message", handler);
        clearTimeout(timeoutId);
      };
      window.addEventListener("message", handler);

      try {
        iframe.contentWindow.postMessage({
          type: "mouseless_hints_request",
          id,
          origin: childOrigin,
        }, "*");
      } catch (err) {
        // sandboxed / cross-origin no-postMessage case
        cleanup();
        resolve([]);
      }
    });
  }
})();
