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

  // Main entry. Returns an array of hint records.
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

    return visible.map(c => ({
      tag: c.element.tagName.toLowerCase(),
      rect: {
        x: Math.round(c.rect.left),
        y: Math.round(c.rect.top),
        w: Math.round(c.rect.width),
        h: Math.round(c.rect.height),
      },
      text: labelFor(c.element),
    }));
  }

  window.MouselessDetector = { listHints };
})();
