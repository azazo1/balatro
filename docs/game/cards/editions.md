# 版本目录
版本: 1.0.1n. 共 5 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [基础 / e_base](#e-base)
- [闪箔 / e_foil](#e-foil)
- [镭射 / e_holo](#e-holo)
- [多彩 / e_polychrome](#e-polychrome)
- [负片 / e_negative](#e-negative)

## 完整条目

<a id="e-base"></a>

### 1. 基础 / Base

- ID: `e_base`.
- 新档初始解锁: true.
- 效果: 无额外效果
- 来源: [原型:658](<../../../game/game.lua#L658>).

<a id="e-foil"></a>

### 2. 闪箔 / Foil

- ID: `e_foil`.
- 新档初始解锁: true.
- 效果: +50 筹码
- 原型参数: `{"extra":50}`.
- 来源: [原型:659](<../../../game/game.lua#L659>).

<a id="e-holo"></a>

### 3. 镭射 / Holographic

- ID: `e_holo`.
- 新档初始解锁: true.
- 效果: +10 倍率
- 原型参数: `{"extra":10}`.
- 来源: [原型:660](<../../../game/game.lua#L660>).

<a id="e-polychrome"></a>

### 4. 多彩 / Polychrome

- ID: `e_polychrome`.
- 新档初始解锁: true.
- 效果: X1.5 倍率
- 原型参数: `{"extra":1.5}`.
- 来源: [原型:661](<../../../game/game.lua#L661>).

<a id="e-negative"></a>

### 5. 负片 / Negative

- ID: `e_negative`.
- 新档初始解锁: true.
- 效果: +1 个小丑牌槽位
- 原型参数: `{"extra":1}`.
- 来源: [原型:662](<../../../game/game.lua#L662>).
