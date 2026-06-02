// Mouseless extension — P0 (environment proof of concept).
//
// At document_idle, walk the page for clickable elements with a
// hard-coded selector + visibility filter, and console.log a hint
// list. This is the *only* thing P0 verifies — that we can load an
// unpacked Manifest V3 extension, inject into a real page, and
// read DOM rects.
//
// Anything Vimium-level (cross-frame, Shadow DOM, occlusion,
// iframe coord translation, message passing to a background SW)
// arrives in P1+. Keep this file boring.

(function () {
  "use strict";

  const SELECTOR = [
    "a[href]",
    "button",
    "input:not([type=hidden])",
    "select",
    "textarea",
    "[role=button]",
    "[role=link]",
    "[onclick]",
    "[tabindex]:not([tabindex='-1'])"
  ].join(",");

  function isVisible(el) {
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    if (r.bottom < 0 || r.top > window.innerHeight) return false;
    if (r.right < 0 || r.left > window.innerWidth) return false;
    const cs = window.getComputedStyle(el);
    if (cs.visibility === "hidden" || cs.display === "none") return false;
    if (parseFloat(cs.opacity || "1") < 0.05) return false;
    return true;
  }

  function listHints() {
    const els = document.querySelectorAll(SELECTOR);
    const out = [];
    for (const el of els) {
      if (!isVisible(el)) continue;
      const r = el.getBoundingClientRect();
      const text = (el.innerText || el.value || el.getAttribute("aria-label") || el.getAttribute("title") || "").trim().slice(0, 40);
      out.push({
        tag: el.tagName.toLowerCase(),
        rect: { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) },
        text
      });
    }
    return out;
  }

  const hints = listHints();
  // eslint-disable-next-line no-console
  console.log("[mouseless P0]", hints.length, "hints on", location.host, hints);
})();
