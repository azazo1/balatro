# 小丑与卡牌效果规格 第 3 批: calculate_joker 尾段与逐卡结算入口

依据上游 Balatro 1.0.1o 资源, 涉及文件:

- [game/card.lua](<../../game/card.lua>)
- [game/functions/common_events.lua](<../../game/functions/common_events.lua>)
- [game/functions/state_events.lua](<../../game/functions/state_events.lua>)
- [game/back.lua](<../../game/back.lua>)

## 覆盖范围与边界

- A 部分: `Card:calculate_joker` 的尾段, 即 [L4000-L4062](<../../game/card.lua#L4000-L4062>). 该函数整体是 L2291-L4062, 前面的 L2293-L3999 由本系列前两份文档覆盖, 本文件不重复.
  - 另外说明: L4063 到文件末尾 L4771 是 `is_suit`, `set_card_area`, `remove_from_area`, `align`, `flip`, `update`, `hard_set_T`, `move`, `hover`, `juice_up`, `draw`, `release`, `highlight`, `click`, `save`, `load`, `remove`, 它们不含小丑效果分支.
- B 部分: `calculate_joker` 之外的逐卡结算入口, 含 `eval_card`, 逐卡数值 getter, 增强牌结算, `Card:calculate_seal`, `Card:get_end_of_round_effect`, 以及 `Back:trigger_effect` 里的 `final_scoring_step`.

姊妹文件与重叠: [joker-effects-01.md](<./joker-effects-01.md>) 覆盖 L2291-L3100, [joker-effects-02.md](<./joker-effects-02.md>) 覆盖 L3065-L4062. 因此本文 A 部分 (L4000-L4062) 的十条与 02 的末段 (目录里的 5.3.31 到 5.3.40) 是同一批小丑, 合并时取任一份即可. 本文额外给出这些效果的成长与销毁分支行号 (见各条目的 "成长分支"), 以及顺序依赖表 (见 A.11), 便于逐条实现时确认前置条件.

字段名一律沿用源码: `mult_mod`, `chip_mod`, `Xmult_mod`, `dollars`, `p_dollars`, `repetitions`, `level_up`, `extra`, `card`, `message`, `colour`, `func`. 注意源码用的是复数 `repetitions`, 不是 `repetition`.

## A. calculate_joker 尾段 (L4000-L4062)

### A.0 这些条目共同的前提

这一段代码本身只是一串 `if ... then return` 的尾巴, 单独看会漏掉触发条件, 所以先把包住它的结构写清楚.

调用链:

1. `calculate_joker` 只由 `eval_card` ([common_events.lua L580-L656](<../../game/functions/common_events.lua#L580-L656>)) 调用.
2. `joker_main` 阶段的 context 在 [state_events.lua L905](<../../game/functions/state_events.lua#L905>) 构造:

   ```lua
   {cardarea = G.jokers, full_hand = G.play.cards, scoring_hand = scoring_hand,
    scoring_name = text, poker_hands = poker_hands, joker_main = true}
   ```

   调用对象是 `G.jokers.cards` 与 `G.consumeables.cards` 的并集 (后者是为了让 `v_observatory` 的星球牌生效).
3. 由于 context 里没有 `before` 也没有 `after`, 分支链会落到 [card.lua L3631](<../../game/card.lua#L3631>) 的 `else`, 再进入 [L3410](<../../game/card.lua#L3410>) 的 `if context.cardarea == G.jokers`, 本部分所有条目都在这个块内.
4. 整段是**按顺序**判断的 `if ... then return` 串 (L3632 到 L4057), 命中即返回, 后面的判断不再执行. 所以 L4000 以后的条目只有在此前 L3632-L3997 全部分支都没有返回时才可能命中. 其中 [L3653](<../../game/card.lua#L3653>) 的 `self.ability.x_mult > 1` 分支, 以及 [L3660](<../../game/card.lua#L3660>) / [L3666](<../../game/card.lua#L3666>) 的 `t_mult` / `t_chips` 分支都不看名字, 任何满足数值条件的小丑都会提前返回. 逐条翻译时**必须保留原有判断顺序**, 不能改写成按名字查表的哈希分派.
5. [L2292](<../../game/card.lua#L2292>) `if self.debuff then return nil end`: 被压制 (boss 盲注压制, 或 `perishable` 耗尽) 的小丑完全不参与.
6. 蓝图与头脑风暴在 [L2304-L2334](<../../game/card.lua#L2304-L2334>): 累加 `context.blueprint` 后递归调用目标小丑的 `calculate_joker`, 并把返回值改成 `card = context.blueprint_card or self`, 同时覆写 `colour` (蓝图用 `G.C.BLUE`, 头脑风暴用 `G.C.RED`). A 部分的条目都**不含** `not context.blueprint` 判断, 也就是被复制时数值照常返回. 这些分支不改状态, 所以不存在复制导致的重复计数问题.
7. 返回值消费在 [state_events.lua L905-L925](<../../game/functions/state_events.lua#L905-L925>): 只处理 `mult_mod` (加到 mult), `chip_mod` (加到 chips), `Xmult_mod` (乘到 mult). `dollars`, `p_dollars`, `message`, `colour` 在这个阶段不会自动结算, 只用于显示; 需要给钱的 joker 必须自己在分支里调 `ease_dollars` (例如 [L3721](<../../game/card.lua#L3721>) 的 Matador).
8. joker_main 阶段里每张小丑只被轮询调用一次, 所以返回值只提供一次加成. 例外是被蓝图或头脑风暴复制时: 复制牌会带着 `context.blueprint` 额外调一次被复制的小丑, 于是同一份数值被计入两次, 这是设计如此 (例如被复制的 Bootstraps 会给出两次 `mult_mod`). A 部分的条目因为没有 `not context.blueprint` 判断, 复制行为与普通情况一致.

相关入口的位置对照 (供实现时找上下文):

- `context.before` 的效果结算: [state_events.lua L630](<../../game/functions/state_events.lua#L630>), 只处理 `level_up` 字段.
- `context.individual` (逐张计分牌): [state_events.lua L692](<../../game/functions/state_events.lua#L692>) (play 区), [L798](<../../game/functions/state_events.lua#L798>) (hand 区).
- `context.repetition`: [state_events.lua L669](<../../game/functions/state_events.lua#L669>), [L678](<../../game/functions/state_events.lua#L678>).
- `context.after`: [state_events.lua L1070](<../../game/functions/state_events.lua#L1070>).
- `context.discard`: [state_events.lua L404](<../../game/functions/state_events.lua#L404>), context 为 `{discard = true, other_card = G.hand.highlighted[i], full_hand = G.hand.highlighted}`.
- `context.reroll_shop`: Flash Card 的成长点, 见 A.1.

### A.1 闪示卡 / Flash Card (`j_flash`)

- 触发: `context.joker_main` 阶段 (`cardarea == G.jokers`, 非 `before`, 非 `after`), 附加条件 `self.ability.mult > 0`.
- 返回值:
  - `mult_mod = self.ability.mult`
  - `message = localize{type = 'variable', key = 'a_mult', vars = {self.ability.mult}}`
- 读取状态: `self.ability.mult`.
- 副作用: 本分支无副作用 (只读).
- 成长分支 (不在本段): [L2403-L2411](<../../game/card.lua#L2403-L2411>), `context.reroll_shop` 且 `not context.blueprint`, 执行 `self.ability.mult = self.ability.mult + self.ability.extra` (每次商店重 roll +2), 并挂一个只显示状态文本的事件.
- 行号: 返回分支 [L3998-L4003](<../../game/card.lua#L3998-L4003>).
- 原型: `config = {extra = 2, mult = 0}`, 稀有度 2, 售价 5, `perishable_compat = false`, `eternal_compat = true`. 因为 `ability.mult` 初值是 0, 没重 roll 过时这个分支不会命中.

### A.2 爆米花 / Popcorn (`j_popcorn`)

- 触发: `context.joker_main` 阶段, 附加条件 `self.ability.mult > 0`.
- 返回值:
  - `mult_mod = self.ability.mult`
  - `message = localize{type = 'variable', key = 'a_mult', vars = {self.ability.mult}}`
- 读取状态: `self.ability.mult`.
- 副作用: 本分支无副作用.
- 成长分支 (不在本段): [L2945-L2974](<../../game/card.lua#L2945-L2974>), `context.end_of_round` 且 `not context.blueprint`:
  - 若 `self.ability.mult - self.ability.extra <= 0`: 挂事件执行 `G.jokers:remove_card(self)` 与 `self:remove()`, 即**销毁自身**, 返回 `{message = localize('k_eaten_ex'), colour = G.C.RED}`.
  - 否则 `self.ability.mult = self.ability.mult - self.ability.extra`, 返回 `{message = localize{type = 'variable', key = 'a_mult_minus', vars = {self.ability.extra}}, colour = G.C.MULT}`.
- 行号: 返回分支 [L4004-L4009](<../../game/card.lua#L4004-L4009>).
- 原型: `config = {mult = 20, extra = 4}`, 稀有度 1, `perishable_compat = true`, `eternal_compat = false`. 从 20 起, 每回合结束 -4, 第 5 次回合结束时自毁.

### A.3 绿色小丑 / Green Joker (`j_green_joker`)

- 触发: `context.joker_main` 阶段, 附加条件 `self.ability.mult > 0`.
- 返回值:
  - `mult_mod = self.ability.mult`
  - `message = localize{type = 'variable', key = 'a_mult', vars = {self.ability.mult}}`
- 读取状态: `self.ability.mult`.
- 副作用: 本分支无副作用.
- 成长分支 (不在本段):
  - [L3563-L3569](<../../game/card.lua#L3563-L3569>), `context.before` 且 `not context.blueprint`: `self.ability.mult = self.ability.mult + self.ability.extra.hand_add`, 返回 `{card = self, message = localize{type = 'variable', key = 'a_mult', vars = {self.ability.extra.hand_add}}}`. 也就是每次出牌 +1.
  - [L2846-L2857](<../../game/card.lua#L2846-L2857>), `context.discard` 且 `not context.blueprint` 且 `context.other_card == context.full_hand[#context.full_hand]`: `self.ability.mult = math.max(0, self.ability.mult - self.ability.extra.discard_sub)`, 值真的变化时返回 `{message = localize{type = 'variable', key = 'a_mult_minus', vars = {self.ability.extra.discard_sub}}, colour = G.C.RED, card = self}`.
    - `context.full_hand` 在弃牌 context 里是 `G.hand.highlighted`, 所以 `other_card == full_hand[#full_hand]` 表示只有被弃的最后一张牌会让这里生效, 一次弃牌只减一次.
- 行号: 返回分支 [L4010-L4015](<../../game/card.lua#L4010-L4015>).
- 原型: `config = {extra = {hand_add = 1, discard_sub = 1}}`, 稀有度 1, `perishable_compat = false`, `eternal_compat = true`.

### A.4 占卜师 / Fortune Teller (`j_fortune_teller`)

- 触发: `context.joker_main` 阶段, 附加条件 `G.GAME.consumeable_usage_total` 存在且 `G.GAME.consumeable_usage_total.tarot > 0`.
- 返回值:
  - `mult_mod = G.GAME.consumeable_usage_total.tarot`
  - `message = localize{type = 'variable', key = 'a_mult', vars = {G.GAME.consumeable_usage_total.tarot}}`
  - 注意倍率直接等于累计使用过的塔罗张数, **不乘** `ability.extra`.
- 读取状态: `G.GAME.consumeable_usage_total.tarot`.
- 副作用: 本分支无副作用.
- 相关分支:
  - [L2722-L2726](<../../game/card.lua#L2722-L2726>), `context.using_consumeable` 且 `not context.blueprint` 且 `context.consumeable.ability.set == "Tarot"`: 只挂一个显示 `a_mult` 的状态文本事件, 不改数值.
  - 真正的计数在 [misc_functions.lua L1196-L1206](<../../game/functions/misc_functions.lua#L1196-L1206>) 的 `set_consumeable_usage`, 那里按 `card.config.center.set` 累加 `tarot` / `planet` / `spectral` / `tarot_planet` / `all`.
- 行号: 返回分支 [L4016-L4021](<../../game/card.lua#L4016-L4021>).
- 原型: `config = {extra = 1}`, 稀有度 1, 售价 6.

### A.5 大麦克香蕉 / Gros Michel (`j_gros_michel`)

- 触发: `context.joker_main` 阶段, 无附加条件.
- 返回值:
  - `mult_mod = self.ability.extra.mult` (原型为 15)
  - `message = localize{type = 'variable', key = 'a_mult', vars = {self.ability.extra.mult}}`
- 读取状态: `self.ability.extra.mult`.
- 副作用: 本分支无副作用.
- 其它分支 (不在本段): [L3019-L3046](<../../game/card.lua#L3019-L3046>), `context.end_of_round` 且外层 [L2888](<../../game/card.lua#L2888>) 的 `not context.blueprint`. 与 Cavendish 共用同一段:
  - `pseudorandom('gros_michel') < G.GAME.probabilities.normal / self.ability.extra.odds` (odds 为 6) 命中: 挂事件销毁自身 (`G.jokers:remove_card(self)`, `self:remove()`), 置 `G.GAME.pool_flags.gros_michel_extinct = true`, 返回 `{message = localize('k_extinct_ex')`.
  - 未命中: 返回 `{message = localize('k_safe_ex')}`.
- 行号: 返回分支 [L4022-L4027](<../../game/card.lua#L4022-L4027>).
- 原型: `config = {extra = {odds = 6, mult = 15}}`, `no_pool_flag = 'gros_michel_extinct'`, `eternal_compat = false`.

### A.6 卡文迪什 / Cavendish (`j_cavendish`)

- 触发: `context.joker_main` 阶段, 无附加条件.
- 返回值:
  - `Xmult_mod = self.ability.extra.Xmult` (原型为 3)
  - `message = localize{type = 'variable', key = 'a_xmult', vars = {self.ability.extra.Xmult}}`
- 读取状态: `self.ability.extra.Xmult`.
- 副作用: 本分支无副作用.
- 其它分支 (不在本段): 与 Gros Michel 共用 [L3019-L3046](<../../game/card.lua#L3019-L3046>) 的 `context.end_of_round` 段:
  - `pseudorandom('cavendish') < G.GAME.probabilities.normal / self.ability.extra.odds` (odds 为 1000) 命中: 销毁自身, 返回 `{message = localize('k_extinct_ex')}`. 这里**不设** pool flag.
  - 未命中: 返回 `{message = localize('k_safe_ex')}`.
- 行号: 返回分支 [L4028-L4033](<../../game/card.lua#L4028-L4033>).
- 原型: `config = {extra = {odds = 1000, Xmult = 3}}`, `yes_pool_flag = 'gros_michel_extinct'`, 稀有度 1, 售价 4. 注意 `Xmult` 写在 `extra` 里, 所以 `ability.x_mult` 仍是 1, 不会被 [L3653](<../../game/card.lua#L3653>) 的泛化分支截走.

### A.7 红牌 / Red Card (`j_red_card`)

- 触发: `context.joker_main` 阶段, 附加条件 `self.ability.mult > 0`.
- 返回值:
  - `mult_mod = self.ability.mult`
  - `message = localize{type = 'variable', key = 'a_mult', vars = {self.ability.mult}}`
- 读取状态: `self.ability.mult`.
- 副作用: 本分支无副作用.
- 成长分支 (不在本段): [L2441-L2455](<../../game/card.lua#L2441-L2455>), `context.skipping_booster` 且 `not context.blueprint`: `self.ability.mult = self.ability.mult + self.ability.extra` (每次跳过补充包 +3), 并挂状态文本事件.
- 行号: 返回分支 [L4034-L4039](<../../game/card.lua#L4034-L4039>).
- 原型: `config = {extra = 3}`, 稀有度 1, 售价 5, `perishable_compat = false`. `ability.mult` 初值 0.

### A.8 老千小丑 / Card Sharp (`j_card_sharp`)

- 触发: `context.joker_main` 阶段, 附加条件 `G.GAME.hands[context.scoring_name]` 存在且 `G.GAME.hands[context.scoring_name].played_this_round > 1`.
- 返回值:
  - `Xmult_mod = self.ability.extra.Xmult` (原型为 3)
  - `message = localize{type = 'variable', key = 'a_xmult', vars = {self.ability.extra.Xmult}}`
- 读取状态: `G.GAME.hands[context.scoring_name].played_this_round`, `context.scoring_name`.
- 副作用: 本分支无副作用.
- 行号: 返回分支 [L4040-L4045](<../../game/card.lua#L4040-L4045>). 没有别的分支, 全效果只有这一处.
- 原型: `config = {extra = {Xmult = 3}}`, 稀有度 2, 售价 6. `played_this_round` 由回合流程维护, 实现时要在出牌开始时复位, 出牌结算后累加.

### A.9 提靴带 / Bootstraps (`j_bootstraps`)

- 触发: `context.joker_main` 阶段, 附加条件 `math.floor((G.GAME.dollars + (G.GAME.dollar_buffer or 0)) / self.ability.extra.dollars) >= 1`.
- 返回值:
  - `mult_mod = self.ability.extra.mult * math.floor((G.GAME.dollars + (G.GAME.dollar_buffer or 0)) / self.ability.extra.dollars)`, 原型即 `2 * floor(钱 / 5)`
  - `message = localize{type = 'variable', key = 'a_mult', vars = ...}` 用同一个值.
- 读取状态: `G.GAME.dollars`, `G.GAME.dollar_buffer` (可能为 nil, 按 0 处理), `self.ability.extra.mult`, `self.ability.extra.dollars`.
- 副作用: 本分支无副作用.
- 行号: 返回分支 [L4046-L4051](<../../game/card.lua#L4046-L4051>). 没有别的分支.
- 原型: `config = {extra = {mult = 2, dollars = 5}}`, 稀有度 2, 售价 7. `dollar_buffer` 是在一次结算里预记但还没落账的钱, 计算收益时必须一起算进来.

### A.10 卡尼奥 / Canio (`j_caino`)

- 源码里的名字字符串写作 `'Caino'`, 本地化键是 `j_caino`, 中文名 `卡尼奥`.
- 触发: `context.joker_main` 阶段, 附加条件 `self.ability.caino_xmult > 1`.
- 返回值:
  - `Xmult_mod = self.ability.caino_xmult`
  - `message = localize{type = 'variable', key = 'a_xmult', vars = {self.ability.caino_xmult}}`
- 读取状态: `self.ability.caino_xmult`, 初值 1, 在 [set_ability L324-L326](<../../game/card.lua#L324-L326>) 里初始化.
- 副作用: 本分支无副作用.
- 成长分支 (不在本段):
  - [L2622-L2646](<../../game/card.lua#L2622-L2646>), `context.cards_destroyed` 且 `not context.blueprint`: 数 `context.glass_shattered` 里的面牌数量 faces, `faces > 0` 时 `self.ability.caino_xmult = self.ability.caino_xmult + faces * self.ability.extra`.
    - 注意: 上游 1.0.1o 里**没有任何调用方**构造 `context.cards_destroyed`, 这一段是死代码 (活的是下面那一个).
  - [L2672-L2686](<../../game/card.lua#L2672-L2686>), `context.remove_playing_cards` 且 `not context.blueprint`: 数 `context.removed` 里的面牌数量, 同样按 `张数 * self.ability.extra` 累加到 `caino_xmult`. 调用点: [card.lua L1369-L1371](<../../game/card.lua#L1369-L1371>) (使用 Immolate 销毁手牌之后), [state_events.lua L425-L427](<../../game/functions/state_events.lua#L425-L427>) (`G.FUNCS.discard_cards_from_highlighted` 里, 小丑在 discard context 返回 `remove` 导致牌被销毁时), [state_events.lua L975](<../../game/functions/state_events.lua#L975>) (出牌结算后销毁本手里被标记销毁的牌, 例如玻璃牌破碎).
- 行号: 返回分支 [L4052-L4057](<../../game/card.lua#L4052-L4057>).
- 原型: `config = {extra = 1}`, 稀有度 4 (传奇), 售价 20, 每张销毁的面牌 +1 倍率乘数.

### A.11 本段的顺序依赖汇总

下面这张表说明 L4000-L4057 各条命中之前, 有哪些泛化分支可能已经返回. 实现时按源码顺序逐条判断即可, 不要按名字重排.

| 前置判断 | 行号 | 影响范围 |
| --- | --- | --- |
| `self.debuff` 直接返回 nil | [L2292](<../../game/card.lua#L2292>) | 全部 |
| Loyalty Card 的 `Xmult_mod` | [L3632-L3652](<../../game/card.lua#L3632-L3652>) | 只看名字, 无冲突 |
| `self.ability.x_mult > 1` 且 `name ~= 'Seeing Double'` 且 `type` 匹配 | [L3653-L3659](<../../game/card.lua#L3653-L3659>) | **任何** `x_mult > 1` 的小丑, 泛化分支 |
| `self.ability.t_mult > 0` 且 `type` 匹配 | [L3660-L3665](<../../game/card.lua#L3660-L3665>) | 泛化分支 |
| `self.ability.t_chips > 0` 且 `type` 匹配 | [L3666-L3671](<../../game/card.lua#L3666-L3671>) | 泛化分支 |
| 各个具名小丑判断 | [L3672-L3997](<../../game/card.lua#L3672-L3997>) | 只看名字, 无冲突 |

结论: A.1 到 A.10 的十个小丑在 L4000 之后, 且它们的 `ability.x_mult` 都等于 1 (`Cavendish` 与 `Card Sharp` 的倍率乘数写在 `extra.Xmult` 里, `Caino` 写在 `ability.caino_xmult` 里), `t_mult` 与 `t_chips` 都是 0, 所以不会被上面的泛化分支截走. 但 Rust 实现仍要保留顺序, 否则以后新增可成长 x_mult 的小丑时会静默出错.

## B. calculate_joker 之外的逐卡结算入口

### B.1 `eval_card` ([common_events.lua L580-L656](<../../game/functions/common_events.lua#L580-L656>))

唯一的逐卡效果分发入口. 签名 `eval_card(card, context)`, `context` 缺省为 `{}`, 返回值是一张结果表.

- 入口分支一: `context.repetition_only` 为真 ([L584-L590](<../../game/functions/common_events.lua#L584-L590>))
  - 只调 `card:calculate_seal(context)`, 有返回值就放进 `ret.seals`, 然后**立即返回**.
  - 也就是说这个模式下不做任何数值计算 (`get_chip_*` 都不会被调用), 只回答 "这张牌要不要重复结算".
  - 调用点: [state_events.lua L669](<../../game/functions/state_events.lua#L669>) (出牌区红印), [L813](<../../game/functions/state_events.lua#L813>) (手牌区红印), [L192](<../../game/functions/state_events.lua#L192>) (回合结束手牌红印).
- 入口分支二: `context.cardarea == G.play` ([L592-L622](<../../game/functions/common_events.lua#L592-L622>)), 依次求值并只在大于 0 时写入结果:
  - `ret.chips = card:get_chip_bonus()`
  - `ret.mult = card:get_chip_mult()`
  - `ret.x_mult = card:get_chip_x_mult(context)`
  - `ret.p_dollars = card:get_p_dollars()`
  - `ret.jokers = card:calculate_joker(context)` (对普通牌来说 `set` 既不是 `Planet` 也不是 `Joker`, 调用直接返回 nil, 这步只是兼容)
  - `ret.edition = card:get_edition(context)`
- 入口分支三: `context.cardarea == G.hand` ([L624-L639](<../../game/functions/common_events.lua#L624-L639>)):
  - `ret.h_mult = card:get_chip_h_mult()` (仅在 > 0 时写入)
  - `ret.x_mult = card:get_chip_h_x_mult()` (仅在 > 0 时写入, 注意字段名是 `x_mult` 而不是 `h_x_mult`)
  - `ret.jokers = card:calculate_joker(context)`
- 入口分支四: `context.cardarea == G.jokers` 或 `context.card == G.consumeables` ([L641-L653](<../../game/functions/common_events.lua#L641-L653>)), 三选一:
  - `context.edition` 为真: `ret.jokers = card:get_edition(context)`
  - 否则 `context.other_joker` 为真: `ret.jokers = context.other_joker:calculate_joker(context)` (注意是对**被注视的那张小丑**调用, 不是 `card`)
  - 否则: `ret.jokers = card:calculate_joker(context)`
- 副作用: 函数自身不改游戏状态, 但会通过 `get_p_dollars` 写 `G.GAME.dollar_buffer` 并挂清空事件, 通过 `get_chip_mult` / `get_p_dollars` 对 Lucky Card 掷随机数并置 `self.lucky_trigger = true`.
- 读取状态: `card.debuff`, `card.ability.*`, `card.seal`, `card.edition`, `context.cardarea`, `context.edition`, `context.other_joker`, `context.card`.
- 消费侧 (决定字段含义的地方):
  - 出牌区 [state_events.lua L692-L800](<../../game/functions/state_events.lua#L692-L800>): `chips` 加到 chips, `mult` 加到 mult, `p_dollars` 与 `dollars` 走 `ease_dollars`, `x_mult` 乘到 mult, `extra` 里的 `mult_mod` / `chip_mod` / `swap` / `func` 逐个处理, `edition` 的三个字段按加/乘处理.
  - 手牌区 [state_events.lua L798-L866](<../../game/functions/state_events.lua#L798-L866>): 只处理 `dollars`, `h_mult` (加到 mult), `x_mult` (乘到 mult), `message` (只显示). 手牌区**不处理** `chips` / `p_dollars`.
  - 小丑区 [state_events.lua L880-L930](<../../game/functions/state_events.lua#L880-L930>): edition 的 `chip_mod` / `mult_mod` 先结算, 再结算 `joker_main` 的 `mult_mod` / `chip_mod` / `Xmult_mod`, 最后才结算 edition 的 `x_mult_mod`.

### B.2 逐卡数值入口 ([card.lua L976-L1089](<../../game/card.lua#L976-L1089>))

这些 getter 就是牌面增强与封印的数值来源.

- `Card:get_chip_bonus` [L976-L982](<../../game/card.lua#L976-L982>)
  - `self.debuff` 为真: 返回 0.
  - `self.ability.effect == 'Stone Card'`: 返回 `self.ability.bonus + (self.ability.perma_bonus or 0)`, 即石头牌**不读** `self.base.nominal`.
  - 其它: 返回 `self.base.nominal + self.ability.bonus + (self.ability.perma_bonus or 0)`.
  - 读取: `debuff`, `ability.effect`, `ability.bonus`, `ability.perma_bonus`, `base.nominal`. 副作用: 无.
- `Card:get_chip_mult` [L984-L997](<../../game/card.lua#L984-L997>)
  - `debuff` 为真: 0. `ability.set == 'Joker'`: 0.
  - `ability.effect == "Lucky Card"`: 掷 `pseudorandom('lucky_mult') < G.GAME.probabilities.normal / 5`, 命中则置 `self.lucky_trigger = true` 并返回 `ability.mult`, 否则返回 0. 概率分母 5 是硬编码.
  - 其它: 返回 `ability.mult`.
- `Card:get_chip_x_mult(context)` [L999-L1004](<../../game/card.lua#L999-L1004>)
  - `debuff` 为真: 0. `ability.set == 'Joker'`: 0. `ability.x_mult <= 1`: 0. 否则返回 `ability.x_mult`.
  - 参数 `context` 在函数体内没有被使用.
- `Card:get_chip_h_mult` [L1006-L1009](<../../game/card.lua#L1006-L1009>): `debuff` 为真返回 0, 否则返回 `ability.h_mult`.
- `Card:get_chip_h_x_mult` [L1011-L1014](<../../game/card.lua#L1011-L1014>): `debuff` 为真返回 0, 否则返回 `ability.h_x_mult`.
- `Card:get_edition` [L1016-L1031](<../../game/card.lua#L1016-L1031>): `debuff` 为真返回 nil; `self.edition` 为空返回 nil; 否则返回 `{card = self}`, 并按存在性附加 `x_mult_mod = edition.x_mult`, `mult_mod = edition.mult`, `chip_mod = edition.chips`.
  - `edition` 的字段由 `Card:set_edition` [L387-L416](<../../game/card.lua#L387-L416>) 写入: 闪箔 `chips = 50`, 全息 `mult = 10`, 多彩 `x_mult = 1.5`, 负片不加数值只改 `card_limit`.
- `Card:get_p_dollars` [L1068-L1089](<../../game/card.lua#L1068-L1089>)
  - `debuff` 为真: 返回 0.
  - `self.seal == 'Gold'`: `ret = ret + 3`.
  - `ability.p_dollars > 0` 时: 若 `ability.effect == "Lucky Card"`, 掷 `pseudorandom('lucky_money') < G.GAME.probabilities.normal / 15` (分母 15 硬编码), 命中才加上 `ability.p_dollars` 并置 `lucky_trigger`; 非幸运牌直接加上.
  - `ret > 0` 时写 `G.GAME.dollar_buffer = (G.GAME.dollar_buffer or 0) + ret`, 并挂一个把 buffer 归零的事件.
  - 读取: `debuff`, `seal`, `ability.p_dollars`, `ability.effect`, `ability.mult`, `G.GAME.probabilities.normal`, `G.GAME.dollar_buffer`.
- 字段来源: `Card:set_ability` [L277-L299](<../../game/card.lua#L277-L299>) 把中心定义映射进 `ability`: `config.mult -> ability.mult`, `config.h_mult -> h_mult`, `config.h_x_mult -> h_x_mult`, `config.h_dollars -> h_dollars`, `config.p_dollars -> p_dollars`, `config.t_mult -> t_mult`, `config.t_chips -> t_chips`, `config.Xmult -> x_mult` (缺省 1), `config.extra -> extra`, 然后 [L299](<../../game/card.lua#L299>) 再把 `config.bonus` 加到 `ability.bonus`.

### B.3 增强牌结算入口

上游 `card.lua` 里**不存在** `Card:calculate_enhancement`. 增强的效果由三处拼起来完成, 移植时要一起实现:

1. 数据写入: `Card:set_ability` [L277-L299](<../../game/card.lua#L277-L299>).
2. 数值读取: B.2 的 getter, 由 B.1 的 `eval_card` 按区域调用.
3. 状态副作用: `state_events.lua` 的结算流程与 `Card:is_suit`.

八种增强的定义在 [game.lua L648-L655](<../../game/game.lua#L648-L655>), 效果如下:

| 增强 | 定义行 | 写入的 ability 字段 | 生效位置 |
| --- | --- | --- | --- |
| 奖励牌 Bonus Card | [L648](<../../game/game.lua#L648>) | `bonus = 30` | 出牌区 `get_chip_bonus` |
| 倍率牌 Mult Card | [L649](<../../game/game.lua#L649>) | `mult = 4` | 出牌区 `get_chip_mult` |
| 狂野牌 Wild Card | [L650](<../../game/game.lua#L650>) | 无字段 | `Card:is_suit`, 对任意花色返回 true |
| 玻璃牌 Glass Card | [L651](<../../game/game.lua#L651>) | `Xmult = 2`, `extra = 4` | 出牌区 `get_chip_x_mult` 给 2 倍乘数, 破碎判定见下 |
| 钢铁牌 Steel Card | [L652](<../../game/game.lua#L652>) | `h_x_mult = 1.5` | 手牌区 `get_chip_h_x_mult` |
| 石头牌 Stone Card | [L653](<../../game/game.lua#L653>) | `bonus = 50` | 出牌区 `get_chip_bonus` 走 Stone 分支, 不读 `base.nominal` |
| 黄金牌 Gold Card | [L654](<../../game/game.lua#L654>) | `h_dollars = 3` | 回合结束 `Card:get_end_of_round_effect` |
| 幸运牌 Lucky Card | [L655](<../../game/game.lua#L655>) | `mult = 20`, `p_dollars = 20` | 出牌区 `get_chip_mult` 与 `get_p_dollars`, 各掷一次随机 |

需要额外注意的副作用点:

- 玻璃破碎: [state_events.lua L961-L967](<../../game/functions/state_events.lua#L961-L967>), 出牌结算后对每张计分牌掷 `pseudorandom('glass') < G.GAME.probabilities.normal / ability.extra`, 命中就标记 `shattered = true` 并加入销毁列表; 破碎的牌还会触发 Glass Joker 与 Canio 的成长分支.
- 幸运牌触发标记: `lucky_trigger` 由 B.2 的 getter 写入, 在 [state_events.lua L700](<../../game/functions/state_events.lua#L700>) 于该张牌结算完后清空, 供 Lucky Cat 在同一张牌的 `context.individual` 里读取.
- 石头牌: 不计入 `G.GAME.cards_played` ([state_events.lua L650-L653](<../../game/functions/state_events.lua#L650-L653>)), 且 `is_suit` 恒为 false.
- 狂野牌: `is_suit` [L4064-L4089](<../../game/card.lua#L4064-L4089>) 里两处特例, 见 B.7.

### B.4 `Card:calculate_seal` ([card.lua L2242-L2269](<../../game/card.lua#L2242-L2269>))

- 触发: 调用方传入的 context.
  - `context.repetition` 且 `self.seal == 'Red'`: 返回 `{message = localize('k_again_ex'), repetitions = 1, card = self}`.
  - `context.discard` 且 `self.seal == 'Purple'`: 生成一张塔罗到消耗牌区, 条件为 `#G.consumeables.cards + G.GAME.consumeable_buffer < G.consumeables.config.card_limit`.
- 读取状态: `self.debuff`, `self.seal`, `G.consumeables.cards`, `G.consumeables.config.card_limit`, `G.GAME.consumeable_buffer`.
- 副作用: `G.GAME.consumeable_buffer = G.GAME.consumeable_buffer + 1`, 事件内 `create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, '8ba')` 后 `card:add_to_deck()`, `G.consumeables:emplace(card)`, buffer 归零, 以及 `card_eval_status_text` 的紫色塔罗提示.
- 返回值: 只有红印分支有返回值; 紫印分支与未命中分支返回 nil.
- 调用点: [common_events.lua L585](<../../game/functions/common_events.lua#L585>) (`eval_card` 的 `repetition_only`), [state_events.lua L400](<../../game/functions/state_events.lua#L400>) (`{discard = true}`), [state_events.lua L192](<../../game/functions/state_events.lua#L192>) (回合结束手牌红印).
- 金币印不在这里: 它由 `Card:get_p_dollars` 的 `seal == 'Gold'` 分支加 3 元.

### B.5 `Card:get_end_of_round_effect` ([card.lua L1033-L1065](<../../game/card.lua#L1033-L1065>))

- 触发: 调用方 [state_events.lua L180](<../../game/functions/state_events.lua#L180>) 对手牌逐张调用, 参数为空 (`get_end_of_round_effect()`), 所以函数签名上的 `context` 在 1.0.1o 里没有被使用.
- 返回值与条件:
  - `self.debuff` 为真: 返回空表 `{}`.
  - `self.ability.h_dollars > 0`: 写入 `ret.h_dollars = self.ability.h_dollars` 与 `ret.card = self`.
  - `self.seal == 'Blue'` 且 `#G.consumeables.cards + G.GAME.consumeable_buffer < G.consumeables.config.card_limit`: 从 `G.P_CENTER_POOLS.Planet` 里找 `config.hand_type == G.GAME.last_hand_played` 的那张星球牌并生成, 同时置 `ret.effect = true`.
- 读取状态: `self.debuff`, `self.ability.h_dollars`, `self.seal`, `G.consumeables.cards`, `G.consumeables.config.card_limit`, `G.GAME.consumeable_buffer`, `G.GAME.last_hand_played`, `G.P_CENTER_POOLS.Planet`.
- 副作用: `G.GAME.consumeable_buffer = G.GAME.consumeable_buffer + 1`, 事件内 `create_card('Planet', ...)`, `card:add_to_deck()`, `G.consumeables:emplace(card)`, buffer 归零, 再加一条 `card_eval_status_text` 星球提示.
- 消费侧: [state_events.lua L220-L227](<../../game/functions/state_events.lua#L220-L227>) 把 `h_dollars` 交给 `ease_dollars`.

### B.6 `Back:trigger_effect` 的 `final_scoring_step` ([back.lua L108-L172](<../../game/back.lua#L108-L172>))

- 调用点: [state_events.lua L946](<../../game/functions/state_events.lua#L946>)
  `local nu_chip, nu_mult = G.GAME.selected_back:trigger_effect{context = 'final_scoring_step', chips = hand_chips, mult = mult}`
  随后 `mult = mod_mult(nu_mult or mult)`, `hand_chips = mod_chips(nu_chip or hand_chips)`. 也就是说返回 nil 时保持原值.
- 触发条件: `self.name == 'Plasma Deck' and args.context == 'final_scoring_step'`.
- 返回值: 两个值 `args.chips, args.mult` (同时函数内的 `args` 表也被就地改动).
- 计算: `local tot = args.chips + args.mult`, 然后 `args.chips = math.floor(tot/2)`, `args.mult = math.floor(tot/2)`. 先求和再平分, 两次 floor 独立, 由于 chips 与 mult 都是整数所以两半相等.
- 副作用: `update_hand_text({delay = 0}, {mult = ..., chips = ...})`, 一个包含音效, `ease_colour` 与 `attention_text` 的展示事件 (含 4.3 秒与 6.3 秒的两段恢复动画), 以及 `delay(0.6)`.
- 相邻分支 (同一个函数里, 与本部分无关但需要一并保留):
  - [L111-L120](<../../game/back.lua#L111-L120>) Anaglyph Deck 的 `args.context == 'eval'`: 击败 boss 盲注后加一个 `tag_double`.
  - [L121-L123](<../../game/back.lua#L121-L123>) Plasma Deck 的 `args.context == 'blind_amount'`: 直接 return, 不改盲注所需筹码.
- 读取状态: `self.name`, `args.context`, `args.chips`, `args.mult`, 以及展示用的 `G.C.UI_CHIPS`, `G.C.UI_MULT`.

### B.7 附: 其它逐卡入口

- `Card:calculate_rental` [L2271-L2276](<../../game/card.lua#L2271-L2276>): `self.ability.rental` 为真时 `ease_dollars(-G.GAME.rental_rate)` 并加一条负数状态文本. 调用点 [state_events.lua L108](<../../game/functions/state_events.lua#L108>).
- `Card:calculate_perishable` [L2278-L2289](<../../game/card.lua#L2278-L2289>): `self.ability.perishable` 且 `perish_tally > 0` 时, `perish_tally == 1` 则置 0 并调 `self:set_debuff()`, 否则 `perish_tally = perish_tally - 1`, 两种情况都加状态文本. 调用点 [state_events.lua L109](<../../game/functions/state_events.lua#L109>).
- `Card:is_suit(suit, bypass_debuff, flush_calc)` [L4064-L4089](<../../game/card.lua#L4064-L4089>), 三处特例按顺序判断:
  1. `flush_calc` 为真且 `ability.effect == 'Stone Card'`: 返回 false. 非 flush 时同样在 `debuff` 检查之后返回 false.
  2. 狂野牌: `flush_calc` 为真时要求 `not self.debuff` 才返回 true, 非 flush 时不看 debuff.
  3. Smeared Joker 在场 (`next(find_joker('Smeared Joker'))`) 时, 红桃方片视为同类, 黑桃梅花视为同类, 同色即返回 true.
  4. 其它情况返回 `self.base.suit == suit`.
  - 非 flush 路径的第一行是 `if self.debuff and not bypass_debuff then return end`, 即 debuff 时返回 nil (不是 false), 调用方需要区分.
