# Browser Support — Chrome / Safari 扩展 + Native Messaging

**状态**（2026-06）：

| Phase | 状态 |
|---|---|
| P0 装机 PoC | ✅ |
| P1 通讯骨架（BridgeServer / mouseless-bridge CLI / 扩展长连接） | ✅ |
| P2-A 检测器（Vimium 规则改写） | ✅ |
| P2-B iframe 跨 frame 协调（postMessage 链） | ✅ |
| P3 `BrowserProvider` 接入 HintMode | ✅ |
| P4 异步加载 `page_changed` 触发 in-place rehint（leading+trailing 节流）| ✅ |
| 增量补丁：多 profile / 多浏览器 `i_am_active` 路由 | ✅ |
| 增量补丁：同窗口换 tab 的 `tab_changed` 信号 | ✅ |
| 增量补丁：SW 启动 auto-inject 已存在的 tab | ✅ |
| 增量补丁：navigation_complete 信号（`tabs.onUpdated status=complete`） | ✅ |
| 增量补丁：anchor link commit 跳过 100ms post-commit rehint | ✅ |
| 增量补丁：`/`-search 在浏览器走 DOM TreeWalker 取代 OCR | ✅ |
| 增量补丁：app-switch cursor park 在浏览器走 DOM (`document.activeElement` / 第一个可见 input) | ✅ |
| P5 Safari Web Extension + 上架 | ⏳ 未开始 |

Chrome 上**功能层面已可 daily-drive**。Safari 等 P5。

详细的 commit 链：`fb2ccde` (P0) → `130297e` (P1.1) → `f08a775` (P1.2) → `3c62077` (P1.3) → `a89caee` (P2-A) → `01a5fa8` (P2-B) → `59d4f54` (P3) → `fd7efa6` (P4) → `afd41bc` (multi-route) → `374ea21` (browser path 自治) → `0413c85` (auto-inject) → `76dd2a3` (tab_changed) → `ebcb371` (navigation_complete) → `8df297b` (anchor skip 100ms rehint) → `d68a7d5` (DOM /-search) → `1df5c64` (DOM cursor park) → `a614792` (page_changed leading+trailing 节流，修连切 tab)。

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

### P0 — 概念验证（半天）✅

最小可演示：硬编码一个 hardcoded selector（`a, button`），在 Chrome 一个固定测试页（如 https://github.com）上：

1. 写最小 manifest + content script，console.log 出可点元素列表
2. 不连 Mouseless，目的只是验证"在浏览器内拿到可点元素+坐标"这一步通

**验收**：console 里打出 N 个 `{rect, text}` JSON。

### P1 — Native Messaging Host + 协议 stub（1-2 天）✅

1. 写 `mouseless-bridge` Swift CLI（~200 LOC）：stdin 长度前缀 JSON 读取 + stdout 长度前缀 JSON 写出
2. Mouseless 主进程开 Unix socket listener，bridge 跟它互发 echo
3. 注册 host manifest 到 `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.mouseless.bridge.json`
4. 扩展 background script `chrome.runtime.connectNative('com.mouseless.bridge')`，发一条 ping，主进程 echo 回来

**验收**：从扩展按一个按钮，能在 Mouseless 主进程 log 看到消息，且回包能传回扩展并在 console 显示。

### P2 — 检测模块（2-3 天）

#### P2-A 检测器规则改写 ✅

**偏离原计划**：原计划是"fork Vimium 抠模块"，实际是**借鉴规则重写**——Vimium 的 `LocalHints` 严重依赖 6 个 Vimium-internal 全局（Settings / Utils / DomUtils / Rect / HUD / HintCoordinator），stub 比 rewrite 还麻烦。改成把 Vimium 的事实性 know-how（选择器列表、ARIA roles、jsaction 规则、可见性判断、5 点遮挡探测、shadow DOM 递归）搬过来在 `detector.js` 干净重写。许可方面保留 `vendor/vimium/MIT-LICENSE.txt` + `NOTICE.md` attribution。

#### P2-B iframe 协调 ✅

**偏离原计划**：原计划提到"路 1（推荐）用 `chrome.scripting.executeScript({allFrames: true})`"和"路 2（Vimium 那套）postMessage 链"。**实际选了路 2 风格**——iframe 协调用 `window.postMessage` 在 frame 树上递归请求/响应。理由：

