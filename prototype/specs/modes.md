# Modes & Key Bindings

Mode 状态机、命令面板、所有键位的完整定义。

相关文件：`VimSession.swift`, `KeyCode.swift`。

---

## 1. 概念模型

```swift
enum Mode {
    case tap(HintMode)            // hint 点击 + IJKL 移光标 + Enter 点击
    case scroll(ScrollController) // 键盘滚动（多区域 picker）
    // 未来：case selectText(...), case drag(...), case rightClick(...)
}

var paletteBuffer: String? = nil   // nil = 面板关闭
var sticky: Bool = false           // TAP mode 内有效
```

- **Mode** 描述 "用户当前在干什么"。当前两个：`.tap`（hint 点击，也含 IJKL 移光标 + Enter 点击）、`.scroll`（键盘滚动）。
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
   └─ Caps Lock 按住 + j/k ──┐        ├─ hint 字母      → 点击（commit）
                             │        ├─ i/j/k/l        → 移光标（IJKL，Shift 加速）
   [TAP] Caps Lock按住+j/k ──┤        ├─ Enter          → 光标位置左键单击
                             ▼        ├─ Shift+; (:)    → 命令面板
                         [SCROLL] ◄───┘ Caps Lock按住+jk
                             │
                             ├─ j/k          → 滚动（按住连续，Shift 加速）
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

实现见 `HotkeyTap.swift`（arm 状态机）+ `VimSession.handleTriggerTap()`。arm 覆盖所有 mode，不只 OFF——这是"TAP 内也能 Caps Lock+jk 进 SCROLL"和"连续 Caps Lock 进 sticky"两个行为的根。

---

## 3. 进入 / 退出

触发键是 **Caps Lock**（物理键，hidutil 重映射成 F19 后 CGEventTap 接到的是 F19 keyDown，见 `event-pipeline.md` §3）。

### 3.1 三个层级，别混淆

Mouseless 的状态有**三层**，"退出"在哪一层语义不一样：

| 层级 | menu bar 图标 | hidutil remap | 怎么进入 | 怎么离开 |
| --- | --- | --- | --- | --- |
| **进程未运行** | 无 | 已还原 | 还未启动 / 用户菜单栏 Quit | 启动 Mouseless |
| **进程运行 · OFF** | `M●` | 生效 | 启动 / Esc 退出 mode | Caps Lock 进 TAP / Caps Lock+jk 进 SCROLL / 菜单栏 Quit |
| **进程运行 · TAP/SCROLL** | `M●` + overlay | 生效 | 见 §2 | Esc / 菜单栏 Quit |

**Esc 只在层级内"deactivate"——回 OFF，不退进程**。Caps Lock 还是 F19，你再按一下立刻又能进 TAP。要真退出进程（让 Caps Lock 还原成普通 toggle），走菜单栏 Quit 或 Cmd+Q——那条路径触发 `applicationWillTerminate` → `TriggerRemap.revertAtQuit()`。

### 3.2 Caps Lock 在各状态的行为（统一 arm）

| 操作 | OFF | TAP | TAP sticky | SCROLL | palette 开 |
| --- | --- | --- | --- | --- | --- |
| Caps Lock 单击（松手无 chord） | 进 TAP | 切 sticky | 切回非 sticky | 切回 TAP | 关 palette |
| Caps Lock 按住 + j/k | 进 SCROLL | 进 SCROLL | 进 SCROLL | （重进 SCROLL） | — |
| `Esc` | — | deactivate | deactivate | deactivate | deactivate |
| 菜单栏 Quit / Cmd+Q | quit 进程 | quit 进程 | quit 进程 | quit 进程 | quit 进程 |

Caps Lock + Shift/Cmd/Ctrl/Option（修饰键）→ 不 arm，放行给系统/用户。

`VimSession.enter()`：**同步**设 `mode = .tap(h)`（消除连按 race，见 §2.1），再异步 `h.activate()` 扫描 + 显示 overlay。三个来源都空时显示 "no hints here" 并退出。

---

## 4. TAP mode 键位

