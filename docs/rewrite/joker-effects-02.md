# 小丑效果规格 02: calculate_joker 第二段

覆盖 `game/card.lua` 的 `Card:calculate_joker` 第 3065 行到第 4062 行, 即 `context.individual` 分支, `context.repetition` 分支, `context.other_joker` 分支, 以及 `else` 分支里的 `context.cardarea == G.jokers` 部分.

## 0. 阅读约定

- 行号均为当前仓库 `game/card.lua` 的行号.
- `extra` 等原型参数取自 `game/game.lua` 的同名 center, 括号里给出该 center 的行号.
- 文中 `self.ability.*` 是卡牌运行时状态, `card.ability.*` 是"被打分的那张牌"的运行时状态.
- 函数返回 `nil` 表示"不生效", 返回 table 表示"生效"; 因为每个小丑的判定都是顺序 `if`, 同一小丑在同一 context 下最多只返回第一个命中的分支.
- `context.blueprint` 为真表示这个小丑是被蓝图 (Blueprint) 或头脑风暴 (Brainstorm) 复制触发的. 复制时蓝图会把真正的效果持有者算一遍, 然后把返回值的 `card` 改成蓝图自身, `colour` 改成 `G.C.BLUE` (Blueprint) 或 `G.C.RED` (Brainstorm), 见第 2304-2333 行. 蓝图自身和头脑风暴不参与本段任何判定, 它们的 `context.blueprint` 标记才是关键.
- 本段中所有小丑的 `context.*` 入口都由 `game/functions/state_events.lua` 的计分流程调用, 调用点见下文各节.

## 1. 本段用到的 context 与返回值字段

### 1.1 context 字段及触发时机

| context | 额外字段 | 触发点 |
| --- | --- | --- |
| `context.individual` | `context.cardarea == G.play` | 每张计分牌每轮重复时, `state_events.lua:695` 对每个小丑调用 |
| `context.individual` | `context.cardarea == G.hand` | 每张留在手里的牌, `state_events.lua:802` 对每个小丑调用 |
| `context.repetition` | `context.cardarea == G.play` | 计分牌第一次打分的重复次数统计, `state_events.lua:678` |
| `context.repetition` | `context.cardarea == G.hand` | 手里牌第一次打分的重复次数统计, `state_events.lua:823` |
| `context.other_joker` | `context.other_joker` | 每张小丑自身效果结算完之后, 其它小丑对它的结算, `state_events.lua:920` |
| 其余 (无专用键) | `context.cardarea == G.jokers` | 小丑主效果; 细分 `context.before` (`state_events.lua:630`), `context.after` (`state_events.lua:1070`), 两者都不是的默认分支 (`state_events.lua:905`) |

备注: `context.before` 的调用点传入的是 `before = true`, 而不是把 `cardarea` 当作唯一判据; 本段代码里的结构是 `cardarea == G.jokers` 之下先判 `context.before`, 再 `context.after`, 再默认分支.

### 1.2 返回值的消费方

| 字段 | 生效方式 |
| --- | --- |
| `chips` | 只用于 `context.individual`; 加到本轮 `hand_chips` (加法), `state_events.lua:704-709` |
| `mult` | 只用于 `context.individual`; 加到本轮 `mult` (加法), `state_events.lua:712-717` |
| `x_mult` | 只用于 `context.individual`; 乘到本轮 `mult`, `state_events.lua:751-756` (在手牌 loop 里是 857-862) |
| `h_mult` | 只用于 `context.individual` 且 `context.cardarea == G.hand`; 加到本轮 `mult`, `state_events.lua:850-855` |
| `dollars` | 立即 `ease_dollars`, `state_events.lua:727-731` (手牌 loop 845-848) |
| `extra` | 立即执行: 可用 `extra.mult_mod` 加 mult, `extra.chip_mod` 加 chips, `extra.swap` 交换 chips 与 mult, `extra.func()` 执行副作用, `state_events.lua:734-748` |
| `repetitions` | 只用于 `context.repetition`; 该计分牌多打分几次, `state_events.lua:680-683`, 823-828 |
| `level_up` | 只用于主效果 `before` 分支; 触发 `level_up_hand(持有者小丑, 当前牌型)`, `state_events.lua:634-636` |
| `mult_mod` | 加到 `mult`, `state_events.lua:910` (也被 `context.other_joker` 分支消费, 923) |
| `chip_mod` | 加到 `hand_chips`, `state_events.lua:911` (也被 924) |
| `Xmult_mod` | 乘到 `mult`, `state_events.lua:912` (也被 925) |
| `message` | 仅用于飘字显示 |
| `colour` | 仅用于飘字颜色 |
| `card` | 用于让某个小丑播动画 (`juice_card` / `juice_up`) |
| `playing_cards_created` | 由 DNA 使用, 用于提示新牌 |
| `remove` | 用于 `context.discard` 等分支, 本段不涉及 |

### 1.3 通用规则 (主效果默认分支, 第 3653-3671 行)

下面三条在 `else` 默认分支里先于所有小丑专有判定执行, 对所有"主效果型"小丑都生效, 命中即返回, 后面的专有判定不再执行:

1. 第 3653-3659 行: 若 `self.ability.name ~= 'Seeing Double'` 且 `self.ability.x_mult > 1` 且 (`self.ability.type == ''` 或 `next(context.poker_hands[self.ability.type])`), 返回 `{message = a_xmult(self.ability.x_mult), colour = G.C.RED, Xmult_mod = self.ability.x_mult}`. 这条服务于可用 `Xmult` 配置初始化的成长型小丑 (如吸血鬼, 方尖石塔, 卡尼奥等, 但卡尼奥的 `self.ability.x_mult` 恒为 1, 见其小节).
2. 第 3660-3665 行: 若 `self.ability.t_mult > 0` 且 `next(context.poker_hands[self.ability.type])`, 返回 `{message = a_mult(t_mult), mult_mod = self.ability.t_mult}`.
3. 第 3666-3671 行: 若 `self.ability.t_chips > 0` 且 `next(context.poker_hands[self.ability.type])`, 返回 `{message = a_chips(t_chips), chip_mod = self.ability.t_chips}`.

注: `t_mult` 与 `t_chips` 由 `self.ability.type` 指定的牌型决定是否生效, 本仓库 1.0.1o 的原版小丑里没有用到这两个字段的小丑, 它们是为 MOD 预留的结构.

## 2. A 类: context.individual (每张牌的个体效果)

入口: `context.individual == true`, 由 `state_events.lua:695` (`cardarea == G.play`) 与 `state_events.lua:802` (`cardarea == G.hand`) 调用. 每张牌每轮重复都会重新问一次, 所以效果会随重复次数叠加.

### 2.1 照片 / Photograph (`j_photograph`)

- 源码: 第 3093-3105 行. `extra = 2` (game.lua:450).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`. 先在 `context.scoring_hand` 里找到第一张 `is_face()` 的牌 `first_face`, 再要求 `context.other_card == first_face`.
- 返回: `{x_mult = self.ability.extra, colour = G.C.RED, card = self}`.
- 读取状态: `context.scoring_hand`.
- 副作用: 无. 不检查 `context.blueprint`, 因此蓝图复制时也会生效 (数值取自蓝图自身 `ability.extra`).
- 备注: 本段起点在第 3100 行, 该分支跨越起点, 这里写全.

### 2.2 八号球 / 8 Ball (`j_8_ball`)

- 源码: 第 3106-3126 行. `extra = 4` (game.lua:394).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `#G.consumeables.cards + G.GAME.consumeable_buffer < G.consumeables.config.card_limit`, 且 `context.other_card:get_id() == 8`, 且 `pseudorandom('8ball') < G.GAME.probabilities.normal / self.ability.extra`.
- 返回: `{extra = {focus = self, message = k_plus_tarot, func = ...}, colour = G.C.SECONDARY_SET.Tarot, card = self}`. `func` 里 `G.GAME.consumeable_buffer = G.GAME.consumeable_buffer + 1` (在返回前已经加过一次), 然后 AddEvent 创建一张 `'Tarot'` 消耗牌 (`create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, '8ba')`), `card:add_to_deck()`, `G.consumeables:emplace(card)`, 最后把 `G.GAME.consumeable_buffer` 归零.
- 读取状态: `#G.consumeables.cards`, `G.GAME.consumeable_buffer`, `G.consumeables.config.card_limit`, `G.GAME.probabilities.normal`, `context.other_card` 的 id.
- 副作用: 写 `G.GAME.consumeable_buffer`, 生成并加入一张塔罗牌.
- 类别: 小丑; 产物类别为 Tarot (塔罗).

### 2.3 偶像 / The Idol (`j_idol`)

