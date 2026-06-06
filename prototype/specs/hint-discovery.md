# Hint Discovery

哪些 UI 元素能被加上 hint，怎么找到它们。

相关文件：`HintMode.swift`（`collectAll`, `walk`, `walkMenuBar`, `batchFetch`, `collectDirectMenuExtras`），`HintWindowCache.swift`，`MenuExtraCache.swift`。

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

时序日志（每次触发都打，含 IPC 计数和 cache 命中）：
```
[mouseless] collect timings: focused=53ms (270 IPC, 0 window cache hit) dock=5ms (38 IPC) extras=31ms
```

稳态总耗时 < 100ms。已知尖峰：destructive click（关弹框 / 关 sheet）后的第一次 sticky rescan 会落进目标 app 的 AX cleanup 窗口，per-IPC 延迟从 ~0.2ms 跳到 ~40ms —— 详见 §5。

---

## 2. 焦点 app（`focused`）

入口：
```swift
let sys = AXUIElementCreateSystemWide()
AXUIElementCopyAttributeValue(sys, "AXFocusedApplication" as CFString, &ref)
```

拿到焦点 app 的根 AX 元素，深度优先递归 `AXChildren`。

### 2.1 walk + 批量属性获取

`walk()` 深度优先递归，每个元素**只发一次 IPC**：用
`AXUIElementCopyMultipleAttributeValues` 一次拿 10 个属性
（role / enabled / position / size / title / description / help / value /
subrole / children），打包成 `BatchedAttrs` 结构体在内存里使用。详见
`HintMode.batchFetch`。

这是上一轮性能优化的核心改动。**老路径**每个元素 9+ 次独立
`AXUIElementCopyAttributeValue`，对 WeChat / Slack 这种几百节点的
AX 树就是几千次跨进程 RPC（焦点 app 扫描 ~840ms）；改批量后
同样的树是几百次（~200ms）。

约束：

- `maxDepth = 12` —— 深嵌套（Slack / 网页）会超，能跳就跳。
- `maxTargets = 200` —— 单次扫描的硬上限。
- `skipRoles = {AXStaticText, AXImage, AXProgressIndicator}` —— 元素本身
  仍然作为 candidate 评估（Finder 桌面文件就是 `AXImage`），**只是不进
  子树**。这些 role 的子树几乎永远不含可点元素，递归代价又大。
- **AXMenu 子树**：role == `AXMenu` 且其父 `AXMenuBarItem` 的
  `AXSelected` 为 false 时（关闭状态的菜单栏下拉）→ return。这条
  只剩 Dock 右键菜单这一个用例会触发；焦点 app 的菜单栏走单独的
  `walkMenuBar` 快速路径（§2.4）。
- **subtree bounds cull**：容器 bounds 非空且与所有屏幕都不相交 →
  return。零 bounds / 缺失 bounds 不剪枝（buggy SwiftUI/Electron
  容器的"未知"哨兵）。

### 2.2 收录条件

候选过滤按"先便宜后贵"排序，因为 `AXUIElementCopyActionNames`
不能合进 batchFetch（不是属性 query），未知 role 时它是额外 IPC。
所有便宜过滤都用 batchFetch 结果，把贵的放最后：

1. `AXEnabled == true`（或属性缺失 —— 多数 control 不显式标）。
2. 矩形 ≥ 8×8（伪元素过滤）。
3. 矩形与屏幕并集相交（`onScreen`）。
4. **矩形落在源窗口内**（`withinWindow`，焦点 app walk 才生效）。
   walk 入口（`depth == 0` 且 `sourceWindow != nil`）抓住窗口自己的
   rect 当作 `effectiveBounds`，递归一路传下去，每个 candidate 都得跟它
   相交。**为什么需要这条**：AX 偶尔会把"滚出 viewport 的 row"（典型：
   Finder 侧栏底下 Tags 段、长表格的下半截）也报出来，rect 在屏幕几何
   范围内但其实在窗口下方——`onScreen` 过不了它，hint 标签就贴到后面
   那个窗口的内容上去了（实测踩到：Finder 在前 + Chrome 在后，Tags 段
   的虚拟 row 把 hint 撒到了 Chrome 的页面上）。Dock / menubar / extras
   走的路 `sourceWindow == nil`，跳过这条（它们不在某个"窗口"里）。
   零额外 IPC：bound 直接复用 root 调用本来就要做的 `batchFetch`。