| 键 | 行为 |
| --- | --- |
| `a s d f g h e r u` | 输入 hint 标签字母（9 个；**注意不含 i/j/k/l**） |
| `0–9` | 输入 hint 标签数字（Dock 专用） |
| `Shift + 末位字符` | 双击 |
| `Option + 末位字符` | 右键点击 |
| `i / j / k / l` (bare) | **移光标** 上/左/下/右（IJKL 倒 T，按住连续，normal 速度） |
| `Shift + ijkl` | 加速移光标 |
| `Option + ijkl` | 精细移光标（慢速，精确落到小 icon） |
| `Enter` (bare) | 当前光标位置 **左键单击一次**（配 IJKL：移到位 → Enter 点击） |
| `Backspace` | 撤销上一个输入的 hint 字符（typed 空时无操作，不退出） |
| `Shift + ;` (= `:`) | 打开命令面板 |
| `Cmd / Ctrl + 任意键` | **放行**，不消费（保系统快捷键） |

为什么 hint 池没有 i/j/k/l：它们是 IJKL 移光标键，裸按一定是"移动"，不能再当 hint 字母（否则按 j 有歧义）。所以 `HintMode.alphabet` 移除 j/k/l（i 本就不在），补 e/r/u 维持 9 键。详见 §4.3。

为什么不用 Ctrl 做移动：power user（如 HHKB）常在系统层把 Ctrl+hjkl 映射成方向键，跟我们冲突。裸 IJKL 完全避开 Ctrl。

### 4.1 标签输入

每次按键：
1. `next = typed + char`
2. 过滤 `targets` 中 `label.hasPrefix(next)` 的：
   - 0 个匹配 → `.ignored`，**吞掉、不退出**（误按；typed 保持上一个有效值，Esc 才退出）
   - 1 个且完整匹配 → `.committed`，commit 后视 sticky 决定下一步
   - 多个 → `.pending`，刷新 overlay 展示剩余候选

提交点击的实现详见 `hint-rendering.md` 的 commit 部分。

### 4.2 Sticky

- 进入 TAP 时 `sticky = false`。
- Caps Lock 单击（松手无 chord）切换 —— 走 §2.1 的 arm 机制 + `handleTriggerTap()`，不在 `handleTap` 里。
- `.committed` 时如果 sticky：`deactivate()` 当前 HintMode → 构造新的 `HintMode()` → `activate()`，
  整套 hint 集合重新扫描（焦点 app 可能已经因为点击而变了）。

### 4.3 `Enter` —— 光标位置点击 + IJKL 移光标

`Enter` 与 IJKL 配套，构成 TAP 内的"键盘鼠标"：**IJKL 移光标对准，Enter 点击**。Enter 比原来的 `x` 更直觉（确认/点击）。

```swift
// Enter：当前光标位置左键单击一次
MouseSynth.click(at: MouseSynth.cursorPosition(), button: .left, count: 1)
// 点完按 sticky 分派：sticky → 重扫留 TAP；否则 → exit
```

- **`Enter`** = 在**当前鼠标光标位置**合成一次左键单击。落点 = 光标现在在哪。Enter 在 palette 里是"执行命令"，但 palette 拦截在前；hint 标签是字母/数字，Enter 不冲突；mode 激活时 Enter 被消费、不下发 app。
- **`i/j/k/l`** = 移光标（IJKL 倒 T：i 上、j 左、k 下、l 右），按住连续（60fps timer 合成 `.mouseMoved`，hover 状态会更新），Shift 加速 / Option 精细。实现见 `MouseMover.swift`。
- 合成点击/移动统一走 `MouseSynth`（HintMode 的 hint-commit 点击也用它）。

**历史**：`x` 曾是"dismiss 所有打开的菜单 + 重扫"手势（Dock 菜单 AXCancel + 焦点切换关浮层）。撞 OmniParser 异步化和"键盘鼠标"设计后改成现在的纯光标点击——更简单、跟 IJKL 移动闭环。旧的 `findOpenDockMenu` / `AXCancel` / `AXWait.appActivated` 那套已从代码移除。**关菜单能力丢失**（光标在控件上点会误触发），可接受。

---

## 5. SCROLL mode 键位

键盘滚动。完整设计见 [`scroll-mode-design.md`](scroll-mode-design.md)，这里是键位摘要。

