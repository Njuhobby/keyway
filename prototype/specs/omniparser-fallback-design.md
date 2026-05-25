# OmniParser Fallback — Design Notes

视觉路径接进 Mouseless 的设计草稿。**不是实现计划**，是一份"我们到目前为止知道什么、还要决定什么"的备忘录。

**核心定位**：AX 是主路径。AX 快（稳态 ~50ms）、信息量大（role、enabled、action 都给）。OmniParser **只在 AX 显然不够时兜底**。fall-through，**不并行**。理由见 §4。

PoC 代码在仓库**外**：`~/Desktop/mouseless-omniparser-poc/`（throwaway，不跟踪）。

---

## 1. 起源 / 现状

`hint-discovery.md` §5 留了一个 known gap：destructive click 后 ~500ms 扫描尖峰，根因是目标 app 的 AX server 在 cleanup 期间 per-IPC 延迟暴涨。spec 把"OmniParser 视觉路径"作为长远方向：脱离 AX server，扫描跟它的内部状态解耦，尖峰自然消失。

同样动机的还有：**Electron / 复杂 web app 的 AX 兼容性**（SPECS.md known gap #2）。WeChat 的文件列表 / Wrike 的 SPA 这类 app，AX 大量元素是 `AXGroup` 无 action 无 label，hint 路径直接给不出来。视觉路径绕开。

PoC 目的：先验证 OmniParser 在 Apple Silicon 上的延迟和召回是否足以撑起这条路径，**再决定**要不要正经实现。

---

## 2. PoC 结果

环境：`uv` + Python 3.11 + torch 2.11 (MPS) + ultralytics 8.4 + transformers 4.57，OmniParser-v2.0 detector (`microsoft/OmniParser-v2.0` HF repo, `icon_detect/model.pt`).

三张全屏截图（2992×1934）detection-only 数据：

| 截图 | 内容 | boxes | detect p50 | detect p90 |
| --- | --- | --- | --- | --- |
| `fullscreen.png` | Clash Verge 设置 + dock + menu bar 混合 | 143 | 142.3 ms | 144.1 ms |
| `wechat.png` | WeChat 聊天列表 + 桌面 + status bar | 174 | 141.1 ms | 146.3 ms |
| `wechat2.png` | Chrome + Wrike SPA（实际是个 web 黑洞） | 177 | 111.1 ms | 118.5 ms |

**关键观察**：

- **延迟稳态 110–145 ms**，远低于 spec §5 设的 300ms 上限。p90 - p50 < 10ms，抖动几乎不存在。
- **召回明显高于 AX**。Wrike 的 inbox 卡片、task detail 字段、Activity feed 每条事件、Wrike 左侧 ~25 项导航——这些在 AX 树里大概率是一片 `AXGroup`，OmniParser 一次全捞回来。
- 测的 WeChat 文件列表那张（之前讨论过的 AX = 0 hint 的视图）—— PoC 期间该截图意外丢失，没拿到正式数据，但 wechat.png 同来源 app 的高召回已经印证。
- **冷启动 detector load ~170s**（首次下权重），后续启动 1s。生产环境模型常驻，冷启动成本一次性。

结论按 spec §5 决策树：**OmniParser 路径技术上 viable，值得做正经集成**——作为 fallback，不是替代。

PoC overlay 图存在 `~/Desktop/mouseless-omniparser-poc/screenshots/*_overlay.png`，是判断召回的视觉证据。

---

## 3. Captioner：尝试过，搁置

`OmniParser-v2.0` 在 detector 之外还配了一个基于 Florence-2 的 **icon captioner**（每个 box 输出一句自然语言描述，如 "Send button" / "User avatar with name"）。**试了，三层版本不兼容连环坑**：

1. `transformers==5.x` 把 `forced_bos_token_id` 从 config 移走 → Florence-2 community modeling 代码访问失败
2. 降到 4.57，又撞 `_supports_sdpa` 没设（Florence-2 代码 2024-10 写的，早于 SDPA 标准化）
3. 加 `attn_implementation="eager"` 绕开，又撞 `past_key_values[0][0]` 是 `None`（KV cache 接口在 transformers 4.45+ 改成 `Cache` 对象，老代码仍按 tuple 索引）

**之所以放弃**（而不是继续降 transformers 到 ~4.49 把所有坑填了）：

- **Mouseless 不需要语义 caption**：hint label 是我们**自己分配**的两字母编码（`as`、`af`...），不是自然语言。captioner 输出零用于画 hint 这一步。
- captioner 唯一能加 value 的场景：根据 box 推断"这是 button / link / 文本框"，从而在 OmniParser 路径下选择对应的合成动作。**但 fall-through 路径下，OmniParser 只在 AX 不够时启用**——AX 够用时 role 信号已经从 AX 拿到；AX 不够（黑洞 app）时统一合成 mouse click 就好，不需要再分类。
- 推断 caption 延迟：Florence-2 base 在 MPS 上自回归 ~20 token 估每 box 50-200ms。全屏 100+ box 一次 caption 是几秒级，**根本进不了实时路径**。哪怕只 caption 选中那一个（commit 后），那时点击已经发生，太晚。

未来如果真要用 caption（比如做 box "可点性"二次过滤），用 **OCR 文本探针**（easyOCR / 系统 Vision framework）比 VLM caption 快一个数量级。**但是否真有用，目前是臆测**，见 §5.2。

---

## 4. Fall-through：AX 主，OmniParser 兜底

PoC 草稿里曾考虑过"并行 + IoU fusion"——两条路径都跑、按 IoU 合并候选。**否决了**。

### 4.1 为什么不并行 fusion

| Scenario | AX 路径 | 跑 OmniParser 是否值得 |
| --- | --- | --- |
| 好 AX（Slack、VS Code、Safari、Finder） | ~50ms，role 全、AXPress 精确，候选量够用 | **不值得**：多花 140ms + GPU + 电池，只为捡可能多出来的几个 box |
| AX 黑洞（WeChat 文件列表、Wrike SPA） | 0 / 极少候选 | **必须**：没有别的来源 |

