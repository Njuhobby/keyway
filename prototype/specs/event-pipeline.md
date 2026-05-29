# Event Pipeline

事件从硬件到 mode 的传递路径。覆盖 `HotkeyTap` 的拦截策略、反馈环避免、修饰键透传规则。

相关文件：`HotkeyTap.swift`, `KeyPoster.swift`, `HintMode.swift` 末尾的 `synthesizeClick`。

---

## 1. CGEventTap 注册

```swift
let mask = (1 << CGEventType.keyDown.rawValue)
         | (1 << CGEventType.keyUp.rawValue)        // F19 arm resolve + scroll/move stop
         | (1 << CGEventType.flagsChanged.rawValue)
CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,         // 可阻断事件，不只是观察
    eventsOfInterest: CGEventMask(mask),
    callback: callback,
    userInfo: Unmanaged.passUnretained(self).toOpaque()
)
```

- `cgSessionEventTap` —— 会话级，所有 app 的事件都过这里。
- `headInsertEventTap` —— 插在最前面，比其他 tap 早一步看到事件。
- `.defaultTap` —— 可以返回 `nil` 吞掉事件。**这就是消费按键的物理机制。**
- Callback 跑在注册时所在 run loop 的线程。我们把它附加到主 run loop，所以 callback 永远在 main 线程上，可以
  用 `MainActor.assumeIsolated` 安全调主-actor 方法。

启动失败常见原因：Accessibility 未授权。`CGEvent.tapCreate` 返回 `nil`，AppDelegate 把菜单栏图标改成 `M⚠`。

---

## 2. Callback 的三层 short-circuit

进入 `handle(type:event:)` 后按顺序判断，**越早 return 越省事**：

### Layer 1：Tap 自愈

```swift
if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
    return passUnretained(event)
}
```

系统会在两种情况下自动禁用 event tap：
- **timeout** —— callback 跑得太慢（默认上限 ~1s）
- **user input race** —— 用户在 callback 跑的同时还在敲键盘

被禁用后我们再调一次 `tapEnable` 续上，事件本身放行。

> 这就是 `VimSession.handleTap` 里 `x → Finder` 必须把 AX 扫描扔进 `Task` 而不是同步跑的原因：80ms 的 sleep + 一次完整 hint 收集，
> 如果在 callback 里同步执行就会触发 timeout disable，tap 挂掉。

### Layer 2：合成事件穿透（反馈环避免）

```swift
if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
    return passUnretained(event)
}
// syntheticMarker = 0x4D4F5553  ("MOUS")
```

我们自己 post 的事件（合成点击、KeyPoster）都打这个标记。callback 一眼识别，立刻放行 ——
否则会进入下一层判断逻辑，把合成的字母键当成 hint 输入再次拦截，形成循环。

**所有未来要合成事件的代码必须打这个标记。** Marker 定义在 `HotkeyTap.syntheticMarker`，
`nonisolated` 暴露出来，任何 actor context 都能用。

### Layer 3：keyUp 处理 + 非 keyDown 放行

```swift
if type == .keyUp {
    // F19 release resolves the arm（见 §3）；其他键的 keyUp 路由给
    // session（scroll / hjkl move 的 stop）。
    ...
}
guard type == .keyDown else { return passUnretained(event) }
```

事件 mask 订了 `keyDown` + `keyUp` + `flagsChanged`。keyUp 不再无脑放行——它要 (a) 解析 F19 arm（松手分派），(b) 把 j/k/i/l 等的释放交给 `session.handleKeyUp`（停止连续滚动 / 连续移光标）。`flagsChanged` 仍直接放行（mask 订它只为避免某些组合下 macOS 不发 keyDown）。

---

## 3. 触发键判定：F19 arm 机制（所有 mode）

F19（= Caps Lock）**不在按下时立即动作**，而是 **arm**（待命），等松手或等 chord。这让一个键兼多职（单击进 TAP / 切 sticky / SCROLL→TAP，按住+jk 进 SCROLL）。完整交互见 `modes.md` §2.1。

```swift
// keyDown
if keyCode == KeyCode.f19 && flags.intersection(modifierMask).isEmpty {
    f19Armed = true; f19ChordUsed = false
    return nil                              // 吞掉，先不动作
}
if f19Armed && (keyCode == KeyCode.j || keyCode == KeyCode.k) {
    f19ChordUsed = true
    session.enterScroll()                   // chord → SCROLL（任何 mode）
    return nil
}
if session.isActive {
    return session.handle(...) ? nil : passUnretained(event)
}
return passUnretained(event)

// keyUp
if keyCode == KeyCode.f19, f19Armed {
    let wasChord = f19ChordUsed
    f19Armed = false; f19ChordUsed = false
    if !wasChord { session.handleTriggerTap() }   // 松手无 chord → 按 mode 分派
    return nil
}
```

**arm 覆盖所有 mode，不只 OFF**——这是"TAP 内 Caps Lock+d 也能进 SCROLL"和"连续 Caps Lock 进 sticky"的根（旧实现 arm 只在 OFF，导致这两个失效，见该 commit）。

**bare F19**（无任何修饰键）才 arm。F19 不是物理键盘上真实存在的键——靠 `hidutil` 把物理 **Caps Lock** 重映射成 F19，**由 app 在启动时自动调用** `TriggerRemap.applyAtLaunch()`（见 `SPECS.md` §2.1）。用户零配置。

