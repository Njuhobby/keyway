# Modes & Key Bindings

Mode 状态机、命令面板、所有键位的完整定义。

相关文件：`VimSession.swift`, `KeyCode.swift`。

---

## 1. 概念模型

```swift
enum Mode {
    case tap(HintMode)            // hint 点击 + hjkl 移光标 + bare c 点击 + (子状态：drag / search)
    case scroll(ScrollController) // 键盘滚动（多区域 picker）
    case window(WindowController)     // 整窗口 resize
    case windowMove(WindowMoveController)  // 整窗口平移
    // TAP 内还有子状态：TapSub.normal / .dragging / .searchTyping / .searchSearching / .searchPicking
}

var paletteBuffer: String? = nil   // nil = 面板关闭
var sticky: Bool = false           // TAP mode 内有效
```

- **Mode** 描述 "用户当前在干什么"。当前两个：`.tap`（hint 点击，也含 hjkl 移光标 + bare `c` 点击）、`.scroll`（键盘滚动）。移光标键 **hjkl 在两个模式统一**（消除模式间认知切换）。点击键 **bare `c` 在 TAP/SCROLL 统一**——避免 Enter 在 app 里有自己的语义（菜单确认、表单提交）被吃掉。
- **paletteBuffer** 是命令面板的输入缓冲。打开面板**不会**改变底层 mode；关闭面板回到原 mode 继续。
- **sticky** 只在 TAP mode 里使用，表示点击后是否保持 mode（连续点多个目标）。

触发键 **Caps Lock**（hidutil 重映射成 F19）统一走 **arm 机制**：按下不立即动作，等松手或等 chord（见 §2.1）。这让一个键承担多职：单击进 TAP / 切 sticky / SCROLL→TAP，按住+jk 进 SCROLL。

---

## 2. 状态转移图

```
                      ┌──────── Caps Lock 松手(无 chord) ────────┐
                      │                                          ▼
[OFF] ──Caps Lock 松手(无 chord)──> [TAP] ──Caps Lock 松手──> [TAP sticky]
   │                                  │  ▲                        │
   │                                  │  └── Caps Lock 松手 ───────┘ (toggle)
   │                                  │
   └─ Caps Lock 按住 + d ───┐        ├─ hint 字母      → 点击（commit）
                            │        ├─ h/j/k/l        → 移光标（vim hjkl，Shift 加速）
   [TAP] Caps Lock按住+d ───┤        ├─ bare `c`       → 光标位置左键单击（Enter 放行给 app）
                            ▼        ├─ Shift+; (:)    → 命令面板
                        [SCROLL] ◄───┘ Caps Lock按住+d
                            │
                            ├─ d / u        → 下/上滚（按住连续，Shift 加速）
                            ├─ h/j/k/l      → 移光标（同 TAP，Shift 快/Option 慢）
                             ├─ 数字键        → 切换滚动区域
                             ├─ Caps Lock 松手 → 切回 TAP
                             └─ Esc          → OFF

任意 mode：Esc → deactivate 回 OFF
```

### Caps Lock 的统一语义（arm）

Caps Lock(F19) 在**任何 mode** 都先 **arm**（按下不动作），松手时分情况：

- **按住期间按了 j/k**（chord）→ 进 SCROLL（从任何 mode）
- **没按 chord，直接松手** → 执行当前 mode 的默认：OFF→进 TAP，TAP→切 sticky，SCROLL→切回 TAP，palette 开→关 palette

所以**连续按两下 Caps Lock = 进 TAP + 切 sticky = 直接到 TAP sticky**。代价：所有 Caps Lock 单击动作在**松手**时才生效（~50ms，感知不到）。详见 §2.1。

**Esc 永远 deactivate**——回到 OFF（hint 隐藏、sticky 清零、palette 关、scroll 退出），但 **进程不退**（Mouseless 仍在 menu bar，Caps Lock 仍是 F19）。要真退出进程走菜单栏 Quit（见 §3.1）。

只想关面板回 TAP 而不 deactivate：空 buffer 上按 Backspace，或按 Caps Lock。

### 2.1 arm 机制（chord vs tap 消歧）

一个键要兼"单击"和"按住+组合"，按下瞬间无法区分（chord 的第二键还没来），所以按下时**先不动作，记一个 armed 标记**，等下一步：

```
Caps Lock 按下 → f19Armed = true（待命，先不动）
   ├─ 期间按 j/k    → chord：enterScroll()，标记 chordUsed
   └─ Caps Lock 松手 → 若没 chordUsed → handleTriggerTap()（按 mode 分派默认动作）
```

实现见 `HotkeyTap.swift`（arm 状态机）+ `VimSession.handleTriggerTap()`。arm 覆盖所有 mode，不只 OFF——这是"TAP 内也能 Caps Lock+d 进 SCROLL"和"连续 Caps Lock 进 sticky"两个行为的根。

---

## 3. 进入 / 退出

触发键是 **Caps Lock**（物理键，hidutil 重映射成 F19 后 CGEventTap 接到的是 F19 keyDown，见 `event-pipeline.md` §3）。

### 3.1 三个层级，别混淆

Mouseless 的状态有**三层**，"退出"在哪一层语义不一样：

| 层级 | menu bar 图标 | hidutil remap | 怎么进入 | 怎么离开 |
| --- | --- | --- | --- | --- |
| **进程未运行** | 无 | 已还原 | 还未启动 / 用户菜单栏 Quit | 启动 Mouseless |
| **进程运行 · OFF** | `M●` | 生效 | 启动 / Esc 退出 mode | Caps Lock 进 TAP / Caps Lock+d 进 SCROLL / 菜单栏 Quit |
| **进程运行 · TAP/SCROLL** | `M●` + overlay | 生效 | 见 §2 | Esc / 菜单栏 Quit |

**Esc 只在层级内"deactivate"——回 OFF，不退进程**。Caps Lock 还是 F19，你再按一下立刻又能进 TAP。要真退出进程（让 Caps Lock 还原成普通 toggle），走菜单栏 Quit 或 Cmd+Q——那条路径触发 `applicationWillTerminate` → `TriggerRemap.revertAtQuit()`。

### 3.2 Caps Lock 在各状态的行为（统一 arm）

| 操作 | OFF | TAP | TAP sticky | SCROLL | WINDOW | MOVE | palette 开 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Caps Lock 单击（松手无 chord） | 进 TAP | 切 sticky / 退子状态* | 切回非 sticky / 退子状态* | 切回 TAP | 切回 TAP | 切回 TAP | 关 palette |
| Caps Lock + d | 进 SCROLL | 进 SCROLL | 进 SCROLL | （重进 SCROLL）| 进 SCROLL | 进 SCROLL | — |
| Caps Lock + w | 进 WINDOW | 进 WINDOW | 进 WINDOW | 进 WINDOW | （已在 WINDOW，no-op）| 进 WINDOW | — |
| Caps Lock + m | 进 MOVE | 进 MOVE | 进 MOVE | 进 MOVE | 进 MOVE | （已在 MOVE，no-op）| — |
| `Esc` | — | deactivate / 退子状态* | deactivate / 退子状态* | deactivate | deactivate | deactivate | deactivate |
| 菜单栏 Quit / Cmd+Q | quit 进程 | quit 进程 | quit 进程 | quit 进程 | quit 进程 | quit 进程 | quit 进程 |

\* DRAG 与 `/`-搜索是 TAP 的**子状态**而非独立 mode（见 §6 / §6.5）。在 TAP 子状态里按 Caps Lock 单击会先**清理子状态**（drag → drop at cursor；search → 关 search overlay 恢复 hints）再回 TAP normal；Esc 在 search 子状态里是"取消搜索回 TAP normal"，在 dragging 子状态里是"drop at cursor 后 deactivate 回 OFF"，在 TAP normal 里才是直接 deactivate。

Caps Lock + Shift/Cmd/Ctrl/Option（修饰键）→ 不 arm，放行给系统/用户。

**Caps Lock 永远响应**：WINDOW / MOVE 不"吞" Caps Lock。`teardownCurrentMode()` 在切之前清干净——WINDOW/MOVE 停 timer + 关 overlay。TAP 内部按 Caps Lock 由子状态自己处理（dragging 释放 mouseDown、search 关 search overlay），整体逻辑跟 mode 切换一致。

`VimSession.enter()`：**同步**设 `mode = .tap(h)`（消除连按 race，见 §2.1），再异步 `h.activate()` 扫描 + 显示 overlay。三个来源都空时显示 "no hints here" 并退出。

---

## 4. TAP mode 键位

