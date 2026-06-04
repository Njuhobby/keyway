# Per-App 修正层设计（AX walker 覆写为主）

> **状态：设计草稿，暂不实现**。OmniParser 集成（P0-P6）之后规划的**重要独立模块**，也是 Mouseless 主要的**护城河**。本文固化设计推理 + 被否决/降级的方案，等优先级到了直接照此实现。
>
> 相关：`omniparser-fallback-design.md`（OP 视觉路径主体）、`browser-support-design.md`（浏览器走扩展 DOM，是这套思路在浏览器域的对应物）。

---

## 0. TL;DR — 三层防线

```
1. per-app AX walker 覆写（主力）  —— 80%+ 长尾 app，声明式 JSON 规则，~1-5ms
2. OmniParser 视觉路径（fallback） —— 真·AX 黑洞 app（纯 canvas / 自绘），已实现
3. pattern exclude / threshold override（辅助） —— OP/AX 误报与调参
```

**护城河 = 社区共建的、每个 app 的 AX 适配规则库** —— 把每个 app 怪异的 accessibility 树翻译成精确的可点元素。纯文本、可 diff、可 review、零模型维护、贡献门槛低到任何能用 AX Inspector 戳一下的人都能提 PR。

NCC 模板匹配从早期设计的"主力"**降级到附录**（§A1）——重新分析后它的适用面被 AX 覆写从上面挤掉、被 OP 从下面盖住，夹在中间几乎没有立足之地。**v1 不实现，大概率永不实现。**

---

## 1. 动机：AX-bad ≠ AX-absent

OmniParser 路径上线后的根本问题：OP 不是 100% 准确（漏 icon-only 按钮、误标标题栏文字）、confidence 阈值不通用、box 是匿名的（不知道是相机还是文件夹）。所以 Mouseless 成熟必须有 **per-app 个性化修正**。

但关键的二次洞察（决定了主力机制）：**绝大多数"OP-bad"的 app,其实 AX 不是"没有",而是"不规范"**。

例子 —— Slack 的 Compose 按钮在 AX 树里是：

```
AXGroup (subrole=nil, action=nil)
  └── AXGroup
        └── AXImage (action=AXPress, title="Compose")   ← 在这里!
```

我们的通用 walker 跑 role 白名单 + depth 限制时跳过了这种"罩在两层 AXGroup 里、role 是 AXImage 但带 AXPress action"的元素。**App 是有信息的,我们没读到。**

真·视觉零 AX 的 app（WeChat 聊天自绘区、Figma canvas、网页游戏）是**少数**。Slack / Notion / Linear / Discord / Cursor / 大多数 Electron 和 SwiftUI app 都有相当程度的 AX，只是结构怪。

**结论:对长尾 app 做深度适配,"customize AX 规则"是比"视觉补漏"更好的路** —— 所有规则都能用文字表示、便宜、抗 app 升级、社区可贡献。只有 app AX 真的啥都没有时才退回 OP。

---

## 2. 为什么不是 per-app 模型 fine-tuning

直觉上"为每个 app 微调一套 OP 模型，教它相机可点"——**否决**。

| 维度 | per-app 模型 fine-tuning |
| --- | --- |
| 标注 | 人工框出 app 所有界面状态的每个可点元素，几百-几千张/app |
| 训练 | GPU + 管线 + 调参，per app 重来 |
| 体积 | 每个 ~38MB，100 app = **3.8 GB** |
| 维护 | **app 一更新 UI 模型就过时** → 重标注 + 重训 |
| 讽刺点 | 你标注"相机可点"的那个框，**AX 本来就免费能拿到**（只是 walker 没收）|

fine-tuning 是"完全没有结构化信息、只能从像素学"时的最后手段。我们对绝大多数 app 有更便宜的信息源（AX 树本身）。真要训模型，也该是拿**聚合** UI 数据训一个更强的**通用**检测器替换 OmniParser，不是 per-app 一个模型。

---

## 3. 核心洞察：self-gating，绕开窗口分类

修正方案的第一个死结：**一个 app 不止一种窗口布局**（WeChat 有主窗口、通讯录、朋友圈、设置、图片预览……）。一条"左下角有相机"的规则套到设置窗口就凭空造假 hint。

试图做"窗口分类器"（靠标题/尺寸/AXIdentifier 判断布局）是死结：标题会变、用户会 resize、很多 app 不设 AXIdentifier。

**破解：不分类窗口。让规则锚到一个可判定的条件，条件的"成不成立"本身充当 gate。** 对 AX 覆写来说尤其干净 —— 规则是"AX 树里存在满足 predicate 的元素"，predicate 匹配不到就自动静默，零误报。设置窗口里没有那个 Compose 结构 → 规则自然不产出 hint。**分类窗口这一步直接消失。**