并行的代价是 100% 的扫描都背上 OmniParser 的延迟 + 资源开销，**收益却集中在不到 10% 的 app 场景**。明显不合算。

并且并行 fusion 还引入了 IoU 合并逻辑、两路结果协调的复杂度，**没换来对应价值**。

### 4.2 Fall-through 流程

```
collectAll:
    ax_targets = AX walk (现有 HintMode.walk / HintWindowCache / walkMenuBar 全套)

    if ax_targets 数量 >= AX_USEFUL_THRESHOLD:
        return ax_targets         # 主路径，OmniParser 不启动

    # AX 黑洞场景
    screenshot   = capture focused screen
    visual_boxes = OmniParser detect(screenshot)
    visual_boxes = apply_baseline_filters(visual_boxes)   # §5.1
    return ax_targets ∪ visual_boxes
```

OmniParser 只在 AX 显然不够时启动。**99% 的 scan 完全感知不到它存在**，电池、GPU、加载成本都省了。

### 4.3 每类目标的 commit 行为

| 来源 | sourceWindow | commit 时怎么点 |
| --- | --- | --- |
| AX target | 有 | 合成 mouse event 到 rect 中心（见 `hint-rendering.md` §3——AX action 路径已废，统一走合成） |
| OmniParser-only target | 无 | 合成 mouse event 到 box 中心（见 §4.6 含 OCR refiner） |

两条路径 commit 机制**完全统一**，区别只在 click point 怎么算（AX 有现成 rect；OP 要 OCR refiner 处理容器嵌套问题）。

Sticky rescan / `HintWindowCache` 逻辑保留——AX 是主路径，缓存有价值。OmniParser 这一支每次重新跑 detection（140ms 稳态，不值得缓存复杂度）。

### 4.4 路径选择：框架探测 + 小白/黑名单

最初 spec 这一节叫 `AX_USEFUL_THRESHOLD`——按"AX 返回候选数低于 N 就触发 OP"决定。实际写下来发现这个 framing **抓不住真实情况**。

#### 现实是什么

按"用户日常时间分布"看，macOS app 大致分两类：

| 框架 | AX 质量 | 代表 |
| --- | --- | --- |
| **Pure AppKit (老派)** | 干净 | Finder / Mail / Xcode / Pages 全家 / TextEdit / Preview / Terminal / Safari **chrome** / BBEdit / Things / 各种生产力工具 |
| **Catalyst (UIKit→macOS)** | 稀薄 | Music / TV / Podcasts / News / Maps / Stocks / Home / Books / 部分版本的 Notes |
| **SwiftUI** | 参差，改善中 | System Settings (Ventura+) / 部分新 Apple app / 一些第三方 |
| **Electron / web wrapper** | 几乎没有 | VS Code / Slack / Discord / Notion / Figma / WeChat / Wrike / 各类 SaaS |
| **WebKit 内 web content** | 看 site 的 ARIA 卫生 | 好：MDN/GitHub。差：大多数 SPA |
| **自渲染** | 没有 | 游戏 / Unity / Unreal |

**"AX 干净的 app 没几个"**——按用户加权时间算，AppKit-good 大约占 20-30%，剩下 70%+ 在 Catalyst / Electron / 自渲染里。

#### 简单 count 阈值的问题

`if ax_targets.count < N: run OmniParser` 看起来直观，实际两头都不准：

- **AX-bad app 上仍然有大量虚高 count**：WeChat 文件列表 AX 仍然能给 menu bar / dock / sidebar 30+ 候选，但用户实际想点的 PDF 行 = 0。count 高、recall 烂——阈值漏掉。
- **AX-good app 上偶尔合法 low count**：用户开了个空 Finder 窗口或一个无聊的对话框，AX 返回 5 个 target——本来就这么多。阈值误触发跑 OP，浪费 ~140ms + GPU。

所以 count 不是好信号。**真正的信号是"这个 app 的 UI 框架是什么"**——框架决定了 AX 质量的 ceiling，跟某次扫描的具体数字无关。

#### 框架探测：两层

bundle-layout 判定单独不够——很多 "native shell + web 内核" 的 app（New Outlook for Mac、Teams、OneNote 新版……）**没有** Electron Framework 也**没有** Catalyst 标志，但主 UI 是 WKWebView 渲染的 web 页面。Microsoft 这类 app 的 shell 是 bespoke 的，bundle layout 跟正经 AppKit app 几乎没区别。所以我们要**两层探测**：

```
detectFramework(app):
    // Layer 1: 廉价 bundle-layout 探测（0 IPC，纯文件系统读取）

    if Info.plist 含 UIDeviceFamily / LSRequiresIPhoneOS
       或 executable layout 是 iOS-style:
        return .catalyst

    if .app/Contents/Frameworks/Electron Framework.framework 存在
       或 .app/Contents/Resources/app.asar 存在:
        return .electron

    // Layer 2: AX 结构探测（per-app cached，10-20 IPC 一次性）

    if rootHasAXWebArea(app, maxDepth: 3):
        return .webContent     // covers Outlook / Teams / OneNote /
                               // 任何 WKWebView 包装的 native shell
                               // 也覆盖一些 Electron app（双重命中无妨）

    return .appkit             // 默认假设 native AppKit
```

##### Layer 2 (AXWebArea probe) 的原理

任何"主 UI 是 web 渲染"的 app，AX 树里都有 `AXWebArea` 节点——这是 WebKit / Chromium 的 AX bridge 给"web content 区"的标准 role。从 AXApplication 根 BFS 走前 3-4 层就能命中：

