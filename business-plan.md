# Keyboard-Complete macOS — 商业计划书

> 一个面向 macOS power user 的"完整键盘操作层"独立产品，目标 18-24 个月内达到 $20K-60K MRR，养活 1-2 人独立团队。

**版本**：v0.1 · 战略草案
**日期**：2026-04
**状态**：决策前（建议先做 4 周市场验证再 all-in）

---

## 1. 一句话定位

**"Throw away your mouse. For real this time."**

一个让用户**完全用键盘替代鼠标**操作 macOS 的工具——不只是"点击代替"（Homerow 做到的），而是覆盖**点击、文字选择、拖拽、滚动、窗口操作、应用切换**全部场景。核心承诺：**鼠标能做的事键盘都能做，并且更快**。

---

## 2. 问题陈述

### 2.1 现有方案的根本缺陷

市面上"键盘导航"工具（Homerow、Vimac、Shortcat、Scoot 等）都把世界建模成"可点击元素的集合"，只解决了**点击**这一个动作。但鼠标的真实使用场景远不止点击：

| 场景 | 现有键盘工具表现 | 用户体感 |
|---|---|---|
| 点击按钮/链接 | Homerow 已经做得不错 | 满意 |
| **选中一段文字复制** | 几乎不支持，必须手动拖鼠标 | **痛点严重** |
| **拖动文件到目标位置** | 无支持 | 必须用鼠标 |
| **调整窗口大小、移动窗口** | 需要单独装 Rectangle/Magnet | 工具碎片化 |
| 精细滚动（不是页面级） | 弱支持 | 不顺手 |
| Electron / Web 应用内操作 | 大面积失效 | 无法用 |

**结果**：声称"键盘党工具"的产品没有一个能让用户真正**扔掉鼠标**。每天仍要在键盘和鼠标之间来回切换 50-200 次。

### 2.2 用户群

核心 ICP（Ideal Customer Profile）：

- **重度键盘党 / vim 用户**：开发者、技术作家、终端爱好者，已经习惯快捷键思维
- **RSI 患者**：手腕/肩膀劳损，想最小化鼠标使用
- **效率极客**：BetterTouchTool / Raycast / Karabiner 用户群，愿意为生产力工具付费
- **无障碍需求用户（B 端）**：运动障碍员工，企业为合规需求付费

全球付费用户池估算：**5 万-15 万人**。

---

## 3. 产品愿景

### 3.1 核心范式：6 个模式构成"键盘 OS"

不只做点击，做完整的操作层：

```
┌──────────────────────────────────────────────┐
│           Leader Key (e.g., Hyper)           │
└──────────────────────────────────────────────┘
        │
        ├── Click Mode      → label 点击（追平 Homerow）
        ├── Selection Mode  → vim-style 文字选择 ★ 杀手功能
        ├── Drag Mode       → 两点拖拽 / 路径拖拽
        ├── Window Mode     → 移动 / resize / 工作区
        ├── Scroll Mode     → 精细滚动 + 跳转
        └── App Mode        → 应用切换 / 焦点 / 启动
```

### 3.2 设计原则

1. **肌肉记忆优先**：所有高频操作必须能在 0.3 秒内完成。**拒绝任何需要"思考表达"的交互**（包括语音 / 自然语言）。
2. **跨 app 一致性**：同样的快捷键在 Safari、Xcode、VSCode、Figma 行为统一。
3. **AI 作为不可见兜底**：仅在 AX 树失效时（Electron / 自定义 canvas）用本地视觉模型识别元素。用户感知不到 AI 在工作。
4. **Power user first**：不为新手优化引导。前 100 个用户必须是死忠粉。

### 3.3 杀手功能（差异化锚点）

**vim-style 文字选择**。理由：

- 每个 macOS 用户每天做 30-100 次
- Homerow / Raycast / Apple Voice Control 都做不了或做得很烂
- 技术上 AX `AXSelectedTextRange` 在 60% 原生 app 里能用，2-3 周能做出 demo
- 体验上比鼠标拖拽**更快**——是少数能在演示视频里"一秒打动用户"的功能