为什么不直接监听 Caps Lock：macOS 把 Caps Lock 当**modifier**而不是普通键处理。事件流里 Caps Lock 只发 `flagsChanged` 事件改 `.maskAlphaShift` flag，不发 `keyDown`。CGEventTap 拿到的"按下 Caps Lock"是一个 flag change，**没有 keyCode 可以匹配**，而且 Caps Lock 的 toggle 语义（按一次锁定、再按一次解锁）也不符合"瞬时触发"的需求。

hidutil 重映射改的是 **HID usage code**（在事件进入 macOS 的 modifier 处理逻辑之前），重映射后系统看到的是普通的 F19 keyDown，走标准 keyboard 事件流，event tap 拿得到，且没有 toggle 状态。

留 modifier mask 检查是给未来用户保留"Shift+F19 / Cmd+F19"绑别的快捷键的空间。F19 本身没有任何 app 用，"Hyper key" 范畴。

F19 的 keyDown 和 keyUp 都**消费** —— 不下发到下层 app，否则下层会收到孤立的 F19 keypress。

---

## 4. 激活后的事件流

```swift
return session.handle(keyCode: keyCode, flags: flags)
    ? nil                                   // 消费
    : passUnretained(event)                 // 放行
```

`session.handle` 的返回值决定该事件是否下发到下层 app。两条放行规则在 `VimSession.handle()` 顶部：

### 4.1 Cmd / Ctrl 透传

```swift
if !flags.intersection([.maskCommand, .maskControl]).isEmpty {
    return false
}
```

带 Cmd 或 Ctrl 的事件**永远放行**。这保了：
- Cmd+Space → Spotlight
- Cmd+Tab → app 切换
- Cmd+Shift+4 → 截屏
- Cmd+Q → 退出 app
- Ctrl+↑ → Mission Control
- Cmd+W → 关窗口

历史踩过的坑：Mouseless 激活期间 Cmd+Space 失效，用户被锁在 mode 里。

### 4.2 Shift / Option 不透传

这两个**消费**，因为它们承载 hint click action 语义：
- `Shift + 标签末位` → 右键点击（`AXShowMenu` 或合成右键）
- `Option + 标签末位` → 双击（合成两次 mouseDown/Up，`mouseEventClickState` = 1, 2）

---

## 5. 合成事件

两个出口：`HintMode.synthesizeClick`（鼠标）和 `KeyPoster.post`（键盘）。

共同套路：

```swift
let src = CGEventSource(stateID: .privateState)
// ... 构造 down / up ...
for ev in [down, up] {
    ev.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
    ev.post(tap: .cghidEventTap)
}
```

要点：
- `CGEventSource(stateID: .privateState)` —— 独立的事件状态，不污染系统全局 modifier flags。
- `setIntegerValueField(.eventSourceUserData, ...)` —— 打 `"MOUS"` 标记。
- `.post(tap: .cghidEventTap)` —— 投到 HID 层最前端，所有 tap（包括我们自己的）都能看到。

双击的关键：`.mouseEventClickState` 字段，第一对设 1，第二对设 2。系统据此识别双击。

`KeyPoster` 目前没有在主路径使用。API 留给未来 select-text mode（合成方向键）。

## 7. 异步事件等待（`AXWait`）

`x` 路径里需要等 `finder.activate()` 真正落地（焦点切到 Finder）—— 不用固定 sleep，走 `AXWait.appActivated`：

```swift
AXWait.appActivated(bundleID:timeoutMs:) async -> Bool       // NSWorkspace 通知
```

底层用 `withCheckedContinuation` 桥接 `NSWorkspace.didActivateApplicationNotification` 到 async/await。返回 `true` = 通知触发，`false` = 超时兜底。如果 app 已经是 frontmost，立即返回 true，不挂起。

实现细节（`AXWait.swift`）：
- `OneShot` —— 防 callback 和 timeout 同时 resume 导致 continuation 双 resume crash
- `Box<T>` —— `@unchecked Sendable` 引用胞，让 `@Sendable` callback 和 `@MainActor` timeout Task 共享 observer 引用（两者都跑在 main thread，但 Swift 类型系统看不出来）

兜底 timeout 是**防 silent failure** 的安全带，不是路径主线 —— OS 在极端情况下偶尔不发通知（已知 macOS 老毛病），timeout 让 Task 不至于永远挂起。详见 `modes.md` §4.3。

> 历史：早期版本还有 `AXWait.axNotification(_:on:pid:)` 用来等 Dock 菜单的 `kAXUIElementDestroyedNotification`。后来发现 Dock 在"焦点切换关菜单"路径下根本不发这个通知（element 被留着），改用 `AXUIElementPerformAction(menu, kAXCancelAction)` 直接同步触发 Dock 的完整清理路径，这个 helper 就用不上了，已删。

---

## 6. AX 调用与超时

不在事件 pipeline 主路径上，但相关：

- 默认 AX 消息超时 6s。卡死的 app 会拖慢扫描。
- **不要**用 `AXUIElementSetMessagingTimeout` 全局调低 —— 历史决策：会让正常但慢的 app 拿不到数据。
  正确的优化路径是减少需要 query 的元素总数（参考 `hint-discovery.md` 里的 MenuExtraCache 设计）。