- 源码: 第 3127-3135 行. `extra = 2` (game.lua:502).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:get_id() == G.GAME.current_round.idol_card.id`, 且 `context.other_card:is_suit(G.GAME.current_round.idol_card.suit)`.
- 返回: `{x_mult = self.ability.extra, colour = G.C.RED, card = self}`.
- 读取状态: `G.GAME.current_round.idol_card` (`{rank, suit}`), 由回合开始时选取.
- 副作用: 无. 不检查蓝图.

### 2.4 恐怖面孔 / Scary Face (`j_scary_face`)

- 源码: 第 3136-3142 行. `extra = 30` (game.lua:402).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:is_face()`.
- 返回: `{chips = self.ability.extra, card = self}`.
- 副作用: 无.

### 2.5 微笑表情 / Smiley Face (`j_smiley`)

- 源码: 第 3143-3149 行. `extra = 5` (game.lua:477).
- 触发条件: 同 2.4, 且 `context.other_card:is_face()`.
- 返回: `{mult = self.ability.extra, card = self}`.

### 2.6 金票 / Golden Ticket (`j_ticket`)

- 源码: 第 3150-3158 行. `extra = 4` (game.lua:479).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card.ability.name == 'Gold Card'` (金色强化).
- 返回: `{dollars = self.ability.extra, card = self}`.
- 副作用: 返回前先 `G.GAME.dollar_buffer = (G.GAME.dollar_buffer or 0) + self.ability.extra`, 并 AddEvent 把 `G.GAME.dollar_buffer` 归零 (用于显示中的暂存金额).
- 读取状态: 被打分牌的强化名.

### 2.7 学者 / Scholar (`j_scholar`)

- 源码: 第 3159-3166 行. `extra = {mult = 4, chips = 20}` (game.lua:410).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:get_id() == 14` (A).
- 返回: `{chips = self.ability.extra.chips, mult = self.ability.extra.mult, card = self}`.

### 2.8 对讲机 / Walkie Talkie (`j_walkie_talkie`)

- 源码: 第 3167-3174 行. `extra = {chips = 10, mult = 4}` (game.lua:474).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:get_id() == 10` 或 `== 4`.
- 返回: `{chips = self.ability.extra.chips, mult = self.ability.extra.mult, card = self}`.

### 2.9 名片 / Business Card (`j_business`)

- 源码: 第 3175-3184 行. `extra = 2` (game.lua:411).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:is_face()`, 且 `pseudorandom('business') < G.GAME.probabilities.normal / self.ability.extra`.
- 返回: `{dollars = 2, card = self}`. 注意金额是硬编码的 `2`, 不读 `extra`; `extra` 只当作概率分母.
- 副作用: 与金票相同, 增删 `G.GAME.dollar_buffer` 各一次.

### 2.10 斐波那契 / Fibonacci (`j_fibonacci`)

- 源码: 第 3185-3195 行. `extra = 8` (game.lua:399).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:get_id()` 属于 `{2, 3, 5, 8, 14}`.
- 返回: `{mult = self.ability.extra, card = self}`.

### 2.11 偶数史蒂文 / Even Steven (`j_even_steven`)

- 源码: 第 3196-3205 行. `extra = 4` (game.lua:408).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:get_id() <= 10` 且 `>= 0` 且 `get_id() % 2 == 0`. 即 2, 4, 6, 8, 10; 不含 A (14), 不含 J/Q/K.
- 返回: `{mult = self.ability.extra, card = self}`.

### 2.12 奇数托德 / Odd Todd (`j_odd_todd`)

- 源码: 第 3206-3216 行. `extra = 31` (game.lua:409).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 (`get_id() <= 10` 且 `>= 0` 且 `get_id() % 2 == 1`) 或 `get_id() == 14`. 即 3, 5, 7, 9 (不含 A) 与 A.
- 返回: `{chips = self.ability.extra, card = self}`.
- 注意: `extra` 在当前版本原型里是 31.

### 2.13 花色倍率小丑 (贪婪 / 色欲 / 愤怒 / 暴食, 通过 `effect == 'Suit Mult'`)

- 源码: 第 3217-3223 行.
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `self.ability.effect == 'Suit Mult'`, 且 `context.other_card:is_suit(self.ability.extra.suit)`.
- 返回: `{mult = self.ability.extra.s_mult, card = self}`.
- 读取状态: `self.ability.effect`, `self.ability.extra.suit`, `self.ability.extra.s_mult` (原型为 `config = {s_mult = N, suit = 'Hearts' | 'Diamonds' | 'Spades' | 'Clubs'}`).
- 覆盖的 id: `j_greedy_joker` (方块), `j_lusty_joker` (红桃), `j_wrathful_joker` (黑桃), `j_gluttenous_joker` (梅花). 这四个 id 在原版里共用同一段代码, 靠 `extra.suit` 区分.
- 副作用: 无. 不检查蓝图.
- 注意: 这里用的是 `is_suit(suit)` 而不是 `is_suit(suit, true)`, 所以会受"万能牌 (Wild Card)"影响, 也会受花色转换影响.

### 2.14 璞玉 / Rough Gem (`j_rough_gem`)

- 源码: 第 3224-3232 行. `extra = {count = 30, suit = 'Diamonds'}` (game.lua:490).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:is_suit("Diamonds")`.
- 返回: `{dollars = self.ability.extra, card = self}`. 金额取 `extra` 标量, 原型里是 30. (`extra.count` 与 `extra.suit` 只用于解锁条件提示.)
- 副作用: 与金票相同, 增删 `G.GAME.dollar_buffer`.

### 2.15 缟玛瑙 / Onyx Agate (`j_onyx_agate`)

- 源码: 第 3233-3239 行. `extra = {count = 30, suit = 'Clubs'}` (game.lua:493).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:is_suit("Clubs")`.
- 返回: `{mult = self.ability.extra, card = self}`. 数值 30.

### 2.16 箭头 / Arrowhead (`j_arrowhead`)

- 源码: 第 3240-3246 行. `extra = {count = 30, suit = 'Spades'}` (game.lua:492).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:is_suit("Spades")`.
- 返回: `{chips = self.ability.extra, card = self}`. 数值 30.

### 2.17 血石 / Bloodstone (`j_bloodstone`)

- 源码: 第 3247-3254 行. `extra = {odds = 2, Xmult = 1.5}` (game.lua:491).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:is_suit("Hearts")`, 且 `pseudorandom('bloodstone') < G.GAME.probabilities.normal / self.ability.extra.odds`.
- 返回: `{x_mult = self.ability.extra.Xmult, card = self}`.
- 读取状态: `G.GAME.probabilities.normal`, `self.ability.extra.odds`.

### 2.18 古老小丑 / Ancient Joker (`j_ancient`)

