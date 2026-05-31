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

## 4. OP-default：OmniParser 主，AX 在 whitelist 上兜底

> **本节经过 3 次重写**。先是"AX 主、OP 黑洞兜底"（fall-through），然后"框架探测路由"，最后落到当前的"OP-default + AX whitelist"。每次推翻的原因都记在 §4.4 末尾的「历史决策」。

### 4.1 为什么不并行 fusion

之前考虑过"并行 + IoU fusion"——两条路径都跑、按 IoU 合并候选。**否决了**：并行 fusion 引入了 IoU 合并、两路结果协调的复杂度，**而对任何单一 app 来说只有一条路径是真正信息源**（要么 AX 信息全、要么 AX 信息空）——fusion 拿不到对应价值。

### 4.1a 也不"AX-default with OP fallback"

中间一版方案是 AX-default：所有 app 先跑 AX，框架探测说是 AX-bad 才补 OP。这一版被 WeChat 击破——WeChat 是 native AppKit（bundle 是 AppKit、`AXTable` `AXRow` `AXColumn` 等标准 widget 都在 AX 树里），但**聊天消息气泡是自定义 NSView，AX 树里没有**。AX 焦点 walk 在 WeChat 上返回 ~58 个候选（够多），却**漏掉了用户最想点的东西**（消息、文件、表情）。

由此推出：**framework ≠ AX 质量**。同样模式的 app 还有 QQ / 钉钉 / 飞书 / 网易系——一大类「**native AppKit 但 AX 黑洞**」根本无法通过 bundle 探测识别。Blacklist 路径会无限膨胀。

详见 §4.4 末尾的"历史决策"。

### 4.2 Fall-through 流程

#### AX walk 不是一个动作，是 4 个独立来源

`HintMode.collectAll()` 当前同时跑 4 个 AX 来源：

| 来源 | AX 表现 | OP 能替代吗 | 备注 |
| --- | --- | --- | --- |
| **焦点 app 子元素树**（窗口内按钮/列表项等） | Electron/WebContent/Catalyst 上烂 | ✅ 可以——OP 截焦点窗口看到的就是这一层 | 这是**唯一**需要 OP 兜底的部分 |
| **Dock items** | 永远好（苹果原生 AX）| ❌ 不行——dock 不在焦点窗口内，OP 截图看不到 | 永远 AX 提供 |
| **焦点 app 的 AXMenuBar** | 永远好（AppKit/SwiftUI 渲染）| ❌ 同上，菜单栏不在焦点窗口内 | 永远 AX 提供 |
| **Menu bar extras**（status icons） | 永远好（苹果原生 AX）| ❌ 同上 | 永远 AX 提供 |

**关键洞察**：OP 路径**只替代第一行**。其他 3 个来源在 OP 路径下**继续保留 AX walk**——它们既快（dock + extras + menubar 合计 ~50ms）又准（苹果原生 100% 覆盖），而且 OP 物理上看不到（截图只覆盖焦点窗口）。

#### 完整流程

```
collectAll:
    # 永远跑（OP 看不到这 3 个来源——dock/menubar/extras 不在焦点窗口内）
    dock_targets       = AX walk: Dock                       // ~6ms
    menubar_targets    = AX walk: focused app's AXMenuBar    // ~7ms
    extras_targets     = AX walk: menu extras                // ~44ms

    # 焦点 app 子元素树：OP-default，少数 app 走 AX
    if app.bundleID in AX_FOCUSED_WHITELIST:
        focused_targets = AX walk: focused app children      // ~150-200ms
    else:
        # 默认路径——任何不在 whitelist 里的 app
        screenshot      = capture focused window             // ~60ms warm
        visual_boxes    = OmniParser detect(screenshot)      // ~30ms
        focused_targets = apply_baseline_filters(visual_boxes)   // §5.1, ~5ms

    return dock_targets ∪ menubar_targets ∪ extras_targets ∪ focused_targets
```