---

## 4. AX walker 覆写：主力机制

要救的是"**AX 树里有这个元素,只是通用 walker 没收**"。覆写 = 一份声明式 JSON,告诉 walker 在某个 app 里**额外**把满足某些条件的元素算作可点。

### 4.1 数据形态

每个 app 一份 `patch.json` + 可选 README：

```
patches/com.tinyspeck.slackmacgap/
├── patch.json
└── README.md          # 维护者备注（哪个版本 teach 的、截图示例）
```

`patch.json`（schema 草稿）：

```jsonc
{
  "schema_version": 1,
  "bundle_id": "com.tinyspeck.slackmacgap",
  "app_name": "Slack",
  "maintainer": "@njuhobby",
  "verified_against": ["4.36.x", "4.37.x"],

  "additional_clickable": [
    {
      "role": "AXImage",
      "must_have_action": "AXPress",
      "comment": "侧栏 Compose / Threads / Mentions icon"
    },
    {
      "role": "AXGroup",
      "must_have_subrole": "AXButton",
      "comment": "自定义按钮 wrap 在 group 里"
    }
  ],

  "exclude": [
    { "role": "AXStaticText", "title_equals_window": true,
      "comment": "标题栏文字" }
  ],

  "fallback_op": false
}
```

**格式决策（v1 拍板）**：

- **JSON 不用 YAML** —— Foundation 原生 parse、零依赖、CI 工具好写。可读性对这种扁平结构够用。
- **predicate 扁平、不做 role_path** —— 一条 rule 内字段 AND（role=AXImage 且 has AXPress）；多条 rule 之间 OR。不支持祖先链（"AXGroup → AXGroup → AXImage 才算"）。绝大多数 case 扁平 predicate 够；真需要路径精准防误命中再在 v2 加。
- **二值判定、不做 score** —— rule `matches → clickable`，纯布尔。文本规则没必要装小数。
- **`fallback_op` 默认 false** —— patch 存在即表示"这 app 走 AX 自洽,不需要 OP"。设 true 才在 AX 收完后再叠 OP 补漏（给"AX 拿到大部分 + 动态内容如聊天气泡需要视觉兜底"的混合 app 用）。默认 false 避免开发者忘记关、白付 OP 的 ~95ms。

predicate 可用字段（v1）：`role` / `subrole` / `must_have_action`（"AXPress"/"AXShowMenu"）/ `must_not_have_action` / `title_matches`（正则）等，按需扩。

### 4.2 接入现有 walker

现状路由（`HintMode.collectAll`）：

```
frontmost.bundleID
   ├─ isBrowserApp → BrowserProvider（扩展 DOM）
   ├─ shouldUseAXForFocused → AX walk（hardcoded whitelist）
   └─ 其它 → OmniParser
```

加 patch 后变成：

```swift
if let patch = AppPatchRegistry.shared.patch(for: bundleID) {
    walker.run(window: focusedWindow, augmentedBy: patch)   // AX walk + 额外规则
    if patch.fallbackOP { mergeOP(...) }                    // 默认不跑
} else if AppRegistry.shouldUseAXForFocused(bundleID) {
    walker.run(window: focusedWindow)                       // 原通用 walk
} else {
    OmniParserPath.collect()                                // 无 patch + 非白名单 → OP
}
```

walker 判"某元素是否 clickable"时多过一遍 patch 的 `additional_clickable` 规则：

```swift
func isClickable(element, patch) -> Bool {
    if defaultClickableHeuristics(element) { return true }   // 已有通用判定
    if let patch, patch.additionalClickable.contains(where: { $0.matches(element) }) {
        return true                                          // app-specific 补充
    }
    return false
}
```

简单的 forward-chaining，零黑魔法。原 `AX_FOCUSED_WHITELIST` 语义保留 —— 那是"这 app **不用 patch** 也信通用 walker"（Finder / Mail / Notes 这种规范 a11y app）。**二分（AX whitelist vs OP）变三分（patch app / vanilla whitelist app / OP-only app）**，绝大多数长尾 app 从 OP 迁到 patch。

### 4.3 teach 闭环（抓 AX predicate）

```
教学（每条规则一次性）：
  1. 用户在 Slack，Compose 按钮没 hint
  2. 触发 teach（menu bar "Teach a missing hint…" 选项）
  3. 用户把鼠标指向 Compose 按钮
  4. Mouseless 用 AXUIElementCopyElementAtPosition 拿那个元素
  5. 读它的 role / subrole / actions → 生成一条候选 predicate
     （"role=AXImage, must_have_action=AXPress"）
  6. 存进本地 patch.json
运行时：加载 patch → walk 时套用 → 命中 → 合成 hint
```