- 源码: 第 3255-3261 行. `extra = 1.5` (game.lua:472).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:is_suit(G.GAME.current_round.ancient_card.suit)`.
- 返回: `{x_mult = self.ability.extra, card = self}`.
- 读取状态: `G.GAME.current_round.ancient_card.suit` (由回合结束时 `Card:get_end_of_round_effect` 之外的逻辑轮换, 每次换局随机花色).

### 2.19 特里布莱 / Triboulet (`j_triboulet`)

- 源码: 第 3262-3269 行. `extra = 2` (game.lua:523).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `context.other_card:get_id() == 12` (Q) 或 `== 13` (K).
- 返回: `{x_mult = self.ability.extra, colour = G.C.RED, card = self}`.

### 2.20 射月 / Shoot the Moon (`j_shoot_the_moon`)

- 源码: 第 3272-3286 行. `extra = 13` (game.lua:516).
- 触发条件: `context.individual` 且 `context.cardarea == G.hand`, 且 `context.other_card:get_id() == 12` (Q).
- 返回: 若 `context.other_card.debuff` 则 `{message = k_debuffed, colour = G.C.RED, card = self}`; 否则 `{h_mult = 13, card = self}`. 注意 13 是硬编码, 不读 `extra`.
- 读状态: `context.other_card.debuff`.
- 备注: 在手牌 loop (`state_events.lua:784-871`) 里生效, 命中的牌不要求参与当前牌型, 只要是留在手里的 Q 即可. `h_mult` 加到本轮 mult.

### 2.21 男爵 / Baron (`j_baron`)

- 源码: 第 3287-3301 行. `extra = 1.5` (game.lua:443).
- 触发条件: `context.individual` 且 `context.cardarea == G.hand`, 且 `context.other_card:get_id() == 13` (K).
- 返回: `context.other_card.debuff` 时 `{message = k_debuffed, colour = G.C.RED, card = self}`, 否则 `{x_mult = self.ability.extra, card = self}`.
- 备注: 在手牌 loop 里生效, `x_mult` 乘到本轮 mult.

### 2.22 私人车位 / Reserved Parking (`j_reserved_parking`)

- 源码: 第 3302-3319 行. `extra = {odds = 2, dollars = 1}` (game.lua:454).
- 触发条件: `context.individual` 且 `context.cardarea == G.hand`, `context.other_card:is_face()`, 且 `pseudorandom('parking') < G.GAME.probabilities.normal / self.ability.extra.odds`.
- 返回: `context.other_card.debuff` 时 `{message = k_debuffed, colour = G.C.RED, card = self}`; 否则先 `G.GAME.dollar_buffer += self.ability.extra.dollars` 并 AddEvent 归零, 返回 `{dollars = self.ability.extra.dollars, card = self}`.
- 读状态: `G.GAME.probabilities.normal`, `self.ability.extra.odds`, `self.ability.extra.dollars`.

### 2.23 致胜之拳 / Raised Fist (`j_raised_fist`)

- 源码: 第 3320-3340 行. 无 `config.extra` (game.lua:397).
- 触发条件: `context.individual` 且 `context.cardarea == G.hand`, 且 `context.other_card` 恰好是在手牌里"点数最低"的那张牌.
- 最低牌的判定 (第 3321-3325 行): `temp_Mult, temp_ID = 15, 15`; 遍历 `G.hand.cards`, 若 `temp_ID >= G.hand.cards[i].base.id` 且该牌 `ability.effect ~= 'Stone Card'`, 就取 `temp_Mult = base.nominal`, `temp_ID = base.id`, `raised_card = 该牌`. 即: 跳过石头牌, 用 `base.id` 比较, 取 id 最小 (A 的 `base.id` 为 14, 因此 A 不会赢过 2..10, 会被 J/Q/K 与 2..10 击败), 记录其 `base.nominal` (A 为 11).
- 返回: `raised_card == context.other_card` 时, 若该牌 `debuff` 则 `{message = k_debuffed, colour = G.C.RED, card = self}`, 否则 `{h_mult = 2 * temp_Mult, card = self}`.
- 读状态: `G.hand.cards` 全部, `context.other_card.debuff`.
- 副作用: 无.
- 备注: `raised_card` 与 `context.other_card` 是同一指针比较; 同点数并列时取遍历中最后满足条件的那张 (因为条件是 `>=`).

## 3. B 类: context.repetition (重复打分次数)

入口: 计分牌/手牌第一次打分前统计重复次数, 见 `state_events.lua:678` (play) 与 `state_events.lua:823` (hand). 返回的 `repetitions` 会让该牌再走 `repetitions` 轮同样的打分流程.

### 3.1 喜与悲 / Sock and Buskin (`j_sock_and_buskin`)

- 源码: 第 3344-3351 行. `extra = 1` (game.lua:483).
- 触发条件: `context.repetition` 且 `context.cardarea == G.play`, 且 `context.other_card:is_face()`.
- 返回: `{message = k_again_ex, repetitions = self.ability.extra, card = self}`.

### 3.2 未断选票 / Hanging Chad (`j_hanging_chad`)

- 源码: 第 3352-3359 行. `extra = 2` (game.lua:489).
- 触发条件: `context.repetition` 且 `context.cardarea == G.play`, 且 `context.other_card == context.scoring_hand[1]` (计分牌的从左到右第一张).
- 返回: `{message = k_again_ex, repetitions = self.ability.extra, card = self}`.

### 3.3 黄昏 / Dusk (`j_dusk`)

- 源码: 第 3360-3366 行. `extra = 1` (game.lua:396).
- 触发条件: `context.repetition` 且 `context.cardarea == G.play`, 且 `G.GAME.current_round.hands_left == 0` (本回合最后一次出牌).
- 返回: `{message = k_again_ex, repetitions = self.ability.extra, card = self}`.

### 3.4 汽水 / Seltzer (`j_selzer`)

- 源码: 第 3367-3373 行. `extra = 10` (game.lua:475), 该 center 的 `eternal_compat = false`.
- 触发条件: `context.repetition` 且 `context.cardarea == G.play`. 无其它条件.
- 返回: `{message = k_again_ex, repetitions = 1, card = self}`. 固定 1 次, 不读 `extra`; `extra` 是"剩余可用次数", 每回合结束递减, 见 4.4.
- 备注: 每张计分牌都会各触发一次, 所以是多张牌时对每张牌各加一次重复.

### 3.5 烂脱口秀演员 / Hack (`j_hack`)

- 源码: 第 3374-3384 行. `extra = 1` (game.lua:405).
- 触发条件: `context.repetition` 且 `context.cardarea == G.play`, 且 `context.other_card:get_id()` 属于 `{2, 3, 4, 5}`.
- 返回: `{message = k_again_ex, repetitions = self.ability.extra, card = self}`.

### 3.6 哑剧演员 / Mime (`j_mime`)

- 源码: 第 3387-3393 行. `extra = 1` (game.lua:387).
- 触发条件: `context.repetition` 且 `context.cardarea == G.hand`, 且 `next(context.card_effects[1]) or #context.card_effects > 1`. `context.card_effects` 是这张手牌本次已经收集到的效果列表 (含该牌自身的强化/贴纸效果), 因此"手牌有实效"时才触发.
- 返回: `{message = k_again_ex, repetitions = self.ability.extra, card = self}`.
- 备注: 哑剧演员让手里的牌重复结算; 只作用于留在手里的牌, 不作用于打出的牌.

## 4. C 类: context.other_joker (小丑对小丑)

入口: `state_events.lua:920`, 在每张小丑自身主效果结算之后, 用其它小丑对它结算.

### 4.1 棒球卡 / Baseball Card (`j_baseball`)

- 源码: 第 3397-3408 行. `extra = 1.5` (game.lua:465).
- 触发条件: `context.other_joker` 且 `context.other_joker.config.center.rarity == 2` (罕见 Uncommon) 且 `self ~= context.other_joker`.
- 返回: `{message = a_xmult(self.ability.extra), Xmult_mod = self.ability.extra}`. 注意没有 `card` 字段.
- 副作用: 返回前 AddEvent 对 `context.other_joker:juice_up(0.5, 0.5)`.
- 读状态: `context.other_joker.config.center.rarity`.
- 备注: 只对罕见稀有度的小丑生效, 其它稀有度不返回任何值.

## 5. D 类: 主效果 (else 分支, context.cardarea == G.jokers)

### 5.1 D1: context.before (打出牌型确定后, 计分前)

这些分支只在 `context.before == true` 时评估 (`state_events.lua:630`), 通常只改自身状态并返回飘字, 不加成本轮数值.

#### 5.1.1 备用裤子 / Spare Trousers (`j_trousers`)

- 源码: 第 3412-3419 行. `extra = 2` (game.lua:471).
- 触发条件: `context.before`, 且 (`next(context.poker_hands['Two Pair'])` 或 `next(context.poker_hands['Full House'])`), 且 `not context.blueprint`.
- 返回: `{message = k_upgrade_ex, colour = G.C.RED, card = self}`.
- 副作用: `self.ability.mult = self.ability.mult + self.ability.extra` (永久成长).
- 读状态: `context.poker_hands`.
- 备注: 成长值在默认分支以 `mult_mod = self.ability.mult` 回收 (见 5.3.29).

#### 5.1.2 太空小丑 / Space Joker (`j_space`)

- 源码: 第 3420-3426 行. `extra = 4` (game.lua:414).
- 触发条件: `context.before`, 且 `pseudorandom('space') < G.GAME.probabilities.normal / self.ability.extra`. 不检查蓝图 (蓝图复制会再次独立掷骰).
- 返回: `{card = self, level_up = true, message = k_level_up_ex}`.
- 副作用: `level_up` 由 `state_events.lua:634-636` 触发 `level_up_hand(持有者小丑, 当前牌型)`, 即当前牌型等级 +1.
- 读状态: `G.GAME.probabilities.normal`.

#### 5.1.3 方形小丑 / Square Joker (`j_square`)

- 源码: 第 3427-3434 行. `extra = {chips = 0, chip_mod = 4}` (game.lua:436).
- 触发条件: `context.before`, 且 `#context.full_hand == 4` (打出的牌正好 4 张, 注意是 `full_hand` 不是 `scoring_hand`), 且 `not context.blueprint`.
- 返回: `{message = k_upgrade_ex, colour = G.C.CHIPS, card = self}`.
- 副作用: `self.ability.extra.chips = self.ability.extra.chips + self.ability.extra.chip_mod`.
- 备注: 筹码值在默认分支以 `chip_mod = self.ability.extra.chips` 回收 (5.3.23).

#### 5.1.4 跑步选手 / Runner (`j_runner`)

- 源码: 第 3435-3442 行. `extra = {chips = 0, chip_mod = 15}` (game.lua:419).
- 触发条件: `context.before`, 且 `next(context.poker_hands['Straight'])` (打出顺子, 含同花顺与皇家同花顺), 且 `not context.blueprint`.
- 返回: `{message = k_upgrade_ex, colour = G.C.CHIPS, card = self}`.
- 副作用: `self.ability.extra.chips += self.ability.extra.chip_mod`.
- 备注: 以 `chip_mod = self.ability.extra.chips` 回收 (5.3.24).

#### 5.1.5 迈达斯面具 / Midas Mask (`j_midas_mask`)