| 键 | 行为 |
| --- | --- |
| `j` / `k` (bare) | 下/上滚（按住连续，60fps timer 合成 scroll wheel 事件） |
| `Shift + j/k` | 加速滚动 |
| `s/d/f/e` (bare) | 移光标 左/下/右/上（SDFE 倒 T，按住连续） |
| `Shift + sdfe` / `Option + sdfe` | 加速 / 精细移光标 |
| `Enter` (bare) | 当前光标位置左键单击（留在 SCROLL） |
| `数字键 1-9` | 切换选中的滚动区域 |
| Caps Lock 单击 | 切回 TAP（见 §2.1） |
| `Esc` | deactivate 回 OFF |

**移光标为什么用 SDFE，且跟 TAP 的 IJKL 不一致**：scroll 里 `j/k` 已是滚动，腾不出 IJKL。SDFE（e 上 / s 左 / d 下 / f 右，倒 T 中心在 d）让**左手不离 home row**——s/d/f 正是无名指/中指/食指的 home 位，e 只需中指上抬，不像 WASD 要小指够 'a'。左手移光标、右手滚动可**双手并行**。TAP 用 IJKL 是因为它的 home row `a/s/d/f` 要留给 hint 字母，scroll 没有 hint 所以 home row 空出来给移动。`Enter` 与 SDFE 配套（移→点闭环），复用 `MouseMover` / `MouseSynth`（与 TAP 同一套）。

> 两个模式移动键不同（TAP=IJKL、SCROLL=SDFE）是各自键位约束下的最优，暂时接受。日后会开放让用户自定义按键配置。

进入：任何 mode 按住 Caps Lock + j/k（chord）。进入时 `ScrollAreaDetector` AX-walk 焦点窗口找所有 `AXScrollArea` + `AXWebArea`，`ScrollOverlay` 画蓝色光晕边框 + 数字标记，默认选离光标最近的区域并 warp 光标进去（滚动事件按光标位置路由）。

零-AX app（a11y 关闭的 Electron，如 Claude 桌面）检测不到滚动区 → 退到窗口中心滚主内容，无区域 picker。识别不出的区域靠未来"键盘平移鼠标"兜底。

---

## 6. 命令面板键位

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

## 7. KeyCode 常量

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
| `a..l` | 0,1,2,3,5,4,38,40,37 | home row 9 键（注意 g/h 顺序：g=5, h=4） |
| `i` | 34 | TAP 内 IJKL "上"（在上排，非 home row） |
| `q..p` | 12,13,14,15,17,16,32,34,31,35 | 上排（`e=14 r=15 u=32` 现作 hint 字母补位） |
| `z..m` | 6,7,8,9,11,45,46 | 下排（含 `b=11`, `n=45`, `m=46`） |
| `1..0` | 18,19,20,21,23,22,26,28,25,29 | 数字（注意 5=23, 6=22；7=26, 9=25） |
| `arrow*` | 123–126 | left/right/down/up，给未来 select-text mode |

**键位用途速查**（TAP mode）：`i/j/k/l` = IJKL 移光标；hint 字母 = `a s d f g h e r u`（不含 ijkl）；`x` = 点击；数字 = Dock hint / SCROLL 切区域。

---

## 8. 修饰键策略汇总

| 修饰键 | 在 TAP mode 内的行为 | 为什么 |
| --- | --- | --- |
| `Cmd` | 整个事件放行 | 保 Spotlight / Cmd+Tab / 截屏 / 关窗口等 |
| `Ctrl` | 整个事件放行 | 保 Mission Control / Ctrl+↑ 等；也因为 power user 把 Ctrl+hjkl 当方向键 |
| `Shift` | 消费 —— hint 末位字符 = 双击；移光标键(IJKL/SDFE) = 加速 | 高频动作配顺手修饰键 |
| `Option` | 消费 —— hint 末位字符 = 右键；移光标键 = 精细慢速 | 移光标键非 hint 字母，Option 不冲突 |

放行 vs 消费在 `VimSession.handle()` 顶部判断（`flags.intersection([.maskCommand, .maskControl]).isEmpty`）；IJKL 移动额外要求不含 Cmd/Ctrl/Option（只允许 Shift 加速）。

---

## 9. 新 mode 接入路径

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
