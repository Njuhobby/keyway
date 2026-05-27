# OmniParser Integration — Phased Roadmap

把 `omniparser-fallback-design.md` 里的设计落到代码上的分阶段实施计划。

**总目标**：让 Mouseless 在 AX 黑洞 app（Electron / Catalyst / WKWebView 包装的 web shell）也能扫出 hint，端到端 wall-clock < 400ms，无 misclick UX regression。

**全程估算**：2-4 周专注开发 + 1 周真实数据调参。下面每个阶段都给了独立估时和风险。

---

## 总览：阶段依赖图

```
P0 决策     ──→  P1 CoreML 推理 spike  ──┬─→ P3 框架探测
   │                                      │
   │                                      ├─→ P4 集成接缝
   ↓                                      │
P2 截屏 + 权限 ──────────────────────────┘
                                          │
                                          ↓
                                     P5 baseline 过滤
                                          │
                                          ↓
                                     P6 OCR refiner
                                          │
                                          ↓
                                     P7 端到端测试 + 数据
                                          │
                                          ↓
                                     P8 发布打包
```

P0/P1/P2 可以并行（人手够的话）。P3-P8 串行。

---

## P0 — 架构决策（1-2 天）

**目标**：定下不可逆的架构选择，避免后续阶段返工。

**输出**：一份简短决策记录（直接更新 `omniparser-fallback-design.md` §6），不是新文件。

**待决问题**：

1. **推理进程边界**：CoreML in-Swift vs Python sidecar?
   - 倾向：CoreML（已写进 design doc §6.1）
   - 推翻条件：P1 spike 显示 CoreML 转换精度大幅下降 / ANE 不支持必要的算子
   - 备用方案：Python sidecar + Unix socket JSON-RPC（PoC 代码可改造，多 ~1 周）

2. **模型分发**：bundle in .app vs first-launch download?
   - YOLO weights ~30MB。bundle 进 app 优点：离线可用、无依赖网络。缺点：app size 上升。
   - 倾向：**bundle**（30MB 在 menu bar app 里仍然可接受）

3. **截屏 API**：ScreenCaptureKit vs CGWindowList vs CGDisplayCreateImage?
   - 倾向：ScreenCaptureKit（现代 API，多显示器友好，性能最佳）
   - 但需要 Screen Recording 权限，这是 AX 之外的新门槛——见 P2

4. **`HintMode.swift` 改造范围**：原地改 vs 新建 `HintSource` 抽象层?
   - 倾向：引入 `enum HintSource { case ax(...); case omni(...) }`，`HintTarget` 内部 union
   - 理由：commit() 已经是纯合成 click，路径统一；唯一分支是 cache invalidation（OP 不写 cache）

**风险**：决策错了到 P4 才暴露，返工成本大。Mitigation：P1 spike 完成前不锁定其他决策。

---

## P1 — CoreML 推理 spike（2-3 天）

**目标**：验证 YOLOv8 → CoreML 转换是否保留召回率，ANE 推理延迟是否优于 PoC 的 MPS Python。

**输出**：
- 一个 throwaway Swift command-line tool：input 图片路径 → output JSON box list
- 转换后的 `.mlpackage` 模型文件
- 性能数据表（对比 PoC 的 MPS Python 数据）

**步骤**：
1. 用 ultralytics 官方 export 工具把 `icon_detect/model.pt` 转 CoreML：
   ```bash
   yolo export model=icon_detect/model.pt format=coreml nms=True
   ```
   注：`nms=True` 让 NMS 进图，省掉 Swift 侧手写
2. 写个 ~150 行的 Swift CLI（`omniparser-coreml-spike/`，仓库外）：
   - 加载 `.mlpackage`，单图推理
   - 输出 `[{x, y, w, h, confidence}, ...]` JSON
3. 在 PoC 的三张截图上跑，验证：
   - **召回率**：转换后 box 数和 MPS Python 偏差 < 10%（说明转换没掉精度）
   - **延迟**：ANE p50 < 100ms（理论目标；超过 MPS 也算 acceptable）
4. 跑一遍可视化 overlay，对比 PoC 的输出图

**风险**：
- **YOLOv8 算子 ANE 不支持**：某些算子（dynamic NMS、特定激活）会强制回退 CPU。Mitigation：先用 GPU compute units，验证可行后再优化 ANE。
- **精度损失**：CoreML 量化可能丢小目标。Mitigation：先用 FP16，必要时回到 FP32。
- **转换失败**：fallback 到 Python sidecar 方案，多 1 周。

**决策点**：spike 完成后明确"CoreML 路径走得通"，否则切 Python sidecar。

---