5. **有可识别标签**（`hasMeaningfulLabel`）：`AXTitle / AXDescription /
   AXHelp / AXValue / AXSubrole` 任一非空。
   - 例外：`AXDockItem / AXMenuBarItem / AXMenuExtra` 跳过这条
     （它们靠位置和 role 本身就能识别）。
   - 没有这条过滤的话，AX 会报很多"幻影"元素 —— 标签全空、app 实际
     没画 —— 导致 hint 出现在空白处。
6. **role 在 `clickableRoles`**：
   ```
   AXButton, AXLink, AXMenuItem, AXMenuBarItem, AXMenuButton,
   AXCheckBox, AXRadioButton, AXPopUpButton, AXTab,
   AXDisclosureTriangle, AXDockItem, AXMenuExtra
   ```
   或 `AXUIElementCopyActionNames` 返回包含 `AXPress` / `AXOpen`。
   `AXOpen` 是 Finder 桌面 `AXImage` 实际暴露的动作（替代 `AXPress`），
   不收就没法点桌面文件 / 文件夹。

#### Source-list `AXRow` fallback

Apple 的 NSOutlineView source list（Finder / Mail / Notes / Music /
System Settings / Calendar 等侧栏）有个特点：**整个 row 是 click target**
（点击触发选中，app 写 `AXSelectedRows`），但 row 本身既不在
`clickableRoles` 里，也不暴露 `AXPress` / `AXOpen`——所以条件 6 通不过，
walk 默认会**漏掉整列侧栏项**（Finder 早期就这样：sidebar 完全没 hint）。

修法：在 `walk()` 递归完一个元素的子树后，**如果 role 是 `AXRow`、且
子树里没人成为 candidate**（用 `out.count` 在进入子树前后做差），就把
row 自己作为 candidate 加进去——synth click 到它中心就能选中那项。

为什么"子树有可点后代时不补 row"？避免双 hint：Finder **主**文件列表里
每行的 `AXImage` 子元素有 `AXOpen`，会通过条件 6 进 candidate；这种情况
`out.count` 已经涨了，fallback 跳过 row，整行只留图标那一个 hint。

零额外 IPC：纯 `out.count` 对比 + 一次条件 4-5 复查（cheap）。一改全顺，
所有上面提到的 source-list app 侧栏一起亮起来。

### 2.3 屏幕并集计算

AX 用左上角原点 + Y 向下，NSScreen 用左下角原点 + Y 向上。`totalScreenSpan()` 把每块屏的 NSScreen frame 翻 Y 后取 union：
```swift
let axRect = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
```
`primaryH = NSScreen.screens.first.frame.height`。

返回 `nil`（无屏幕）时所有元素都算"在屏幕上"——降级行为而非崩溃。

### 2.4 焦点 app 的 collect 拓扑

焦点 app 的 collect 不是单次 `walk(app)`，而是按 root 的两个子来源
分开处理，每个走最便宜的路径：

```swift
collect focused app:
  syncFocusedApp(pid)                    // 切 app 就清 cache
  windows = read AXWindows attr
  cache.pruneTo(windows)                 // AXWindows diff
  for window in windows:
    if cache hit → reuse cached targets  // §2.5
    else        → walk(window), cache.store()
  menubar = read AXMenuBar attr
  walkMenuBar(menubar)                   // §2.6 快速路径
```

不走 `AXChildren` 直接拿 root 的所有子，是因为我们要分别处理两类
子：windows 要走缓存，menubar 要走 fast path，dock / extras 都不来自
焦点 app（它们走自己的路径，§3 / §4）。

> **不支持右键 / 弹出菜单的 hint。** 试过：右键弹出的 context menu 想加
> hint，得先在 AX 里找到那个 `AXMenu`。但实测 **Finder 桌面右键菜单根本
> 不在 Finder 进程的 AX 树里**——system-wide / app 的 `AXFocusedUIElement`
> 都不是它,`AXChildren` 没有它,深挖子树(depth≤4)也没有。它是独立进程
> 的系统级菜单,AX 经 Finder 这条路够不着。所以这个功能放弃了(详见 git
> 历史里那次 revert)。