- 源码: 第 3443-3464 行. 无 `config.extra` (game.lua:447), `blueprint_compat = false`.
- 触发条件: `context.before` 且 `not context.blueprint`.
- 行为: 遍历 `context.scoring_hand`, 对每张 `is_face()` 的牌做 `v:set_ability(G.P_CENTERS.m_gold, nil, true)` (变成金色强化牌), 并 AddEvent 让它 `juice_up()`. 收集到 `faces` 列表.
- 返回: `#faces > 0` 时返回 `{message = k_gold, colour = G.C.MONEY, card = self}`; 否则无返回.
- 副作用: 修改计分牌的强化 (实时生效, 影响本轮后续打分的金色效果), 播动画.
- 读状态: `context.scoring_hand`, `G.P_CENTERS.m_gold`.

#### 5.1.6 吸血鬼 / Vampire (`j_vampire`)

- 源码: 第 3465-3490 行. `extra = 0.1, Xmult = 1` (game.lua:439).
- 触发条件: `context.before` 且 `not context.blueprint`.
- 行为: 遍历 `context.scoring_hand`, 对满足 `v.config.center ~= G.P_CENTERS.c_base` 且 `not v.debuff` 且 `not v.vampired` 的牌, 置 `v.vampired = true`, 执行 `v:set_ability(G.P_CENTERS.c_base, nil, true)` (移除强化), 并 AddEvent 先 `juice_up()` 再清掉 `v.vampired`. 收集到 `enhanced` 列表.
- 返回: `#enhanced > 0` 时先 `self.ability.x_mult = self.ability.x_mult + self.ability.extra * #enhanced`, 再返回 `{message = a_xmult(self.ability.x_mult), colour = G.C.MULT, card = self}`; 否则无返回.
- 读状态: `context.scoring_hand` 每张的 `config.center`, `debuff`, `vampired`; `G.P_CENTERS.c_base`.
- 副作用: 移除打出牌的强化, 播动画, 自身 `x_mult` 成长.
- 备注: 自身 `x_mult` 通过通用规则 1 (3653 行) 在本轮 `Xmult_mod` 结算.

#### 5.1.7 待办清单 / To Do List (`j_todo_list`)

- 源码: 第 3491-3500 行. `extra = {dollars = 4, poker_hand = 'High Card'}` (game.lua:430).
- 触发条件: `context.before`, 且 `context.scoring_name == self.ability.to_do_poker_hand`.
- 返回: `{message = localize('$')..self.ability.extra.dollars, dollars = self.ability.extra.dollars, colour = G.C.MONEY}`. 没有 `card` 字段.
- 副作用: 先执行 `ease_dollars(self.ability.extra.dollars)` (真加钱), 再 `G.GAME.dollar_buffer += self.ability.extra.dollars` 并 AddEvent 归零.
- 读状态: `self.ability.to_do_poker_hand` 由 `Card:set_ability` 第 311-323 行初始化, 在可见牌型里随机选一个, 且保证与上一次不同; `self.ability.extra.poker_hand` 只是原型里的初始手牌名.
- 备注: 触发后 `to_do_poker_hand` 的重新抽取在别处 (每次触发后刷新), 本函数不负责.

#### 5.1.8 DNA (`j_dna`)

- 源码: 第 3501-3524 行. 无 `config.extra` (game.lua:421).
- 触发条件: `context.before`, 且 `G.GAME.current_round.hands_played == 0` (本回合第一次出牌), 且 `#context.full_hand == 1` (只打出 1 张牌). 不检查蓝图.
- 行为: `G.playing_card = (G.playing_card or 0) + 1`; `local _card = copy_card(context.full_hand[1], nil, nil, G.playing_card)`; `_card:add_to_deck()`; `G.deck.config.card_limit += 1`; `table.insert(G.playing_cards, _card)`; `G.hand:emplace(_card)`; `_card.states.visible = nil`; AddEvent 里 `_card:start_materialize()`.
- 返回: `{message = k_copied_ex, colour = G.C.CHIPS, card = self, playing_cards_created = {true}}`.
- 读状态: `G.GAME.current_round.hands_played`, `context.full_hand`, `G.playing_card`.
- 副作用: 复制牌, 加入手牌与牌组, 改牌组上限, 动画.

#### 5.1.9 搭乘巴士 / Ride the Bus (`j_ride_the_bus`)

- 源码: 第 3525-3542 行. `extra = 1` (game.lua:413).
- 触发条件: `context.before` 且 `not context.blueprint`.
- 行为: 扫描 `context.scoring_hand`, 只要有一张 `is_face()` 就置 `faces = true`.
  - 若 `faces`, 记 `last_mult = self.ability.mult`, 然后 `self.ability.mult = 0`; 若 `last_mult > 0` 则返回 `{card = self, message = k_reset}`.
  - 若没有面牌, `self.ability.mult += self.ability.extra`.
- 返回: 只在"有面牌且此前 mult 大于 0"时返回 reset 提示; 成长时不返回 (本轮数值由后续默认分支给出).
- 备注: 数值回收见 5.3.27.

#### 5.1.10 方尖石塔 / Obelisk (`j_obelisk`)

- 源码: 第 3543-3562 行. `extra = 0.2, Xmult = 1` (game.lua:446).
- 触发条件: `context.before` 且 `not context.blueprint`.
- 行为: `local play_more_than = G.GAME.hands[context.scoring_name].played or 0`; 遍历 `G.GAME.hands`, 若存在 `k ~= context.scoring_name` 且 `v.played >= play_more_than` 且 `v.visible` 的牌型, 则 `reset = false`.
  - `reset` 为真: 若 `self.ability.x_mult > 1`, 置 `self.ability.x_mult = 1` 并返回 `{card = self, message = k_reset}`.
  - 否则 `self.ability.x_mult += self.ability.extra`.
- 读状态: `G.GAME.hands` (全部牌型的 `played` 与 `visible`).
- 备注: 数值回收见通用规则 1, 以及 5.3.32 的专有分支.

#### 5.1.11 绿色小丑 / Green Joker (`j_green_joker`)

- 源码: 第 3563-3569 行. `extra = {hand_add = 1, discard_sub = 1}` (game.lua:428).
- 触发条件: `context.before` 且 `not context.blueprint`.
- 副作用: `self.ability.mult += self.ability.extra.hand_add`.
- 返回: `{card = self, message = a_mult(self.ability.extra.hand_add)}`. 只显示本回合增量, 不加成本轮数值.
- 备注: `discard_sub` 在 `context.discard` 分支使用 (属于第一段范围); 数值回收见 5.3.28.

### 5.2 D2: context.after (本轮计分结束后)

#### 5.2.1 冰淇淋 / Ice Cream (`j_ice_cream`)

- 源码: 第 3571-3599 行. `extra = {chips = 100, chip_mod = 5}` (game.lua:420), `eternal_compat = false`.
- 触发条件: `context.after` 且 `not context.blueprint`.
- 行为:
  - 若 `self.ability.extra.chips - self.ability.extra.chip_mod <= 0`: AddEvent 播放 `tarot1` 音效, 设置 `self.T.r = -0.2`, `self:juice_up(0.3, 0.4)`, `self.states.drag.is = true`, `self.children.center.pinch.x = true`, 再 AddEvent (`trigger = 'after', delay = 0.3, blockable = false`) 执行 `G.jokers:remove_card(self)`, `self:remove()`, `self = nil`. 然后返回 `{message = k_melted_ex, colour = G.C.CHIPS}`.
  - 否则 `self.ability.extra.chips -= self.ability.extra.chip_mod`, 返回 `{message = a_chips_minus(self.ability.extra.chip_mod), colour = G.C.CHIPS}`.
- 副作用: 每回合融化 5 点; 归零时自毁.
- 备注: 当前筹码值在默认分支以 `chip_mod = self.ability.extra.chips` 回收 (5.3.25).

#### 5.2.2 汽水 / Seltzer (`j_selzer`)

- 源码: 第 3601-3630 行. `extra = 10` (game.lua:475), `eternal_compat = false`.
- 触发条件: `context.after` 且 `not context.blueprint`.
- 行为:
  - 若 `self.ability.extra - 1 <= 0`: AddEvent 播放 `tarot1`, `self.T.r = -0.2`, `self:juice_up(0.3, 0.4)`, `self.states.drag.is = true`, `self.children.center.pinch.x = true`, 再 AddEvent (`trigger = 'after', delay = 0.3, blockable = false`) 执行 `G.jokers:remove_card(self)`, `self:remove()`, `self = nil`. 返回 `{message = k_drank_ex, colour = G.C.FILTER}`.
  - 否则 `self.ability.extra -= 1`, 返回 `{message = self.ability.extra..'', colour = G.C.FILTER}` (显示剩余次数).
- 备注: `extra` 就是剩余回合数, 与 3.4 的重复触发共用.

### 5.3 D3: 默认分支 (普通出牌结算)

分支位置: 第 3631 行起 `else`, 到第 4058 行. 这些分支只处理 `context.cardarea == G.jokers` 且既非 `before` 也非 `after` 的调用 (`state_events.lua:905`).

