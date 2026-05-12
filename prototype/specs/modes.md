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
[OFF] --press ` (no mods)--> [TAP, sticky=off]
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
   press `              press : (Shift+;)         press hint letter
   toggles sticky        opens palette             │
        │                     │                ┌───┴────────┐
        ▼                     ▼              .pending   .committed
   [TAP, sticky=on]      [TAP + palette]      │             │
                              │              stay      sticky?
                              ▼                          ├── on  → re-scan, stay TAP
                         <CR> = run                      └── off → exit
                         <BS> on empty = close
                         <BS> on non-empty = pop char
                         esc = exit Mouseless (always)
```

**Esc 永远完全退出 Mouseless**，不只是退出面板或退出 sticky。
要关面板就在空 buffer 上按 Backspace。

---

## 3. 进入 / 退出

| 键 | 状态 | 行为 |
| --- | --- | --- |
| `` ` `` (bare) | OFF | 进入 TAP mode，立即扫描并显示 hints |
| `` ` `` (bare) | TAP | 切换 sticky |
| `Esc` | TAP / palette | **完全退出** Mouseless |

`` ` `` + 任意修饰键放行：Cmd+`` ` ``（切窗口）、Shift+`` ` ``（输入 `~`）、Ctrl/Option+`` ` ``（让位给其他 app 绑定）。

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
- bare `` ` `` 切换。
- `.committed` 时如果 sticky：`deactivate()` 当前 HintMode → 构造新的 `HintMode()` → `activate()`，
  整套 hint 集合重新扫描（焦点 app 可能已经因为点击而变了）。

### 4.3 `x` —— 点空白处

```swift
if keyCode == KeyCode.x && flags.intersection(modMask).isEmpty {
    hint.deactivate()
    NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(80))
        // re-scan ...
    }
}
```

为什么不直接合成 Esc？很多 app 把 Esc 绑了别的语义：
- vim normal mode 已经在 normal mode 时 Esc 是 no-op，但 insert mode 时是切 mode
- 对话框 cancel
- terminal escape sequence
- 全屏视频退出

激活 Finder = 物理上点击桌面壁纸的效果：前一个 app 失焦、菜单/popover 关闭、Finder 成 frontmost，**没有合成键盘事件**，所以没有上述副作用。

80ms 延迟是因为 `activate` 是异步的 —— `AXFocusedApplication` 不会立刻指向 Finder，立刻 re-scan 会拿到旧 app 的元素。
`Task` 包起来还有个作用：把扫描挪出 event tap callback，避免 callback 超时（见 `event-pipeline.md`）。

---

## 5. 命令面板键位

| 键 | 行为 |
| --- | --- |
| 字母 a–z | 追加到 buffer |
| `Backspace` on non-empty | 删一个字符 |
| `Backspace` on empty | **关闭面板**，回到底层 mode |
| `Return` | 执行命令 |
| `Esc` | **完全退出** Mouseless（即使面板打开） |

注意面板**只接字母**（`letterChar(for:)` 显式只列 a–z）。数字 / 符号会被忽略。原因：当前命令都是
字母短串（`q`、未来的 `st`、`dr`），让用户少思考"这个键是不是命令"。

### 当前命令

| 命令 | 行为 |
| --- | --- |
| `q` | 退出 Mouseless |
| 其他 | buffer 清空，**面板保持打开**，让用户继续输 |

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
| `grave` | 50 | `` ` `` / `~` —— 触发键 |
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
