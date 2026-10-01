# 标签目录
版本: 1.0.1o. 共 24 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [罕见标签 / tag_uncommon](#tag-uncommon)
- [稀有标签 / tag_rare](#tag-rare)
- [负片标签 / tag_negative](#tag-negative)
- [闪箔标签 / tag_foil](#tag-foil)
- [镭射标签 / tag_holo](#tag-holo)
- [多彩标签 / tag_polychrome](#tag-polychrome)
- [投资标签 / tag_investment](#tag-investment)
- [优惠券标签 / tag_voucher](#tag-voucher)
- [Boss 标签 / tag_boss](#tag-boss)
- [标准标签 / tag_standard](#tag-standard)
- [吊饰标签 / tag_charm](#tag-charm)
- [流星标签 / tag_meteor](#tag-meteor)
- [小丑标签 / tag_buffoon](#tag-buffoon)
- [顺手标签 / tag_handy](#tag-handy)
- [垃圾标签 / tag_garbage](#tag-garbage)
- [空灵标签 / tag_ethereal](#tag-ethereal)
- [代金券标签 / tag_coupon](#tag-coupon)
- [双倍标签 / tag_double](#tag-double)
- [杂耍标签 / tag_juggle](#tag-juggle)
- [D6 标签 / tag_d_six](#tag-d-six)
- [充值标签 / tag_top_up](#tag-top-up)
- [速度标签 / tag_skip](#tag-skip)
- [轨道标签 / tag_orbital](#tag-orbital)
- [经济标签 / tag_economy](#tag-economy)

## 完整条目

<a id="tag-uncommon"></a>

### 1. 罕见标签 / Uncommon Tag

- ID: `tag_uncommon`.
- 效果: 商店会有一张免费的 / 罕见小丑牌
- 原型参数: `{"type":"store_joker_create"}`.
- 来源: [原型:225](<../../../game/game.lua#L225>).

<a id="tag-rare"></a>

### 2. 稀有标签 / Rare Tag

- ID: `tag_rare`.
- 效果: 商店会有一张免费的 / 稀有小丑牌
- 存档发现前置: `"j_blueprint"`.
- 原型参数: `{"odds":3,"type":"store_joker_create"}`.
- 来源: [原型:226](<../../../game/game.lua#L226>).

<a id="tag-negative"></a>

### 3. 负片标签 / Negative Tag

- ID: `tag_negative`.
- 效果: 商店里的下一张 / 基础版本小丑牌 / 将会免费且变为负片
- 存档发现前置: `"e_negative"`.
- 原型参数: `{"edition":"negative","odds":5,"type":"store_joker_modify"}`.
- 标签最早底注: 2.
- 来源: [原型:227](<../../../game/game.lua#L227>).

<a id="tag-foil"></a>

### 4. 闪箔标签 / Foil Tag

- ID: `tag_foil`.
- 效果: 商店里的下一张 / 基础版本小丑牌 / 将会免费且变为闪箔
- 存档发现前置: `"e_foil"`.
- 原型参数: `{"edition":"foil","odds":2,"type":"store_joker_modify"}`.
- 来源: [原型:228](<../../../game/game.lua#L228>).

<a id="tag-holo"></a>

### 5. 镭射标签 / Holographic Tag

- ID: `tag_holo`.
- 效果: 商店里的下一张 / 基础版本小丑牌 / 将会免费且变为镭射
- 存档发现前置: `"e_holo"`.
- 原型参数: `{"edition":"holo","odds":3,"type":"store_joker_modify"}`.
- 来源: [原型:229](<../../../game/game.lua#L229>).

<a id="tag-polychrome"></a>

### 6. 多彩标签 / Polychrome Tag

- ID: `tag_polychrome`.
- 效果: 商店里的下一张 / 基础版本小丑牌 / 将会免费且变为多彩
- 存档发现前置: `"e_polychrome"`.
- 原型参数: `{"edition":"polychrome","odds":4,"type":"store_joker_modify"}`.
- 来源: [原型:230](<../../../game/game.lua#L230>).

<a id="tag-investment"></a>

### 7. 投资标签 / Investment Tag

- ID: `tag_investment`.
- 效果: 击败 / Boss 盲注后 / 获得 $25
- 原型参数: `{"dollars":25,"type":"eval"}`.
- 来源: [原型:231](<../../../game/game.lua#L231>).

<a id="tag-voucher"></a>

### 8. 优惠券标签 / Voucher Tag

- ID: `tag_voucher`.
- 效果: 添加一张优惠券 / 到下一个商店
- 原型参数: `{"type":"voucher_add"}`.
- 来源: [原型:232](<../../../game/game.lua#L232>).

<a id="tag-boss"></a>

### 9. Boss 标签 / Boss Tag

- ID: `tag_boss`.
- 效果: 重掷 / Boss 盲注
- 原型参数: `{"type":"new_blind_choice"}`.
- 来源: [原型:233](<../../../game/game.lua#L233>).

<a id="tag-standard"></a>

### 10. 标准标签 / Standard Tag

- ID: `tag_standard`.
- 效果: 获得一个免费的 / 超级标准包
- 原型参数: `{"type":"new_blind_choice"}`.
- 标签最早底注: 2.
- 来源: [原型:234](<../../../game/game.lua#L234>).

<a id="tag-charm"></a>

### 11. 吊饰标签 / Charm Tag

- ID: `tag_charm`.
- 效果: 获得一个免费的 / 超级秘术包
- 原型参数: `{"type":"new_blind_choice"}`.
- 来源: [原型:235](<../../../game/game.lua#L235>).

<a id="tag-meteor"></a>

### 12. 流星标签 / Meteor Tag

- ID: `tag_meteor`.
- 效果: 获得一个免费的 / 超级天体包
- 原型参数: `{"type":"new_blind_choice"}`.
- 标签最早底注: 2.
- 来源: [原型:236](<../../../game/game.lua#L236>).

<a id="tag-buffoon"></a>

### 13. 小丑标签 / Buffoon Tag

- ID: `tag_buffoon`.
- 效果: 获得一个免费的 / 超级小丑包
- 原型参数: `{"type":"new_blind_choice"}`.
- 标签最早底注: 2.
- 来源: [原型:237](<../../../game/game.lua#L237>).

<a id="tag-handy"></a>

### 14. 顺手标签 / Handy Tag

- ID: `tag_handy`.
- 效果: 本赛局每打出过一次手牌 / 获得 $1 / (将得到 $[累计出牌次数])
- 原型参数: `{"dollars_per_hand":1,"type":"immediate"}`.
- 标签最早底注: 2.
- 来源: [原型:238](<../../../game/game.lua#L238>).

<a id="tag-garbage"></a>

### 15. 垃圾标签 / Garbage Tag

- ID: `tag_garbage`.
- 效果: 本赛局每一次 / 未使用的弃牌得到 $1 / (将得到 $[累计未用弃牌次数])
- 原型参数: `{"dollars_per_discard":1,"type":"immediate"}`.
- 标签最早底注: 2.
- 来源: [原型:239](<../../../game/game.lua#L239>).

<a id="tag-ethereal"></a>

### 16. 空灵标签 / Ethereal Tag

- ID: `tag_ethereal`.
- 效果: 获得一个免费的 / 幻灵包
- 原型参数: `{"type":"new_blind_choice"}`.
- 标签最早底注: 2.
- 来源: [原型:240](<../../../game/game.lua#L240>).

<a id="tag-coupon"></a>

### 17. 代金券标签 / Coupon Tag

- ID: `tag_coupon`.
- 效果: 下一家店内的 / 初始卡牌和补充包 / 均为免费
- 原型参数: `{"type":"shop_final_pass"}`.
- 来源: [原型:241](<../../../game/game.lua#L241>).

<a id="tag-double"></a>

### 18. 双倍标签 / Double Tag

- ID: `tag_double`.
- 效果: 下一次选定的标签 / 会额外获得一个复制品 / 双倍标签除外
- 原型参数: `{"type":"tag_add"}`.
- 来源: [原型:242](<../../../game/game.lua#L242>).

<a id="tag-juggle"></a>

### 19. 杂耍标签 / Juggle Tag

- ID: `tag_juggle`.
- 效果: 下一回合 / +3 手牌上限
- 原型参数: `{"h_size":3,"type":"round_start_bonus"}`.
- 来源: [原型:243](<../../../game/game.lua#L243>).

<a id="tag-d-six"></a>

### 20. D6 标签 / D6 Tag

- ID: `tag_d_six`.
- 效果: 下一个商店的 / 重掷起价为 $0
- 原型参数: `{"type":"shop_start"}`.
- 来源: [原型:244](<../../../game/game.lua#L244>).

<a id="tag-top-up"></a>

### 21. 充值标签 / Top-up Tag

- ID: `tag_top_up`.
- 效果: 生成最多 2 张 / 普通小丑牌 / (必须有空位)
- 原型参数: `{"spawn_jokers":2,"type":"immediate"}`.
- 标签最早底注: 2.
- 来源: [原型:245](<../../../game/game.lua#L245>).

<a id="tag-skip"></a>

### 22. 速度标签 / Speed Tag

- ID: `tag_skip`.
- 效果: 本赛局中每跳过 / 一次盲注,可获得 $5 / (将获得 $[累计跳过数含本次, 乘 5])
- 原型参数: `{"skip_bonus":5,"type":"immediate"}`.
- 来源: [原型:246](<../../../game/game.lua#L246>).

<a id="tag-orbital"></a>

### 23. 轨道标签 / Orbital Tag

- ID: `tag_orbital`.
- 效果: 升级[该标签指定牌型] / 3 个等级
- 原型参数: `{"levels":3,"type":"immediate"}`.
- 标签最早底注: 2.
- 来源: [原型:247](<../../../game/game.lua#L247>).

<a id="tag-economy"></a>

### 24. 经济标签 / Economy Tag

- ID: `tag_economy`.
- 效果: 资金翻倍 / (最高 $40)
- 原型参数: `{"max":40,"type":"immediate"}`.
- 来源: [原型:248](<../../../game/game.lua#L248>).