| 键 | 行为 |
| --- | --- |
| `a s d f g e r u i o p w t n m` | 输入 hint 标签字母（15 个；**注意不含 h/j/k/l/v/c**） |
| `0–9` | 输入 hint 标签数字（Dock 专用） |
| `Shift + 末位字符` | **右键** |
| Shift **双击按住** + 末位字符 | **双击**（Shift 按-松-按住,150ms 内,第二下按住敲 label —— 同 WINDOW 双击手势,详见 §4.3.6）|
| `'` (撇号) 后再敲 label | **只移动不点击**——光标 warp 到目标,**不点击**(把 hints 当光标传送锚点)。详见 §4.3.5 |
| `h / j / k / l` (bare) | **移光标** 左/下/上/右（vim hjkl，按住连续，normal 速度） |
| `Shift + hjkl` | 加速移光标 |
| `Option + hjkl` | 精细移光标（慢速，精确落到小 icon） |
| `c` (bare) | 当前光标位置 **左键单击**（配 hjkl：移到位 → `c` 点击） |
| `Shift + c` | 当前光标位置 **右键** |
| Shift 双击按住 + `c` | 当前光标位置 **双击** |
| `Enter` | **放行**给焦点 app（菜单确认、表单提交等都不被 Mouseless 吃掉） |
| `v` (bare) | **进入 DRAG 子状态**——立刻在光标位置 `mouseDown`，hjkl 拖、Enter drop、Backspace 取消（见 §6） |
| `/` (bare) | **进入 `/`-搜索子状态**——OCR 焦点窗口、字符级匹配，复用 hint label 池标记结果（见 §6.5） |
| `Backspace` | TAP normal：撤销上一个输入的 hint 字符（typed 空时无操作）；子状态里有自己的语义 |
| `Shift + ;` (= `:`) | 打开命令面板 |
| `↑↓←→` / `Cmd / Ctrl + 任意键` | **放行**，不消费（保系统快捷键 + app 原生导航） |

为什么 hint 池没有 h/j/k/l/v/c/o/p：h/j/k/l 是 hjkl 移光标键、v 是 bare-key 进 DRAG 子状态、c 是 bare-key 点击键，裸按它们都有专门含义、不能再当 hint 字母（否则歧义）；`o`/`p` 因右小拇指外伸手感差被剔除。除这八个外其它顺手字母都可用，`HintMode.alphabet` 取 **13 个**：`a s d f g e r u i w t n m`。13² = 169 = `maxTargets`(169)，所以**任何一次扫描都不会出现 3 字母 label**（2 字母封顶）。顺序按手感前置（左手 home row 在前，单字母 label 用 `prefix` 取前缀、最短 label 最快 commit）。详见 §4.3 与 `hint-rendering.md`。

为什么不用 Ctrl 做移动：power user（如 HHKB）常在系统层把 Ctrl+hjkl 映射成方向键，跟我们冲突。裸 hjkl 完全避开 Ctrl。

### 4.1 标签输入

每次按键：
1. `next = typed + char`
2. 过滤 `targets` 中 `label.hasPrefix(next)` 的：
   - 0 个匹配 → `.ignored`，**吞掉、不退出**（误按；typed 保持上一个有效值，Esc 才退出）
   - 1 个且完整匹配 → 普通 = `.committed`（commit 点击后视 sticky 决定下一步）；move-armed = `.moved`（warp 光标、不点击、留在 TAP，见 §4.3.5）
   - 多个 → `.pending`，刷新 overlay 展示剩余候选

提交点击的实现详见 `hint-rendering.md` 的 commit 部分。

### 4.2 Sticky 与切 app / 同 app 内容变化的跟随

- 进入 TAP 时 `sticky = false`。
- Caps Lock 单击（松手无 chord）切换 sticky —— 走 §2.1 的 arm 机制 + `handleTriggerTap()`，不在 `handleTap` 里。
- TAP 内 hint `.committed` 时如果 sticky：`deactivate()` 当前 HintMode → 构造新的 `HintMode()` → `activate()`，整套 hint 重新扫描（焦点 app 可能已经因为点击而变了）。Non-sticky `.committed` 直接 `exit()` 回 OFF。

**问题：画面变化（点击导致 或 切 app）让 overlay / mode 状态失效。** overlay 是按某个 app 的布局画的（`.statusBar` 级、跨所有 space、`orderFrontRegardless`，**不跟随焦点**）；mode controller（WindowController / ScrollController）持有的是原 app 的 AX 引用。两件事会让它失效：

1. **切 app**（Cmd+Tab，或点击打开别的 app）—— overlay 还停在旧 app 的坐标上盖着新 app；controller 的 AX 引用还指向旧 app 的窗口。**所有 active mode 都会遇到这个问题**，不止 sticky TAP。
2. **同 app 内容变化**（列表选中 → 详情面板重载、展开 disclosure、原地导航、弹 popover、开新窗口）—— 合成 click 是异步的，`rehintSticky()` 立即跑时 walk 的是**点击前**的树，重扫出来还是旧画面（用户实测踩到）。**仅 sticky TAP 这条路径需要这个机制**（其它 mode 没有"commit 后继续操作"的概念）。

靠**两套机制**覆盖。**关键区别是焦点窗口变没变**：

**机制 1 — 焦点窗口变了（切 app **或者** 同 app 内换窗）：旧 overlay 立即隐藏 + 100ms 后在新 frontmost 上重新 apply 当前模式 + 截图只含新 app。** 整个 active session（TAP / SCROLL / WINDOW / MOVE 都算）挂信号，前三条汇到 `reapplyOnCurrentFrontmost`：

