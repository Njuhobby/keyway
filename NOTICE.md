# NOTICE

Mouseless
Copyright (c) 2026 Yihao Jiang and contributors

Licensed under the GNU Affero General Public License v3.0 or later
(AGPL-3.0-or-later). See [LICENSE](LICENSE) for the full terms.

Except for the third-party material listed below, the source in this
repository is original work.

---

## Third-party material

### 1. OmniParser icon-detection model

- **Where**: `prototype/Sources/Mouseless/icon_detect.mlpackage`
- **What**: the CoreML model bundled for the on-device vision fallback is the
  icon detector from **Microsoft OmniParser** (OmniParser-v2.0,
  `icon_detect/model.pt` from the `microsoft/OmniParser-v2.0` model repo),
  exported to CoreML.
- **License**: the detector is built on **Ultralytics YOLO**, whose weights
  are licensed under **AGPL-3.0**. Because this model is bundled and the AGPL
  is viral over the combined work, the entire Mouseless project is licensed
  AGPL-3.0-or-later (this is the reason for the project's license choice).
- **Upstream**:
  - OmniParser — https://github.com/microsoft/OmniParser (Microsoft)
  - Ultralytics YOLO — https://github.com/ultralytics/ultralytics (AGPL-3.0)

### 2. Vimium (browser-extension element detection)

- **Where**: `prototype/extension/detector.js`
- **What**: the clickable-element classification rules and the
  visibility / occlusion heuristics are **adapted** from Vimium's
  `content_scripts/link_hints.js` — reimplemented in clean code, not vendored
  verbatim.
- **License**: MIT. Copyright (c) 2010 Phil Crosby, Ilya Sukhar.
- **Upstream**: https://github.com/philc/vimium
- **Details**: the full MIT license text and a precise breakdown of exactly
  which rules were adapted live in
  `prototype/extension/vendor/vimium/MIT-LICENSE.txt` and
  `prototype/extension/vendor/vimium/NOTICE.md`.