- 不需要新加 `scripting` permission（当时）
- 每个 frame 独立报自己的 hint，父 frame 算"父 origin + iframe.getBoundingClientRect" 给子 frame 当 viewport origin → 嵌套 iframe 免费递归
- 比 `executeScript` 跨 origin 限制少

各 frame 之间消息类型：
- `mouseless_hints_request {id, origin}` → 父让子收集
- `mouseless_hints_response {id, hints}` → 子返回（屏幕坐标 hint 列表）
- `mouseless_page_changed_inner` → 子向父冒泡 "我这里有新可点元素"
- 250ms 超时兜底（sandboxed / chrome:// iframe 不响应）

### P3 — Mouseless 端 BrowserProvider + Overlay 渲染（1-2 天）✅

实现要点：

- 新文件 `Sources/Mouseless/BrowserProvider.swift`
- `HintSource` 新增 `case .browser`（commit 时跟 `.ax` 走同一条 `MouseSynth.click` 中心点击路径，浏览器自家 hit-test 自动路由）
- `HintMode.collectAll` 在 `AppRegistry.isBrowserApp(bundleID:)` 时走 BrowserProvider 分支
- `BridgeServer.sendToActive` 写 socket → bridge 转 stdio → 扩展 SW → content_script → detector → 反向回流；Mouseless 端 `awaitResponse(ofType:"hints", timeout:0.4)` async 等
- **偏离原计划**：`fetchHints` 超时返回的不是 nil → fallback OP，而是 `[]` 直接接受。详见 §7 "浏览器路径自治"

### P3.5 — 多 profile / 多浏览器路由（增量）✅

原计划没考虑同一时刻有多个扩展客户端连着。实际场景常见：用户同时开 Chrome Profile A + Profile B（每个 profile 是独立扩展安装 = 独立 SW = 独立 bridge 进程 = 独立 socket 连接到 Mouseless）。

错的话很难看：用户在 Profile A 按 Caps Lock，Mouseless 把 list_hints 发到最后连上的 fd（可能是 Profile B），Profile B 返回它自己 active tab 的 hints，画在 Profile A 上。

**修法**：

- 扩展端 `chrome.windows.onFocusChanged` 监听 → SW 发 `{type: "i_am_active"}` 给 Mouseless。SW 启动时也用 `chrome.windows.getLastFocused` 主动 probe 一次（startup race 兜底）。
- `BridgeServer.activeFD` 不再在 accept 时设置，**只在收到 `i_am_active` 时跟着切**。
- ping 带 `browser` 身份字段（`"chrome"/"edge"/"brave"/"safari"/...` 从 UA 反推）。
- `sendToActive(_, expectingBrowserBundleID:)` 给当前 frontmost bundleID 与 active fd 的 identity 做匹配 — 不匹配 refuse（避免"Safari 是 frontmost 但只有 Chrome 扩展在线时把 list_hints 发给 Chrome bridge 拿到 Chrome 的 hints 画在 Safari 上"）

### P4 — 异步加载感知的 hint 刷新 ✅

**偏离原计划**：原计划 "scroll / DOM mutation 失效" 范围太宽。实际**砍掉了 scroll 失效**——Mouseless UX 里滚动必须进 SCROLL mode，不会出现"sticky TAP 中滚动 → hint 飘到错位置" 的场景。**留下 DOM mutation**，因为这是 Vimium 也没解决的 daily-use 痛点（用户进 TAP 时页面正在 lazy load，hint 不全；等几秒后再补）。

机制：

