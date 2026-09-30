# 增强目录
版本: 1.0.1n. 共 8 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [奖励牌 / m_bonus](#m-bonus)
- [倍率牌 / m_mult](#m-mult)
- [万能牌 / m_wild](#m-wild)
- [玻璃牌 / m_glass](#m-glass)
- [钢铁牌 / m_steel](#m-steel)
- [石头牌 / m_stone](#m-stone)
- [黄金牌 / m_gold](#m-gold)
- [幸运牌 / m_lucky](#m-lucky)

## 完整条目

<a id="m-bonus"></a>

### 2. 奖励牌 / Bonus Card

- ID: `m_bonus`.
- 效果: +30 额外筹码
- 原型参数: `{"bonus":30}`.
- 来源: [原型:648](<../../../game/game.lua#L648>).

<a id="m-mult"></a>

### 3. 倍率牌 / Mult Card

- ID: `m_mult`.
- 效果: +4 倍率
- 原型参数: `{"mult":4}`.
- 来源: [原型:649](<../../../game/game.lua#L649>).

<a id="m-wild"></a>

### 4. 万能牌 / Wild Card

- ID: `m_wild`.
- 效果: 可以视作 / 任何花色
- 来源: [原型:650](<../../../game/game.lua#L650>).

<a id="m-glass"></a>

### 5. 玻璃牌 / Glass Card

- ID: `m_glass`.
- 效果: X2 倍率 / 有[概率倍率 normal, 默认 1]/4 几率 / 摧毁此牌
- 原型参数: `{"Xmult":2,"extra":4}`.
- 来源: [原型:651](<../../../game/game.lua#L651>).

<a id="m-steel"></a>

### 6. 钢铁牌 / Steel Card

- ID: `m_steel`.
- 效果: 这张牌被 / 留在手牌中时 / 将给予 X1.5 倍率
- 原型参数: `{"h_x_mult":1.5}`.
- 来源: [原型:652](<../../../game/game.lua#L652>).

<a id="m-stone"></a>

### 7. 石头牌 / Stone Card

- ID: `m_stone`.
- 效果: +50 筹码 / 无点数无花色
- 原型参数: `{"bonus":50}`.
- 来源: [原型:653](<../../../game/game.lua#L653>).

<a id="m-gold"></a>

### 8. 黄金牌 / Gold Card

- ID: `m_gold`.
- 效果: 如果这张卡牌 / 在回合结束时还在手牌中 / 你获得 $3
- 原型参数: `{"h_dollars":3}`.
- 来源: [原型:654](<../../../game/game.lua#L654>).

<a id="m-lucky"></a>

### 9. 幸运牌 / Lucky Card

- ID: `m_lucky`.
- 效果: [概率倍率 normal, 默认 1]/5 几率 / +20 倍率 / [概率倍率 normal, 默认 1]/15 几率 / 获得 $20
- 原型参数: `{"mult":20,"p_dollars":20}`.
- 来源: [原型:655](<../../../game/game.lua#L655>).