- **Pure AppKit** app：没 AXWebArea（即使内嵌帮助小窗那也在深层）
- **Catalyst** app：没（这条 Layer 1 已经先 return 了，不会走到 Layer 2）
- **Electron** app：有（Layer 1 也先 return 了；走到 Layer 2 是冗余兜底）
- **WKWebView 包装的 shell**（New Outlook、Teams、OneNote 等）：有 ← **这是 Layer 2 唯一不可替代的命中**
- **Safari**：有 AXWebArea 但只在 web 视图节点，chrome 部分是 AppKit。Layer 2 命中后整个 app 被归到 webContent——**可接受的折中**，Safari 的导航 + 标签 chrome 走 OmniParser 也能识别

`rootHasAXWebArea` 实现：BFS app 的 AXChildren 树，每个节点检查 role，发现 `AXWebArea` 立即返回 true，maxDepth = 3 限深。一次性，per-app 缓存进 dict，**整个 app 生命周期只判定一次**。

##### 探测顺序

Layer 1 在前是因为它是**纯文件系统读取，0 IPC**——能命中就立刻返回。Catalyst / Electron 大多数情况在 Layer 1 就被识别。Layer 2 兜底那些没明显 bundle 标志的 web-wrapper（主要是微软家产）。

#### 路径选择伪码

```
collectAll():
    app = frontmost app
    framework = detectFramework(app)       // cached after first call

    // 显式覆盖优先：人工小列表
    if app.bundleID in AX_FORCE_BLACKLIST:
        run OmniParser, return
    if app.bundleID in AX_FORCE_WHITELIST:
        run AX walk, return                 // e.g. VS Code 之类 Electron 但 AX 不错

    switch framework:
        case .catalyst, .electron, .webContent:
            run OmniParser, return          // 框架级判定，省一次 AX 扫描
        case .appkit, .unknown:
            ax_targets = run AX walk
            if count(ax_targets) < FALLBACK_N:
                # AppKit app 但实际 AX 候选异常少 → 安全网
                # （SwiftUI 嵌入控件、奇怪自定义 view 兜底）
                op_targets = run OmniParser
                return ax_targets ∪ op_targets
            return ax_targets
```

#### 人工维护的两个列表

| 列表 | 内容 | 期望规模 |
| --- | --- | --- |
| `AX_FORCE_BLACKLIST` | Layer 1 + Layer 2 都漏掉的 AX-烂 app（理论上几乎不存在——Layer 2 的 AXWebArea probe 是个非常宽的网） | **接近 0** |
| `AX_FORCE_WHITELIST` | 框架探测说 Electron / webContent 但实际 AX 不错的 | VS Code、可能 Cursor、可能 Discord 较新版本——目前估 < 5 |

**两层探测覆盖了几乎所有自动决策**。Blacklist 在以前的草稿里被预计 < 10 条（要塞 New Outlook / Teams / OneNote 之类），加上 Layer 2 之后这些 app 全部被 AXWebArea probe 自动归类，Blacklist 接近空。这是把 framework detection 做得更通用换来的实际收益。

#### 还没解的细分场景

**同一 app 内 AX 质量分层**：

- Safari：browser chrome (AppKit, 好) + web view 内容（看 site）
- Xcode：编辑器 (AppKit, 好) + 集成 doc viewer (WebKit, 看文档源)
- VS Code：menu bar (native, 好) + editor (Monaco, 好) + bottom panel (Electron, 看)

严格说应该 per-view 判定，但**第一版按 app 维度 + count 安全网就能拿到 80/20**——AX 候选异常少时退化到 fall-through 跑一次 OP 兜住。

#### 历史决策

这一节经过两轮翻盘：

**第一轮**：最初 spec 按"count 阈值是主信号"写。讨论后发现 AX-bad app 经常返回虚高 count（menu bar / dock / sidebar 加起来 30+ 但实际内容区域 = 0），AX-good app 偶发合法 low count。**改成"框架探测优先 + count 当安全网"**。

**第二轮**：第一版框架探测只用 bundle-layout（Catalyst 的 Info.plist 标志 / Electron 的 Framework 路径），漏掉了 **WKWebView 包装的 web app**（New Outlook for Mac / Teams / OneNote 新版……）。这些 app 没有明显 bundle 标志、但主 UI 是 web 渲染。当时草稿提议把它们塞进 `AX_FORCE_BLACKLIST` 手工维护——但 blacklist 越长越说明探测不够通用。**改成"两层探测：bundle-layout fast path + AXWebArea probe 兜底"**，自动把 web-shell 类 app 归到 webContent 桶，blacklist 接近 0 条。

留这段史是为了不让未来读者重新走这个推理过程。下一次再调整时，第一反应应该是"探测能不能做得更通用"，不是"加 entry 到 blacklist"。

### 4.5 跟 AX 卡顿尖峰（hint-discovery.md §5）的关系

destructive click 后的 ~500ms AX cleanup 期：

- 现在：sticky rescan 跑进 cleanup 期，IPC 单价飙到 40ms，扫描 500ms。
- 接入 OmniParser 后：fall-through 本身没缓解尖峰，**因为 AX 候选数仍然多**（cleanup 期 AX 返回值不一定变少）。需要单独检测"AX is busy" 信号才能切到 OmniParser 兜底。
- 实际更可能的修法：**等 AX 稳定**（hint-discovery.md §5 提到的事件驱动等通知方案）+ **OmniParser 仍然只用于 AX 黑洞场景**。两者解决不同问题。

OmniParser **不是** AX cleanup 尖峰的银弹。它是 AX 黑洞场景的兜底。SPECS.md 上一版里我说"OmniParser 落地后这个尖峰自然消失"是错的，那个尖峰要单独治。

### 4.6 OmniParser commit 的精度问题

AX 路径 commit 时跟坐标无关——`AXUIElementPerformAction(element, "AXPress")` 按元素引用派发，元素在屏幕上的位置不影响。OmniParser 路径**没有元素**，commit 只能合成 mouse event 到一个 `(x, y)` 坐标，**这个坐标必须落进真实可点区域**。

