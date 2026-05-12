# Hint Discovery

哪些 UI 元素能被加上 hint，怎么找到它们。

相关文件：`HintMode.swift`（`collectAll`, `walk`, `collectDirectMenuExtras`），`MenuExtraCache.swift`。

---

## 1. 三个来源

`HintMode.collectAll()` 串行扫三组，结果分桶返回 —— 桶决定了标签字符集（数字 / 字母）。

```swift
struct CollectedElements {
    let focused: [ElementCandidate]        // 焦点 app 内的可点击元素
    let dock: [ElementCandidate]           // Dock 图标
    let menuBarExtras: [ElementCandidate]  // 菜单栏右侧 status icons
}
```

时序日志（每次触发都打）：
```
[mouseless] collect timings: focused=12ms dock=4ms extras=18ms
```

典型总耗时 < 50ms。慢的是 extras（多个 PID 串行 AX query），但比早期"遍历所有 app"的 5000+ms 改善了两个数量级。

---

## 2. 焦点 app（`focused`）

入口：
```swift
let sys = AXUIElementCreateSystemWide()
AXUIElementCopyAttributeValue(sys, "AXFocusedApplication" as CFString, &ref)
```

拿到焦点 app 的根 AX 元素，深度优先递归 `AXChildren`。

### 2.1 递归约束

- `maxDepth = 12` —— 深嵌套（如 Slack、网页）会超，能跳就跳。
- `maxTargets = 200` —— 单次扫描的硬上限。
- `skipRoles = {AXStaticText, AXImage, AXProgressIndicator}` —— 直接 return，**不进子树**。
  这些元素几乎永远不可点，递归代价又大（一个网页 AXStaticText 子树可能成千上万元素）。

### 2.2 收录条件

满足全部：

1. **role 在 `clickableRoles` 集合里**：
   ```
   AXButton, AXLink, AXMenuItem, AXMenuBarItem, AXMenuButton,
   AXCheckBox, AXRadioButton, AXPopUpButton, AXTab,
   AXDisclosureTriangle, AXDockItem, AXMenuExtra
   ```
   或 `AXUIElementCopyActionNames` 返回包含 `"AXPress"`。
2. `AXEnabled == true`（或属性不存在 —— 大多数原生 control 不显式标这个属性）。
3. 矩形 ≥ 8×8（伪元素过滤）。
4. **有可识别标签**（`hasMeaningfulLabel`）：`AXTitle / AXDescription / AXHelp / AXValue / AXSubrole`
   任一非空。
   - 例外：`AXDockItem / AXMenuBarItem / AXMenuExtra` 跳过这个检查（它们靠位置和 role 本身就能识别）。
   - 没有这条过滤的话，AX 会报很多"幻影"元素 —— 标签全空、app 实际没画 —— 导致 hint 出现在空白处。
5. 矩形与所有屏幕的 AX 坐标系并集相交（`onScreen`）。

### 2.3 屏幕并集计算

AX 用左上角原点 + Y 向下，NSScreen 用左下角原点 + Y 向上。`totalScreenSpan()` 把每块屏的 NSScreen frame 翻 Y 后取 union：
```swift
let axRect = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
```
`primaryH = NSScreen.screens.first.frame.height`。

返回 `nil`（无屏幕）时所有元素都算"在屏幕上"——降级行为而非崩溃。

---

## 3. Dock（`dock`）

```swift
if let dockApp = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock").first {
    let dock = AXUIElementCreateApplication(dockApp.processIdentifier)
    walk(element: dock, depth: 0, into: &dockOut, screenSpan: screenSpan)
}
```

复用同一个 `walk()`。Dock 不依赖焦点，永远扫。

Dock items 全部 role = `AXDockItem`，会被 `clickableRoles` 命中，且 `hasMeaningfulLabel` 对它免检。
所以 Dock 分隔符 / Recents 占位也会被收（用户体感是这俩通常没用，可以未来过滤）。

标签使用数字 `0..9`（详见 `hint-rendering.md`）。

---

## 4. Menu bar extras（`menuBarExtras`）

菜单栏右侧的 status icons。**这是踩坑最深的来源。**

### 4.1 踩坑史

为什么不能用其他更直接的 API：

| 尝试过的方法 | 失败原因 |
| --- | --- |
| `NSStatusBar.system.statusItems` | 只暴露**自己 app** 的 items，看不到别的 app |
| `CGWindowListCopyWindowInfo` 过滤菜单栏区域 | Sonoma+ 菜单栏渲染**集中到 Control Center 进程**，第三方 status item 不出现在 WindowServer 列表里。即使授了 Screen Recording 也没用。 |
| 硬编码常见 menu extra bundle ID 白名单 | 第三方（Bartender、Dropbox、各种 status app）漏掉 |
| 每次触发遍历所有 running apps 查 AX | 实测 5479ms，无法接受 |

最终方案：**`MenuExtraCache` 后台维护"哪些 PID 有 menu extras"的 PID 集合，触发时只查这些 PID。**

### 4.2 MenuExtraCache 设计