teach 产物**从"截 icon PNG"变成"抓一条 AX predicate"** —— 这是主力换成 AX 覆写后 teach 的关键变化。门槛更低、PR 是几行 JSON 而非 PNG+JSON、review 更快、不存在"icon 改版模板失效"。

teach 入口走 **menu bar 下拉选项**（"Teach a missing hint…"），不抢 chord —— 一次性操作不值得占按键。

---

## 5. exclude / threshold override（辅助）

**exclude** —— 删 OP/AX 误报（标题栏文字被标 hint）。优先 pattern-based（跨布局通用）：

```jsonc
{ "role": "AXStaticText", "title_equals_window": true }   // 删文字 == 窗口标题的
```

标题栏文字 == 窗口标题这条所有布局通用，不用 per-layout 配。exclude 比 include 容易 —— 它作用在**已有** candidate 上，能做模式匹配。

**threshold override** —— 某 app OP confidence 默认 0.3 不对，patch 里调一行。纯配置，~0 成本。仅对 `fallback_op: true` 或 OP-only 的 app 有意义。

---

## 6. 分发飞轮：L0 → L1 → L2

护城河要转起来，靠社区共建。按复杂度递进，**做 L0→L1→L2，跳过 L3**：

| 阶段 | 机制 | 消费门槛 | 贡献门槛 | 飞轮 |
|---|---|---|---|---|
| **L0** 自带 curated | top ~30 app 的 patch 打包进 .app | 0 操作 | （我们手写）| 不增长 |
| **L1** GitHub repo + 自动 pull | `Njuhobby/mouseless-patches` 公开 repo，启动时 pull 最新 + 本地 cache + 离线 fallback | 0 操作 | 懂 PR | 慢飞轮 |
| **L2** 一键分享 | app 内 teach 完点"分享" → GitHub OAuth 自动提 PR（patch.json + 截图） | 0 操作 | **0 摩擦** | 真飞轮 |
| L3 marketplace | 类 VS Code 扩展商店（搜/装/评分）| 完全消费式 | — | 强但工程量大,**不做** |

L3 工程量太大、收益不匹配当前规模。L2 已经能让任何 macOS 用户（不懂 git）贡献。

repo 结构：`patches/<bundleID>/{patch.json, README.md}`。

---

## 7. 治理 / 抗噪 / 隐私

| 风险 | 缓解 |
|---|---|
| **规则过时**（Slack v5 改了 AX 结构）| `verified_against` 记版本；app 版本号变了 UI 上 flag "可能需要重 teach"。AX role 命名通常很稳，比 PNG 模板抗升级得多 |
| **误命中**（predicate 太宽，把不该点的标成可点）| teach 时生成的 predicate 尽量带约束（role + action 一起）；PR review 配套截图人眼对；CI 可在 reference 截图上跑"命中数是否爆炸"启发式 |
| **质量参差** | CI 自动校验 patch.json schema + 在维护者提供的 reference AX dump 上跑规则、统计命中 |
| **流量攻击** | GitHub Actions + CODEOWNERS 标准防护 |
| **隐私** | teach 抓的是 AX role/action/title 文本,可能含用户数据（如窗口标题里的人名）→ teach UI 让用户预览 + 编辑后再存/提交;截图（仅 L2 分享时）强制让用户涂抹敏感区 |

**信任分级**：高风险 app（银行、1Password、密码管理器）的 patch 走人工审；普通 app CI 通过即可 merge。贡献多了引入 trusted contributor（贡献过高质量 PR 的用户授 merge 权）。

---

## 8. Bootstrapping（鸡生蛋）

**0 用户阶段（我们 seed）**：手动 teach ~30 个高频 app —— Slack / Discord / Notion / Linear / Figma / Zoom / Spotify / Music / Mail / Calendar / Notes / Telegram / Bear / Obsidian / Cursor / Warp / iTerm / Postman / Things / Excel / Numbers / Keynote / Pages / Sketch / TablePlus 之类。这波直接是产品 day-1 价值（装完主力 app 立刻好用）。

**100 用户阶段**：激活 L2 一键 PR，我们每天 review 几个，catalog 从 30 → 100+。

**1000+ 用户阶段**：trusted contributors + CI 自动化（schema 校验、staleness 检测、命中回归）。

---

## 9. 护城河