| 信号 | 触发场景 | 延迟 / 处理 |
|---|---|---|
| `NSWorkspace.didActivateApplication` | Cmd+Tab 切 app / 单击别的 app | ~0ms → reapply |
| `NSWorkspace.activeSpaceDidChange` | 跨 Space 滑动（Ctrl+方向键 / 三指滑），或 cross-Space 切 app 完成动画 | ~0ms → reapply |
| 150ms `focusedWindowPollTimer` | **同 app 内** focused window 变了：Cmd+W 关窗 / Cmd+M 最小化 / Cmd+\` 切窗 / Cmd+N 开新窗 | 最坏 150ms → reapply |
| `NSWorkspace.didTerminateApplication` | 任意 app 退出（**右键 Dock 图标 → Quit 一个后台 app** 的场景：frontmost 没变，前三条都不 fire，但 Dock 图标没了 → overlay 的 Dock hint 过时）| 见下方"Dock-change-only 刷新" |

前三条 + 一个 handler 的扇入设计。handler 不关心是谁叫的，它就一件事：**读当前 frontmost app / window，在那个状态上重画**。同一逻辑事件可能多条线一起 fire（例：cross-Space Cmd+Tab 时 didActivateApplication 立刻发，300ms 后 activeSpaceDidChange 又发，poll 在中间也可能看到 window 变化）——`reapplyOnCurrentFrontmost` 每次进来都 `cancel` 上次 pending 的 reapply DispatchWorkItem 再重新 schedule，**setup 跑 N 次但实际 re-enter 只跑 1 次**（最后那次胜出）。同时进来时刷一下 poll 缓存的 `lastSeenFocusedWindow`，让晚到的信号看不到变化、不再触发。

> **为什么 poll 而不用 AX observer**。`kAXFocusedWindowChangedNotification` 是更"对口"的事件——AXObserver 注册到 frontmost app 的 PID 上、~0ms 延迟。试过，砍了。理由：AX notification 的 emission 是 **app 自己的责任**，非原生框架（WeChat、Electron、Qt 类）普遍不发——观察者在那些 app 上跟空气一样。poll 是"我自己去读"，跟 app 是否合规无关，**普适**。代价是 ~7 IPC/sec（150ms 一次 `AXUIElementCopyAttributeValue`，比 60fps 的 WindowController tick 便宜 8 倍）+ 最坏 150ms 延迟，可接受。AX observer 的 ~80 行 `@convention(c)` callback + Unmanaged refcon + AXObserver/runloop source 管理也一并省掉。

> **Dock-change-only 刷新（didTerminate 走单独的轻路径，不进 reapply）**。app 退出每天发生无数次——dockless 后台 agent（更新器、helper）退出跟屏幕上画的东西毫无关系，**不该重扫也不该闪**。所以 `handleAppTerminated` 不调 reapply，而是：① gate 只在 TAP（只有 TAP 有 Dock hint 会过时）；② debounce 排一个 `pendingDockCheck` @ +500ms（Dock 移除图标是 ~几百 ms 的动画，立刻比会假阴性；连续退出也合并成一次）；③ `checkDockChangedAndRefresh` 比 **当前显示的 Dock hint rects**（`HintMode.currentDockRects`，即 numeric-label 的 targets）vs **现在 walk 一遍 Dock 的 rects**（`HintMode.collectDockRects()`，~5ms）——本质是"显示的 Dock vs 实际的 Dock 还一致吗"。签名（rect 取整排序）不同才 `refreshInPlace`（原地换 targets，**零闪**），相同直接忽略。退 dockless agent → Dock 集合不变 → 忽略；退有 Dock 图标的 app（含"运行中临时有图标"的）→ 图标移除 reflow → 集合变 → 刷一次。**Dock 自己变没变就是答案**，不用判断 app 算前台/后台/dockless，也不依赖 `AXDockItem → app` 映射（那个 AX 属性各版本不一定稳）。gate 还含 `tapSub == .normal` + `typed` 空（不在用户敲 label 中途 reshuffle）。`pendingDockCheck` 在 `exit()` 取消。代价：无关退出也白 walk 一次 Dock（~5ms，无感），换"判断绝对可靠"。

observer 的生命周期跟"用户在 active 状态"绑定：每个 `enterX()` 都注册（idempotent），`exit()` 注销；mode 之间互切（如 TAP ↔ SCROLL）**不**注销——`teardownCurrentMode` 不动 observer。任一信号触发 → 立即藏旧 overlay + 取消 pending operations + 100ms（同 Space）或 500ms（跨 Space，见下）后 dispatch `reapplyOnCurrentFrontmost` 按 `currentModeKind` 重 enter：

- `.tap` → `rehintSticky(isolateApp: true)`（**sticky 和 non-sticky 都重扫**——两者差别只在 commit 后是否 stay，重扫这一步对两者都正确）
- `.scroll` → `enterScroll()`（重检测新 app 的 scroll areas、warp、画 overlay）
- `.window` / `.windowMove` → `enterWindowMode()` / `enterWindowMove()`（重过 gate；不过则 HUD + 退 OFF）

> 早期版本只有 sticky TAP 有这个跟随、其它 mode 切 app 都是 overlay 残留 + 操作仍指向原 app（broken）。统一改成"任何 active mode + 切 app = 在新 app 重 apply"后，UX 跟用户直觉对齐：切 app = "我现在想在这个 app 上继续做刚才的事"。

> **为什么要等 100ms**：早期版本是收到通知**立即**重扫，因为想当然以为"通知发了 = 新 app 已经 frontmost = 没什么可等的"。实测有一定概率拿到空结果——`didActivateApplication` 在 OS *标记* app 激活时就发，但 AX 树还没填好 / ScreenCaptureKit 还在抓半截画的帧的窗口期里，扫描会返回 0 个 target，进而触发 `rehintSticky` 的 `else { exit() }` 把整个 session 静默杀掉，用户看到的是"切完 app 后 Mouseless 像没了一样"。机制 2 已经在用 100ms 等 click 落地+渲染稳定；切 app 这条路同样的延迟来等 AX 树+像素就位，正好对称。`isolateApp: true` 仍然保留（截图排除 Dock 进程，过滤 Cmd+Tab 切换器 HUD）。

> **跨 Space 切 app 时的额外延迟**：用户 Cmd+Tab 到**另一个 Space** 的 app 时，macOS 跑一段 250-400ms 的滑动动画——固定 100ms 延迟下扫描刚好落在动画中间，截到一片黑的过渡画面（实测踩过）。macOS **没有 public API** 告诉我们"当前正在切换 Space"或"即将切换 Space"——只有 `activeSpaceDidChangeNotification`，在动画**完成后**才 fire（"Did" 是 past tense）。所以采用启发式：`didActivateApplication` 触发时用 `CGWindowListCopyWindowInfo(.optionOnScreenOnly, ...)` 查激活的 app 有没有 window 在当前 Space 上可见——如果**没有**（跨 Space 切换 / 全部 minimized / 全部 hidden 三种情况都表现为这个），延迟从 100ms 拉到 **500ms**；同时订阅 `activeSpaceDidChangeNotification`，如果 500ms 之内 fire 了（说明是跨 Space 切换、动画刚结束），取消 pending 500ms 重新调 100ms（这时 window 已在当前 Space 可见）。500ms 内没有 Space change 就说明 app 真的没可见 window，原 500ms 触发 + HUD `TAP/SCROLL/WINDOW/MOVE: no frontmost window`。代价：跨 Space + 无可见窗 case 多 400ms，但视觉上没有错位 hint 闪过。

> **`activeSpaceDidChange` 也直接订阅了**，用作两类信号：(1) 上面说的 cross-Space 加速；(2) 用户主动切 Space（Ctrl+方向键 / 三指滑），没有 app activation 但焦点 app 切了，也要在新 Space 重 apply。两类都走 `handleSpaceChanged` → `reapplyOnCurrentFrontmost`，pending 取消+重新调度的机制天然 dedup。

> **`isolateApp` —— 截图时把 Dock 进程整个排除。** 普通截图是"整屏合成画面再 crop"，所以 **Cmd+Tab 切换器 HUD**（它是 **Dock** 的窗口）会被截进来，OP 把上面一排 app 图标全识别成 hint（用户实测：切过去画出来的是切换器图标，不是新 app 的 UI）。切换器要几百 ms 才淡出，而通知是切换**一发生**就来——靠"等延迟"既不精确又分不清 Cmd+Tab（有 HUD）和单击（无 HUD）。改成 `SCContentFilter(display:excludingApplications:[dockApp])` **排除 Dock 这个进程**：HUD 是 Dock 拥有的，被排除掉了；Dock 自己也一起排除（无所谓，OP 路径本来就不 hint Dock，那块靠 AX walk）。和它在不在、何时消失无关——时序问题直接消失。代价：要 fresh 查一次 `SCShareableContent`（apps 列表没缓存）+ 重新合成，约多几十 ms，只在切 app 这条不频繁的路上付。AX 白名单 app 不受影响——它走 AX walk 读目标 app 的 AX 树，HUD 是 Dock 窗口、不在树里。
>
> **为什么不用 `including:[focusedApp]`（更紧的隔离）？** 试过，但 `including:` 这条 filter 的 **canvas 锚定语义** Apple 没写清楚——它生成那张图的 (0,0) 锚在 display 全局坐标的哪个点不明确，实测 crop 出右半边一大片黑（说明锚定不是我假设的样子）。要把它做对得拿 log 实测多种模型反推真实语义。`excludingApplications:[dock]` 是 **display-based filter**（canvas 就是 display，原点等于 `display.frame.origin`，文档明确），crop 数学直接对。代价是不排除别的 app 浮窗 / 通知横幅——如果以后实测出问题再去摸 `including:` 的锚定行为不迟，当前 bug（Cmd+Tab HUD）只来自 Dock，exclude-Dock 是最小够用的精确解。

**机制 2 — 同 app 内容变化（焦点窗口没变）：commit 后延后 ~100ms 重扫。** commit（hint 点击 / Enter）后等 ~100ms 再 `rehintSticky()`（普通整屏截图，无 HUD 问题）。合成 click 是异步的，立即重扫 walk/截的是**点击前**那帧（stale）；等 100ms 让点击生效 + 内容 re-render 稳定。100ms 对任何正常 app 都够（re-render 100ms 还没完那 app 也太慢了），又短到感觉即时。延后期间再 commit 会取消上一个 pending（最新胜出），切 app / 退出也取消。**代价**：点击后 >100ms 才落定的更新（远程加载、多阶段布局）会重扫到 stale，需重新触发刷新——赌这种罕见。

> **历史踩坑。** 早期想用 AX notification watcher 兜同 app 异步变化，撞两个问题：① 即使 AX app，立即重扫也会和 click 抢跑；② "走 OP 路由" ≠ "不发 AX 通知"——WeChat 原生 AppKit 会发 `kAXValueChanged`，只是聊天内容自绘、AX walk 不到才走 OP。给它挂 watcher → 通知重扫 + 100ms 延后重扫**双重 re-hint**（WeChat 实测）。所以同 app 路只留单一延后重扫。也没用截图轮询：一次截图 ~50ms ≈ 一次 OP 推理，轮询比多重扫 2~3 次还贵。

### 4.3 光标自动跳转规则（cursor auto-park）

**触发**：进 TAP / sticky 跟随触发的 reapply / app-switch follow / focused-window-change 都会进 `parkCursorOnFrontmostWindowIfOutside`。

**三段决策**：

```
Step 1: 读 frontmost app 的 focused window rect
        - 没 frontmost app / 没可见窗口 → 整个 park 跳过, HUD "no frontmost window"

Step 2: cursor 已经在那个 window 内部?
        - 在: 啥都不动（尊重用户主动放过的位置）
        - 不在: 进 Step 3 决定落点

Step 3: 选 input rect, 失败回 title bar
        ┌─ frontmost 是浏览器 (Chrome/Safari/Brave/Arc/Edge)?
        │   是 → BrowserProvider.findFirstInputRect (DOM)
        │        - 扩展 detector.js 查:
        │          1. document.activeElement (用户上次点过的)
        │          2. 第一个可见 input/textarea/contenteditable
        │        - 浏览器没装扩展 / 没连 / chrome:// 类页 → null
        │   否 → AXFocusedUIElement (native AX)
        │        - role 白名单: AXTextField/AXTextArea/AXSearchField/AXComboBox
        │        - 或 AXValue 可写（兜 Electron 类返回非标 role 但确实可编辑的元素）
        │        - 还要 rect 跟 window 相交 + 至少 4×4
        │
        └─ 拿到 rect → warp 到 rect 中心 (MouseSynth.warp, .mouseMoved 合成事件)
           拿到 null → 兜底 title bar 中点 (rect.midX, rect.minY + 6pt)
```

**各 app 类型实际表现**：

| App 类型 | 上次焦点 | 落点 |
|---|---|---|
| 浏览器（装扩展） | 焦点在某 input | `document.activeElement` 中心 |
| 浏览器 | 没点过任何 input | 页面第一个可见 input 中心 |
| 浏览器 | 页面无 input / chrome:// | title bar 中点 |
| AX 友好 native（Mail / Notes / WeChat / TextEdit）| 焦点在 text input | 那个 input 中心 |
| AX 友好 native | 焦点在 button / link / list item | title bar（role 不在白名单，安全） |
| Electron / AX 弱（Slack / Discord / VS Code）| — | title bar 中点（`AXFocusedUIElement` 返回 `kAXErrorNoValue`） |
| Finder Desktop（无窗口）| — | park 整个跳过 |

**设计原则**：

1. **不动 cursor 已经在的 window** —— Step 2 短路保留用户主动位置（如鼠标已经在 sticky TAP 期间用 hjkl 移到了某处）
2. **只跳 text 类输入** —— 不跳 button / link / menu item，避免 Cmd+Tab 后误触意外动作
3. **AX 不暴露的不强求** —— Electron 类直接接受 title bar fallback，不做 AX 子树深度 walk（之前尝试过 walker fallback + role 普查诊断，复杂度收益不成正比，回退）。将来 per-app patch 路线启动后可单独给 Slack 写"compose 在窗口底部 80pt"硬编码规则
4. **可观察** —— 每条分支都打 `[mouseless] focusedInput: ...` 日志（match via role / via editable-value / read failed / rect too small / rect outside window / skipped role=...），定位某 app 没生效时一行就能看到哪一道闸拦的
5. **`.mouseMoved` 而非 `CGWarp`** —— 跟 §6.5 search commit 同理，让目标 view 收到事件、更新 cursor shape (I-beam) + hover state

### 4.3.5 `'` 前缀 —— hint 当光标传送锚点（move-only pick）