**`AX_FOCUSED_WHITELIST`** 见 `Sources/Mouseless/AppRegistry.swift`。初始内容：Apple 自家 AppKit app（Finder、Mail、Safari、Pages、Xcode...），10-15 条。第三方 app 必须经过实测验证 AX 覆盖好才能进。

#### 延迟分析（M3 Max，实测数）

**Whitelist 路径**（Finder / Mail / Xcode / ... 这种 AX 优秀的）：

```
thread A: dock + menubar + extras AX walk    ~50ms
thread B: AX walk focused app subtree         150-200ms

user-facing = max(A, B) = 150-200ms
```

**OP-default 路径**（WeChat / Slack / VS Code / Tauri app / 任何不在 whitelist 的）：

```
thread A: dock + menubar + extras AX walk    ~50ms
thread B: screencap + OP infer + filter      60 + 30 + 5 = 95ms warm

user-facing = max(A, B) = ~95ms
```

**反直觉**：OP-default 比 whitelist 路径还**更快**——因为 AX 焦点 walk（150-200ms）是 Mouseless 最重的操作，OP 取代它后 wall-clock 反而下降。AX walk 的速度优势其实早被现代 ScreenCaptureKit + CoreML on Metal GPU 抹平了（详见 P1 spike `omniparser-coreml-spike` 的 29ms 推理数据 + P2 `ScreenCapture.swift` 的 60ms warm screencap）。

Whitelist 在性能上**只是相同/略劣**，它存在的真正理由是别的：
- 不依赖 Screen Recording 权限（仅对真正不想授权的用户有意义）
- AX 元素携带 role / label / state，未来 mode 扩展（selectText、drag）可能用得到
- AX click 精度 100%（box 中心一定可点），不需要 §4.6 的 OCR refiner

权衡后选 OP-default 是因为：**universal coverage + 简单决策（一个 set lookup） + 大多数 app 上更快**。Whitelist 的两项优势对当前 hint mode 实际用不上，未来需要再扩展。

### 4.3 每类目标的 commit 行为

| 来源 | sourceWindow | commit 时怎么点 |
| --- | --- | --- |
| AX target | 有 | 合成 mouse event 到 rect 中心（见 `hint-rendering.md` §3——AX action 路径已废，统一走合成） |
| OmniParser-only target | 无 | 合成 mouse event 到 box 中心（见 §4.6 含 OCR refiner） |

两条路径 commit 机制**完全统一**，区别只在 click point 怎么算（AX 有现成 rect；OP 要 OCR refiner 处理容器嵌套问题）。

Sticky rescan / `HintWindowCache` 逻辑保留——AX 是主路径，缓存有价值。OmniParser 这一支每次重新跑 detection（140ms 稳态，不值得缓存复杂度）。

### 4.4 路径选择：OP-default + AX whitelist

**决策**：bundle ID 在 `AX_FOCUSED_WHITELIST` 里 → AX 焦点 walk；其他全部 → OP 路径。Dock / menubar / extras AX walk 永远跑（§4.2）。

实现位于 `Sources/Mouseless/AppRegistry.swift`：

```swift
@MainActor
enum AppRegistry {
    static let axFocusedWhitelist: Set<String> = [
        "com.apple.finder",
        "com.apple.mail",
        "com.apple.Safari",
        "com.apple.TextEdit",
        "com.apple.Preview",
        "com.apple.calculator",
        "com.apple.Terminal",
        "com.apple.Console",
        "com.apple.ActivityMonitor",
        "com.apple.Pages", "com.apple.Keynote", "com.apple.Numbers",
        "com.apple.iCal",
        "com.apple.dt.Xcode",
        "com.apple.Notes",
    ]

    static func shouldUseAXForFocused(bundleID: String) -> Bool {
        return axFocusedWhitelist.contains(bundleID)
    }
}
```

#### 维护原则

