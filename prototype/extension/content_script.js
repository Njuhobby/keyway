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

  // ---------- (2b) Frame role: respond to parent's text-search request ----------
  //
  // Parallel to hints request but for /-search. Iframes get queried
  // with (query, parent-computed origin), recurse into their own
  // iframes, return all matches flattened.

  window.addEventListener("message", async (e) => {
    const data = e.data;
    if (!data || typeof data !== "object") return;
    if (data.type !== "mouseless_text_request") return;
    if (typeof data.id !== "string") return;
    if (typeof data.query !== "string") return;
    if (!data.origin || typeof data.origin.x !== "number" || typeof data.origin.y !== "number") return;

    let textMatches = [];
    try {
      textMatches = await gatherTextMatchesRecursive(data.query, data.origin);
    } catch (err) { /* swallow */ }
    try {
      e.source.postMessage({
        type: "mouseless_text_response",
        id: data.id,
        matches: textMatches,
      }, "*");
    } catch (err) { /* parent gone — caller timeout handles */ }
  });

  // ---------- (1) Top frame: bg → CS bridge entry point ----------

  if (IS_TOP) {
    chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
      if (!msg || typeof msg !== "object") return;

      // Top frame computes its own viewport origin in screen coords
      // (heuristic: window.screenX is window left in CSS px;
      // outerHeight - innerHeight is the vertical chrome at the top
      // of the window).
      function topOrigin() {
        return {
          x: window.screenX,
          y: window.screenY + (window.outerHeight - window.innerHeight),
        };
      }

      if (msg.type === "list_hints") {
        const t0 = performance.now();
        gatherHintsRecursive(topOrigin()).then((hints) => {
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
        return true;
      }

      if (msg.type === "find_text") {
        const query = typeof msg.query === "string" ? msg.query : "";
        const t0 = performance.now();
        gatherTextMatchesRecursive(query, topOrigin()).then((matches) => {
          sendResponse({
            type: "text_matches",
            url: location.href,
            query,
            ms: parseFloat((performance.now() - t0).toFixed(1)),
            matches,
          });
        }).catch((err) => {
          sendResponse({
            type: "text_matches",
            url: location.href,
            query,
            matches: [],
            error: String(err),
          });
        });
        return true;
      }

      if (msg.type === "find_first_input") {
        // Synchronous — detector returns immediately. Reports the
        // input that's currently focused (document.activeElement), or
        // first visible <input>/<textarea>/contenteditable in
        // document order. Top frame only for v1.
        const result = window.MouselessDetector?.findFirstInput({
          viewportOriginInScreen: topOrigin(),
        });
        sendResponse({
          type: "first_input",
          url: location.href,
          rect: result?.rect || null,
          source: result?.source || null,
        });
        return false;   // synchronous response, no async work
      }
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

  // Same shape as gatherHintsRecursive but for /-search. The detector
  // returns viewport-clamped text-substring rects in screen coords;
  // child frames are queried via postMessage with both the query AND
  // the parent-computed origin.
  async function gatherTextMatchesRecursive(query, origin) {
    if (!window.MouselessDetector || !window.MouselessDetector.findTextMatches) return [];
    if (!query) return [];
    const myMatches = window.MouselessDetector.findTextMatches(query, {
      viewportOriginInScreen: origin,
    });

    const iframes = Array.from(document.querySelectorAll("iframe"));
    if (iframes.length === 0) return myMatches;

    const childBatches = await Promise.all(
      iframes.map((f) => askIframeForTextMatches(f, query, origin))
    );
    return myMatches.concat(...childBatches);
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

  // Throttle page_changed to ≤1 per NOTIFY_THROTTLE_MS (leading + trailing
  // edge). Continuously-mutating pages — a playing YouTube video is the
  // worst case: its suggestion rail / player controls churn clickable
  // nodes many times a second — would otherwise flood the native host
  // with page_changed AND keep the content-script main thread busy enough
  // that `list_hints` can't reply within Mouseless's 400ms budget (→
  // "0 hints"). Mirrors the 500ms cooldown on the Mouseless side
  // (VimSession.handlePageChanged), but matters more here because the work
  // we're skipping is on the page's own main thread.
  const NOTIFY_THROTTLE_MS = 500;
  let lastFireAt = 0;
  let trailingTimer = null;
  function scheduleTrailingNotify(remaining) {
    if (trailingTimer !== null) return;
    trailingTimer = setTimeout(() => {
      trailingTimer = null;
      lastFireAt = Date.now();
      notifyPageChanged();
    }, remaining);
  }
  // For relayed signals (iframe page_changed) — no expensive scan to skip,
  // just rate-limit the send.
  function notifyPageChangedThrottled() {
    const since = Date.now() - lastFireAt;
    if (since >= NOTIFY_THROTTLE_MS) {
      lastFireAt = Date.now();
      notifyPageChanged();
    } else {
      scheduleTrailingNotify(NOTIFY_THROTTLE_MS - since);
    }
  }

  const pageChangeObserver = new MutationObserver((mutations) => {
    const since = Date.now() - lastFireAt;
    if (since < NOTIFY_THROTTLE_MS) {
      // Inside the cooldown that a real change just opened → the page is
      // actively churning. Skip the expensive `hasNewClickable` scan
      // entirely (this is the whole point — that querySelector work, not
      // the send, is what starves `list_hints`); just ensure one trailing
      // fire lands. Slightly less precise (the trailing fire is
      // unconditional, so a burst that happened to add no clickable still
      // notifies), but it costs at most one extra rescan, which Mouseless
      // coalesces — and it only happens while a genuine change keeps the
      // burst alive. `lastFireAt` advances ONLY on a real fire, so a page
      // that mutates without ever adding a clickable never enters this
      // branch and never spuriously notifies.
      scheduleTrailingNotify(NOTIFY_THROTTLE_MS - since);
      return;
    }
    // Outside the cooldown: run the real check; fire (and open the
    // cooldown) only on a genuine new clickable.
    if (hasNewClickable(mutations)) {
      lastFireAt = Date.now();
      notifyPageChanged();
    }
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
    notifyPageChangedThrottled();
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

  // Parallel to askIframeForHints for /-search. Same plumbing — just
  // the message type and reply field differ.
  function askIframeForTextMatches(iframe, query, parentOrigin) {
    return new Promise((resolve) => {
      const r = iframe.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) { resolve([]); return; }
      if (!iframe.contentWindow) { resolve([]); return; }
      if (r.bottom < 0 || r.right < 0 || r.top > innerHeight || r.left > innerWidth) {
        resolve([]);
        return;
      }
      const childOrigin = {
        x: parentOrigin.x + r.left,
        y: parentOrigin.y + r.top,
      };
      const id = "mt_" + Math.random().toString(36).slice(2) + "_" + Date.now();
      let settled = false;
      const handler = (e) => {
        const d = e.data;
        if (!d || d.type !== "mouseless_text_response" || d.id !== id) return;
        cleanup();
        resolve(Array.isArray(d.matches) ? d.matches : []);
      };
      const timeoutId = setTimeout(() => { cleanup(); resolve([]); }, HINT_REQ_TIMEOUT_MS);
      const cleanup = () => {
        if (settled) return;
        settled = true;
        window.removeEventListener("message", handler);
        clearTimeout(timeoutId);
      };
      window.addEventListener("message", handler);
      try {
        iframe.contentWindow.postMessage({
          type: "mouseless_text_request",
          id,
          query,
          origin: childOrigin,
        }, "*");
      } catch (err) {
        cleanup();
        resolve([]);
      }
    });
  }
})();