把 hint 从"点击目标"升维成"光标快速跳转点"。流程:

```
TAP 里按 '       → 武装 move-only（label 变浅黄、HUD 显 "TAP · move"）
  再敲 label      → 光标 warp 到目标中心，**不点击**
  pick 完          → 自动复位（disarm），hints 留在屏幕上、留在 TAP/sticky
再按 '（pick 前）→ 取消武装
```

**为什么这个触发器**（设计取舍）:

- **不用修饰键**:Cmd/Ctrl 会跟系统快捷键冲突;Shift/Option 已被双击/右键占用
- **不开新 mode**:对"这一下只移动"这种即时意图太重
- **一次性前缀 `'`** 两者都不是 —— 只是个 bool flag,pick 完或退出自动清。vim mark 的"跳到"语义;`'` 不在 hint 池,不会跟 label 冲突

**关键行为:move pick 不终结会话**。click pick 是终结动作(non-sticky commit 后 exit);move pick 是**导航**动作,移完应该接着干活。所以:

- 光标 warp 后,**留在 TAP**(不管 sticky 不 sticky) —— `HintResult.moved` 而非 `.committed`
- 移完内容没变,hints 位置不变 → **不重扫**,同一批 targets 瞬间重显示(零延迟、无闪烁)
- 复位回正常黄,用户可以接着:再 `'`+label 移到别处 / 直接敲 label 点击 / hjkl 微调 / `c` 点击 / `v` 拖拽

**实现**:`HintMode.moveArmed` 一次性 flag,`toggleMoveArmed()` 由 `'` 触发;`handle()` 命中唯一 label 时 armed 则走 `commit(action: .move)` → `MouseSynth.warp`(`.mouseMoved` 合成,更新 cursor shape/hover) 而非 click,然后保留 targets + 清 typed + disarm + 重渲染,返回 `.moved`。overlay 的 `moveArmed` 参数决定浅黄(`1.0, 0.95, 0.70`) vs 正常黄(`1.0, 0.84, 0.0`)。

配合 §4.3 的 hjkl 微调 + 双击跳屏,导航闭环:`'`+label 粗定位 → hjkl/双击精调 → `c`/`v` 操作。

### 4.3.6 点击修饰键:Shift=右键、Shift 双击=双击

commit(hint pick 或 bare `c`)的点击类型由修饰键决定:

| 输入 | 动作 |
|---|---|
| 裸 | 左键 |
| Shift 按住 + label | 右键 |
| Shift **按-松-按住**(150ms 内,第二下保持按住敲 label)| 双击 |
| Option | **不再映射任何点击**(已废) |

**为什么从"Shift=双击/Option=右键"改过来**:实测 Option 够不顺手、且用户潜意识把 Shift 读成"另一种点击"= 右键。改成 Shift=右键后,双击让给"Shift 双击手势"(跟 WINDOW resize 的 `hh/jj` 双击同一套肌肉记忆、同一个 `windowReverseTapWindow`=150ms 常量),Option 彻底空出来留作他用。

**状态机**(`handleShiftFlagsChanged`,由 HotkeyTap 的 flagsChanged 喂入,**从不消费** —— 修饰键必须透传给 app):

- `shiftDoubleArmed` 在"紧跟一次快速 TAP 的 Shift 按下"时置位。要求**第一下必须是裸 tap**(短按 + 期间没敲键,靠 `noteKeyWhileShiftHeld` 追踪)—— 这条专门排除"连续两次右键"的误判:右键的那次 Shift 按住里**含 label 键**,不算 tap → 第二次 Shift 不 arm → 仍是右键。
- armed 在 committing 那一击被消费(`.committed`/`.moved` 清掉;pending 的多字符 label 保留它给最终那击);Shift 释放、`exit()` 也清。

`clickAction(for:)` / `clickKind(for:)` 是读这个手势状态的实例方法,hint commit 和 bare `c`(TAP+SCROLL)共用。

### 4.4 bare `c` —— 光标位置点击 + hjkl 移光标

bare `c` 与 hjkl 配套，构成 TAP 内的"键盘鼠标"：**hjkl 移光标对准，`c` 点击**。

```swift
// bare c：当前光标位置左键单击一次
MouseSynth.click(at: MouseSynth.cursorPosition(), button: .left, count: 1)
// 点完按 sticky 分派：sticky → 重扫留 TAP；否则 → exit
```

- **`c`** = 在**当前鼠标光标位置**合成点击。修饰键选类型，跟 hint commit 一致：bare = 左键单击、`Shift+c` = 双击、`Option+c` = 右键（共用 `clickKind(from:)`）。落点 = 光标现在在哪。`c` 已从 hint 池移除（同 `v`），所以不会和 hint label 冲突。
- **`h/j/k/l`** = 移光标（vim hjkl：h 左、j 下、k 上、l 右），按住连续（60fps timer 合成 `.mouseMoved`，hover 状态会更新），Shift 加速 / Option 精细。实现见 `MouseMover.swift`。**TAP 与 SCROLL 共用同一套 hjkl**（`VimSession.moveDirection(for:)` 单一映射）。
- **双击 `hh` / `jj` / `kk` / `ll`**（150ms 内释放后再按，跟 WINDOW resize 用同一个 `windowReverseTapWindow`）= **光标一口气跳 1/4 当前屏幕**该方向距离。**Shift+双击 = 跳 1/2 屏**（远距离一发到位）。第二下按住不放 → OS key-repeat 让每次 repeat 都过双击窗口（每跳一次刷新 `lastTapHjklKeyUp` 时间戳），**连续跳**直到松手。多屏环境下取**光标当前所在那块屏**的尺寸作为基准，clamp 到那块屏边界（3pt 内缩）。
  - 用 `MouseSynth.warp`（synthesize `.mouseMoved`）而不是 raw `CGWarpMouseCursorPosition`——同 `/`-search commit 的理由，让目标 view 收到事件、更新 cursor shape / hover state
  - drag 子状态下**禁用**（每按一下都要延续 held drag，跳跃会让 drop target 不可预测）；search 子状态本来就吃掉 hjkl，自然不影响
  - Shift 决定 1/4 vs 1/2；Option / Cmd / Ctrl 不影响跳距（它们在别处有语义，叠加在 jump 上语义不清）
- 合成点击/移动统一走 `MouseSynth`（HintMode 的 hint-commit 点击也用它）。

**为什么不是 Enter**：早期版本用 `Enter` 当点击键，但 Enter 在 app 里**经常有自己的语义**——典型场景是按 ↑↓ 在菜单里 nav、然后 Enter 确认选中那一项。配上 §11 的箭头键放行后，用户预期 Enter 也能透传给 app。把"点击"挪到 `c` 上让两边都成立：Enter 永远放行、`c` 永远 click。

**历史**：`x` → `Enter` → `c`。`x` 最早是"dismiss 所有打开的菜单 + 重扫"手势（Dock 菜单 AXCancel + 焦点切换关浮层），改 `Enter` 是为了直觉（确认/点击）+ 跟 hjkl 配套形成"键盘鼠标"闭环；改 `c` 是为了把 Enter 放行给 app。`v` 也是同一节奏的产物：bare → chord → bare 子状态触发键。旧 `findOpenDockMenu` / `AXCancel` / `AXWait.appActivated` 那套已从代码移除，**关菜单能力丢失**（光标在控件上点会误触发），可接受。

---

## 5. SCROLL mode 键位

键盘滚动。完整设计见 [`scroll-mode-design.md`](scroll-mode-design.md)，这里是键位摘要。

