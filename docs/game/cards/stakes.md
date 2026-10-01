# 赌注目录
版本: 1.0.1o. 共 8 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [白注 / stake_white](#stake-white)
- [红注 / stake_red](#stake-red)
- [绿注 / stake_green](#stake-green)
- [黑注 / stake_black](#stake-black)
- [蓝注 / stake_blue](#stake-blue)
- [紫注 / stake_purple](#stake-purple)
- [橙注 / stake_orange](#stake-orange)
- [金注 / stake_gold](#stake-gold)

## 完整条目

<a id="stake-white"></a>

### 1. 白注 / White Stake

- ID: `stake_white`.
- 新档初始解锁: true.
- 效果: 基础难度
- 来源: [原型:253](<../../../game/game.lua#L253>).

<a id="stake-red"></a>

### 2. 红注 / Red Stake

- ID: `stake_red`.
- 新档初始解锁: false.
- 效果: 小盲注 / 没有奖励金 / 之前所有赌注也都起效
- 来源: [原型:254](<../../../game/game.lua#L254>).

<a id="stake-green"></a>

### 3. 绿注 / Green Stake

- ID: `stake_green`.
- 新档初始解锁: false.
- 效果: 底注提升时 / 过关需求分数的增速更快 / 之前所有赌注也都起效
- 来源: [原型:255](<../../../game/game.lua#L255>).

<a id="stake-black"></a>

### 4. 黑注 / Black Stake

- ID: `stake_black`.
- 新档初始解锁: false.
- 效果: 商店可能会出现永恒小丑牌 / (无法卖出或摧毁) / 之前所有赌注也都起效
- 来源: [原型:256](<../../../game/game.lua#L256>).

<a id="stake-blue"></a>

### 5. 蓝注 / Blue Stake

- ID: `stake_blue`.
- 新档初始解锁: false.
- 效果: 弃牌次数-1 / 之前所有赌注也都起效
- 来源: [原型:257](<../../../game/game.lua#L257>).

<a id="stake-purple"></a>

### 6. 紫注 / Purple Stake

- ID: `stake_purple`.
- 新档初始解锁: false.
- 效果: 底注提升时 / 过关需求分数的增速更快 / 之前所有赌注也都起效
- 来源: [原型:258](<../../../game/game.lua#L258>).

<a id="stake-orange"></a>

### 7. 橙注 / Orange Stake

- ID: `stake_orange`.
- 新档初始解锁: false.
- 效果: 商店可能会出现易腐小丑牌 / (经过 5 回合后被削弱) / 之前所有赌注也都起效
- 来源: [原型:259](<../../../game/game.lua#L259>).

<a id="stake-gold"></a>

### 8. 金注 / Gold Stake

- ID: `stake_gold`.
- 新档初始解锁: false.
- 效果: 商店可能会出现租用小丑牌 / (售价为 $1,每回合花费 $3) / 之前所有赌注也都起效
- 来源: [原型:260](<../../../game/game.lua#L260>).