- **扩展端**：每个 frame content_script 装 `MutationObserver`。"有新可点"时 top frame 直接 `chrome.runtime.sendMessage` 给 SW；iframe 用 `mouseless_page_changed_inner` postMessage 给父，父递归向上中继到 top 才出局。
  - **扩展端也节流(leading+trailing, 500ms)**：原来 callback 只用 selector 早 return 过滤"没新可点"的 mutation,但**正在播放的 YouTube** 这类页面**一直在增删可点元素**(推荐位/播放器控件),`hasNewClickable` 频繁返回 true → 每秒几十次 `sendMessage`,既刷爆 bridge 又把 content script **主线程**占住,导致 `list_hints` 在 Mouseless 的 400ms 预算内回不出(→ 0 web hints)。所以节流挪到 observer callback **最开头**:冷却窗口内**直接 return**,连 `hasNewClickable`(里面是 `querySelector`,真正烧主线程的那块)都跳过,只排一个 trailing 兜底。关键:`lastFireAt` 只在**真发了**(leading 检测到真可点 / trailing)才前进,所以"一直变但从不加可点元素"的页面永不进 skip 分支、不会乱发。这层和 Mouseless 端的节流互补——扩展端治源头(主线程过载 + bridge 刷屏),Mouseless 端治"别过度重扫 + 多源合并(还有 iframe / `navigation_complete` / `tab_changed`)+ 最终状态兜底"。
- **Mouseless 端**：BridgeServer handler 路由 `{type: "page_changed"}` → `VimSession.handlePageChanged` → **leading+trailing 节流(500ms)** + 4 道闸：in TAP + frontmost 是 browser + `tapSub == .normal`（不在 drag/search 子状态） + `typed` 前缀为空（不打断用户选 label）。全过 → `HintMode.refreshInPlace` —— **不 deactivate + 不 hide + 不重 activate**，直接 `applyCollected` 重 fetch hints + `HintOverlay.show(targets: new, typed: typed)` 原地替换 targets，**零闪烁**。
  - **节流为什么是 leading+trailing 而非纯 leading**：纯 leading（窗口内事件全丢）对"连切 tab"会出错 —— tab1→tab2→tab3→tab4 快连，第一次刷到 tab2、后面被 cooldown 丢，overlay 停在 tab2 而用户在 tab4。改成 leading+trailing：窗口外立即刷（leading，保 streaming 及时性），窗口内排**一个** trailing 在窗口末尾再刷一次、读 THEN-当前的 tab（最终状态赢）。频率上限仍被 500ms cooldown 钉死（trailing 不增频，只补最终状态），所以防 Gmail/Slack DOM 井喷的目标只增不减。`performPageChangedRefresh` 在真正执行时**重新过一遍 4 道闸**（trailing 调度到 fire 之间状态可能变），stale fire 安全 no-op。`pendingPageChangedTrailing` 在 `exit()` 取消。
- **HintMode 改造**：原 `activate` 里"label 分配 + targets writeback"提到 `applyCollected(_:)` 共用，`activate` 跟新加的 `refreshInPlace(isolateApp:)` 都走它。前者初次进入会清 `typed` + 设 `isActiveFlag = true`；后者保留两者。

### P4.5 — 同窗口换 tab 的 `tab_changed`（增量）✅

P4 解决了"同 tab 内 DOM 变化"，但**同窗口切 tab**（Cmd+1/2/3 / 点 tab strip / Cmd+\[\] navigation）是另一个盲区：

- NSWorkspace.didActivateApplication：不 fire（同 app）
- activeSpaceDidChange：不 fire
- 150ms `focusedWindowPoll`：AXFocusedWindow 还是同一个 NSWindow → 不触发
- chrome.windows.onFocusChanged：不 fire（window 没变）
- content_script MutationObserver：通常不 fire（tab 切换是 visibility 切换，DOM 没真改）

**修法**：扩展端 `chrome.tabs.onActivated` 监听器；过滤"是不是这个 profile 当前 focused window 内的 tab 切"；发 `{type: "tab_changed"}` 给 Mouseless。Mouseless 端 handler 把 `tab_changed` 跟 `page_changed` 走同一条路径（reuse `handlePageChanged()`，UX 行为完全一致）。

### P4.6 — SW 启动 auto-inject 已开 tab（增量）✅

Chrome 扩展开发的 #1 footgun：**reload 扩展不会重新注入到已经打开的 tab**——manifest 的 `content_scripts` 只在 tab navigation 之后才注入。pre-existing tab 没有 content script（或者是旧版本），bg 用 `tabs.sendMessage` 失败报 `Receiving end does not exist`。

**修法**：扩展 manifest 加 `"scripting"` permission + `"host_permissions": ["<all_urls>"]`。SW 连上 native bridge 时遍历所有 tab 调 `chrome.scripting.executeScript({target: {tabId, allFrames: true}, files: ["detector.js", "content_script.js"]})`。chrome:// / Web Store 等不允许 inject 的 tab 自然 reject（catch + 计数为 skipped，不算 error）。dev 迭代不再每次 reload 都要挨个刷标签页。