| 键 | 行为 |
| --- | --- |
| `d` / `u` (bare) | 下/上滚 **垂直**（按住连续，60fps timer 合成 scroll wheel 事件 wheel1） |
| `b` / `f` (bare) | 左/右滚 **水平**（按住连续，合成 wheel2）。使用场景：Finder 列视图 / 宽表格 / Notion DB 表 / Figma 无限画布 / 日历周视图等 |
| `Shift + d/u/b/f` | 加速滚动（垂直或水平） |
| `gg` (连按两次 g) | 跳到选中区域**顶部**（vim 风格，仅垂直） |
| `G` (Shift+g) | 跳到选中区域**底部**（仅垂直） |
| `h/j/k/l` (bare) | 移光标 左/下/上/右（vim hjkl，**与 TAP 统一**，按住连续） |
| `Shift + hjkl` / `Option + hjkl` | 加速 / 精细移光标 |
| **双击** `hh` / `jj` / `kk` / `ll` | 跳跃 **1/4** 当前屏方向距离；**Shift+双击 = 1/2** 屏（跟 TAP §4.3 一样的双击-跳跃机制，共用 `maybeJumpOnDoubleTap` helper + `lastTapHjklKeyUp` 字典；150ms 内连按） |
| `c` (bare) | 当前光标位置左键单击（留在 SCROLL） |
| `Shift / Option + c` | 当前光标位置 双击 / 右键 |
| `Enter` | **放行**给焦点 app（与 TAP normal §4 统一） |
| `/` (bare) | **进入 `/`-搜索子状态**——OCR 焦点窗口、字符级匹配、复用 hint label 池标记结果；commit 后光标 warp 到匹配文本左边、回 SCROLL normal（scroll-area picker overlay 自动恢复）。跟 TAP 的 §6.5 search 共用一套机制 |
| `数字键 1-9` | 切换选中的滚动区域 |
| Caps Lock 单击 | 切回 TAP（见 §2.1） |
| `Esc` | search 子状态：取消回 SCROLL normal；normal：deactivate 回 OFF |

**移光标用 hjkl，与 TAP 完全统一**：早期 SCROLL 用 SDFE、TAP 用 IJKL，两套移动键逼用户在模式间切换肌肉记忆——是真实的认知负担。现统一成 vim hjkl（`VimSession.moveDirection(for:)` 单一映射，两模式共用），"移光标"在哪都一样，只有滚动/点击因模式而异。滚动因此从 `j/k` 改到 **`d`(下)/`u`(上)**——`j/k` 让给移光标，`d` 也正好对上进入 SCROLL 的 chord 键。`c` 与 hjkl 配套（移→点闭环），复用 `MouseMover` / `MouseSynth`（与 TAP 同一套）。

**水平滚动 `b`/`f`**：跟 `d`/`u` 左手 home row 同节奏（`b`=back/left、`f`=forward/right）。`ScrollController` 用一个 `Axis` enum 统一驱动 wheel1（垂直）或 wheel2（水平），单 timer 复用、切轴瞬时无停顿。约定 wheel1 / wheel2 都是"负值 = 向 forward 方向滚"（forward = 下 / 右）。`gg` / `G` 没扩展到水平（"行首/行末"在很多场景下不是常规需求，没值得加新 chord）。

**`/`-搜索在 SCROLL 也支持**：search 本质上是"精准光标传送"——SCROLL 既然支持 hjkl 相对移光标 + c 点击，再加上 `/` 绝对跳转就构成"滚到大致位置 → search 精确定位 → c 点击"的完整闭环，全程不出 SCROLL。机制跟 TAP 的 §6.5 完全一样，差别只在 host overlay：进 search 时藏 scroll-area picker，commit 后光标 warp 完恢复 picker（不像 TAP 那样 sticky-rehint，因为 SCROLL 没有 hint 概念）。底层 OCR / label 生成 / SearchOverlay 完全复用，宿主无关的实现见 `setSearchPhase` / `searchPhase` 辅助函数。

> 统一前两个模式移动键不同（TAP=IJKL、SCROLL=SDFE）是各自键位约束下的妥协；统一到 hjkl 后认知负担消除。日后会开放让用户自定义按键配置。

进入：任何 mode 按住 Caps Lock + d（chord）。进入时 `ScrollAreaDetector` AX-walk 焦点窗口找所有 `AXScrollArea` + `AXWebArea`，`ScrollOverlay` 画蓝色光晕边框 + 数字标记，默认选离光标最近的区域。**光标已经在选中区内 → 不 warp**；只在区外才 warp 到区中心（滚动事件按光标位置路由，落在区内任意处即可，已在区内还 warp 多余且 jarring）。

零-AX app（a11y 关闭的 Electron，如 Claude；**Chrome 网页内容也是——renderer a11y 默认关**）检测不到滚动区 → 退到焦点窗口：光标已在窗内则不动，在窗外才 warp 到窗口中心，无区域 picker。识别不出的区域靠未来"键盘平移鼠标" / 扩展 DOM 滚动容器检测兜底。

---

## 6. DRAG 子状态（TAP 的子状态，不是独立 mode）

全键盘拖拽，vim-visual 风格。**单段式**：在 TAP normal 里按 bare `v` **立刻** 在光标位置合成 `mouseDown` 进入 dragging 子状态——用户用 hjkl 移光标已经把光标 aim 到目标上了，没必要再多一段 "armed 等再按 v" 的间隔。`DragController` 只持有 `startPoint: CGPoint`（Backspace 取消时用到）。

**入口与归属**：DRAG 是 TAP 的子状态（`TapSub.dragging(DragController)`）。从 TAP normal 进入；drop / cancel 完都回到 **TAP normal** 而非退 OFF（用户场景里 drop 完往往要继续点别的东西，sticky-rehint 接管刷新）。所以 SCROLL / OFF / WINDOW / MOVE 里**没有"直接进 DRAG"的路径**——要 drag 先 Caps Lock 进 TAP 再 `v`。

| 键 | 行为 |
| --- | --- |
| **进入：bare `v`**（仅 TAP normal）| 在光标位置立刻 `leftMouseDown` → tapSub = dragging；记下 `startPoint`；hint overlay 隐藏（label 干扰拖拽视线），HUD `TAP · DRAG` |
| `h / j / k / l` (held) | 移光标，事件类型 `.leftMouseDragged`（目标 app 看到拖拽轨迹）；Shift 加速 / Option 慢，速度跟 TAP normal 一致 |
| `Enter` | `leftMouseUp` 在当前位置 → drop；回 TAP normal（sticky → `scheduleStickyRehint()`；非 sticky → exit OFF，跟 hint commit 一致） |
| `Backspace` | cursor warp 回 `startPoint` → 在起点 `leftMouseUp`（目标 app 看到零位移 click，不触发 drop）→ 回 TAP normal、恢复 hint overlay |
| `Esc` | drop at cursor 后 deactivate 回 OFF（drop 副作用不可避免——按钮必须释放） |
| `Caps Lock`（单击 / + d / + w / + m chord）| 切之前 `cleanupTapSub` 在当前位置 mouseUp 释放（drop 副作用，同 Esc），再走对应 mode 切换 |
| 其它键 | 吞掉（按住 mouseDown 时更不能让杂键漏过去）|

**为什么删了之前的两段式 armed/grab**：早先用 `Caps Lock + v` chord 进 armed（不 grab）、再按 bare `v` 才 grab，是为了"先 aim 再握"。但 TAP 里 hjkl 移光标本来就是 aim——用户走到目标上、然后想 drag 时按 v，**已经 aim 完了**，多一段 armed 反而要按两次 v、还要记当前是 armed 还是 dragging。把 DRAG 收编成 TAP 子状态 + 单段式：TAP 里 aim → bare v → 直接 grab → hjkl 拖 → Enter drop，认知模型最简。

**`v` 选键说明**：vim visual 的对应。`v` 被**从 hint 池里移除**（见 §4）—— TAP normal 里 bare v 永远是"进 DRAG"，不和 hint commit 冲突。代价：hint 池从 17 字母缩回 16；16² = 256 还远够覆盖 maxTargets = 200，没影响。

**典型用例**：
- 拖文件：Caps Lock 进 TAP → hjkl 把光标精确移到文件图标上 → `v` → hjkl 拖到目标文件夹（hover 高亮 + 拖拽指示）→ Enter。
- 选文字 + 复制：（先用 `/` 搜索定位起点光标——见 §6.5）→ `v` → hjkl 到终点（沿途文本被选中）→ Enter（释放，**选区保留**）→ Cmd+C 复制。
- 拖 divider / slider / 时间轴 trim：hjkl 把 cursor 移到 divider 上 → `v` → hjkl 拖 → Enter。

**实现注意点**：
- `startDragFromTap()` 立刻 `MouseSynth.dragDown(at: cursor)` 并构造 `DragController(at: cursor)`，没有 "armed 等 v" 的中间态。
- 早期 hjkl 拦截读 `tapSub` 决定 `dragHeld`（dragging = `.leftMouseDragged`、其它 TAP 子状态 = `.mouseMoved`）。
- `cleanupTapSub()` / `exit` 的 mouseUp 只在 dragging 子状态合成（其它子状态没东西可释放）。
- 进 DRAG 子状态时取消 `pendingStickyRehint`（避免 100ms 延迟里 re-hint 在 drag 中途弹出 overlay）。

---

## 6.5 `/`-搜索子状态（TAP 的子状态）

按 bare `/` 进入：在焦点窗口里找 query 的所有出现位置、复用 hint label 池标记每个匹配——用户敲 query → Enter → 看到一群带 label 的高亮框 → 敲 label commit → cursor warp 到匹配文本左边沿（rect.minX, minY + 0.6×height）→ 回 TAP normal。

**两条匹配路径**（`kickoffSearch` 按 frontmost bundleID 分流）：

- **浏览器 frontmost** → 走扩展 DOM `MouselessDetector.findTextMatches(query)`：TreeWalker 遍历可见 text node + Range.getClientRects() 出 viewport 内的 rect。**~5-20ms**，字符级 100% 准确。每个 visual line 一条 match（多行 wrap 自动展开成多个高亮框）。viewport 外的不返回（OCR 也看不到屏外内容，行为对齐）。**top frame only for v1**（iframe 内容延后）。
- **其它所有 app** → 老的 Vision OCR 路径：`ScreenCapture.captureFocusedWindow()` + `OCRRefiner.recognizeText`（zh + en 双语）+ `findMatches(query, observations, windowRect)` 字符级 boundingBox。**80-200ms**，可能有 OCR 错读（"complete" → "tomplete" 之类）。