### 2.5 AXWindow 缓存（`HintWindowCache`）

**问题**：sticky rescan（点完一个 hint 后自动重扫）总是把焦点 app 的整棵
AX 树重新走一遍。但用户的典型操作 —— 比如关掉一个弹框 —— 只销毁了
一个 NSWindow，其他 window 的 AX 子树完全没变，重扫是浪费。

**缓存模型**：按 `AXWindow` ref 缓存其子树的扫描结果。`AXUIElement` 是
CF 类型，identity 用 `CFEqual / CFHash`，所以包一层 `WindowKey: Hashable`
喂给 `Dictionary`。每个 entry 存：

```swift
struct CachedTarget {
    let element: AXUIElement
    let offsetFromWindow: CGPoint   // target.origin - window.origin（扫描时）
    let size: CGSize
    let role: String
}

struct Entry {
    var targets: [CachedTarget]
    var dirty: Bool
}
```

**坐标用窗口局部存**：扫描时记的是 `target_screen_origin - window_screen_origin`，
不是绝对屏幕坐标。复用时读一次该 window 的当前 `AXPosition`（1 IPC），
加回 offset 得到最新屏幕坐标。**用户拖动 window 不需要 invalidate**，
自然处理。

**三层失效**（按从便宜到贵的顺序）：

1. **`syncFocusedApp(pid)`**：焦点 app 变了 → 整清。我们在 app 不是焦点
   期间无法监听它的变化，缓存信任度归零。
2. **AXWindows diff**：每次 collect 读一次 AXApplication 的 `AXWindows`
   属性（1 IPC），跟 cache 里的 keys 比对。不在新列表里的 → drop。
   关弹框这种"window 销毁"的 case 在这一道被命中。
3. **commit 触发 dirty**：`HintMode.commit` AXPress 之后，按 target 上
   的 `sourceWindow` 调 `markDirty(window:)`。语义：**用户点击了该窗口
   里的东西，该窗口的内容可能变了，下次 reuse 它必须重扫**。其他没动
   过的窗口保持 cache 有效。dock / menu extras / menu bar items 的
   `sourceWindow` 为 nil，commit 不触发 dirty。

**没有 AX observer 监听内容变化**。理由：

- AX 通知层语义不稳定（很多 app 不发或漏发 layout / value 变化）。
- commit-driven dirty 已经覆盖了 sticky 流程里所有"用户主动改 UI"的
  case —— sticky session 期间用户的输入只有 hint click，每次 click
  都标 dirty。
- 用户用真鼠标在 Mouseless **关闭期间** 改了 UI → `VimSession.enter()`
  调 `cache.clear()` 兜底，每次重新进 Mouseless 都从零开始。

**复用代价**：1 IPC 读 window AXPosition + 内存里加 offset。命中一个
window 节省的 IPC 是该 window 子树的全部 batchFetch（百量级）。

**适用场景**（实测有效）：
- 关弹框后 sticky rescan：弹框 prune 掉、主窗口 cache 命中。
- 同会话内反复 sticky：每次只重扫真正变了的 window。

**不适用场景**（cache 直接 miss / 不生效）：
- 焦点 app 切换：整清。
- 用户点了焦点 window 里的东西：该 window 自己被标 dirty，重扫。
  这是"对的"，不是 cache 失败。

### 2.6 AXMenuBar 快速路径（`walkMenuBar`）

**问题**：焦点 app 的菜单栏（File / Edit / View ... 那一排）每次 collect
都要走。通用 `walk()` 处理它的代价是：

- 每个 AXMenuBarItem 自己 batchFetch：1 IPC
- 每个 item 下挂着一个**关闭状态的 AXMenu**（macOS AX 树即使下拉
  没展开也保留这个节点），batchFetch 一遍：1 IPC
- `axMenuIsOpen` 检查（AXParent + parent's role + parent's AXSelected）：
  3 IPC

每个 menubar item **~5 IPC**。10 个 item = ~50 IPC，全是浪费 ——
因为 99% 的扫描时刻菜单栏根本没有任何 dropdown 展开。

**快速路径**：在 AXMenuBar 这一层先读一次 `AXSelectedChildren`（1 IPC）。
返回的数组：

- **空** → 没有任何 menu 展开（绝大多数情况）。只 batchFetch 每个
  顶级 AXMenuBarItem 作为 candidate，**不下钻**。总 ~12 IPC。
