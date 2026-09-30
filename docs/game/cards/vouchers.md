# 优惠券目录
版本: 1.0.1n. 共 32 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [库存过剩 / v_overstock_norm](#v-overstock-norm)
- [库存过剩加强版 / v_overstock_plus](#v-overstock-plus)
- [清仓特卖 / v_clearance_sale](#v-clearance-sale)
- [清算 / v_liquidation](#v-liquidation)
- [打磨 / v_hone](#v-hone)
- [焕彩 / v_glow_up](#v-glow-up)
- [多次重掷 / v_reroll_surplus](#v-reroll-surplus)
- [重掷加強版 / v_reroll_glut](#v-reroll-glut)
- [水晶球 / v_crystal_ball](#v-crystal-ball)
- [预兆球 / v_omen_globe](#v-omen-globe)
- [望远镜 / v_telescope](#v-telescope)
- [天文台 / v_observatory](#v-observatory)
- [抓手 / v_grabber](#v-grabber)
- [玉米片夹 / v_nacho_tong](#v-nacho-tong)
- [常弃常新 / v_wasteful](#v-wasteful)
- [回收魔法 / v_recyclomancy](#v-recyclomancy)
- [塔罗牌商人 / v_tarot_merchant](#v-tarot-merchant)
- [塔罗大亨 / v_tarot_tycoon](#v-tarot-tycoon)
- [星球牌商人 / v_planet_merchant](#v-planet-merchant)
- [星球大亨 / v_planet_tycoon](#v-planet-tycoon)
- [种子基金 / v_seed_money](#v-seed-money)
- [摇钱树 / v_money_tree](#v-money-tree)
- [空白 / v_blank](#v-blank)
- [反物质 / v_antimatter](#v-antimatter)
- [魔术 / v_magic_trick](#v-magic-trick)
- [幻象 / v_illusion](#v-illusion)
- [象形文字 / v_hieroglyph](#v-hieroglyph)
- [岩画 / v_petroglyph](#v-petroglyph)
- [导演剪辑版 / v_directors_cut](#v-directors-cut)
- [重构 / v_retcon](#v-retcon)
- [油漆刷 / v_paint_brush](#v-paint-brush)
- [调色板 / v_palette](#v-palette)

## 完整条目

<a id="v-overstock-norm"></a>

### 1. 库存过剩 / Overstock

- ID: `v_overstock_norm`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 商店內 / 卡牌槽位+1
- 来源: [原型:592](<../../../game/game.lua#L592>).

<a id="v-overstock-plus"></a>

### 2. 库存过剩加强版 / Overstock Plus

- ID: `v_overstock_plus`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 商店内 / 卡牌槽位+1
- 解锁说明: 在商店内总共花费 / $2500 / ($[当前存档累计值])
- 解锁条件原型: `{"extra":2500,"type":"c_shop_dollars_spent"}`.
- 本局已兑换前置: `["v_overstock_norm"]`.
- 来源: [原型:609](<../../../game/game.lua#L609>).

<a id="v-clearance-sale"></a>

### 3. 清仓特卖 / Clearance Sale

- ID: `v_clearance_sale`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 所有卡牌,补充包和优惠券 / 在店内均可享受 25%折扣
- 原型参数: `{"extra":25}`.
- 来源: [原型:593](<../../../game/game.lua#L593>).

<a id="v-liquidation"></a>

### 4. 清算 / Liquidation

- ID: `v_liquidation`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 所有卡牌,补充包和优惠券 / 在店内均可享受 50%折扣
- 解锁说明: 在一场赛局中 / 至少兑换 / 10 张优惠券
- 解锁条件原型: `{"extra":10,"type":"run_redeem"}`.
- 本局已兑换前置: `["v_clearance_sale"]`.
- 原型参数: `{"extra":50}`.
- 来源: [原型:610](<../../../game/game.lua#L610>).

<a id="v-hone"></a>

### 5. 打磨 / Hone

- ID: `v_hone`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 闪箔卡,镭射卡和 / 多彩卡 / 出现频率 X2
- 原型参数: `{"extra":2}`.
- 来源: [原型:594](<../../../game/game.lua#L594>).

<a id="v-glow-up"></a>

### 6. 焕彩 / Glow Up

- ID: `v_glow_up`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 闪箔卡,镭射卡和 / 多彩卡 / 出现频率 X4
- 解锁说明: 同时拥有至少 5 张 / 闪箔卡,镭射卡,或 / 多彩卡版本的小丑牌
- 解锁条件原型: `{"extra":5,"type":"have_edition"}`.
- 本局已兑换前置: `["v_hone"]`.
- 原型参数: `{"extra":4}`.
- 来源: [原型:611](<../../../game/game.lua#L611>).

<a id="v-reroll-surplus"></a>

### 7. 多次重掷 / Reroll Surplus

- ID: `v_reroll_surplus`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 重掷费用 / 减少 $2
- 原型参数: `{"extra":2}`.
- 来源: [原型:595](<../../../game/game.lua#L595>).

<a id="v-reroll-glut"></a>

### 8. 重掷加強版 / Reroll Glut

- ID: `v_reroll_glut`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 重掷费用 / 减少 $2
- 解锁说明: 重掷商店 / 总共 100 次 / ([当前存档累计值])
- 解锁条件原型: `{"extra":100,"type":"c_shop_rerolls"}`.
- 本局已兑换前置: `["v_reroll_surplus"]`.
- 原型参数: `{"extra":2}`.
- 来源: [原型:612](<../../../game/game.lua#L612>).

<a id="v-crystal-ball"></a>

### 9. 水晶球 / Crystal Ball

- ID: `v_crystal_ball`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 消耗牌槽位+1
- 原型参数: `{"extra":3}`.
- 来源: [原型:596](<../../../game/game.lua#L596>).

<a id="v-omen-globe"></a>

### 10. 预兆球 / Omen Globe

- ID: `v_omen_globe`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 幻灵牌可能 / 会在任何 / 秘术包中出现
- 解锁说明: 从任何秘术包中 / 总共使用 25 张 / 塔罗牌 / ([当前存档累计值])
- 解锁条件原型: `{"extra":25,"type":"c_tarot_reading_used"}`.
- 本局已兑换前置: `["v_crystal_ball"]`.
- 原型参数: `{"extra":4}`.
- 来源: [原型:613](<../../../game/game.lua#L613>).

<a id="v-telescope"></a>

### 11. 望远镜 / Telescope

- ID: `v_telescope`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 天体包中的 / 星球牌始终有 / 你最常用的 / 的牌型
- 原型参数: `{"extra":3}`.
- 来源: [原型:597](<../../../game/game.lua#L597>).

<a id="v-observatory"></a>

### 12. 天文台 / Observatory

- ID: `v_observatory`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 在您消耗牌栏位中 / 的星球牌 / 会使这一特定牌型 / 给予 X1.5 倍率
- 解锁说明: 从任何天体包中 / 总共使用 25 张 / 星球牌 / ([当前存档累计值])
- 解锁条件原型: `{"extra":25,"type":"c_planetarium_used"}`.
- 本局已兑换前置: `["v_telescope"]`.
- 原型参数: `{"extra":1.5}`.
- 来源: [原型:614](<../../../game/game.lua#L614>).

<a id="v-grabber"></a>

### 13. 抓手 / Grabber

- ID: `v_grabber`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 每回合 / 出牌次数 / 永久+1
- 原型参数: `{"extra":1}`.
- 来源: [原型:598](<../../../game/game.lua#L598>).

<a id="v-nacho-tong"></a>

### 14. 玉米片夹 / Nacho Tong

- ID: `v_nacho_tong`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 每回合 / 出牌次数 / 永久+1
- 解锁说明: 打出总共 / 2500 张卡牌 / ([当前存档累计值])
- 解锁条件原型: `{"extra":2500,"type":"c_cards_played"}`.
- 本局已兑换前置: `["v_grabber"]`.
- 原型参数: `{"extra":1}`.
- 来源: [原型:615](<../../../game/game.lua#L615>).

<a id="v-wasteful"></a>

### 15. 常弃常新 / Wasteful

- ID: `v_wasteful`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 每回合 / 弃牌次数 / 永久+1
- 原型参数: `{"extra":1}`.
- 来源: [原型:599](<../../../game/game.lua#L599>).

<a id="v-recyclomancy"></a>

### 16. 回收魔法 / Recyclomancy

- ID: `v_recyclomancy`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 每回合 / 弃牌次数 / 永久+1
- 解锁说明: 弃掉总共 / 2500 张卡牌 / ([当前存档累计值])
- 解锁条件原型: `{"extra":2500,"type":"c_cards_discarded"}`.
- 本局已兑换前置: `["v_wasteful"]`.
- 原型参数: `{"extra":1}`.
- 来源: [原型:616](<../../../game/game.lua#L616>).

<a id="v-tarot-merchant"></a>

### 17. 塔罗牌商人 / Tarot Merchant

- ID: `v_tarot_merchant`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 商店内 / 塔罗牌 / 出现频率 X2
- 原型参数: `{"extra":2.4,"extra_disp":2}`.
- 来源: [原型:600](<../../../game/game.lua#L600>).

<a id="v-tarot-tycoon"></a>

### 18. 塔罗大亨 / Tarot Tycoon

- ID: `v_tarot_tycoon`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 商店内 / 塔罗牌 / 出现频率 X4
- 解锁说明: 在商店 / 购买总计 / 50 张塔罗牌 / ([当前存档累计值])
- 解锁条件原型: `{"extra":50,"type":"c_tarots_bought"}`.
- 本局已兑换前置: `["v_tarot_merchant"]`.
- 原型参数: `{"extra":8,"extra_disp":4}`.
- 来源: [原型:617](<../../../game/game.lua#L617>).

<a id="v-planet-merchant"></a>

### 19. 星球牌商人 / Planet Merchant

- ID: `v_planet_merchant`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 商店内 / 星球牌 / 出现频率 X2
- 原型参数: `{"extra":2.4,"extra_disp":2}`.
- 来源: [原型:601](<../../../game/game.lua#L601>).

<a id="v-planet-tycoon"></a>

### 20. 星球大亨 / Planet Tycoon

- ID: `v_planet_tycoon`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 商店内 / 星球牌 / 出现频率 X4
- 解锁说明: 在商店 / 购买总计 / 50 张星球牌 / ([当前存档累计值])
- 解锁条件原型: `{"extra":50,"type":"c_planets_bought"}`.
- 本局已兑换前置: `["v_planet_merchant"]`.
- 原型参数: `{"extra":8,"extra_disp":4}`.
- 来源: [原型:618](<../../../game/game.lua#L618>).

<a id="v-seed-money"></a>

### 21. 种子基金 / Seed Money

- ID: `v_seed_money`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 每回合 / 可获得利息的上限 / 提高到 $10
- 原型参数: `{"extra":50}`.
- 来源: [原型:602](<../../../game/game.lua#L602>).

<a id="v-money-tree"></a>

### 22. 摇钱树 / Money Tree

- ID: `v_money_tree`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 每回合 / 可获得利息的上限 / 提高到 $20
- 解锁说明: 连续 10 回合 / 在计算收益时 / 获得的利息到达上限 / ([当前存档累计值])
- 解锁条件原型: `{"extra":10,"type":"interest_streak"}`.
- 本局已兑换前置: `["v_seed_money"]`.
- 原型参数: `{"extra":100}`.
- 来源: [原型:619](<../../../game/game.lua#L619>).

<a id="v-blank"></a>

### 23. 空白 / Blank

- ID: `v_blank`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 什么都没有?
- 原型参数: `{"extra":5}`.
- 来源: [原型:603](<../../../game/game.lua#L603>).

<a id="v-antimatter"></a>

### 24. 反物质 / Antimatter

- ID: `v_antimatter`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 小丑牌槽位+1
- 解锁说明: 兑换空白优惠券 / 总计 10 次 / ([当前存档空白兑换次数])
- 解锁条件原型: `{"extra":10,"type":"blank_redeems"}`.
- 本局已兑换前置: `["v_blank"]`.
- 原型参数: `{"extra":15}`.
- 来源: [原型:620](<../../../game/game.lua#L620>).

<a id="v-magic-trick"></a>

### 25. 魔术 / Magic Trick

- ID: `v_magic_trick`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 商店里面 / 有游戏牌 / 可供选购
- 原型参数: `{"extra":4}`.
- 来源: [原型:604](<../../../game/game.lua#L604>).

<a id="v-illusion"></a>

### 26. 幻象 / Illusion

- ID: `v_illusion`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 商店内的游戏牌 / 可以是增强卡牌, / 不同版本,和/或蜡封
- 解锁说明: 在商店 / 购买总计 / 20 张游戏牌 / ([当前存档累计值])
- 解锁条件原型: `{"extra":20,"type":"c_playing_cards_bought"}`.
- 本局已兑换前置: `["v_magic_trick"]`.
- 原型参数: `{"extra":4}`.
- 来源: [原型:621](<../../../game/game.lua#L621>).

<a id="v-hieroglyph"></a>

### 27. 象形文字 / Hieroglyph

- ID: `v_hieroglyph`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 底注-1 / 每回合 / 出牌次数-1
- 原型参数: `{"extra":1}`.
- 来源: [原型:605](<../../../game/game.lua#L605>).

<a id="v-petroglyph"></a>

### 28. 岩画 / Petroglyph

- ID: `v_petroglyph`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 底注-1 / 每回合 / 弃牌次数-1
- 解锁说明: 达到底注 / 等级 12
- 解锁条件原型: `{"ante":12,"extra":12,"type":"ante_up"}`.
- 本局已兑换前置: `["v_hieroglyph"]`.
- 原型参数: `{"extra":1}`.
- 来源: [原型:622](<../../../game/game.lua#L622>).

<a id="v-directors-cut"></a>

### 29. 导演剪辑版 / Director's Cut

- ID: `v_directors_cut`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 可以重掷 Boss 盲注 / 每个底注限重掷 1 次 / 每次花费 $10
- 原型参数: `{"extra":10}`.
- 来源: [原型:606](<../../../game/game.lua#L606>).

<a id="v-retcon"></a>

### 30. 重构 / Retcon

- ID: `v_retcon`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 重掷 Boss 盲注 / 不限次数 / 每次重掷花费 $10
- 解锁说明: 发现 / 25 盲注
- 解锁条件原型: `{"extra":25,"type":"blind_discoveries"}`.
- 本局已兑换前置: `["v_directors_cut"]`.
- 原型参数: `{"extra":10}`.
- 来源: [原型:623](<../../../game/game.lua#L623>).

<a id="v-paint-brush"></a>

### 31. 油漆刷 / Paint Brush

- ID: `v_paint_brush`.
- 基价: $10.
- 新档初始解锁: true.
- 效果: 手牌上限+1
- 原型参数: `{"extra":1}`.
- 来源: [原型:607](<../../../game/game.lua#L607>).

<a id="v-palette"></a>

### 32. 调色板 / Palette

- ID: `v_palette`.
- 基价: $10.
- 新档初始解锁: false.
- 效果: 手牌上限+1
- 解锁说明: 手牌上限减少 / 至 5 张
- 解锁条件原型: `{"extra":5,"type":"min_hand_size"}`.
- 本局已兑换前置: `["v_paint_brush"]`.
- 原型参数: `{"extra":1}`.
- 来源: [原型:624](<../../../game/game.lua#L624>).