### P4.7 — `navigation_complete` 信号（增量）✅

P4 的 MutationObserver 只看"新加入 DOM 的 clickable"，但**用户点链接触发整页 navigation** 时新页面的初始 DOM 是一次性渲染齐的、不是逐步加进来的，MutationObserver fire 不了。同时 sticky 的 100ms post-commit rehint 会落在 navigation 中间，content script 尚未在新 DOM 上 inject → 收到 `content_script_unavailable` → 显示 0 web hint。

**修法**：扩展端 `chrome.tabs.onUpdated` 监听 `changeInfo.status === "complete"`（页面加载完成），过滤"focused window 的 active tab"，发 `{type: "page_changed", reason: "navigation_complete", url, tabId}` 给 Mouseless。Mouseless 端走现成的 `handlePageChanged` 通路。`reason` 字段纯调试用，handler 不区分（同样 4 道闸 + refreshInPlace）。

### P4.8 — Anchor link commit 跳过 100ms post-commit rehint（增量）✅

承接 P4.7：即便加了 navigation_complete 通知，100ms 那次 rehint 仍然会**先**踩到 content_script_unavailable、把 overlay 替换成"只剩 Dock + menubar 的 65 个 hint"中间态，user 看到一段诡异的"只剩 Dock"窗口，过几百毫秒才被新页面 hint 覆盖。直接**跳过这次 rehint** 就好——根本不让它跑到那个失败状态。

**修法分扩展端 + Mouseless 端**：

- `detector.js` 给每个 hint 多带一个 `nav: bool` 字段。`isLikelyNavigating(el)` 判定：tag === "a"，href 非空且不以 `#` 开头、非 `javascript:` 开头，target ≠ `_blank`
- `BrowserProvider.Hint` 加 `navigates: Bool`；`HintSource.browser` 改成 `case browser(navigates: Bool)` 携带
- `HintMode` 跟踪 `lastCommittedTarget`（survives `deactivate`），让 VimSession 在 `.committed` 分派后能查
- `VimSession` 在 sticky `.committed` 路径里：`if case .browser(true) = lastCommittedTarget.source` → 跳过 `scheduleStickyRehint`。tabs.onUpdated 完成时的 page_changed 会接管重画

**不影响**：非 anchor browser hint（button / role=button / div+onclick 等）、AX hint、OP hint —— 这些 commit 后仍然走 100ms rehint（同页 DOM 变化场景需要它）。同页 `#section` anchor、`javascript:` URL、`target=_blank` 也走 100ms rehint（这些**不真 navigation**）。

### P4.9 — `/`-search 在浏览器走 DOM（增量）✅

`/`-search 在浏览器里也一直走 Vision OCR + ScreenCaptureKit（80-200ms，且 OCR 偶有读错）—— 扩展已经在了，DOM 文本随手拿得到，没理由不用。

**实现**：

- `detector.js` 新加 `findTextMatches(query, opts)`：TreeWalker 走 `document.body` 的 text node，NodeFilter 早过滤掉不包含 needle 的 / `<script>`、`<style>`、`<noscript>` / `display:none` / `visibility:hidden` 的。每个 match 用 `Range.getClientRects()` 拿 viewport 内的 rect（多行 wrap 自动每行一条 match）。viewport 外的不返回（跟 OCR 行为对齐——OCR 也只看屏上内容）。
- iframe 协调：和 hints 路径**镜像**——`mouseless_text_request` / `mouseless_text_response`（id, query, origin），250ms 超时，off-viewport iframe 同样 cull。
- bg `find_text` 命令路由跟 `list_hints` 一样找 active tab top frame，response `{type:"text_matches", matches:[{rect, text}], ms, query, url}` 回 native。
- `BrowserProvider.findText(query:timeout:)` Swift 端封装 + `BrowserProvider.TextMatch` struct（rect + text）。
- `VimSession.kickoffSearch` 拆成 router → `kickoffSearchViaBrowser` / `kickoffSearchViaOCR`。frontmost 是浏览器走前者；其它（包括浏览器但扩展不可达）走 OCR。**注意：浏览器路径自治原则保留——OCR 不是 fallback，是不同 app 类型的独立路径**。

