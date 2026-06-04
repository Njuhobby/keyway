// Mouseless extension — DOM hint detector.
//
// Enumerates every element in the document (including shadow roots),
// classifies clickability with the same rules Vimium uses, filters by
// visibility and 5-point occlusion, returns hint rects in viewport
// coords. Exposed as `window.MouselessDetector.listHints()`.
//
// MIT attribution: the classification rules and occlusion heuristic
// are adapted from Vimium's `content_scripts/link_hints.js` (the
// `LocalHints` object, ~lines 1068-1460). Copyright (c) 2010 Phil
// Crosby, Ilya Sukhar. See vendor/vimium/MIT-LICENSE.txt + NOTICE.md
// for the full attribution.

(function () {
  "use strict";

  // Tag-level clickability cues. Some are unconditional (a, details),
  // some depend on disabled/readOnly state, some depend on inline
  // style (img with cursor:zoom-*).
  const ALWAYS_CLICKABLE_TAGS = new Set(["a", "object", "embed", "details"]);

  // ARIA roles that count as clickable (Vimium's allow-list).
  const CLICKABLE_ROLES = new Set([
    "button", "tab", "link", "checkbox",
    "menuitem", "menuitemcheckbox", "menuitemradio",
    "radio", "textbox",
  ]);

  // AngularJS click-handler attributes. 3 prefixes × 3 separators = 9.
  const NG_CLICK_ATTRS = (() => {
    const out = [];
    for (const p of ["", "data-", "x-"]) {
      for (const s of ["-", ":", "_"]) out.push(`${p}ng${s}click`);
    }
    return out;
  })();

  // Walk the entire DOM, descending into shadow roots so Web
  // Components are not invisible to us.
  function getAllElements(root, out) {
    out = out || [];
    for (const el of root.querySelectorAll("*")) {
      out.push(el);
      if (el.shadowRoot) getAllElements(el.shadowRoot, out);
    }
    return out;
  }

  // Per-element classification. Returns {secondClass, falsePositive}
  // when clickable, null otherwise.
  //   secondClass    — tabindex-only; treated as low priority and
  //                    skipped by the occlusion pass (matches Vimium).
  //   falsePositive  — likely a wrapper (e.g., class=btn span) whose
  //                    real clickable target is a descendant. Filtered
  //                    later when a descendant within 3 generations is
  //                    also clickable.
  function classify(el) {
    const tagName = el.tagName && el.tagName.toLowerCase && el.tagName.toLowerCase();
    if (!tagName) return null;

    // aria-disabled → never hint.
    const ariaDisabled = el.getAttribute("aria-disabled");
    if (ariaDisabled === "" || ariaDisabled === "true") return null;

    let clickable = false;
    let secondClass = false;
    let falsePositive = false;

    if (el.hasAttribute("onclick")) clickable = true;

    if (!clickable) {
      const role = el.getAttribute("role");
      if (role && CLICKABLE_ROLES.has(role.toLowerCase())) clickable = true;
    }

    if (!clickable) {
      const ce = el.getAttribute("contenteditable");
      const v = ce && ce.toLowerCase();
      if (v === "" || v === "true" || v === "contenteditable") clickable = true;
    }

    if (!clickable) {
      for (const attr of NG_CLICK_ATTRS) {
        if (el.hasAttribute(attr)) { clickable = true; break; }
      }
    }

    if (!clickable && el.hasAttribute("jsaction")) {
      // Format: "click:foo.bar" or "foo.bar" (event defaults to click)
      // multiple rules separated by ";".
      for (const rule of el.getAttribute("jsaction").split(";")) {
        const parts = rule.trim().split(":");
        let event, ns, action;
        if (parts.length === 1) {
          event = "click";
          [ns, action = "_"] = parts[0].trim().split(".");
        } else if (parts.length === 2) {
          event = parts[0];
          [ns, action = "_"] = parts[1].trim().split(".");
        } else {
          continue;
        }
        if (event === "click" && ns !== "none" && action !== "_") {
          clickable = true;
          break;
        }
      }
    }

    if (ALWAYS_CLICKABLE_TAGS.has(tagName)) {
      clickable = true;
    } else {
      switch (tagName) {
        case "button":
        case "select":
          clickable = clickable || !el.disabled;
          break;
        case "textarea":
          clickable = clickable || (!el.disabled && !el.readOnly);
          break;
        case "input": {
          const t = el.getAttribute("type");
          const type = t && t.toLowerCase();
          clickable = clickable || !(type === "hidden" || el.disabled);
          break;
        }
        case "img":
          clickable = clickable || el.style.cursor === "zoom-in" || el.style.cursor === "zoom-out";
          break;
      }
    }

    // class="button" / "btn" heuristic. Vimium tags these as
    // possibleFalsePositive because real buttons are often wrapped in
    // an outer "btn-something" div.
    if (!clickable) {
      const cls = el.getAttribute("class");
      const lower = cls && cls.toLowerCase();
      if (lower && (lower.includes("button") || lower.includes("btn"))) {
        clickable = true;
        falsePositive = true;
      }
    }

    // <span> always flagged as falsePositive — common wrapper.
    if (tagName === "span") falsePositive = true;

    // Tabindex ≥ 0 as a last-resort cue. Real intent unclear (might be
    // a focusable container that doesn't actually want a click), so
    // mark secondClass — dropped in occlusion pass.
    if (!clickable) {
      const tiRaw = el.getAttribute("tabindex");
      const ti = tiRaw == null ? NaN : parseInt(tiRaw, 10);
      if (!Number.isNaN(ti) && ti >= 0) {
        clickable = true;
        secondClass = true;
      }
    }

    if (!clickable) return null;
    return { element: el, secondClass, falsePositive };
  }

  // Pick a viewport-visible client rect for `el`, or null if it
  // doesn't have one. Filters out: zero-size, < 3×3, fully off-screen,
  // visibility:hidden / display:none.
  function visibleRect(el) {
    const rects = el.getClientRects();
    for (const r of rects) {
      if (r.width < 3 || r.height < 3) continue;
      if (r.bottom < 0 || r.top > innerHeight) continue;
      if (r.right < 0 || r.left > innerWidth) continue;
      const cs = getComputedStyle(el);
      if (cs.visibility === "hidden" || cs.display === "none") return null;
      // Clamp to viewport so the rect we report is what's actually
      // visible (matters for partially-off-screen elements that are
      // mid-scroll).
      const left = Math.max(0, r.left);
      const top = Math.max(0, r.top);
      const right = Math.min(innerWidth, r.right);
      const bottom = Math.min(innerHeight, r.bottom);
      return { left, top, right, bottom, width: right - left, height: bottom - top };
    }
    return null;
  }

  // Shadow-DOM-aware elementFromPoint. If the element at (x,y) hosts a
  // shadow root, descend into it recursively until we hit a real
  // element. Stack prevents infinite descent in degenerate cases.
  function deepElementFromPoint(x, y, root, stack) {
    root = root || document;
    stack = stack || [];
    const el = root.elementsFromPoint
      ? root.elementsFromPoint(x, y)[0]
      : root.elementFromPoint(x, y);
    if (!el || stack.includes(el)) return el;
    stack.push(el);
    if (el.shadowRoot) {
      return deepElementFromPoint(x, y, el.shadowRoot, stack) || el;
    }
    return el;
  }

  // 5-point occlusion: center + 4 corners. Element is "on top" if at
  // least one probe finds it (or one of its descendants/ancestors)
  // under the cursor. 0.1 px inset on corners avoids picking up the
  // element immediately to the upper/left when rects exactly touch.
  function isOnTop(el, r) {
    const probes = [
      [r.left + r.width * 0.5, r.top + r.height * 0.5],
      [r.left + 0.1, r.top + 0.1],
      [r.right - 0.1, r.top + 0.1],
      [r.left + 0.1, r.bottom - 0.1],
      [r.right - 0.1, r.bottom - 0.1],
    ];
    for (const [x, y] of probes) {
      const at = deepElementFromPoint(x, y);
      if (at && (el.contains(at) || at.contains(el))) return true;
    }
    return false;
  }

  // Extract a short label for a hint. Priority: rendered text → input
  // value → aria-label → title → alt → empty.
  function labelFor(el) {
    let t = el.innerText;
    if (!t && el.value) t = el.value;
    if (!t) t = el.getAttribute("aria-label");
    if (!t) t = el.getAttribute("title");
    if (!t) t = el.getAttribute("alt");
    return (t || "").trim().replace(/\s+/g, " ").slice(0, 60);
  }

  // Translate viewport-space coords to macOS screen-space (points).
  //
  // `window.screenX/screenY` is the OS window's top-left in CSS px.
  // CSS px on macOS = points, so no DPR conversion. The viewport (web
  // content area) sits INSIDE the window with Chrome's tab bar + URL
  // bar + (optional) bookmarks bar above it; in Chrome on macOS all
  // chrome is at the top, so:
  //   viewportLeftInScreen = window.screenX  (no left chrome to speak of)
  //   viewportTopInScreen  = window.screenY + (outerHeight - innerHeight)
  // Approximate — ignores devtools-docked-right (would shift content
  // left) and the small bottom status-bar slice some browsers draw.
  // Good enough for v1; Mouseless can refine using AX window rect
  // diffing if labels drift on real pages.
  function viewportOriginInScreen() {
    return {
      x: window.screenX,
      y: window.screenY + (window.outerHeight - window.innerHeight),
    };
  }

  // Main entry. Returns an array of hint records in screen coords.
  //
  // opts.viewportOriginInScreen — when present, used verbatim instead
  // of computing from `window.screenX/Y`. Required for **iframes**:
  // `window.screenX` in a child frame returns the top-level window's
  // position (not the iframe's), so the child can't compute its own
  // screen origin alone — its parent has to supply
  //   { x: parentOriginX + iframe.getBoundingClientRect().left,
  //     y: parentOriginY + iframe.getBoundingClientRect().top }
  // and pass it down through postMessage. See content_script.js
  // `gatherHintsRecursive`.
  function listHints(opts) {
    opts = opts || {};
    if (!document.documentElement) return [];

    const all = getAllElements(document.documentElement);
    const cands = [];
    for (const el of all) {
      const c = classify(el);
      if (!c) continue;
      const r = visibleRect(el);
      if (!r) continue;
      cands.push({ ...c, rect: r });
    }

    // Reverse so descendants come before ancestors — the false-
    // positive filter wants to know "is there a clickable descendant
    // of this <span class=btn> within 3 generations". Lookback window
    // of 6 keeps the scan cheap.
    cands.reverse();
    const filtered = cands.filter((c, i) => {
      if (!c.falsePositive) return true;
      const start = Math.max(0, i - 6);
      for (let j = start; j < i; j++) {
        let d = cands[j].element;
        for (let depth = 1; depth <= 3; depth++) {
          d = d && d.parentElement;
          if (d === c.element) return false;
        }
      }
      return true;
    });

    // Occlusion. Skip secondClass items entirely (Vimium pattern —
    // tabindex-only nodes are rarely what the user wants).
    const visible = filtered.filter(c => !c.secondClass && isOnTop(c.element, c.rect));
    visible.reverse();   // restore document order

    const origin = opts.viewportOriginInScreen || viewportOriginInScreen();
    return visible.map(c => ({
      tag: c.element.tagName.toLowerCase(),
      rect: {
        x: Math.round(origin.x + c.rect.left),
        y: Math.round(origin.y + c.rect.top),
        w: Math.round(c.rect.width),
        h: Math.round(c.rect.height),
      },
      text: labelFor(c.element),
      nav: isLikelyNavigating(c.element),
    }));
  }

  // True if clicking this element is highly likely to navigate the
  // current tab to a different URL — used by Mouseless to skip the
  // 100ms post-commit rehint (which would race the page load and hit
  // content_script_unavailable). False positives here aren't fatal:
  // they just mean we'll miss a refresh for an unusual link case;
  // the user can re-trigger.
  //
  // Conservative rules — only true when:
  //   - <a> tag with non-empty href
  //   - href doesn't start with "#" (same-page anchor scroll, no nav)
  //   - href doesn't start with "javascript:" (custom handler, may
  //     or may not navigate; treat as may-not for safety)
  //   - target is not "_blank" (opens in a new tab, current tab
  //     doesn't navigate)
  //
  // Doesn't try to predict SPA pushState — those go through DOM
  // mutation, P4 MutationObserver picks them up anyway.
  function isLikelyNavigating(el) {
    if (el.tagName !== "A") return false;
    const href = el.getAttribute("href");
    if (!href) return false;
    if (href.startsWith("#")) return false;
    if (href.startsWith("javascript:")) return false;
    const target = el.getAttribute("target");
    if (target === "_blank") return false;
    return true;
  }

  // ---------- TAP `/`-search support (browser path) ----------
  //
  // On browser apps, `/`-search in Mouseless uses this DOM-level
  // matcher instead of Vision OCR. Faster (typically <10ms for
  // typical pages vs 80-200ms OCR), 100% accurate (no OCR errors),
  // doesn't need ScreenCaptureKit screenshots. Only matches text
  // **currently in the viewport** — matches the OCR pipeline's
  // implicit "what's on screen" semantics; off-screen matches would
  // need scroll-then-click which we don't model.
  //
  // Returns the same shape as `listHints` (rect in screen coords,
  // text snippet) so the Mouseless side can hand off straight to
  // SearchOverlay without conversion.

  function findTextMatches(query, opts) {
    opts = opts || {};
    if (!query || !document.body) return [];
    const origin = opts.viewportOriginInScreen || viewportOriginInScreen();
    const needle = query.toLowerCase();
    const matches = [];

    // TreeWalker with NodeFilter to cheap-skip text nodes that don't
    // contain the needle or whose parent is hidden — saves us the
    // expense of range arithmetic on those.
    const walker = document.createTreeWalker(
      document.body,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode(node) {
          if (!node.nodeValue || !node.nodeValue.toLowerCase().includes(needle)) {
            return NodeFilter.FILTER_REJECT;
          }
          const parent = node.parentElement;
          if (!parent) return NodeFilter.FILTER_REJECT;
          // <script>, <style>, etc. contents are textually present in
          // the DOM but not user-visible. Skip them.
          const tag = parent.tagName;
          if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT") {
            return NodeFilter.FILTER_REJECT;
          }
          const cs = getComputedStyle(parent);
          if (cs.visibility === "hidden" || cs.display === "none") {
            return NodeFilter.FILTER_REJECT;
          }
          return NodeFilter.FILTER_ACCEPT;
        },
      }
    );

    let node;
    while ((node = walker.nextNode())) {
      const text = node.nodeValue;
      const haystack = text.toLowerCase();
      let from = 0;
      while (from < haystack.length) {
        const idx = haystack.indexOf(needle, from);
        if (idx < 0) break;
        try {
          const range = document.createRange();
          range.setStart(node, idx);
          range.setEnd(node, idx + needle.length);
          // getClientRects returns one rect per line — for multi-line
          // wraps we emit a separate match per visual line.
          for (const r of range.getClientRects()) {
            if (r.width < 2 || r.height < 2) continue;
            if (r.bottom < 0 || r.top > innerHeight) continue;
            if (r.right < 0 || r.left > innerWidth) continue;
            const left = Math.max(0, r.left);
            const top = Math.max(0, r.top);
            const right = Math.min(innerWidth, r.right);
            const bottom = Math.min(innerHeight, r.bottom);
            matches.push({
              rect: {
                x: Math.round(origin.x + left),
                y: Math.round(origin.y + top),
                w: Math.round(right - left),
                h: Math.round(bottom - top),
              },
              text: text.substr(idx, needle.length),
            });
          }
        } catch (e) {
          // Range manipulation can throw on detached / odd nodes;
          // skip them silently.
        }
        from = idx + needle.length;
      }
    }
    return matches;
  }

  // ---------- App-switch cursor park (browser path) ----------
  //
  // Mouseless drops the cursor into a text input on app activation
  // when the user was last typing there. Chrome's AX is unreliable
  // for web content focus (renderer accessibility is off by default)
  // — DOM resolves this in microseconds with 100% accuracy. Same
  // priorities as the native AX path:
  //   1. document.activeElement, if it's a text input
  //   2. First visible <input> / <textarea> / contenteditable in
  //      the top frame's viewport
  //   3. nil → caller falls back to title-bar landing
  //
  // Top-frame only for v1 — iframe-hosted main inputs (Notion, Figma)
  // would need postMessage recursion; defer until that case matters.

  function isTextInputEl(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el.disabled || el.readOnly) return false;
    const tag = el.tagName;
    if (tag === "INPUT") {
      const type = (el.getAttribute("type") || "text").toLowerCase();
      // Non-text input types — clicking them doesn't help a keyboard
      // user resume typing.
      const NON_TEXT = new Set([
        "hidden", "button", "submit", "reset",
        "checkbox", "radio", "image", "file",
        "color", "range",
      ]);
      return !NON_TEXT.has(type);
    }
    if (tag === "TEXTAREA") return true;
    if (el.isContentEditable) return true;
    return false;
  }

  function isElVisible(el) {
    const cs = getComputedStyle(el);
    if (cs.visibility === "hidden" || cs.display === "none") return false;
    return true;
  }

  function rectInScreen(r, origin) {
    if (r.width < 4 || r.height < 4) return null;
    if (r.bottom < 0 || r.top > innerHeight) return null;
    if (r.right < 0 || r.left > innerWidth) return null;
    const left = Math.max(0, r.left);
    const top = Math.max(0, r.top);
    const right = Math.min(innerWidth, r.right);
    const bottom = Math.min(innerHeight, r.bottom);
    return {
      x: Math.round(origin.x + left),
      y: Math.round(origin.y + top),
      w: Math.round(right - left),
      h: Math.round(bottom - top),
    };
  }

  function findFirstInput(opts) {
    opts = opts || {};
    const origin = opts.viewportOriginInScreen || viewportOriginInScreen();

    // (1) document.activeElement — the canonical "last edited here"
    // signal. Works on the top frame; iframe-internal active elements
    // surface here as the iframe element itself (we'd need to recurse
    // into the iframe via postMessage to drill in; deferred).
    const focused = document.activeElement;
    if (focused && focused !== document.body && isTextInputEl(focused) && isElVisible(focused)) {
      const r = rectInScreen(focused.getBoundingClientRect(), origin);
      if (r) {
        return { rect: r, source: "activeElement" };
      }
    }

    // (2) First visible text input in document order.
    const candidates = document.querySelectorAll(
      "input, textarea, [contenteditable=true], [contenteditable='']"
    );
    for (const el of candidates) {
      if (!isTextInputEl(el)) continue;
      if (!isElVisible(el)) continue;
      const r = rectInScreen(el.getBoundingClientRect(), origin);
      if (r) {
        return { rect: r, source: "first_visible" };
      }
    }
    return null;
  }

  window.MouselessDetector = { listHints, findTextMatches, findFirstInput };
})();