## P2 — 截屏 + 权限流（1-2 天）

**目标**：把"如何在 Swift 里拿到焦点窗口的截图"这个独立子问题闭环。

**范围决策**：**只截焦点窗口**，不是焦点屏、不是全屏。详见 `omniparser-fallback-design.md` §6.4 的讨论——核心理由：AX 路径在 Dock / menu bar / menu extras 上永远好用，OmniParser 精确补"焦点窗口内子元素 AX 黑洞"问题，截图范围跟 AX 路径互补不重叠 + 召回率更高（窗口 ~1500×900 → 1280² resize 比全屏 3000×2000 → 1280² 召回好）。

**输出**：
- `Sources/Mouseless/ScreenCapture.swift`：`focusedWindowImage() async throws -> CGImage?`（nil 表示焦点 app 没窗口）
- 权限请求 UI：lazy prompt（首次走 OP 路径时才弹）
- 跟 AX 协作的窗口探测：用 `AXFocusedWindow` + `_AXUIElementGetWindow` 拿 CGWindowID

**步骤**：
1. **AX 拿焦点窗口**：
   - `AXFocusedApplication` → app element
   - `app.attribute("AXFocusedWindow")` → window element
   - `_AXUIElementGetWindow(window, ...)` → CGWindowID（私有但 stable 的 API）
   - 任何一步 fail → 返回 nil，路径降级为 AX-only
2. **ScreenCaptureKit per-window 截图**：
   - `SCShareableContent.current.windows.first { $0.windowID == cgWindowID }` 找对应 SCWindow
   - `SCContentFilter(desktopIndependentWindow: scWindow)`（关键 mode：忽略遮挡，画完整窗口内容）
   - `SCScreenshotManager.captureImage(...)` → CGImage
3. **权限处理**：
   - 启动时**不**请求 Screen Recording
   - 首次 OP 路径触发时检测 `CGPreflightScreenCaptureAccess()`，没权限就弹原生授权 prompt
   - 没授权：当次 OP 路径退化为"无候选"（跟现在 AX 黑洞 app 体验一致），不阻塞 Mouseless 整体
4. **AX-bad app 验证**：在 WeChat / Slack / VS Code 这种 AX 黑洞 app 上跑一遍，确认 `AXFocusedWindow` ✅ 能拿、CGWindowID ✅ 能拿、ScreenCaptureKit ✅ 能出图。**AX 黑洞只是子元素层的问题，顶层窗口骨架对所有 app 都可用**。
5. **验证延迟**：典型 < 30ms 在 M 系列。

**风险**：
- **权限 UX 突兀**：用户切到 Slack，按 Caps Lock，弹个授权框很惊。Mitigation：banner 里提示一次"打开 Electron 支持需要 Screen Recording 权限"。
- **截屏延迟超 50ms**：超过会吃掉 OP 路径的预算。如果发生，调研 `SCStream` 持续流 vs single-shot screenshot 的差异。
- **`_AXUIElementGetWindow` 是私有 API**：苹果可能哪天 break。备用方案：用 `CGWindowListCopyWindowInfo` 按 PID + 窗口标题匹配（慢但 public）。第一版先用私有 API，遇到问题再切。

---

## P3 — 路由决策（0.5 天）

**目标**：实现 OP-default + AX whitelist 路由（详见 design doc §4.4）。

> **历史**：P3 最初是"两层框架探测"——撞 WeChat 后整体推翻。WeChat 是 native AppKit 但 AX 黑洞，说明框架 ≠ AX 质量。改成显式 whitelist。`FrameworkDetector.swift` 实现已在 commit `04f57f4` 提交、`b0e4...` (P3 pivot 这次) 删除。

**输出**：
- `Sources/Mouseless/AppRegistry.swift`：`AX_FOCUSED_WHITELIST: Set<String>` + `shouldUseAXForFocused(bundleID:) -> Bool`
- 初始 whitelist：~15 条 Apple-built AppKit app（Finder、Mail、Safari、Pages、Xcode 等）
- VimSession.enter() 加 routing 决策 log（debug 用）

**步骤**：

1. **新建 `AppRegistry.swift`**：whitelist 用 `Set<String>` 即可，O(1) lookup
2. **VimSession.enter() 加 log**：从 `AXFocusedApplication` 拿 bundleID，调 `shouldUseAXForFocused`，打 log `route: <bundleID> -> AX walk (whitelist) | OmniParser (default)`
3. **不改 routing 真分流**：collectAll 实际分流在 P4 接入。P3 只做"决策机制 + log"，验证 whitelist 命中预期

**风险**：极低。一个 set lookup。

---