- **保守入选**：第三方 app 必须经过实测 + 主观确认"在这个 app 里 AX 路径 hint 体验明显优于 OP 路径"才入。默认是 OP。
- **错向无害**：whitelist 漏了一个 AX-good app → 多花 ~80ms 跑 OP（OP 也能给好 hint），不影响功能正确性。whitelist 误收一个 AX-bad app → 用户直接观察到"hint 在这个 app 上少了关键东西"，剔除即可。**错向都不致命，但漏比误便宜**。
- **不依赖自动探测**：上一轮设计尝试 framework detection 自动分类（Catalyst / Electron / WKWebView / 自渲染），但 WeChat 击破了"native = AX-good"的假设（详见下文「历史决策」第三轮），证明自动探测不可靠。**手工 whitelist + 错向便宜 = 正确权衡**。

#### 决策是否要 per-view 细化（暂不做）

理想情况：

- Safari → chrome (AppKit, 好) + web view (per-site varies)
- Xcode → 编辑器 (好) + 集成 doc viewer (WebKit)
- VS Code → menu bar (native, 好) + editor (Monaco) + bottom panel

严格说应该 per-view 判定。**第一版按 app 维度足够 80/20**。哪个 app 真的需要 per-view 分流再单独处理。

#### 历史决策

这一节**经过三轮翻盘**：

**第一轮（推翻）**：最初按 "count 阈值是主信号" 写——AX 返回候选数 < N 时触发 OP。发现两头都不准：AX-bad app 经常返回虚高 count（menu bar / dock / sidebar 加起来 30+ 但实际内容区域 = 0），AX-good app 偶发合法 low count（空 Finder 窗口、简单对话框）。**改成"框架探测优先 + count 当安全网"**。

**第二轮（推翻）**：第一版框架探测只用 bundle-layout（Catalyst Info.plist / Electron Framework 路径），漏掉 WKWebView 包装的 web shell（New Outlook、Teams、OneNote 新版）。**改成"两层探测：bundle fast path + AXWebArea BFS 兜底"**——Layer 2 BFS 到 depth 5 能命中绝大多数 web 内核 app（Clash Verge / Tauri 等也覆盖）。

**第三轮（推翻——本次）**：实测 WeChat 击破核心假设「**non-native = AX-bad / native = AX-good**」。WeChat 是 genuine native AppKit（bundle 含 swift dylibs 和 .nib 资源、AX 树里有 `AXTable` `AXRow` `AXScrollArea` 等 AppKit 标准 widget），但**聊天消息气泡是自定义 NSView，AX 完全看不到**——AX 焦点 walk 返回 58 个候选（够多），却全是 sidebar 和 nav，**用户真正想点的消息内容 0 候选**。

WeChat 不是孤例：QQ / 钉钉 / 飞书 / 网易系一大类中国大厂 native app 都是这个模式。一旦"框架 ≠ AX 质量"，整个 framework-detection 路由失去基础——blacklist 路径不可持续。

**改成"OP-default + 显式 AX whitelist"**：

- OP 路径**对所有 app 都 work**（包括 WeChat 这种 "native + 自渲染" 的 AX 黑洞）
- OP 性能数据（screencap 60ms warm + CoreML 推理 29ms = ~95ms parallel with AX 50ms = max 95ms wall-clock）**已经比 AX 焦点 walk 快**（AX 焦点 walk 单独要 150-200ms）。OP-default 的成本只是 Screen Recording 权限要求和略低的 click 精度（用 OCR refiner 补偿，§4.6）。
- 决策机制简化为一个 `Set<String>` lookup，**没有自动探测、没有缓存、没有 BFS、没有 fallback chain**。

`FrameworkDetector.swift` 已经从代码库删除（保留在 git commit `04f57f4` 里供未来回看）。

留这段史是为了**警告未来读者**：每次撞墙的反应都是"再加一层启发式探测让它更智能"，但实际上**人工 whitelist 比自动探测更便宜、更可控、更可解释**。下一次想要"自动 detect AX-bad app"之前，先问"我们为什么不直接维护 whitelist？"

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

第 4 类是工程问题（必须正确），1-3 + 5 类是 OP 路径的**固有概率性失败**——AX 路径下完全不存在。下面的 refiner **只处理第 5 类**（容器嵌套）——这是唯一能在不 OCR 的情况下廉价检测、且 OCR 修复收益明确的一类。第 1、2 类（box 偏移 / 可点≠视觉）实测下 box 中心命中率已经够高，无脑 OCR 反而引入新错误（详见下方"历史决策"）；第 3、4 类 refiner 处理不了。

