# Modes & Key Bindings

Mode 状态机、命令面板、所有键位的完整定义。

相关文件：`VimSession.swift`, `KeyCode.swift`。

---

## 1. 概念模型

两个正交维度：

```swift
enum Mode {
    case tap(HintMode)
    // 未来：case selectText(...), case drag(...), case rightClick(...)
}

var paletteBuffer: String? = nil   // nil = 面板关闭
var sticky: Bool = false           // TAP mode 内有效
```

- **Mode** 描述 "用户想做什么操作"（点击 / 选文字 / 拖拽）。
- **paletteBuffer** 是命令面板的输入缓冲。打开面板**不会**改变底层 mode；关闭面板回到原 mode 继续。
- **sticky** 只在 TAP mode 里使用，表示点击后是否保持 mode（连续点多个目标）。

---

## 2. 状态转移图

```
[OFF] --press Caps Lock (no mods)--> [TAP, sticky=off]
                                      │
        ┌─────────────────────────────┼─────────────────────┐
        │                             │                     │
   press Caps Lock          press : (Shift+;)          press hint letter
   toggles sticky            opens palette                  │
        │                             │                ┌────┴───────┐
        ▼                             ▼              .pending   .committed
   [TAP, sticky=on]           [TAP + palette]          │            │
                                      │              stay     sticky?
                                      ▼                         ├── on  → re-scan, stay TAP
                                 <CR> = run                     └── off → exit
                                 <BS> on empty = close
                                 <BS> on non-empty = pop char
                                 esc = deactivate (always)
```

**Esc 永远 deactivate**——回到 OFF（hint 隐藏、sticky 清零、palette 关），不只是退出面板或退出 sticky。
但 **进程不退**——Mouseless 仍在 menu bar，Caps Lock 仍是 F19，再按 Caps Lock 立刻进 TAP。
要真正退出进程让 Caps Lock 还原，走菜单栏 Quit（见 §3.1 三层级表）。

只想关面板回到 TAP 而不 deactivate：空 buffer 上按 Backspace，或按 Caps Lock。

---

## 3. 进入 / 退出

触发键是 **Caps Lock**（物理键，hidutil 重映射成 F19 后 CGEventTap 接到的是 F19 keyDown，见 `event-pipeline.md` §3）。

### 3.1 三个层级，别混淆

Mouseless 的状态有**三层**，"退出"在哪一层语义不一样：

| 层级 | menu bar 图标 | hidutil remap | 怎么进入 | 怎么离开 |
| --- | --- | --- | --- | --- |
| **进程未运行** | 无 | 已还原 | 还未启动 / 用户菜单栏 Quit | 启动 Mouseless |
| **进程运行 · OFF**（hint 不显示） | `M●` | 生效 | 启动 Mouseless / Esc 从 TAP 退出 | Caps Lock 进 TAP / 菜单栏 Quit |
| **进程运行 · TAP**（hint 显示中） | `M●` + hint overlay | 生效 | OFF 按 Caps Lock | Esc / commit + sticky=off |

**Esc 只在层级内"deactivate"——回 OFF，不退进程**。Caps Lock 还是 F19，你再按一下立刻又能进 TAP。要真退出进程（让 Caps Lock 还原成普通 toggle），走菜单栏 Quit 或 Cmd+Q——那条路径触发 `applicationWillTerminate` → `TriggerRemap.revertAtQuit()`。

### 3.2 键位

| 键 | 状态 | 行为 |
| --- | --- | --- |
| Caps Lock (bare) | OFF | 进入 TAP mode，立即扫描并显示 hints |
| Caps Lock (bare) | TAP | 切换 sticky |
| Caps Lock (bare) | palette 开 | 关 palette，回到 TAP（mode 不变） |
| `Esc` | TAP / palette | deactivate Mouseless（回到 OFF，进程仍在 menu bar） |
| 菜单栏 Quit / Cmd+Q | 任意 | quit 进程，Caps Lock 还原成普通键 |