## P4 — 集成接缝：HintTarget 改造 + 路由（2-3 天）

**目标**：把 OP 路径接进 `collectAll()`，commit() / cache 逻辑维持兼容。

**输出**：refactor 后的 `HintMode.swift` + 新的 `OmniParserPath.swift` stub（先返回空，P5 填充）。

**步骤**：

1. **`HintTarget` 改造**：
   ```swift
   enum HintSource {
       case ax(element: AXUIElement, sourceWindow: AXUIElement?)
       case omni(box: CGRect, confidence: Float)
   }
   struct HintTarget {
       let label: String
       let rect: CGRect       // screen-space, 两种来源都用
       let role: String       // AX role 或 "AXOmni"（OP 来源占位）
       let source: HintSource // 取代原来的 element + sourceWindow
   }
   ```
2. **`commit()` 适配**：
   - 当前已是合成 click on `rect.midX/midY`，**无需改动 click 逻辑**
   - `HintWindowCache.markDirty` 只对 `.ax` source 调用：
     ```swift
     if case .ax(_, let win?) = target.source {
         HintWindowCache.shared.markDirty(window: win)
     }
     ```
3. **`collectAll()` 路由**：AX walk 拆成"焦点 app 子元素"vs"其他 3 个 AX 来源"，OP 在 default 路径替代前者。详见 `omniparser-fallback-design.md` §4.2/§4.4。
   ```swift
   // 永远跑——dock/menubar/extras AX walk 跟下面焦点 app 分支并行
   async let dockTargets = walkDock(...)
   async let menubarTargets = walkMenuBar(...)
   async let extrasTargets = walkMenuExtras(...)

   // 焦点 app 子元素这一支：OP-default + AX whitelist
   async let focusedTargets: [HintTarget] = {
       if AppRegistry.shouldUseAXForFocused(bundleID: bundleID) {
           // Whitelist 路径：AX walk 焦点 app 子元素
           return walkFocusedApp(...)
       } else {
           // 默认路径：OP（截图 + 推理 + baseline 过滤）
           return await runOmniParser()
       }
   }()

   return await (dockTargets + menubarTargets + extrasTargets + focusedTargets)
   ```

   **关键点**：用 `async let` 让 4 个分支真正并行，而不是顺序跑。**OP 路径下** user-facing 延迟 ≈ `max(50ms AX 其他来源, 95ms OP) = 95ms`。**Whitelist 路径下**延迟 ≈ `max(50ms, 150-200ms 焦点 AX walk) = 150-200ms`。**OP 比 whitelist 还快** —— 这是 ScreenCaptureKit + Metal GPU 把 AX walk 反超的实际结果（见 P1/P2 数据）。
4. **hint label 分配**：当前是 `dock(numeric) + (focused + extras)(letters)`。OP 候选合并进 letter 池，跟 focused 共用空间。
5. **`OmniParserPath.swift` stub**：
   ```swift
   func runOmniParser() -> [HintTarget] {
       // P5 之前返回 []
       return []
   }
   ```

**风险**：
- **HintTarget 改造波及面**：grep `target.element` / `target.sourceWindow`，会动到 HintOverlay、VimSession 等。Mitigation：先 grep 列清单，refactor 一次性做完。
- **路由判断在 collectAll() 开销**：一个 Set lookup，< 1us。OK。

---

## P5 — Baseline 过滤（§5.1）（1 天）

**目标**：把 OP detector 输出的 100-180 box 压到 60-100。

**输出**：`OmniParserPath.applyBaselineFilters(boxes: [...]) -> [...]`

**步骤**：

1. Confidence 阈值：`box.confidence >= 0.3`（P7 数据调）
2. Size 最小值：`width >= 8 && height >= 8`
3. Size 最大值：`width * height <= 0.25 * screen.area`
4. NMS dedup：IoU > 0.5 的对里留高 conf
   - 注意：如果 P1 用了 `nms=True` 导出，NMS 已经在模型里做了；这里跳过即可
5. 每条 filter 打个 log 数（filtered out N）方便调试

**风险**：低。纯几何 + ML 后处理。

---

## P6 — OCR refiner（§4.6）（2-3 天）

**目标**：实现 containment-aware click point refinement，避开容器误点。

**输出**：`commit()` 路径里对 `.omni` source 调用 OCR refiner，决定真正的 click point。

**步骤**：

1. **Vision OCR 封装**：
   ```swift
   func ocrTextRegions(in image: CGImage) -> [(text: String, rect: CGRect)]
   ```
   用 `VNRecognizeTextRequest`，`recognitionLevel = .fast`（accurate 慢一倍，我们不需要拼写正确）