#### 5.3.1 积分卡 / Loyalty Card (`j_loyalty_card`)

- 源码: 第 3632-3652 行. `extra = {Xmult = 4, every = 5, remaining = "5 remaining"}` (game.lua:393).
- 触发条件: `context.cardarea == G.jokers` 默认分支, 且 `self.ability.name == 'Loyalty Card'`.
- 行为: 每次都先重算进度:
  `self.ability.loyalty_remaining = (self.ability.extra.every - 1 - (G.GAME.hands_played - self.ability.hands_played_at_create)) % (self.ability.extra.every + 1)`.
  - 若 `context.blueprint`: 只有在 `self.ability.loyalty_remaining == self.ability.extra.every` 时返回 `{message = a_xmult(self.ability.extra.Xmult), Xmult_mod = self.ability.extra.Xmult}`.
  - 否则 (非蓝图): 若 `loyalty_remaining == 0`, 用 `local eval = function(card) return (card.ability.loyalty_remaining == 0) end` 调 `juice_card_until(self, eval, true)` (只做动画提示, 不返回); 否则若 `loyalty_remaining == self.ability.extra.every`, 返回 `{message = a_xmult(self.ability.extra.Xmult), Xmult_mod = self.ability.extra.Xmult}`.
- 读状态: `G.GAME.hands_played`, `self.ability.hands_played_at_create` (在 `set_ability` 第 337 行记录), `self.ability.extra.every` / `Xmult`.
- 备注: `hands_played_at_create` 是创建时的手数, 所以进度按"第 5n 次出牌"触发 (剩余 0 表示下一次出牌生效, 因此 `remaining == 0` 时只提示). 蓝图走的是同一段重算逻辑, 但把 `remaining == 0` 归入触发条件.

#### 5.3.2 半张小丑 / Half Joker (`j_half`)

- 源码: 第 3672-3677 行. `extra = {mult = 20, size = 3}` (game.lua:383).
- 触发条件: 默认分支, 且 `#context.full_hand <= self.ability.extra.size` (打出的牌数 <= 3).
- 返回: `{message = a_mult(self.ability.extra.mult), mult_mod = self.ability.extra.mult}`.

#### 5.3.3 抽象小丑 / Abstract Joker (`j_abstract`)

- 源码: 第 3678-3687 行. `extra = 3` (game.lua:403).
- 触发条件: 默认分支.
- 行为: `x = 0`; 遍历 `G.jokers.cards`, 若 `G.jokers.cards[i].ability.set == 'Joker'` 则 `x += 1`.
- 返回: `{message = a_mult(x * self.ability.extra), mult_mod = x * self.ability.extra}`.
- 读状态: `G.jokers.cards` 每张的 `ability.set`.

#### 5.3.4 杂技演员 / Acrobat (`j_acrobat`)

- 源码: 第 3688-3693 行. `extra = 3` (game.lua:482).
- 触发条件: 默认分支, 且 `G.GAME.current_round.hands_left == 0`.
- 返回: `{message = a_xmult(self.ability.extra), Xmult_mod = self.ability.extra}`.

#### 5.3.5 神秘之峰 / Mystic Summit (`j_mystic_summit`)

- 源码: 第 3694-3699 行. `extra = {mult = 15, d_remaining = 0}` (game.lua:391).
- 触发条件: 默认分支, 且 `G.GAME.current_round.discards_left == self.ability.extra.d_remaining` (剩余弃牌数等于 0).
- 返回: `{message = a_mult(self.ability.extra.mult), mult_mod = self.ability.extra.mult}`.

#### 5.3.6 印错小丑 / Misprint (`j_misprint`)

- 源码: 第 3700-3706 行. `extra = {min = 0, max = 23}` (game.lua:395).
- 触发条件: 默认分支.
- 行为: `temp_Mult = pseudorandom('misprint', self.ability.extra.min, self.ability.extra.max)`.
- 返回: `{message = a_mult(temp_Mult), mult_mod = temp_Mult}`.
- 备注: 随机种子固定为字符串 `'misprint'`, 后两个参数是上下界.

#### 5.3.7 旗帜 / Banner (`j_banner`)

- 源码: 第 3707-3712 行. `extra = 30` (game.lua:390).
- 触发条件: 默认分支, 且 `G.GAME.current_round.discards_left > 0`.
- 返回: `{message = a_chips(G.GAME.current_round.discards_left * self.ability.extra), chip_mod = G.GAME.current_round.discards_left * self.ability.extra}`.

#### 5.3.8 特技演员 / Stuntman (`j_stuntman`)

- 源码: 第 3713-3718 行. `extra = {h_size = 2, chip_mod = 250}` (game.lua:511).
- 触发条件: 默认分支. 手牌上限 -2 的效果不在这里 (在 `Card:calc_hand_size` 附近, 第 684 行).
- 返回: `{message = a_chips(self.ability.extra.chip_mod), chip_mod = self.ability.extra.chip_mod}`.

#### 5.3.9 斗牛士 / Matador (`j_matador`)

- 源码: 第 3719-3730 行. `extra = 8` (game.lua:504).
- 触发条件: 默认分支, 且 `G.GAME.blind.triggered` (本次出牌触发了 Boss 盲注的限制, 由计分流程在牌被 debuff 时置位).
- 行为: `ease_dollars(self.ability.extra)`; `G.GAME.dollar_buffer += self.ability.extra`; AddEvent 把 `dollar_buffer` 归零.
- 返回: `{message = localize('$')..self.ability.extra, dollars = self.ability.extra, colour = G.C.MONEY}`.
- 备注: 与本段其它加钱的写法不同: 这里直接调了 `ease_dollars`, 同时又设置 `dollars`, 因此实际加钱动作由 `ease_dollars` 完成.

#### 5.3.10 超新星 / Supernova (`j_supernova`)

- 源码: 第 3731-3736 行. `extra = 1` (game.lua:412).
- 触发条件: 默认分支.
- 返回: `{message = a_mult(G.GAME.hands[context.scoring_name].played), mult_mod = G.GAME.hands[context.scoring_name].played}` (该牌型历史总打出次数).
- 读状态: `G.GAME.hands[context.scoring_name].played`, `context.scoring_name`.

#### 5.3.11 仪式匕首 / Ceremonial Dagger (`j_ceremonial`)

- 源码: 第 3737-3742 行 (回收分支) 与 5.1 区之外的另一处 (第 2561-2579 行, `context.setting_blind`, 属于第一段).
- 触发条件: 默认分支, 且 `self.ability.mult > 0`.
- 返回: `{message = a_mult(self.ability.mult), mult_mod = self.ability.mult}`.
- 读状态: `self.ability.mult` (由 `context.setting_blind` 里吃掉右侧小丑获得, 见第一段).
- 备注: 原型 `config = {mult = 0}` (game.lua:389).

#### 5.3.12 流浪者 / Vagabond (`j_vagabond`)

- 源码: 第 3743-3761 行. `extra = 4` (game.lua:442).
- 触发条件: 默认分支, 且 `#G.consumeables.cards + G.GAME.consumeable_buffer < G.consumeables.config.card_limit`, 且 `G.GAME.dollars <= self.ability.extra`.
- 行为: `G.GAME.consumeable_buffer += 1`; AddEvent 生成 `'Tarot'` 消耗牌: `create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, 'vag')`, `card:add_to_deck()`, `G.consumeables:emplace(card)`, `G.GAME.consumeable_buffer = 0`.
- 返回: `{message = k_plus_tarot, card = self}`.
- 类别: 小丑; 产物为 Tarot.

#### 5.3.13 叠加态 / Superposition (`j_superposition`)

- 源码: 第 3762-3786 行. 无 `config.extra` (game.lua:429).
- 触发条件: 默认分支, 且 `#G.consumeables.cards + G.GAME.consumeable_buffer < G.consumeables.config.card_limit`, 且 `context.scoring_hand` 里 `get_id() == 14` 的牌数 `aces >= 1`, 且 `next(context.poker_hands["Straight"])`.
- 行为: `G.GAME.consumeable_buffer += 1`; AddEvent 生成 `'Tarot'` (`create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, 'sup')`), 加牌, 归零 buffer.
- 返回: `{message = k_plus_tarot, colour = G.C.SECONDARY_SET.Tarot, card = self}`.

#### 5.3.14 通灵 / Seance (`j_seance`)

- 源码: 第 3787-3806 行. `extra = {poker_hand = 'Straight Flush'}` (game.lua:437).
- 触发条件: 默认分支, 且消耗牌未满, 且 `next(context.poker_hands[self.ability.extra.poker_hand])`.
- 行为: AddEvent 生成 `'Spectral'` 消耗牌 (`create_card('Spectral', G.consumeables, nil, nil, nil, nil, nil, 'sea')`), 加牌, buffer 归零; 前一步先 `consumeable_buffer += 1`.
- 返回: `{message = k_plus_spectral, colour = G.C.SECONDARY_SET.Spectral, card = self}`.
- 类别: 小丑; 产物为 Spectral (幻灵).