终端日志区分两条：`[mouseless] search: ... — DOM match via extension` vs `... — capturing + OCR'ing focused window`。

`MouseSynth.warp` 用 `.mouseMoved` 合成事件让目标 view 收到事件、cursor flips to I-beam（同 §4.3 cursor park 同样的设计）。

**为什么独立做、不复用 hint pipeline**：hint mode 走 AX walk + OmniParser 找 **可点元素**；search 走 OCR + 文本匹配找 **某个字符串在哪**——两个完全不同的检索意图。例如 WeChat 长聊天里要复制中间某条消息，hint 给的是消息行（每行只一个 commit 点、点完是选中行而不是 caret 落到字里），完全不能定位"那段文字的开头"；OCR 直接找字、按 character-level boundingBox 给出像素位置。

**为什么不依赖 AX 白名单**：用户明确指定 search 应该**对所有 app 都用 OCR**，不分 AX / OP。hint 池有白名单是因为 AX 给的可点元素更精确；search 是文本检索、AX 拿不到 "第 47 个字在第几像素"。统一走 OCR 反而最简单。

**为什么字符级 boundingBox**：`VNRecognizedText.boundingBox(for: range)` 给的是 substring 在图像里的精确像素 rect，而不是整行 OCR observation 的粗框。用户搜 "complete" 想落点到 c 前面，不是整段文字开头。

**输入侧目前只支持 ASCII**：OCR 双语（zh + en）但 search buffer 只接 a-z / 0-9 / space（含 **Shift+letter 大写**——`typingMods` 允许 Shift 通过，按下时把字符 `.uppercased()`）。原因是 CGEventTap 在 IME 之前拦截 keyDown、IME 收不到原料就 compose 不出字。中文支持已记入 `SPECS.md` §7 TODO list。

**子状态机**：

| 子状态 | 含义 | 进入条件 |
| --- | --- | --- |
| `.searchTyping(buffer)` | 用户在敲 query（buffer 还没 OCR）| TAP normal 按 `/` |
| `.searchSearching` | OCR + 匹配跑中（异步 Task）| `.searchTyping` 按 Enter 且 buffer 非空 |
| `.searchPicking(matches, typed)` | 匹配结果已绘制成带 label 的高亮框，用户在敲 label 选择 | OCR 完且 matches 非空 |

进 `.searchTyping` 时**隐藏** TAP 的 hint overlay（label 池要复用、视觉上不能撞）；matches 出来时通过 `SearchOverlay` 单独画黄色高亮框 + label chip；commit 时 hide search overlay、cursor warp、`tapSub = .normal`、`scheduleStickyRehint()` 让 hint overlay 100ms 后回来（如果用户在这 100ms 内按 v 进 drag，pending rehint 会被 startDragFromTap 取消——见 §6 实现要点）。

**键位**：

| 键 | `.searchTyping` | `.searchSearching` | `.searchPicking` |
| --- | --- | --- | --- |
| 字母 / 数字 / 空格 | 追加到 buffer，更新 HUD | swallow（OCR 在跑）| 追加到 typed，过滤匹配 label；唯一完整命中 → commit |
| `Enter` | kickoff OCR（buffer 非空才跑）| swallow | swallow（commit 由敲完 label 触发）|
| `Backspace` | 删一字符；buffer 空再按 = cancel 回 TAP normal | swallow | 删一字符；typed 空再按 = 回 `.searchTyping("")` 重新输 query |
| `Esc` | cancel 回 TAP normal（恢复 hint overlay）| cancel 回 TAP normal（OCR task 进 cancellation guard）| cancel 回 TAP normal |
| Caps Lock 单击 / chord | 同 dragging：先 cleanup（关 search overlay 恢复 hints）再切 mode | 同 | 同 |

**Commit 落点**：`(rect.minX, rect.minY + 0.6×height)` —— 匹配文本的**左边沿**、垂直从顶下来 60% 处。X 不加 inset（早期讨论过给个 -2pt 偏移让光标在第一个字符**外**，但所有 macOS 文本控件 hit-test 都对 minX 包容，落到 minX 就在文本里）。Y 用 60% 而非 50%：字符 boundingBox 通常贴文字本身，垂直正中（midY）会落在字符笔画里、文本视图 hit-test 有时把它判为"字符内部"而非"caret 间隙"；60%（midY 略偏下）落到字符基线附近，更稳定。Commit 后立刻可以按 `v` 起 drag（§6 入口），这是 search → drag 选文字复制的核心 workflow。

**用 `.mouseMoved` 合成而非 `CGWarpMouseCursorPosition`**：CGWarp 把像素挪过去但**跳过事件管线**，目标 view 不知道鼠标进来过，cursor shape 还是 warp 前的样子（典型现象：落到文本框后光标仍是箭头不是 I-beam，要鼠动一下才翻）。改成合成一发 `.mouseMoved` 给同一个落点，view 收到正常事件 → 触发 cursorRect / hover state 更新 → I-beam 翻过来、按钮高亮、链接下划线、tooltip 等全部到位。代价是一次合成 `CGEvent` 比直接 warp 多 ~1ms，可忽略。

**为什么 OCR 直接对**整个焦点窗口**而不是按 OP 那种 crop**：用户搜的字可能在窗口任何位置；crop 不知道往哪 crop。整窗 OCR 一次 ~80-200ms（取决于字数），用户已经按了 Enter、可以接受这点延迟（不像 hint mode 是进入瞬间）。

**实现注意点**：
- `OCRRefiner.recognizeText(in:)` 抽出来给 search 用（同一个 `.accurate` + zh/en config，跟 OP refiner 共用）。
- `findMatches(query, observations, windowRect)`：对每个 observation 找所有 substring 命中（同一行多次命中 = 多个 label），用 `topCandidates(1)[0].boundingBox(for: range)` 拿字符级 rect。case-insensitive。
- Label 复用 `HintMode.generateLabels(count:)`（`generateLabels` 已开放为 internal），所以 search 的 label 和 hint label 视觉一致、按键习惯一致。
- `SearchOverlay` 是另一个 `.statusBar` 级 borderless 透明 NSWindow（per-NSScreen），画黄色高亮框 + label chip（chip 在匹配文本**左侧**，挤不下时回退到内侧）。
- 异步 OCR Task 在每个等待点 guard `tapSub == .searchSearching`，用户在 OCR 跑的时候 cancel / 切 mode 时 task 自己短路。

---

## 7. WINDOW mode 键位

整窗口尺寸调整。`WindowController` 持有状态 + 60fps timer，每 tick 算 delta 并直接 AX 写焦点窗口的 `AXPosition` / `AXSize`，瞬时无动画。

| 键 | 行为 |
| --- | --- |
| **进入：`Caps Lock + w` chord**（任意 mode）| 两道 gate 都过才进（见下）。任一不过 → HUD 提示原因、不入 mode |
| `h` / `j` / `k` / `l` (held) | 把对应 border 往**外**推（`k` 顶上 / `j` 底下 / `h` 左外 / `l` 右外），按住连续；步长 20pt/tick @ 60fps |
| **双击** `hh` / `jj` / `kk` / `ll`（150ms 内连按两次同键，第二下保持按住）| **反向**该 edge：往内压 = 缩小该 edge。每条 edge 独立——可以 k 长按扩顶 + jj 双击缩底同时进行 |
| `Shift + hjkl` | **加速**（80pt/tick = 4×，跨屏快速 reshape）。跟 TAP-hjkl 移光标、SCROLL d/u、MOVE hjkl 的 Shift 语义一致 |
| `Option + hjkl` | **精细**步长（5pt/tick 替代默认 20pt/tick），用于和别的窗口/屏幕边贴齐时的微调 |
| `Shift + Option + hjkl` | Option 优先 → slow（仿 `MouseMover.moveSpeed` / `WindowMoveController`：误按 Shift+Option 倾向"慢"而非"快"） |
| 同时按（如 `h+j`）| 组合 → corner 推拉，4 个角都成立。双击反向也独立——`kk + jj` 双击同时按 = 顶底同时收 |
| 矛盾对（`h+l` 或 `j+k`）| deltas 自然抵消（位置和大小都 +/− 相消，窗口不变） |
| `Esc` | exit OFF（teardown：停 timer / 关 overlay） |
| 其它键 | 吞掉 |
| `Caps Lock`（单击 / + d / + w / + m chord）| 立即切到对应 mode。`teardownCurrentMode` 先停 timer + 关 overlay 再切；resize 不残留状态 |

**入 mode 的两道 gate**（`enterWindowMode`）：

