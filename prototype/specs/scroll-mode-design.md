# Scroll 模式设计

> 键盘驱动滚动，对标 Homerow 的 scroll。独立于 hint（TAP）模式的第二个交互模式。

相关文件（实现后）：`ScrollAreaDetector.swift`、`ScrollOverlay.swift`、`ScrollController.swift`、`HotkeyTap.swift`（chord 检测）、`VimSession.swift`（mode 状态机）。

## 1. 目标

- 按键进入滚动模式，j/k 上下滚动焦点 app
- 按住 j/k 连续滚，Shift+j/k 加速
- 多个可滚区域时，能选要滚哪个
- 不依赖鼠标——纯键盘

## 2. 进入模型：chord vs tap

Caps Lock（已 hidutil 重映射成 F19）一个键承担两种进入：

```
OFF
 ├─ Caps Lock 单击（按下→松开，中间没按 j/k）→ TAP 模式（扫描 + hints）
 └─ Caps Lock 按住 + j/k                      → SCROLL 模式（无扫描、无 hints）
```

**为什么 chord 进入而非"TAP 里按 j/k"**：scroll 模式**没有 hints**（hints 是 TAP 模式才扫描出来的）。chord 直接进 SCROLL，**完全不触发 AX/OP 扫描**——省 100-200ms，也不闪一下 hints。

### 2.1 关键机制：TAP 进入时机从 keyDown 改到 keyUp

要区分"单击"和"chord"，F19 按下时**不能立即进 TAP**——得等，看后面有没有 j/k：

```
F19 keyDown（bare，无其他修饰键）:
    armed = true, chordUsed = false
    消费（return nil）

armed 期间 j/k keyDown:        # F19 仍按住
    进入 SCROLL 模式
    chordUsed = true
    消费

F19 keyUp:
    if armed:
        if !chordUsed: 进入 TAP 模式（现在才扫描 + 出 hints）
        armed = false
    消费
```

**代价**：TAP 在 F19 松手时进入，比现在（按下即进）晚一个"按住时长"——单击约 50ms，感知不到。

**收益**：scroll chord 完全不触发扫描（不会先进 TAP 扫一遍再切走）。

需要给 event tap 加 **keyUp 处理 + F19 held 状态跟踪**（keyUp 做连续滚动本来也要加）。

### 2.2 j/k 不从 hint 字母池删除

scroll 由 chord 进入，**不是** TAP 里按 j/k。所以 TAP 模式里 j/k 仍是正常 hint 字母，**字母池保持 9 个不变**（a s d f g h j k l）。

（早期讨论过"删 j/k 补 e/i"——那是基于"j/k 在 TAP 内即滚"的旧模型，chord 模型下作废。）

### 2.3 chord 只进入，不滚动

Caps Lock+j 和 Caps Lock+k **等价**——都只是"进 SCROLL 模式"，**不触发滚动**。进模式后，**再按 j/k** 才开始滚。chord 里的 j 还是 k 不决定方向。

## 3. SCROLL 模式状态机

```
SCROLL 模式：
    显示 scroll overlay（见 §5）
    j 按住 → 连续下滚，松开停      （Shift+j 加速）
    k 按住 → 连续上滚，松开停      （Shift+k 加速）
    松开 j/k → 停止滚动，**不重扫**，留在 SCROLL
    数字键 1-9 → 切换选中区域
    Caps Lock → 切到 TAP 模式（这时才扫描 + 出 hints）
    Esc → 退出到 OFF
```

### 3.1 松开 j/k 不自动重扫

滚动**不触发任何重扫**。滚完想 hint-click，按 **Caps Lock 显式切到 TAP**（扫描当前位置 + 出 hints）。重扫永远是用户主动触发（Caps Lock），不自动发生。

## 4. Scroll area 检测：只认 AX

### 4.1 为什么只用 AXScrollArea（+ AXWebArea）

滚动区是**容器**，没有可靠视觉特征——OP（找可点元素）识别不了。窗口中心 / 视觉启发式都不靠谱。**唯一可靠的是 AX 的 `AXScrollArea`**（+ web 内容的 `AXWebArea`）。

关键：**scroll area 检测永远走 AX，跟"可点元素用 AX 还是 OP"的路由无关**。即使 WeChat 这种路由到 OP 的 app，它的滚动容器（NSScrollView）仍是 `AXScrollArea`、AX 看得见——结构 AX 可靠，内容 AX 才瞎（见 `omniparser-fallback-design.md` §4.2 同款逻辑）。

| app | 滚动区 AX role | 能否检测 |
| --- | --- | --- |
| 原生（WeChat / Finder / Mail）| `AXScrollArea` | ✓ |
| Safari / WKWebView | `AXWebArea` | ✓ |
| Electron（开了 renderer accessibility 的，如 VS Code）| `AXWebArea` / `AXScrollArea` | ✓ |
| Electron（默认关 AX 的）/ 游戏 / 纯自渲染 | 无 | ✗ |

### 4.2 识别不出怎么办：靠未来的"键盘平移鼠标"

AX 认不出的区域（零 AX 的 Electron / 游戏）**不做兜底 hack**。未来会有"键盘平移鼠标"功能——用户手动把光标移到目标区域，再 j/k 照样发滚动指令（滚动事件路由到光标底下的 view）。