#### 5.3.15 花盆 / Flower Pot (`j_flower_pot`)

- 源码: 第 3807-3839 行. `extra = 3` (game.lua:497).
- 触发条件: 默认分支, 且 `context.scoring_hand` 同时包含四种花色各至少一张.
- 两遍扫描的细节 (必须照抄):
  - 第一遍 (3814-3821): 只处理 `ability.name ~= 'Wild Card'` 的牌, 依次判 `is_suit('Hearts', true)`, `'Diamonds', true`, `'Spades', true`, `'Clubs', true`, 且只在该花色计数为 0 时加 1. 由于是 `if/elseif` 链, 一张牌最多只贡献一种花色.
  - 第二遍 (3822-3829): 只处理 `ability.name == 'Wild Card'` 的牌, 同样的 `if/elseif` 结构与 `== 0` 条件, 但调用 `is_suit(suit)` (不带 `bypass_debuff` 参数).
- 返回: 四花色都大于 0 时 `{message = a_xmult(self.ability.extra), Xmult_mod = self.ability.extra}`.
- 读状态: `context.scoring_hand`, `G.C` 无, `ability.name == 'Wild Card'`.

#### 5.3.16 重影 / Seeing Double (`j_seeing_double`)

- 源码: 第 3840-3872 行. `extra = 2` (game.lua:503).
- 触发条件: 默认分支, 且 (红桃或方块或黑桃计数大于 0) 且 梅花计数大于 0.
- 扫描细节:
  - 第一遍 (3847-3854): 非 Wild Card 的牌, 用四个独立 `if` 判 `is_suit('Hearts')`, `'Diamonds'`, `'Spades'`, `'Clubs'`, 累加计数 (同一张牌可以同时命中多种花色, 例如被花色转换的牌).
  - 第二遍 (3855-3862): Wild Card 的牌, 用 `if/elseif` 链并且只在计数为 0 时加 1, 顺序为 Clubs, Diamonds, Spades, Hearts.
- 返回: 条件满足时 `{message = a_xmult(self.ability.extra), Xmult_mod = self.ability.extra}`.
- 备注: 该小丑被通用规则 1 显式排除 (`self.ability.name ~= 'Seeing Double'`), 避免与自身的 `x_mult` 冲突.

#### 5.3.17 小小丑 / Wee Joker (`j_wee`)

- 源码: 第 3873-3878 行. `extra = {chips = 0, chip_mod = 8}` (game.lua:499).
- 触发条件: 默认分支. 成长在 `context.individual` (第 3083-3092 行): 当 `context.cardarea == G.play` 且 `context.other_card:get_id() == 2` 且 `not context.blueprint` 时, `self.ability.extra.chips += self.ability.extra.chip_mod`, 并返回 `{extra = {focus = self, message = k_upgrade_ex}, card = self, colour = G.C.CHIPS}` (只飘字, 不加成本轮数值).
- 返回: `{message = a_chips(self.ability.extra.chips), chip_mod = self.ability.extra.chips, colour = G.C.CHIPS}`.

#### 5.3.18 城堡 / Castle (`j_castle`)

- 源码: 第 3880-3885 行. `extra = {chips = 0, chip_mod = 3}` (game.lua:476).
- 触发条件: 默认分支, 且 `self.ability.extra.chips > 0`.
- 返回: `{message = a_chips(self.ability.extra.chips), chip_mod = self.ability.extra.chips, colour = G.C.CHIPS}`.
- 备注: 成长在 `context.discard` 分支 (第一段), 不是本函数本段.

#### 5.3.19 蓝色小丑 / Blue Joker (`j_blue_joker`)

- 源码: 第 3887-3892 行. `extra = 2` (game.lua:423).
- 触发条件: 默认分支, 且 `#G.deck.cards > 0`.
- 返回: `{message = a_chips(self.ability.extra * #G.deck.cards), chip_mod = self.ability.extra * #G.deck.cards, colour = G.C.CHIPS}`.
- 读状态: `G.deck.cards` 数量 (注意只数牌库, 不含手牌与已打出的牌).

#### 5.3.20 侵蚀 / Erosion (`j_erosion`)

- 源码: 第 3894-3899 行. `extra = 4` (game.lua:453).
- 触发条件: 默认分支, 且 `(G.GAME.starting_deck_size - #G.playing_cards) > 0`.
- 返回: `{message = a_mult(self.ability.extra * (G.GAME.starting_deck_size - #G.playing_cards)), mult_mod = self.ability.extra * (G.GAME.starting_deck_size - #G.playing_cards), colour = G.C.MULT}`.
- 读状态: `G.GAME.starting_deck_size`, `#G.playing_cards`.

#### 5.3.21 石头小丑 / Stone Joker (`j_stone`)

- 源码: 第 3922-3927 行. `extra = 25` (game.lua:461).
- 触发条件: 默认分支, 且 `self.ability.stone_tally > 0`.
- 返回: `{message = a_chips(self.ability.extra * self.ability.stone_tally), chip_mod = self.ability.extra * self.ability.stone_tally, colour = G.C.CHIPS}`.
- 读状态: `self.ability.stone_tally` (整副牌里石头牌的数量, 由别处维护).

#### 5.3.22 钢铁小丑 / Steel Joker (`j_steel_joker`)

- 源码: 第 3929-3934 行. `extra = 0.2` (game.lua:401).
- 触发条件: 默认分支, 且 `self.ability.steel_tally > 0`.
- 返回: `{message = a_xmult(1 + self.ability.extra * self.ability.steel_tally), Xmult_mod = 1 + self.ability.extra * self.ability.steel_tally, colour = G.C.MULT}`.

#### 5.3.23 斗牛 / Bull (`j_bull`)

- 源码: 第 3936-3941 行. `extra = 2` (game.lua:466).
- 触发条件: 默认分支, 且 `(G.GAME.dollars + (G.GAME.dollar_buffer or 0)) > 0`.
- 返回: `{message = a_chips(self.ability.extra * math.max(0, G.GAME.dollars + (G.GAME.dollar_buffer or 0))), chip_mod = self.ability.extra * math.max(0, G.GAME.dollars + (G.GAME.dollar_buffer or 0)), colour = G.C.CHIPS}`.

#### 5.3.24 驾驶执照 / Driver's License (`j_drivers_license`)

- 源码: 第 3943-3950 行. `extra = {count = 16, tally = 'total'}` (game.lua:517).
- 触发条件: 默认分支, 且 `(self.ability.driver_tally or 0) >= 16`.
- 返回: `{message = a_xmult(self.ability.extra), Xmult_mod = self.ability.extra}`. 数值取 `extra` 表本身 (Lua 表转字符串), 原型里 `extra` 被改成标量 3, 所以显示 X3.
- 备注: `driver_tally` 由别处维护, 统计当前增强牌数量.

#### 5.3.25 黑板 / Blackboard (`j_blackboard`)

- 源码: 第 3951-3965 行. `extra = 3` (game.lua:418).
- 触发条件: 默认分支, 且 `G.hand.cards` 里**所有**牌都是 Clubs 或 Spades.
- 细节: 遍历 `G.hand.cards`, `all_cards += 1`; 若 `v:is_suit('Clubs', nil, true) or v:is_suit('Spades', nil, true)` 则 `black_suits += 1`. 条件 `black_suits == all_cards`. 注意第三个参数 `flush_calc = true`, 因此石头牌 (`ability.effect == 'Stone Card'`) 在 `is_suit` 里恒为 false (见第 4064-4069 行), 会破坏条件.
- 返回: `{message = a_xmult(self.ability.extra), Xmult_mod = self.ability.extra}`.
- 读状态: `G.hand.cards` 全部 (包括不参与牌型的牌).

#### 5.3.26 小丑模板 / Joker Stencil (`j_stencil`)

- 源码: 第 3966-3972 行. 无 `config.extra`, 初始 `x_mult = 1` (game.lua:385).
- 触发条件: 默认分支, 且 `(G.jokers.config.card_limit - #G.jokers.cards) > 0` (有空的小丑槽位).
- 返回: `{message = a_xmult(self.ability.x_mult), Xmult_mod = self.ability.x_mult}`.
- 读状态: `G.jokers.config.card_limit`, `#G.jokers.cards`, `self.ability.x_mult`. 注意 `x_mult` 是通过通用规则 1 被排除的 (因为 `x_mult > 1` 且 `type == ''`), 所以这里的专有分支负责回收.
- 备注: `self.ability.x_mult` 在 `Card:update` 每帧维护为 `G.jokers.config.card_limit - #G.jokers.cards` (第 4203-4205 行), 实现时不能漏掉这个被动值.

#### 5.3.27 侠盗 / Swashbuckler (`j_swashbuckler`)

