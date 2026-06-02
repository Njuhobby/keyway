# Browser Support — Chrome / Safari 扩展 + Native Messaging

**状态**：设计草稿，未实现。优先级：**高**——浏览器占用户日常 30%+ 时间，是 Mouseless"一套心智模型覆盖所有 app"产品论点的关键缺口。

---

## 1. 为什么要做

Mouseless 的产品立论是 *"按 Caps Lock，所有 app 一套心智模型"*——sticky / shift 加速 / hjkl 移光标 / drag / 未来的新 mode……全在一个统一交互模型里。一旦"浏览器请用 Vimium"，这个论点立刻失效：

- **Sticky 在浏览器不可用**——Vimium 是 hint-跳-按-退的一次性流程
- **shift 加速滚动 / hjkl 拖光标 / DRAG**——浏览器 JS 发的 mouseEvent 不是真鼠标，做不了。Mouseless 用 OS 级 `CGEvent` 才能真的"拖动 Figma 元素 / Google Maps 画布"
- **未来新 mode 自动跟进**——每加一个 mode 不能都回答"那浏览器里怎么办"

**当前现状**：Chrome / Safari 都不在 `AppRegistry.AX_FOCUSED_WHITELIST`，走 OP（ScreenCaptureKit + YOLO + OCR refiner）。痛点：

- 网页可点的不只是文字按钮——很多链接 icon、`<div onclick>`、`[role=button]`、SPA 框架渲染的伪按钮——OP 视觉路径覆盖率低
- 折叠区下面的元素没 render，OP 看不到（DOM 里有）
- React/Vue 等框架的 ARIA 卫生参差，强开 AX 树（`--force-renderer-accessibility`）也不解决问题

**`/`-search 已经是 partial workaround**——用户能"OCR 看见啥就点啥"，对纯文字链接够用，但 icon-only 按钮 / 复杂 SPA 不行。

---

## 2. 架构

```
            ┌─────────────────────────────────┐
            │  Chrome / Safari                │
            │  ┌───────────────────────────┐  │
            │  │ Mouseless 扩展            │  │   JS, 跑在浏览器沙箱里
            │  │  - background.js (SW)     │  │
            │  │  - content_script.js      │  │   每个 tab / iframe
            │  │  - detector (借鉴 Vimium) │  │   ← MIT, 抠核心模块
            │  └────────┬──────────────────┘  │
            └───────────│─────────────────────┘
                        │ chrome.runtime.connectNative()
                        │ stdin/stdout, 长度前缀 JSON
            ┌───────────▼─────────────────────┐
            │ Native Messaging Host           │   Swift CLI binary
            │ (mouseless-bridge)              │   浏览器 spawn,
            │                                 │   生命周期归浏览器管
            └───────────┬─────────────────────┘
                        │ Unix domain socket
                        │ ~/Library/Application Support/Mouseless/bridge.sock
            ┌───────────▼─────────────────────┐
            │ Mouseless 主进程                │   既有 Swift app
            │  - BrowserProvider             │   新增：跟 AXProvider / OPProvider
            │  - 复用现有 HintMode / Overlay │      并列的第三个 hint source
            └─────────────────────────────────┘
```

**三个进程的职责分工**：

| 进程 | 责任 |
|---|---|
| **扩展（每 tab）** | 检测当前 viewport 内可点元素 + 给元素分配稳定 ID + 收 main process 的 "click ID=X" 指令 + 滚动 / DOM 变化时主动失效 |
| **bridge host** | stdio ↔ Unix socket 双向 forward；用户 launch 浏览器后被自动拉起；进程很轻（≈200 LOC Swift） |
| **Mouseless 主进程** | 检测 frontmost 是 Chrome/Safari → 走 BrowserProvider 而非 OP；收到 hint 列表用现有 `HintOverlay` 渲染；commit 后告诉扩展点哪个 ID |

---

## 3. 协议

```jsonc
// Mouseless → extension
{ "cmd": "list_hints",
  "viewport_only": true,           // 只要当前可见，避免 SPA 内大量隐藏节点
  "include_text": true             // 让 /-search 可以用 hint text 匹配
}

// extension → Mouseless
{ "type": "hints",
  "tab_id": 12,
  "main_frame_rect": { "x": 0, "y": 0, "w": 1440, "h": 800 },   // 在屏幕坐标系
  "hints": [
    { "id": "h1", "rect": { "x":120,"y":340,"w":40,"h":20 }, "text": "Sign in", "kind": "link" },
    { "id": "h2", "rect": { "x":200,"y":340,"w":80,"h":20 }, "text": "Sign up", "kind": "button" },
    ...
  ]
}

// Mouseless → extension（commit）
{ "cmd": "activate", "tab_id": 12, "id": "h2", "modifier": "none" }   // none / shift / option
// 或：
{ "cmd": "activate_at_cursor" }                                       // CGEvent click 已发，扩展不用动

// extension → Mouseless（DOM 变化，主动失效当前 hint 集）
{ "type": "invalidate", "tab_id": 12, "reason": "scroll" }
```