第一个 demo 视频就是这个：在 Safari 里用 5 个按键选中一段引用并复制。

---

## 4. 竞争格局

### 4.1 直接对手

| 产品 | 团队 | 定价 | 强项 | 弱项 |
|---|---|---|---|---|
| **Homerow** | 1 人（Dexter Leng） | $29 一次性 / $5/月 | 体验最打磨、Chrome 集成 | 不做文字选择/拖拽/窗口 |
| Vimac | 已死（同一作者） | 免费开源 | 留下了"无家可归"用户 | 已停更 4 年 |
| Shortcat | 1-2 人 | $19 | — | 已被市场遗忘 |
| Scoot | 小团队 | Freemium | — | 差异化弱 |

**关键发现**：Homerow 和 Vimac 是同一个开发者 Dexter Leng 的两代产品。开源版（Vimac）因为维护成本不可持续而停更，商业版（Homerow）一个人维护至今。这条赛道**只能商业化、不能开源**。

### 4.2 邻接威胁

- **Raycast**（最危险）：估值 $500M+，几十万付费。当前不做点击导航，但任何时候可以用扩展打过来。**应对策略**：做 Raycast 不会做的"系统底层精细操作"，让出"命令调用"赛道。
- **BetterTouchTool**：跟我们用户重合度高，但产品定位是"自动化"不是"键盘导航"，可借鉴商业模型而非竞争。
- **Karabiner-Elements**：底层键盘重映射，互补不竞争。

### 4.3 结构性风险

- **Apple Sherlock**：macOS 26+ 可能内置更强的 Voice Control / 键盘控制。3-5 年内必然发生。
  - **应对**：差异化做 Apple 不会做的"vim-style 精细操作"——这跟 Apple 的产品哲学冲突，他们不会做。
- **AI 桌面代理**（Claude Computer Use 等）：5+ 年后可能颠覆"用户操作"概念本身，但近期不是威胁。

---

## 5. 商业模型

### 5.1 定价结构

| 层级 | 定价 | 内容 | 目标群体 |
|---|---|---|---|
| **Free** | $0 | Click Mode（基础 label 点击） | 漏斗顶部，转化用 |
| **Pro** | $9.99/月 或 $79/年 | 所有 6 个模式 + 配置同步 | 主力收入来源 |
| **Teams**（v2） | $15/座/月 | 集中管理 + SSO + 合规报表 | B 端无障碍合规市场 |

### 5.2 为什么是订阅制

一次性买断（如 Homerow 早期 $29）是陷阱：

- 每年 macOS 升级 + 重要 app 更新（Chrome / VSCode / Figma）需要持续工程投入
- 一次性收费的用户 5 年后还在要求免费更新和支持
- 收入无法预测，无法穿越周期

**第一天就只卖订阅**。年付优惠 35%（$79 vs $120）锁定用户。

### 5.3 收入目标拆解

达到 $20K MRR 地板（按 $79/年 主力定价）：

- 需要 **3,000 个活跃年付用户**
- 假设品类天花板 30,000 付费用户，需要拿到 **10% 市场份额**
- 这是"做到品类 Top 1-2"才能达到的位置

达到 $60K MRR 天花板：

- 需要 9,000 活跃用户，或 3,000 + 50 家企业客户（Teams 版）
- C 端必须是品类 No.1 + 启动 B 端销售

---

## 6. Go-to-Market 策略

### 6.1 冷启动序列

**第 0-4 周（决策窗口）**：技术 spike + 等待名单
- 写文字选择的 prototype demo
- X 账号 build in public，发第一个 demo 视频
- 简单 landing page + 邮箱收集
- 目标：500 个等待名单邮箱、demo 视频 5K+ 浏览
- **决策点**：反响平平就调整方向或放弃

**第 1-6 个月（闭门 + 内测）**：MVP
- 全职开发，覆盖原生 app + Safari/Chrome
- 邀请 50 名 Vimac 老用户做 alpha 测试
- 每 2 周在 X 发一个新功能 demo
- 月底邀请 200 名等待名单用户做 beta（付费早鸟 $39/年）

