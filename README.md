# mouseless

> Throw away your mouse. For real this time.

完整替代鼠标的 macOS 键盘操作层。不只点击——文字选择、拖拽、窗口、滚动、应用切换，全部用键盘。

---

## North Star

**Homerow 解决了"点哪里"，没解决"做什么"。mouseless 解决完整的鼠标替代。**

杀手功能：**vim-style 文字选择**。这是 Homerow / Raycast / Apple Voice Control 都做不了的差异化锚点。

---

## 关键事实

- 目标：18-24 个月内 $20K-60K MRR
- 定价：$79/年 订阅（年付）/ $9.99/月
- 主要对手：Homerow（1 人，估算 $20K-60K MRR）
- 赛道窗口期：3-5 年（Apple Sherlock 之前）
- 真实成功率（独立开发者）：5-10%（calibrated）

详细策略见 [`business-plan.md`](./business-plan.md)。

---

## 第 1 周（决策窗口）

**目标**：用文字选择 prototype 验证技术可行性 + 测市场反应。

- [ ] Day 1-2：Swift + AppKit 项目骨架，注册全局快捷键
- [ ] Day 3-4：调通 `AXSelectedTextRange` 在 Safari / Notes / Xcode 的读写
- [ ] Day 5：实现最小 vim-mode（h/j/k/l 移动 + v 选择 + y 复制）
- [ ] Day 6：录 30 秒 demo 视频（在 Safari 选中并复制一段引用）
- [ ] Day 7：发到 X，配文 "Why Homerow isn't enough"

**决策点**：
- demo 跑不通 → 调整路线或放弃
- demo 跑通但 X 反响平平（< 5K 浏览，< 50 互动）→ 调整定位
- demo 跑通且反响热烈（> 10K 浏览，等待名单 100+）→ 进入 6 个月 MVP 期

---

## 6 个自我评估问题

决定要不要 all-in 之前先答：

1. 以前发布过付费产品吗（哪怕 $1K MRR）？
2. X / YouTube / 知乎有几千真实粉丝吗？
3. 能拿出 18 个月生活费而不焦虑吗？
4. 近 3 年有过持续 6 个月做无外部反馈的事吗？
5. 身边有同行能商量产品决策吗？
6. 你的痛点能在 30 个真实用户里复现吗？

判定：
- 4-6 个 Yes → 全职 all-in
- 2-3 个 Yes → 兼职 12 周做 MVP demo 测水温
- 0-1 个 Yes → 暂不做，先补短板

---

## 联系 Dexter Leng（关键动作）

Homerow + Vimac 同一作者，是这条赛道唯一走过完整周期的独立开发者。

**强烈建议第 2-3 周写邮件给他**：`dexter@homerow.app`

模板和理由见 business-plan.md 第 11 节。

---

## 文件夹结构（建议）

```
mouseless/
├── README.md              ← 你在这里
├── business-plan.md       ← 完整战略文档
├── prototype/             ← 第 1 周技术 spike（Xcode 项目）
├── research/              ← 用户访谈、竞品分析、AX API 笔记
├── content/               ← X 帖子草稿、demo 视频脚本
└── decisions/             ← 关键决策记录（ADR 风格）
```

---

## 下一步

打开 `business-plan.md`，对照第 9 节的 6 个问题给自己打分。先有诚实的自我判断，再决定要不要写第一行 Swift。
