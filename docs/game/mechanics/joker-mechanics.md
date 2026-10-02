# 小丑牌触发机制

适用版本: Balatro 1.0.1o. 本文补充卡面说明没有明确描述的触发顺序, 当前动态数值, 成长/重置/自毁与交互边界. 以仓库源码为准, 不把 wiki 当前版本的规则直接套到旧版本.

静态说明, 名称, 价格, 稀有度与兼容标记见 [小丑卡牌目录](<../cards/jokers.md>) 和 [结构化目录](<../data/catalog.json>). 本文的主键是原始 `j_*` id, 保留源码拼写, 包括 `j_gluttenous_joker`, `j_selzer`, `j_ring_master`. 覆盖表按原型 `order` 列出全部 150 个 id.

## 1. context 与执行顺序

### 1.1 公共约定

- `full_hand`: 本次打出/弃掉的整批牌. `scoring_hand`: 牌型判定后真正参与计分的牌, 加上石头牌, 或在 Splash 生效时扩展为全部打出的牌. 两者不能混用.
- `scoring_name`: 最高优先级的最终牌型. `poker_hands`: 所有被判定存在的子牌型. "包含对子" 用后者, "恰好打出指定牌型" 用前者.
- `other_card`: 当前计分/留手/弃掉的单张扑克牌. `other_joker`: 刚处理完主效果的那张小丑牌.
- `cardarea` 说的是当前被计分的区域, 不一定是该小丑本身的位置. 例如小丑的 `individual` + `G.play` 是响应一张打出牌.
- 小丑每次进入 `calculate_joker` 首先检查自身 `debuff`; 失效小丑不输出也不成长. 留手牌是否失效另由相应分支判断.
- `before`/`individual` 中的增长发生在 `joker_main` 之前, 因而通常立即用于本次计分. `after` 的衰减发生在本次分数已计算之后.
- 生成消耗牌时通常检查 `#G.consumeables.cards + consumeable_buffer < card_limit`. 生成小丑检查相应 `joker_buffer`. 缓冲区是对排队生成的容量预约, 不能只数画面上已经出现的牌.
- `getting_sliced` 表示已被排队销毁. 多个回合开始效果会排除它, 防止同一张牌被多次吞噬或在移除前继续生成牌.