所以 v1：**AXScrollArea 能认的精确认，认不出的留给未来人力补**。当前实现里认不出时退到焦点窗口中心（至少主内容区能滚），不画 overlay。

#### 试过但无效：AXManualAccessibility 唤醒 Electron

Chromium/Electron 默认关 AX 树。理论上在 app 的 AX 元素上设 `AXManualAccessibility = true`（辅助技术唤醒 Chromium a11y 的标准信号）能让它建完整 AX 树。**实测在 Claude 桌面 app（Electron）上无效**——设了之后多次重试，AX role census 仍然从窗口往下全是 `AXGroup`，没有冒出 `AXScrollArea`/`AXWebArea`。

可能原因：该版本 Electron 没接 `AXManualAccessibility`、或需要更早设置（app 启动时而非运行时）、或需配合 `AXEnhancedUserInterface`（但后者会让 app 以为 VoiceOver 开了，可能改变行为/出 bug，不敢轻易用）。

**结论**：不靠这个。零-AX Electron 的 scroll 区域识别留给"键盘平移鼠标"兜底。**别再试 AXManualAccessibility 这条路**（除非有证据某些 Electron 版本响应）。

诊断：检测到 0 区域时会打 `[mouseless] scroll: 0 areas — AX role census: ...`，能区分"app 零-AX"（全 AXGroup）vs"我们 BFS 漏了"（有 scroll role 但没抓到）。

### 4.3 检测时机 + 成本

进 SCROLL 模式时 walk 一次焦点窗口找 `AXScrollArea` + `AXWebArea`。只找容器 role、不下钻枚举内容 → depth-limited BFS，~10-30 IPC，几 ms。一次性（不是每次按键）。

## 5. 多区域 picker overlay

进 SCROLL 模式时：

- walk 出所有 scroll area
- **每个区域左上角画蓝底数字 label**（1, 2, 3...）
- **高亮每个区域的边框**（让用户清楚看到区域范围）
- **默认选离当前光标最近的区域**（高亮区分选中 vs 未选中）
- warp 光标到选中区域中心（确保滚动落在那）

用户操作：

- 直接 j/k → 滚默认（最近）区域
- 按数字键 → 切到那个区域（重新 warp 光标、更新高亮）

overlay 一直显示直到 Esc / 切 TAP（这样数字键随时可切区域）。

## 6. 滚动合成

```swift
let scroll = CGEvent(scrollWheelEvent2Source: src,
                     units: .pixel, wheelCount: 1,
                     wheel1: deltaY,   // 负=下滚，正=上滚
                     wheel2: 0, wheel3: 0)
scroll?.setIntegerValueField(.eventSourceUserData, HotkeyTap.syntheticMarker)  // 防自处理
scroll?.post(tap: .cghidEventTap)
```

- **连续滚**：keyDown 启动定时器（~16ms / 60fps），每次 post 小 delta → 平滑；keyUp 停定时器
- **Shift 加速**：加大 delta 或提高频率
- **光标定位**：`CGWarpMouseCursorPosition(areaCenter)`——滚动事件路由到光标底下的 view，所以滚前要把光标 warp 到目标区域

### 6.1 光标 warp 的 gotcha

`CGWarpMouseCursorPosition` 之后可能有短暂的鼠标移动 freeze / 位置上报滞后。我们的用法（warp 完即 post 滚动）不受影响，但要知道。若出问题加 `CGAssociateMouseAndMouseCursorPosition(true)`。

## 7. 组件分解

| 组件 | 职责 |
| --- | --- |
| `HotkeyTap` | F19 armed 状态机 + keyUp + chord 检测；分发到 TAP / SCROLL |
| `VimSession` | Mode enum 加 `.scroll`；scroll 模式的按键分发 |
| `ScrollAreaDetector` | AX walk 找 AXScrollArea + AXWebArea，返回各自 screen rect |
| `ScrollOverlay` | 画蓝底数字 label + 高亮边框（类似 HintOverlay 但样式不同）|
| `ScrollController` | 滚动合成 + 定时器 + 光标 warp + 区域选择状态 |

## 8. v1 scope

做：
- chord 进入（F19 armed 状态机，TAP 改 keyUp 进入）
- AXScrollArea + AXWebArea 检测
- 多区域 overlay（数字 + 边框 + 最近默认）
- 按住连续滚 + shift 加速
- 数字键切区域
- Caps Lock → TAP，Esc → OFF
- 松开 j/k 不重扫

暂不做（defer）：
- 键盘平移鼠标（认不出区域的兜底）—— 独立大功能，单独做
- 横向滚动（h/l）—— 用户只要纵向
- 半页 / 整页 / 顶底跳转（d/u/g/G）—— 先 j/k + shift 加速够用
- 平滑动量 / 惯性滚动 —— 先匀速连续

## 9. 待实现时确认的边角

- armed 期间按非 j/k 键（如 F19+a）：v1 倾向 pass-through，遇到 stray char 再收紧
- 多区域"最近"的度量：光标在某区域内 → 距离 0；在外 → 到边缘最近距离
- 区域嵌套（scroll area 套 scroll area）：取最大？还是都列出来让用户选？v1 先都列，观察
