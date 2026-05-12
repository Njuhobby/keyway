# Event Pipeline

事件从硬件到 mode 的传递路径。覆盖 `HotkeyTap` 的拦截策略、反馈环避免、修饰键透传规则。

相关文件：`HotkeyTap.swift`, `KeyPoster.swift`, `HintMode.swift` 末尾的 `synthesizeClick`。

---

## 1. CGEventTap 注册

```swift
let mask = (1 << CGEventType.keyDown.rawValue)
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

### Layer 3：非 keyDown 放行

```swift
guard type == .keyDown else { return passUnretained(event) }
```

`flagsChanged` 进入这层就放行 —— mask 里订了它只是为了避免 macOS 在某些组合下不发 keyDown。
未来需要 modifier-only 触发可以改这里。

---

## 3. 触发键判定（未激活时）

```swift
if !session.isActive {
    let modifierMask: CGEventFlags = [.maskShift, .maskControl,
                                      .maskCommand, .maskAlternate]
    if keyCode == KeyCode.grave && flags.intersection(modifierMask).isEmpty {
        session.enter()
        return nil                          // 吞掉触发键本身
    }
    return passUnretained(event)            // 其他全放行
}
```

**bare `` ` ``**（无任何修饰键）才触发。原因：
- `Shift + `` ` `` = `~`，是普通字符
- `Cmd + `` ` ``` 是 macOS 系统 "下一个窗口" 切换
- Ctrl/Option + `` ` `` 也可能被其他 app 绑定

触发键命中后**消费**该按键 —— 不下发到下层 app，否则下层会收到一个 `` ` ``。

未来计划：迁移到 Caps Lock。物理上需要用户用 hidutil remap 或者 IOKit HID。代码侧只是改 keyCode。

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

`KeyPoster` 目前未在主路径用到，留给未来 select-text mode（合成方向键）。

---

## 6. AX 调用与超时

不在事件 pipeline 主路径上，但相关：

- 默认 AX 消息超时 6s。卡死的 app 会拖慢扫描。
- **不要**用 `AXUIElementSetMessagingTimeout` 全局调低 —— 历史决策：会让正常但慢的 app 拿不到数据。
  正确的优化路径是减少需要 query 的元素总数（参考 `hint-discovery.md` 里的 MenuExtraCache 设计）。