1. **`AXWindowOps.hasTitleBarButton(window)`** —— 至少有一个标题栏按钮（`AXCloseButton` / `AXMinimizeButton` / `AXZoomButton` / `AXFullScreenButton`）。这是"是不是真正的用户窗口"的判据：
   - **Finder Desktop**（没开 Finder 窗口时 `AXFocusedWindow` 落到的那个 desktop "窗口"）：没有任何标题栏按钮 → 拒绝。本来就不是用户可 resize 的东西。
   - **macOS fullscreen 状态**：标题栏按钮被隐藏 → 拒绝。fullscreen 状态下也 resize 不了。
   - **AX 黑洞 app**（Electron 等）：外壳 NSWindow chrome 是原生的，标题栏按钮在 AX 树里能查到（AX 黑洞是窗口**内容**那一层）→ 过。
   - **为什么用这个而非 `AXSubrole == "AXStandardWindow"`**：AX 黑洞 app 的 subrole 经常 nil / 乱写 / 不暴露，严格 subrole 检查会误杀。标题栏按钮直接查 attribute 是否存在，比 subrole 鲁棒；最多 4 次 IPC（短路命中即返），一次性。
2. **`AXWindowOps.isResizable(window)`** —— `AXPosition` 和 `AXSize` 两个都得 `AXUIElementIsAttributeSettable` 才行。resize 靠每 tick 写这俩属性，任一不通直接没法做。

**视觉**（`WindowOpOverlay`）：蓝色实线 border（3pt）贴窗口外沿；4 个**两行 chip**（蓝底白字）贴在每边中点的**外侧**：
- 第一行（大字粗体）：bare key + 扩展方向，如 `↑k`
- 第二行（小字稍淡）：双击反向，如 `↓kk`

完整对照：top `↑k / ↓kk`、bottom `↓j / ↑jj`、left `←h / →hh`、right `→l / ←ll`。角落**不画**——hjkl 组合是隐含的，不再加 chip。**chip 屏幕外不画**：每个 chip 单独检查是不是全部包含在某个 NSScreen 的 view bounds 内；窗口顶到屏幕顶时，顶部 chip 应该在屏幕外那一块，就**直接不画**（用户明确要求：不画到屏幕外）。

**为什么双击反向、不是 Shift 反向**：早先版本用 `Shift+hjkl` 表示 shrink（反向）——但 Shift 在整个项目里固定语义是"加速"（TAP-hjkl 移光标、SCROLL d/u、MOVE-hjkl 都是 Shift=fast）。WINDOW 拿 Shift 做反向（a）跟其它 mode 不一致、用户切来切去会犯迷糊，（b）让 resize 失去了加速的能力。改成"双击同键反向"后：Shift 回归加速、反向落到一个本来就属于 vim 风格的肌肉记忆（连按）、每条 edge 的反向状态还能独立追踪（k 长按扩顶 + jj 双击缩底可以同时进行）。双击窗口是 150ms（`windowReverseTapWindow`，从初版 300ms → 200ms → 150ms 两次调短：300ms 把"按一下、看一眼结果、再按一下扩大"这种自然停顿误判成双击；200ms 还有少量边界 case；150ms 把窗口压到"故意快连按"的舒适区 80-130ms 略上方、把"看一眼再按"的自然停顿区 250ms+ 全部排除）。第二下要保持按住（"双击 + hold"，第二下放掉就只缩一格）。

**HUD**：进 mode 时显示 `WINDOW`。

**为什么用 chord 而非 bare `w`**：`w` 在 hint 字母池里（`a s d f g e r u i o p w t n m c v`，见 §4）。用 chord 触发，bare `w` 仍可当 hint label。也跟 SCROLL 的 `Caps Lock + d` 一致。

**为什么不留 fallback 合成边缘拖拽路径**：原型最早有一条 fallback——AX 不可写时合成 `mouseDown` 在窗口 border 中点 / 角点、每 tick 合成 `.leftMouseDragged` 推光标。撞到 Finder Desktop 这种"AX 里是窗口、实际不是用户窗口"的 case 时 HUD 标 `WINDOW · synth-drag`，但 fallback 在 Desktop 上同样没效果（没 resize handle 给 OS hit-test），变成迷惑性 UX。加了标题栏按钮 gate 后，能过 gate 的窗口几乎都允许 AX 写——fallback 的复杂度不再值得，删掉。

**实现要点**：
- 触发：`HotkeyTap` F19 arm 期间按 `w` → `session.enterWindowMode()`，仿 `Caps Lock + d → enterScroll`。
- 焦点窗口解析：`AXWindowOps.frontmostWindow()` 沿用 `ScreenCapture.focusedWindow()` 的链（`AXFocusedWindow` → `AXMainWindow` → `AXWindows[0]`）。
- Edge math：`top` expand 概念上 = `AXPosition.y -= step, AXSize.height += step`；`bottom` expand = `AXSize.height += step`；left/right 对称。shrink 翻号——每条 edge 的 sign 独立由 `WindowController.reversedEdges` 决定。
- **写顺序：anchored grow 走 position-first，其它走 size-first**。AX 一次只能写一个属性（不像 NSWindow 的 resize handle 是 atomic），中间状态是可被 app 拒绝的。

  *Anchored grow*（顶/左 expand：`k` / `h` / `kh` / `kl` / `jh`…）走 `tickPositionFirst`：先 `writePosition` 把 origin 移到目标位置 → 读回 OS 实际允许的 origin（菜单栏会 clamp y，屏幕左缘会 clamp x） → 按**实际**位移 + 非 anchored edge 的 size 贡献算最终 size → `writeSize`。

  *其它情况*（anchored shrink、纯 bottom/right、纯平移）走 `tickSizeFirst`：先 `writeSize` → 读回 → 按 actualΔ 比例移 origin → readback → 反向 clamp trim（origin 被 OS 卡住时把 size 也回收一下保持对边不动）。

  踩坑：早期统一 size-first，WeChat 这种"右边 ≤ X" 约束的 app 在 `h` expand（向左扩 = 顶上 origin 不变、size 加宽）时拒绝 writeSize——因为中间态"old origin + new bigger size"会让右边超过 X。把 anchored grow 路径改成 position-first 后 origin 先到位，再写 size 时右边其实没动，app 接受。鼠标拖窗能无限拉，因为 NSWindow.resize 是 atomic，AX 写做不到 atomic，所以要靠写顺序绕。

- **Contribution tracking**：anchored edge（top/left）的 origin 移动只该响应它**自己那份** size 贡献，不是整轴的 sizeΔ。`topContribution` / `leftContribution` 跟 `sizeDelta` 分别维护——`k+j` 同时按时，顶 contribution = +step、底 contribution = +step、整 sizeΔ.height = +2×step；origin.y 只该 -= step（顶的那份），不是 -= 2×step。早期版本用 `topActive: Bool` 标记 + `actualHDelta` 算 origin 位移，`k+j` 会变成"顶向上 2×step，底没动"，bug。
- **Clamp suppression**：anchored edge 如果上一 tick 写完 origin 被 OS clamp 住（partial move），缓存到 `clampedOriginY / clampedOriginX`；下一 tick 这条 edge 直接跳过、不参与 sizeΔ 也不参与 contribution。否则会反复"写 origin → OS clamp → 写 size 长出去 → 视觉上对边在飘"。`stopEdge`（keyUp）时清缓存让用户重按重试。
- **双击反向后的链式误判**：hh（双击 shrink）释放后 100ms 内再按 h，原本 `now - lastKeyUp < 150ms` 又被判为双击 = 又反向 = 还在 shrink，用户感觉"h 失灵"。修复：`stopEdge` 时如果当前是 reversed 状态，把 `lastWindowEdgeKeyUp[edge]` 清成 nil 而不是刷成 now——下次按 h 拿不到上一次的 timestamp，按"首次"逻辑走（grow）。
- 双击检测：`VimSession.lastWindowEdgeKeyUp[edge]` 存每条 edge 上次 keyUp 的 `CFAbsoluteTimeGetCurrent()` 时间戳。下次同键 keyDown 时 `now - last < 0.15` → 此次 hold 标 reversed，传给 `controller.startEdge(edge, reversed: true)`。OS key-repeat 不会误触（key-repeat 不发 keyUp，timestamp 不更新）。退 WINDOW mode 时清空 `lastWindowEdgeKeyUp` 防再次进入读到旧时间戳。
- 速度：bare = 20pt/tick，Shift = 80pt/tick (fast)，Option = 5pt/tick (slow)，Option > Shift 优先（同 `MouseMover.moveSpeed`）。
- 软 min size 200×120 防 in-memory rect 跟实际拉得太开（app 自己也会 clamp）。

---

## 8. WINDOW MOVE mode 键位

窗口整体平移（不改尺寸）。跟 WINDOW resize 是**独立的两个 mode**——一个动 `AXPosition`、一个动 `AXPosition + AXSize`，混在一起做反而要给 hjkl 多挂修饰键，分开干净。

`WindowMoveController` 镜像 `WindowController` 结构：方向集合 + 60fps timer + 每 tick 写 `AXPosition`（**只写 position**，单 IPC，比 `writeRect` 省一次 IPC）。

