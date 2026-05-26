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

1. **HotkeyTap** 是唯一事件入口。注册 `CGEvent.tapCreate` 监听 `keyDown` + `flagsChanged`。
   每个事件先检查 `eventSourceUserData == "MOUS"` —— 我们自己合成的直接放行（避免反馈环）。
2. **未激活**时只看 bare F19（= 重映射后的 Caps Lock） —— 命中调 `session.enter()` 吞掉该事件，其余全放行。
3. **已激活**时事件交给 `VimSession.handle()`。返回 `true` = 消费，`false` = 放行
   （让 Cmd+Space / Cmd+Tab 等系统快捷键继续工作）。
4. `VimSession` 按 mode 和 palette 状态分发；mode 内部决定要不要触发 hint、要不要退出。
5. 提交点击优先用 AX 语义动作（`AXPress` / `AXShowMenu`），失败再合成 mouse event。
   合成事件统一打 `"MOUS"` 标记。

---

## 4. 文件职责

| 文件 | 职责 |
| --- | --- |
| `main.swift` | NSApp 启动器，accessory activation policy |
| `AppDelegate.swift` | 菜单栏、AX 权限检查、启动 HotkeyTap、kick off `MenuExtraCache.warmUp()` |
| `HotkeyTap.swift` | CGEventTap 注册 + 反馈环避免 + 触发键 → `session.enter()` |
| `VimSession.swift` | Mode 状态机、命令面板缓冲、按键到 hint char 的映射 |
| `HintMode.swift` | AX 扫描三个来源 → 生成标签 → 处理 typing → 提交点击 |
| `HintWindowCache.swift` | 焦点 app 的 per-`AXWindow` 缓存。sticky rescan 时复用没动过的 window 子树，关弹框这种"只销毁一个窗"的常见 case 不重扫 |
| `MenuExtraCache.swift` | 后台维护"哪些 PID 有 menu extras"的 PID 集合 |
| `HintOverlay.swift` | 每屏一个无边框透明窗口，绘制 hint 标签 |
| `HUD.swift` | 右下角 mode 提示 |
| `KeyCode.swift` | `kVK_ANSI_*` 物理键码常量（ANSI 布局，非 QWERTY 会出错） |
| `KeyPoster.swift` | 合成键盘事件的辅助函数（当前主路径未使用；留给未来 select-text mode） |
| `AXWait.swift` | 把 NSWorkspace / AX observer 通知桥接成 `async/await`，带超时兜底。`x` 路径用它替代固定 sleep |
| `TriggerRemap.swift` | App 启动时 shell-out `/usr/bin/hidutil` 把物理 Caps Lock → F19；退出时还原 |
| `setup-trigger.sh` | 高级用户用。`--persist` 模式装 LaunchAgent，让 F19 映射独立于 Mouseless 生命周期 |

---

## 5. 文档地图

各 subsystem 的细节、设计权衡、踩坑记录在 `specs/` 下：

| 文档 | 内容 |
| --- | --- |
| [`specs/event-pipeline.md`](specs/event-pipeline.md) | HotkeyTap 注册、callback 三层 short-circuit、反馈环 `"MOUS"` 标记、修饰键透传策略（Cmd/Ctrl 放行，Shift/Option 消费） |
| [`specs/modes.md`](specs/modes.md) | Mode 状态机、palette 正交性、sticky、状态转移图、**所有键位表**、KeyCode 常量、新 mode 接入路径 |
| [`specs/hint-discovery.md`](specs/hint-discovery.md) | AX 三源（focused / Dock / menu extras）、`walk()` 收录条件、屏幕并集计算、**menu extras 踩坑史 + `MenuExtraCache` 设计**、并发安全 |
| [`specs/hint-rendering.md`](specs/hint-rendering.md) | 标签生成、typing → commit、AX action vs 合成点击、`HintOverlay` 多屏窗口、坐标系转换、**三种 badge 排版**（Dock / `AXMenuItem` 级联 / 通用）、HUD |
| [`specs/omniparser-fallback-design.md`](specs/omniparser-fallback-design.md) | **设计草稿，未实现**：视觉 ML 路径作为 AX 兜底（fall-through，不并行）；PoC 数据；captioner 为何搁置；过滤设计的 baseline vs exploratory；集成的开放问题 |
| [`specs/omniparser-integration-roadmap.md`](specs/omniparser-integration-roadmap.md) | **实施路线图**：把上面设计落到代码上的 9 个分阶段计划（P0 决策 → P8 发布），含估时、风险、降级路径、out-of-scope 边界、验收清单 |