这给 OP 路径引入了一类 AX 路径下不存在的失败：**hint 出现，用户按下，合成 click 成功，但点的位置没命中实际的 click handler，UI 无变化**。

#### click point 和 hint label 视觉位置是两件事

不能混淆。沿用 AX 路径目前的 label 排版逻辑（badge 在元素旁、不挡内容、密集时级联等等，见 `hint-rendering.md`），但 **commit 时合成 click 的目标坐标不等于 label 视觉位置**：

```swift
// 错的：
synthesizeClick(at: target.labelPosition, ...)

// 对的：
synthesizeClick(at: target.clickPoint, ...)
// where clickPoint 是 box 内部一个真正可点的像素
```

`clickPoint` 怎么算见下面。

#### click point 的失败模式

box 中心**不总是**可点像素。5 类：

1. **box 框得偏移**：detector 输出边缘抖动，几何中心落到 padding 或 border 外。
2. **可点区域 ≠ 视觉区域**：web app 里 click handler 装在外层 `<div>` 上、可视按钮是个 `<span>`，或反之；OmniParser 只看视觉，无法看 hit-test 边界。
3. **透明 overlay 截获**：modal 上面盖一层吃点击的层，click 落到它身上而不是底下的目标。
4. **HiDPI 坐标系**：截图是物理像素，合成 event 走 logical points。**转换错就直接点空气**。这是实现侧的死活要保证的。
5. **容器嵌套**：大框套小框（IoU 不达 NMS 阈值都保留），大框的几何中心落进小框区域，按外层 hint 反而触发了内层目标的 click handler。

第 4 类是工程问题（必须正确），1-3 + 5 类是 OP 路径的**固有概率性失败**——AX 路径下完全不存在。下面的 refiner 算法处理 1、2、5；3 和 4 各自有不同性质，refiner 处理不了。

#### OCR-based click point refiner

观察：**点文字几乎一定命中 click handler**。原因有二：

- 文字是 UI 元素的"label"，本身在视觉区域中央或紧贴中央；
- 文字所在的像素一定属于可视区域内部，不会落到 padding / border 外。

但单纯"OCR 出文字 → 点文字中心"还不够，因为 OmniParser 经常输出**容器嵌套** box：一个大框完全包住一个小框，两者 IoU 不达阈值都保留（见 §5.1.4 的 NMS 数学）。这时大框 OCR 会**把小框里的文字也识别进来**——小框是 "Send" 按钮含文字 "Send"，大框是套着 Send 按钮的卡片不含自己的文字，大框的 OCR 输出**仍然是 "Send"**，因为它的 crop 区域包含了 Send 那块像素。

朴素 refiner 在这种 case 下会让大框和小框都点到 "Send" 同一像素，触发同一个 click handler，**用户按外层 hint 想干的事被错误地变成内层 hint 的行为**。

#### 关键设计原则：containment-aware

如果 OmniParser 输出了两个 hint label（外大、内小），按 mouseless 的语义：

> **两个 hint 意味着用户有两个独立的"可点目标"**。inner box 是更精准、更具体的那个；outer box 代表"点容器自身、但不点已经被 inner box 覆盖的部分"。

所以外层 box 的 click point **必须避开** inner box 的覆盖范围——把它视为"outer 减 inner 的剩余区域"的中心。

#### containment-aware OCR refiner 算法

```
commit OP-only target B:
    inner_boxes = [b for b in all_targets
                   if b ≠ B and b.rect ⊂ B.rect]      # B 套住的所有更小框
    text_regions = OCR(B.crop)                        # 仅 OCR 这一个 box

    # Step 1: 剔除属于 inner box 的文字
    own_text = [t for t in text_regions
                if t.center not in any inner_box.rect]

    if own_text 非空:
        clickPoint = 最长 own_text 段的几何中心
        return synthesizeClick(at: clickPoint)

    # Step 2: B 没有"自己的文字"——全部 OCR 文字都属于 inner box
    if inner_boxes 非空:
        # B 的"自身区域" = B.rect 减去所有 inner box 的并集
        # 通常是 L 形或 frame 形（环形 minus inner rect）
        own_region = B.rect minus union(inner_boxes.rects)

        if own_region 几何上非空（有 ≥1 pixel area）:
            clickPoint = own_region 最大连通分量的几何中心
        else:
            # 病态：B 完全被 inner boxes 覆盖，无 own region
            # 说明 B 其实就不是用户能"额外点"的目标 —— 但既然出了 hint 也得能 commit
            # 折中：点 B 几何中心，等同于触发某个 inner box 的功能
            # （这种 case 应该极少，是 detector 输出冗余的兜底）
            clickPoint = B.center

        return synthesizeClick(at: clickPoint)

    # Step 3: 既无 own_text 也无 inner_boxes —— B 是个纯 icon 类 leaf 框
    clickPoint = B.center
    synthesizeClick(at: clickPoint)
```

#### 每个 case 的具体处理

| 场景 | 走哪条路径 |
| --- | --- |
| 大框套小框，小框有文字 "Send"，大框无自己的文字（典型卡片） | Step 1 过滤后 own_text 为空 → Step 2 算 own_region 中心 |
| 大框套小框，小框有 "Send"，大框还有自己的标题 "Tech Backlog" | Step 1 过滤后 own_text = ["Tech Backlog"] → 点 "Tech Backlog" 中心 |
| 单独的 Send 按钮（无 inner box，OCR 出 "Send"） | Step 1 own_text 非空 → 点 "Send" 中心 |
| 单独的 ✓ 图标（无 inner box，OCR 无文字） | 跳到 Step 3 → 点 box 中心 |
| 完全冗余的容器（B 完全被 inner box 覆盖） | Step 2 own_region 为空 → fallback 到 B.center（极少触发） |

#### 实现复杂度