2. **crop 复用**：collect 阶段已经截过全屏图，commit 时直接从那张 crop 出当前 box（避免重新截屏）
3. **containment 检测**：
   ```swift
   let innerBoxes = allOmniTargets.filter {
       $0 != current && current.rect.contains($0.rect)
   }
   ```
4. **算法实现**（design doc §4.6 简化版）：
   - Step 1：OCR 出 `text_regions`，过滤掉 `region.center in any innerBox.rect` 的
   - Step 1 非空：点最长文字段的几何中心
   - Step 1 空 + innerBoxes 非空：
     - 用简化版：检查 `B.center` 是否落在某 innerBox 里
     - 不落 → 用 `B.center`
     - 落 → 取 B 四条边中点，选距所有 innerBox 最远的
   - 全部 fallback：`B.center`
5. **延迟预算**：单 box OCR 几 ms，commit 路径加 5-10ms 可接受
6. **logging**：refiner 决策路径打 log（"used own_text" / "used own_region midpoint" / "fallback center"）

**风险**：
- **Vision OCR Y 轴翻转**：Vision 用 bottom-left origin，AX 用 top-left。Mitigation：crop 之前明确坐标系转换。
- **OCR 误识别**：把图标当文字。无所谓——refiner 路径下任何决策都不比 box.center 差。

---

## P7 — 端到端测试 + 数据收集（3-5 天）

**目标**：在真实 AX 黑洞 app 上验证 OP 路径有效，调参，发现 design doc 没覆盖的边缘 case。

**测试 app 矩阵**：

| App | 框架 | 预期路径 | 关键 check |
| --- | --- | --- | --- |
| Finder | appkit | AX-only | OP 不该触发 |
| Slack | electron | OP | hint 覆盖侧边栏 + 消息列表 |
| WeChat | electron | OP | 文件列表能扫出 |
| Wrike (Chrome) | webContent (via Safari/Chrome) | OP | inbox 卡片可点 |
| New Outlook | webContent (Layer 2) | OP | 邮件列表可点 |
| Music | catalyst | OP | 左侧 playlists 能扫 |
| System Settings | appkit | AX-only + FALLBACK | 不该误触 OP |
| VS Code | electron | OP（除非进 whitelist） | 编辑器/侧边栏可点 |

**端到端指标**：

| 指标 | 目标 |
| --- | --- |
| Cold start（首次 OP 触发，含模型 load）| < 1.5s（可接受 user-visible 卡顿一次） |
| Hot path（OP 已 warm）| screencap + infer + filter + render < 400ms |
| Misclick 率 | OP 路径下点了无反应 < 10%（不要求 0） |

**数据收集**：
- 每次 OP 触发打详细 log：`[mouseless] OP: bundle=<X> screencap=<Xms> infer=<Xms> boxes_raw=<N> boxes_filtered=<N> render=<Xms>`
- 一两天用下来回看 log，看是否有：
  - 误触发（appkit app 进 OP）
  - 漏检（用户切回鼠标的 case）
  - misclick（点了没反应）
- 根据数据调：
  - `confidence threshold`（默认 0.3，可能要 0.2 拉召回，或 0.4 减误检）
  - `AX_FOCUSED_WHITELIST`（add/remove apps based on hint quality observations）
  - 是否需要 §5.2 的 exploratory 过滤

**风险**：
- **数据需要时间积累**：3-5 天可能不够，但能拿到 80% 信号
- **OP 慢得用户感知**：如果 cold start > 2s，考虑预加载（启动后 idle 时 warm 模型）

---

## P8 — 发布打包（1-2 天）

**目标**：把 OP 路径所需的额外 asset 和权限纳入 release pipeline。

**输出**：可发布的 signed + notarized .app。

**步骤**：

1. **模型文件 bundling**：`.mlpackage` 放进 `.app/Contents/Resources/`，code sign 自动覆盖
2. **Info.plist 更新**：
   - `NSScreenCaptureUsageDescription`：填一段"Mouseless 在不支持 accessibility 的 app 上需要截屏来识别可点元素"
3. **Notarization 验证**：CoreML 模型不会触发问题（Apple 自家格式），跑一遍 `notarytool` 确认
4. **Settings panel 更新**（如果有的话）：
   - 显示当前 app 的路由决策（AX whitelist vs OP default）
   - 提供 manual whitelist 编辑（增删 bundleID）
   - 显示 Screen Recording 权限状态
5. **README 更新**：说明 Electron 支持要 Screen Recording 权限

**风险**：低。常规 macOS app 发布流程。

---

## 跨阶段关注点

### 错误处理边界

