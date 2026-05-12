# Hint Rendering & Click Commit

标签生成、用户输入到提交点击、overlay 绘制、HUD 提示。

相关文件：`HintMode.swift`（生成 + commit + synth click），`HintOverlay.swift`，`HUD.swift`。

---

## 1. 标签生成

`HintMode.alphabet`：
```swift
static let alphabet: [Character] = ["a","s","d","f","g","h","j","k","l"]
```
home row 9 个字母（顺序按物理位置左→右，不是字母表序）。

**字母组**（焦点 app + menu extras 共享）：
- count ≤ 9：单字母 `a, s, d, f, g, h, j, k, l`
- count > 9：两字母 `aa, as, ad, ..., ll`（9 × 9 = 81 个组合，再多就溢出尾部，不报错）

**数字组**（Dock 独享）：
- count ≤ 10：单字符 `0, 1, ..., 9`
- count > 10：两字符 `00, 01, ..., 99`

字母 / 数字独立空间的好处：用户输入 `a` 立刻锁定字母组，输入 `1` 立刻锁定 Dock，前缀不会撞。

两字母 / 两数字标签的好处：第一字符过滤一次，第二字符才提交，错按时前缀不匹配立即 `.cancelled` 而非误触发。

排列顺序：Dock targets 先入 `targets` 数组，非 Dock 后入。**这只影响内部数组顺序**，绘制完全按 target 自己的 rect 定位。

---

## 2. Typing → Commit 状态机

`HintMode.handle(char:action:)`：

```swift
let next = typed + String(char)
let matches = targets.filter { $0.label.hasPrefix(next) }
if matches.isEmpty {
    deactivate()
    return .cancelled
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
- `.cancelled` —— 直接 exit（"你按错了，退出 mode 别瞎点"）

---

## 3. Commit：AX 动作 vs 合成点击

```swift
private func commit(target: HintTarget, action: ClickAction) {
    let center = CGPoint(x: target.rect.midX, y: target.rect.midY)
    switch action {
    case .left:
        if AXUIElementPerformAction(target.element, "AXPress" as CFString) != .success {
            synthesizeClick(at: center, button: .left, count: 1)
        }
    case .right:
        if AXUIElementPerformAction(target.element, "AXShowMenu" as CFString) != .success {
            synthesizeClick(at: center, button: .right, count: 1)
        }
    case .double:
        synthesizeClick(at: center, button: .left, count: 2)  // 没有 AX 等价物
    }
}
```

**为什么优先用 AX 动作？** AX 是**语义化**的：
- 不依赖元素当前是否被遮挡
- 不依赖元素是否在屏幕可见区域
- 不需要先移动鼠标（鼠标可以留在原地）
- 不需要焦点切换

合成 mouse event 必须把鼠标移到元素中心 —— 期间被任何浮层遮挡都会点错对象。所以 AX 动作能成功就用 AX。

回退路径（合成）必须存在的原因：
- 有些 app 的 AX 元素**不实现 AXPress** —— 比如 Electron 默认 AX 实现就是稀薄的。
- 有些 AXButton 报 success 但实际没反应（buggy AX 实现）—— 这个目前没法事前检测，只能 fallback 不可达。

`.double` 没有 AX 等价物。`AXIncrement / AXDecrement / AXShowAlternateUI` 都不是双击语义。所以双击永远走合成路径。

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
    w.level = .statusBar               // 25
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
| `.mainMenu` | 24 | 顶部菜单栏 |
| `.statusBar` | **25** | **我们的 overlay** + HUD |
| `.popUpMenu` | 101 | 下拉菜单 / popover |

选 `.statusBar` 的语义：高于菜单栏 + 普通窗口（hints 能盖住下方）；**低于** popup menu（下拉菜单打开时盖住 hints —— 这是 desired，跟"下拉菜单覆盖下方 app 内容"一致的 z-order 期望）。

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

## 7. 三种 badge 排版

`HintOverlayView.draw` 用 `target.role` 和 `target.label` 分流到三个分支。

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

Badge 居中对齐文字（其他两种是左对齐）。

### 7.2 `AXMenuItem`（下拉菜单项）

菜单项是窄长条**纵向堆叠**的，下方紧贴下一项。所以 badge 不能放下方，否则盖到相邻菜单项。

默认放**左侧**（尾巴向右指向菜单项），左侧超出屏幕回退到**右侧**。

**级联菜单特殊处理**：parent menu 打开 + submenu 打开时，submenu 项的左边是 parent menu 的窗口（`.popUpMenu` = 101，高于我们的 `.statusBar` = 25），会**遮住**画在那里的 badge。

检测策略：扫所有 `AXMenuItem` 同伴，看是否存在**严格在左侧的列**（其他 menu item 的 `maxX <= 当前 origin.x`）或**严格在右侧的列**：

```swift
var hasLeftSiblingMenu = false
var hasRightSiblingMenu = false
for other in targets where other.role == "AXMenuItem" {
    if other.rect == r { continue }
    if other.rect.maxX <= r.origin.x { hasLeftSiblingMenu = true }
    if other.rect.minX >= r.origin.x + r.size.width { hasRightSiblingMenu = true }
}
```

放置决策：
- `hasLeftSiblingMenu && !hasRightSiblingMenu` → parent 在左 → badge 放**右**
- `hasRightSiblingMenu && !hasLeftSiblingMenu` → parent 在右（右锚点 status menu 级联向左） → badge 放**左**
- 独立菜单（或夹在中间，极少见）：默认左，回退右

**`contains` vs `intersects`**：用 `viewBounds.contains(rect)` 严格判断"badge 完整在屏幕内"，不用 `intersects`。部分超出会被裁剪不可读。

### 7.3 其他（普通按钮 / 链接 / status icon）

Badge 22×16 矩形 + 尾巴三角。默认**下方**（尾巴指上），不 fit 翻**上方**（尾巴指下）。同样用 `contains` 判断 fit。

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

如果某个 target 的矩形不在当前 view 的 bounds 上（比如焦点 app 在另一块屏），三种分支都会 `continue` 跳过绘制。
这就是为什么每屏一个独立的 HintOverlayView：每个 view 只画落在自己屏幕上的 hints，自动分流。

判断：
```swift
if !self.bounds.intersects(fillRect) { continue }
```
注意是 `intersects` 不是 `contains` —— 跨屏边界的元素在两块屏上各画一半也比都不画好。
