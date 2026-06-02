# Hint Rendering & Click Commit

标签生成、用户输入到提交点击、overlay 绘制、HUD 提示。

相关文件：`HintMode.swift`（生成 + commit + synth click），`HintOverlay.swift`，`HUD.swift`。

---

## 1. 标签生成

`HintMode.alphabet`：
```swift
static let alphabet: [Character] = [
    "a","s","d","f","g","e","r","u","i","o","p","w","t","n","m",
]
```
15 个字母。**不含 h/j/k/l/v/c**——h/j/k/l 在 TAP 和 SCROLL 里都是 hjkl 移光标键、`v` 在 TAP normal 里是"进 DRAG 子状态"触发键、`c` 是"点击当前光标位置"触发键，裸按它们都有专门含义、不能再当 hint 标签（见 `modes.md` §4 / §6）。除这六个外其它顺手字母都纳入。顺序按手感前置（左手 home row `a s d f g` 在前），因为单字母 label 用 `prefix` 取前缀、最短 label 最快 commit。

**历史**：池容量在 16/17/15 之间来回过几轮。`v` 曾短暂被纳入（17 字母，那是 DRAG 还是独立 mode、`Caps Lock + v` chord 进入时），DRAG 收编成 TAP 子状态、bare `v` 改成进 DRAG 触发键后又移除（16）。`c` 这一轮：原本是 Enter 当点击键、`c` 留在池里；Enter 经常跟 app 的菜单确认 / 表单提交冲突（被 Mouseless 吃掉），把 Enter 放行 + 点击挪到 bare `c` 后，`c` 也从池里移除（15）。

**字母组**（焦点 app + menu extras 共享），同一次扫描内所有标签**等长**——混长度会前缀冲突（"aa" 是 "aaa" 的前缀，用户输 "aa" 会卡住等第三字符）：
- count ≤ 15：单字母
- 16–225：两字母（15 × 15）
- 226+：三字母——**实际不可达**：`maxTargets` 是 200 < 225，所以任何一次扫描都落在 ≤2 字母。三字母分支只作 pool/cap 变动时的安全网。

**数字组**（Dock 独享）：
- count ≤ 10：单字符 `0, 1, ..., 9`
- count > 10：两字符 `00, 01, ..., 99`

字母 / 数字独立空间的好处：用户输入 `a` 立刻锁定字母组，输入 `1` 立刻锁定 Dock，前缀不会撞。

两字母 / 两数字标签的好处：第一字符过滤一次，第二字符才提交，错按时前缀不匹配 `.ignored` 吞掉（不误触发、也不退出）。

排列顺序：Dock targets 先入 `targets` 数组，非 Dock 后入。**这只影响内部数组顺序**，绘制完全按 target 自己的 rect 定位。

---

## 2. Typing → Commit 状态机

`HintMode.handle(char:action:)`：

```swift
let next = typed + String(char)
let matches = targets.filter { $0.label.hasPrefix(next) }
if matches.isEmpty {
    return .ignored          // 误按：吞掉，typed 不变，留在 TAP
}
if matches.count == 1 && matches[0].label == next {
    commit(target: matches[0], action: action)
    deactivate()
    return .committed
}
typed = next
HintOverlay.shared.show(targets: targets, typed: typed)
return .pending
```

三种返回值由 `VimSession.handleTap` 处理：
- `.pending` —— 啥也不做，等下一个键
- `.committed` —— 看 sticky：true 则 re-scan 进新 HintMode；false 则 exit
- `.ignored` —— 误按（不匹配任何 hint 前缀）：吞掉不退出，typed 保持上一个有效值。退出只靠 Esc。（另有 `backspace()` 撤销已输入的前缀字符。）

---

## 3. Commit：纯合成 mouse event

```swift
private func commit(target: HintTarget, action: ClickAction) {
    let center = CGPoint(x: target.rect.midX, y: target.rect.midY)
    switch action {
    case .left:
        synthesizeClick(at: center, button: .left,  count: 1)
    case .right:
        synthesizeClick(at: center, button: .right, count: 1)
    case .double:
        synthesizeClick(at: center, button: .left,  count: 2)
    }
}
```

