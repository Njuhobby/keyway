# Settings / 用户配置设计

> **状态：设计草稿，未实现**。上线前要让用户至少能调最痛的几项（速度、颜色、trigger）。本文固化配置项分档 + 存储 + 让硬编码常量变可配的改法 + v1 scope。

---

## 0. TL;DR + 原则

```
菜单栏加 "Settings…"（Cmd+,）→ 配置面板 → 存 UserDefaults → 控制器读它（带默认值，live-apply）
```

**配置是双刃剑**：太多配置 = 维护负担 + 测试矩阵爆炸 + 新用户被淹没。所以**分档**，只把"因人而异很大、自己 daily-drive 都反复调过"的项放进 v1，复杂的（自定义键位）推后。Homerow 有配置面板是对的，但别一上来堆满。

---

## 1. 存储：UserDefaults + 中央 Settings

一个 `Settings.shared` 薄封装 `UserDefaults`，**每个键带默认值**（没配过 = 当前硬编码值，行为不变）：

```swift
@MainActor final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var cursorNormalStep: CGFloat { d.object(forKey: "cursorNormalStep") as? CGFloat ?? 6 }
    var cursorFastStep:   CGFloat { d.object(forKey: "cursorFastStep")   as? CGFloat ?? 18 }
    // ... 其余同理
    func reset() { /* 清掉所有 mouseless.* key */ }
}
```

**live-apply**：控制器在 `start()` 或每 tick 读 `Settings.shared.xxx`（60fps 读缓存值无成本）→ 改了设置立即生效，不用重启。主题色类（影响渲染）发一个 `Settings.didChange` 通知让 overlay 重画。

---

## 2. 配置面板

- 菜单栏 "Settings…"（macOS 惯例，**不叫 Configure**；绑 Cmd+,）
- 一个 NSWindow（或 SwiftUI `Settings` scene），分 tab：**General / Speed / Appearance / Trigger**
- 每项即时写 UserDefaults
- "Reset to Defaults" 按钮

---

## 3. 配置项分档

| 项 | 当前硬编码 | 档 |
|---|---|---|
| **光标移动速度** slow/normal/fast | MouseMover 2 / 6 / 18 px/tick | **v1 必须** |
| **滚动速度** normal/fast | ScrollController 30 / 90 px/tick | **v1 必须** |
| **窗口 resize/move 速度** slow/normal/fast | Window(Move)Controller 5 / 20 / 80 px/tick | **v1 必须** |
| **双击阈值** | hjkl 跳屏 `hjklJumpTapWindow` 0.10s；WINDOW 反向 + Shift 双击 `windowReverseTapWindow` 0.15s | **v1 必须**（手速因人而异大）|
| **跳屏距离** | jumpCursor 0.25 / 0.5 屏 | v1 必须 |
| **hint label 主题色** | 黄 `1.0,0.84,0` / move-armed `1.0,0.95,0.70` | **v1 该有** |
| **label 字号** | 11pt | v1 该有 |
| **trigger 键** | Caps Lock→F19（hidutil 硬定）| **v1 该有**（不是人人接受 Caps Lock）|
| **开机自启** | 无 | v1 该有（LaunchAgent / SMAppService）|
| **sticky 默认开关** | 默认 off | v1 该有 |
| **完全自定义键位映射**（hjkl 改键、hint 字母池、chord 键）| 硬编码 | **v2**（见 §6）|

> 提供"慢/中/快"三档预设比裸数值更友好；高级用户可展开填精确值。

---

## 4. 让硬编码常量变可配

现状是各控制器里 `private let normalStep: CGFloat = 6`。改法：

1. 控制器构造时或 `start()` 时从 `Settings.shared` 取值（替掉 `let` 常量）
2. 速度类每 tick 读（已经在跑 timer，读缓存值无成本）→ live-apply
3. 主题色：`HintOverlay` 渲染时读 `Settings.shared.hintColor`；`Settings.didChange` 通知触发 `needsDisplay`
4. 双击阈值（VimSession）→ 读 Settings：`hjklJumpTapWindow`（hjkl 跳屏，0.10s）和 `windowReverseTapWindow`（WINDOW 反向 + Shift 双击，0.15s）现在是两个常量。hjkl 跳屏比其它紧，因为它和"正常单步移动"共享同一个键、最容易把快速连点误判成跳屏；WINDOW/Shift 没有这种单步歧义，留 0.15s。可各自暴露，或合成一个"双击灵敏度"滑块按比例缩放两者。

零风险迁移：每个键的默认值 = 当前硬编码值，没配过的用户行为完全不变。

---

## 5. Trigger 键（比值型配置重）

当前 `TriggerRemap` 用 hidutil 把 Caps Lock → F19 全局重映射。让 trigger 可配不是改个数：

- **简单版（v1 该有）**：给**几个预设**（Caps Lock / Right Cmd / Right Option / F19 直连），不做任意键。换预设 = 改 hidutil 映射目标 + 更新 arm 逻辑认的 keycode。
- **任意键**：复杂（修饰键不能当 trigger、要处理冲突），v2 再说。

---

## 6. 自定义键位映射 —— 推到 v2（can of worms）

让用户把 hjkl 改成别的、改 hint 字母池、改 chord 键，是个大坑，跟 `SPECS.md` Future-work #1 的**非 QWERTY 键盘布局**老问题绑在一起：

- 现在 `KeyCode.swift` 是 ANSI 物理键位，Dvorak/国际键盘已经会错
- 自定义键位要先把 keyCode↔字符映射重构（`UCKeyTranslate`）
- 还要处理"用户把 hint 字母改成 hjkl 之类"的冲突校验

**所以 v1 只做值型 + 主题 + trigger 预设；键位映射等键盘布局重构一起做。**

---

## 7. v1 scope

做：
- `Settings.shared`（UserDefaults 封装，全键带默认值 = 当前硬编码值）
- 控制器改读 Settings（速度类 live-apply）
- Settings 窗口（Cmd+,）：Speed（光标/滚动/窗口，慢中快预设 + 精确值）、Appearance（主题色 + label 字号）、Trigger（预设列表）、General（开机自启、sticky 默认）
- Reset to Defaults

之后（v2）：
- 完全自定义键位映射（配键盘布局重构）
- trigger 任意键
- 配置导入/导出、跨设备同步（iCloud）

---

## 8. 决策记录

1. **分档，不堆满** —— config 是双刃剑；v1 只放因人而异大的（速度/阈值/色/trigger 预设）
2. **UserDefaults + 默认值 = 当前硬编码值** —— 零风险迁移，没配过行为不变
3. **菜单叫 "Settings…" + Cmd+,** —— macOS 惯例（不叫 Configure）
4. **trigger 给预设不给任意键**（v1）；**自定义键位推 v2**（绑非 QWERTY 重构）
5. **live-apply** —— 改了即时生效，不重启