`own_region = B.rect minus union(inner_boxes.rects)` 听起来复杂但对**轴对齐矩形**很简单：

- inner boxes 都是 axis-aligned，subtract 结果是若干个 axis-aligned 子矩形拼成的多边形
- 实践中常见两种形状：
  - 一个 inner box 偏在 B 内某一侧 → own_region 是个 L 形或 frame 形
  - 多个 inner box 散布 → own_region 是几条"间隙带"
- 找最大连通子矩形的算法直白：枚举 inner box 边界划分出的网格 cell，取其中不被任何 inner 占据的最大 cell

对我们的用途简化版本就够：

1. 算 B 的几何中心 `c = B.center`
2. 检查 `c` 是否落在任何 inner box 内
3. 不落 → 用 `c`，落 → 沿 B 的四条边各取中点，取**离所有 inner box 距离最远**的那个点

这个简化版在大多数 case 下行为正确，且实现 10 行内。等观察到边界 case 失败时再升级到完整 own_region 计算。

#### 这条路径处理的失败模式

回到 §4.6 前面列的 4 类 misclick：

- **第 1 类**（偏移 box）：own_text 的中心一定在 B 内部偏中央，避开边缘 padding ✓
- **第 2 类**（可点区域 ≠ 视觉）：文字属于视觉区域 ✓
- **第 3 类**（透明 overlay 截获）：refiner 无能为力 ✗
- **第 4 类**（HiDPI 坐标系）：工程问题，跟 refiner 无关 ✗

新增的 containment-aware 路径**额外**处理了一类失败：

- **第 5 类**（容器嵌套导致外层 hint 错点内层目标）：containment-aware Step 1 + Step 2 ✓

#### 故意没处理：partial overlap

NMS（§5.1.4）让两个 box 都活下来的条件是 `IoU < 0.5`，containment 只是其中一个特例——理论上也可能两个 box partial overlap（互不包含、但有交集），中心都落进交集那块文字。

PoC 三张图里**没观察到** detector 输出这种 partial overlap 形态——containment 是常见的（会话行套头像/名字），partial overlap 几乎没有，因为视觉上的 UI 元素本来就不该相互错位重叠。

算法理论上一行字就能推广（把 `b.rect ⊂ B.rect` 换成 `intersects(b.rect, B.rect)`，own_region 计算原样适用），但**不在没观察到的情况下提前加**——同 §5.2 的纪律。

如果日后接进 prototype 后真在 commit log 里看到 partial-overlap 导致的 misclick，再把 `inner_boxes` 字面改成 `overlapping_boxes`，算法骨架不动。

#### 为什么 OCR 在这里是 grounded 的（vs §5.2 的 OCR-as-filter）

之前 §5.2 草稿里把 OCR 当 filter（"无文字 box → 丢"），那是臆测——纯 icon 按钮没字但确实可点，丢了就漏。

OCR 当 **click-point refiner** 是不同 trade-off：

| 维度 | OCR-as-filter | OCR-as-refiner |
| --- | --- | --- |
| 触发时机 | collect 路径（每次扫都跑） | commit 路径（只对用户选定的一个 box 跑） |
| 全屏代价 | 50-200ms / 全屏 | 几 ms / 单 box |
| OCR 失败的后果 | 把可点 box 误丢，**用户根本看不到 hint** | 降级 fallback 到 box 中心，**等同于没用 OCR** —— 无损 |
| OCR 误识别的后果 | 影响过滤决策 | 至多影响"是点文字 A 还是文字 B"，两个都在 box 内部，都比边缘安全 |

refiner 用法**任何情况都不比不用差**。这是它跟 filter 用法的根本区别。

#### 实现细节

- macOS Vision framework: `VNRecognizeTextRequest`，硬件加速，无外部 ML 依赖
- crop 区域：把 box 从全屏截图上 crop 出来（截图本身在 collect 阶段已经截过，commit 时复用同一张）
- 单 box OCR wall-clock：几 ms 级，commit 路径上的额外延迟可忽略
- 如果 box 内多个文本段，取最长那段的中心（一般是 button label，比 hint/tooltip 这种短附属文本更靠近 click handler）

#### 用户体感对比

| 失败模式 | AX 路径 | OP 路径（不带 OCR refiner） | OP 路径（带 OCR refiner） |
| --- | --- | --- | --- |
| element 完全无 hint | 用户切回鼠标 | 用户切回鼠标 | 同 |
| 点了没反应 | 几乎不会 | 偶发（box 偏移 / 可点≠视觉） | 显著降低（点字 ≈ 必然命中可点） |

OCR refiner 把 OP 路径的"hint 出现 ≠ 一定生效" 拉近 AX 路径的"hint 出现 ≈ 一定生效"。

#### 一个 commit 后的可观察 affordance

即使 OCR refiner 加上去，misclick 仍然可能发生。考虑 commit 后短暂高亮 click point —— 让用户至少知道"系统点了这个位置"。如果 UI 没反应，用户知道是 OP 路径的精度问题（vs 怀疑 Mouseless 没收到键），可以切鼠标重试。这是 UX 上的小投入，对调试和信任都有意义。

---

## 5. OmniParser 路径的过滤设计

AX 路径靠 `clickableRoles` + `hasMeaningfulLabel` + `skipRoles` 把 candidate 压到 50-100。OmniParser detector 输出未过滤，wechat.png 上是 174 box，**全做 hint 会出现 label 通胀**（屏幕铺满黄色标签）。

过滤是必须的。但**哪些过滤规则是可靠的、哪些是猜的**，要分清。

### 5.1 Baseline：标准 CV 后处理（验证过、可以放心用）

这一组过滤跟 UI 语义无关，是 object detection 的标准 post-processing，已经被 ML 社区在千万张图上验证过。**这些是上线时必加的**。

四条：

1. **YOLO confidence 阈值**
2. **Size 最小值**（≥ 8×8）
3. **Size 最大值**（占屏 < N%）
4. **NMS dedup**（IoU-based 去重）