来源: [Card:calculate_joker](<../../../game/card.lua#L2291-L2304>), [eval_card](<../../../game/functions/common_events.lua#L580-L655>), [G.FUNCS.evaluate_play](<../../../game/functions/state_events.lua#L570-L684>).

### 1.2 生命周期/操作 context

| context/入口 | 发生时机 | 对 agent 的约束 |
| --- | --- | --- |
| `add_to_deck` / `remove_from_deck` | 获得/移除牌, 或小丑失效/恢复时撤销/重建持续效果 | 手牌上限, 透支线, 概率乘数等不是计分事件; 蓝图不执行这些入口 |
| `setting_blind` | 盲注已设置, 新回合次数已重置, 首次抽牌之前 | Dagger, Madness, Burglar 等从左到右处理; 跳过盲注不触发 |
| `first_hand_drawn` | 面对盲注, 本回合出牌/弃牌计数均为 0 的首次抽牌后 | Certificate 在此生成牌; DNA/Trading 的分支这里只控制提示动画 |
| `pre_discard` | 弃牌列表按横向位置排序后, 逐张弃牌之前 | Burnt 升级整批弃牌的最高牌型; 能识别 The Hook 的 `hook` |
| `discard` | 每张弃牌先处理蜡封, 再从左到右通知小丑 | Green/Faceless 用批次最后一张避免每张重复处理整批效果; 多个小丑仍会收到被 Trading 销毁的牌 |
| `end_of_round` | 判断分数是否达标之后, 手牌回合末效果之前 | 包含输掉的回合; Mr. Bones 可改写 `game_over`; 每个小丑随后结算租赁和易腐 |
| `end_of_round` + `individual` | 每张留手牌回合末效果 | 本版本小丑该分支为空; 不等同于计分时的留手 Q/K 效果 |
| `end_of_round` + `repetition` | 留手牌回合末重触发请求 | Mime 可重触发金色增强/蓝蜡封等回合末效果 |
| `calculate_dollar_bonus` | 达标或被救活后, 结算面板计算收入 | 独立于 `calculate_joker`; 不能用蓝图复制 Golden Joker/Rocket 等收入 |
| `open_booster` | 打开补充包 | Hallucination 掷一次概率; 免费标签包也走打开流程 |
| `skipping_booster` | 点击已打开包中的 Skip | Red Card 增长; 自动拿完最后一个选择不算 Skip |
| `reroll_shop` | 刷新商店 | Flash 增长; 免费刷新也算 |
| `ending_shop` | 离开商店 | Perkeo 复制当前消耗牌, 不是买牌时复制 |
| `buying_card` | 商店购买牌 | 本版本小丑分支为空, 不提供额外奖励 |
| `selling_self` | 出售该牌, 尚未溶解移除 | Luchador/Diet Cola/Invisible; 与销毁不同 |
| `selling_card` | 售卖后通知其余小丑 | Campfire; 包括出售消耗牌, 不包括直接销毁 |
| `using_consumeable` | 消耗牌调用 `use_consumeable` 后通知小丑 | Constellation/Glass 特判; 黑洞属于 Spectral, 不是 Planet |
| `playing_card_added` | 创建/加入扑克牌后显式通知 | Hologram 按 `#context.cards` 增长; 花色/点数/增强转换不算加入 |
| `remove_playing_cards` | 弃牌销毁, 计分后销毁或消耗牌销毁的通知 | Caino/Glass 用 `context.removed`; 不要与未被调用的旧分支合并 |
| `cards_destroyed` | 定义存在, 但本仓库未发现调用方 | 接收 `glass_shattered`; 不应额外模拟一次, 否则重复成长 |
| `skip_blind` | 全局 `skips` 已增加后 | Throwback 提示; 实际数值在 `update` 中重算 |

来源: [new_round 与弃牌调用方](<../../../game/functions/state_events.lua#L290-L438>), [首次抽牌](<../../../game/game.lua#L3194-L3220>), [end_round](<../../../game/functions/state_events.lua#L87-L233>), [收入结算](<../../../game/functions/state_events.lua#L1175-L1182>), [生成通知](<../../../game/functions/misc_functions.lua#L1580-L1583>), [use_card](<../../../game/functions/button_callbacks.lua#L2196-L2215>), [sell_card](<../../../game/functions/button_callbacks.lua#L2303-L2310>), [skip_booster](<../../../game/functions/button_callbacks.lua#L2543-L2547>), [商店/跳盲注/刷新回调](<../../../game/functions/button_callbacks.lua#L2471>), [Card:open](<../../../game/card.lua#L1797>).

### 1.3 每次出牌的精确阶段

1. 消耗 1 次出牌次数. `current_round.hands_left` 已减少, 但 `current_round.hands_played` 仍是此前出牌数.
2. 判定最终牌型和计分牌. `G.GAME.hands[scoring_name].played` 和 `played_this_round` **先加 1**, 无论这手后来是否被 Boss 拒绝. `last_hand_played` 也先更新.
3. 扩展石头牌/Splash, 按横向位置排序计分牌. Boss `debuff_hand` 若拒绝整手, 跳过步骤 4-9 的正常计分, 只通知 `debuffed_hand`; 之后仍执行 `after`.
4. 按小丑从左到右通知 `before`, 完成 Square/Runner/Green/Vampire 等本手成长或牌面转换. Space 产生的牌型升级立即生效. 再从升级后的牌型读基础筹码/倍率, 调用 Boss `modify_hand`.
5. 按计分牌从左到右处理. 失效计分牌不给自身效果, 不收集重触发, 不通知逐牌 `individual`, 但会令 `blind.triggered = true`. 正常牌先收集红蜡封和各小丑 `repetition` 的额外次数, 然后执行 `1 + sum(repetitions)` 轮. 每轮先取牌自身筹码/增强/金钱/版本, 再从左到右通知所有小丑 `individual` + `G.play`, 再应用本轮效果. 每轮结束清除 `lucky_trigger`.
6. 按留手牌顺序处理 `individual` + `G.hand`. 首轮收集红蜡封/Mime 的额外次数, 重触发只重复这张留手牌的效果. 不能把整排小丑主效果也乘上次数.
7. 对每张小丑依次执行: 闪箔/镭射版本加成 -> `joker_main` -> 所有小丑的 `other_joker` 响应 -> 多彩版本 XMult. 消耗牌也进入这段循环, 以支持天文台优惠券; 普通小丑主要使用 `cardarea == G.jokers` 下非 `before/after` 的分支.
8. 牌组 `final_scoring_step`, 如等离子平衡, 在所有小丑之后执行.
9. 每张计分牌尝试 `destroying_card`, 第一个返回真者结束该牌的小丑销毁检查; 随后另做一次玻璃自碎检查. 对销毁列表统一通知 `remove_playing_cards`. 不会因重触发次数多而做多次玻璃自碎掷骰.
10. 分数为 `floor(hand_chips * mult)`, 累加到本盲注分数. 按小丑从左到右通知 `after`, Ice Cream/Seltzer 在此衰减. 之后才增加全局 `hands_played` 与回合内 `hands_played`.

来源: [出牌次数与事后计数](<../../../game/functions/state_events.lua#L470-L525>), [evaluate_play 前半段](<../../../game/functions/state_events.lua#L570-L700>), [留手与主效果](<../../../game/functions/state_events.lua#L782-L949>), [销毁/失效/after](<../../../game/functions/state_events.lua#L950-L1085>).

## 2. 蓝图与头脑风暴

蓝图 Blueprint (`j_blueprint`) 找其右侧紧邻小丑. 头脑风暴 Brainstorm (`j_brainstorm`) 找整排最左小丑, 不会跳过不兼容目标或失效目标. 头脑风暴自己在最左时没有目标.

### 2.1 复制的是一次 context 调用, 不是完整卡牌

- 复制器把同一 `context` 递归传入目标的 `calculate_joker`. 增加 `context.blueprint` 的深度计数, 保存最外层 `blueprint_card`; 返回效果的显示归属改成最外层复制器.
- 若深度 `> #G.jokers.cards + 1`, 返回空, 防止蓝图与头脑风暴链循环. 能形成链不意味着必定输出: 链必须最终落到实际效果小丑.
- 目标/复制器任一失效都会停止该路径. 目标的版本, 永恒/易腐/租赁贴纸, 售价, 手牌上限等不被当作复制器自己的属性.
- 目标仍在它自己的位置执行原效果. 复制效果在复制器的位置执行, 因此复制 +Mult 或 XMult 的排布仍影响最终分数.
- `blueprint_compat` 在 `update` 中驱动兼容提示. 递归代码本身没有先用该标记阻挡调用, 实际无效通常由目标缺少对应 context 或 `not context.blueprint` 守卫实现. 模拟器应依据分支, 不能仅看 UI 字段.
- **成长通常不被复制, 已成长的输出可被复制**. 例如 Square 的 `before` 被守卫挡住, `joker_main` 仍输出当前 chips. 同样适用于 Wee, Vampire, Hologram, Yorick, Lucky Cat 等.
- **不是所有状态变化都被挡住**. Hiker 加永久筹码, Space/Burnt 升级牌型, DNA 创建牌, Certificate/Marble 创建牌, Burglar 加出牌次数, Riff-raff/Cartomancer/Perkeo 生成牌均没有相应的成长守卫, 可以多次执行.
- Selling Self 可被复制: 出售指向 Diet Cola 的蓝图可以获得双倍标签; 指向 Luchador 可禁用当前 Boss. 出售 Diet Cola 本体不会因旁边存在蓝图而广播本体的 Selling Self.
- 卖其他牌时通知每个剩余小丑, 但 Campfire 守卫只让本体增长. 切牌/自毁不是出售, 不触发 Campfire.

来源: [复制器递归](<../../../game/card.lua#L2304-L2334>), [兼容提示](<../../../game/card.lua#L4225-L4239>), [Selling Self](<../../../game/card.lua#L2354-L2402>), [Card:sell_card](<../../../game/card.lua#L1590-L1610>).

### 2.2 静态不兼容集合

本版本原型标记 `blueprint_compat = false` 的 29 个 id:

```text
j_four_fingers, j_credit_card, j_chaos, j_delayed_grat, j_pareidolia,
j_egg, j_splash, j_sixth_sense, j_shortcut, j_cloud_9, j_rocket, j_midas_mask,
j_gift, j_turtle_bean, j_to_the_moon, j_juggler, j_drunkard, j_golden,
j_trading, j_mr_bones, j_troubadour, j_smeared, j_ring_master,
j_merry_andy, j_oops, j_invisible, j_satellite, j_astronomer, j_chicot
```

这些卡大多在持续属性入口, 牌型判定函数或独立收入入口生效. 例如复制 `j_oops` 不会翻倍概率, 复制 `j_troubadour` 不会扩大手牌, 复制 `j_cloud_9` 不会多收收入.

来源: [完整小丑原型](<../../../game/game.lua#L368-L526>), [add_to_deck/remove_from_deck](<../../../game/card.lua#L564-L699>), [calculate_dollar_bonus](<../../../game/card.lua#L1655-L1679>).

## 3. 全 150 张机制覆盖表

缩写: `B = before`, `M = joker_main`, `A = after`, `IP = individual + G.play`, `IH = individual + G.hand`, `RP/RH = repetition + G.play/G.hand`, `E = end_of_round` 的非 individual/repetition 分支, `D = discard`, `PD = pre_discard`, `S = setting_blind`, `F = first_hand_drawn`, `U = update` 实时重算, `P = 持有时的外部被动规则`, `入/出 = add_to_deck/remove_from_deck`, `收入 = calculate_dollar_bonus`.

所有未写成长/重置的条目, 没有独立累积成长状态. `normal` 指 `G.GAME.probabilities.normal`, 初始为 1, 每张有效 Oops! All 6s 使其翻倍. "有空位" 同时考虑缓冲区. 表内静态数值只为说明更新公式, 不代替卡面目录.

### 3.1 order 1-30

主要来源: [逐牌效果与重触发](<../../../game/card.lua#L3065-L3395>), [before/主效果](<../../../game/card.lua#L3411-L3742>), [持续属性](<../../../game/card.lua#L564-L699>), [U](<../../../game/card.lua#L4176-L4248>), [牌型判定](<../../../game/functions/misc_functions.lua#L428-L589>).

| # | id | 时机 | 精确规则/动态状态 |
| --- | --- | --- | --- |
| 1 | `j_joker` | M | 输出 `ability.mult = 4`, 每手一次, 不是每张牌一次 |
| 2 | `j_greedy_joker` | IP | 每次有效方块牌计分 +3 Mult; 万能/涂抹使用 `is_suit`, 重触发再加 |
| 3 | `j_lusty_joker` | IP | 每次有效红桃牌计分 +3 Mult; 与黑桃/梅花互不替代, 除非花色判定被修改 |
| 4 | `j_wrathful_joker` | IP | 每次有效黑桃牌计分 +3 Mult; 不要求最终牌型为同花 |
| 5 | `j_gluttenous_joker` | IP | 每次有效梅花牌计分 +3 Mult; 非计分的梅花不触发 |
| 6 | `j_jolly` | M | `poker_hands.Pair` 非空时 +8 Mult; 三条/四条/五条也包含对子 |
| 7 | `j_zany` | M | `Three of a Kind` 非空时 +12 Mult; 葫芦/四条/五条也满足 |
| 8 | `j_mad` | M | `Two Pair` 非空时 +10 Mult; 葫芦满足, 单独四条不是两对 |
| 9 | `j_crazy` | M | `Straight` 非空时 +12 Mult; 同花顺也满足 |
| 10 | `j_droll` | M | `Flush` 非空时 +10 Mult; 同花顺/同花葫芦/同花五条也满足 |
| 11 | `j_sly` | M | 包含对子 +50 Chips, 条件与 Jolly 相同 |
| 12 | `j_wily` | M | 包含三条 +100 Chips, 条件与 Zany 相同 |
| 13 | `j_clever` | M | 包含两对 +80 Chips, 条件与 Mad 相同 |
| 14 | `j_devious` | M | 包含顺子 +100 Chips, 条件与 Crazy 相同 |
| 15 | `j_crafty` | M | 包含同花 +80 Chips, 条件与 Droll 相同 |
| 16 | `j_half` | M | `#full_hand <= 3` 才 +20 Mult; 只计分 3 张但打出 5 张不满足 |
| 17 | `j_stencil` | U -> M | XMult = 槽位上限 - 当前小丑张数 + 所有 Joker Stencil 张数. 本体/其他 Stencil 都当空位; 负片提高槽位. 值 >1 可走通用 XMult 分支, 不要误读后面的空槽条件为必须实际空槽 |
| 18 | `j_four_fingers` | P | 顺子/同花所需不同点数/同花张数由 5 降到 4; 多张不继续降. 同花顺判定取顺子集合与同花集合的并集, 两组 4 张可不是完全同一组 |
| 19 | `j_mime` | RH, E+RH | 只有该留手牌已有自身效果或小丑效果时才加 1 次. 可放大钢牌, 留手 Q/K, 金牌回合末收入, 蓝蜡封. 不重放整排 M |
| 20 | `j_credit_card` | 入/出 | 每张使 `bankrupt_at -= 20`, 移除撤销. 是可支出的透支边界, 不是赠送 $20, 不增加 Bull/利息使用的余额 |
| 21 | `j_ceremonial` | S -> M | 只吞右侧紧邻且非永恒/非已切片小丑, 增加 `2 * sell_cost` Mult. 不跳过永恒目标去吃更右侧; 蓝图只复制累计输出, 不复制吞噬 |
| 22 | `j_banner` | M | 30 * 当前剩余弃牌次数 Chips, 不是初始弃牌数 |
| 23 | `j_mystic_summit` | M | 剩余弃牌次数恰好 0 时 +15 Mult; 与本回合是否曾弃牌无关 |
| 24 | `j_marble` | S | 每次实际选择盲注创建 1 张石头牌加入牌组, 不是每次出牌. 可复制; 通知 Hologram 一次新增 |
| 25 | `j_loyalty_card` | M | `remaining = (4 - (hands_played - hands_played_at_create)) % 6`; 当值为 5 时 X4. 第 6/12/... 次取得后全局出牌触发; 不是概率. 最终判定读取当前 M 的派生值 |
| 26 | `j_8_ball` | IP | 每张有效计分 8 每轮以 `normal/4` 生成塔罗, 先查空位再掷骰. 重触发/蓝图各自检查, 不能无视容量预约 |
| 27 | `j_misprint` | M | 每次调用独立抽取 [0,23] 整数 Mult. 蓝图也重新抽, 不固定复用本体的此次结果; 悬浮框动画不是实际抽到的值 |
| 28 | `j_dusk` | RP | 已消耗本次出牌次数后 `hands_left == 0` 时, 每张计分牌 +1 次; 不是提前达标的最后一手 |
| 29 | `j_raised_fist` | IH | 选留手非石头牌中最小 `base.id`; 并列选择循环中最后一个. 仅该牌触发 `2 * base.nominal` Mult; A 是 14/11 Chips, 人头 nominal 为 10. 若被选中的最低牌失效, 不改选第二低牌 |
| 30 | `j_chaos` | 入/出, 新回合 | 每张加入 +1 免费刷新, 移除 -1; 新回合按有效 Chaos 数重置免费次数. 不是每到一家商店无条件额外重置 |

### 3.2 order 31-60

主要来源: [IP](<../../../game/card.lua#L3065-L3269>), [D](<../../../game/card.lua#L2756-L2873>), [B/A](<../../../game/card.lua#L3411-L3630>), [主效果](<../../../game/card.lua#L3653-L4056>), [首次创建/回合末](<../../../game/card.lua#L2462-L2602>), [is_face](<../../../game/card.lua#L957-L969>), [Splash 扩展](<../../../game/functions/state_events.lua#L580-L600>).

| # | id | 时机 | 精确规则/动态状态 |
| --- | --- | --- | --- |
| 31 | `j_fibonacci` | IP | 仅 id 为 A/2/3/5/8 的有效计分牌 +8 Mult; 石头牌没有这些有效 id |
| 32 | `j_steel_joker` | U -> M | 扫整个 `G.playing_cards`, 按增强原型 `m_steel` 计数, XMult = 1 + 0.2 * 数量. 计入未抽到/失效钢牌, 不只留手牌 |
| 33 | `j_scary_face` | IP | `is_face()` 的有效计分牌 +30 Chips; Pareidolia 可扩展人头判定 |
| 34 | `j_abstract` | M | +3 * 当前小丑牌张数 Mult, 包含自己, 负片及失效的其他小丑仍在张数内 |
| 35 | `j_delayed_grat` | 收入 | `discards_used == 0` 且有剩余弃牌时收入为 `2 * discards_left`. 与 Mystic Summit 相反, 0 剩余时没有收入 |
| 36 | `j_hack` | RP | 每张有效计分 2/3/4/5 +1 次; 多个重触发来源求和, 不递归产生自身 |
| 37 | `j_pareidolia` | P | 有效持有时 `is_face()` 把所有正常有效牌视为人头, 也影响 Boss 的人头检查. 不把点数改成 J/Q/K, 因此不能让任意牌触发 Triboulet/Baron |
| 38 | `j_gros_michel` | M, E | M +15 Mult. 每个回合末以 `normal/6` 自毁, 同时设置 `gros_michel_extinct`. 普通出售/被 Madness 吞掉不会设置灭绝标记 |
| 39 | `j_even_steven` | IP | 2/4/6/8/10 +4 Mult; A 不满足偶数规则, J/Q/K 不满足 <=10 |
| 40 | `j_odd_todd` | IP | A/3/5/7/9 +31 Chips; A 是显式特判, 不是 id 的奇偶结果 |
| 41 | `j_scholar` | IP | A 每轮 +20 Chips, +4 Mult; 不因 A 在低端顺子中被视作 1 而失去效果 |
| 42 | `j_business` | IP | 有效人头牌每轮以 `normal/2` 得 $2; 不是每次出牌只掷一次 |
| 43 | `j_supernova` | M | +最终牌型全局 `played` 次数 Mult, 已包含本次, 也包含之前被 Boss 拒绝的手. 取得前次数追溯有效 |
| 44 | `j_ride_the_bus` | B -> M | 仅查 `scoring_hand` 中 `is_face()`. 有人头则 mult=0, 否则 +1; 不计分的人头不会重置. 失效人头通常 `is_face()` 返回空, 不触发重置. 不在回合末重置 |
| 45 | `j_space` | B | 每次有效正常计分手以 `normal/4` 升级最终牌型 1 级, 立即影响本手. 蓝图各掷一次, 可升多级 |
| 46 | `j_egg` | E | `extra_value += 3`, 调用 `set_cost` 更新售价; 不增加计分输出 |
| 47 | `j_burglar` | S | 当前剩余弃牌归零, 出牌次数 +3. 蓝图各加 3 次; 多次归零不会再扣出负弃牌 |
| 48 | `j_blackboard` | M | 检查全部留手牌是否按 `is_suit(..., flush_calc=true)` 为梅花/黑桃; 空留手也满足. 石头留手不满足, 失效的普通黑牌仍可满足, 有效万能牌满足 |
| 49 | `j_runner` | B -> M | 包含顺子时累计 Chips +=15, 本手即输出增长后的值. 同花顺也增长; RP 不会额外 B |
| 50 | `j_ice_cream` | M, A | 初始 100 Chips, 本手按旧值输出; 每次出牌后 -5, 若下一值 <=0 自毁. 即使整手被 Boss 拒绝, `after` 仍衰减 |
| 51 | `j_dna` | B | 本回合第一次出牌, `#full_hand == 1` 才复制整张扑克牌加入手牌/牌组. 出牌是否人头/增强无关; 整手被拒绝则无 B. 可复制, 触发 Hologram; F 只是提示 |
| 52 | `j_splash` | P | 牌型仍按原规则判定, 仅将所有打出牌加入计分牌列表. 失效牌不会因此恢复计分. 因此会改变 Ride the Bus/Vampire/Flower Pot 的检查范围 |
| 53 | `j_blue_joker` | M | 2 * 此刻抽牌堆 `#G.deck.cards` Chips, 不含手牌/弃牌堆/正在打出的牌 |
| 54 | `j_sixth_sense` | 销毁阶段 | 本回合首次出牌恰好单张 6 时, 正常计分阶段结束后销毁它. 有空位才生成幻灵, 没空位仍销毁. 不可复制, 不在每次 RP 后反复销毁 |
| 55 | `j_constellation` | 使用 Planet -> M | 每次实际使用 Planet, x_mult +=0.1, 初始 1. 单张星球一次, 并非每升一级一次. 黑洞/Space/Burnt/标签升级不算星球使用 |
| 56 | `j_hiker` | IP | 每轮给该牌 `perma_bonus +=5`, 不清除已有永久筹码. 本轮基础筹码已提前读取, 这 +5 从下一轮重触发/下次打出开始计入; 蓝图可再加 |
| 57 | `j_faceless` | D, 批次末牌 | 数整批 `full_hand` 人头牌, >=3 给 $5, 每批仅一次. 可被 Pareidolia 扩大, 多张/蓝图分别给钱; 失效人头通常不被计数 |
| 58 | `j_green_joker` | B, D -> M | 正常手 B: mult +=1. 每次弃牌批次最后一张: mult=max(0,mult-1), 与弃几张无关. The Hook 也走 D, 不在回合末重置 |
| 59 | `j_superposition` | M | 计分牌包含 A, 且 `poker_hands.Straight` 非空, 有空位生成 1 塔罗. 同花顺也满足, A 必须在计分集合 |
| 60 | `j_todo_list` | 初始化, B, E | 从可见牌型中选目标. B 仅当最终 `scoring_name` 恰好目标才得 $4. E 改为其他可见牌型, 保证不同于原目标; 不按 "包含" 判断 |

### 3.3 order 61-90

主要来源: [选择盲注](<../../../game/card.lua#L2491-L2602>), [回合末](<../../../game/card.lua#L2888-L3063>), [before](<../../../game/card.lua#L3411-L3570>), [主效果](<../../../game/card.lua#L3640-L4056>), [U](<../../../game/card.lua#L4176-L4248>), [目标重选](<../../../game/functions/common_events.lua#L2271-L2324>), [持续属性与收入](<../../../game/card.lua#L564-L699>).

| # | id | 时机 | 精确规则/动态状态 |
| --- | --- | --- | --- |
| 61 | `j_cavendish` | M, E | 只有 `gros_michel_extinct` 后进入普通池; M X3, E 以 `normal/1000` 自毁. 出售 Gros Michel 不能解锁它 |
| 62 | `j_card_sharp` | M | 同一最终牌型 `played_this_round >1` 才 X3. 本次计数已加 1, 第二次开始有效; 首次手被拒绝也算已经打过 |
| 63 | `j_red_card` | Skip 包 -> M | 每次 `skipping_booster` mult +=3. 大型包先选 1 张再按 Skip 丢剩下的选择仍算; 在商店不购买包不算 |
| 64 | `j_madness` | S -> M | 仅非 Boss 盲注 x_mult +=0.5, 随机销毁一个其他非永恒/非已切片小丑. 无可销毁目标仍增长; 复制只输出当前 x_mult |
| 65 | `j_square` | B -> M | 打出的总牌数恰好 4 时 Chips +=4, 即使只有 1 张真正计分也增长; 起始为 0 |
| 66 | `j_seance` | M | 包含 `Straight Flush` 且有空位生成 1 幻灵; 支持 Four Fingers/Shortcut 修改后的同花顺 |
| 67 | `j_riff_raff` | S | 生成 min(2, 空槽含缓冲区) 张普通小丑, 不是先生成 2 张再溢出. 本体/蓝图依执行顺序争用容量 |
| 68 | `j_vampire` | B -> M | 对计分集合内非基础增强, 非失效, 非已 `vampired` 牌每张 x_mult +=0.1, 立即去增强, 保留版本/蜡封/永久筹码. 不吃不计分的增强, 不因 RP 多吃一次 |
| 69 | `j_shortcut` | P | 顺子中每两个已出现点数之间可跳过一个缺失点数, 不只是整条顺子总共缺一格. 不能连续缺两格, 不能从 K 绕过 A 连回 2 |
| 70 | `j_hologram` | 新增扑克牌 -> M | 初始 X1, 每个加入通知的 `context.cards` 项 +0.25. DNA/Certificate/Marble/标准包新增均算; Death 改写现有牌不算, 删牌不减 |
| 71 | `j_vagabond` | M | 执行该小丑时 `G.GAME.dollars <=4` 且有空位才生成塔罗. 不使用 `dollar_buffer` 加回余额, 因此不能用 Bull 的余额公式替代 |
| 72 | `j_baron` | IH | 每张留手 K 每轮 X1.5, 失效 K 不输出. 只看真实 id=13, 不被 Pareidolia 扩成所有人头 |
| 73 | `j_cloud_9` | U -> 收入 | 按整个牌组 `get_id()==9` 张数给每张 $1, 包括未抽到/失效普通 9. 石头牌 id 不算 9 |
| 74 | `j_rocket` | E -> 收入 | 初始收入 $1, 每次 Boss 回合末 `extra.dollars +=2`, 本次结算已按增长后收入. 不可复制收入 |
| 75 | `j_obelisk` | B -> M | 若本次计数增加后, 当前最终牌型为可见牌型中唯一最高 `played`, x_mult=1; 否则 +=0.2. 并列最高在增加后仍并列才增长, 详见案例 |
| 76 | `j_midas_mask` | B | 将计分牌中 `is_face()` 为真者改为金色增强, 可覆盖玻璃/钢/万能等增强, 保留版本/蜡封. 不处理非计分人头; Pareidolia 可扩大范围 |
| 77 | `j_luchador` | Selling Self | 只有当前面对未禁用 Boss 时禁用它. 在商店预先卖掉不会禁用下一个 Boss; 被吞噬/销毁无效 |
| 78 | `j_photograph` | IP | 找计分集合第一张 `is_face()` 的牌, 仅其每轮 X2. 不是所有人头都 X2; 重触发首张人头可重复 X2 |
| 79 | `j_gift` | E | 所有当前小丑与消耗牌 `extra_value +=1`, 包含本体, 逐张重新计算售价. 无须出售才成长 |
| 80 | `j_turtle_bean` | 入/出, E | 手上限起始 +5, 每个 E 减 1 并同步 `change_size(-1)`, 下一值 <=0 时自毁, 移除撤销剩余加成 |
| 81 | `j_erosion` | M | +4 * max(0, `starting_deck_size - #G.playing_cards`) Mult. 基准是本局实际起始牌数, 不是固定 52; 新增牌会抵消删牌收益 |
| 82 | `j_reserved_parking` | IH | 每张有效留手人头每轮以 `normal/2` 得 $1, 在计分阶段而非 E; Mime 可以增加掷骰 |
| 83 | `j_mail` | D | 每张非失效弃牌真实 id 与本回合目标相同给 $5. 目标从牌组非石头牌按实体抽样, 因此多副同点数使该点数更容易入选 |
| 84 | `j_to_the_moon` | 入/出 | 每张把 `interest_amount` +1, 移除撤销. 是每个 $5 区间多 $1 利息, 不提升利息上限, 无利息牌组/挑战仍无利息 |
| 85 | `j_hallucination` | Open 包 | 每次打开以 `normal/2` 生成塔罗, 要求空位. 可复制, 对包的剩余选择次数没有逐次触发 |
| 86 | `j_fortune_teller` | 使用 Tarot 提示, M | M 读取全局 `consumeable_usage_total.tarot`, 包含取得前用过的塔罗. 不是这张小丑自己的累计值; 卖塔罗不增长 |
| 87 | `j_juggler` | 入/出 | 每张持续手上限 +1, 移除/失效撤销. 蓝图不复制持续属性 |
| 88 | `j_drunkard` | 入/出 | `round_resets.discards +=1`, 当前剩余弃牌也加 1; 移除反向扣减. 每回合初始值受影响, 不只下回合生效 |
| 89 | `j_stone` | U -> M | 整个牌组 `m_stone` 增强张数 *25 Chips; 被吸血鬼去增强后不再计入 |
| 90 | `j_golden` | 收入 | 每次回合结算 $4, 不受手牌重触发影响, 蓝图不能复制 |

### 3.4 order 91-120

主要来源: [Lucky Cat 与 IP](<../../../game/card.lua#L3065-L3269>), [D/E](<../../../game/card.lua#L2756-L3063>), [RP/other_joker](<../../../game/card.lua#L3342-L3408>), [主效果](<../../../game/card.lua#L3640-L4056>), [Glass 的三个通知分支](<../../../game/card.lua#L2622-L2734>), [操作通知](<../../../game/functions/button_callbacks.lua#L2303-L2310>), [U](<../../../game/card.lua#L4176-L4248>).

| # | id | 时机 | 精确规则/动态状态 |
| --- | --- | --- | --- |
| 91 | `j_lucky_cat` | IP -> M | 该牌本轮 `lucky_trigger` 为真时 x_mult +=0.25, 初始 1. 幸运倍率/金钱任一成功即真, 同轮两个都成功仍只 +0.25. 每次 RP 可再成功/增长, 蓝图只复制输出 |
| 92 | `j_baseball` | Other Joker | 每处理一张原型 rarity=2 的其他小丑, X1.5. 不要求那张小丑主效果实际输出; 失效目标也可能被扫描, 但 Baseball 自己失效无效. 不对自己触发 |
| 93 | `j_bull` | M | Chips =2 * max(0, dollars + dollar_buffer), 读取执行到它时的余额与缓冲. 信用额度不算财富 |
| 94 | `j_diet_cola` | Selling Self | 出售时获得 1 Double Tag. 销毁/被吞噬无标签. 可复制 Selling Self, 但不是全排收到广播 |
| 95 | `j_trading` | D | 当 `discards_used <=0` 且整批只 1 张时得 $3 并销毁该牌; 无非失效限制. F 仅提示, 不负责销毁. The Hook 没有专门排除守卫 |
| 96 | `j_flash` | Reroll -> M | 每次刷新 mult +=2, 初始 0. 免费刷新算, 刷新 Boss 不走此 context |
| 97 | `j_popcorn` | M, E | 初始 +20 Mult, 每 E -4, 下一值 <=0 自毁. 最后一次仍先使用旧值计分 |
| 98 | `j_trousers` | B -> M | 包含两对/葫芦累计 mult +=2, 本手立即生效. 四条不会仅因可抽象拆成两对而增长 |
| 99 | `j_ancient` | IP | 匹配回合目标花色每轮 X1.5. 回合结束从其他 3 种花色选新目标, 不看牌组花色分布, 保证不连续相同 |
| 100 | `j_ramen` | D -> M | 初始 X2, 每张弃牌 -0.01, 下一值 <=1 时自毁. 与弃牌次数不同, 5 张扣 0.05; The Hook 也算. 浮点阈值以源码比较为准 |
| 101 | `j_walkie_talkie` | IP | 真 id 为 10/4 时每轮 +10 Chips,+4 Mult; 人头 nominal=10 不等于真实 id=10 |
| 102 | `j_selzer` | RP, A | 每张计分牌 +1 次, 初始剩余 10 手. 每 A 减 1, 下一值 <=0 自毁; 单手重触发多少张不额外消耗寿命, 被拒绝手也消耗 |
| 103 | `j_castle` | D -> M | 每张非失效且匹配目标花色的弃牌, 累计 Chips +=3. E 后目标从牌组非石头牌实体抽样花色, 不保证与前回合不同; 不重置累计 Chips |
| 104 | `j_smiley` | IP | 有效人头每轮 +5 Mult; 受 Pareidolia 扩展 |
| 105 | `j_campfire` | Selling Card, E -> M | 每卖一张其他小丑或消耗牌 x_mult +=0.25; Boss 回合末重置为 1. 在 Boss 商店卖牌可为下一底注重新积累 |
| 106 | `j_ticket` | IP | 当前增强为 Gold Card 才每轮得 $4. 金蜡封不等于金色增强; 与金蜡封收入可叠加 |
| 107 | `j_mr_bones` | E | 只有当前 `game_over` 且本盲注累计分数/目标 >=0.25 才救活并自毁; 不提高累计分数. 多张从左到右, 第一张救活后后面的不消耗 |
| 108 | `j_acrobat` | M | 已扣本手次数后 `hands_left==0` 才 X3. 与 Dusk 同条件, 提前达标不算最后一手 |
| 109 | `j_sock_and_buskin` | RP | 每张有效人头计分牌 +1 次, Pareidolia 可扩大; 留手人头不在范围 |
| 110 | `j_swashbuckler` | U -> M | mult = 其他当前处于小丑区的牌售价之和, 不管在它左/右. 不含自身, 不含消耗牌; Egg/Gift 的增值立即影响派生数值 |
| 111 | `j_troubadour` | 入/出 | 手上限 +2, `round_resets.hands -=1`; 不直接调用 `ease_hands_played`, 因此回合内取得不直接扣当前剩余出牌次数 |
| 112 | `j_certificate` | F | 每个首抽时创建随机普通扑克牌加入手牌, 随机四种蜡封各 1/4. 不要求抽牌堆有额外空位, 可使手牌临时超过上限; 通知 Hologram |
| 113 | `j_smeared` | P | `is_suit` 将红桃/方块视同类, 黑桃/梅花视同类. 不修改实体 base.suit, 石头仍无花色; 多张不进一步扩成四花色 |
| 114 | `j_throwback` | U -> M | x_mult =1 +0.25 * 本局全局 skips, 包含取得前跳过的盲注. `skip_blind` 只提示, 不再额外加一次 |
| 115 | `j_hanging_chad` | RP | 计分集合第一张有效牌 +2 次, 即通常共 3 轮. 判断是 `other_card == scoring_hand[1]`, 不是第一张打出牌; 第一张计分牌若失效, 不把 +2 转给后面 |
| 116 | `j_rough_gem` | IP | 每轮有效方块得 $1; 受万能/涂抹花色判定影响 |
| 117 | `j_bloodstone` | IP | 每轮有效红桃以 `normal/2` X1.5; 每个 RP/复制调用重新掷骰, 不是按红桃张数只抽一次 |
| 118 | `j_arrowhead` | IP | 每轮有效黑桃 +50 Chips |
| 119 | `j_onyx_agate` | IP | 每轮有效梅花 +7 Mult |
| 120 | `j_glass` | 移除/使用 Hanged Man -> M | 初始 X1, 每张已 `shattered` 的移除牌 +0.75; The Hanged Man 另查当时高亮的 Glass Card. 不按仅 "有玻璃增强" 的所有移除一概增加; 详见时序限制 |

### 3.5 order 121-150

主要来源: [主效果](<../../../game/card.lua#L3807-L4056>), [IP/IH](<../../../game/card.lua#L3065-L3341>), [入/出](<../../../game/card.lua#L564-L699>), [复制器](<../../../game/card.lua#L2304-L2334>), [Yorick/Trading 的 D](<../../../game/card.lua#L2788-L2844>), [Invisible/Perkeo](<../../../game/card.lua#L2371-L2427>), [PD/Caino](<../../../game/card.lua#L2622-L2755>), [卡池](<../../../game/functions/common_events.lua#L1963-L2029>), [价格](<../../../game/card.lua#L369-L395>).

| # | id | 时机 | 精确规则/动态状态 |
| --- | --- | --- | --- |
| 121 | `j_ring_master` | P | Showman 解除随机池的 `used_jokers` 重复排除, 允许已持有的小丑/塔罗/星球再出现. 不绕过禁用 id, 解锁, 增强门槛或特殊池标记; 多张不再增加重复概率乘数 |
| 122 | `j_flower_pot` | M | 按计分集合覆盖四花色才 X3. 先分配非万能牌, 每张最多填一个尚缺花色; 再分配万能牌, 每张也最多补一个缺口. 非计分牌无效, 不是一张万能就覆盖四花色 |
| 123 | `j_blueprint` | 递归当前 context | 紧邻右侧目标, 复制该次响应; 改排布即改目标, 不在取得时永久绑定 |
| 124 | `j_wee` | IP -> M | 每次有效 2 计分 `extra.chips +=8`, 重触发重复成长, 本手后面的 M 输出增长后的累计值. 蓝图只复制 Chips 输出 |
| 125 | `j_merry_andy` | 入/出 | 手牌上限 -1, 初始/当前弃牌 +3; 失效/移除撤销. 不增加每次允许弃掉的牌数 |
| 126 | `j_oops` | 入/出 | 所有 `G.GAME.probabilities[k]` 乘 2, 移除除 2. 多张为 2^n, 不作用于 Misprint 的 [0,23] 均匀抽样, 也不作用于未使用该概率表的商店版本概率 |
| 127 | `j_idol` | IP | 同时匹配真实点数 id 和目标花色 `is_suit` 才 X2. 目标从牌组非石头牌实体抽样, 多副同牌增加入选率; E 后更新, 全部 Idol 共用该局当前目标 |
| 128 | `j_seeing_double` | M | 计分集合至少 1 梅花, 且至少 1 红桃/方块/黑桃时 X2. 非万能牌可同时增多个花色计数, 万能牌每张只补一个; 万能先补梅花. 与 Flower Pot 的分配算法不同 |
| 129 | `j_matador` | 被拒绝手或 M | 仅 `G.GAME.blind.triggered` 为真才 $8; "Boss 名称存在" 不够. 被拒绝整手也可给钱; 普通失效计分牌会置 triggered, 单纯更高目标分等不一定置它 |
| 130 | `j_hit_the_road` | D -> M, E | 每张非失效 J 弃牌 x_mult +=0.5; E 重置为 1. Pareidolia 不让非 J 当 J; 复制只输出当前倍率 |
| 131 | `j_duo` | M | 包含对子时 X2, 三条/四条/五条满足, 并非最终牌型必须是 Pair |
| 132 | `j_trio` | M | 包含三条时 X3, 葫芦/四条/五条满足 |
| 133 | `j_family` | M | 包含四条时 X4, 五条满足 |
| 134 | `j_order` | M | 包含顺子时 X3, 同花顺满足 |
| 135 | `j_tribe` | M | 包含同花时 X2, 不是旧 effect 字段中残留的 X3 文案 |
| 136 | `j_stuntman` | 入/出, M | 本体持续手上限 -2, M +250 Chips. 蓝图只复制 +250, 不附带减手上限 |
| 137 | `j_invisible` | E, Selling Self | 持有期间每 E `invis_rounds +=1`, >=2 后出售随机复制另一小丑. 不要求售卖时额外空一格, 检查 `#jokers <= card_limit`; 不复制负片版本, 复制成长/贴纸等 ability. 若复制另一 Invisible, 新牌回合计数归 0 |
| 138 | `j_brainstorm` | 递归当前 context | 目标为当前最左小丑, 若最左是自己无效果; 不从第二张开始找兼容目标 |
| 139 | `j_satellite` | 收入 | 每个本局已经使用过的不同 Planet id 得 $1, 重复用同一 id 不重复增加种类. Black Hole 不属于 Planet; 取得前记录追溯有效 |
| 140 | `j_shoot_the_moon` | IH | 每张非失效留手 Q 每轮 +13 Mult, 不是回合末效果. Mime/红蜡封可重复, 不对所有人头触发 |
| 141 | `j_drivers_license` | U -> M | 整个牌组 `config.center != c_base` 数量 >=16 才 X3; 算增强, 不算仅版本/蜡封. 失效增强仍计数, 去增强后数量减少 |
| 142 | `j_cartomancer` | S | 每次实际选择盲注, 有消耗槽生成塔罗 1 张. 蓝图/本体按容量预约顺序触发, 不在跳盲注时生成 |
| 143 | `j_astronomer` | P, 入/出 | `Card:set_cost` 将所有 Planet 与名字含 Celestial 的补充包 cost 设 0, 获得/移除时对现有卡重算价格. 不让幻灵 Black Hole 变 Planet, 不免商店刷新费用 |
| 144 | `j_burnt` | PD | 本回合尚未主动弃牌且 `not context.hook`, 升级整批高亮弃牌最高牌型 1 级. 不需出牌成功, 有空白/失效牌仍按牌型判定. 每个蓝图再升一级, 不受卡面 `extra=4` 误导 |
| 145 | `j_bootstraps` | M | +2 * floor((dollars+dollar_buffer)/5) Mult, 仅结果至少 1 区间时输出. 余额可以随本手收入变化, 信用额度不算 |
| 146 | `j_caino` | 移除 -> M | 初始 `caino_xmult=1`, 每张被通知移除且 `is_face()` 为真的牌 +1. 人头由 Pareidolia 扩展, 但失效牌 `is_face()` 可返回空. 卖小丑/销毁小丑不算 |
| 147 | `j_triboulet` | IP | 仅真实 Q/K 每轮 X2. `is_face` 扩展不改变点数, 所以 Pareidolia 不把 A/2 等变成触发目标 |
| 148 | `j_yorick` | D -> M | 初始 X1, 每张弃牌让 `yorick_discards` 倒数, 到第 23 张时 XMult +=1 并重置倒数 23. 累计跨回合, 大批次余下牌继续下一轮; 每张而非每次弃牌动作 |
| 149 | `j_chicot` | 入, S | 获得时若已在未禁用 Boss 中立即禁用; 每次 S 的 Boss 也禁用. 无复制守卫以外的永久计分成长, 蓝图无此效果 |
| 150 | `j_perkeo` | Ending Shop | 有消耗牌时随机复制一张并设为负片, 不需普通空槽, 可复制已有负片消耗牌. 各复制效果是排队事件, 不必然共用同一源牌 |

## 4. 重触发, 成长与事件时序

### 4.1 重触发是次数相加, 不是重触发器相乘

假设首张计分牌是 Q, 同时有 Hanging Chad, Sock and Buskin 与红蜡封, 它执行 `1 + 2 + 1 + 1 = 5` 轮. 若它也是第一张人头, Photograph 产生 5 次 X2, 而不是 3*2*2=12 轮. 在全程无其他 Mult 加法的简化情形下, Photograph 对当时倍率的乘数为 2^5.

每轮会重做该牌自身的幸运掷骰, 金蜡封收入, 所有 IP 小丑响应及牌版本. 例如 Wee 在同一张 2 上可以长多次; Hiker 第一次加的永久筹码从第二轮起计入. **不会**重做 B 中的 Vampire 成长, M 中整排小丑, 或计分之后的玻璃破碎概率.

来源: [重触发列表构造与逐轮计算](<../../../game/functions/state_events.lua#L648-L778>), [玻璃检查](<../../../game/functions/state_events.lua#L950-L975>).

### 4.2 幸运猫不是两种幸运效果各加一次

`get_chip_mult` 的幸运倍率成功与 `get_p_dollars` 的幸运金钱成功均设置同一个 `lucky_trigger` 布尔值. Lucky Cat 读取布尔值一次, 然后调用方清空. 因此单轮两种均成功只增长 0.25, 多轮才可能多次增长. Oops 的翻倍同时提高两种成功率.

来源: [幸运倍率](<../../../game/card.lua#L984-L997>), [幸运金钱](<../../../game/card.lua#L1068-L1089>), [Lucky Cat](<../../../game/card.lua#L3076-L3082>), [清除标记](<../../../game/functions/state_events.lua#L692-L700>).

### 4.3 米达斯面具与吸血鬼的左右顺序

B 按小丑横向顺序执行. `Midas Mask -> Vampire` 时, 有效计分人头先变金色, 再被 Vampire 去增强并增长. `Vampire -> Midas Mask` 时, 吸血鬼先吃原增强, 面具随后可将该人头重新设为金色, 留下金色增强, Golden Ticket 的 IP 随后可得钱.

吸血鬼在 B 而不是 IP 吃增强, 因而不会保留被吃掉的玻璃 X2/幸运效果直到计分后. 保留牌型已选定的计分集合, 不重新用去增强后的整手判定牌型. 多个 Vampire 用临时 `vampired` 防止同一处理链重复吃牌. Midas 不增加扑克牌数量, 与 Hologram 没有新增牌增长关系.

来源: [Midas/Vampire](<../../../game/card.lua#L3443-L3489>), [增强设置保留永久筹码](<../../../game/card.lua#L277-L303>), [计分集合先生成](<../../../game/functions/state_events.lua#L571-L630>).

### 4.4 方尖碑的并列最高边界

B 之前已经给本次最终牌型 `played +=1`. 所以判断不是简单比较 "出牌前最常用牌型".

- 出牌前高牌 10 次, 对子 8 次. 再出对子, 新计数 9 <10, Obelisk 增长.
- 出牌前高牌 10 次, 对子 9 次. 再出对子, 新计数 10 与高牌并列, 仍增长.
- 出牌前高牌 10 次, 对子 10 次. 再出对子, 新计数 11 成为唯一最高, 重置.
- 被 Boss 拒绝的牌型仍增加全局计数, 但不执行 B, 即不在那一手立即增长/重置; 它改变之后正常手的比较基准.

来源: [先增加计数](<../../../game/functions/state_events.lua#L574-L578>), [Obelisk 判断](<../../../game/card.lua#L3543-L3562>).

### 4.5 花色覆盖算法不能统一成一张牌的花色集合并集

- Flower Pot 非万能牌用 `if/elseif` 顺序 Hearts -> Diamonds -> Spades -> Clubs, 每张至多填一个空缺; 然后万能牌依同样顺序填空缺. 被失效的普通牌在第一轮 `bypass_debuff=true` 仍可贡献基础/涂抹花色, 但失效万能牌第二轮不贡献.
- Seeing Double 对非万能牌用四个独立 `if`, 所以一张涂抹判定的黑色牌可以同时计入 Clubs 与 Spades. 万能牌再按 Clubs -> Diamonds -> Spades -> Hearts 每张只填一格. 单张无涂抹万能牌通常不能独自满足两个需求.
- Blackboard 用 `flush_calc=true`, 失效普通黑牌仍黑, 但失效万能恢复只按基础花色判断. 石头牌不是黑牌.

来源: [Flower Pot/Seeing Double](<../../../game/card.lua#L3807-L3872>), [Blackboard](<../../../game/card.lua#L3951-L3964>), [Card:is_suit](<../../../game/card.lua#L4064-L4088>).

### 4.6 回合结束与全局随机目标

- E 从左到右, 之后才处理留手回合末效果, 然后进入收入计算. Rocket 在 Boss E 增长, 当次结算就多给钱. Campfire 在 Boss E 清零, 不影响刚刚完成的 Boss 最后一手.
- 租赁扣费/易腐计数在每张小丑 E 之后执行. 若易腐刚在 E 后失效, 后续 `calculate_dollar_bonus` 会看到 `debuff` 并不给收入, 不能仅凭回合中有效就预计它有结算收入.
- Idol/Mail/Castle 的目标从 `G.playing_cards` 的非石头牌实体抽样. 多副相同牌会增加其点数/花色作为目标的概率; 各副同名小丑共用全局目标, 不是各自抽目标.
- Ancient 与前三者不同: 只从上回合目标之外的 3 种花色均匀选, 不限于牌组现有花色.
- 这些目标在正常回合结束后的流程中重选, 不在每次出牌改变; 起局也初始化. To Do List 的目标是每张小丑自己的 `to_do_poker_hand`, 不与其他副共用, 从 `G.handlist` 的可见牌型中抽.

来源: [E/贴纸结算](<../../../game/functions/state_events.lua#L99-L110>), [回合末目标重选](<../../../game/functions/state_events.lua#L273-L276>), [目标重选函数](<../../../game/functions/common_events.lua#L2271-L2324>), [To Do List](<../../../game/card.lua#L2975-L2984>).

### 4.7 失效与持续属性

`Card:set_debuff` 对处于小丑区的牌调用 `remove_from_deck(true)` 或 `add_to_deck(true)`, 从而撤销/恢复 Juggler, Oops, To the Moon, Credit Card 等持续属性. 已有累计成长一般不清零, 恢复后可继续输出. 负片槽位在失效时使用延迟移除标记, 不要立即把失效负片当成从排面被删掉.

`update` 中全牌组数值重算与各效果输出判断是两件事. 例如 Driver/Steel/Stone 的牌组统计可以包括失效扑克牌, 但该小丑自己失效仍不输出. `find_joker` 默认排除失效小丑, 因此 Four Fingers/Pareidolia/Showman 等被动规则失效后不再参与.

来源: [失效切换](<../../../game/card.lua#L526-L538>), [入/出与负片](<../../../game/card.lua#L564-L699>), [实时统计](<../../../game/card.lua#L4176-L4208>), [find_joker](<../../../game/functions/misc_functions.lua#L903-L917>).

## 5. 1.0.1o 数值与旧规则隔离

这里列的是 1.0.1o **已经具有**的行为, 不表示这些变化恰好首次发布于 o. 旧攻略常混用首发与 1.0.1 系列规则, 自动决策不得沿用旧数值.

| 小丑 | 本仓库确认的 1.0.1o 行为 | 应排除的旧说法 |
| --- | --- | --- |
| Yorick | 每累计弃 23 **张牌**增加 X1, 可持续成长 | 弃牌 23 **次动作**后固定 X5 |
| Vampire | 每张有效增强 **计分牌** +X0.1 | 每张打出的增强牌 +X0.2, 包括不计分踢脚牌 |
| Hanging Chad | 第一张计分牌额外 2 次 | 仅额外 1 次 |
| 8 Ball | 每张计分 8 以 1/4 生成塔罗 | 一手打出两张 8 即必定生成 |
| Bloodstone | 每张红桃以 1/2 得 X1.5 | 1/3 得 X2 |
| Runner | 初始 0 Chips, 每个包含顺子的正常手 +15 | 旧起始值/增长速度 |
| Square Joker | 初始 0 Chips, 每个总共打出 4 张的正常手 +4 | 旧初始 Chips |
| Stuntman | +250 Chips, 手牌上限 -2 | +300 Chips |
| Seeing Double | 梅花和其他花色, X2 | 仅针对某张固定梅花点数的旧 effect 文案 |

来源: [小丑原型和实际 config](<../../../game/game.lua#L368-L526>), [D/B/IP/RP 实现](<../../../game/card.lua#L2788-L2799>), [Vampire](<../../../game/card.lua#L3465-L3489>), [Hanging Chad](<../../../game/card.lua#L3352-L3359>). wiki 交叉核对: [Yorick](https://balatrowiki.org/w/Yorick) 的更新历史明确区分 23 次旧规则与每 23 张成长; [Vampire](https://balatrowiki.org/w/Vampire) 与 [Hanging Chad](https://balatrowiki.org/w/Hanging_Chad) 的当前页面支持计分牌/重触发机制. 当 wiki 页后来更新时, 仍以这些源码分支和 config 为准.

## 6. 实现/观测时需要谨慎的点

这些是从代码调用链能定位的边界, 没有运行游戏验证. 不应在 agent 预测中悄悄把它们简化成卡面自然语言.

1. **Glass Joker 的消耗牌销毁时序**. 普通计分玻璃自碎在通知前就设置 `shattered=true`, 所以必增长. Trading 弃牌销毁玻璃先调用 `shatter()`, 再通知, 同样满足. 但 `Card:use_consumeable` 对 Familiar/Grim/Incantation/Immolate 是排队 `shatter()` 之后, 同步通知 `remove_playing_cards`; 当时可能尚未设置 `shattered`. The Hanged Man 有独立 `using_consumeable` 检查高亮玻璃牌补偿. 因此不要假定所有幻灵销毁玻璃必定触发一次 Glass 成长, 或把两个通知机制机械相加. 需要精确仿真时保留事件队列和通知当时的标记, 并对结果作观测核对. 来源: [use_consumeable 销毁入口](<../../../game/card.lua#L1269-L1371>), [Glass 分支](<../../../game/card.lua#L2687-L2721>), [shatter 设置标记](<../../../game/card.lua#L2079-L2082>).
2. **找不到调用的旧分支不能自己创造事件**. `cards_destroyed` 仍存在, 接收 `glass_shattered`, 但实际调用用 `remove_playing_cards`. 不同时派发两者. 来源: [旧分支](<../../../game/card.lua#L2622-L2671>), [实际计分销毁通知](<../../../game/functions/state_events.lua#L950-L975>).
3. **异步生成的源牌选择**. Perkeo 的随机消耗牌选择位于排队事件内部, 多个 Perkeo/复制器后面的事件可能看到前面已生成的负片. Invisible 的复制保留 ability 成长字段, 但显式去掉负片并重置新 Invisible 的持有回合数. 不应将 "复制" 统一为回到初始 config. 来源: [Perkeo](<../../../game/card.lua#L2413-L2424>), [Invisible](<../../../game/card.lua#L2371-L2394>), [copy_card](<../../../game/functions/common_events.lua#L2156-L2180>).
4. **动态值可能由 update 派生**. Stencil/Swashbuckler/Throwback/Steel/Stone/Driver/Cloud 9 的数值不只在特定操作 context 增量修改. 读状态时优先同时记录原材料数量, 售价, skips 与字段, 避免动画中的旧提示值当成下一手最终值.
5. **全牌组都是石头时的目标**. `reset_idol_card`/`reset_mail_rank` 无有效候选只重设部分显示字段, 没有在函数开头重设 id. 不要从显示的 Ace 文案推断新目标 id; 按实际 `current_round.*.id` 读取. 来源: [目标函数](<../../../game/functions/common_events.lua#L2271-L2301>).
6. **Matador 不等于所有 Boss 负面效果都给钱**. 它只读 `blind.triggered`, 没有重新鉴定本手损失来源. `debuff_hand` 先将此标记清为 false, 会覆盖 The Hook/The Tooth/Crimson Heart 在 `press_play` 设置的 true, 因此不能只看到前者设置标记就预测 $8. 正常可满足的路径包括: Psychic/Eye/Mouth 拒绝整手, Arm 在牌型等级 >1 时降级, Ox 命中目标牌型, Flint 的减半, 或计分集合中存在失效扑克牌. 没有实际失效计分牌时, Wall/Manacle/Water/Needle/翻背/强制选牌等单纯限制通常不给钱. 来源: [Matador 两个分支](<../../../game/card.lua#L2735-L2747>), [M 分支](<../../../game/card.lua#L3719-L3729>), [计分失效置标记](<../../../game/functions/state_events.lua#L654-L663>), [Blind:press_play/modify_hand/debuff_hand](<../../../game/blind.lua#L466-L570>).

## 7. 自动决策前的最小小丑状态清单

- 有序小丑列表: id, 是否失效, 版本, 贴纸, 售价, 是否已标记销毁, 当前动态 ability 字段.
- 本手输入: 打出顺序, `full_hand`, `scoring_hand`, 最终牌型, 子牌型列表; 扣除本手后的 `hands_left` 与出牌前 `hands_played`.
- 所有牌型的全局/本回合 `played`, 本局 `hands_played`, 取得时 `hands_played_at_create`, 全局 skips.
- 消耗牌列表/上限/预约数, 小丑槽位上限/预约数; 不能把生成承诺当作无限容量.
- 当前 dollars/dollar_buffer/透支线, 牌组起始张数和当前完整牌组, 抽牌堆剩余数量, 牌组增强统计.
- Idol/Mail/Castle/Ancient 的全局随机目标, 每张 To Do List 的个别目标, Yorick 倒数, Invisible 回合数, 食物寿命.
- `probabilities.normal`, `gros_michel_extinct`, 全局塔罗使用次数与不同星球使用记录.
- Boss 的 `triggered/disabled` 与拒绝整手判定. 不只记录 Boss 名称.

这一清单只描述应读懂的游戏状态, 不规定截图识别, 输入驱动或自动化框架.