**性能** ~5-20ms（典型 GitHub PR 页 ~5ms）vs OCR ~80-200ms，~10× 提速 + 100% 精确。

**已知 trade-off**：浏览器 chrome（URL bar / tab 标题）的文字不在 DOM 里，所以 `/`-search 在浏览器不能搜到 URL / tab title。可接受——这些有自己的快捷键（Cmd+L 进 URL 栏等）。

### P4.10 — App-switch cursor park 在浏览器走 DOM（增量）✅

App-switch 后 cursor 默认 warp 到 focused window 的 title bar 中点。改成"如果焦点窗里有 input，落进那个 input"是 daily-drive 让 Mouseless 更顺手的细节。

**Native AX 路径**（普通 native app + WeChat 等 AX 好的 Electron 例外）：读 `AXFocusedUIElement`，role 在白名单（AXTextField / AXTextArea / AXSearchField / AXComboBox）或 `AXValue` 可写（兜 Electron 类返回奇怪 role 的可编辑元素），rect 跟 window 相交 + 至少 4×4。详见 `modes.md` §4.3。

**浏览器路径**（Chrome 类）：AX 不可信（renderer accessibility 默认关），走 DOM——

- `detector.js` 新加 `findFirstInput(opts)`：先看 `document.activeElement` 是不是 text 类 input（INPUT 排除 hidden/button/submit/checkbox/radio/image/file/color/range；TEXTAREA；contenteditable）—— 那是用户上次主动聚焦过的，强信号；fallback 到第一个可见 input/textarea/contenteditable in document order。
- bg `find_first_input` 命令路由复用 list_hints / find_text 的 active-tab 解析；response `{type:"first_input", rect|null, source}` 回 native，source 标 `activeElement` / `first_visible` / null。
- `BrowserProvider.findFirstInputRect(timeout:0.3)` Swift 端封装。
- `VimSession.parkCursorOnFrontmostWindowIfOutside` 改 async（两个 caller 都在 `Task { @MainActor }` 里），根据 frontmost bundleID 分流。

**已知 trade-off**：iframe 内的主输入框（Notion / Figma / Google Docs 部分 widget 在 iframe 里）目前不命中——top frame only for v1，跟 hint 检测的 iframe 协调一样的限制，等真踩到痛点再扩。

**Electron / AX 弱 app**（Slack / Discord / VS Code）：`AXFocusedUIElement` 返回 `kAXErrorNoValue`，老老实实 fallback 到 title bar。早期实验过深度 walk focused window AX 子树补漏，**有意识地撤回了**——Slack 的 compose 在 AX 树里根本不存在（不只是 role 不对），walker 跑了 400+ 节点也找不到。复杂度收益不成正比，留给将来 per-app patch 路线（"对 Slack 直接硬编码 compose 在窗口底部 80pt"）。

### P4.11 — 浏览器免模式滚动（d/u/gg/G，Vimium 式）✅

频繁浏览网页时，每次滚动都要先 Caps Lock+d 进 SCROLL 很烦。Vimium 不进任何模式就能 j/k/d/u 滚——我们对**浏览器真网页**也做到：不进模式直接 `d`/`u`（Shift 加速）连续滚、`gg`/`G` 跳顶/底。键位见 `modes.md` §5.1。

**关键决策：检测在网页、滚动在 native（发真滚轮）。** 一开始试过纯 JS 在 content script 里 `scrollBy` 滚 DOM（甚至移植了 Vimium 的 `scroller.js`），但在 YouTube 这类站翻车：手动鼠标滚轮只滚光标下的容器，而 JS `scrollBy` 滚某内层容器时**页面被一起带滚**（站点把内层滚动同步到了文档；浏览器内核对真滚轮有"滚动包含"，JS `scrollBy` 复制不出来）。实测确认：滚 `#guide-inner-content` 时 `document.scrollTop` 也变。结论——**只有发真 OS 滚轮才能和手动滚轮行为一致**，而那只有 native 能做。

最终架构（标准 B）：