**第 7-9 个月（公开发布）**：
- HN Show + Product Hunt 双渠道
- 联系 3-5 个生产力 YouTuber（Tiago Forte、Ali Abdaal 风格的）
- 写 3 篇深度技术 blog（"How we built Vim-style text selection"）
- 目标：500 付费用户

### 6.2 持续增长引擎

每周时间分配（必须严格执行，否则等于没营销）：

- **50%** 写代码 / 修 bug / 适配新 app
- **25%** 内容（X demo 视频、技术 blog、剪 YouTube 短视频）
- **15%** 用户支持 + 反馈处理
- **10%** 商务（合作、PR、定价测试）

### 6.3 关键传播资产

- **每月一个 demo 视频**（30-60 秒，X 优化），主题循环：文字选择 → 拖拽 → 窗口 → Electron 集成 → 工作流组合
- **季度技术 blog**（HN 友好），讲 macOS Accessibility 的脏活
- **vim 圈 KOL 合作**：ThePrimeagen、tj 这种受众的 podcast

---

## 7. 财务规划

### 7.1 时间线和现金流

| 阶段 | 月数 | MRR 预期 | 累计用户 |
|---|---|---|---|
| 闭门开发 | 0-4 | $0 | 0 |
| Beta 早鸟 | 5-6 | $0-1K | 50-200 |
| 公开发布 | 7-9 | $2K-8K | 500 |
| 口碑增长 | 10-15 | $5K-20K | 1,500-2,500 |
| 站稳 | 16-24 | **$20K-50K** | 3,000-6,000 |
| 扩品类 | 25+ | $30K-100K+ | 加 B 端 |

### 7.2 个人 runway 需求

- **国内成本**（生活 ¥10K/月）：备 ¥30-40 万储蓄
- **海外成本**（生活 $3K/月）：备 $60-80K 储蓄
- **缓冲建议**：再额外 30%（用于设备、订阅工具、PR 投放、签证/法律）

**临界点判断**：如果 12 个月没到 $5K MRR，需要严肃考虑暂停或转型。不要"再坚持 6 个月看看"。

### 7.3 单位经济（Unit Economics）

- ARPU：$79/年 ≈ $6.6/月
- Stripe/Paddle 抽成：~5%
- 净 ARPU：~$6.3/月
- 假设月流失率：3-5%（订阅 SaaS 良好水平）
- LTV：~$130-200
- CAC 上限：$40-60（保持 LTV/CAC ≥ 3）

**含义**：每个付费用户的获客成本不能超过 $50。这意味着付费投放空间很小，**必须靠内容和口碑**。

---

## 8. 风险清单

按可控性排序：

### 8.1 高可控（执行问题）

1. **工程深度不足**：投入时间能解决，但需要 18 个月。**应对**：每周 1 个 app 适配的固定节奏，不要一次铺开。
2. **完美主义陷阱**：发布前打磨过度。**应对**：第 6 个月强制 beta，丑也要发。
3. **定价错误**：$5/月还是 $9/月？年付折扣？**应对**：第 9 个月做一次 A/B test。

### 8.2 中可控（技能问题）

4. **营销执行**：内容做不出来或没人看。**应对**：第 1 周就开始发，4 周内验证内容能力。
5. **产品 taste**：UX 决策反复出错。**应对**：早期招 5-10 个反馈伙伴，每个决策征求意见。

### 8.3 低可控（外部冲击）

6. **Apple Sherlock**：macOS 26 / 27 内置类似功能。**应对**：差异化做 Apple 不会做的精细场景；同时启动 B 端业务作为兜底。
7. **Raycast 扩张**：Raycast 推出 keyboard navigation 扩展。**应对**：保持工程深度领先，让 Raycast 扩展只能做 30% 的事。
8. **心理崩溃**：18 个月孤立工作。**应对**：每月固定见 1-2 次同行，加入 indie 社群（IndieHackers / MicroConf）。

---

## 9. 自我评估（决策前必答）

**6 个问题，决定你是不是这件事的合适人选**：