| 键 | 行为 |
| --- | --- |
| **进入：`Caps Lock + m` chord**（任意 mode）| 两道 gate：`hasTitleBarButton`（同 WINDOW resize）+ `isMovable`（只查 `AXPosition` 可写，比 `isResizable` 松——move 不动 size） |
| `h / j / k / l` (held) | 窗口往对应方向平移（h=左 / j=下 / k=上 / l=右，跟 cursor / SCROLL / WINDOW resize 同套 hjkl 方向编码）|
| `Shift + hjkl` | **fast**（80pt/tick，4×）—— 跨屏快移 |
| `Option + hjkl` | **slow**（5pt/tick）—— 精细对齐到其它窗口/屏幕边 |
| `Shift + Option + hjkl` | **Option 优先 → slow**（跟 `MouseMover.moveSpeed` 优先级一致：误按 Shift+Option 时倾向"慢"而非"快"） |
| 同时按（如 `h+j`）| 对角线平移（左下），两 axis 的 delta 独立叠加 |
| 矛盾对（`h+l` 或 `j+k`）| 自然抵消（dx 或 dy 相加为 0，窗口不动） |
| `Esc` | exit OFF |
| 其它键 | 吞掉 |
| `Caps Lock`（单击 / + d / + w / + m chord）| 立即切到对应 mode。`teardownCurrentMode` 先停 timer + 关 overlay 再切 |

**视觉**：跟 WINDOW resize 共用 `WindowOpOverlay`，但 `show(rect:withChips:)` 这里传 `false`——**蓝色 border 照画，4 个边缘 chip 不画**。原因：resize 的 chip（`↑k / ↓j / ←h / →l`）暗示"这个 border 往那边推"，绑边语义；move 里 hjkl 是方向、不绑边，挂同样的 chip 反而让人误以为是 resize。border + HUD `MOVE` 标签足够，hjkl 方向跟其它 mode 一致不用每次重学。

**HUD**：进 mode 时显示 `MOVE`。

**为什么用 chord 而非 bare `m`**：`m` 在 hint 字母池里（`a s d f g e r u i o p w t n m c v`，见 §4）。chord 触发，bare `m` 仍是 hint label。也跟 SCROLL `Caps Lock + d` / WINDOW resize `Caps Lock + w` 一致。

**实现要点**：
- 触发：`HotkeyTap` F19 arm 期间按 `m` → `session.enterWindowMove()`。
- `AXWindowOps` 加 `isMovable`（只 probe `AXPosition` settable）+ `writePosition`（单 IPC 只写 origin）。
- 控制器：`WindowMoveController.swift`，~70 行。`enum Direction { left, right, up, down }` + `Set<Direction>` 追踪按住的方向。tick 里每 axis 独立加 step 算 `dx, dy`。
- Mode 互斥：MOVE 时其它 mode 触发（`enterWindowMode` / `enterScroll` / `enterDrag` / `handleTriggerTap`）都 guard 掉，必须先 Esc。

---

## 9. 命令面板键位

| 键 | 行为 |
| --- | --- |
| 字母 a–z | 追加到 buffer |
| `Backspace` on non-empty | 删一个字符 |
| `Backspace` on empty | 关闭面板，回到底层 mode |
| Caps Lock (bare) | 关闭面板，回到底层 mode（跟空 buffer + Backspace 等效） |
| `Return` | 执行命令 |
| `Esc` | deactivate Mouseless（回 OFF，进程仍在 menu bar） |

注意面板**只接字母**（`letterChar(for:)` 显式只列 a–z）。数字 / 符号会被忽略。原因：当前未来的命令都是
字母短串（`st`、`dr`），让用户少思考"这个键是不是命令"。

### 当前命令

| 命令 | 行为 |
| --- | --- |
| 任何当前未实现的字母组合 | buffer 清空，**面板保持打开**，让用户继续输 |

故意**没有 `:q` 命令**——Esc 已经 deactivate，quit 进程是 menu bar 行为，跟 hint mode 里的命令面板不是一回事（见 §3.1 三层级）。把"退进程"放进面板会模糊"deactivate vs quit"的界限。

未来 mode 通过 `executeCommand` 接入：
```swift
case "st": switchTo(.selectText(...))
```

（不需要 `dr` 命令——DRAG 已经收编成 TAP 子状态，bare `v` 进入；palette 不再为子状态留口子。）

---

## 10. KeyCode 常量

`KeyCode.swift` 里的是 `kVK_ANSI_*`，**物理键位**。Dvorak / 国际键盘上字母位会错。
迁移路径：用 `UCKeyTranslate` 或 `CGEventKeyboardGetUnicodeString` 把 keyCode + flags → 字符再匹配。
TODO 已经留在 `KeyCode.swift` 头部注释。

主要常量：

| 名字 | 码 | 说明 |
| --- | --- | --- |
| `f19` | 80 | **触发键**——物理 Caps Lock 经 hidutil 重映射后到达这里 |
| `grave` | 50 | `` ` `` / `~` —— 保留常量，目前没用作触发 |
| `escape` | 53 | 退出键 |
| `semicolon` | 41 | `;` —— Shift 后是 `:`，打开面板 |
| `quote` | 39 | `'` —— TAP normal 里 toggle move-only arm（见 §4.3.5）|
| `return` | 36 | 执行命令 |
| `delete` | 51 | Backspace |
| `tab` | 48 | 暂未用 |
| `space` | 49 | 暂未用 |
| `a..l` | 0,1,2,3,5,4,38,40,37 | home row 9 键（注意 g/h 顺序：g=5, h=4）；`h/j/k/l` = hjkl 移光标，`a s d f g` = hint 字母 |
| `i` | 34 | hint 字母（上排，非 home row） |
| `q..p` | 12,13,14,15,17,16,32,34,31,35 | 上排（`e r u i o p w t` 现作 hint 字母） |
| `z..m` | 6,7,8,9,11,45,46 | 下排（`c=8 n=45 m=46` 现作 hint 字母）|
| `1..0` | 18,19,20,21,23,22,26,28,25,29 | 数字（注意 5=23, 6=22；7=26, 9=25） |
| `arrow*` | 123–126 | left/right/down/up，给未来 select-text mode |

**键位用途速查**（TAP mode）：`h/j/k/l` = hjkl 移光标；hint 字母 = `a s d f g e r u i o p w t n m`（15 个，不含 hjkl/v/c）；`v` = bare 进 DRAG 子状态；`c` = bare 点击（Shift 双击 / Option 右键）；`/` = bare 进 search 子状态；`Enter` = 放行给 app；数字 = Dock hint / SCROLL 切区域。

---

## 11. 修饰键策略汇总

| 键 / 修饰键 | 在任何 mode 内的行为 | 为什么 |
| --- | --- | --- |
| `Cmd` | 整个事件放行 | 保 Spotlight / Cmd+Tab / 截屏 / 关窗口等 |
| `Ctrl` | 整个事件放行 | 保 Mission Control / Ctrl+↑ 等；也因为 power user 把 Ctrl+hjkl 当方向键 |
| `↑ / ↓ / ← / →`（任意 mode、任意修饰键组合）| 整个事件放行 | Mouseless 用 hjkl 做自己的光标 / 滚动 / 窗口移动；箭头键让位给焦点 app 的原生导航（滚列表、移文本 caret、走菜单等）。如果不放行，sticky TAP 里就没法用箭头翻页 |
| `Enter`（TAP normal / SCROLL）| 整个事件放行 | Enter 在 app 里经常有自己的语义——确认菜单、提交表单、决定选项。配合上面的箭头键放行，组成"↑↓ nav 菜单 + Enter 选中"完整闭环。原 Enter 点击的功能挪到 bare `c`（见 §4 / §5）。 dragging 子状态 / search-typing / palette 仍内部用 Enter（drop / kickoff OCR / execute），那些场景跟 app 的 Enter 语义没冲突 |
| `Shift` | 消费 —— hint 末位字符 / `c` = **右键**（按住 + label）；Shift **双击按住** + label/`c` = **双击**（§4.3.6）；移光标键(hjkl) = 加速；hjkl 双击 = 跳 1/2 屏（否则 1/4） | Shift 潜意识 = "另一种点击" = 右键；双击让给 Shift 双击手势 |
| `Option` | 消费 —— **点击动作已不再用 Option**（空出来留作他用）；只剩移光标键 = 精细慢速 | 旧"Option = 右键"已废（够不顺手）；移光标非 hint 字母，不冲突 |
| `'`（TAP normal）| 消费 —— toggle move-only arm（下一个 hint pick warp 光标不点击，见 §4.3.5）| Cmd/Ctrl 跟系统冲突、Shift/Option 占了，`'` 是非修饰键的轻量前缀 |

放行 vs 消费在 `VimSession.handle()` 顶部判断：先 `flags.intersection([.maskCommand, .maskControl]).isEmpty` 排掉系统快捷键，再独立判一次 keyCode 是不是箭头键（任意修饰组合都放行）。hjkl 移动额外要求不含 Cmd/Ctrl/Option（只允许 Shift 加速）。

---

## 12. 新 mode 接入路径

加一个新 mode（例如 select-text）的最小改动：

1. **`Mode` enum 加 case**：`case selectText(SelectTextMode)`。
2. **`handleMode` switch 加分支**：dispatch 到 `handleSelectText(...)`。
3. **写 `SelectTextMode` 类**：仿 `HintMode` 的 `activate / deactivate / handle` 接口。
4. **`executeCommand` 接命令**：`case "st": switchTo(.selectText(SelectTextMode()))`。
5. **mode 切换函数**（如果还没有）：
   ```swift
   private func switchTo(_ newMode: Mode) {
       if case .tap(let h) = self.mode { h.deactivate() }
       self.mode = newMode
       paletteBuffer = nil
       renderModeHUD()
   }
   ```
6. **HUD 文案**：`renderModeHUD` 的 switch 加分支。

palette 不需要改，因为它和 mode 正交。