- **非空** → 有 dropdown 展开。fallback 到通用 `walk()`，保证 dropdown
  里的 `AXMenuItem` 仍然能被打 hint。

```swift
walkMenuBar(menubar):
  if AXSelectedChildren(menubar) is non-empty:
    walk(menubar)         // 慢路径，覆盖打开的 dropdown
    return
  for item in menubar.AXChildren:    // 快路径
    if isCandidate(item): append
    // 不进 item.AXChildren
```

降幅实测：单次 collect 的 IPC 总数 ~270 → ~13（关弹框后 cache 命中
+ 快速路径双管齐下时）。

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

## 5. 已知性能尖峰：app AX cleanup 期

**现象**：用户点击关闭某个 window（弹框上的红色 close / 关 sheet
按钮），sticky rescan 立刻发生，焦点扫描耗时跳到 ~500ms，**即使
`HintWindowCache` 和 `walkMenuBar` 都命中了最优路径**。

**实测**：

```
关弹框后那次：  focused=535ms (13 IPC, 1 window cache hit)
紧接着的扫描：  focused=53ms (270 IPC, 0 window cache hit)
```

13 IPC 已经是理论下限（AXFocusedApplication + AXWindows +
1 个 readScreenOrigin + AXMenuBar + AXSelectedChildren + AXMenuBar
batchFetch + ~7 个 menubar item）—— 没法再砍了。**问题是单 IPC 延迟
从 0.2ms 涨到 ~40ms**，500ms 几乎完全是 13 × ~40ms 的累积。

**根因**：用户点击的瞬间 app 内部开始 cleanup（销毁 NSWindow、
重算焦点、清 AX 子树、可能伴随 layout 重排），这段 wall-clock 时间是
app 的内部代价（实测 WeChat 约 400-600ms）。我们的 IPC query 在
这段时间里发出，每个都被 app 的 AX server 排在 cleanup 工作后面，
单价从 0.2ms 涨到 ~40ms。**IPC 数量优化对单价没影响**——任何路径
下都要至少 ~10 个 IPC 才能完成最小扫描，每个 40ms 就 400ms 起。

**尝试过的失败方案**：

| 方向 | 为什么不行 |
| --- | --- |
| 进一步压 IPC 数（5 以下） | 几个核心 query（AXWindows、AXMenuBar root、cache 复用的 AXPosition）是必需的，砍掉就退化或失能 |
| 全局降低 AX message timeout | 历史已弃，会让正常但慢的 app 拿不到数据（见 `event-pipeline.md`） |
| 事件驱动等 AX 稳定再扫（`kAXFocusedWindowChangedNotification` 等） | 通知到达时机不可控：通知可能恰好在 cleanup 结束时发，那时总 wall-clock 时间 ≈ 现在的 535ms（甚至略差，多一段空等）；通知早发的话扫描还是落在 cleanup 中，没改善。需要实测才知道，目前未尝试 |

**接受的现状**：

- 尖峰只在"destructive click 紧接着 sticky rescan"这一瞬间出现。
- 下一次扫描立刻回到 ~50ms（AX server 已恢复 + cache 还在）。
- 535ms 比上一轮优化前的 840ms baseline 还快。

**长远方向**：Electron app（vs Homerow wedge）的 AX 兼容性本身不行
（很多可点 `<div>` 暴露成 AXGroup 无 action 无 label，hint 命中率低），
最终会引入 **OmniParser / 视觉 ML** 路径来识别可点元素。那条路径完全
脱离 AX server —— 用屏幕截图喂模型 → 拿坐标。扫描跟 app 的 AX
内部状态解耦，**这个尖峰自然消失**。当那条路径落地时再回头修这里。

---

## 6. 并发安全

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

## 7. 调试

`debugDumpAXTree(element, depth, maxDepth)` 静态函数，递归打印任意 AX 元素的子树：role + rect + actions。
当扫描结果不对时（"为什么这个按钮没 hint?"、"为什么 menu extras 是 0?"），把它接到 `collectAll` 里手动调用一次，看树结构。

例如：
```swift
if let (focused, pid) = focusedApplication() {
    debugDumpAXTree(focused, depth: 0, maxDepth: 4)
}
```
