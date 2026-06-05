# Licensing / 订阅 / 激活设计

> **状态：设计草稿，未实现**。上线收费前必做的基建。本文固化架构 + 选型 + 离线签名 token 流程 + v1 scope。
>
> 商业模式：**年付订阅**（不做月付 —— 目标用户效率极客对月付订阅疲劳反感）。

---

## 0. TL;DR

```
钱 + 账号 + 发票 + 税务 + license key + seat 限制  → 买 Merchant of Record（Lemon Squeezy）
离线能用 + 订阅失效要停 + 防篡改                     → 自建薄后端发 Ed25519 签名 entitlement token
反盗版                                              → 抬高随手盗版门槛即可，拦不住铁了心的，别过度投入
```

**核心原则：70% 不自己写。** 注册 / 登录 / invoices / 订阅管理 / 续费 / 退款 / 全球税务 / license key / 设备激活全部由 MoR 接管。自己只建一个**薄签名层**(让 token 离线可验、且订阅失效后会停)。

---

## 1. Merchant of Record：Lemon Squeezy

选 **Lemon Squeezy**（被 Stripe 收购）。它是 MoR —— **它是法律上的卖方，替我们收税报税**（全球 VAT / 销售税合规，独立开发者自己搞是噩梦）。一并提供：

- 托管 checkout（年付 product）
- **托管 customer portal**（邮箱 magic link 登录）→ 用户在这看 invoices、管订阅、取消、换卡 —— **我们一行 auth / invoice 代码都不用写**
- 内置 **license key API**：发 key、`activate` / `validate` / `deactivate` 实例、**activation 上限**（= seat 限制）
- 订阅生命周期 webhook（renewed / cancelled / payment_failed）

> 备选 Paddle（同为 MoR，licensing 略弱）。**不要 Stripe 直连** —— 那不是 MoR，要自己背全球税务。

**配置**：一个 annual subscription product；license key activation limit = **1**（见 §6 决策）。

---

## 2. 账号模型：不自建

app 内**没有账号系统、没有密码、没有登录页**。身份 = 邮箱，全部由 LS portal（magic link）处理。app 内用户只接触**一个 license key 输入框**。

- 买完 → LS 邮件发 license key
- 看发票 / 管订阅 → LS portal（app 里放个"Manage subscription"链接跳过去）
- app 激活 → 粘 key

---

## 3. 离线签名 token（唯一自建部分）

LS 的 license 校验是**在线 API**。但"没网也能用" + "订阅过期要停" 这两个需求纯在线校验满足不了。解法是签名 entitlement token。

### 3.1 薄后端（serverless）

一个无状态函数（Cloudflare Workers / Vercel / Lambda 皆可），持有 **Ed25519 私钥**（放 secret env），包装 LS API：

| 端点 | 干嘛 |
|---|---|
| `POST /activate {key, device_id}` | 调 LS `activate`（LS 强制 seat 上限=1）→ 成功则签发 token |
| `POST /refresh {key, device_id}` | 调 LS `validate` → 订阅 active 且 device 匹配 → 签发新 token |
| `POST /deactivate {key, device_id}` | 调 LS `deactivate` 释放 seat（换机用，见 §6） |

### 3.2 token 内容

Ed25519 签名的紧凑 JSON（或 EdDSA JWT）：

```jsonc
{
  "activation_id": "...",
  "device_id": "<SHA-256(IOPlatformUUID)>",   // 隐私：哈希后存
  "plan": "annual",
  "issued_at": 1730000000,
  "expires_at": 1730172800                     // = issued_at + GRACE(2 天)
}
```

**device_id** = Mac 硬件 UUID（IOKit `IOPlatformUUID`）的 SHA-256。不用 MAC 地址。

**expires_at = issued_at + 离线宽限**。token **故意短命**（2 天 TTL），这样订阅一旦失效，最后一个 token 最多 2 天后过期 → app 停。不在 token 里编码订阅到期日 —— 由后端"订阅不 active 就拒发新 token"来 gate。

### 3.3 app 侧验证（离线完成）

公钥**内嵌在 binary**。每次启动 + 周期性：

```
load 本地 token（Keychain）
verify Ed25519 签名（用内嵌公钥）+ expires_at > now ?
  是 → entitled，正常跑（零网络）
       若 online 且 token 已超 refreshInterval(~12h) → 后台静默 refresh
  否（过期 / 无 token）→ 尝试在线 refresh：
       成功 → 跑（拿到新 token）
       失败-没网 → 锁：「需要联网验证（离线已超 2 天）」
       失败-订阅失效 → 锁：「订阅已结束，请续费」
       无 token → trial 检查 / 激活界面
```

