# Mouseless Prototype — Specs

完整替代鼠标的 macOS 键盘操作层。当前 prototype 实现的入口文档。

**读这一份**：项目定位、怎么跑、顶层架构、文件职责、关键权衡。
**子文档**：具体 subsystem 的实现细节和踩坑记录，见 [§ 5 文档地图](#5-文档地图)。

差异点（vs Homerow）：Electron 支持 + 多 mode 架构（未来 select-text、drag）是 wedge。
hint mode 本身只是 MVP 基线。详见 `memory/competitor_homerow.md`、`memory/feedback_priorities.md`。

---

## 1. 运行 / 构建

```sh
cd prototype
./run.sh           # swift build + ad-hoc 重签名 + 启动
```

`run.sh` 三步缺一不可：

1. `swift build` —— Swift 6 严格并发，platforms = `.macOS(.v13)`。
2. `codesign --force --sign -` —— 用 ad-hoc 签名**覆盖** SwiftPM 的 linker-signed 签名。
   后者对 TCC（Accessibility）授权不稳定，每次重建都让用户重新授权；ad-hoc 签名后授权稳定记住。
3. `pkill -f Mouseless` —— 旧实例必须杀掉再起新的，否则旧 event tap 还在拦截事件。

启动后菜单栏出现 `M` 图标：
- `M●` = 已就绪，按 **Caps Lock** 进入 vim mode
- `M⚠` = Accessibility 未授权

启动时 app 自动跑 hidutil 把 Caps Lock 重映射成 F19（见 §2.1），用户**零设置**。app 退出时自动还原 Caps Lock 原始行为。

`main.swift` 用 `setActivationPolicy(.accessory)` —— 没有 Dock 图标，也不抢焦点。

---

## 2. 权限

**只依赖 Accessibility。** 不需要 Screen Recording、不需要 Input Monitoring。

- 第一次启动会弹 AX 授权对话框（`AXIsProcessTrustedWithOptions` + `kAXTrustedCheckOptionPrompt`）。
- 授权后必须**完全退出**并重启进程才能生效（系统不会热加载权限）。
- 从 kitty / iTerm 启动 `./run.sh` 时：TCC 的 responsible process 是 terminal，权限挂 terminal 上；
  双击 `.app` 才会以 Mouseless 自身为 responsible process。开发期走 terminal 路径。

历史决策：曾尝试过 `CGWindowList` + Screen Recording 列举 menu extras。Sonoma+ 菜单栏渲染
集中到 Control Center 进程，第三方 status item 看不到，即使授权也没用。已移除。详见 `specs/hint-discovery.md`。

### 2.1 触发键（Caps Lock → F19）

触发键是 **F19**——一个标准键盘上没有的"Hyper 键"。物理 Caps Lock 经 `hidutil` 重映射成 F19 后被 CGEventTap 接管。

**App 自动管理这个映射**，见 `TriggerRemap.swift`：

- `applicationDidFinishLaunching` (AX 授权通过后) → `TriggerRemap.applyAtLaunch()` 调一次 `/usr/bin/hidutil property --set ...`
- `applicationWillTerminate` → `TriggerRemap.revertAtQuit()` 调 `hidutil property --set '{"UserKeyMapping":[]}'`

用户视角：装上、授权、按 Caps Lock 就用上；quit Mouseless 后 Caps Lock 又是普通 toggle，零残留。

底层就一行 `hidutil property --set ...` 把 HID usage `0x39` (Caps Lock) → `0x6E` (F19)。
**不需要 root，不需要 kext**。Caps Lock 的 LED 不再随按键亮 —— 这是对的，键的身份已经不是 Caps Lock。

**为什么走 F19 而不直接抓 Caps Lock**：macOS 对 Caps Lock 做特殊处理——只发 `flagsChanged` 事件改 `.maskAlphaShift` flag，**不发 keyDown**，CGEventTap 接不到一个可匹配的事件。重映射后系统在 HID 层就把这个键当 F19 处理，走普通 keyboard 事件流，event tap 拿得到，且没有 toggle 状态。

**生命周期不完美的地方**：`applicationWillTerminate` 在 force-quit / 崩溃 / 系统关机时**不一定 fire**。这几种情况下 remap 残留到下次 reboot 或下次 Mouseless 启动（启动时 applyAtLaunch 是幂等的，重新应用一次没副作用）。用户感知到时可以手动 `hidutil property --set '{"UserKeyMapping":[]}'` 清掉。

### 2.2 setup-trigger.sh — 仅给高级用户

正常使用根本不用碰这个脚本，app 自己搞定。它存在的两个场景：

```sh
./setup-trigger.sh             # 不启动 app、只手动应用 remap（测试 / 调试用）
./setup-trigger.sh --persist   # 装一个 LaunchAgent，让 remap 在 Mouseless 不运行时也生效
```

`--persist` 模式的使用场景：用户依赖 F19 给**其他**工具用（比如自己绑了 F19→某 Alfred workflow），希望 Caps Lock = F19 **永远生效**，不止 Mouseless 运行时。

### 2.3 卸载

```sh
hidutil property --set '{"UserKeyMapping":[]}'                            # 当前 session 恢复
launchctl unload ~/Library/LaunchAgents/com.mouseless.trigger-remap.plist  # 卸 LaunchAgent（如装过）
rm ~/Library/LaunchAgents/com.mouseless.trigger-remap.plist
```

---

## 3. 顶层架构

```
NSApplication
└── AppDelegate (main.swift)
    ├── NSStatusItem ("M" 菜单栏图标)
    ├── HotkeyTap         ← CGEventTap，拦截/放行所有键盘事件
    │   └── VimSession    ← mode 状态机 + 命令面板缓冲
    │       └── HintMode  ← AX 扫描 + 标签生成 + 提交点击
    │           ├── HintOverlay (全屏透明窗口画 hint label)
    │           └── HUD       (右下角 mode 提示)
    └── MenuExtraCache    ← 后台维护"哪些 PID 有 menu extras"的 PID 集合
```

控制流：

1. **HotkeyTap** 是唯一事件入口。注册 `CGEvent.tapCreate` 监听 `keyDown` + `keyUp` + `flagsChanged`。
   每个事件先检查 `eventSourceUserData == "MOUS"` —— 我们自己合成的直接放行（避免反馈环）。
2. **F19（= Caps Lock）走 arm 机制，任何 mode 都适用**：按下不立即动作（arm）；松手时若期间没按 chord → `session.handleTriggerTap()`（按当前 mode 分派：OFF→进 TAP / TAP→切 sticky / SCROLL→切 TAP / palette→关）；arm 期间按 d → `session.enterScroll()`。详见 `modes.md` §2.1。
3. **其他键**在已激活时交给 `VimSession.handle()`。返回 `true` = 消费，`false` = 放行（让 Cmd+Space / Cmd+Tab 等系统快捷键继续工作）。
4. `VimSession` 按 mode（`.tap` / `.scroll`）和 palette 状态分发；mode 内部决定 hint / 移光标 / 滚动 / 退出。
5. 提交点击**统一合成 mouse event**（AX 语义动作 AXPress/AXShowMenu 已弃用——不可靠，见 `hint-rendering.md` §3）。
   合成事件统一打 `"MOUS"` 标记。

---

## 4. 文件职责

**核心**：

| 文件 | 职责 |
| --- | --- |
| `main.swift` | NSApp 启动器，accessory activation policy |
| `AppDelegate.swift` | 菜单栏、AX 权限检查、启动 HotkeyTap、`MenuExtraCache.warmUp()`、`OmniParserModel.preload()`、`TriggerRemap` 生命周期 |
| `HotkeyTap.swift` | CGEventTap 注册（keyDown/keyUp/flagsChanged）+ 反馈环避免 + F19 arm/chord 分派 |
| `VimSession.swift` | Mode 状态机（`.tap`/`.scroll`）、arm 分派（`handleTriggerTap`/`enterScroll`）、palette、按键路由 |
| `HintMode.swift` | 收集 4 来源（焦点窗口 AX **或** OP / Dock / menubar / extras）→ 生成标签 → typing → commit（合成点击）|
| `HintWindowCache.swift` | 焦点 app 的 per-`AXWindow` 缓存。sticky rescan 复用没动过的 window 子树 |
| `MenuExtraCache.swift` | 后台维护"哪些 PID 有 menu extras"的 PID 集合 |
| `HintOverlay.swift` | 每屏一个无边框透明窗口，绘制 hint 标签（大 rect 用 inside 放置） |
| `HUD.swift` | 右下角 mode 提示 |
| `KeyCode.swift` | `kVK_ANSI_*` 物理键码常量（含 `f19=80`；ANSI 布局，非 QWERTY 会出错） |
| `FocusedApp.swift` | 经 `NSWorkspace.frontmostApplication` 解析前台 app（Electron 上比 AXFocusedApplication 可靠） |
| `MouseSynth.swift` | 合成 mouse click + drag down/up + 取光标位置（hint commit、Enter 点击、DRAG 共用） |
| `TriggerRemap.swift` | App 启动 shell-out `hidutil` 把 Caps Lock → F19；退出还原 |
| `KeyPoster.swift` | 合成键盘事件辅助（主路径未用；留给未来 select-text mode） |

**键盘鼠标 / 滚动**：

| 文件 | 职责 |
| --- | --- |
| `MouseMover.swift` | hjkl 连续移光标，**TAP + SCROLL + DRAG 共用**（60fps timer；`dragHeld=true` 时事件类型换成 `.leftMouseDragged`） |
| `ScrollController.swift` | SCROLL 模式滚动合成 + 连续 + 加速 + 区域选择 + 光标 warp |
| `DragController.swift` | DRAG 模式状态容器：`startPoint`（Backspace 取消用来 warp 回 + 起点 mouseUp）+ `preMode`（决定 Enter/Backspace 完成后回哪个模式，见 `modes.md` §6） |
| `ScrollAreaDetector.swift` | AX-walk 焦点窗口找 `AXScrollArea`/`AXWebArea`（不依赖 OP 路由）|
| `ScrollOverlay.swift` | 滚动区域 picker：蓝色光晕边框 + 数字标记 |
| `WindowController.swift` | WINDOW resize 模式状态机 + 60fps timer：跟踪当前按住的 hjkl 边集合、每 tick 算 resize delta 直接 AX 写焦点窗口（无 fallback 路径——入口 gate 已保证 AX 可写）。每 tick 现读 `NSEvent.modifierFlags`：Shift = shrink、Option = 5pt 精细步长、两者正交可组合。见 `modes.md` §7 |
| `WindowMoveController.swift` | WINDOW MOVE 模式状态机 + 60fps timer：跟踪按住的方向集合（`enum Direction { left, right, up, down }`），每 tick 只写 `AXPosition`（单 IPC，比 resize 省一次）。修饰键：bare 20pt / Shift 80pt fast / Option 5pt slow（Option > Shift 优先，仿 `MouseMover.moveSpeed`）。见 `modes.md` §8 |
| `WindowOpOverlay.swift` | WINDOW resize / MOVE 共用：蓝色 border + 可选 4 个边缘 chip（`↑k / ↓j / ←h / →l`）。`show(rect:withChips:)` 控制是否画 chip——resize 画（绑边的暗示），MOVE 不画（hjkl 是方向不绑边）。仿 `HintOverlay` / `ScrollOverlay` 的 per-NSScreen borderless window 模式；chip 算位置时若不全包于当前屏内则跳过不画（用户要求：不画到屏幕外） |
| `AXWindowOps.swift` | 窗口 AX helper：`frontmostWindow()`、`isResizable()`（probe `AXPosition`+`AXSize` 都可写）、`isMovable()`（只 probe `AXPosition`——MOVE 不需要 `AXSize`）、`hasTitleBarButton()`（判"真窗口"：至少有 Close/Min/Zoom/FullScreen 一个按钮——`AXSubrole` 对 AX 黑洞 app 不可靠，标题栏按钮对外壳 NSWindow chrome 都查得到）、`readRect()` / `writeRect()`（两 IPC，pos+size）/ `writePosition()`（单 IPC，只写 origin，给 MOVE 用） |

**OmniParser 视觉路径**（AX-bad app 的焦点窗口 hint，见 `omniparser-fallback-design.md`）：

| 文件 | 职责 |
| --- | --- |
| `AppRegistry.swift` | `AX_FOCUSED_WHITELIST` —— 焦点窗口走 AX 还是 OP 的路由决策 |
| `ScreenCapture.swift` | ScreenCaptureKit 截焦点窗口（display capture + crop，display 缓存）|
| `OmniParserModel.swift` | CoreML YOLO 检测器（icon_detect.mlpackage，启动预加载）|
| `OmniParserPath.swift` | 截图 → 推理 → §5.1 baseline 过滤 → 屏幕坐标候选；debug overlay |
| `OCRRefiner.swift` | OP 点击精度：center 落进 inner box 时用 Vision OCR 重定位（含 CJK）|

**脚本**：

| 文件 | 职责 |
| --- | --- |
| `setup-trigger.sh` | 高级用户用。`--persist` 装 LaunchAgent，让 F19 映射独立于 Mouseless 生命周期 |

---

## 5. 文档地图

各 subsystem 的细节、设计权衡、踩坑记录在 `specs/` 下：

| 文档 | 内容 |
| --- | --- |
| [`specs/event-pipeline.md`](specs/event-pipeline.md) | HotkeyTap 注册、callback 三层 short-circuit、反馈环 `"MOUS"` 标记、修饰键透传策略（Cmd/Ctrl 放行，Shift/Option 消费） |
| [`specs/modes.md`](specs/modes.md) | Mode 状态机（`.tap`/`.scroll`）、F19 arm 机制、palette、sticky、hjkl 移光标（TAP+SCROLL 统一）+ Enter 点击、**所有键位表**、KeyCode 常量、新 mode 接入 |
| [`specs/scroll-mode-design.md`](specs/scroll-mode-design.md) | **SCROLL 模式完整设计**：chord 进入（Caps Lock + d）、AXScrollArea/AXWebArea 检测、多区域 picker、d/u 滚动合成、gg/G 跳顶底、hjkl 移光标 + Enter 点击、零-AX Electron 限制 |
| [`specs/hint-discovery.md`](specs/hint-discovery.md) | AX 三源（focused / Dock / menu extras）、`walk()` 收录条件、屏幕并集计算、**menu extras 踩坑史 + `MenuExtraCache` 设计**、并发安全 |
| [`specs/hint-rendering.md`](specs/hint-rendering.md) | 标签生成、typing → commit、**统一合成点击**（AX action 已弃）、`HintOverlay` 多屏窗口、坐标系转换、badge 排版（inside / Dock / 级联）、HUD |
| [`specs/omniparser-fallback-design.md`](specs/omniparser-fallback-design.md) | **已实现 (P5-P6)**：OP 视觉路径，OP-default + AX whitelist 路由（非 fall-through）；baseline 过滤；OCR click-point refiner（§4.6）；PoC 数据；captioner 搁置 |
| [`specs/omniparser-integration-roadmap.md`](specs/omniparser-integration-roadmap.md) | **实施路线图**：P0-P6 已完成（CoreML spike → 截屏 → 路由 → 集成 → 端到端 → OCR refiner），P7（数据调参）/ P8（发布）待做 |
| [`specs/per-app-correction-design.md`](specs/per-app-correction-design.md) | **设计草稿，未实现**：per-app 修正层（模板匹配补 OP 漏检 + exclude 误报），护城河；P8 之后启动 |

---

## 6. 关键设计权衡（speed-read）

| 权衡 | 选择 | 理由 |
| --- | --- | --- |
| 单元素 AX 属性获取 | `AXUIElementCopyMultipleAttributeValues` 一次拿 10 个属性 | per-element IPC 从 9+ 砍到 1，焦点 app 扫描从 ~840ms 降到 ~200ms |
| Sticky rescan 复用 | per-`AXWindow` cache + `AXWindows` diff + commit-driven dirty | 关弹框这种"只销毁一窗、其他没动"的常见操作不重扫 |
| Menu bar fast path | AXMenuBar 上读一次 `AXSelectedChildren`；空则不下钻 | 99% 时刻菜单栏没展开，跳过 N×4 个 axMenuIsOpen 探针 |
| Menu extras 发现 | 后台 PID cache + NSWorkspace 增量 | 触发期 < 30ms；预热成本对用户透明 |
| 点击实现 | **统一合成 mouse event**（不用 AX 动作） | AX 动作（AXPress/AXShowMenu）在 NSBrowser cell / 自定义 view / Electron 上常静默失败；合成点击行为可预测，跟用户心智一致 |
| `Enter` 点击 | 当前光标位置合成点击（Shift 双击 / Option 右键） | 跟 hjkl 移光标配套（移→点闭环）；取代了旧的 `x`"关菜单+重扫"手势 |
| 移光标 / 滚动用裸键不用 Ctrl | hjkl 移光标（TAP+SCROLL 统一）、d/u 滚动 | power user（HHKB）常把 Ctrl+hjkl 系统级映射成方向键，会冲突 |
| 焦点窗口 hint 路由 | AX whitelist → AX walk；其余 → OmniParser | 框架 ≠ AX 质量（WeChat 是 native 但 AX 黑洞）；OP 对所有 app 都 work 且 ~95ms 不比 AX walk 慢 |
| 滚动区检测 | 只用 AX（`AXScrollArea`/`AXWebArea`），不用 OP | 滚动区是容器无视觉特征，OP 识别不了；结构 AX 即使内容 AX 烂也可靠 |
| Overlay 数量 | 每屏一个窗口 | 单窗口跨屏 macOS 渲染不可靠 |
| Overlay 层级 | `.statusBar` (25) | 高于菜单栏，低于下拉菜单（保持自然 z-order） |
| 异步操作的"等" | AX / NSWorkspace observer + async/await + timeout 兜底 | 不用固定 sleep 猜时间。OS 通知比经验值早就发了就早走；慢路径一直等到 AX 同步完。silent failure 时超时兜底防 Task 卡死 |
| Cmd/Ctrl 透传 | 不消费 | 保 Spotlight、Mission Control、screenshot 等系统功能 |
| Shift/Option | 消费 | 给 hint click action 用（Shift=双击 / Option=右键） |
| 标签字符集 | home row 9 字母 + 10 数字 | 数字独立给 Dock，字母组留给其他来源 |
| KeyCode 抽象 | 物理 `kVK_ANSI_*` 常量 | 简单；代价：非 QWERTY 布局错位（已知缺口） |

---

## 7. 已知缺口 / Future work

按优先级：

1. **键盘布局** —— `KeyCode.swift` 是 ANSI 物理位。非 QWERTY 字母 hint 全错。
   迁移路径：用 `UCKeyTranslate` / `CGEventKeyboardGetUnicodeString` 把 keyCode + flags 映射到字符再匹配。
2. **Electron / AX-bad app**（vs Homerow 的 wedge）—— **已实现 OmniParser 视觉路径 (P5-P6)**。
   背景：Chromium 桥暴露什么取决于 app 的 ARIA 卫生，差的（WeChat、国产 SaaS）一片
   AXGroup 无 action；而且框架 ≠ AX 质量（WeChat 是 native AppKit 但聊天内容自渲染、AX 黑洞）。
   方案：**OP-default + AX whitelist 路由**——焦点窗口不在 `AppRegistry.AX_FOCUSED_WHITELIST`
   的 app 走 OP（ScreenCaptureKit 截屏 + CoreML YOLO + baseline 过滤 + OCR click-refine），
   ~95ms 不比 AX walk 慢。剩余：P7 数据调参（confidence 阈值 / whitelist 增删）、P8 发布打包、
   per-app 修正层（模板匹配，护城河，P8 后）。详见
   [`specs/omniparser-fallback-design.md`](specs/omniparser-fallback-design.md)。
3. **App AX cleanup 期的扫描尖峰** —— 关弹框 / 关 sheet 后 sticky rescan 落进目标 app
   的 ~500ms cleanup 窗口里，per-IPC 延迟从 ~0.2ms 涨到 ~40ms。IPC 数已经压到下限
   13（cache + walkMenuBar 双管），优化空间在这条路径上耗尽。事件驱动等 AX 稳定再
   扫的方案没尝试过——通知发出时机不可控，理论 wall-clock 时间可能不降。
   **跟 OmniParser 路由是独立问题**——OP 只解决 AX 黑洞 app；cleanup 尖峰下
   AX 仍能返回候选（只是慢），且白名单 app 才走 AX walk。详见
   `specs/hint-discovery.md` §5 + [`specs/omniparser-fallback-design.md`](specs/omniparser-fallback-design.md) §4.5。
4. **新 modes** —— `Mode` enum 已经留好扩展点：select-text、right-click 命令模式（DRAG `specs/modes.md` §6 / WINDOW resize §7 / WINDOW MOVE §8 都已实现）。接入路径见 `specs/modes.md` §12。
5. **多 hint 来源的标签空间冲突** —— 焦点 app 元素很多时会吃光字母组，menu extras 排到 `lj/lk/ll`。
   方案候选：menu extras 走单独的前缀（如 `;a`, `;s` …）或单独字母池。
6. **Dock 分隔符 / Recents 占位过滤** —— 当前 Dock 把所有 `AXDockItem` 都收，包括分隔符。低价值的 hint 浪费标签。