下面逐条展开。

#### 5.1.1 YOLO confidence 阈值

每个 box 从 detector 出来时附带一个 `[0, 1]` 的 confidence score，代表模型对"这是一个 interactive UI element"的把握程度。

- 实现：`box.confidence >= threshold`，threshold 一般 0.3-0.5。
- 作用：砍掉模型自己都不确定的检测，多半是误报。
- threshold 怎么定：**这个数值需要在 UI 截图上扫一下**——0.3 太松会漏一些低 conf 但实际可点的元素，0.5 太严会丢掉一些半可见的合法目标。**PoC 阶段用 0.05 ~ 0.3 这种宽松值跑过**（看 PoC 数据时有 100-180 box，是宽松阈值的产物），真要上线时按"AX 黑洞 app 的 box 命中率"决定。

#### 5.1.2 Size 最小值

- 实现：`rect.width >= 8 && rect.height >= 8`。
- 作用：砍掉几像素的检测噪音。
- 跟 AX 路径同条件（`hint-discovery.md` §2.2 收录条件第 2 条）。
- 这条几乎不会误杀真实 UI 元素——再小的图标按钮也有十几像素。

#### 5.1.3 Size 最大值

- 实现：`rect.width * rect.height <= MAX_SIZE_FRAC * screen.area`，`MAX_SIZE_FRAC` 取 0.25 ~ 0.5。
- 作用：砍掉"detector 错把整个 panel / sidebar / 窗口当 interactive element"输出的大框。
- **为什么需要单独一条**：直觉上"NMS 应该把覆盖了小框的大框去重掉"，**事实是不会**——见 §5.1.4 后面的 NMS 含义解释。
- 实测看 PoC 的三张图没出现这种大框，但**不能假设永远不会**：训练数据覆盖不到的边缘 UI、模型对某些 web app 的容器层 hallucinate、未来 detector 版本变化，都可能产生。**几何 sanity check，加上去几乎无成本，错过的代价是屏幕上多一个无用的覆盖大区域的 hint label**。
- 注：这条不区分"占满整屏"和"占了 30% 的 sidebar"——都是几乎不会被用户当 hint target 点击的尺寸级别。如果未来发现某些合法 UI（比如全屏弹框）被它误杀，再调 frac 或加 role-aware 的例外。

#### 5.1.4 NMS dedup（**附 NMS 行为说明**）

- 实现：标准 Non-Maximum Suppression。两两计算 box 之间的 IoU，IoU 大于阈值（典型 0.5）的一对里，留 confidence 高的、抑制 confidence 低的。
- 作用：detector 有时会对同一 UI 元素出两个紧挨的框（典型例子：图标 + 它紧挨的 label 各画一个，或者一个元素被检测两次重叠输出）。NMS 把这种"几乎重合"的去重，留一个代表。

**这里要讲清楚一个反直觉的事：NMS 不去"包含关系"的重叠**，也就是大框完全套住小框这种场景。原因是 NMS 用 **IoU**（Intersection over Union），而 IoU 是：

```
IoU = 两框相交面积 / 两框并集面积
```

考虑大框完全包住小框：

```
大框：1000×800 = 800,000 px²
小框：  50×30  =   1,500 px²

Intersection = 1,500 px²        （小框自身的面积，因为它整个在大框里）
Union        = 800,000 px²      （≈ 大框面积，小框是它的子集）
IoU          = 1,500 / 800,000 = 0.0019
```

IoU ≈ 0，远低于 NMS 阈值 0.5，**NMS 不会动这两个框，都保留**。

这就是为什么 §5.1.3 必须存在：**NMS 不防大框污染候选集**。两条规则各管一边：

- NMS 处理"两个差不多大小的框互相重叠 ~50% 以上"（去重）。
- Size 最大值处理"一个框大到不像 interactive element"（剔除巨型误报）。

这俩不重叠，缺一不可。

#### 这四条加起来能压到多少

实测 PoC 三张图都是 100-180 box 量级的**未过滤**输出。这四条加上去通常能压到 60-100，**且不引入任何 UI 启发式**——纯 ML / 几何后处理。剩下的过滤（如果还需要）只能靠 §5.2 的 exploratory 信号，需要数据支撑。

### 5.2 Exploratory：UI 启发式（需要数据，目前是臆测）

下面这些规则**听起来合理**，但**在真实 UI 上是否真有效，目前未知**。需要把 OmniParser 接进 prototype、跑过若干 AX 黑洞 app、看数据后才能决定：

| 候选规则 | 直觉 | 待验证的问题 |
| --- | --- | --- |
| **Size × confidence 组合**：小框只在 conf 高时保留 | 大框 + 低 conf 多半是误报的容器 | 阈值定多少？同一规则在 web app vs native app 是否一致？ |
| **Aspect ratio 过滤**：极宽 / 极高的框 → 丢 | 装饰横线 / 分隔条 | 跨度大的 toolbar 也是极宽，怎么区分？ |

**结论**：上线时先**只用 §5.1 的 baseline 过滤**。Exploratory 这些，等真有 OmniParser-on-AX-bad-app 的数据再决定要不要加。**别在没数据的情况下提前预设规则**。

> **OCR 不在这一节**——它一开始确实被列在 exploratory filter 里（"box 内无文字 → 丢"），但分析后挪到了 §4.6 commit-time refiner 的位置。区别见 §4.6 的对比表。简单说：filter 用法是臆测，refiner 用法是 grounded。

---

## 6. 集成的开放问题

到正经实现之前要先回答的：

### 6.1 进程边界

OmniParser 是 PyTorch 模型，不可能塞进 Swift 进程里跑。三个候选架构：