- **content script 检测按键**（capture 阶段，每个 frame）：聚焦可编辑元素（input/textarea/select/contenteditable/role=textbox，含 shadow DOM）时放行让打字；带 Cmd/Ctrl/Alt 放行；裸 d/u/gg/G 才 `preventDefault`+`stopPropagation`。可编辑判断用 JS 同步读 `document.activeElement`——**这是检测必须在网页侧而非 native event tap 的唯一原因**（tap 同步拿不到 DOM 焦点）。
- **native 发真滚轮**：content script 只在手势边界发 `page_scroll`（start/stop/jump）；native 用常驻 `ScrollController`（**不 enter / 不 warp / 不画 overlay**，复用其 start/stop/jumpToTop/jumpToBottom 的发轮逻辑）在**当前光标处**发 CGEvent 滚轮。滚轮天然落在光标下的容器、走浏览器内核滚动包含，所以"滚侧栏不带动主内容"免费正确，也不用发坐标。
- **通信只在手势边界**：60fps 连续滚在 native 本地 timer 跑，IPC 仅 start/stop/jump（不是每帧）。延迟只有"按下→开始滚"那一下单程（SW keepalive 热着，个位数 ms，<1 帧）。
- **进模式即自动禁用**：进任何 Mouseless 模式后 native tap 在网页收键前就吞掉 d/u → content script 不触发 → 免模式滚动停。零协调。
- **Caps Lock+d 门控**：真网页禁用 Caps Lock+d（见 `scroll-mode-design.md` §2.4）；判定靠 `scroll_gate`。
- **兜底停**：`teardownCurrentMode()`（进模式）、`BridgeServer.onActiveClientDisconnect`（SW 挂掉）、content script 的 blur/visibilitychange 都会停在飞的 page scroll，防止松手前进模式 / 扩展断连导致一直滚。

**Shift 实时加速**：Shift 自身有 keydown/keyup，content script 在持滚期间据此重发 `start{fast}`，松手前补按/松开 Shift 即时变速。

新增协议消息：

```jsonc
// extension → Mouseless：当前焦点 tab 是否注入了 content script（门控 Caps Lock+d）
// bg 在 focus / tab / navigation 变化时 ping 活动 tab 的 top frame，收到回应才算 live
{ "type": "scroll_gate", "live": true, "browser": "chrome" }

// extension → Mouseless：免模式滚动指令（content script 检测到 d/u/gg/G）
{ "type": "page_scroll", "action": "start", "dir": "down", "fast": false }
{ "type": "page_scroll", "action": "stop" }
{ "type": "page_scroll", "action": "jump", "to": "top" }    // gg=top / G=bottom

// Mouseless → extension（bg 内部）：content-script 存活探测
{ "type": "mouseless_cs_alive" }   // content script 回 { type:"cs_alive", alive:true }
```

native 端：`VimSession.handlePageScroll` + 常驻 `pageScroll` controller；`setBrowserScrollGate` / `browserHandlesScroll`；`HotkeyTap` 的 Caps Lock+d 门控；`AppDelegate` 路由 `scroll_gate` / `page_scroll`；`BridgeServer.hasActiveBrowserConnection` + `onActiveClientDisconnect`。

**已知 v1 边界**：光标停在 iframe 上时，真滚轮仍由浏览器按光标落点路由（多数情况正确）；其余跟 hint 检测一样的 top-frame 倾向。其它非浏览器 app 不受影响，仍需 Caps Lock+d 进 SCROLL。

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