| # | 问题 | 你的答案 | 影响 |
|---|---|---|---|
| 1 | 以前发布过付费产品吗（哪怕 $1K MRR）？ | ? | 有=概率 ×3，没有=÷2 |
| 2 | X / YouTube / 知乎有几千真实粉丝吗？ | ? | 有=概率 ×5 |
| 3 | 能拿出 18 个月生活费而不焦虑吗？ | ? | 不能=概率 ÷3 |
| 4 | 近 3 年有过持续 6 个月做无外部反馈的事吗？ | ? | 没有=心理风险高 |
| 5 | 身边有同行能商量产品决策吗？ | ? | 没有=决策质量 ↓ |
| 6 | 你的痛点在 30 个真实用户里能复现吗？ | ? | 必须做调研验证 |

**判断规则**：
- ≥4 个 Yes → 严肃投入
- 2-3 个 Yes → 降级目标，先做 6 个月 MVP 看反应
- ≤1 个 Yes → 现在不是时机，先补短板

---

## 10. 90 天行动计划

### 第 1 周（4/28-5/4）：技术验证
- [ ] 用 Swift + AX API 写文字选择 prototype
- [ ] 在 Safari、Notes、Xcode 验证 `AXSelectedTextRange`
- [ ] 录制 30 秒 demo 视频
- **决策点**：如果跑不通 → 这条路不可行

### 第 2 周（5/5-5/11）：Build in Public 开始
- [ ] X 账号定位为 "building keyboard-complete macOS"
- [ ] 发布第一条 thread：为什么 Homerow 不够 + 你的 demo
- [ ] 关注 100 个键盘党 / vim 党 / indie maker

### 第 3 周（5/12-5/18）：Landing Page
- [ ] 简单 landing：1 个 demo 视频 + 1 个邮箱收集表单（用 Tally）
- [ ] 域名：keyboardcomplete.dev / 类似
- [ ] 第二条 demo 视频（可能是窗口操作 / 拖拽）

### 第 4 周（5/19-5/25）：决策窗口
- 看数据：等待名单 100+？X 总浏览 10K+？
- **Yes** → 全职启动，进入 6 个月 MVP 期
- **No** → 调整方向（差异化角度 / 目标用户）或暂停

### 第 5-12 周：MVP 开发
- 完成 Click Mode（追平 Homerow）+ Selection Mode（差异化）
- 每 2 周发一个新 demo
- 第 10 周：邀请 50 个 alpha 测试者

### 第 13 周（约 7 月底）：第一次评估
- 200+ 等待名单？50+ alpha 用户？
- 决定是否准备 9 月公开发布

---

## 11. 联系 Dexter Leng（Homerow 作者）

**强烈建议在第 2-3 周做这件事**。Dexter 是 Vimac 和 Homerow 同一个作者，是这个赛道唯一一个走过完整周期（开源失败 → 商业化重启）的独立开发者。15 分钟的对话能替你节省 3 个月。

邮箱：`dexter@homerow.app`

模板：

> Subject: Long-time Homerow user, building something adjacent
>
> Hi Dexter,
>
> I'm a paying Homerow user since [time]. Love the craft.
>
> I'm exploring building a more ambitious keyboard-first macOS tool—covering text selection, drag, and window ops as a unified system, not just clicks. Different positioning, not aiming to compete with Homerow's core.
>
> Would you be open to 15 minutes of brain-pick? Specifically curious about:
> 1. Lessons from Vimac → Homerow transition
> 2. Hardest engineering surprises you didn't expect
> 3. How you handle the AX-fails edge cases (Electron, etc.)
>
> Happy to share what I'm thinking. Zero expectation of business overlap.
>
> [Your name]

最坏情况：他不回。零成本。

最好情况：你拿到一份"哪些坑要绕开"的实操指南。

---

## 12. 现实期望管理

### 12.1 这是一个值得做的赛道吗？

**是的，但有条件**：

- 时间窗口约 3-5 年（Apple 内置功能成熟前）
- 天花板：$30K-100K MRR（独立开发者范畴，非 VC 故事）
- 退出可能：被 Raycast / Notion 收购，$5M-20M（小概率）