Caps Lock + 任意修饰键放行：Shift / Cmd / Ctrl / Option + Caps Lock 都不消费，留给未来扩展或用户自己绑别的快捷键。

`VimSession.enter()`：构造 `HintMode`，调 `activate()` 扫描 + 显示 overlay。如果三个来源都空，直接显示 "no hints here" 不进 mode。

---

## 4. TAP mode 键位

| 键 | 行为 |
| --- | --- |
| `a s d f g h j k l` | 输入 hint 标签字母（home row 9 个） |
| `0–9` | 输入 hint 标签数字（Dock 专用） |
| `Shift + 末位字符` | 右键点击 |
| `Option + 末位字符` | 双击 |
| `Shift + ;` (= `:`) | 打开命令面板 |
| `x` (bare) | "点空白处" —— 激活 Finder，重新扫描 |
| `Cmd / Ctrl + 任意键` | **放行**，不消费（保系统快捷键） |

### 4.1 标签输入

每次按键：
1. `next = typed + char`
2. 过滤 `targets` 中 `label.hasPrefix(next)` 的：
   - 0 个匹配 → `.cancelled`，整个 mode 退出
   - 1 个且完整匹配 → `.committed`，commit 后视 sticky 决定下一步
   - 多个 → `.pending`，刷新 overlay 展示剩余候选

提交点击的实现详见 `hint-rendering.md` 的 commit 部分。

### 4.2 Sticky

- 进入 TAP 时 `sticky = false`。
- bare Caps Lock 切换。
- `.committed` 时如果 sticky：`deactivate()` 当前 HintMode → 构造新的 `HintMode()` → `activate()`，
  整套 hint 集合重新扫描（焦点 app 可能已经因为点击而变了）。

### 4.3 `x` —— 点空白处

语义：**dismiss + rescan**。两阶段，没有固定 sleep，没有可猜的 timing。

```swift
if keyCode == KeyCode.x && flags.intersection(modMask).isEmpty {
    hint.deactivate()
    let dockPID = ...com.apple.dock....processIdentifier
    let openDockMenu = dockPID.flatMap { findOpenDockMenu(pid: $0) }
    let finder = ...com.apple.finder....first

    Task { @MainActor in
        // Stage 1a: AX-cancel the Dock context menu (if open)
        if let menu = openDockMenu {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
        // Stage 1b: focus switch + wait for confirmation
        if let finder, !finder.isActive {
            finder.activate(options: [])
            _ = await AXWait.appActivated(bundleID: "com.apple.finder", timeoutMs: 300)
        }
        // Stage 2: re-scan
        let next = HintMode()
        if next.activate() { ... }
    }
}
```

#### Stage 1a：AX-cancel Dock 上下文菜单

Dock 的右键菜单在视觉关闭和 AX 树清理是**两条独立路径**：

- 真鼠标点击菜单外 → 两路都走完 → 菜单消失 + AX 树清 ✓
- 焦点切换（app 激活） → 只走视觉路 → 菜单消失 + **AX 树留着 AXMenu 元素**（ghost）
- 合成 Esc（不管投到哪） → 同上，只视觉关

ghost AXMenu 是个真问题：下一次 hint walk 仍能从 `AXDockItem → AXChildren → AXMenu → AXChildren → AXMenuItem` 拿到菜单项，position 还是旧坐标，AXEnabled 还是 true，filter 全都过 —— 屏幕中间就会出现悬空 hint。

**`AXUIElementPerformAction(menu, kAXCancelAction)`** 是 AX 层暴露的"取消这个元素"信号，Dock 的 AXMenu 实现了它（实测 actions 里有 `AXCancel`）。调用后 Dock 走和"真鼠标点击空白处"等效的清理路径：menu 视觉关 + AXMenu 从 AX 树里销毁。Re-scan 拿到干净的树。

AXCancel 是同步的 —— 函数返回时 element 已经被销毁。所以不需要 observer + wait。

发现菜单元素的代码：`VimSession.findOpenDockMenu(pid:)`，结构是：