**坐标系**：扩展返回的 rect 已经是 **macOS 屏幕全局坐标** （top-left origin），通过 `window.screenX/Y + window.devicePixelRatio + el.getBoundingClientRect()` 算出来。Mouseless 端拿到不用再变换，直接喂给 `HintOverlay`。

**click commit 双路**：

- 默认 `activate_at_cursor` —— Mouseless 已经把光标 warp 到 hint 中心、合成 `CGEvent` click。**用真鼠标事件好处大**：浏览器、`<canvas>`、Flash-likes、复杂 SPA 全都正确响应。
- 可选 `activate` —— 让扩展用 DOM `.click()` 触发。少数场景下（元素在视口外但 DOM 里存在；或者真鼠标 click 被 stop-propagation）后备用。

---

## 4. Vimium 借鉴清单

Vimium 是 **MIT 协议**，可商用，要求 attribution + 保留 LICENSE。

抄它的核心是 **content script 里的 hint detection 逻辑**——12 年迭代踩出来的 corner case 处理是最值钱的部分：

| Vimium 模块 | 我们用来做什么 | 难度 |
|---|---|---|
| `link_hints.coffee` 的可点选择器 | 决定哪些元素值得 hint | 中——多年补充的边缘 selector |
| `dom_utils.coffee` 的可见性 / 遮挡判断 | 排掉 `visibility:hidden`、`opacity:0`、被 z-index 高的遮住的 | **高**——Vimium 最值钱的部分 |
| iframe 跨 origin 协调 | main frame + iframe 各自有 content script，要协调成一份 hint list | 高 |
| Shadow DOM 穿透 | Web Components 的 shadow root 内可见元素枚举 | 中——但越来越常见 |
| scrollable ancestor 检测 | j/k 滚动时找最近的可滚容器（不止 window） | 中——给 SCROLL mode 用 |

**不用**它的：

- Hint label 渲染（它在页面里 inject `<div>`；我们让 Mouseless 的 `HintOverlay` 画）
- Modal key 状态机（Mouseless 自己有 mode 系统）
- 浏览器命令（H 后退 / t 新 tab / x 关闭——这些走 OS 浏览器快捷键）
- Options UI / help dialog

**License 处理**：

- 抄过来的文件顶部保留 Vimium copyright header + MIT 文本
- 我们 extension `README.md` 注明 "Hint detection adapted from Vimium (https://github.com/philc/vimium), MIT License"
- 不要求我们整个项目开源，不要求把改动回贡

---

## 5. 实施路线图（P0 → P5）

### P0 — 概念验证（半天）

最小可演示：硬编码一个 hardcoded selector（`a, button`），在 Chrome 一个固定测试页（如 https://github.com）上：

1. 写最小 manifest + content script，console.log 出可点元素列表
2. 不连 Mouseless，目的只是验证"在浏览器内拿到可点元素+坐标"这一步通

**验收**：console 里打出 N 个 `{rect, text}` JSON。

### P1 — Native Messaging Host + 协议 stub（1-2 天）

1. 写 `mouseless-bridge` Swift CLI（~200 LOC）：stdin 长度前缀 JSON 读取 + stdout 长度前缀 JSON 写出
2. Mouseless 主进程开 Unix socket listener，bridge 跟它互发 echo
3. 注册 host manifest 到 `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.mouseless.bridge.json`
4. 扩展 background script `chrome.runtime.connectNative('com.mouseless.bridge')`，发一条 ping，主进程 echo 回来

**验收**：从扩展按一个按钮，能在 Mouseless 主进程 log 看到消息，且回包能传回扩展并在 console 显示。

### P2 — 检测模块剥离 + 接入（2-3 天）

1. fork Vimium，抠 `link_hints.coffee` + `dom_utils.coffee` + iframe 协调相关的最小子集（编译输出 / 用现成 vimium-c 的 TS 版也可以——确认许可后选）
2. 包装成 `detector.js`，导出 `listHints(viewportOnly: bool): Hint[]`
3. content script 注入 `detector.js`，定期或按 background 请求调它，把结果发给 background
4. background 收 `list_hints` 命令 → 转发给当前 active tab 的 content script → 取回 hint list → 通过 native messaging 发给 Mouseless

**验收**：Mouseless 主进程能收到 GitHub 首页所有可点元素的 rect + text，数量级跟 Vimium 按 f 时画的差不多。

### P3 — Mouseless 端 BrowserProvider + Overlay 渲染（1-2 天）