### 12.2 这是一个"投入时间就能成"的事吗？

**不是**。时间是必要条件，不是充分条件。决定成败的 40% 在工程之外：

- 分销 / 内容能力
- 产品 taste
- 心理耐力
- 商业直觉
- 时机和运气

### 12.3 基础成功率

全职做 indie macOS app：
- 12 个月达 $1K MRR：~10-15%
- 达 $10K MRR：~2-4%
- 达 $20K+ MRR 稳定 1 年：**~0.5-1%**

**通过这份计划提升的部分**：清晰的差异化（杀手功能 + 完整模式）+ 已验证的商业模型（订阅）+ 明确的窗口期 + 可联系的同行（Dexter）。把基础概率从 1% 提到 5-10% 是合理目标。

### 12.4 兜底价值

即使商业上失败，你在这个过程中获得的：

- 深度 macOS Accessibility / AI 集成 / 系统编程经验
- X 上几千真实粉丝（个人品牌）
- "做过完整 indie 项目"的简历亮点
- 可能被收购或被招聘的 option

**这些都是可观的兜底回报，让这个 bet 在期望值上为正**。

---

## 13. 决策

回答完第 9 节的 6 个问题后，按以下规则决策：

```
4-6 个 Yes  → 全职 all-in，按 90 天计划执行
2-3 个 Yes  → 兼职 12 周，做 MVP demo 测水温
0-1 个 Yes  → 暂不做，先补短板（学营销 / 攒粉丝 / 攒 runway）
```

**最危险的状态**：模糊地"开始做"但没有明确判断。这是 indie dev 的头号死因——既没全力投入，也没果断放弃，3 年烧光积蓄。

---

## 附录 A：技术栈建议

- **语言**：Swift（macOS 原生，AX API 最直接）
- **核心 framework**：AppKit + Accessibility + CoreGraphics（CGEvent）
- **持久化**：UserDefaults + Keychain（License）+ CloudKit（同步）
- **付费**：Paddle 或 LemonSqueezy（**不要** App Store，Sandbox 限制核心功能）
- **签名公证**：Apple Developer Program $99/年
- **网站**：Astro / Next.js + Vercel
- **AI 兜底**（可选 v2）：本地 ONNX / CoreML 视觉模型（YOLO / DETR 风格做 UI 元素检测）

## 附录 B：参考产品清单

研究/借鉴对象：
- **BTT (BetterTouchTool)** — 商业模型样板
- **Karabiner-Elements** — 底层 API 用法
- **Vimac (open source)** — 架构起点
- **Vimium / Surfingkeys** — 浏览器内 vim 范式
- **Raycast** — 命令模式 UX
- **Rectangle** — 窗口管理 API 调用方式

## 附录 C：进一步要做的功课

发布前需要回答：

- [ ] 30 个真实用户访谈，验证文字选择是普遍痛点而非个人偏好
- [ ] Homerow 用户在哪里讨论（subreddit / Discord）？做潜伏调研
- [ ] Vimac 老用户的"无家可归"程度（GitHub issue 回头率、stars 增减）
- [ ] B 端无障碍合规市场调研：哪些公司有预算，怎么接触
- [ ] 法律：注册公司还是个人开票？Stripe Atlas / WyoStartup 等方案对比

---

**最后一句话**

这是个**技术上可行、市场上有空、但商业上极其依赖执行**的项目。Dexter Leng 一个人做到今天，证明了上限存在。你的优势是站在他的肩膀上看清了下一步在哪——文字选择、拖拽、窗口操作的完整化。劣势是你还没证明自己有他那种独立开发者的全栈能力（工程 + 产品 + 营销 + 客服）。

**第一个里程碑很低**：4 周后看 X 有没有人 care 你的 demo。这一步就能筛掉 80% 的不确定性。**先迈这一步，再决定要不要 all-in**。

---

*本文档基于初步对话生成，所有数字均为估算。决策前请独立验证关键假设（市场规模、竞品数据、技术可行性）。*
