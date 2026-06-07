# Vimium attribution

Mouseless's clickable-element detector (`prototype/extension/detector.js`)
adapts the classification rules and visibility / occlusion heuristics
from [Vimium](https://github.com/philc/vimium)'s
`content_scripts/link_hints.js` (the `LocalHints` object, approximately
lines 1068–1460). Vimium is © 2010 Phil Crosby, Ilya Sukhar, licensed
MIT — see `MIT-LICENSE.txt` next to this file.

We did not vendor the source as-is. The classification rules are
factual / functional and are reimplemented in clean code in our
file, but Vimium is the origin of:

- the comprehensive clickable-tag list (a, button, input, select,
  textarea, object, embed, label, details, img, div, ol, ul, body)
- the ARIA role allow-list (button, tab, link, checkbox,
  menuitem{,checkbox,radio}, radio, textbox)
- the `onclick` / `contenteditable` / `tabindex` / `jsaction`
  attribute checks (including the parsing of `jsaction` rules)
- the AngularJS `ng-click` / `data-ng-click` / `x-ng-click`
  attribute family (with `-`, `:`, `_` separator variants)
- the `class*="button"` / `class*="btn"` heuristic with
  false-positive flagging
- the `aria-disabled` opt-out
- the false-positive filter (drop class-detected items whose
  descendant within 3 levels is also clickable, lookback window 6)
- the 5-point `elementFromPoint` occlusion test (center + 4 corners
  with 0.1px inset)
- the shadow-DOM-aware `getAllElements` + `elementFromPoint`
  traversal pattern

Source pin: rules taken from commit on `master` retrieved 2026-06-03.
When pulling in upstream fixes (e.g., shadow-root occlusion improvements,
new framework heuristics), reference the date and commit SHA here so
divergence is traceable.

(Note: an earlier iteration of the in-page d/u scroller adapted Vimium's
`content_scripts/scroller.js`; that was replaced — Mouseless now detects
the keys in the content script but delegates the actual scroll to the
native side, which posts a real OS scroll-wheel event. No Vimium scroller
code remains.)