**唯一通用 commit 机制 = 合成 mouse event 到 rect 中心**。简单、可预测、跟用户的心智模型 ("按 hint = 鼠标点这里") 一致。

### 3.1 为什么不用 AX 动作

早期实现是"AXPress 优先 / 合成兜底"。**已弃**——AX 动作不可靠到不值得放在主路径：

- **AX metadata 可靠**（元素存在、rect、role、label 这些是怎么找到 hint target 的根基）。
- **AX actions 不可靠**：很多 control 把 `AXPress` 暴露在 actions list 里但 handler 是 no-op 或语义不符——NSBrowser cell、NSTableRowView、自定义 NSView、Electron 的 AX bridge 都属于这一类。**实测足够多次"hint 出来按了没反应"的 case 才决定砍掉**。
- `AXShowMenu` 同样问题——某些元素暴露但调用不弹菜单。
- `AXOpen`（Finder desktop icon 用）同样问题——合成单击 + Finder 双击习惯就够了，不需要它。

### 3.2 砍掉 AX action 的 trade-offs

| 维度 | 老 AX-first 路径 | 新 synth-only 路径 |
| --- | --- | --- |
| 标准 control（Button / Link） | AXPress 命中 | synth 单击命中（鼠标实际点确实生效） |
| 自定义 / 复杂 control | AXPress 静默失败 → 不可预测的 fallback | synth 单击，跟真鼠标点同样的效果 |
| 被遮挡 / off-screen 的元素 | AX 能点 | 点不到 |
| 鼠标光标 | AX 路径不动；synth 路径会动 | **总是动到 click 点** |
| 失败模式 | 两种（AX 命中无效果 / synth 命中无效果），不好排查 | 一种（synth 命中无效果，element 本身的 hit-test 问题） |

被遮挡的元素丢了——但我们 `onScreen` 过滤本来就已经只保留可见元素。这个理论收益用不上。

光标会动——是个**好事**而不是坏事，符合"按 hint = 把鼠标放到那里点一下"的用户心智。

`.double` 跟之前一样——AX 就没有双击动作，永远走合成路径。

---

## 4. 合成点击实现

```swift
private static func synthesizeClick(at point: CGPoint,
                                    button: CGMouseButton,
                                    count: Int) {
    let src = CGEventSource(stateID: .privateState)
    let downType: CGEventType = (button == .left) ? .leftMouseDown : .rightMouseDown
    let upType: CGEventType = (button == .left) ? .leftMouseUp : .rightMouseUp

    for clickIdx in 1...count {
        let down = CGEvent(mouseEventSource: src, mouseType: downType,
                           mouseCursorPosition: point, mouseButton: button)!
        let up = CGEvent(mouseEventSource: src, mouseType: upType,
                         mouseCursorPosition: point, mouseButton: button)!
        for ev in [down, up] {
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(clickIdx))
            ev.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
            ev.post(tap: .cghidEventTap)
        }
    }
}
```

要点：
- `.mouseEventClickState` —— 双击的关键字段。第一对 down/up 设 1，第二对设 2。系统据此识别双击。
- `eventSourceUserData = "MOUS"` —— 让 HotkeyTap callback 放行（见 `event-pipeline.md`）。
- `CGEventSource(stateID: .privateState)` —— 隔离的事件源，不污染全局 modifier flags。

---

## 5. HintOverlay 窗口

```swift
for screen in NSScreen.screens {
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, ...)
    w.level = NSWindow.Level(rawValue: 102)   // CGOverlayWindowLevel, 高于 .popUpMenu = 101
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    w.contentView = HintOverlayView(...)
}
```

**每屏一个独立窗口**。曾经试过单窗口跨屏 union frame —— 在非主屏上会丢帧 / 不渲染。多窗口稳定。

### 窗口层级