- 源码: 第 3974-3978 行. `config = {mult = 1}` (game.lua:484).
- 触发条件: 默认分支, 且 `self.ability.mult > 0`.
- 返回: `{message = a_mult(self.ability.mult), mult_mod = self.ability.mult}`.
- 读状态: `self.ability.mult` (其它小丑 `mult` 之和, 由别处维护).

#### 5.3.28 小丑 / Joker (`j_joker`)

- 源码: 第 3980-3984 行. `config = {mult = 4}` (game.lua:368).
- 触发条件: 默认分支. 无额外条件.
- 返回: `{message = a_mult(self.ability.mult), mult_mod = self.ability.mult}`.

#### 5.3.29 备用裤子 / Spare Trousers (`j_trousers`) 回收分支

- 源码: 第 3986-3990 行. `extra = 2` (game.lua:471).
- 触发条件: 默认分支, 且 `self.ability.mult > 0`.
- 返回: `{message = a_mult(self.ability.mult), mult_mod = self.ability.mult}`.
- 备注: 成长见 5.1.1.

#### 5.3.30 搭乘巴士 / Ride the Bus (`j_ride_the_bus`) 回收分支

- 源码: 第 3992-3996 行. `extra = 1` (game.lua:413).
- 触发条件: 默认分支, 且 `self.ability.mult > 0`.
- 返回: `{message = a_mult(self.ability.mult), mult_mod = self.ability.mult}`.

#### 5.3.31 闪示卡 / Flash Card (`j_flash`)

- 源码: 第 3998-4002 行. `extra = 2, mult = 0` (game.lua:469).
- 触发条件: 默认分支, 且 `self.ability.mult > 0`.
- 返回: `{message = a_mult(self.ability.mult), mult_mod = self.ability.mult}`.
- 备注: 成长在 `context.reroll_shop` 分支 (第一段, 第 2403-2410 行), 每次商店重掷 +2.

#### 5.3.32 爆米花 / Popcorn (`j_popcorn`)

- 源码: 第 4004-4008 行. `mult = 20, extra = 4` (game.lua:470).
- 触发条件: 默认分支, 且 `self.ability.mult > 0`.
- 返回: `{message = a_mult(self.ability.mult), mult_mod = self.ability.mult}`.
- 备注: 每回合结束减 4 倍率的行为在 `context.ending_shop` 或回合结束逻辑 (第一段, 第 2412 行起), 本函数本段只做回收.

#### 5.3.33 绿色小丑 / Green Joker (`j_green_joker`) 回收分支

- 源码: 第 4010-4014 行. `extra = {hand_add = 1, discard_sub = 1}` (game.lua:428).
- 触发条件: 默认分支, 且 `self.ability.mult > 0`.
- 返回: `{message = a_mult(self.ability.mult), mult_mod = self.ability.mult}`.

#### 5.3.34 占卜师 / Fortune Teller (`j_fortune_teller`)

- 源码: 第 4016-4021 行. `extra = 1` (game.lua:458).
- 触发条件: 默认分支, 且 `G.GAME.consumeable_usage_total` 存在, 且 `G.GAME.consumeable_usage_total.tarot > 0`.
- 返回: `{message = a_mult(G.GAME.consumeable_usage_total.tarot), mult_mod = G.GAME.consumeable_usage_total.tarot}`.
- 读状态: `G.GAME.consumeable_usage_total.tarot` (本局使用过的塔罗总数, 由 `set_consumeable_usage` 维护).
- 备注: `self.ability.extra` 在显示里用, 计算里不用.

#### 5.3.35 大麦克香蕉 / Gros Michel (`j_gros_michel`)

- 源码: 第 4022-4027 行. `extra = {odds = 6, mult = 15}` (game.lua:407).
- 触发条件: 默认分支. 无额外条件 (即使 `mult` 为 0 也返回).
- 返回: `{message = a_mult(self.ability.extra.mult), mult_mod = self.ability.extra.mult}`.
- 备注: 消失概率 (`odds = 6`) 的判定在回合结束时 (第一段或 `get_end_of_round_effect` 之外的逻辑).

#### 5.3.36 卡文迪什 / Cavendish (`j_cavendish`)

- 源码: 第 4028-4033 行. `extra = {odds = 1000, Xmult = 3}` (game.lua:431).
- 触发条件: 默认分支. 无额外条件.
- 返回: `{message = a_xmult(self.ability.extra.Xmult), Xmult_mod = self.ability.extra.Xmult}`.

#### 5.3.37 红牌 / Red Card (`j_red_card`)

- 源码: 第 4034-4039 行. `extra = 2, mult = 0` (game.lua:433).
- 触发条件: 默认分支, 且 `self.ability.mult > 0`.
- 返回: `{message = a_mult(self.ability.mult), mult_mod = self.ability.mult}`.
- 备注: 成长在 `context.skipping_booster` (第一段, 第 2441-2455 行).

#### 5.3.38 老千小丑 / Card Sharp (`j_card_sharp`)

- 源码: 第 4040-4045 行. `extra = {Xmult = 3}` (game.lua:433).
- 触发条件: 默认分支, 且 `G.GAME.hands[context.scoring_name]` 存在, 且 `G.GAME.hands[context.scoring_name].played_this_round > 1` (本回合这个牌型已经打过一次以上).
- 备注: `extra = {Xmult = 3}` (game.lua:433, `j_card_sharp`).
- 返回: `{message = a_xmult(self.ability.extra.Xmult), Xmult_mod = self.ability.extra.Xmult}`.

#### 5.3.39 提靴带 / Bootstraps (`j_bootstraps`)

- 源码: 第 4046-4051 行. `extra = {mult = 2, dollars = 5}` (game.lua:521).
- 触发条件: 默认分支, 且 `math.floor((G.GAME.dollars + (G.GAME.dollar_buffer or 0)) / self.ability.extra.dollars) >= 1` (每满 $5 算一份).
- 返回: `{message = a_mult(self.ability.extra.mult * math.floor((G.GAME.dollars + (G.GAME.dollar_buffer or 0)) / self.ability.extra.dollars)), mult_mod = self.ability.extra.mult * math.floor((G.GAME.dollars + (G.GAME.dollar_buffer or 0)) / self.ability.extra.dollars)}`.
- 读状态: `G.GAME.dollars`, `G.GAME.dollar_buffer`.

#### 5.3.40 卡尼奥 / Caino (`j_caino`)

- 源码: 第 4052-4057 行 (回收分支). `extra = 1` (game.lua:522).
- 触发条件: 默认分支, 且 `self.ability.caino_xmult > 1`.
- 返回: `{message = a_xmult(self.ability.caino_xmult), Xmult_mod = self.ability.caino_xmult}`.
- 读状态: `self.ability.caino_xmult` (在 `Card:set_ability` 第 324-326 行初始化为 1; 成长在 `context.cards_destroyed` 与 `context.remove_playing_cards` 分支, 属于第一段, 第 2623-2707 行).
- 备注: 该小丑的 `self.ability.x_mult` 恒为 1, 所以通用规则 1 不会命中.

## 6. 跨段补充: 这些效果在别处的分支

以下条目在本段之外还有判定, 实现时需要一并看, 但细节不在此文档展开:

- `Card:calculate_seal` (第 2242 行起): 红封贴纸的重复, 与 `context.repetition` / `repetition_only` 配合.
- `Card:get_end_of_round_effect` (第 1033 行起): 蓝封 (月亮) 生成 Planet, `h_dollars`.
- `Card:get_p_dollars` (第 1068 行起): 金封, 幸运牌.
- `Card:set_ability` (第 277-338 行): `to_do_poker_hand` 抽取, `caino_xmult` 初始化, `loyalty_remaining` / `hands_played_at_create` 初始化, `yorick_discards` 初始化.
- `Card:calculate_joker` 第一段 (第 2291-3064 行): `joker_main` 里的第一波 (含 `Xmult_mod` 之类), `open_booster`, `buying_card`, `selling_self`, `selling_card`, `reroll_shop`, `ending_shop`, `skip_blind`, `skipping_booster`, `playing_card_added`, `first_hand_drawn`, `setting_blind`, `destroying_card`, `cards_destroyed`, `remove_playing_cards`, `using_consumeable`, `debuffed_hand`, `pre_discard`, `discard` 等分支.

## 7. 覆盖清单 (本段涉及的全部 id)