- **数据护城河**：随使用积累的 per-app AX 规则库 —— 别人从零积累一千个 app 的适配
- **形态是结构化文本,不是模型权重**：纯 JSON predicate,可 diff / review / 手编,过时改一行;不背训练 + 重训 + 体积成本
- **贡献门槛极低**：teach 一键抓 predicate → PR 几行 JSON,任何能用 AX Inspector 的人都能贡献
- **越用越准的闭环**：teach → PR → 预置库变强 → 新用户开箱即用
- 对标 Vimium：它真正的护城河不是技术,是 15 年沉淀的每个网站的处理细节。我们是**OS 层**的对应物 —— 每个 app 的 AX 适配。竞品想追要从零积累。
- Homerow 纯 AX、不做任何 per-app 适配；我们的差异化是**把每个 app 的 AX 怪癖都驯服**。

---

## 10. v1 scope

做：

- `AppPatchRegistry` —— 加载 + 索引 patch.json（bundleID → patch）
- AX walker 接 `additional_clickable` predicate（扁平、二值、AND/OR）
- `exclude`（pattern-based，先做 title_equals_window）
- `fallback_op` 开关（默认 false）
- teach 流程：menu bar 入口 → `AXUIElementCopyElementAtPosition` 抓元素 → 生成 predicate → 写本地 patch
- L0 curated 预置（~30 app）+ L1 GitHub pull 脚手架

暂不做（defer）：

- L2 一键 PR（先 L1 手动 PR 跑通飞轮再做）
- threshold override（仅 fallback_op app 需要，量出来再做）
- role_path 路径化 predicate（扁平不够用再加）
- **NCC 模板匹配 + OCR-landmark + 几何缺口检测**（见 §A 附录，大概率永不做）

---

## 附录 A：被砍 / 降级的方案

### A1. NCC 模板匹配 —— 从"主力"降到"附录脚注"

早期设计把 NCC 视觉模板匹配当 include 主力（teach 一张 icon PNG，运行时在截图里 NCC 匹配补 hint）。重新分析后**砍掉**：

NCC 唯一站得住的场景是"**目标可见可点、但 AX 树里压根没有这个 node**"。但这个场景：
- 从上面被 **AX 覆写**挤掉（AX 里有 node 的，覆写就搞定，不用视觉）
- 从下面被 **OmniParser** 盖住（AX 真没有的，OP 的通用视觉检测已经在兜）

NCC 想占的是"AX 没有 + OP 也漏 + 但又是视觉稳定固定 icon"的三重交集 —— **面积极小**。当初它是"补 OP 漏检"，但 OP 自己已退居 fallback（只服务真黑洞 app），NCC 就成了 fallback 的 fallback，性价比不成立。

附带好处：砍掉 NCC，护城河数据更纯（全是文本 JSON，无 PNG 库）、体积更小、贡献门槛更低、没有"icon 改版模板失效"的维护负担。

（NCC 技术本身的设计 —— Accelerate vImage 实现、归一化抗暗色模式、区域限定 ~5ms、DPR 缩放 —— 如果将来真碰到非做不可的 canvas-app icon 场景，git 历史里有完整推理可捞。）

### A2. OCR-text-landmark —— defer

"可点元素在文字 'Search' 右边"，靠区域限定 OCR 找文字 landmark 定位。成本是软肋（每次 collect 跑 region OCR ~5-10ms）。只在 AX 覆写也搞不定（元素 AX 没有、外观会变、但附近有稳定文字）时才有意义 —— 罕见，defer。

### A3. OP-相对锚定 —— 否决

"相机在文件夹 icon 右边"：OP 的 box 是匿名的，不知道哪个是文件夹，无法解析"相对某个有身份的框"。唯一不靠身份的形式是纯几何缺口检测（等间距图标行里推断"中间有洞 → 漏了一个"），但又窄又险（缺口可能是故意分隔 → 误报），大概率不做。

### A4. 窗口分类器 —— 死结

见 §3。靠标题/尺寸/AXIdentifier 判断"我在哪个布局"没有可靠信号。被 self-gating 取代。

---

## 附录 B：决策史（防止重走弯路）

1. **per-app fine-tune 模型** → 否决（标注/训练/维护/体积天文成本，AX 免费能拿到的没必要用模型学）
2. **修正 JSON + 窗口分类器** → 死结（布局多、无可靠分类信号）→ 改成 **self-gating**
3. **NCC 模板匹配当 include 主力** → 重新定位后**降级到附录**（被 AX 覆写从上挤、被 OP 从下盖，交集极小）
4. **主力改为 per-app AX walker 覆写** → 关键洞察"AX-bad 多半是 AX-irregular 不是 AX-absent"，大多数长尾 app 有 AX 只是结构怪，声明式规则比视觉补漏更便宜/更稳/更易贡献

想要 per-app 精度时，第一反应应该是 **"写一条 AX predicate 覆写"**，不是"训模型" / "做窗口分类器" / "存 icon 模板"。