| level | 数值 | 谁在这里 |
| --- | --- | --- |
| `.normal` | 0 | 普通 app 窗口 |
| `.modalPanel` | 8 | modal 弹窗 |
| `.mainMenu` | 24 | 顶部菜单栏 |
| `.statusBar` | 25 | 早期 overlay 用过这里 |
| `.popUpMenu` | 101 | 下拉菜单 / popover |
| `CGOverlayWindowLevel` | **102** | **我们的 overlay** + HUD |
| Assistive tech | 1500 | VoiceOver 等无障碍叠加 |

选 **102** 的语义：高于一切普通 UI 层（菜单栏、modal、`.popUpMenu` 下拉菜单），但低于 assistive tech，让 hint label 在打开的下拉菜单上也能可见——之前用 `.statusBar` (25) 时 AXMenuItem 的 inside-top-left label 会被菜单容器的背景填充盖掉（菜单容器在 101，label 画在 25 → 被覆盖）。代价是 hint label 也会画在 modal alert 之上，TAP mode 下这是想要的（hint-click alert 的按钮）。详见 §7.2。

`ignoresMouseEvents = true`：overlay 不消费鼠标，鼠标点击穿透到底层 app。

`canJoinAllSpaces + stationary + ignoresCycle`：跟随 Space 切换、不出现在 Mission Control 缩略图、不参与 Cmd+Tab。

---

## 6. 坐标系转换

三套坐标系打架：

| 系统 | 原点 | Y 方向 |
| --- | --- | --- |
| AX | 主屏左上角 | 向下 |
| NSScreen 全局 | 主屏左下角 | 向上 |
| NSView 局部 | 视图左下角 | 向上 |

`HintOverlayView.draw` 每个 target 都要转：

```swift
let primaryH = primary.frame.height
let winOrigin = win.frame.origin         // 当前屏的 NSScreen origin
let r = target.rect                      // AX 坐标
let nsGlobalY = primaryH - (r.origin.y + r.size.height)  // AX → NSScreen 全局 Y
let viewX = r.origin.x - winOrigin.x     // NSScreen 全局 → view 局部 X
let viewY = nsGlobalY - winOrigin.y      // NSScreen 全局 → view 局部 Y
```

`winOrigin` 是**这块**屏幕的 NSScreen origin —— 必须减掉才能落到本视图的局部坐标。

---

## 7. 四种 badge 排版

`HintOverlayView.draw` 按优先级分流：Dock（数字标签）→ AXMenuItem → **足够大的 rect 用 inside 放置** → 其余 speech bubble。

### 7.1 Dock items（label 首字符是数字）

Badge 是带尾巴的方块（20×20），画在图标**外侧**，尾巴指回图标。位置取决于 Dock 朝向：

```swift
let dockOrientation = UserDefaults(suiteName: "com.apple.dock")?
    .string(forKey: "orientation") ?? "bottom"
```

| orientation | badge 位置 | 尾巴方向 |
| --- | --- | --- |
| `bottom` | 图标上方 | 向下指 |
| `left` | 图标右侧 | 向左指 |
| `right` | 图标左侧 | 向右指 |

Badge 居中对齐文字（其他几种是左对齐）。

### 7.2 `AXMenuItem`（下拉菜单项）—— inside top-left

跟下面 §7.3 的大 rect 走**同一套 inside-top-left 放置**（rect 内部左上角、4pt 水平 inset、垂直贴顶、无尾巴）。早期版本另外做了一套"默认左、回退右、级联菜单特殊处理"的逻辑，统一到 inside 后那一堆"级联探测左右同伴列"代码全删掉。

**前提是 overlay 必须位于 `.popUpMenu` 之上**（level 102，见 §6）。原因：菜单项的视觉背景是**菜单容器**那个 `.popUpMenu` (level 101) 窗口画的，里面包括菜单项之间的描边、selected highlight 高亮。我们的 label 画在菜单项 rect 内部，如果 overlay 在 `.statusBar` (25) 层、低于菜单容器，菜单容器的背景填充就盖在 label 上面只剩空白；overlay 升到 102 后，label 那一小方块的黄底浮在菜单容器之上，其余区域（菜单文字 / icon / selected 高亮）由菜单容器自己画、透过 overlay 透明区显出来，互不打架。