| id | 中文名 | 类别 | 触发 context | 主要返回字段 | 源码行 |
| --- | --- | --- | --- | --- | --- |
| `j_photograph` | 照片 | 小丑 | individual / play | `x_mult` | 3093-3105 |
| `j_8_ball` | 八号球 | 小丑 | individual / play | `extra(func)` | 3106-3126 |
| `j_idol` | 偶像 | 小丑 | individual / play | `x_mult` | 3127-3135 |
| `j_scary_face` | 恐怖面孔 | 小丑 | individual / play | `chips` | 3136-3142 |
| `j_smiley` | 微笑表情 | 小丑 | individual / play | `mult` | 3143-3149 |
| `j_ticket` | 金票 | 小丑 | individual / play | `dollars` | 3150-3158 |
| `j_scholar` | 学者 | 小丑 | individual / play | `chips`, `mult` | 3159-3166 |
| `j_walkie_talkie` | 对讲机 | 小丑 | individual / play | `chips`, `mult` | 3167-3174 |
| `j_business` | 名片 | 小丑 | individual / play | `dollars` | 3175-3184 |
| `j_fibonacci` | 斐波那契 | 小丑 | individual / play | `mult` | 3185-3195 |
| `j_even_steven` | 偶数史蒂文 | 小丑 | individual / play | `mult` | 3196-3205 |
| `j_odd_todd` | 奇数托德 | 小丑 | individual / play | `chips` | 3206-3216 |
| `j_greedy_joker` `j_lusty_joker` `j_wrathful_joker` `j_gluttenous_joker` | 贪婪 / 色欲 / 愤怒 / 暴食 | 小丑 | individual / play | `mult` | 3217-3223 |
| `j_rough_gem` | 璞玉 | 小丑 | individual / play | `dollars` | 3224-3232 |
| `j_onyx_agate` | 缟玛瑙 | 小丑 | individual / play | `mult` | 3233-3239 |
| `j_arrowhead` | 箭头 | 小丑 | individual / play | `chips` | 3240-3246 |
| `j_bloodstone` | 血石 | 小丑 | individual / play | `x_mult` | 3247-3254 |
| `j_ancient` | 古老小丑 | 小丑 | individual / play | `x_mult` | 3255-3261 |
| `j_triboulet` | 特里布莱 | 小丑 | individual / play | `x_mult` | 3262-3269 |
| `j_shoot_the_moon` | 射月 | 小丑 | individual / hand | `h_mult` | 3272-3286 |
| `j_baron` | 男爵 | 小丑 | individual / hand | `x_mult` | 3287-3301 |
| `j_reserved_parking` | 私人车位 | 小丑 | individual / hand | `dollars` | 3302-3319 |
| `j_raised_fist` | 致胜之拳 | 小丑 | individual / hand | `h_mult` | 3320-3340 |
| `j_sock_and_buskin` | 喜与悲 | 小丑 | repetition / play | `repetitions` | 3344-3351 |
| `j_hanging_chad` | 未断选票 | 小丑 | repetition / play | `repetitions` | 3352-3359 |
| `j_dusk` | 黄昏 | 小丑 | repetition / play | `repetitions` | 3360-3366 |
| `j_selzer` | 汽水 | 小丑 | repetition / play, after | `repetitions` | 3367-3373, 3601-3630 |
| `j_hack` | 烂脱口秀演员 | 小丑 | repetition / play | `repetitions` | 3374-3384 |
| `j_mime` | 哑剧演员 | 小丑 | repetition / hand | `repetitions` | 3387-3393 |
| `j_baseball` | 棒球卡 | 小丑 | other_joker | `Xmult_mod` | 3397-3408 |
| `j_trousers` | 备用裤子 | 小丑 | before, 默认 | `mult_mod` | 3412-3419, 3986-3990 |
| `j_space` | 太空小丑 | 小丑 | before | `level_up` | 3420-3426 |
| `j_square` | 方形小丑 | 小丑 | before, 默认 | `chip_mod` | 3427-3434, 3901-3906 |
| `j_runner` | 跑步选手 | 小丑 | before, 默认 | `chip_mod` | 3435-3442, 3908-3913 |
| `j_midas_mask` | 迈达斯面具 | 小丑 | before | 无 (副作用) | 3443-3464 |
| `j_vampire` | 吸血鬼 | 小丑 | before, 通用规则 1 | `Xmult_mod` | 3465-3490 |
| `j_todo_list` | 待办清单 | 小丑 | before | `dollars` | 3491-3500 |
| `j_dna` | DNA | 小丑 | before | `playing_cards_created` | 3501-3524 |
| `j_ride_the_bus` | 搭乘巴士 | 小丑 | before, 默认 | `mult_mod` | 3525-3542, 3992-3996 |
| `j_obelisk` | 方尖石塔 | 小丑 | before, 通用规则 1 | `Xmult_mod` | 3543-3562 |
| `j_green_joker` | 绿色小丑 | 小丑 | before, 默认 | `mult_mod` | 3563-3569, 4010-4014 |
| `j_ice_cream` | 冰淇淋 | 小丑 | after, 默认 | `chip_mod` | 3571-3599, 3915-3920 |
| `j_loyalty_card` | 积分卡 | 小丑 | 默认 | `Xmult_mod` | 3632-3652 |
| `j_half` | 半张小丑 | 小丑 | 默认 | `mult_mod` | 3672-3677 |
| `j_abstract` | 抽象小丑 | 小丑 | 默认 | `mult_mod` | 3678-3687 |
| `j_acrobat` | 杂技演员 | 小丑 | 默认 | `Xmult_mod` | 3688-3693 |
| `j_mystic_summit` | 神秘之峰 | 小丑 | 默认 | `mult_mod` | 3694-3699 |
| `j_misprint` | 印错小丑 | 小丑 | 默认 | `mult_mod` | 3700-3706 |
| `j_banner` | 旗帜 | 小丑 | 默认 | `chip_mod` | 3707-3712 |
| `j_stuntman` | 特技演员 | 小丑 | 默认 | `chip_mod` | 3713-3718 |
| `j_matador` | 斗牛士 | 小丑 | 默认 | `dollars` | 3719-3730 |
| `j_supernova` | 超新星 | 小丑 | 默认 | `mult_mod` | 3731-3736 |
| `j_ceremonial` | 仪式匕首 | 小丑 | 默认 | `mult_mod` | 3737-3742 |
| `j_vagabond` | 流浪者 | 小丑 | 默认 | 塔罗牌生成 | 3743-3761 |
| `j_superposition` | 叠加态 | 小丑 | 默认 | 塔罗牌生成 | 3762-3786 |
| `j_seance` | 通灵 | 小丑 | 默认 | 幻灵牌生成 | 3787-3806 |
| `j_flower_pot` | 花盆 | 小丑 | 默认 | `Xmult_mod` | 3807-3839 |
| `j_seeing_double` | 重影 | 小丑 | 默认 | `Xmult_mod` | 3840-3872 |
| `j_wee` | 小小丑 | 小丑 | 默认 (成长在 individual) | `chip_mod` | 3873-3878 |
| `j_castle` | 城堡 | 小丑 | 默认 | `chip_mod` | 3880-3885 |
| `j_blue_joker` | 蓝色小丑 | 小丑 | 默认 | `chip_mod` | 3887-3892 |
| `j_erosion` | 侵蚀 | 小丑 | 默认 | `mult_mod` | 3894-3899 |
| `j_stone` | 石头小丑 | 小丑 | 默认 | `chip_mod` | 3922-3927 |
| `j_steel_joker` | 钢铁小丑 | 小丑 | 默认 | `Xmult_mod` | 3929-3934 |
| `j_bull` | 斗牛 | 小丑 | 默认 | `chip_mod` | 3936-3941 |
| `j_drivers_license` | 驾驶执照 | 小丑 | 默认 | `Xmult_mod` | 3943-3950 |
| `j_blackboard` | 黑板 | 小丑 | 默认 | `Xmult_mod` | 3951-3965 |
| `j_stencil` | 小丑模板 | 小丑 | 默认 | `Xmult_mod` | 3966-3972 |
| `j_swashbuckler` | 侠盗 | 小丑 | 默认 | `mult_mod` | 3974-3978 |
| `j_joker` | 小丑 | 小丑 | 默认 | `mult_mod` | 3980-3984 |
| `j_flash` | 闪示卡 | 小丑 | 默认 | `mult_mod` | 3998-4002 |
| `j_popcorn` | 爆米花 | 小丑 | 默认 | `mult_mod` | 4004-4008 |
| `j_fortune_teller` | 占卜师 | 小丑 | 默认 | `mult_mod` | 4016-4021 |
| `j_gros_michel` | 大麦克香蕉 | 小丑 | 默认 | `mult_mod` | 4022-4027 |
| `j_cavendish` | 卡文迪什 | 小丑 | 默认 | `Xmult_mod` | 4028-4033 |
| `j_red_card` | 红牌 | 小丑 | 默认 | `mult_mod` | 4034-4039 |
| `j_card_sharp` | 老千小丑 | 小丑 | 默认 | `Xmult_mod` | 4040-4045 |
| `j_bootstraps` | 提靴带 | 小丑 | 默认 | `mult_mod` | 4046-4051 |
| `j_caino` | 卡尼奥 | 小丑 | 默认 | `Xmult_mod` | 4052-4057 |

本段不含消耗牌自己的分支: `self.ability.set == "Planet"` 等消耗牌逻辑集中在第 2293-2302 行 (`joker_main` 且 `v_observatory`), 以及第一段; 本段内出现的 Tarot / Spectral / Planet 生成都来自小丑的副作用, 已在上面各自小节标注.