每个新组件都要明确"失败时怎么办"：

| 组件 | 失败模式 | 处理 |
| --- | --- | --- |
| ScreenCapture | 无权限 / 调用失败 | 返回 nil，OP 路径降级为"无候选"，AX 候选仍可用 |
| CoreML 推理 | 模型加载失败 | log error，OP 路径退化为"无候选"，**Mouseless 整体仍可用** |
| OCR | Vision 调用失败 | refiner 降级到 `box.center` |

**核心原则**：OP 路径任何环节挂掉，**只影响焦点 app 子元素这一来源**——dock/menubar/extras 三个 AX 来源继续工作，用户至少能 hint 到这些。

### Telemetry / 调试

- 所有 OP 路径相关 log 用 `[mouseless OP]` 前缀，方便 grep
- Debug 模式（环境变量 `MOUSELESS_OP_DEBUG=1`）：dump 截图 + box 叠加图到 `/tmp`
- 每次 trigger 时 log 路由决策（AX whitelist vs OP default + bundleID）

### Out of scope（暂不做）

明确**这一版不做**的东西，避免 scope creep：

- **Per-view AX/OP 混合**（design doc §4.4 末尾提到的 Safari chrome + web view）：第一版只 per-app
- **Captioner**（design doc §3）：不需要
- **§5.2 exploratory 过滤**：P7 数据有需要再加
- **OP 候选的 cache**：每次重跑 detection（PoC 数据说稳态 140ms 不值得缓存复杂度）
- **Multi-display 并行扫**：第一版只焦点屏
- **CGEvent post 之后的 "click point flash" affordance**（design doc §4.6 末尾）：UX 改进，第二版做

### 配置开关

发布版至少要有两个用户可见开关（默认全开）：

- `Enable OmniParser fallback`：总开关（off 时退化到当前行为）
- `Show OmniParser hint badge`（debug）：OP 来源的 hint 是否用不同颜色标记

---

## 验收清单（全部 phase 完成的标准）

- [ ] 在 Slack / WeChat / Wrike / New Outlook 上按 Caps Lock 能看到 hint，按下 hint 字母能点到对应元素，misclick 率 < 10%
- [ ] 在 Finder / Mail / System Settings 上按 Caps Lock 行为不变（OP 不该被触发）
- [ ] Cold start 首次 OP 触发 < 1.5s，hot path < 400ms
- [ ] Screen Recording 权限拒绝时，AX 路径仍工作，OP 路径优雅降级
- [ ] App 通过 notarization，无 console 报错
- [ ] 文档更新：SPECS.md 移除 Electron known gap、Caps Lock 触发的 Electron app 文档化

---

## 时间线粗算

| Phase | 估时 | 累计 |
| --- | --- | --- |
| P0 决策 | 1-2 d | 2 d |
| P1 CoreML spike | 2-3 d | 5 d |
| P2 截屏 + 权限 | 1-2 d | 7 d |
| P3 框架探测 | 2 d | 9 d |
| P4 集成接缝 | 2-3 d | 12 d |
| P5 baseline 过滤 | 1 d | 13 d |
| P6 OCR refiner | 2-3 d | 16 d |
| P7 端到端 + 数据 | 3-5 d | 21 d |
| P8 发布打包 | 1-2 d | 23 d |

**~3-4 周专注开发**。Risk-adjusted（CoreML spike 失败要切 Python sidecar）：+1 周到 ~5 周。

P0/P1/P2 可以并行（人手够的话），可压缩到 ~3 周。

---

## 决策点（每个 phase 结束时复核）

- **P1 结束**：CoreML 走得通吗？走不通 → 切 Python sidecar，调整 P4 设计
- **P3 结束**：框架探测命中率合理吗？跑测试矩阵里每个 app 都该归对类
- **P4 结束**：合并后 commit 路径在 AX-only app 上有 regression 吗？
- **P7 结束**：misclick 率 / cold start / hot path 都达标吗？达不到回看是哪一步要优化

---

## P8 之后：per-app 修正层（重要独立模块）

OP 路径上线后会暴露"没有通用最强标准"——OP 不是 100% 准、confidence 阈值不通用、漏检/误报因 app 而异。解法是 **per-app 个性化修正**（可能是产品护城河），设计已固化在
[`per-app-correction-design.md`](per-app-correction-design.md)。

核心：**模板匹配补 OP 漏的固定 chrome icon**（teach-by-example，self-gating，无需训模型）+ pattern-based exclude 删误报 + per-app confidence override。**不是** per-app fine-tune 模型（体积/维护成本天文，已否决）。

暂不实现，等 P7 数据确认这是高频痛点后启动。