```
AXApplication (Dock)
└── AXList
    ├── AXDockItem ...
    ├── AXDockItem (right-clicked)
    │   └── AXMenu             ← 这里
    │       └── AXMenuItem ...
    └── AXDockItem ...
```

必须在 `kAXCancelAction` 之前拿到 handle —— AXCancel 之后元素就没了，没法再 query。

#### Stage 1b：焦点切换 + 等激活通知

激活 Finder 处理"焦点切换就能关掉"的浮层：app 菜单栏下拉、popover、status menu 都会随 owning app 失焦自动消失。

`AXWait.appActivated` 订阅 `NSWorkspace.didActivateApplicationNotification`，Finder 真正成 frontmost 时 OS 发通知，挂起的 Task 才被唤醒。Finder 已经是 frontmost 时立即返回不挂起。300ms timeout 兜底，正常路径下不会触发。

#### Stage 2：re-scan

AXCancel + Finder 激活完成 → AX 树清 + 焦点稳 → 新建 `HintMode` 扫一遍。

#### 为什么这样 vs 历史方案

写这条路径之前迭代过的失败方案：

| 尝试 | 为什么不行 |
| --- | --- |
| 合成 Esc（默认 `cghidEventTap`） | Esc 路由到 frontmost app（Finder 已激活了），Dock 收不到。菜单不关。 |
| `CGEventPostToPid(dockPID, esc)` 直接投 Dock | Dock 视觉关菜单了，但走的不是"完整 cancel"路径，AXMenu 留着。ghost 仍在。 |
| 订阅 `kAXMenuClosedNotification` / `kAXUIElementDestroyedNotification` | 因为 Dock 没走完整 cancel 路径，根本不发这些通知。永远 timeout。 |
| 固定 sleep N ms | 猜时间。快机器浪费，慢机器漏。不论多长都不能让 Dock 主动清理 AX 树。 |
| Walk 时跳过 `AXMenu` 下钻 | 直接砍掉"用户右键 Dock → 按触发键 → 选菜单项"功能。 |

`AXCancel` 是唯一一个**对 AX 树实际有效**的清理手段。

`Task` 包起来还有一个独立作用：把整个序列挪出 event tap callback，否则同步等待会让 CGEventTap 触发 user-input timeout 自动 disable（见 `event-pipeline.md`）。

---

## 5. 命令面板键位

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
case "dr": switchTo(.drag(...))
```

---

## 6. KeyCode 常量

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
| `return` | 36 | 执行命令 |
| `delete` | 51 | Backspace |
| `tab` | 48 | 暂未用 |
| `space` | 49 | 暂未用 |
| `a..l` | 0,1,2,3,5,4,38,40,37 | home row 9 个字母（注意 g/h 顺序：g=5, h=4） |
| `q..p` | 12,13,14,15,17,16,32,34,31,35 | 上排 |
| `z..m` | 6,7,8,9,11,45,46 | 下排（含 `b=11`, `n=45`, `m=46`） |
| `1..0` | 18,19,20,21,23,22,26,28,25,29 | 数字（注意 5=23, 6=22；7=26, 9=25） |
| `arrow*` | 123–126 | left/right/down/up，给未来 select-text mode |

---

## 7. 修饰键策略汇总

| 修饰键 | 在 TAP mode 内的行为 | 为什么 |
| --- | --- | --- |
| `Cmd` | 整个事件放行 | 保 Spotlight / Cmd+Tab / 截屏 / 关窗口等 |
| `Ctrl` | 整个事件放行 | 保 Mission Control / Ctrl+↑ 等 |
| `Shift` | 消费，作为 right-click 语义 | hint click action 需要 |
| `Option` | 消费，作为 double-click 语义 | hint click action 需要 |

放行 vs 消费在 `VimSession.handle()` 顶部用 `flags.intersection([.maskCommand, .maskControl]).isEmpty` 判断。

---

## 8. 新 mode 接入路径

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
