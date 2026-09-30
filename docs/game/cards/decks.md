# 牌组目录
版本: 1.0.1n. 共 15 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [红色牌组 / b_red](#b-red)
- [蓝色牌组 / b_blue](#b-blue)
- [黄色牌组 / b_yellow](#b-yellow)
- [绿色牌组 / b_green](#b-green)
- [黑色牌组 / b_black](#b-black)
- [魔法牌组 / b_magic](#b-magic)
- [星云牌组 / b_nebula](#b-nebula)
- [幽灵牌组 / b_ghost](#b-ghost)
- [废弃牌组 / b_abandoned](#b-abandoned)
- [方格牌组 / b_checkered](#b-checkered)
- [黄道牌组 / b_zodiac](#b-zodiac)
- [彩绘牌组 / b_painted](#b-painted)
- [浮雕牌组 / b_anaglyph](#b-anaglyph)
- [等离子牌组 / b_plasma](#b-plasma)
- [古怪牌组 / b_erratic](#b-erratic)

## 完整条目

<a id="b-red"></a>

### 1. 红色牌组 / Red Deck

- ID: `b_red`.
- 新档初始解锁: true.
- 效果: 每回合 / +1 次弃牌
- 原型参数: `{"discards":1}`.
- 来源: [原型:628](<../../../game/game.lua#L628>).

<a id="b-blue"></a>

### 2. 蓝色牌组 / Blue Deck

- ID: `b_blue`.
- 新档初始解锁: false.
- 效果: 每回合 / +1 次出牌
- 解锁条件原型: `{"amount":20,"type":"discover_amount"}`.
- 原型参数: `{"hands":1}`.
- 来源: [原型:629](<../../../game/game.lua#L629>).

<a id="b-yellow"></a>

### 3. 黄色牌组 / Yellow Deck

- ID: `b_yellow`.
- 新档初始解锁: false.
- 效果: 开局时 / 额外获得 $10
- 解锁条件原型: `{"amount":50,"type":"discover_amount"}`.
- 原型参数: `{"dollars":10}`.
- 来源: [原型:630](<../../../game/game.lua#L630>).

<a id="b-green"></a>

### 4. 绿色牌组 / Green Deck

- ID: `b_green`.
- 新档初始解锁: false.
- 效果: 每回合结束时: / 每剩一次出牌次数,获得 $2 / 每剩一次弃牌次数,获得 $1 / 不赚取任何利息
- 解锁条件原型: `{"amount":75,"type":"discover_amount"}`.
- 原型参数: `{"extra_discard_bonus":1,"extra_hand_bonus":2,"no_interest":true}`.
- 来源: [原型:631](<../../../game/game.lua#L631>).

<a id="b-black"></a>

### 5. 黑色牌组 / Black Deck

- ID: `b_black`.
- 新档初始解锁: false.
- 效果: 小丑牌槽位+1 /  / 每回合 / 出牌次数-1
- 解锁条件原型: `{"amount":100,"type":"discover_amount"}`.
- 原型参数: `{"hands":-1,"joker_slot":1}`.
- 来源: [原型:632](<../../../game/game.lua#L632>).

<a id="b-magic"></a>

### 6. 魔法牌组 / Magic Deck

- ID: `b_magic`.
- 新档初始解锁: false.
- 效果: 开局时拥有 / 水晶球优惠券 / 和 2 张愚者
- 解锁条件原型: `{"deck":"b_red","type":"win_deck"}`.
- 原型参数: `{"consumables":["c_fool","c_fool"],"voucher":"v_crystal_ball"}`.
- 来源: [原型:633](<../../../game/game.lua#L633>).

<a id="b-nebula"></a>

### 7. 星云牌组 / Nebula Deck

- ID: `b_nebula`.
- 新档初始解锁: false.
- 效果: 开局时拥有 / 望远镜优惠券 / 消耗牌槽位-1
- 解锁条件原型: `{"deck":"b_blue","type":"win_deck"}`.
- 原型参数: `{"consumable_slot":-1,"voucher":"v_telescope"}`.
- 来源: [原型:634](<../../../game/game.lua#L634>).

<a id="b-ghost"></a>

### 8. 幽灵牌组 / Ghost Deck

- ID: `b_ghost`.
- 新档初始解锁: false.
- 效果: 商店中可能 / 出现幻灵牌 / 初始带有妖法牌
- 解锁条件原型: `{"deck":"b_yellow","type":"win_deck"}`.
- 原型参数: `{"consumables":["c_hex"],"spectral_rate":2}`.
- 来源: [原型:635](<../../../game/game.lua#L635>).

<a id="b-abandoned"></a>

### 9. 废弃牌组 / Abandoned Deck

- ID: `b_abandoned`.
- 新档初始解锁: false.
- 效果: 开局时 / 玩家牌组中 / 没有人头牌
- 解锁条件原型: `{"deck":"b_green","type":"win_deck"}`.
- 原型参数: `{"remove_faces":true}`.
- 来源: [原型:636](<../../../game/game.lua#L636>).

<a id="b-checkered"></a>

### 10. 方格牌组 / Checkered Deck

- ID: `b_checkered`.
- 新档初始解锁: false.
- 效果: 开局时 / 牌组中有 26 张黑桃和 / 26 张红桃
- 解锁条件原型: `{"deck":"b_black","type":"win_deck"}`.
- 来源: [原型:637](<../../../game/game.lua#L637>).

<a id="b-zodiac"></a>

### 11. 黄道牌组 / Zodiac Deck

- ID: `b_zodiac`.
- 新档初始解锁: false.
- 效果: 开局时即拥有 / 塔罗牌商人, / 星球牌商人, / 和库存过剩
- 解锁条件原型: `{"stake":2,"type":"win_stake"}`.
- 原型参数: `{"vouchers":["v_tarot_merchant","v_planet_merchant","v_overstock_norm"]}`.
- 来源: [原型:638](<../../../game/game.lua#L638>).

<a id="b-painted"></a>

### 12. 彩绘牌组 / Painted Deck

- ID: `b_painted`.
- 新档初始解锁: false.
- 效果: 手牌上限+2 / 小丑牌槽位-1
- 解锁条件原型: `{"stake":3,"type":"win_stake"}`.
- 原型参数: `{"hand_size":2,"joker_slot":-1}`.
- 来源: [原型:639](<../../../game/game.lua#L639>).

<a id="b-anaglyph"></a>

### 13. 浮雕牌组 / Anaglyph Deck

- ID: `b_anaglyph`.
- 新档初始解锁: false.
- 效果: 每次击败 Boss 盲注后 / 获得一个双倍标签
- 解锁条件原型: `{"stake":4,"type":"win_stake"}`.
- 来源: [原型:640](<../../../game/game.lua#L640>).

<a id="b-plasma"></a>

### 14. 等离子牌组 / Plasma Deck

- ID: `b_plasma`.
- 新档初始解锁: false.
- 效果: 计算出牌分数时 / 平衡筹码和倍率 / 盲注要求分数 X2
- 解锁条件原型: `{"stake":5,"type":"win_stake"}`.
- 原型参数: `{"ante_scaling":2}`.
- 来源: [原型:641](<../../../game/game.lua#L641>).

<a id="b-erratic"></a>

### 15. 古怪牌组 / Erratic Deck

- ID: `b_erratic`.
- 新档初始解锁: false.
- 效果: 牌组中所有牌的 / 点数和花色 / 都是随机的
- 解锁条件原型: `{"stake":7,"type":"win_stake"}`.
- 原型参数: `{"randomize_rank_suit":true}`.
- 来源: [原型:642](<../../../game/game.lua#L642>).