| 方案 | 优 | 缺 |
| --- | --- | --- |
| **Python helper 进程 + XPC** | OmniParser 原生跑，无需转模型；可以单独升级 | Swift ↔ Python IPC 自己撸；Python 运行时 + venv 跟 .app 一起发；启动慢 |
| **CoreML 转换 + Swift 推理** | 单 binary，启动快，Apple Neural Engine 加速 | YOLO 转 CoreML 可行（ultralytics 有 export 工具），但 Florence-2 转 CoreML 很难；至少 detector 部分能转 |
| **subprocess（python script）+ stdio** | 简单粗暴 | 每次 detect 都要 spawn Python？或者长驻 worker + stdio 协议，差不多复杂 |

#### P1 spike 实验结果 ✅ 选定 CoreML

`~/Desktop/mouseless-omniparser-coreml-spike/` 跑通了 PyTorch → CoreML 转换 + 推理基准。结论：**CoreML 路径远比预期好**。

**转换过程**（要拉通几个 pin）：

- 直接 `yolo export model=icon_detect.pt format=coreml nms=True` 是死路——撞 coremltools `_int` 算子 bug
- root cause：numpy 2.x 移除了多元素数组到 Python scalar 的隐式转换，但 coremltools 8.x 的 torch 前端代码还按 numpy 1.x 写
- 修复：固定 `numpy<2.0` + `coremltools>=8.0,<9.0` + `torch>=2.2,<2.5` + `ultralytics>=8.2,<8.4`
- ONNX 中转路径**死了**：coremltools 8.x 彻底删除 ONNX frontend，不再支持
- 总结：export 时 toolchain 必须按上面 pin，**runtime 没有 Python 依赖**

**推理延迟**（M3 Max，1280×1280 输入，纯 CoreML.framework 调用，剥离 ultralytics wrapper）：

| compute_units | p50 延迟 |
| --- | --- |
| CPU_ONLY | 145ms |
| CPU_AND_NE (ANE) | 42ms |
| ALL (runtime 自选) | 43ms |
| **CPU_AND_GPU (Metal)** | **29ms** 🏆 |

参考：PoC 报的 PyTorch + MPS 是 110-140ms。**CoreML + GPU 比 PyTorch MPS 快 4-5 倍**，比设计目标 300ms 快 10 倍。

**意外发现**：**GPU 比 ANE 快 30%**。这跟"YOLO 是卷积密集型网络，Metal GPU 流水线效率高，ANE 更适合 attention-heavy（如 Transformer）"的实际工程经验一致。生产实现要 `MLModelConfiguration.computeUnits = .cpuAndGPU`，**不要**用默认的 `.all` 或显式 `.cpuAndNeuralEngine`。

**召回质量**：

- CoreML 原始输出比 PyTorch 少 30-40% 的 box（fullscreen 143→83、wechat 174→112、wechat2 177→133）
- 原因：`nms=True` 导出时把 conf 阈值 ~0.25 烧进模型，过滤了低 conf 检测
- 这些被砍的低 conf box **本来就是 §5.1.1 的 conf>0.3 baseline 过滤要丢的**——production impact = 0
- 加 conf>0.3 baseline 过滤后 CoreML 最终输出 75/111/126 box，跟 PyTorch + conf>0.3 几乎对齐
- 视觉 overlay 抽查：聊天列表、菜单栏、dock、消息气泡、桌面图标都各自打了框，质量跟 PoC 一致

**模型输出 schema**：CoreML 模型有两个张量输出——

```
coordinates: (N, 4)   // [cx, cy, w, h], 归一化到 [0,1] 的 1280×1280 输入空间
confidence:  (N, 80)  // 每个 box 80 个类别的 confidence
```

YOLO11m 是多类训练的（80 类，COCO 标准），但 OmniParser fine-tune 数据全归一类。生产代码取 `confidence.max(axis=1)` 当 box 的 conf 用，**不关心具体类别**。坐标要乘原图尺寸还原到屏幕空间。

**决策**：选 #2（CoreML in Swift）。理由不仅是"单 binary 部署"，更是"快得离谱 + 比 #1 的 IPC + Python runtime 简单一个量级"。完整路线见 [`omniparser-integration-roadmap.md`](./omniparser-integration-roadmap.md) P2/P4/P8。

PoC v2 的 throwaway spike 在 `~/Desktop/mouseless-omniparser-coreml-spike/`，可随时 `rm -rf`——production 不需要它。

### 6.2 模型常驻 vs 按需加载

模型 weights ~30MB（detector）。常驻 ANE/MPS 内存 ~200-500MB。

- **常驻**：menu bar app 启动时 load，每次 trigger 直接推理。延迟最低。
- **按需**：首次 trigger 加载，可能 1-2s 卡顿；之后常驻。

**fall-through 改变了这个权衡**：OmniParser 不是每次都用，可能用户大部分时间根本触发不到它。常驻 500MB 内存 99% 时间是浪费。

倾向：**首次需要时加载 + 之后常驻**（懒加载 + 不卸载）。第一次 AX-bad app 上稍微卡一下接受，之后回到稳态延迟。

### 6.3 触发判定

`AX_USEFUL_THRESHOLD` 在 §4.4 已经讨论。这里只是再次强调：**这个决定需要数据**。落地时先用最保守的 `N=0`，运行一段时间看实际"OmniParser 是否经常被触发"，再调。

### 6.4 截屏来源 + 范围（已定）

#### 范围：**只截焦点窗口**（不是全屏，不是焦点屏）

讨论时考虑过三种范围：

| 方案 | 优 | 缺 |
| --- | --- | --- |
| 全屏 | API 最简单 | 跟 AX 路径在 Dock / menu bar 上重叠产生 label 冲突；3000×2000 → 1280² resize 后小图标接近模型识别下限，召回打折；隐私上把用户当前任务无关的内容也喂给 ML pipeline |
| 焦点屏 | 多显示器场景过滤掉其他屏 | 仍然包含 Dock / menu bar / 桌面 / 其他窗口，重叠和召回问题不解 |
| **焦点窗口** | 跟 AX 路径分工干净；窗口 1500×900 → 1280² resize 后小图标 scale ~0.85 召回更高；隐私上只看用户当前窗口 | API 略复杂（要先 AX 拿 windowID，再 ScreenCaptureKit 截特定窗口） |

