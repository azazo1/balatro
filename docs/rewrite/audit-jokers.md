# 小丑系统审计

## 范围与证据层级

从 [游戏原型定义](<../../game/game.lua#L368-L526>) 枚举 order=1..150, 恰好 150 张, 没有以文档列举替代源码枚举. 同时检查 [小丑本体](<../../engine/src/jokers/mod.rs>) 的具名分支, 以及 [流程](<../../engine/src/run/flow.rs>), [计分](<../../engine/src/scoring/engine.rs>), [生成](<../../engine/src/run/shop.rs>) 和池子对原型的引用.

- 84 张有本体具名分支, 包括构造特殊值, before, individual, held, repetition, after, other_joker, discard, end_of_round 和 joker_main.
- 16 张走 config 通用分支: Joker, 10 张 t_mult/t_chips 条件小丑, 5 张牌型 Xmult 小丑. 检查配置值, 包含关系和 main 分支优先级.
- 其余 50 张属于流程, 生成, 牌型规则, 复制调度或固定被动. 无本体分支不等于未实现. 跨域规则按实际入口对照源码, 实现和整体验收由对应领域及中央测试负责.
- 对照了 [补丁后的 Card](<../../.tmp/engine-audit/modded-tree/card.lua#L2660-L4419>) 的完整 calculate_joker 各阶段, [Steamodded 复制函数](<../../mods/Steamodded/src/utils.lua#L2385-L2410>) 与 [眼观双路辅助函数](<../../mods/Steamodded/src/utils.lua#L2790-L2813>), 不是只读原版.
- S = 静态逐分支对照. T = 关键 Rust 回归通过. L = 提取补丁树实际 calculate_joker 并由 LuaJIT 执行, 使用隔离 GUI/事件/概率的最小宿主. L 不是完整游戏对拍, 不证明 UI, 事件队列或所有跨阶段行为.
- 全表达到 S 层级. 只有明确列出的关键分支达到 T/L. 不宣称全部 150 张都经过游戏完整对局验证.
- 最后独立执行的小丑专项组合为 16 项本体回归, 8 项动态被动回归和 72 项原有测试, 合计 96/96, exit 0. 此后 originVec 模型迁移和全套测试的验收由中央报告负责, 不能用该局部结果替代全套验收.

补丁树位于本地临时目录, 下文链接保留了实际生成源码的精确位置. 在没有该临时树的 checkout 中, 应根据游戏源码和当前 Steamodded 补丁重建后检查, 而不是把缺少本地产物当作不存在该规则.

## 已修本体差异

1. 花色逻辑统一为 TriggerContext.is_suit, 检查百搭, 模糊小丑, 石头牌无花色和 debuff. 涉及 4 花色小丑, 璞玉, 缟玛瑙, 箭头, 血石, 上古小丑, 爱豆, 黑板和城堡. 证据: [补丁卡牌花色入口](<../../.tmp/engine-audit/modded-tree/card.lua#L4429-L4460>), [原版原始入口](<../../game/card.lua#L4064-L4088>).
2. 石头牌的底牌 rank 不能触发数字, 人头与 rank retrigger. 改用 HandCard.id, is_face 对石头默认 false, 帕瑞多利亚可赋予面牌身份. 涉及斐波那契, 偶数史蒂文, 奇数托德, 学者, 对讲机, 特里布莱, 八号球, 烂脱口秀演员, 射月, 男爵, 天涯路和叠加态. 证据: [补丁 get_id/is_face](<../../.tmp/engine-audit/modded-tree/card.lua#L1174-L1188>).
3. 花盆先非百搭每牌分配一个未占花色, 再每百搭补一个, 非百搭可 bypass_debuff, 百搭不可. 不再直接排除百搭. 证据: [实际花盆分支](<../../.tmp/engine-audit/modded-tree/card.lua#L4193-L4225>). S/T/L.
4. 眼观双路采用 Steamodded helper 的百搭分配, 允许模糊小丑将普通牌计入同色两种. 单百搭仍不能独自满足两种花色. 证据: [helper](<../../mods/Steamodded/src/utils.lua#L2790-L2813>). S/T.
5. 黑板用效果花色判定. 百搭可算黑色, 石头和削弱手牌不算花色. 证据: [主效果分支](<../../.tmp/engine-audit/modded-tree/card.lua#L4312-L4325>). S/T.
6. 致胜之拳同最小点数选最右, 最小牌削弱时不改选另一同点数牌. 证据: [实际 held 分支](<../../.tmp/engine-audit/modded-tree/card.lua#L3712-L3733>). S/T/L.
7. 搭乘巴士只看计分牌, 不看未计分面牌. 证据: [before](<../../.tmp/engine-audit/modded-tree/card.lua#L3924-L3946>). S/T.
8. 绿色小丑按配置 hand_add/discard_sub, 弃牌倍率下界 0, 削弱不成长. 城堡每张合格弃牌各增长, 排除石头/削弱, 支持 wild/smeared. 无面者与天涯路同样修正石头 rank. 证据: [discard](<../../.tmp/engine-audit/modded-tree/card.lua#L3215-L3280>). S/T.
9. 小不点的成长从 after 移到 individual 专用 grow_on_scored_card, 同手 main 使用成长结果, 每次 retrigger 成长, 复制不重复成长. 计分层调用本体成长接口. 证据: [individual](<../../.tmp/engine-audit/modded-tree/card.lua#L3472-L3484>) 与 [main](<../../.tmp/engine-audit/modded-tree/card.lua#L4234-L4239>). S/T/L.
10. 钢铁小丑不是 held 每钢铁牌 x1.2, 而是 main 对整副存活钢铁牌做 1 + 0.2*N. ctx.deck_steels 由流程/计分提供. 证据: [main](<../../.tmp/engine-audit/modded-tree/card.lua#L4290-L4296>) 与 [更新计数](<../../.tmp/engine-audit/modded-tree/card.lua#L4554-L4559>). S/T/L.
11. 模仿不再只返回额外钢铁倍率, 提供 held_repetitions(card, ctx) 供完整重触发手牌全部效果, 同一接口用于回合末金牌与蓝封. 证据: [回合末 repetition](<../../.tmp/engine-audit/modded-tree/card.lua#L3288-L3296>) 与 [计分 repetition](<../../.tmp/engine-audit/modded-tree/card.lua#L3783-L3790>). S/T, 跨阶段调度由计分/流程验收.
12. 醋栗缺少销毁概率, 已和大麦克共用回合末路径但使用独立 RNG key. 证据: [end_round](<../../.tmp/engine-audit/modded-tree/card.lua#L3419-L3430>). S/T/L.
13. Egg, Invisible, Turtle Bean, Hit the Road 的回合末效果增加 self.debuff guard. individual, held, other_joker 和 on_discard 也一致保护. Baseball 不排除 other.debuff, 实际分支只看自身有效和对方稀有度. S/T.
14. 积分卡计数在 before 的 debuff guard 前推进. 方尖碑只和 visible 牌型比较. 神秘之峰和杂技演员按实际等号判定而非 <=0. S/T.
15. 通灵判断包含配置指定牌型, 不仅判断最终 scoring_name, 和 next(poker_hands[key]) 一致. JokerEffect.is_empty 也把生成消耗牌算有效效果. 证据: [通灵](<../../.tmp/engine-audit/modded-tree/card.lua#L4173-L4192>). S/T.
16. Joker.perishable 在 tally=0 时仍保留易腐身份, 避免绯红之心清除 debuff 时复活已过期小丑. Joker.couponed 保存来源标签, 但本体 sell_price 不因免费标签变为 0/1. 证据: [实际定价顺序](<../../.tmp/engine-audit/modded-tree/card.lua#L497-L528>) 先算正常价和卖价, 最后只在商店区把购买显示价清 0.
17. Hanging Chad 和 Photograph 从 PlayingCard 值相等改为 std::ptr::eq, 和 Raised Fist 一起按当前阶段 slice 的对象身份匹配, 即便同底牌克隆的所有字段值相同也只触发真正首张. S/T.
18. end_of_round_boss_effects 本体 hook: Boss 结算时 Rocket 按配置 extra.increase 增加 extra.dollars, Campfire 在 x_mult>1 时重置 1. 自身削弱时都不执行, 普通回合末不调用, 复制不重复成长, 易腐到期前调用. 证据: [Boss 回合末实际分支](<../../.tmp/engine-audit/modded-tree/card.lua#L3297-L3315>). S/T, 阶段调度由流程负责.
19. 斗牛士主效果使用 ctx.boss_triggered, 按实际盲注 triggered 发当前 extra 的现金, 不依赖流程 any 合并的固定金额. 本体 debuff guard 保持有效, 非 blocked 的逐实例和复制走正常评分队列, blocked/debuffed_hand 的发钱路径由流程逐 effective source 处理. [实际 main](<../../.tmp/engine-audit/modded-tree/card.lua#L4106-L4115>), [实际 blocked](<../../.tmp/engine-audit/modded-tree/card.lua#L3144-L3153>), [原型 extra=8](<../../game/game.lua#L504>). S/T: false 无效果, true 发 8, 配置改 9 发 9, 自身 debuff 不发. 已完成跨域接入并实际验证.

## 跨域规则与验证边界

以下规则有独立源码证据, 接入位置分别是 [流程](<../../engine/src/run/flow.rs>), [计分](<../../engine/src/scoring/engine.rs>) 和 [生成](<../../engine/src/run/shop.rs>). 本报告的局部 96 项结果不等于对所有这些领域独立执行了全套验收, 完成状态以中央全套测试和对拍报告为准.

- 大摇大摆 main 的 mult 等于其他小丑卖价总和, 不是 1+总和, 多张大摇大摆也必须按对象排除自己而非全部同 key. [实际动态更新](<../../.tmp/engine-audit/modded-tree/card.lua#L4609-L4616>).
- To Do List 命中不换任务, 回合末才换, 同手收益在 before 对 main 的 Bull 可见. [命中](<../../.tmp/engine-audit/modded-tree/card.lua#L3891-L3899>) 和 [回合末](<../../.tmp/engine-audit/modded-tree/card.lua#L3368-L3377>).
- Satellite 按不同 Planet 原型数, 不能按每次使用的总计数. [实际奖金](<../../.tmp/engine-audit/modded-tree/card.lua#L2012-L2019>).
- Hiker 每次 individual 每实例永久 +5, retrigger 重新看到已增加的永久筹码, 复制可触发. 本体没有独立分支, 由 scoring.perma_bonuses -> flow 回写. [实际分支](<../../.tmp/engine-audit/modded-tree/card.lua#L3451-L3458>).
- Space 每实例以及复制各掷一次, 不能 any/find 合并, 被 Boss 拦下不执行 before. [实际分支](<../../.tmp/engine-audit/modded-tree/card.lua#L3817-L3822>).
- Hallucination 开包每实例/复制单独掷, 消耗槽 buffer 防止超占, 不能 any/find 合并. [实际分支](<../../.tmp/engine-audit/modded-tree/card.lua#L2698-L2715>).
- Sixth Sense 单张首手 6 无论消耗槽有没有空间都销毁, 空间只决定是否生成, 石头底牌 6 不算 6. [实际分支](<../../.tmp/engine-audit/modded-tree/card.lua#L3001-L3020>).
- Midas Mask 和 Vampire 同属 before, 应按小丑队列处理强化, 多 Vampire 后者不能再次吸走已失去强化的牌. 原先 Midas after 和共享 drained 的路径与真实顺序不符. [实际分支](<../../.tmp/engine-audit/modded-tree/card.lua#L3840-L3889>).
- 复制兼容性, 自身与目标 debuff, 各阶段复制生成, hand cards 重触发由计分层负责. 本体按当前 scoring/held slice 的引用身份做首牌与最小牌匹配, 不依赖卡牌值或 sort_id 相等.
- Ramen 销毁, 永恒破坏例外, 租赁/易腐顺序, 9 霄云外整个 playing_cards 计数, Golden/Blue Seal+Mime, Pool 解锁与 Showman, Coupon/owned normalcost 都属于流程/生成联合规则.
- 积分卡被 Boss 完全拦下的出牌也推进 G.GAME.hands_played. blocked 分支不能运行全部 before 成长, 需要单独推进相应局部计数.
- 大规模全排列以及完整 GUI Oracle 不在本体静态审计的证明范围. 不将 T 当作所有组合正确的证明, 不因缺少反例而声称实现完备.

## 150 张审计矩阵

阶段代码: M=main, B=before, I=individual, H=held, R=repetition, A=after, D=discard, E=end_round, O=other_joker, G=构造/配置, F=流程/被动/跨阶段, P=生成/池子, C=复制调度. 阶段 O 与证据 L 不同. 证据列为 [补丁 Card](<../../.tmp/engine-audit/modded-tree/card.lua>) 的主要效果行, 不列无关本地化行. 每张均完成源枚举/阶段匹配, F/P/C 项的整体验收以对应领域结果为准.

| # | key | 阶段 | 主要证据行 | 层级/状态 |
|---|---|---|---|---|
| 1 | j_joker | G/M | 4341 | S, 通用 mult |
| 2 | j_greedy_joker | I | 3610 | S/T, 花色修复 |
| 3 | j_lusty_joker | I | 3610 | S/T, 花色修复 |
| 4 | j_wrathful_joker | I | 3610 | S/T, 花色修复 |
| 5 | j_gluttenous_joker | I | 3610 | S/T, 花色修复 |
| 6 | j_jolly | G/M | 4047 | S, Pair 包含 |
| 7 | j_zany | G/M | 4047 | S, Three 包含 |
| 8 | j_mad | G/M | 4047 | S, Two Pair 包含 |
| 9 | j_crazy | G/M | 4047 | S, Straight 包含 |
| 10 | j_droll | G/M | 4047 | S, Flush 包含 |
| 11 | j_sly | G/M | 4053 | S, Pair 包含 |
| 12 | j_wily | G/M | 4053 | S, Three 包含 |
| 13 | j_clever | G/M | 4053 | S, Two Pair 包含 |
| 14 | j_devious | G/M | 4053 | S, Straight 包含 |
| 15 | j_crafty | G/M | 4053 | S, Flush 包含 |
| 16 | j_half | M | 4059 | S, full_hand_len |
| 17 | j_stencil | M/F | 4327,4572 | S, 空位+自身计数 |
| 18 | j_four_fingers | F | 964 | S, 牌型规则 |
| 19 | j_mime | H/R/E | 3288,3783 | S/T, 完整重触发接口 |
| 20 | j_credit_card | F | 780,845 | S, on_gain/loss |
| 21 | j_ceremonial | F/M | 2949,4123 | S, 右邻销毁 |
| 22 | j_banner | M | 4094 | S, 剩余弃牌 |
| 23 | j_mystic_summit | M | 4081 | S, 配置相等条件修复 |
| 24 | j_marble | F | 2980 | S/T, setting_blind 生成后 nr 洗牌 |
| 25 | j_loyalty_card | B/M | 448,4019 | S/T, debuff 计数修复 |
| 26 | j_8_ball | I/P | 3498 | S/T, rank/空间/概率 |
| 27 | j_misprint | M | 4087 | S, 整数随机 |
| 28 | j_dusk | R | 3756 | S, hands_left==0 |
| 29 | j_raised_fist | H | 3712 | S/T/L, 最右最小修复 |
| 30 | j_chaos | F | 788,848 | S/T, 多本体与剩余重抽下界 |
| 31 | j_fibonacci | I | 3577 | S/T, 石头 rank 修复 |
| 32 | j_steel_joker | M/F | 4290,4554 | S/T/L, 全牌线性倍率 |
| 33 | j_scary_face | I | 3528 | S/T, 石头 face 修复 |
| 34 | j_abstract | M | 4065 | S, joker_count |
| 35 | j_delayed_grat | E | 2020 | S, used==0 且 left>0 |
| 36 | j_hack | R | 3770 | S/T, 石头 rank 修复 |
| 37 | j_pareidolia | F | 1181 | S/T, face 上下文 |
| 38 | j_gros_michel | E/M | 3419,4383 | S/T, debuff 概率 |
| 39 | j_even_steven | I | 3588 | S/T, 石头 rank 修复 |
| 40 | j_odd_todd | I | 3598 | S/T, 石头 rank 修复 |
| 41 | j_scholar | I | 3551 | S/T, 石头 rank 修复 |
| 42 | j_business | I | 3567 | S, face then probability |
| 43 | j_supernova | M | 4117 | S, played 包含本手 |
| 44 | j_ride_the_bus | B/M | 3924,4353 | S/T, 仅计分面牌 |
| 45 | j_space | F/B | 3817 | S, 多实例/复制跨域规则 |
| 46 | j_egg | E | 3378 | S/T, debuff 早退出 |
| 47 | j_burglar | F | 2907 | S, setting_blind/复制 |
| 48 | j_blackboard | M/H | 4312 | S/T, 效果花色 |
| 49 | j_runner | B/M | 3832,4269 | S, Straight 包含 |
| 50 | j_ice_cream | A/M | 3985,4276 | S, 先计分后耗尽 |
| 51 | j_dna | F/B | 3900 | S, 首手单牌复制 |
| 52 | j_splash | F | 1006 | S, scoring 名单规则 |
| 53 | j_blue_joker | M | 4248 | S, 摸牌堆张数 |
| 54 | j_sixth_sense | F | 3001 | S, 销毁不受生成空间限制 |
| 55 | j_constellation | F/M | 3132 | S, 每次 Planet 成长 |
| 56 | j_hiker | I/F | 3451 | S, 多实例/retrigger 跨域规则 |
| 57 | j_faceless | D | 3266 | S/T, 石头 face 修复 |
| 58 | j_green_joker | B/D/M | 3248,3975,4371 | S/T, 下界/配置修复 |
| 59 | j_superposition | M/P | 4148 | S, 配置 Ace 包含 |
| 60 | j_todo_list | F/B/E | 3368,3891 | S, 换任务时机跨域规则 |
| 61 | j_cavendish | E/M | 3419,4389 | S/T/L, 缺失销毁骰 |
| 62 | j_card_sharp | M | 4401 | S, played_this_round |
| 63 | j_red_card | F/M | 2820,4395 | S, skipping_booster |
| 64 | j_madness | F/M | 2883 | S, 非 Boss/永恒 |
| 65 | j_square | B/M | 3824,4262 | S, full_hand_len==4 |
| 66 | j_seance | M/P | 4173 | S/T, 包含牌型修复 |
| 67 | j_riff_raff | F/P | 2915 | S, 普通池生成/空间 |
| 68 | j_vampire | F/B/M | 3862 | S, 队列顺序跨域规则 |
| 69 | j_shortcut | F | 1058 | S, 牌型规则 |
| 70 | j_hologram | F/M | 2833 | S, 添加牌数量 |
| 71 | j_vagabond | F/P | 4129 | S, before 现金/复制 |
| 72 | j_baron | H | 3679 | S/T, 石头 rank 修复 |
| 73 | j_cloud_9 | E/F | 2006,4560 | S, 全牌计数跨域规则 |
| 74 | j_rocket | E/F | 2009,3307 | S/T, Boss 奖金成长修复 |
| 75 | j_obelisk | B/M | 3948 | S, visible 过滤修复 |
| 76 | j_midas_mask | F/B | 3840 | S, Vampire 顺序跨域规则 |
| 77 | j_luchador | F | 2723 | S, selling_self/停 Boss |
| 78 | j_photograph | I | 3485 | S/T, 首个计分面牌身份 |
| 79 | j_gift | E/F | 3391 | S, jokers+consumables |
| 80 | j_turtle_bean | E/F/G | 3316 | S/T, debuff 早退出 |
| 81 | j_erosion | M | 4255 | S, 全牌比初始差量 |
| 82 | j_reserved_parking | H | 3694 | S, face/概率/复制 |
| 83 | j_mail | F/D | 3225 | S, rank/削弱/复制 |
| 84 | j_to_the_moon | F | 800,860 | S, 利息状态 |
| 85 | j_hallucination | P | 2699 | S, 多实例/复制跨域规则 |
| 86 | j_fortune_teller | F/M | 3126,4377 | S, 已用 Tarot 总数 |
| 87 | j_juggler | F | 773,838 | S/T, hand_size/稳定态补牌 |
| 88 | j_drunkard | F | 776,841 | S/T, 弃牌剩余数下界 |
| 89 | j_stone | M | 4283,4566 | S, 全牌 stones 计数 |
| 90 | j_golden | E | 2003 | S, 固定 bonus |
| 91 | j_lucky_cat | I/M | 3460 | S, lucky_trigger 成长 |
| 92 | j_baseball | O | 3793 | S, 自身 debuff 修复 |
| 93 | j_bull | M | 4297 | S, cash+buffer 跨域规则 |
| 94 | j_diet_cola | F | 2730 | S, selling_self 标签 |
| 95 | j_trading | F/D | 3203 | S, first_discard 单牌 |
| 96 | j_flash | F/M | 2778,4359 | S, reroll_shop |
| 97 | j_popcorn | E/M | 3349,4365 | S/T, debuff 概率 |
| 98 | j_trousers | B/M | 3808,4347 | S, TwoPair 包含 |
| 99 | j_ancient | I | 3647 | S/T, wild/smeared |
| 100 | j_ramen | D/M | 3163 | S, 每张弃牌耗尽 |
| 101 | j_walkie_talkie | I | 3559 | S/T, 石头 rank 修复 |
| 102 | j_selzer | A/R | 3763,4003 | S, 剩余手数 |
| 103 | j_castle | D/M | 3215,4241 | S/T, 每张弃牌成长 |
| 104 | j_smiley | I | 3535 | S/T, face/削弱 |
| 105 | j_campfire | E/F/M | 2767,3298 | S/T, Boss 重置 debuff 修复 |
| 106 | j_ticket | I | 3542 | S, 每次 gold 触发 |
| 107 | j_mr_bones | F/E | 3432 | S, 目标 25% |
| 108 | j_acrobat | M | 4075 | S, 精确 hands_left==0 |
| 109 | j_sock_and_buskin | R | 3740 | S, face/retrigger |
| 110 | j_swashbuckler | F/M | 4335,4609 | S, 动态总卖价跨域规则 |
| 111 | j_troubadour | F | 810,870 | S, hand_size/hands |
| 112 | j_certificate | F/P | 2845 | S, first_hand_drawn |
| 113 | j_smeared | F | 4429 | S/T, 效果花色 |
| 114 | j_throwback | F/M | 2806,4545 | S, skips 总数 |
| 115 | j_hanging_chad | R | 3748 | S/T, 首牌身份 |
| 116 | j_rough_gem | I | 3616 | S/T, wild/smeared |
| 117 | j_bloodstone | I | 3639 | S, wild/smeared 修复 |
| 118 | j_arrowhead | I | 3632 | S/T, wild/smeared |
| 119 | j_onyx_agate | I | 3625 | S/T, wild/smeared |
| 120 | j_glass | F/M | 3045,3089,3112 | S, 真碎裂 vs 销毁 |
| 121 | j_ring_master | P | 1039 | S, 池子已持有排除 |
| 122 | j_flower_pot | M | 4193 | S/T/L, wild 填花色 |
| 123 | j_blueprint | C | 2679 | S, 各阶段复制跨域规则 |
| 124 | j_wee | I/M | 3472,4234 | S/T/L, 同手成长 |
| 125 | j_merry_andy | F | 773,776,838,841 | S/T, hand_size/discards 下界 |
| 126 | j_oops | F | 2717 | S, mod_probability 非复制 |
| 127 | j_idol | I | 3519 | S/T, wild 花色/rank |
| 128 | j_seeing_double | M | 4226 | S/T, SMODS helper |
| 129 | j_matador | M/F | 3144,4106 | S/T, 当前配置金额与 triggered/debuff 守卫 |
| 130 | j_hit_the_road | D/E/M | 3235,3409 | S/T, stone/debuff |
| 131 | j_duo | G/M | 4040 | S, Pair 包含 xmult |
| 132 | j_trio | G/M | 4040 | S, Three 包含 xmult |
| 133 | j_family | G/M | 4040 | S, Four 包含 xmult |
| 134 | j_order | G/M | 4040 | S, Straight 包含 xmult |
| 135 | j_tribe | G/M | 4040 | S, Flush 包含 xmult |
| 136 | j_stuntman | M/F | 4100,814,874 | S/T, 手限代价与稳定态补牌 |
| 137 | j_invisible | E/F | 2741,3338 | S/T, debuff 回合停止 |
| 138 | j_brainstorm | C | 2690 | S, 各阶段复制跨域规则 |
| 139 | j_satellite | E | 2012 | S, 不同 Planet 跨域规则 |
| 140 | j_shoot_the_moon | H | 3664 | S/T, stone/Mime |
| 141 | j_drivers_license | M | 4304,4548 | S, 全牌 16 强化 |
| 142 | j_cartomancer | F/P | 2932 | S, setting_blind 空间 |
| 143 | j_astronomer | F/P | 803,863 | S/T, 状态变更后 Planet/Celestial 价 |
| 144 | j_burnt | F/D | 3156 | S, pre_discard 非 Hook |
| 145 | j_bootstraps | M | 4407 | S, cash/整数倍 |
| 146 | j_caino | G/F/M | 3021,3071,4413 | S, 真 face 移除成长 |
| 147 | j_triboulet | I | 3654 | S/T, 石头 rank 修复 |
| 148 | j_yorick | D/M | 3184 | S, 每 23 张成长 |
| 149 | j_chicot | F | 2871 | S, Boss 禁用非复制 |
| 150 | j_perkeo | F/P | 2789 | S, ending_shop 负片复制 |

## 动态被动的独立复审

动态规则按实际 add_to_deck/remove_from_deck 和当前补丁对照, 精确过渡如下:

| 被动或过渡 | 实际规则 | 证据 |
|---|---|---|
| debuff 边缘 | 相同状态不重复撤销/添加, 易腐到期持续削弱, 从有效转削弱调用 remove_from_deck(true), 恢复则 add_to_deck(true) | [set_debuff](<../../.tmp/engine-audit/modded-tree/card.lua#L690-L728>) |
| Negative | debuff 不撤版本的槽位, 实际属性求和不筛选 debuff | [版本属性](<../../mods/Steamodded/src/overrides.lua#L2216-L2217>), [容量求和](<../../mods/Steamodded/src/utils.lua#L3905-L3927>) |
| Juggler | 有效时手牌上限 +1, debuff 撤 -1, 恢复 +1 | [add](<../../.tmp/engine-audit/modded-tree/card.lua#L773-L775>), [remove](<../../.tmp/engine-audit/modded-tree/card.lua#L838-L840>) |
| Drunkard/Merry Andy | 默认弃牌完整 +/-1 或 +/-3, 当前剩余弃牌的减少下限 0, 恢复完整添加; Merry Andy 的手牌 -1 也成对撤回 | [add/remove](<../../.tmp/engine-audit/modded-tree/card.lua#L773-L779>), [ease_discard 下界](<../../.tmp/engine-audit/modded-tree/functions/common_events.lua#L111-L124>) |
| Stuntman | 有效本体手牌 -2, debuff 撤销为 +2; Blueprint 复制评分不复制该进场代价 | [add/remove](<../../.tmp/engine-audit/modded-tree/card.lua#L814-L815>), [撤销](<../../.tmp/engine-audit/modded-tree/card.lua#L874-L875>) |
| Turtle Bean | 使用当前 h_size 而非原型初值 5, 削弱期间不进行回合末衰减, 恢复当前值 | [add/remove](<../../.tmp/engine-audit/modded-tree/card.lua#L792-L794>), [撤销](<../../.tmp/engine-audit/modded-tree/card.lua#L852-L854>) |
| Credit Card | 有效时破产线 -20, 撤销 +20, 并不强制清除既有负现金 | [add/remove](<../../.tmp/engine-audit/modded-tree/card.lua#L780-L782>), [撤销](<../../.tmp/engine-audit/modded-tree/card.lua#L845-L847>) |
| Astronomer | 进场, 离场, debuff, 恢复都重算卡牌价签, 多张时另一有效本体仍保持免费; 回调提交成员/debuff 新状态后再重算 | [add/remove](<../../.tmp/engine-audit/modded-tree/card.lua#L803-L808>), [撤销](<../../.tmp/engine-audit/modded-tree/card.lua#L863-L868>) |
| Oops | 每张有效本体独立概率 *2, 撤销 /2; SMODS 概率 helper 抵消兼容路径的重复倍率, 不应将蓝图复制算成另一被动本体 | [add/remove](<../../.tmp/engine-audit/modded-tree/card.lua#L795-L798>), [撤销](<../../.tmp/engine-audit/modded-tree/card.lua#L855-L858>), [概率兼容](<../../mods/Steamodded/src/utils.lua#L3215-L3221>) |
| Chaos | 本局默认免费重抽数每本体 +/-1, 当前免费重抽数 max(current+delta,0), 下一回合恢复默认; 不是 any 聚合一次 | [被动入口](<../../.tmp/engine-audit/modded-tree/card.lua#L788-L790>), [当前和默认修改](<../../mods/Steamodded/src/utils.lua#L2741-L2744>), [回合初始化](<../../.tmp/engine-audit/modded-tree/functions/state_events.lua#L259>) |
| Smeared/Pareidolia | find_joker 默认排除削弱牌, 增删/削弱/恢复后重算所有存活扑克牌的 Boss debuff, 评分牌型也读取最新有效本体, 不沿用复制目标赋予被动 | [find_joker](<../../.tmp/engine-audit/modded-tree/functions/misc_functions.lua#L1005-L1018>), [花色](<../../.tmp/engine-audit/modded-tree/card.lua#L4425-L4448>) |
| 手牌上限增大 | drawn_to_hand 前已经进入 SELECTING_HAND, Heart 全部状态过渡后容量 handler 根据最终新上限补牌; 容量降低不主动丢弃已有手牌, 不在恢复旧目标的中间瞬态逐次 fill | [状态顺序](<../../.tmp/engine-audit/modded-tree/game.lua#L3416-L3421>), [容量更新](<../../mods/Steamodded/src/utils.lua#L3919-L3954>), [Heart 整体过渡](<../../.tmp/engine-audit/modded-tree/blind.lua#L635-L664>) |

确认并修复了 4 组动态被动差异:

1. Chaos 多本体初始化, 以及已经使用免费重抽后撤销被动时当前次数的下界.
2. Astronomer 成员/debuff 状态提交后及时刷新价签, 保留其他有效 Astronomer 的免费作用.
3. Drunkard/Merry Andy 剩余弃牌不得变成负值, 默认回合弃牌仍按完整 delta 撤销和恢复.
4. 手牌上限增加后在稳定态补到最终目标, 不因中间恢复状态多抽牌, 也不在上限下降时丢牌.

Negative 槽位计数, debuff 边缘幂等守卫, 当前 Turtle Bean 撤销量和 Smeared/Pareidolia 重新计算已有实现与规则一致. Chicot 初次传入已削弱对象的生命周期顺序证据不足, 不作为确认缺陷或修复项.

[audit-passives 测试](<../../engine/tests/audit-passives.rs>) 的 8 个案例通过公开进出场和 Boss 回调切换状态, 不直接修改 joker.debuffed 后要求自动回调. 覆盖多 Chaos 不复制被动, 用尽后离场/恢复, Heart 重复过渡, Astronomer 多成员和 debuff 后刷新价格, Drunkard/Merry Andy 弃牌下界与完整默认值, Negative 容量, 以及最终稳定手牌上限补牌. 本组实际结果 8/8.

## 回归与执行记录

[audit-jokers 专项测试](<../../engine/tests/audit-jokers.rs>) 覆盖石头 rank/face, wild/smeared, 花盆, 黑板/眼观双路, 同点致胜之拳, 城堡逐张成长, 绿小丑下界与 debuff, 巴士未计分 face, 小不点本手/retrigger, 钢铁全牌线性倍率, Mime 完整手牌效果, debuff 回合末, 醋栗销毁, 积分卡恢复周期, 通灵包含判定, Rocket/Campfire 的 Boss 时机及 Matador 当前配置与 triggered 标志.

[原小丑测试](<../../engine/tests/jokers.rs>) 有 5 个经实际源码确认的错误基准:

- 钢铁必须显式提供全牌 deck_steels=1.
- 小不点计分使用本手已有成长, 不是下一手才享有.
- 花盆的百搭牌补缺失梅花, 仍有 x3.
- 吸血鬼剥除 Mult 强化后, 本手倍率是基础 1 * 1.1, 而非保留 +4 后的 5.5. 原先只主张比无吸血鬼的 5 更高, 掩盖了 stale views 缺陷. 正确精确断言为 plain=5, drained=1.1.
- 大理石在 setting_blind 创建后参与 nr 洗牌, 不可要求洗牌后仍在牌堆下标 0. 时序测试先保存 start_run 的原始牌堆和 RNG clone, 添加实际新石头牌重建洗牌前基线, 按 sort_id 排序并独立 nr1 洗牌, 尾抽 8 张, 比较剩余牌堆完整序列和手牌多重集. 新石头具体 front 由独立生成回归验证, 这里不以实际整副牌的顺序生成 expected, 也不硬编码观测到的下标. [实际先生成后洗牌](<../../.tmp/engine-audit/modded-tree/functions/state_events.lua#L280-L291>).

验证记录:

| 阶段 | 本体专项 | 动态被动 | 原小丑测试 | 退出码 |
|---|---|---|---|---|
| 本体主要差异修复 | 15/15 | 未纳入 | 72/72 | 0 |
| 动态被动接入, 旧 Marble 基准未校正 | 15/15 | 8/8 | 71/72 | 101 |
| Marble 时序基准校正 | 15/15 | 8/8 | 72/72 | 0 |
| Matador 跨域字段接入 | 16/16 | 8/8 | 72/72 | 0 |

最后一行合计 96/96, 实际执行的命令为 `cargo test --manifest-path engine/Cargo.toml --test audit-passives --test audit-jokers --test jokers`. 该组合验证限于上述测试目标, originVec 模型迁移之后的中央全套验收另行报告. 没有以修改被审计源配置追求通过, 没有删除失败案例, 也没有全文件格式化.

独立身份转移回归 [audit-identity](<../../engine/tests/audit-identity.rs>) 在出生字段接入后执行 `cargo test --manifest-path engine/Cargo.toml --test audit-identity`, 1/1, exit 0. 货架由真实 Shop::restock 生成 3 张小丑, 逆序购买第 2 格再第 0 格仍保留原对象的非零出生 ID, 剩余货架对象的 ID 不变. 下一个琥珀橡果按真实出生顺序恢复基线, 三次 aajk 洗牌与独立 RNG 的完整 ID 队列相等. 没有伪造初始 UID 或依赖全局绝对号, 该测试保护对象移动不被误当作新建, 不把复制的新身份规则或完整录像尾段当作已经独立验证.

L 层级验证使用独立 LuaJIT 执行从补丁树提取的实际 calculate_joker 函数, exit 0, 共 5 项: Wee 同手成长, Flower Pot 三花色+wild, Raised Fist 最右最低/debuff 不改选, Cavendish end_of_round 命中销毁, Steel Joker 3 张钢铁的线性 x1.6. 最小宿主仅模拟 G 区域对象, UI/事件, card predicate 和 SMODS.scale_card/概率入口, 没有将 Joker 效果分支重新实现一份作裁判. 概率入口强制命中以测试销毁分支, 不能将该验证当作概率分布证明.

中间失败也保留在证据边界内. 并行接口尚未落齐时, ScoreResult.perma_bonuses, PackCard.cost 和 apply_round_start_jokers 签名交错曾导致编译退出 101. LuaJIT 宿主先缺 config.center, 后缺 SMODS.has_any_suit, 两次均停止报错. 其中一次与 Cargo 合并执行, Cargo 成功使最终命令退出 0, 但 stderr 的 Lua 失败单独识别, 不能算作 5 项通过. 最后独立 Lua 命令才达到 5/5. 这些编译和宿主错误不作为游戏规则反例, 修正后的实际执行结果与未验证范围分别列示.