公钥内嵌、私钥只在服务器 → 用户改不了 token（改了验签即失败）。

---

## 4. 服务器沟通频率

| 时机 | 调用 |
|---|---|
| 激活（首次 + 换机） | `/activate` 一次 |
| 启动时 token 已超 ~12h | `/refresh` 一次 |
| 运行中每 ~12h | `/refresh` 一次（静默后台） |
| 其余时间 | **零网络，完全离线** |

normal use（每天联网）下 token 永远新鲜（每 12h 续）。**离线生存 = 2 天**（token TTL）；联网一次即刷新。

---

## 5. 没网能用吗

**能** —— 到当前 token 的 `expires_at`（= 上次刷新 + 2 天）为止。期间完全离线工作。超过 2 天没联网 → 锁，直到重新联网刷新。

> ⚠️ 2 天偏短，出差 / 飞行 / 无网环境 > 2 天会锁。`GRACE` 是一行常量，要放宽（如 7 天）随时改。

---

## 6. seat = 1 台 + 换机流程（必须项）

LS activation limit = **1**：一个 key 同时只能激活 1 台。

- 第 2 台激活 → LS 拒绝 → 后端返回「已在另一台激活，请先释放」→ app 提示 + 提供两条释放路径：
  1. **app 内「Deactivate this device」** → 调 `/deactivate` 释放当前 seat
  2. LS portal 里释放
- 换新 Mac：旧机 deactivate（app 内或 portal）→ 新机 activate

> ⚠️ 1 台对"台式 + 笔记本"的 power user 偏严，可能挡到正版多 Mac 用户。`activation limit` 在 LS 后台改成 2–3 随时可调。**但自助释放设备无论几台都是必须的**（否则换电脑卡死）。

---

## 7. Trial

年付是大承诺，买前必须能试。**14 天 trial，无需 key**：本地（Keychain）记首次启动时间戳。能被重置（删 Keychain 项），但 trial 低风险，无所谓 —— 别为这点投入侵入式防护。trial 期内全功能；到期 → 激活界面。

---

## 8. 反盗版：诚实的现实

**拦不住铁了心的破解者，追他们负 ROI。** 目标是把"随手盗版"门槛抬高，不是 Fort Knox。

- 签名 token 验签 + **app notarization**：破解者要 patch binary 跳过校验，但 patch 破坏 Apple 代码签名 → Gatekeeper 拦。能本地重签 / 关 Gatekeeper 绕过，但已经把"下个破解版双击就能用"的门槛抬掉。
- 几个**混淆 + 分散的验签点**（不止一处验 token）进一步抬门槛（v2）。
- **不做侵入式 DRM**（频繁强制联网、卡顿、误杀正版）—— 效率极客最恨，且照样被破。
- 接受破解版存在，精力放在**正版体验更好**（无缝续费、跨设备、好用）。Things / Bartender / Sketch 都是这个哲学，活得好。

---

## 9. v1 scope（上线必备）

- LS：annual product + license key，activation limit = 1，配 webhook
- 薄后端：serverless 函数，Ed25519 签名，包 LS `activate`/`validate`/`deactivate`
- app：
  - license key 输入 + `/activate`
  - token 存 Keychain，启动时内嵌公钥验签 + `expires_at` 检查
  - 后台 `/refresh`（启动 token>12h + 运行中每 12h）
  - `GRACE = 2 天` TTL
  - 状态 UI：trial / active / 离线超时锁 / 订阅失效锁 / 未激活
  - **「Deactivate this device」**（换机释放 seat）
  - "Manage subscription" → 跳 LS portal
- 14 天 trial（本地时间戳）

**之后（v2）**：

- 多验签点 + 混淆加固
- seat 管理 UI 优化
- `GRACE` / activation limit 按真实反馈调

---

## 10. 决策记录

1. **买 MoR 不自建** —— 注册/登录/invoice/税务/licensing 全外包，独立开发者别重造（尤其税务合规）
2. **Lemon Squeezy** —— MoR + 内置 licensing + 托管 portal，覆盖清单最全
3. **自建签名 token** —— 唯一必须自己写的，为了离线可用 + 订阅失效会停 + 防篡改
4. **seat = 1**（可调），**离线宽限 = 2 天**（可调），**v1 直接上签名 token**（不走"缓存+grace"过渡版）
5. **不做侵入式反盗版** —— 抬高随手盗版门槛即可