#### 实现版本：fast-path 优先，只在 center 冲突时才 OCR

> 实现见 `Sources/Mouseless/OCRRefiner.swift`。**早期草稿（保留在本节下方"历史决策"）是"无脑 OCR 优先"——实测推翻了，现在是"先判断 center 是否真的有问题，只在有问题时才 OCR"**。

观察：**点文字几乎一定命中 click handler**（文字在可视区域内、贴近中央）。但**"无脑 OCR 出文字就点文字中心"是错的**——实测在 WeChat 聊天行上：

- 聊天行是"整行可点"——行内任何像素点击都触发选中
- box 中心本来就 work
- 但 OCR 只识别到角落的 "21:52" 时间戳（漏了中文名/消息），refiner 反而把 click **从行中央拽到右上角的 21:52**——更糟

教训：**OCR refiner 只该在 box 中心"真的有问题"时介入**。怎么判断有问题？

§4.6 列的 5 类 misclick 里，只有**第 5 类（容器嵌套）能在不 OCR 的情况下廉价检测**——直接判断 `box 中心 ∈ 某个 inner box`。第 1 类（box 框偏移）罕见，且 OCR 误判的风险比它的收益大。所以：

```
refine(B, inner_boxes):
    center = B 的几何中心

    # Fast path：center 不在任何 inner box 里 → 直接用 center
    # 覆盖绝大多数（聊天行、列表项、无嵌套的按钮）。
    # 零 screencap、零 OCR、零额外延迟。
    if center ∉ any inner_box:
        return center

    # Slow path：center 落在某个 inner box 里 → 点它会触发 inner box
    # 的 handler 而非 B 自己的。重新截屏 + OCR B 的 crop，找一个
    # "在 B 内、但避开所有 inner box" 的点。
    text_regions = OCR(B.crop)        # .accurate + 显式中文语言

    # Step 1: own_text = 中心不在任何 inner box 内的文字
    own_text = [t for t in text_regions if t.center ∉ any inner_box]
    if own_text 非空:
        return 最长 own_text 段的中心

    # Step 2: 没有 own_text（文字全属于 inner box）→ 找 own_region
    #   候选 = [B 中心, B 四条边中点]
    #   过滤掉落在 inner box 里的候选
    #   取剩下里离所有 inner box 最远的那个
    candidates = [B.center, top_mid, bottom_mid, left_mid, right_mid]
    outside = [c for c in candidates if c ∉ any inner_box]
    if outside 非空:
        return outside 里离 inner box 最远的
    # Step 3: 全部候选都在 inner box 里（病态，B 几乎被 inner 完全覆盖）
    return B.center
```

设计原则不变（**两个 hint = 两个独立目标，外层 click 必须避开 inner box 覆盖范围**），但**触发条件收紧了**：不是"有 OCR 文字就用"，而是"只有 center 真的撞 inner box 才动用 OCR"。

#### 每个 case 的具体处理

| 场景 | 走哪条路径 |
| --- | --- |
| 聊天行 / 列表项 / 普通按钮（无 inner box 或 center 不撞 inner） | **fast path** → 点 box 中心，不 OCR |
| 大框套小框，小框含文字，**大框中心恰好压在小框上** | slow path：OCR → Step 1 own_text（大框自己的文字）或 Step 2 own_region |
| 大框中心压在小框上 + 大框有自己标题 "Tech Backlog" | slow path → own_text = ["Tech Backlog"] → 点它中心 |
| 大框中心压在小框上 + 大框无自己文字 | slow path → own_text 空 → Step 2 own_region（边中点离 inner 最远的） |
| 大框中心**不**压在小框上（小框偏在一侧） | fast path → 点大框中心（中心本来就是大框自己的区域） |

关键区别：**只有"大框中心恰好压在小框"才进 slow path**。"大框套小框但小框偏在角落" → 大框中心仍在自己区域 → fast path。

