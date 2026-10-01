# 幻灵牌目录
版本: 1.0.1o. 共 18 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [使魔 / c_familiar](#c-familiar)
- [严峻 / c_grim](#c-grim)
- [咒语 / c_incantation](#c-incantation)
- [护身符 / c_talisman](#c-talisman)
- [光环 / c_aura](#c-aura)
- [幽灵 / c_wraith](#c-wraith)
- [符印 / c_sigil](#c-sigil)
- [占卜 / c_ouija](#c-ouija)
- [灵质 / c_ectoplasm](#c-ectoplasm)
- [火祭 / c_immolate](#c-immolate)
- [生命十字章 / c_ankh](#c-ankh)
- [既视感 / c_deja_vu](#c-deja-vu)
- [妖法 / c_hex](#c-hex)
- [入迷 / c_trance](#c-trance)
- [灵媒 / c_medium](#c-medium)
- [神秘生物 / c_cryptid](#c-cryptid)
- [灵魂 / c_soul](#c-soul)
- [黑洞 / c_black_hole](#c-black-hole)

## 完整条目

<a id="c-familiar"></a>

### 1. 使魔 / Familiar

- ID: `c_familiar`.
- 基价: $4.
- 效果: 随机摧毁 1 张手牌 / 并添加 3 张 / 随机增强的人头牌 / 到手牌中
- 原型参数: `{"extra":3,"remove_card":true}`.
- 来源: [原型:571](<../../../game/game.lua#L571>).

<a id="c-grim"></a>

### 2. 严峻 / Grim

- ID: `c_grim`.
- 基价: $4.
- 效果: 随机摧毁 1 张手牌 / 并添加 2 张 / 随机增强的 A / 到手牌中
- 原型参数: `{"extra":2,"remove_card":true}`.
- 来源: [原型:572](<../../../game/game.lua#L572>).

<a id="c-incantation"></a>

### 3. 咒语 / Incantation

- ID: `c_incantation`.
- 基价: $4.
- 效果: 随机摧毁 1 张手牌 / 并添加 4 张 / 随机增强的数字牌 / 到手牌中
- 原型参数: `{"extra":4,"remove_card":true}`.
- 来源: [原型:573](<../../../game/game.lua#L573>).

<a id="c-talisman"></a>

### 4. 护身符 / Talisman

- ID: `c_talisman`.
- 基价: $4.
- 效果: 将金色蜡封添加到 / 1 张选定的 / 手牌中
- 原型参数: `{"extra":"Gold","max_highlighted":1}`.
- 来源: [原型:574](<../../../game/game.lua#L574>).

<a id="c-aura"></a>

### 5. 光环 / Aura

- ID: `c_aura`.
- 基价: $4.
- 效果: 选定 1 张手牌,为其添加 / 闪箔卡,镭射卡,或多彩卡 / 效果中的一种
- 来源: [原型:575](<../../../game/game.lua#L575>).

<a id="c-wraith"></a>

### 6. 幽灵 / Wraith

- ID: `c_wraith`.
- 基价: $4.
- 效果: 生成一张随机的 / 稀有小丑牌 / 将资金变为 $0
- 来源: [原型:576](<../../../game/game.lua#L576>).

<a id="c-sigil"></a>

### 7. 符印 / Sigil

- ID: `c_sigil`.
- 基价: $4.
- 效果: 将手中所有 / 卡牌转换为同一种 / 随机花色
- 来源: [原型:577](<../../../game/game.lua#L577>).

<a id="c-ouija"></a>

### 8. 占卜 / Ouija

- ID: `c_ouija`.
- 基价: $4.
- 效果: 将手中所有 / 手持牌转换为同一个 / 随机点数 / 手牌上限-1
- 来源: [原型:578](<../../../game/game.lua#L578>).

<a id="c-ectoplasm"></a>

### 9. 灵质 / Ectoplasm

- ID: `c_ectoplasm`.
- 基价: $4.
- 效果: 添加负片效果到 / 一张随机的小丑牌 / 手牌上限-[本局灵质使用次数加 1]
- 来源: [原型:579](<../../../game/game.lua#L579>).

<a id="c-immolate"></a>

### 10. 火祭 / Immolate

- ID: `c_immolate`.
- 基价: $4.
- 效果: 随机摧毁 / 5 张手牌 / 获得 $20
- 原型参数: `{"extra":{"destroy":5,"dollars":20},"remove_card":true}`.
- 来源: [原型:580](<../../../game/game.lua#L580>).

<a id="c-ankh"></a>

### 11. 生命十字章 / Ankh

- ID: `c_ankh`.
- 基价: $4.
- 效果: 随机复制一张 / 小丑牌,摧毁 / 其他小丑牌
- 原型参数: `{"extra":2}`.
- 来源: [原型:581](<../../../game/game.lua#L581>).

<a id="c-deja-vu"></a>

### 12. 既视感 / Deja Vu

- ID: `c_deja_vu`.
- 基价: $4.
- 效果: 给你手牌中的 / 1 张所选卡牌 / 加上红色蜡封
- 原型参数: `{"extra":"Red","max_highlighted":1}`.
- 来源: [原型:582](<../../../game/game.lua#L582>).

<a id="c-hex"></a>

### 13. 妖法 / Hex

- ID: `c_hex`.
- 基价: $4.
- 效果: 随机为一张小丑牌添加 / 多彩,摧毁 / 其他小丑牌
- 原型参数: `{"extra":2}`.
- 来源: [原型:583](<../../../game/game.lua#L583>).

<a id="c-trance"></a>

### 14. 入迷 / Trance

- ID: `c_trance`.
- 基价: $4.
- 效果: 给你手牌中的 / 1 张所选卡牌 / 加上蓝色蜡封
- 原型参数: `{"extra":"Blue","max_highlighted":1}`.
- 来源: [原型:584](<../../../game/game.lua#L584>).

<a id="c-medium"></a>

### 15. 灵媒 / Medium

- ID: `c_medium`.
- 基价: $4.
- 效果: 给你手牌中的 / 1 张所选卡牌 / 加上紫色蜡封
- 原型参数: `{"extra":"Purple","max_highlighted":1}`.
- 来源: [原型:585](<../../../game/game.lua#L585>).

<a id="c-cryptid"></a>

### 16. 神秘生物 / Cryptid

- ID: `c_cryptid`.
- 基价: $4.
- 效果: 选定手牌中的 1 张牌 / 生成 2 张其复制牌
- 原型参数: `{"extra":2,"max_highlighted":1}`.
- 来源: [原型:586](<../../../game/game.lua#L586>).

<a id="c-soul"></a>

### 17. 灵魂 / The Soul

- ID: `c_soul`.
- 基价: $4.
- 效果: 生成一张 / 传奇小丑牌 / (必须有空位)
- 来源: [原型:587](<../../../game/game.lua#L587>).

<a id="c-black-hole"></a>

### 18. 黑洞 / Black Hole

- ID: `c_black_hole`.
- 基价: $4.
- 效果: 所有牌型 / 提升 1 级
- 来源: [原型:588](<../../../game/game.lua#L588>).