---

## 6. 关键设计权衡（speed-read）

| 权衡 | 选择 | 理由 |
| --- | --- | --- |
| 单元素 AX 属性获取 | `AXUIElementCopyMultipleAttributeValues` 一次拿 10 个属性 | per-element IPC 从 9+ 砍到 1，焦点 app 扫描从 ~840ms 降到 ~200ms |
| Sticky rescan 复用 | per-`AXWindow` cache + `AXWindows` diff + commit-driven dirty | 关弹框这种"只销毁一窗、其他没动"的常见操作不重扫 |
| Menu bar fast path | AXMenuBar 上读一次 `AXSelectedChildren`；空则不下钻 | 99% 时刻菜单栏没展开，跳过 N×4 个 axMenuIsOpen 探针 |
| Menu extras 发现 | 后台 PID cache + NSWorkspace 增量 | 触发期 < 30ms；预热成本对用户透明 |
| 点击实现 | AX 动作优先，合成事件回退 | AX 不依赖鼠标位置和遮挡 |
| Overlay 数量 | 每屏一个窗口 | 单窗口跨屏 macOS 渲染不可靠 |
| Overlay 层级 | `.statusBar` (25) | 高于菜单栏，低于下拉菜单（保持自然 z-order） |
| 退出"空白处"（`x`） | 激活 Finder + AX-cancel Dock 菜单 | Finder 激活关掉 app 菜单/popover/status menu；`AXUIElementPerformAction(menu, kAXCancelAction)` 是唯一能让 Dock 真正销毁 AXMenu 元素的方式（合成 Esc 只让菜单视觉关，留下 ghost 让 re-scan 画悬空 hint） |
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
2. **Electron / 复杂 web 内容** —— `walk()` 对 web view 的 AX 树兼容性还没系统测过。
   这是 vs Homerow 的 wedge，必须做对。Chromium 的 NSAccessibility 桥规则统一，但
   暴露什么完全取决于 app 的 ARIA/HTML 卫生：好的（VS Code、Slack、Discord）AXButton +
   AXPress 一应俱全，差的（WeChat、各类国产 SaaS）一片 AXGroup 无 action 无 title。
   长远方向是引入 **OmniParser 视觉路径** 作为 AX 的 **fall-through 兜底**——AX 主，
   AX 不够时才启动视觉路径，不并行。PoC 已跑通：3K 全屏 detection p50 ~140ms
   （spec §5 上限是 300ms），WeChat / Wrike 召回明显高于 AX。详见
   [`specs/omniparser-fallback-design.md`](specs/omniparser-fallback-design.md)。
3. **App AX cleanup 期的扫描尖峰** —— 关弹框 / 关 sheet 后 sticky rescan 落进目标 app
   的 ~500ms cleanup 窗口里，per-IPC 延迟从 ~0.2ms 涨到 ~40ms。IPC 数已经压到下限
   13（cache + walkMenuBar 双管），优化空间在这条路径上耗尽。事件驱动等 AX 稳定再
   扫的方案没尝试过——通知发出时机不可控，理论 wall-clock 时间可能不降。
   **跟 OmniParser fallback 是独立问题**——后者只解决 AX 黑洞场景；cleanup 尖峰下
   AX 仍然能返回候选数（只是慢），fall-through 不会触发视觉路径。详见
   `specs/hint-discovery.md` §5 + [`specs/omniparser-fallback-design.md`](specs/omniparser-fallback-design.md) §4.5。
4. **新 modes** —— `Mode` enum 已经留好扩展点：select-text、drag、right-click 命令模式。接入路径见 `specs/modes.md` §8。
5. **多 hint 来源的标签空间冲突** —— 焦点 app 元素很多时会吃光字母组，menu extras 排到 `lj/lk/ll`。
   方案候选：menu extras 走单独的前缀（如 `;a`, `;s` …）或单独字母池。
6. **Dock 分隔符 / Recents 占位过滤** —— 当前 Dock 把所有 `AXDockItem` 都收，包括分隔符。低价值的 hint 浪费标签。