#### CJK OCR 配置（实现细节，但 load-bearing）

slow path 的 OCR 必须能识别非拉丁字符，否则 containment 算法在中文/日文/韩文 UI 上失效：

```swift
request.recognitionLevel = .accurate         // .fast 是拉丁偏向的字符检测器，漏 CJK
request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]  // 显式，否则跟系统 locale
request.usesLanguageCorrection = false       // UI 文字不是句子
```

`.fast` 实测在 WeChat 上只能识别 "21:52" 这种数字，中文名直接漏掉。`.accurate` + 显式中文语言后，"许大维长点脑子" / "洗好了" 都能识别。代价 ~20-40ms，但 slow path 本来就罕见。

#### own_region 的简化实现

完整版 `own_region = B.rect minus union(inner_boxes.rects)`（轴对齐矩形减法，结果是 L 形 / frame 形）理论上更精确，但实现复杂。当前用**边中点近似**：候选 = {B 中心 + 四边中点}，过滤掉落在 inner box 里的，取离 inner 最远的。~10 行，大多数 case 行为正确。观察到边界 case 失败再升级到完整多边形减法。

#### 这条路径处理的失败模式

回到 §4.6 前面列的 5 类 misclick：

- **第 1 类**（偏移 box）：fast path 下不处理（接受 box 中心，罕见且 OCR 风险大于收益）
- **第 2 类**（可点区域 ≠ 视觉）：同上，fast path 接受 box 中心
- **第 3 类**（透明 overlay 截获）：refiner 无能为力 ✗
- **第 4 类**（HiDPI 坐标系）：工程问题，跟 refiner 无关 ✗
- **第 5 类**（容器嵌套导致外层 hint 错点内层目标）：**slow path 专门处理** ✓

注意跟早期草稿的区别：草稿声称 refiner 处理第 1、2 类（"点文字避开 padding"），实测发现**无脑 OCR 引入的新错误（聊天行被拽到时间戳）比它修的第 1、2 类更多**，所以收紧成只处理第 5 类。第 1、2 类留给 box 中心——实测大多数 OP box 中心都可点。

#### 历史决策

§4.6 的 refiner 算法经过一次实测推翻：

**草稿版（已弃）**：commit 时**无脑** OCR box → Step 1 取最长 own_text 中心 → Step 2 own_region → Step 3 box 中心。理由是"点文字一定命中 handler"。

**实测推翻**：WeChat 聊天行——OCR 在 `.fast` 模式下只识别到 "21:52" 时间戳（漏中文），refiner 把 click 从行中央拽到右上角时间戳，**比直接点 box 中心更糟**。即使修好 CJK 识别（`.accurate`），无脑取"最长文字"在多文字行上也不一定是用户想点的位置。

**改后版（当前）**：fast-path 优先——`box 中心 ∉ 任何 inner box` 就直接用中心（覆盖绝大多数），**只有 center 真的撞 inner box（容器嵌套的第 5 类）才动 OCR**。既省 60-90ms（大多数点击不 screencap/OCR），又避免 OCR 误判。

教训：**"理论上更精确的方案"（无脑 OCR）实测可能更差**——OCR 本身有识别失败/不全的概率，把它放进每次点击的关键路径，等于把它的失败概率叠加进来。只在"不用它一定错"（center 撞 inner box）时才用，是更稳的工程选择。

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

> **注：下面的实现块已过时。** 实际 `ScreenCapture.captureFocusedWindow` 用的是"截整个 display 再按窗口 rect crop"（读已合成 framebuffer，比 `desktopIndependentWindow` 的强制重渲染快），不再用 `_AXUIElementGetWindow` / CGWindowID。另外它带一个 `isolateApp` 开关：sticky 切 app 后的重扫用 `SCContentFilter(display:excludingApplications:[dockApp])` **排除 Dock 进程**，把 Cmd+Tab 切换器 HUD（Dock 拥有的窗口）从截图里去掉——否则 OP 会把切换器上的 app 图标识别成 hint。详见 `modes.md` §4.2。

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