**`contains` vs `intersects`**：用 `viewBounds.contains(rect)` 严格判断"badge 完整在屏幕内"，不用 `intersects`。部分超出会被裁剪不可读。

### 7.3 Inside 放置（足够大的 rect —— AX 和 OP 都适用）

非 Dock 的 target，只要 rect ≥ **30pt 宽 × 16pt 高**，badge 画在 rect **内部左上角**（水平 4pt inset，垂直贴顶，无尾巴）。AXMenuItem 也走这里（见 §7.2 的特殊说明）。

为什么：speech bubble（§7.4）+ 尾巴在密集列表（Finder 文件行、OP 聊天气泡）上会浮在相邻 rect 的间隙里，归属不清——badge 到底属于上面那行还是下面那行看不出来。放进 rect 内部，归属一目了然，那个又小又难看的尾巴也省了。

阈值由来：水平要 4pt×2 + 22pt 标签宽 = 30pt；垂直贴顶（0 inset），因为 Finder 日期/大小列的 AX rect 高仅 ~14-16pt，任何正垂直 padding 都会把它们踢回 speech bubble（恰是 inside 要解决的"浮在行间"老问题）。小于阈值的（工具栏小图标）落到 §7.4。

### 7.4 Speech bubble（rect 太小，放不下 inside）

Badge 22×16 矩形 + 尾巴三角。默认**下方**（尾巴指上），不 fit 翻**上方**（尾巴指下）。同样用 `contains` 判断 fit。只有小于 §7.3 阈值的 target 才走这里。

---

## 8. 视觉细节

```swift
let bg = NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 0.95)   // 黄底
let attrsBlack: ... = [NSColor.black, monospaced 11pt bold]        // 未输入部分
let attrsDim: ...   = [NSColor.black.withAlphaComponent(0.30), ...] // 已输入前缀
```

- **背景**：黄 α=0.95（高可见度，与多数 macOS UI 颜色冲突小）
- **字体**：monospaced 11pt bold，等宽确保两字符 label 宽度可预测
- **已输入前缀**：30% 黑（视觉淡化"已确认"的字符），未输入部分纯黑
- **圆角**：badge 矩形 xRadius/yRadius = 3
- **尾巴**：三角形，base ~8px，tip ~5px，跟 badge 用同一个黄色 fill

绘制 typed 部分 + rest 部分的对齐方式：
```swift
let typedSize = (typedPart as NSString).size(withAttributes: attrsDim)
let restSize = (restPart as NSString).size(withAttributes: attrsBlack)
let totalW = typedSize.width + restSize.width

if isDockLabel {
    textX = fillRect.midX - totalW / 2   // 居中
} else {
    textX = fillRect.minX + 3            // 左对齐 + 3px padding
}
```

---

## 9. HUD

独立的右下角 mode 提示窗口（不是 overlay 的一部分）。

```swift
let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 44), ...)
w.level = .statusBar       // 同 overlay
w.hasShadow = true         // overlay 没影子，HUD 有
w.ignoresMouseEvents = true
// 位置：主屏 visibleFrame 底部居中
w.setFrameOrigin(NSPoint(x: f.midX - 80, y: f.minY + 80))
```

文案在 `VimSession.renderModeHUD()` 统一计算：
- TAP mode → `"TAP"` 或 `"TAP · sticky"`
- 命令面板 → `":"`, `":q"`, `":xx"`

样式：半透明黑底（alpha 0.78），白字 14pt monospaced semibold，圆角 10px。

`orderFrontRegardless()`，**不**用 `makeKeyAndOrderFront`（后者会偷焦点 → 当前焦点 app 失焦 → AX 拿不到目标元素了）。

---

## 10. 跨屏元素

如果某个 target 的矩形不在当前 view 的 bounds 上（比如焦点 app 在另一块屏），各分支都会 `continue` 跳过绘制。
这就是为什么每屏一个独立的 HintOverlayView：每个 view 只画落在自己屏幕上的 hints，自动分流。

判断：
```swift
if !self.bounds.intersects(fillRect) { continue }
```
注意是 `intersects` 不是 `contains` —— 跨屏边界的元素在两块屏上各画一半也比都不画好。