1. 新文件 `BrowserProvider.swift`，跟 `OPProvider` / AX walk 并列
2. `HintMode` 在 frontmost bundleID 是 Chrome / Safari 时走 BrowserProvider 而非 OP
3. BrowserProvider 通过 Unix socket 给 bridge 发 `list_hints`，timeout 200ms，失败 fallback 到 OP
4. 收到 hint 列表后转成 `HintTarget`，喂进现有 `HintOverlay` 渲染

**验收**：在 Chrome 上按 Caps Lock，看到 hint label 准确落在所有可点元素上（不是 OP 那种"只看到一半"的状态）。

### P4 — Click commit + 滚动失效（1 天）

1. 用户按 hint 字母 → Mouseless 触发现有 commit 流程：warp cursor 到 hint 中心 + 合成 `CGEvent` click
2. 扩展 content script 监听 scroll / DOM mutation，>50ms debounce 后发 `invalidate` 给 Mouseless
3. Mouseless 收 invalidate 时如果还在 TAP sticky mode 则触发 re-hint

**验收**：在 Gmail / Twitter / Notion 这种 SPA 上 sticky 模式连点 5 个对象，每次都准。

### P5 — Safari 适配 + 打包上架（3-5 天）

1. Safari Web Extension：用 Xcode 的 "Safari Web Extension App" 模板包一层 macOS app
2. Safari 的 Native Messaging API 跟 Chrome 略有差异——主要是 host 注册路径和 manifest 格式
3. Apple 签名（Developer ID 或 App Store）
4. Chrome Web Store 提交：写隐私声明、做 icon、列权限理由
5. README 加用户安装指引

**验收**：装上扩展后即用，不要求开 Develop menu 或其他用户手动设置。

### 总投入估算

| 阶段 | 天数 |
|---|---|
| P0 – P4（功能完整 MVP, Chrome only） | **5-8 天** |
| P5 Safari + 上架准备 | **3-5 天** |
| 总计 | **~10 天到能给用户用** |

跟从零写比节省 **3-5 天**——主要省在 P2 的 detection 边缘 case 不用自己再爬。

---

## 6. 风险 & 已知坑

| 风险 | 缓解 |
|---|---|
| **iframe 跨 origin** | content script 注入到所有 frame；每个 frame 各报各的 hints + offset；background 合并。Vimium 已经处理好，照抄。 |
| **Shadow DOM** | Vimium 的 detector 支持递归 shadow root，照抄 |
| **`<canvas>` 上的 UI（Figma / Google Maps）** | DOM 里只有一个 `<canvas>`——任何 DOM 路径都歇菜。降级到 OP。BrowserProvider 没拿到 hint 时主动降级。 |
| **Chrome Web Store 审核宽权限** | 需要 `<all_urls>` host permission——会触发"宽权限审核"，过审稍慢。文案上说明"需要在所有网页上识别可点元素"。 |
| **Manifest V3 限制** | Service Worker 会被 Chrome 主动 unload；保持长连接要重连机制 |
| **Safari 扩展 API 不完全对齐 Chrome** | 主要是 `chrome.runtime.connectNative` 在 Safari 的等价 API（`browser.runtime.connectNative`）；调用约束略不同 |
| **bridge host 没装** | Mouseless 端 BrowserProvider 在 frontmost 是 Chrome 但 socket 连不上时，HUD 提示一次 + 降级到 OP，不阻断 |
| **用户没装扩展** | 同上——扩展不在时扩展端不会发数据，主进程超时降级到 OP |
| **Mouseless 主进程没启动时浏览器收到消息** | bridge host 发现 socket 不可达 → 给扩展回 `{"type":"error","reason":"main_process_not_running"}` → 扩展 console 警告，不影响浏览器 |

---

## 7. 跟现有 OP / AX 路径的关系

- **不替换 OP**——OP 仍是 fallback。canvas-only UI / 扩展没装 / bridge 连不上 → 自动 OP
- **不影响 AX whitelist 路径**——native macOS app 走 AX walk 不变
- **路由决策点**：`HintMode` 启动时拿 frontmost bundleID，匹配新加的 `BROWSER_BUNDLE_IDS = { "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox" }` → 走 BrowserProvider，timeout 后才降级到 OP

---

## 8. 后续 / 衍生

- **Firefox** —— Manifest V3 兼容后基本免费跟进（V2 时代要 polyfill）
- **Arc / Brave / Edge** —— 都是 Chromium 系，理论上同一个扩展 .crx 包能装；但分别上架需要各自的应用商店账号
- **多 tab hint** —— v1 只 hint 当前 active tab；将来可能扩展到所有 tab（让 Mouseless 帮你切 tab 时直接落点）
- **per-site clickable 修正** —— 类似 `per-app-correction-design.md`，特定网站的 selector 补充（YouTube 的 video 控制按钮、Notion 的 inline button 等）
- **DOM 级 `/`-search** —— 扩展返回的 hint list 自带 text，`/`-search 可以直接 fuzzy 匹配，比 OCR 准