**预热（launch 一次，背景）：**
```swift
DispatchQueue.global(qos: .userInitiated).async {
    let allPIDs = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy != .prohibited
                  && $0.processIdentifier != ownPID }
        .map { $0.processIdentifier }
    DispatchQueue.concurrentPerform(iterations: allPIDs.count) { i in
        if appHasMenuExtras(pid: allPIDs[i]) { bag.add(allPIDs[i]) }
    }
    self.pids = bag.snapshot()
}
```

- **并行**：`concurrentPerform` 把 ~100 个 AX query 分发到多核，~500ms 完成。
- **背景**：`userInitiated` 优先级，不阻塞 UI。
- **时机**：AppDelegate 在 Accessibility 授权检查通过后立即 kick off，远早于用户首次按触发键。
- **最坏情况**：用户在预热完成前按了触发键 → 该次 collect 拿到不完整的 extras 集合。下一次正常。

**增量维护（NSWorkspace 通知，零轮询）：**
```swift
nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, ...) {
    self?.probeAndMaybeAdd(pid: app.processIdentifier, delay: 1.0)
}
nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, ...) {
    self?.remove(pid: app.processIdentifier)
}
```

- 新进程启动后**延迟 1s** 再 probe ——AX bridge 需要时间起来，立刻 probe 会假阴性。
- 进程退出立刻从集合 remove。

**`appHasMenuExtras(pid)` —— 廉价存在性检查：**

```swift
private static func appHasMenuExtras(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    var extrasRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
       extrasRef != nil {
        return true
    }
    // 遗留形态：根 AXChildren 里直接挂 AXMenuExtra
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXChildren" as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement]
    else { return false }
    for child in children {
        if let role = roleOf(child), role == "AXMenuExtra" { return true }
    }
    return false
}
```

只判断**有没有** extras，不枚举具体元素 —— 枚举留给 `HintMode.collectDirectMenuExtras` 每次触发时做。

### 4.3 触发期：`collectDirectMenuExtras`

```swift
for pid in MenuExtraCache.shared.currentPIDs() {
    let app = AXUIElementCreateApplication(pid)
    collectDirectMenuExtras(from: app, into: &extrasOut, screenSpan: screenSpan)
}
```

只查 cache 里的 ~10 个 PID，每个 AX query 都很快。串行总耗时 ~10–30ms。

`collectDirectMenuExtras` 两种 AX 树形态都接受：

**现代形态（Sonoma+ 常见）：**
```
appRoot.AXExtrasMenuBar (单独属性，不在 AXChildren 里)
    └── AXChildren
        ├── AXMenuBarItem  ← Apple 自家 agent / Control Center
        └── AXMenuExtra    ← 一些第三方
```

```swift
var extrasRef: CFTypeRef?
if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
   let extras = extrasRef {
    let bar = extras as! AXUIElement
    // 读它的 AXChildren，role == AXMenuBarItem || AXMenuExtra 都收
}
```

**遗留形态：**
```
appRoot.AXChildren
    ├── AXMenuBar
    └── AXMenuExtra   ← 直接挂根上
```

只在 `AXExtrasMenuBar` 缺失时检查这条路径。

> **关键陷阱**：`AXExtrasMenuBar` **不出现在 `AXChildren` 里**。最初的实现以为 menu extras 都是 root 的孩子，结果 Sonoma+ 全部漏掉 —— 因为 Sonoma+ 把它们放进了独立属性。两条路径都要查。

不递归 —— menu extras 都是顶层 status icon，子菜单（点开后展开的）要等用户点击后才进入 AX 树。

---

## 5. 并发安全

后台预热 `concurrentPerform` 跑 AX query，这意味着这些函数必须能在非 main 线程上跑：

- `MenuExtraCache.appHasMenuExtras` —— 静态函数，无状态，天然 OK。
- `HintMode.collectDirectMenuExtras`, `appendIfValid`, `roleOf`, `boundsOf`, `enabled`, `onScreen` —— 都标 `nonisolated`，因为它们只做 AX IPC + 局部 `inout` 写入，不碰 main-actor 状态。

`ElementCandidate` 持有 `AXUIElement`（CF 类型，refcounted + thread-safe），但 Swift 看不出来，所以标 `@unchecked Sendable`。

`MenuExtraCache` 用 `NSLock` 保护 `pids: Set<pid_t>`，类标 `@unchecked Sendable`：
```swift
func currentPIDs() -> [pid_t] {
    lock.lock(); defer { lock.unlock() }
    return Array(pids)
}
```

返回数组而不是直接暴露 `Set` —— 调用方拿到快照，迭代不受锁约束，新进程随时可以进 cache。

---

## 6. 调试

`debugDumpAXTree(element, depth, maxDepth)` 静态函数，递归打印任意 AX 元素的子树：role + rect + actions。
当扫描结果不对时（"为什么这个按钮没 hint?"、"为什么 menu extras 是 0?"），把它接到 `collectAll` 里手动调用一次，看树结构。

例如：
```swift
if let (focused, pid) = focusedApplication() {
    debugDumpAXTree(focused, depth: 0, maxDepth: 4)
}
```