**决策：焦点窗口**。理由——AX 路径在 Dock / menu bar / menu extras 上**永远好用**（这些苹果原生 AX 100% 覆盖），不需要 OmniParser 重复识别。OmniParser **精确**地补 AX 黑洞问题——**焦点窗口内部的子元素**——所以截图范围跟 AX 路径互补、不重叠。

#### AXFocusedWindow 在 AX-bad app 上也能拿吗？✅ 能

AX 树有两层：

- **顶层窗口骨架**（AXApplication → AXWindow → AXPosition / AXSize / AXTitle）：**任何 app 都正确**——macOS 系统 framework 在 NSWindow 创建时自动注册，不依赖 app 自身 AX 实现质量
- **窗口内子元素树**（AXChildren 递归）：**这一层才会在 Electron / WKWebView / Catalyst 上变成 AXGroup 黑洞**

OmniParser 路径只读顶层（窗口在哪、多大、CGWindowID），**完全不碰子元素树**——所以对 AX-bad app 同样 work。从这个角度看 OmniParser 是"AX 顶层元数据的优秀客户 + 子元素树的替代者"。

边缘 case：

| 场景 | 处理 |
| --- | --- |
| 焦点 app 没有窗口（menu bar agent app）| `AXFocusedWindow` = nil → OmniParser 不触发，AX 路径处理 menu bar |
| 多窗口同时可见（多个 Finder） | 第一版只截 `AXFocusedWindow`，按观察决定要不要扩展到所有 AXWindows |
| 焦点窗口被其他窗口部分遮挡 | ScreenCaptureKit 的 `desktopIndependentWindow` 模式忽略遮挡画完整窗口内容——正合需求 |
| 全屏游戏（自渲染 bypass NSWindow） | 罕见。整个 Mouseless 本来就在游戏内不能 work，已知 limitation |

#### 实现路径：ScreenCaptureKit per-window

```swift
// 1. AX 拿焦点窗口 element
guard let focusedWindow = focusedApp.attribute("AXFocusedWindow") as? AXUIElement
else { return .axOnly }   // 没窗口，OP 不触发

// 2. 拿 CGWindowID（私有 API but stable: _AXUIElementGetWindow）
var windowID: CGWindowID = 0
guard _AXUIElementGetWindow(focusedWindow, &windowID) == .success
else { return .axOnly }

// 3. ScreenCaptureKit 截
let content = try await SCShareableContent.current
guard let scWindow = content.windows.first(where: { $0.windowID == windowID })
else { return .axOnly }
let filter = SCContentFilter(desktopIndependentWindow: scWindow)
let image = try await SCScreenshotManager.captureImage(
    contentFilter: filter,
    configuration: SCStreamConfiguration()
)
```

**对比 API 候选**：

- ✅ **ScreenCaptureKit (`SCScreenshotManager`)**：现代 API、per-window 原生支持、自动处理多屏 / HiDPI / 窗口 z-order
- ⚠️ `CGWindowListCreateImage`：legacy，能 per-window 但 macOS 14+ 起被标 deprecated
- ❌ `CGDisplayCreateImage`：只能整屏，不符合我们需求

选 ScreenCaptureKit。

#### Screen Recording 权限

**这是 AX 之外多加的一个授权门槛**——我们一直避开它，一旦走这条路，权限模型从"只要 AX"变成"AX + Screen Recording"。值得跟用户明确这个 trade-off。

权限请求策略（lazy）：

- 启动时**不**请求 Screen Recording
- 用户首次落进会触发 OmniParser 的 app（按框架探测）时，**才**用 `CGPreflightScreenCaptureAccess()` 检测，没授权弹原生 prompt
- 没授权就降级：当次扫描 OmniParser 路径退化为"无候选"，AX 候选仍可用——跟现在 AX 黑洞 app 体验一致，**不会让 Mouseless 整体挂掉**

#### 坐标系对齐

OmniParser 输出 box 是窗口截图内的归一化坐标 (0-1)。要还原到屏幕坐标用于合成 click：

```
screen_x = window.origin.x + box.cx_normalized * window.size.width
screen_y = window.origin.y + box.cy_normalized * window.size.height
```

`window.origin` / `window.size` 直接从前面那步的 AX `AXPosition` / `AXSize` 拿。**完全跟 AX 路径同一个坐标系**——合成 click 时无需特殊处理 OP 来源的 box。

#### 多显示器

OmniParser 只看焦点窗口——窗口在哪一块屏不重要。**多显示器场景自动正确**，无需特殊代码。

---

## 7. 下一步

详见 [`omniparser-integration-roadmap.md`](./omniparser-integration-roadmap.md)。

该文档把本设计里散布的决策（§4.4 框架探测、§4.6 OCR refiner、§5.1 baseline 过滤、§6 开放问题）映射成 9 个可独立验收的实施阶段（P0 决策 → P8 发布），含估时、风险、降级路径、out-of-scope 边界。**改设计时同步更新那份**。

---

## 8. 参考

- OmniParser repo: `github.com/microsoft/OmniParser`
- 权重: `huggingface.co/microsoft/OmniParser-v2.0` (`icon_detect/model.pt` 是 YOLOv8)
- PoC 源代码：`~/Desktop/mouseless-omniparser-poc/`（throwaway，可以随时 `rm -rf`）
- 相关 specs：
  - `SPECS.md` known gap #2 (Electron / web compatibility) ← OmniParser 主要解决这个
  - `SPECS.md` known gap #3 + `hint-discovery.md` §5 (AX cleanup spike) ← OmniParser **不**解决这个，单独治