| 风险 | 实际处理 |
|---|---|
| **iframe 跨 origin** | postMessage 链协议：每 frame 自己运行 detector，子 frame 收父 frame 的 `mouseless_hints_request` + parent-computed `viewportOriginInScreen` 后递归询问自己的 iframe → 合并返回。所有 hint 都已在 screen 坐标，top frame 不用再做坐标变换。✅ 已实现 |
| **Shadow DOM** | detector 的 `getAllElements` 递归 `element.shadowRoot`；`isOnTop` 占用 `elementsFromPoint` 也递归 shadow root。✅ 已实现 |
| **`<canvas>` 上的 UI（Figma / Google Maps）** | DOM 里只有一个 `<canvas>` → detector 返回 0 hint。**不降级到 OP**（见 §7）—— 用户看到 0 web hint，只剩 Dock + menubar。**有意识取舍**：保持心智模型干净（browser = DOM truth），canvas-only UI 留给特殊处理（per-site rule，未做） |
| **Chrome Web Store 审核宽权限** | `<all_urls>` host permission 已声明，过审时需要文案解释"需要在所有网页上识别可点元素"。**P5 上架时处理** |
| **Manifest V3 SW 非常驻** | 长连接 + 20s `keepalive` 间隔的 port.postMessage 保活；port 死了用 1-30s 指数退避重连。✅ 已实现 |
| **Safari 扩展 API 不完全对齐 Chrome** | `browser.runtime.connectNative` 等同，但 Safari Web Extension API 在 macOS 上跟 Chrome 共用 Manifest V3 大方向。**P5 实测** |
| **bridge host 没装 / 扩展未安装 / 主进程没起** | `sendToActive` 返回 false → `BrowserProvider.fetchHints` 返回 `[]` → 用户在 browser app 看到 0 web hint（仍有 Dock + menubar）。**不降级到 OP**——见 §7 |
| **多 profile / 多浏览器 routing 错** | i_am_active 信号 + bundleID 身份校验。✅ 已实现 |
| **reload 扩展后已开 tab 没 content script** | SW 启动用 `chrome.scripting.executeScript({allFrames:true, files:[...]})` 主动 inject。✅ 已实现 |
| **chrome:// / Web Store 这种内置页禁注入** | 扩展回 `error: content_script_unavailable` → BrowserProvider 接受 0 hint，**不降级到 OP**。用户在 chrome:// 上按 Caps Lock 只看到 Dock + menubar hint，符合预期 |
| **同窗口切 tab 不刷新 hint** | `chrome.tabs.onActivated` → `tab_changed`。✅ 已实现 |
| **异步加载内容晚到** | MutationObserver "新可点出现" → `page_changed` → in-place refresh。✅ 已实现 |

---

## 7. 跟现有 OP / AX 路径的关系

**核心决策（374ea21）**：**进了浏览器分支就和 OP 完全无关**——扩展回啥（包括 0 hint）就是啥，不 fallback OP。

理由：

1. **心智模型干净**——用户记一条规则："Chrome / Safari = DOM 真理；其他 app = AX 或 OP"
2. **OP 在网页上效果差**——网页 OCR 既漏 icon-only 按钮又会误识背景文字，反而比"0 hint 但用户知道为啥" 更让人困惑
3. **fallback 边界难定**——`empty hints` 是因为"页面真的空"还是"content script 没注入"？两种都返回 `[]`，没法区分；要么所有都 fallback 要么都不

代价（接受）：

- 用户没装扩展 → Chrome 上没 web hint。要求**扩展是产品的一部分，不是可选项**。P5 上架后用户拿到的是扩展 + Mouseless 的整体安装包
- chrome:// / Web Store 页面没有 web hint。**合理**——这些页面本来也少有人需要 Mouseless 协助

**路由决策点**（`HintMode.collectAll`）：

```
frontmost.bundleID
   ├─ AppRegistry.isBrowserApp → BrowserProvider.fetchHints  (无 fallback)
   ├─ AppRegistry.shouldUseAXForFocused → AX walk             (whitelist app)
   └─ 其他 → OmniParserPath.collect                            (OP default)
```

`browserBundleIDs` 集合：Chrome / Chrome Canary / Chrome Beta / Brave / Edge / Arc / Safari。Safari 现在还在集合里但没扩展，导致进 browser 分支后 0 hint —— 是 P5 之前的预期行为。

---

## 8. 后续 / 衍生

- **Firefox** —— Manifest V3 兼容后基本免费跟进（V2 时代要 polyfill）
- **Arc / Brave / Edge** —— 都是 Chromium 系，理论上同一个扩展 .crx 包能装；但分别上架需要各自的应用商店账号
- **多 tab hint** —— v1 只 hint 当前 active tab；将来可能扩展到所有 tab（让 Mouseless 帮你切 tab 时直接落点）
- **per-site clickable 修正** —— 类似 `per-app-correction-design.md`，特定网站的 selector 补充（YouTube 的 video 控制按钮、Notion 的 inline button 等）
- **DOM 级 `/`-search** —— 扩展返回的 hint list 自带 text，`/`-search 可以直接 fuzzy 匹配，比 OCR 准
