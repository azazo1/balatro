# 小丑效果规格 01: calculate_joker 第一段

覆盖 `game/card.lua` 的 `Card:calculate_joker` 第 2291 行到第 3100 行. 结构上先处理 `self.ability.set == "Planet"` 的消耗牌分支 (天文台), 再进入 `self.ability.set == "Joker"` 的小丑分支; 小丑分支里第 2291-3064 行都是"非计分型"触发 (开包, 出售, 商店, 盲注, 弃牌, 回合结束等), 第 3065 行起进入 `context.individual`.

姊妹文件: [joker-effects-02.md](<./joker-effects-02.md>) 覆盖第 3065 行到第 4062 行. 两个文件在第 3065-3100 行重叠 (徒步者, 招财猫, 小小丑, 照片), 重叠条目在本文里仍然写全, 使本文可以独立实现.

## 0. 阅读约定

- 行号都是本仓库当前 `game/card.lua` 的行号.
- 原型参数 (`extra`, `mult`, `Xmult` 等) 取自 `game/game.lua` 里的同名 center, 括号内给出该 center 的行号.
- `self.ability.*` 是该小丑自己的运行时状态; `context.other_card.ability.*` 是被打分或被弃掉的那张牌的运行时状态.
- `Card:set_ability` (第 277-338 行) 决定 `self.ability` 与 center `config` 的对应关系: `mult = config.mult or 0`, `x_mult = config.Xmult or 1`, `extra = copy_table(config.extra)`, `extra_value = 0`, `h_size = config.h_size or 0`, `p_dollars = config.p_dollars or 0` 等. 因此正文里的 `self.ability.x_mult` 就对应 center 的 `config.Xmult`.
- 返回 `nil` 表示这次触发不生效; 返回 table 表示生效. 每个小丑在同一个 context 下的判定都是顺序 `if`, 命中即返回, 同一小丑在同一 context 里最多只返回第一个命中的分支.
- `context.blueprint` 为真 (数字) 表示这次调用是被蓝图或头脑风暴复制出来的; `context.blueprint_card` 是复制链最左边那张复制牌 (蓝图或头脑风暴自己). 未检查 `not context.blueprint` 的分支会被蓝图, 头脑风暴再触发一次, 这类条目在正文里单独标注为"可被复制".
- 类别标记: `小丑` 表示 `self.ability.set == "Joker"`; `消耗牌` 表示其它 set (本段只有 `Planet`, 即天文台相关的星球牌).

## 1. 本段的分发结构

`Card:calculate_joker` 的开头有两道全局闸门:

1. 第 2292 行: `if self.debuff then return nil end`. 该牌被 Boss 盲注禁用时, 任何效果都不生效 (本段所有小丑都受这条影响).
2. 第 2293, 2303 行: 之后按 `self.ability.set` 分成 `Planet` 和 `Joker` 两棵子树, 两棵子树都再判一次 `not self.debuff`.

小丑子树的顺序 (顺序即优先级, 命中一个 `elseif` 后其余分支不再判定):

| 顺序 | 分支条件 | 行号范围 | 本段涉及的小丑 |
| --- | --- | --- | --- |
| 前置 | `self.ability.name == "Blueprint"` | 2304-2320 | 蓝图 (复制机制) |
| 前置 | `self.ability.name == "Brainstorm"` | 2321-2334 | 头脑风暴 (复制机制) |
| 1 | `context.open_booster` | 2335-2351 | 幻觉 |
| 2 | `context.buying_card` | 2352-2353 | 空分支 |
| 3 | `context.selling_self` | 2354-2394 | 摔跤手, 零糖可乐, 隐形小丑 |
| 4 | `context.selling_card` | 2395-2402 | 篝火 |
| 5 | `context.reroll_shop` | 2403-2411 | 闪示卡 |
| 6 | `context.ending_shop` | 2412-2427 | 帕奇欧 |
| 7 | `context.skip_blind` | 2428-2440 | 回溯 |
| 8 | `context.skipping_booster` | 2441-2455 | 红牌 |
| 9 | `context.playing_card_added and not self.getting_sliced` | 2456-2461 | 全息影像 |
| 10 | `context.first_hand_drawn` | 2462-2490 | 证书, DNA, 交易卡 |
| 11 | `context.setting_blind and not self.getting_sliced` | 2491-2602 | 希科, 疯狂, 窃贼, 乌合之众, 卡牌术士, 仪式匕首, 大理石小丑 |
| 12 | `context.destroying_card and not context.blueprint` | 2603-2621 | 第六感 |
| 13 | `context.cards_destroyed` | 2622-2671 | 卡尼奥, 玻璃小丑 |
| 14 | `context.remove_playing_cards` | 2672-2707 | 卡尼奥, 玻璃小丑 |
| 15 | `context.using_consumeable` | 2708-2734 | 玻璃小丑, 占卜师, 星座 |
| 16 | `context.debuffed_hand` | 2735-2747 | 斗牛士 |
| 17 | `context.pre_discard` | 2748-2755 | 烧焦小丑 |
| 18 | `context.discard` | 2756-2873 | 拉面, 约里克, 交易卡, 城堡, 邮件回扣, 上路吧杰克, 绿色小丑, 无面小丑 |
| 19 | `context.end_of_round` | 2874-3064 | 哑剧演员, 篝火, 火箭, 黑龟豆, 隐形小丑, 爆米花, 待办清单, 鸡蛋, 礼品卡, 上路吧杰克, 大麦克香蕉, 卡文迪什, 骷髅先生 |
| 20 | `context.individual` | 3065-3100 (本文件截断) | 徒步者, 招财猫, 小小丑, 照片 |

同一个 context 可能被多次调用 (例如 `context.discard` 对每张被弃的牌调用一次), 所以分支内部的"只处理最后一张牌"之类判断不是冗余.

各 context 的调用点:

- `open_booster`: `card.lua:1797` 开补充包时 `{open_booster = true, card = self}`.
- `buying_card`: `card.lua:1856`, `button_callbacks.lua:2437, 2452`, 在本段是空分支.
- `selling_self`: `card.lua:1599` `self:calculate_joker{selling_self = true}`.
- `selling_card`: `button_callbacks.lua:2323` `{selling_card = true, card = card}`.
- `reroll_shop`: `button_callbacks.lua:2901`.
- `ending_shop`: `button_callbacks.lua:2486`.
- `skip_blind`: `button_callbacks.lua:2769` (在此之前 `G.GAME.skips` 已经 +1, 见 2755 行).
- `skipping_booster`: `button_callbacks.lua:2560`.
- `playing_card_added`: `misc_functions.lua:1582` 的 `playing_card_joker_effects`, 参数 `{playing_card_added = true, cards = cards}`.
- `first_hand_drawn`: `game.lua:3229` `{first_hand_drawn = true}`.
- `setting_blind`: `state_events.lua:336` `{setting_blind = true, blind = G.GAME.round_resets.blind}`.
- `destroying_card`: `state_events.lua:957` `{destroying_card = scoring_hand[i], full_hand = G.play.cards}`; 返回 `true` 会指示调用方销毁这张计分牌.
- `remove_playing_cards`: `state_events.lua:426` (弃牌销毁) 与 `state_events.lua:975` (计分销毁), 参数 `{cardarea = G.jokers, remove_playing_cards = true, removed = <被销毁的牌列表>}`.
- `using_consumeable`: `button_callbacks.lua:2220` `{using_consumeable = true, consumeable = card}`.
- `debuffed_hand`: `state_events.lua:1020` `{cardarea = G.jokers, ..., debuffed_hand = true}`; 只在打出的牌型被 Boss 盲注禁用时走这条.
- `pre_discard`: `state_events.lua:395` `{pre_discard = true, full_hand = G.hand.highlighted, hook = hook}`.
- `discard`: `state_events.lua:404` `{discard = true, other_card = G.hand.highlighted[i], full_hand = G.hand.highlighted}`, 对每张高亮的牌调用一次.
- `end_of_round`: `state_events.lua:101` (小丑主循环, `{end_of_round = true, game_over = game_over}`), `state_events.lua:183` (手里每张牌 `individual`), `state_events.lua:202` (手里每张牌 `repetition`, 参数带 `card_effects`).
- `individual` (`cardarea == G.play`): `state_events.lua:695`, 每张计分牌每轮重复都会重新调用.

## 2. 返回值字段与消费方

本段用到的返回字段及其消费方式 (消费代码都在 `game/functions/state_events.lua`):

| 字段 | 生效方式 |
| --- | --- |
| `mult_mod` | 加到本轮 `mult` (加法), 消费点 910 行 |
| `chip_mod` | 加到本轮 `hand_chips` (加法), 消费点 911 行 |
| `Xmult_mod` | 乘到本轮 `mult`, 消费点 912 行 |
| `dollars` | 立即 `ease_dollars`. 只在 `context.individual` 的计分循环里被消费 (第 727-731 行, 手牌 loop 845-848 行); 在 `debuffed_hand` 等分支里, 调用方只把整个返回值交给 `card_eval_status_text` 做飘字, 不会因为返回值里带 `dollars` 再加一次钱 |
| `p_dollars` | 按概率给钱, `Card:get_p_dollars` (第 1068 行) 里消费 |
| `repetitions` | 只用于 `context.repetition`; 让这张牌多结算几次, 消费点 192-206 行 |
| `x_mult` | 只用于 `context.individual`; 乘到本轮 `mult`, 消费点 751-756 行 |
| `chips` / `mult` | 只用于 `context.individual`; 分别加到 `hand_chips` / `mult`, 消费点 704-717 行 |
| `extra` | 立即执行: `extra.mult_mod` 加 mult, `extra.chip_mod` 加 chips, `extra.swap` 交换 chips 与 mult, `extra.func()` 直接调用, 消费点 734-748 行 |
| `remove` | 只用于 `context.discard`; 为真时把被弃的牌直接销毁而不是进弃牌堆, 消费点 406-419 行 |
| `saved` | 只用于 `context.end_of_round`; 为真时取消本局的失败判定, 消费点 104-106 行 |
| `message` | 仅用于飘字显示 |
| `colour` | 仅用于飘字颜色 |
| `card` | 让某张牌播动画 (`juice_card` / `juice_up`) |
| `delay` | 飘字延迟 (秒) |
| `func` | 顶层 `func` 在本段没有消费方, 实际执行的是 `extra.func`; 小丑分支用 `G.E_MANAGER:add_event` 自行排队副作用 |

`message` 里常用的本地化键 (取自 `game/localization/zh_CN.lua`): `k_upgrade_ex` = 升级, `k_reset` = 重置, `k_active_ex` = 激活, `k_eaten_ex` = 吃完了, `k_extinct_ex` = 已灭绝, `k_safe_ex` = 安全, `k_saved_ex` = 被救了, `k_val_up` = 价值提升, `k_duplicated_ex` = 复制, `k_no_room_ex` = 没有空间, `k_no_other_jokers` = 没有其他小丑牌, `k_plus_tarot` = +1 塔罗牌, `k_plus_joker` = +1 小丑, `k_plus_spectral` = +1 幻灵牌, `k_plus_stone` = +1 石头牌, `k_again_ex` = 再来一次, `ph_boss_disabled` = Boss 限制条件失效, `a_mult` = `+#1#` 倍率, `a_xmult` = `X#1#` 倍率, `a_mult_minus` = `-#1#` 倍率, `a_xmult_minus` = `-X#1#` 倍率, `a_hands` = 出牌次数 `+#1#`, `a_handsize_minus` = `-#1#` 手牌上限.

## 3. 消耗牌: 天文台 (`v_observatory`, set == "Planet")

- 类别: 消耗牌. 这段代码不在小丑分支里, 而是第 2293-2302 行.
- 触发条件: `self.ability.set == "Planet"`, 且 `context.joker_main` 为真, 且 `G.GAME.used_vouchers.v_observatory` 为真, 且 `self.ability.consumeable.hand_type == context.scoring_name`.
  - `self.ability.consumeable` 是 `Card:set_ability` 第 301-303 行给消耗牌挂上的原始 `config`, 星球牌的 `config.hand_type` 就是它升级的牌型键 (例如 `"Pair"`).
  - `context.scoring_name` 是本手牌型的英文键 (如 `"Flush Five"`, `"Pair"`, `"High Card"`), 由 `state_events.lua:880-905` 的 `joker_main` 循环传入.
  - 该循环遍历 `G.jokers.cards` 之后接着遍历 `G.consumeables.cards`, 所以放在消耗牌区的星球牌也会被问到.
- 返回: `{message = localize{type = 'variable', key = 'a_xmult', vars = {G.P_CENTERS.v_observatory.config.extra}}, Xmult_mod = G.P_CENTERS.v_observatory.config.extra}`. `v_observatory` 的 `config.extra = 1.5` (game.lua:614), 即 `X1.5` 倍率.
- 读取状态: `G.GAME.used_vouchers.v_observatory`, `self.ability.consumeable.hand_type`, `context.scoring_name`, `G.P_CENTERS.v_observatory.config.extra`.
- 副作用: 无 (纯计分).
- 备注: 不是小丑, 没有 `context.blueprint` 检查; 因此蓝图, 头脑风暴不会复制它的效果 (复制机制只作用于 `set == "Joker"` 的卡).

## 4. 复制类小丑 (在 context 分发之前处理)

这两张牌不按 context 分类, 而是对任何传进来的 context 都先做一次"转发", 所以它们的判定排在所有 `elseif` 之前. 它们自身不产生数值, 只把右边 (或最左边) 小丑的返回值搬过来.

### 4.1 蓝图 / Blueprint (`j_blueprint`)

- 源码: 第 2304-2320 行. 原型: `config = {}` (game.lua:498), `blueprint_compat = true`.
- 触发条件: 任意 context (该判定在 `context.*` 之前), 且 `self.ability.name == "Blueprint"`.
- 行为:
  1. 遍历 `G.jokers.cards` 找到 `self` 的下标 `i`, 取 `other_joker = G.jokers.cards[i+1]` (即蓝图右边紧邻的一张). 蓝图是最右一张时 `other_joker` 为 `nil`.
  2. 若 `other_joker` 存在且 `other_joker ~= self`: 先做 `context.blueprint = (context.blueprint and (context.blueprint + 1)) or 1`, 再 `context.blueprint_card = context.blueprint_card or self`.
  3. 若 `context.blueprint > #G.jokers.cards + 1` 则直接 `return` (防止复制链首尾相接时无限递归).
  4. 调用 `other_joker:calculate_joker(context)` 拿到 `other_joker_ret`.
  5. 若 `other_joker_ret` 非 `nil`: 把 `other_joker_ret.card` 改成 `context.blueprint_card or self`, 把 `other_joker_ret.colour` 改成 `G.C.BLUE`, 然后返回这个 table.
- 返回: 右侧小丑的返回值, 但 `card` 被改成蓝图 (或复制链起点), `colour` 被改成蓝色; 右侧小丑不生效时返回 `nil`.
- 读取状态: `G.jokers.cards` (顺序与相邻关系), `context.blueprint`, `context.blueprint_card`.
- 副作用: 直接改写传入的 `context` 表 (`context.blueprint`, `context.blueprint_card`), 这对被复制的那个小丑是可见的; 会递归触发右侧小丑的完整逻辑, 包括它的副作用 (加钱, 生成卡, 销毁小丑等).
- 备注: 蓝图自己没有数值, 也不检查右侧小丑的 `blueprint_compat` (`blueprint_compat` 只在第 4234 行用于 UI 显示"可否复制"). 因此在 Rust 实现里, 复制不应该按 `blueprint_compat` 过滤, 只按代码里是否写了 `not context.blueprint` 过滤.

### 4.2 头脑风暴 / Brainstorm (`j_brainstorm`)

- 源码: 第 2321-2334 行. 原型: `config = {}` (game.lua:514), `blueprint_compat = true`.
- 触发条件: 任意 context, 且 `self.ability.name == "Brainstorm"`.
- 行为: 与蓝图相同, 只有两点差别:
  1. `other_joker = G.jokers.cards[1]` (最左边那一张), 而不是右边紧邻的一张; 当头脑风暴自己就是最左一张时 `other_joker == self`, 不生效.
  2. 返回值的 `colour` 改成 `G.C.RED`.
- 返回: 最左侧小丑的返回值 (改过 `card` 与 `colour`), 或 `nil`.
- 读取状态: `G.jokers.cards`, `context.blueprint`, `context.blueprint_card`.
- 副作用: 同蓝图 (`context.blueprint` / `context.blueprint_card` 会被写入, 并递归触发目标小丑的逻辑).

## 5. context.open_booster

入口: 玩家打开补充包时, `card.lua:1797` 对每个小丑调用 `{open_booster = true, card = self}`.

### 5.1 幻觉 / Hallucination (`j_hallucination`)

- 源码: 第 2336-2351 行. 原型: `config = {extra = 2}` (game.lua:457), 即 1/2 概率.
- 触发条件: `context.open_booster`, 且 `self.ability.name == 'Hallucination'`, 且 `#G.consumeables.cards + G.GAME.consumeable_buffer < G.consumeables.config.card_limit` (消耗牌区还有空位), 且 `pseudorandom('halu'..G.GAME.round_resets.ante) < G.GAME.probabilities.normal / self.ability.extra`.
  - 随机用的 key 只带当前底注 `G.GAME.round_resets.ante`, 不带具体包的内容.
  - `G.GAME.consumeable_buffer` 是"已经预约但还没落位"的消耗牌数量, 用来防止同时开出多张导致超上限.
- 返回: 无 (返回 `nil`).
- 副作用:
  1. 立即 `G.GAME.consumeable_buffer = G.GAME.consumeable_buffer + 1`.
  2. `G.E_MANAGER:add_event` (trigger = `'before'`, delay = 0.0): `create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, 'hal')` 生成一张塔罗牌, 然后 `card:add_to_deck()`, `G.consumeables:emplace(card)`, 最后把 `G.GAME.consumeable_buffer` 归零.
  3. 飘字 `k_plus_tarot`, 颜色 `G.C.PURPLE`.
- 读取状态: `#G.consumeables.cards`, `G.GAME.consumeable_buffer`, `G.consumeables.config.card_limit`, `G.GAME.round_resets.ante`, `G.GAME.probabilities.normal`, `self.ability.extra`.
- 备注: `create_card` 的第 6 个参数 `soulable` 传 `nil`, 所以这次生成不会出"灵魂"或"黑洞"替换牌; 副作用只有开包时触发一次 (每个包问一次, 不是每张牌问一次). 没有 `not context.blueprint` 检查, 因此蓝图, 头脑风暴可以再开出一张.

## 6. context.selling_self

入口: `card.lua:1599` 卖出小丑时的 `self:calculate_joker{selling_self = true}` (注意这个 context 表里没有 `card` 字段, 也没有 `blueprint` 字段, 全靠 `context.blueprint_card`).

### 6.1 摔跤手 / Luchador (`j_luchador`)

- 源码: 第 2355-2360 行. 原型: `config = {}` (game.lua:449), `eternal_compat = false`.
- 触发条件: `context.selling_self`, 且 `self.ability.name == 'Luchador'`, 且 `G.GAME.blind` 存在, 且 `not G.GAME.blind.disabled`, 且 `G.GAME.blind:get_type() == 'Boss'`.
- 返回: 无.
- 副作用: 飘字 `ph_boss_disabled` (对象是 `context.blueprint_card or self`), 然后 `G.GAME.blind:disable()` 把当前 Boss 盲注的负面效果关掉.
- 读取状态: `G.GAME.blind.disabled`, `G.GAME.blind:get_type()`.
- 备注: 没有 `not context.blueprint` 检查, 蓝图, 头脑风暴卖掉时也会关盲注.

### 6.2 零糖可乐 / Diet Cola (`j_diet_cola`)

- 源码: 第 2361-2370 行. 原型: `config = {}` (game.lua:467), `eternal_compat = false`.
- 触发条件: `context.selling_self`, 且 `self.ability.name == 'Diet Cola'`.
- 返回: 无.
- 副作用: `G.E_MANAGER:add_event` 里 `add_tag(Tag('tag_double'))` 加一个"双倍标签", 然后 `play_sound('generic1', ...)`, `play_sound('holo1', ...)`. 两个音效的音调用的是 `math.random()` 而不是 `pseudorandom()`, 与游戏性无关.
- 读取状态: 无.
- 备注: 没有 `not context.blueprint` 检查, 可被蓝图, 头脑风暴复制 (会加两个双倍标签).

### 6.3 隐形小丑 / Invisible Joker (`j_invisible`)

- 源码: 第 2371-2394 行. 原型: `config = {extra = 2}` (game.lua:513), `blueprint_compat = false`.
- 触发条件: `context.selling_self`, 且 `self.ability.name == 'Invisible Joker'`, 且 `self.ability.invis_rounds >= self.ability.extra` (默认 2 回合), 且 `not context.blueprint`.
  - `self.ability.invis_rounds` 在 `Card:set_ability` 第 309 行初始化为 0, 在回合结束时累加 (见 22.5 节).
- 返回: 无 (只用 `card_eval_status_text` 显示提示).
- 行为与副作用:
  1. `juice_card_until(self, eval, true)`, 其中 `eval = function(card) return (card.ability.loyalty_remaining == 0) and not G.RESET_JIGGLES end` (纯视觉闪烁).
  2. 收集除自己以外的全部小丑到 `jokers` 列表; 若为空 → 飘字 `k_no_other_jokers`, 结束.
  3. 若 `#G.jokers.cards <= G.jokers.config.card_limit` (还有空位):
     - `chosen_joker = pseudorandom_element(jokers, pseudoseed('invisible'))` 随机挑一张.
     - `card = copy_card(chosen_joker, nil, nil, nil, chosen_joker.edition and chosen_joker.edition.negative)` 复制它, 第 5 个参数决定复制体是否继承"负片"版次.
     - 若复制体有 `ability.invis_rounds` 则置 0.
     - `card:add_to_deck()`, `G.jokers:emplace(card)`, 飘字 `k_duplicated_ex`.
  4. 没有空位 → 飘字 `k_no_room_ex` (什么都不生成).
- 读取状态: `self.ability.invis_rounds`, `self.ability.extra`, `G.jokers.cards`, `G.RESET_JIGGLES`, `G.jokers.config.card_limit`, `chosen_joker.edition.negative`.
- 备注: 因为条件里有 `not context.blueprint`, 蓝图, 头脑风暴复制不会额外复制一次; 检查是"卖出的这张牌自身是不是复制体", 而不是"周围有没有蓝图".

## 7. context.selling_card

入口: `button_callbacks.lua:2323`, 卖出一张牌时对每个小丑调用 `{selling_card = true, card = card}`. 这个分支末尾第 2402 行无条件 `return`, 所以卖牌时其他分支不会执行.

### 7.1 篝火 / Campfire (`j_campfire`)

- 源码: 第 2396-2402 行 (分支里的第 2402 行 `return` 属于这个分支). 原型: `config = {extra = 0.25}` (game.lua:478).
- 触发条件: `context.selling_card`, 且 `self.ability.name == 'Campfire'`, 且 `not context.blueprint`.
- 返回: 无 (直接 `return`).
- 副作用: `self.ability.x_mult = self.ability.x_mult + self.ability.extra` (每卖一张牌 `X0.25`); `G.E_MANAGER:add_event` 里飘字 `k_upgrade_ex`.
- 读取状态: `self.ability.x_mult`, `self.ability.extra`.
- 备注: 卖出的牌是哪张无关, 卖自己也会先走 `selling_self` 再走 `selling_card`; 重置逻辑在回合结束 (见 22.2 节).

## 8. context.reroll_shop

入口: `button_callbacks.lua:2901`, 商店里每次刷新时对每个小丑调用 `{reroll_shop = true}`.

### 8.1 闪示卡 / Flash Card (`j_flash`)

- 源码: 第 2404-2411 行. 原型: `config = {extra = 2, mult = 0}` (game.lua:469), 即 `self.ability.mult` 从 0 开始, 每次刷新 +2.
- 触发条件: `context.reroll_shop`, 且 `self.ability.name == 'Flash Card'`, 且 `not context.blueprint`.
- 返回: 无.
- 副作用: `self.ability.mult = self.ability.mult + self.ability.extra`; `G.E_MANAGER:add_event` 里飘字 `a_mult`, 数值用新的 `self.ability.mult`, 颜色 `G.C.MULT`.
- 读取状态: `self.ability.mult`, `self.ability.extra`.
- 备注: 本分支只负责成长, 加成的结算在 `context.joker_main` 的通用 `mult_mod` 分支 (第 3998-4002 行, 见 [joker-effects-02.md](<./joker-effects-02.md>)).

## 9. context.ending_shop

入口: `button_callbacks.lua:2486`, 离开商店时对每个小丑调用 `{ending_shop = true}`. 分支末尾第 2427 行无条件 `return`.

### 9.1 帕奇欧 / Perkeo (`j_perkeo`)

- 源码: 第 2413-2427 行. 原型: `config = {}` (game.lua:526).
- 触发条件: `context.ending_shop`, 且 `self.ability.name == 'Perkeo'`, 且 `G.consumeables.cards[1]` 存在 (至少有一张消耗牌).
- 返回: 无.
- 副作用: `G.E_MANAGER:add_event` 里:
  1. `copy_card(pseudorandom_element(G.consumeables.cards, pseudoseed('perkeo')), nil)` 复制消耗牌区里随机一张消耗牌.
  2. `card:set_edition({negative = true}, true)` 强制加上负片版次.
  3. `card:add_to_deck()`, `G.consumeables:emplace(card)`.
  4. 飘字 `k_duplicated_ex` (`context.blueprint_card or self`).
- 读取状态: `G.consumeables.cards`.
- 备注: 不检查消耗牌区上限, 因此可以超出 `card_limit`; 没有 `not context.blueprint` 检查, 蓝图, 头脑风暴会各复制一张.

## 10. context.skip_blind

入口: `button_callbacks.lua:2769`, 跳过盲注时对每个小丑调用 `{skip_blind = true}`. 调用前第 2755 行已经把 `G.GAME.skips` 加 1. 分支末尾第 2440 行无条件 `return`.

### 10.1 回溯 / Throwback (`j_throwback`)

- 源码: 第 2429-2440 行. 原型: `config = {extra = 0.25}` (game.lua:488).
- 触发条件: `context.skip_blind`, 且 `self.ability.name == 'Throwback'`, 且 `not context.blueprint`.
- 返回: 无.
- 副作用: 只排一个飘字事件 (`a_xmult`, 数值 `self.ability.x_mult`, 颜色 `G.C.RED`, `card = self`); 本分支不改 `self.ability.x_mult`.
- 读取状态: `self.ability.x_mult`.
- 备注: 真正的数值在 `Card:update` 第 4176-4178 行每帧重算: `self.ability.x_mult = 1 + G.GAME.skips * self.ability.extra`. 也就是说回溯的倍率不是"每次加 0.25", 而是"当前跳过次数决定", 数值永远等于 `1 + 0.25 * G.GAME.skips`. 实现时必须照抄这个公式, 不能只做增量.

## 11. context.skipping_booster

入口: `button_callbacks.lua:2560`, 跳过补充包时对每个小丑调用 `{skipping_booster = true}`. 分支末尾第 2455 行无条件 `return`.

### 11.1 红牌 / Red Card (`j_red_card`)

- 源码: 第 2442-2455 行. 原型: `config = {extra = 3}` (game.lua:434), 即每次 +3 倍率.
- 触发条件: `context.skipping_booster`, 且 `self.ability.name == 'Red Card'`, 且 `not context.blueprint`.
- 返回: 无.
- 副作用: `self.ability.mult = self.ability.mult + self.ability.extra`; `G.E_MANAGER:add_event` 里飘字 `a_mult`, 数值用 `self.ability.extra` (显示的是 3, 不是累计值), 颜色 `G.C.RED`, `delay = 0.45`, `card = self`.
- 读取状态: `self.ability.mult`, `self.ability.extra`.
- 备注: 加成的结算在 `context.joker_main` 默认分支 (第 4034-4039 行).

## 12. context.playing_card_added

入口: `misc_functions.lua:1582` 的 `playing_card_joker_effects`, 参数 `{playing_card_added = true, cards = cards}` (牌组里新增牌时调用). 分支条件里还有 `not self.getting_sliced`.

### 12.1 全息影像 / Hologram (`j_hologram`)

- 源码: 第 2457-2461 行. 原型: `config = {extra = 0.25, Xmult = 1}` (game.lua:441).
- 触发条件: `context.playing_card_added`, 且 `not self.getting_sliced`, 且 `self.ability.name == 'Hologram'`, 且 `not context.blueprint`, 且 `context.cards` 非空且 `context.cards[1]` 存在.
- 返回: 无.
- 副作用: `self.ability.x_mult = self.ability.x_mult + #context.cards * self.ability.extra`; 飘字 `a_xmult`, 数值用新的 `self.ability.x_mult`.
- 读取状态: `context.cards` (长度决定加几次), `self.ability.x_mult`, `self.ability.extra`.
- 备注: `#context.cards * extra` 意味着一次加入多张牌会一次加到位; 证书与大理石小丑这两处传的是 `{true}` (长度 1), 而塔罗牌与卡包等其它调用点会传真实的牌数组 (`card.lua:1217, 1338`, `button_callbacks.lua:2228, 2429`, `common_events.lua:923`), 长度就是新增张数. 加成的结算在 `context.joker_main` 通用规则 (第 3653-3671 行).

## 13. context.first_hand_drawn

入口: `game.lua:3229`, 每回合第一次摸牌时对每个小丑调用 `{first_hand_drawn = true}`. 这一段基本只做"闪烁提示", 真正的效果在后面的 context 分支里.

### 13.1 证书 / Certificate (`j_certificate`)

- 源码: 第 2463-2482 行. 原型: `config = {}` (game.lua:486).
- 触发条件: `context.first_hand_drawn`, 且 `self.ability.name == 'Certificate'`. 没有 `not context.blueprint` 检查, 也没有 `getting_sliced` 检查.
- 返回: 无.
- 副作用 (在 `G.E_MANAGER:add_event` 内):
  1. `create_playing_card({front = pseudorandom_element(G.P_CARDS, pseudoseed('cert_fr')), center = G.P_CENTERS.c_base}, G.hand, nil, nil, {G.C.SECONDARY_SET.Enhanced})`: 用随机点数花色牌面加基础中心牌, 直接放进 `G.hand`, 第 5 个参数 `colours` 让入场动画按"增强"配色.
  2. `seal_type = pseudorandom(pseudoseed('certsl'))`, 然后: `> 0.75` 给红封 (`set_seal('Red', true)`), `> 0.5` 蓝封, `> 0.25` 金封, 否则紫封. 四个区间等概率.
  3. `G.GAME.blind:debuff_card(_card)`: 让 Boss 盲注的禁用规则对新牌生效 (例如花色禁用).
  4. `G.hand:sort()` 重新排序手牌.
  5. `context.blueprint_card` 存在时由它播 `juice_up()`, 否则由 `self` 播.
  6. 事件结束后函数再调 `playing_card_joker_effects({true})`, 这会反过来触发全息影像等"新增牌"效果.
- 读取状态: `G.P_CARDS`, `G.hand`, `G.GAME.blind`, `context.blueprint_card`.
- 备注: 生成的是"带随机封印的普通牌", 没有任何增强, 只有封印; 可被蓝图, 头脑风暴复制, 因此能一次摸到两张.

### 13.2 DNA (`j_dna`)

- 源码: 第 2483-2486 行. 原型: `config = {}` (game.lua:421).
- 触发条件: `context.first_hand_drawn`, 且 `self.ability.name == 'DNA'`, 且 `not context.blueprint`.
- 返回: 无.
- 副作用: `juice_card_until(self, eval, true)`, `eval = function() return G.GAME.current_round.hands_played == 0 end` (纯视觉闪烁, 提示"本回合还没出过牌").
- 读取状态: `G.GAME.current_round.hands_played`.
- 备注: DNA 真正的复制逻辑在 `context.before` 分支 (第 3501-3524 行), 返回值用 `playing_cards_created` 提示新牌, 见 [joker-effects-02.md](<./joker-effects-02.md>). 本段这支只是动画.

### 13.3 交易卡 / Trading Card (`j_trading`)

- 源码: 第 2487-2490 行. 原型: `config = {extra = 3}` (game.lua:468), `blueprint_compat = false`.
- 触发条件: `context.first_hand_drawn`, 且 `self.ability.name == 'Trading Card'`, 且 `not context.blueprint`.
- 返回: 无.
- 副作用: `juice_card_until(self, eval, true)`, `eval = function() return G.GAME.current_round.discards_used == 0 and not G.RESET_JIGGLES end` (纯视觉闪烁, 提示"本回合还没弃过牌").
- 读取状态: `G.GAME.current_round.discards_used`, `G.RESET_JIGGLES`.
- 备注: 真正的加钱与销毁在 `context.discard` 分支 (第 2802-2812 行, 见 21.3 节).

## 14. context.setting_blind

入口: `state_events.lua:336`, 选择盲注时对每个小丑调用 `{setting_blind = true, blind = G.GAME.round_resets.blind}`. 分支条件带 `not self.getting_sliced`; 分支末尾第 2602 行无条件 `return`, 所以这里所有小丑都只改状态或排队事件, 从不返回数值 table.

两个容易混淆的对象: `context.blind` 是盲注原型 (`G.P_BLINDS` 里的条目, 用它的 `boss` 字段判断是不是 Boss); `G.GAME.blind` 是盲注实例, 在此之前第 334 行已经执行过 `G.GAME.blind:set_blind(G.GAME.round_resets.blind)`, 因此它已经代表本轮这个盲注, `disable()` 与 `debuff_card()` 都作用在它上面.

这里的 7 个小丑判定顺序固定为: 希科, 疯狂, 窃贼, 乌合之众, 卡牌术士, 仪式匕首, 大理石小丑. 因为它们都是 `if` 而不是 `elseif`, 同一张牌不会命中两个 (名字唯一), 但副作用事件的排队顺序与这个顺序一致.

### 14.1 希科 / Chicot (`j_chicot`)

- 源码: 第 2492-2502 行. 原型: `config = {}` (game.lua:525), `blueprint_compat = false`.
- 触发条件: `context.setting_blind`, 且 `not self.getting_sliced`, 且 `self.ability.name == 'Chicot'`, 且 `not context.blueprint`, 且 `context.blind.boss` 为真, 且 `not self.getting_sliced`.
- 返回: 无.
- 副作用: 排一个事件, 事件里再排一个事件: 内层执行 `G.GAME.blind:disable()` (作用于当前盲注实例), `play_sound('timpani')`, `delay(0.4)`; 外层飘字 `ph_boss_disabled`.
- 读取状态: `context.blind.boss`, `G.GAME.blind`.
- 备注: 在选择盲注时就把 Boss 盲注的负面效果关掉, 等价于"本轮 Boss 无限制条件".

### 14.2 疯狂 / Madness (`j_madness`)

- 源码: 第 2503-2521 行. 原型: `config = {extra = 0.5}` (game.lua:435).
- 触发条件: `context.setting_blind`, 且 `not self.getting_sliced`, 且 `self.ability.name == 'Madness'`, 且 `not context.blueprint`, 且 `not context.blind.boss` (只有小盲注与大盲注会成长, Boss 盲注不成长).
- 返回: 无.
- 行为与副作用:
  1. `self.ability.x_mult = self.ability.x_mult + self.ability.extra` (每个非 Boss 盲注 `X0.5`).
  2. 收集可销毁的小丑: 遍历 `G.jokers.cards`, 排除自己, `ability.eternal` 为真的, 以及 `getting_sliced` 为真的.
  3. 若列表非空, `joker_to_destroy = pseudorandom_element(destructable_jokers, pseudoseed('madness'))`; 列表为空时不消耗随机数, `joker_to_destroy = nil`. 这个"空列表不抽随机数"的细节会影响随机序列, 必须照抄.
  4. 若选中了目标, 且 `not (context.blueprint_card or self).getting_sliced`: 先把目标标记 `joker_to_destroy.getting_sliced = true`, 再排队事件, 事件里对持有者 `juice_up(0.8, 0.8)` 并让目标 `start_dissolve({G.C.RED}, nil, 1.6)`.
  5. 若 `not (context.blueprint_card or self).getting_sliced`: 飘字 `a_xmult`, 数值用新的 `self.ability.x_mult`.
- 读取状态: `self.ability.x_mult`, `self.ability.extra`, `G.jokers.cards`, `G.jokers.cards[i].ability.eternal`, `G.jokers.cards[i].getting_sliced`, `context.blind.boss`.
- 备注: 销毁目标是"相邻无关的随机一张", 与仪式匕首的"右侧紧邻"不同; `getting_sliced` 标记的作用是防止同一张牌被本回合内多次销毁.

### 14.3 窃贼 / Burglar (`j_burglar`)

- 源码: 第 2522-2528 行. 原型: `config = {extra = 3}` (game.lua:417).
- 触发条件: `context.setting_blind`, 且 `not self.getting_sliced`, 且 `self.ability.name == 'Burglar'`, 且 `not (context.blueprint_card or self).getting_sliced`. 没有 `not context.blueprint` 检查, 可以被蓝图, 头脑风暴复制.
- 返回: 无.
- 副作用 (在事件里): `ease_discard(-G.GAME.current_round.discards_left, nil, true)` 把本回合剩余弃牌数清零, `ease_hands_played(self.ability.extra)` 增加 3 次出牌次数, 然后飘字 `a_hands` 数值 `self.ability.extra`.
- 读取状态: `G.GAME.current_round.discards_left`, `self.ability.extra`.
- 备注: 增加的是"本回合的出牌次数", 不是上限; 蓝图复制会变成 +6 次出牌.

### 14.4 乌合之众 / Riff-raff (`j_riff_raff`)

- 源码: 第 2529-2544 行. 原型: `config = {extra = 2}` (game.lua:438).
- 触发条件: `context.setting_blind`, 且 `not self.getting_sliced`, 且 `self.ability.name == 'Riff-raff'`, 且 `not (context.blueprint_card or self).getting_sliced`, 且 `#G.jokers.cards + G.GAME.joker_buffer < G.jokers.config.card_limit` (小丑区有空位). 没有 `not context.blueprint` 检查.
- 返回: 无.
- 副作用:
  1. `jokers_to_create = math.min(2, G.jokers.config.card_limit - (#G.jokers.cards + G.GAME.joker_buffer))`, 上限硬编码为 2 (与 `config.extra` 无关).
  2. `G.GAME.joker_buffer = G.GAME.joker_buffer + jokers_to_create`.
  3. 事件里循环 `jokers_to_create` 次: `create_card('Joker', G.jokers, nil, 0, nil, nil, nil, 'rif')` (稀有度参数 `0` 即"普通"稀有度), `card:add_to_deck()`, `G.jokers:emplace(card)`, `card:start_materialize()`, 并把 `G.GAME.joker_buffer` 归零 (写在循环体内).
  4. 飘字 `k_plus_joker`, 颜色 `G.C.BLUE`.
- 读取状态: `#G.jokers.cards`, `G.GAME.joker_buffer`, `G.jokers.config.card_limit`.
- 备注: `key_append = 'rif'` 决定随机池的种子后缀; 因为稀有度传了 `0`, 只会出普通稀有度的小丑.

### 14.5 卡牌术士 / Cartomancer (`j_cartomancer`)

- 源码: 第 2545-2560 行. 原型: `config = {}` (game.lua:518).
- 触发条件: `context.setting_blind`, 且 `not self.getting_sliced`, 且 `self.ability.name == 'Cartomancer'`, 且 `not (context.blueprint_card or self).getting_sliced`, 且 `#G.consumeables.cards + G.GAME.consumeable_buffer < G.consumeables.config.card_limit`. 没有 `not context.blueprint` 检查.
- 返回: 无.
- 副作用: `G.GAME.consumeable_buffer = G.GAME.consumeable_buffer + 1`; 外层事件里再排一个内层事件生成 `create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, 'car')`, `card:add_to_deck()`, `G.consumeables:emplace(card)`, 缓冲归零; 飘字 `k_plus_tarot`, 颜色 `G.C.PURPLE`.
- 读取状态: `#G.consumeables.cards`, `G.GAME.consumeable_buffer`, `G.consumeables.config.card_limit`.
- 备注: 每回合(每个盲注)开始时给一张塔罗牌.

### 14.6 仪式匕首 / Ceremonial Dagger (`j_ceremonial`)

- 源码: 第 2561-2579 行. 原型: `config = {mult = 0}` (game.lua:389), 即 `self.ability.mult` 从 0 开始.
- 触发条件: `context.setting_blind`, 且 `not self.getting_sliced`, 且 `self.ability.name == 'Ceremonial Dagger'`, 且 `not context.blueprint`, 且满足下面全部:
  - `my_pos` 能找到 (自己在 `G.jokers.cards` 里的下标), 且 `G.jokers.cards[my_pos+1]` 存在 (右侧有牌), 且 `not self.getting_sliced`, 且右侧牌 `not ability.eternal`, 且右侧牌 `not getting_sliced`.
- 返回: 无.
- 副作用:
  1. `sliced_card = G.jokers.cards[my_pos+1]`; `sliced_card.getting_sliced = true`.
  2. `G.GAME.joker_buffer = G.GAME.joker_buffer - 1` (先减, 事件里再归零).
  3. 事件里: `G.GAME.joker_buffer = 0`; `self.ability.mult = self.ability.mult + sliced_card.sell_cost * 2` (注意加的是被销毁牌的 `sell_cost` 的两倍, 不是 `extra`); `self:juice_up(0.8, 0.8)`; `sliced_card:start_dissolve({HEX("57ecab")}, nil, 1.6)`; `play_sound('slice1', 0.96 + math.random() * 0.08)`.
  4. 飘字 `a_mult`, 数值用 `self.ability.mult + 2 * sliced_card.sell_cost`, 颜色 `G.C.RED`, `no_juice = true`.
- 读取状态: `G.jokers.cards` 的顺序与下标, `G.jokers.cards[my_pos+1].ability.eternal`, `getting_sliced`, `sell_cost`, `self.ability.mult`.
- 备注: `sell_cost` 会随商店通胀和卖价修正变化, 因此每次的增量可能不是固定值.

### 14.7 大理石小丑 / Marble Joker (`j_marble`)

- 源码: 第 2580-2601 行. 原型: `config = {extra = 1}` (game.lua:392), 但代码里没有用到 `extra`, 每次固定加一张.
- 触发条件: `context.setting_blind`, 且 `not self.getting_sliced`, 且 `self.ability.name == 'Marble Joker'`, 且 `not (context.blueprint_card or self).getting_sliced`. 没有 `not context.blueprint` 检查.
- 返回: 无.
- 副作用:
  1. 事件里: `front = pseudorandom_element(G.P_CARDS, pseudoseed('marb_fr'))`; `G.playing_card` 计数加 1; 直接构造 `Card(G.play.T.x + G.play.T.w/2, G.play.T.y, G.CARD_W, G.CARD_H, front, G.P_CENTERS.m_stone, {playing_card = G.playing_card})` (中心牌是石头牌 `m_stone`, 不是 `create_card`); `card:start_materialize({G.C.SECONDARY_SET.Enhanced})`; `G.play:emplace(card)`; `table.insert(G.playing_cards, card)`.
  2. 飘字 `k_plus_stone`, 颜色 `G.C.SECONDARY_SET.Enhanced`.
  3. 再排一个事件: `G.deck.config.card_limit = G.deck.config.card_limit + 1`.
  4. `draw_card(G.play, G.deck, 90, 'up', nil)` 把这张石头牌从出牌区挪进牌库 (所以它进牌库, 不是留在出牌区).
  5. 最后调用 `playing_card_joker_effects({true})`, 让全息影像等"新增牌"效果也触发.
- 读取状态: `G.P_CARDS`, `G.playing_card` 计数器, `G.play`, `G.deck.config.card_limit`.
- 备注: 石头牌是通过牌库上限 +1 的方式真正加进牌组的; `draw_card` 的第 3 个参数 90 是动画百分比, 第 4 个 `'up'` 是方向.

## 15. context.destroying_card

入口: `state_events.lua:957`, 计分过程中对每张计分牌问一遍所有小丑, 参数 `{destroying_card = scoring_hand[i], full_hand = G.play.cards}`. 返回真值表示这张牌要被销毁, 调用方 `if destroyed then break end` 会立刻停止询问后面的小丑. 分支条件本身带 `not context.blueprint`, 所以蓝图, 头脑风暴不会复制这一段.

### 15.1 第六感 / Sixth Sense (`j_sixth_sense`)

- 源码: 第 2604-2621 行. 原型: `config = {}` (game.lua:424), `blueprint_compat = false`.
- 触发条件: `context.destroying_card`, 且 `not context.blueprint`, 且 `self.ability.name == 'Sixth Sense'`, 且 `#context.full_hand == 1` (本手只打了一张牌), 且 `context.full_hand[1]:get_id() == 6` (打的是 6), 且 `G.GAME.current_round.hands_played == 0` (本回合第一手).
- 返回: `true` (要销毁这张牌); 条件不满足时返回 `nil`. 注意 `true` 在"消耗牌区没空位"的情况下也会返回, 见下.
- 副作用 (只在消耗牌区有空位时): `#G.consumeables.cards + G.GAME.consumeable_buffer < G.consumeables.config.card_limit` 成立时:
  1. `G.GAME.consumeable_buffer = G.GAME.consumeable_buffer + 1`.
  2. 事件 (`trigger = 'before'`, `delay = 0.0`) 里 `create_card('Spectral', G.consumeables, nil, nil, nil, nil, nil, 'sixth')`, `card:add_to_deck()`, `G.consumeables:emplace(card)`, 缓冲归零.
  3. 飘字 `k_plus_spectral`, 颜色 `G.C.SECONDARY_SET.Spectral`.
- 读取状态: `context.full_hand` (`G.play.cards`), `G.GAME.current_round.hands_played`, `#G.consumeables.cards`, `G.GAME.consumeable_buffer`, `G.consumeables.config.card_limit`.
- 备注:
  - 第 2619 行的 `return true` 在消耗牌区满时依然执行: 即"牌照样被销毁, 但幻灵牌生成不出来". 这一点很容易实现错.
  - 第六感销毁的是打出的那张 6, 它自己不会被销毁.
  - 拆解顺序上, 这个判定在玻璃牌碎裂判定 (同文件 962 行) 之前, 并且 `break` 会阻止后面的小丑再被问.

## 16. context.cards_destroyed

第 2622-2671 行. 进入条件 `context.cards_destroyed`, 读取 `context.glass_shattered` (被销毁的牌列表, 用 `shattered` 标记哪些是玻璃牌碎裂).

可达性说明: 本仓库全部 Lua (含 `mods/`) 里没有任何地方把 `cards_destroyed` 或 `glass_shattered` 放进传给 `calculate_joker` 的 context, 所以这个分支在当前版本不会被触发 (原版真正的销毁通知走下一节的 `remove_playing_cards`). 下面是代码本来的行为, 供对齐时参考.

### 16.1 卡尼奥 / Caino (`j_caino`)

- 源码: 第 2623-2646 行. 原型: `config = {extra = 1}` (game.lua:522). 成长字段是 `self.ability.caino_xmult`, 在 `Card:set_ability` 第 325 行初始化为 1 (不是 `x_mult`).
- 触发条件: `context.cards_destroyed`, 且 `self.ability.name == 'Caino'`, 且 `not context.blueprint`, 且 `context.glass_shattered` 里至少有一张 `is_face()` 为真的牌.
- 返回: 无 (`return`, 即 `nil`).
- 副作用: 双层嵌套事件里执行 `self.ability.caino_xmult = self.ability.caino_xmult + faces * self.ability.extra`; 飘字 `a_xmult`, 数值用 `self.ability.caino_xmult + faces * self.ability.extra`.
- 读取状态: `context.glass_shattered` 的长度与牌面, `self.ability.caino_xmult`, `self.ability.extra`.
- 备注: 统计条件 `v:is_face()` 表示 J, Q, K (含被其它效果改过 id 的情况), 与人头无关的牌不计.

### 16.2 玻璃小丑 / Glass Joker (`j_glass`)

- 源码: 第 2647-2670 行. 原型: `config = {extra = 0.75, Xmult = 1}` (game.lua:494), 即 `self.ability.x_mult` 从 1 开始.
- 触发条件: `context.cards_destroyed`, 且 `self.ability.name == 'Glass Joker'`, 且 `not context.blueprint`, 且 `context.glass_shattered` 里至少有一张 `shattered` 为真的牌.
- 返回: 无 (`return`, 即 `nil`).
- 副作用: 双层嵌套事件里 `self.ability.x_mult = self.ability.x_mult + self.ability.extra * glasses`; 飘字 `a_xmult`, 数值用 `self.ability.x_mult + self.ability.extra * glasses`.
- 读取状态: `context.glass_shattered` 里各牌的 `shattered`, `self.ability.x_mult`, `self.ability.extra`.
- 备注: 用 `shattered` 过滤, 所以非玻璃牌被销毁时不计.

## 17. context.remove_playing_cards

入口: `state_events.lua:426` (弃牌时销毁) 与 `state_events.lua:975` (计分时销毁), 参数 `{cardarea = G.jokers, remove_playing_cards = true, removed = <被销毁的牌列表>}`. 这是本版本真正会走到的"销毁通知"分支. 两个小丑的判定都用 `not context.blueprint` 保护.

注意: 同一个销毁批次可能会同时走 `destroying_card` (第六感, 在销毁之前) 和 `remove_playing_cards` (销毁之后), 但两者语义完全不同.

### 17.1 卡尼奥 / Caino (`j_caino`)

- 源码: 第 2673-2685 行.
- 触发条件: `context.remove_playing_cards`, 且 `self.ability.name == 'Caino'`, 且 `not context.blueprint`, 且 `context.removed` 里至少有一张 `is_face()` 为真的牌.
- 返回: 无.
- 副作用: `self.ability.caino_xmult = self.ability.caino_xmult + face_cards * self.ability.extra` 立即执行 (不放在事件里); 只排一个飘字事件, 数值用累加后的 `self.ability.caino_xmult`.
- 读取状态: `context.removed` 里各牌的 `is_face()`, `self.ability.caino_xmult`, `self.ability.extra`.
- 备注: 与 16.1 的区别有三处: 列表字段是 `removed` 而不是 `glass_shattered`, 判断是 `is_face()` 而不是 `shattered`, 数值累加是立即执行. 计分侧额外的 `Xmult_mod` 结算在 `context.joker_main` 默认分支 (第 4052-4057 行).

### 17.2 玻璃小丑 / Glass Joker (`j_glass`)

- 源码: 第 2687-2707 行.
- 触发条件: `context.remove_playing_cards`, 且 `self.ability.name == 'Glass Joker'`, 且 `not context.blueprint`, 且 `context.removed` 里至少有一张 `shattered` 为真的牌.
- 返回: 无.
- 副作用: 双层嵌套事件里 `self.ability.x_mult = self.ability.x_mult + self.ability.extra * glass_cards`; 飘字 `a_xmult`, 数值用 `self.ability.x_mult + self.ability.extra * glass_cards`.
- 读取状态: `context.removed` 里各牌的 `shattered`, `self.ability.x_mult`, `self.ability.extra`.

## 18. context.using_consumeable

入口: `button_callbacks.lua:2220`, 使用消耗牌时对每个小丑调用 `{using_consumeable = true, consumeable = card}` (`context.consumeable` 是被使用的那张牌). 分支末尾第 2734 行无条件 `return`.

判定顺序: 玻璃小丑 (用"绞刑架"), 占卜师 (塔罗), 星座 (星球).

### 18.1 玻璃小丑 / Glass Joker (`j_glass`)

- 源码: 第 2709-2721 行.
- 触发条件: `context.using_consumeable`, 且 `self.ability.name == 'Glass Joker'`, 且 `not context.blueprint`, 且 `context.consumeable.ability.name == 'The Hanged Man'` (绞刑架).
- 返回: 无.
- 副作用: 统计 `G.hand.highlighted` 里 `ability.name == 'Glass Card'` 的牌数 `shattered_glass`; 若大于 0, 则 `self.ability.x_mult = self.ability.x_mult + self.ability.extra * shattered_glass` (每张玻璃牌 `X0.75`), 并飘字 `a_xmult`, 数值用累加后的 `self.ability.x_mult`.
- 读取状态: `context.consumeable.ability.name`, `G.hand.highlighted` 里各牌的 `ability.name`, `self.ability.x_mult`, `self.ability.extra`.
- 备注: 这里看的是"高亮的牌", 即玩家用绞刑架实际指定的那些牌, 不是最终被销毁的结果.

### 18.2 占卜师 / Fortune Teller (`j_fortune_teller`)

- 源码: 第 2722-2726 行. 原型: `config = {extra = 1}` (game.lua:458), 即每用一张塔罗 `+1` 倍率.
- 触发条件: `context.using_consumeable`, 且 `self.ability.name == 'Fortune Teller'`, 且 `not context.blueprint`, 且 `context.consumeable.ability.set == "Tarot"`.
- 返回: 无.
- 副作用: 只排一个飘字事件, 数值用 `G.GAME.consumeable_usage_total.tarot` (累计用过的塔罗数量).
- 读取状态: `context.consumeable.ability.set`, `G.GAME.consumeable_usage_total.tarot`.
- 备注: 本分支不改任何状态, 真正的加值在 `context.joker_main` 默认分支 (第 4016-4021 行) 按 `G.GAME.consumeable_usage_total.tarot - 1 + ...` 计算, 见 [joker-effects-02.md](<./joker-effects-02.md>). 因为不检查 `context.blueprint` 之外的持久状态, 蓝图复制只影响飘字.

### 18.3 星座 / Constellation (`j_constellation`)

- 源码: 第 2727-2733 行. 原型: `config = {extra = 0.1, Xmult = 1}` (game.lua:425), 即 `self.ability.x_mult` 从 1 开始, 每张星球牌 `+0.1`.
- 触发条件: `context.using_consumeable`, 且 `self.ability.name == 'Constellation'`, 且 `not context.blueprint`, 且 `context.consumeable.ability.set == 'Planet'`.
- 返回: 无 (直接 `return`).
- 副作用: `self.ability.x_mult = self.ability.x_mult + self.ability.extra`; 飘字 `a_xmult`, 数值用新的 `self.ability.x_mult`.
- 读取状态: `context.consumeable.ability.set`, `self.ability.x_mult`, `self.ability.extra`.
- 备注: 判断用的是 `ability.set == 'Planet'`, 所以"黑洞"之类的星球牌也算; 加成的结算在 `context.joker_main` 通用规则 (第 3653-3671 行).

## 19. context.debuffed_hand

入口: `state_events.lua:1020`, 只在"打出的牌型被 Boss 盲注整个禁用"时进入, 参数带 `debuffed_hand = true`, `cardarea = G.jokers`.

### 19.1 斗牛士 / Matador (`j_matador`)

- 源码: 第 2736-2747 行. 原型: `config = {extra = 8}` (game.lua:504), 即每次 `$8`.
- 触发条件: `context.debuffed_hand`, 且 `self.ability.name == 'Matador'`, 且 `G.GAME.blind.triggered` 为真.
  - `G.GAME.blind.triggered` 由 `game/blind.lua` 里的 Boss 盲注在它的压制效果真的生效时置为真 (例如"钩子"强制弃牌, "公牛"清空资金等), 见 `blind.lua:484, 490, 505, 513, 524, 532, 537, 544, 553`.
- 返回: `{message = localize('$')..self.ability.extra, dollars = self.ability.extra, colour = G.C.MONEY}` (即 `dollars = 8`).
- 副作用 (在返回之前):
  1. `ease_dollars(self.ability.extra)` 立刻加钱.
  2. `G.GAME.dollar_buffer = (G.GAME.dollar_buffer or 0) + self.ability.extra`, 再排一个事件把 `dollar_buffer` 归零 (`G.GAME.dollar_buffer` 是"即将到账的金额"显示缓冲, 用来避免飘字与余额不同步).
- 读取状态: `G.GAME.blind.triggered`, `self.ability.extra`, `G.GAME.dollar_buffer`.
- 备注: 没有 `not context.blueprint` 检查, 蓝图, 头脑风暴可以复制, 于是同一次禁用会加两次 `$8`; 注意这里的加钱与返回值里的 `dollars` 是两条路径 (调用方 `card_eval_status_text` 只做飘字, 不会再加一次钱).

## 20. context.pre_discard

入口: `state_events.lua:395`, 玩家确认弃牌后, 真正把牌移走之前对每个小丑调用 `{pre_discard = true, full_hand = G.hand.highlighted, hook = hook}`. `hook` 为真表示这次弃牌是 Boss 盲注"钩子"强制触发的, 不是玩家弃牌.

### 20.1 烧焦小丑 / Burnt Joker (`j_burnt`)

- 源码: 第 2749-2755 行. 原型: `config = {h_size = 0, extra = 4}` (game.lua:520). 本分支里 `extra` 没有被使用, 升级量硬编码为 1 级.
- 触发条件: `context.pre_discard`, 且 `self.ability.name == 'Burnt Joker'`, 且 `G.GAME.current_round.discards_used <= 0` (本回合还没弃过牌), 且 `not context.hook`. 没有 `not context.blueprint` 检查.
- 返回: 无.
- 副作用:
  1. `local text, disp_text = G.FUNCS.get_poker_hand_info(G.hand.highlighted)`: 按当前高亮的牌算出牌型英文键 `text` (例如 `"Pair"`), 找不到牌型时是 `"NULL"`.
  2. 飘字 `k_upgrade_ex` (`context.blueprint_card or self`).
  3. `update_hand_text({sound = 'button', volume = 0.7, pitch = 0.8, delay = 0.3}, {handname = ..., chips = ..., mult = ..., level = ...})` 更新界面上的牌型显示.
  4. `level_up_hand(context.blueprint_card or self, text, nil, 1)`: 把这个牌型升 1 级. `level_up_hand` (common_events.lua:464) 会改 `G.GAME.hands[hand].level`, 并重算 `mult = max(s_mult + l_mult*(level-1), 1)` 与 `chips = max(s_chips + l_chips*(level-1), 0)`, 同时播放音效并让传入的卡牌跳一下.
  5. 再一次 `update_hand_text(...)` 把界面上的临时数字清掉.
- 读取状态: `G.hand.highlighted`, `G.GAME.current_round.discards_used`, `G.GAME.hands[text]`, `context.hook`.
- 备注: "每回合第一次弃牌"用 `discards_used <= 0` 判断, 而不是"第一次弃牌动作的每张牌", 因此一次弃多张牌时这个分支会被调用多次 (每张被弃的牌一次), 结果是牌型被升了多次. 蓝图, 头脑风暴会让升级再多一次.

## 21. context.discard

入口: `state_events.lua:404`, 对本次弃牌里每一张高亮的牌, 按 `G.jokers.cards` 的顺序问每个小丑 `{discard = true, other_card = G.hand.highlighted[i], full_hand = G.hand.highlighted}`. 因此: 弃 N 张牌时, 每个小丑会被调用 N 次; 每次 `context.other_card` 是当前这一张, `context.full_hand` 是整批高亮的牌 (顺序与手牌排列一致).

返回值里 `remove = true` 会让这张被弃的牌被销毁而不是进弃牌堆 (`state_events.lua:406-419`). 分支末尾第 2873 行无条件 `return`.

判定顺序 (在每位小丑内部): 拉面, 约里克, 交易卡, 城堡, 邮件回扣, 上路吧杰克, 绿色小丑, 无面小丑.

### 21.1 拉面 / Ramen (`j_ramen`)

- 源码: 第 2757-2787 行. 原型: `config = {Xmult = 2, extra = 0.01}` (game.lua:473), 即 `self.ability.x_mult` 初始为 2, 每次弃牌减 0.01.
- 触发条件: `context.discard`, 且 `self.ability.name == 'Ramen'`, 且 `not context.blueprint`.
- 分支 A: `self.ability.x_mult - self.ability.extra <= 1` (再减一次就要到 1 或更低):
  - 排队事件: `play_sound('tarot1')`, `self.T.r = -0.2`, `self:juice_up(0.3, 0.4)`, `self.states.drag.is = true`, `self.children.center.pinch.x = true`, 然后在该事件内部再排一个 `trigger = 'after', delay = 0.3, blockable = false` 的事件: `G.jokers:remove_card(self)`, `self:remove()`, `self = nil` (即把小丑真正从牌区移除).
  - 返回: `{message = localize('k_eaten_ex'), colour = G.C.FILTER}` (没有数值字段).
  - 这里不减 `x_mult`.
- 分支 B: 否则 `self.ability.x_mult = self.ability.x_mult - self.ability.extra`; 返回 `{delay = 0.2, message = localize{type = 'variable', key = 'a_xmult_minus', vars = {self.ability.extra}}, colour = G.C.RED}`.
- 读取状态: `self.ability.x_mult`, `self.ability.extra`, `self.T`, `self.children`, `G.jokers`.
- 备注: 比较用的是"减完后的值 `<= 1`", 由于是浮点累减, 实现时要用同样的判据 (`x_mult - extra <= 1`), 不要写成 `x_mult <= 1 + extra` 之外的其它等价式后取整.

### 21.2 约里克 / Yorick (`j_yorick`)

- 源码: 第 2788-2801 行. 原型: `config = {extra = {xmult = 1, discards = 23}}` (game.lua:524); `self.ability.yorick_discards` 在 `Card:set_ability` 第 328 行初始化为 `extra.discards` (23).
- 触发条件: `context.discard`, 且 `self.ability.name == 'Yorick'`, 且 `not context.blueprint`.
- 分支 A: `self.ability.yorick_discards <= 1`:
  - `self.ability.yorick_discards = self.ability.extra.discards` (重置为 23).
  - `self.ability.x_mult = self.ability.x_mult + self.ability.extra.xmult` (永久 `X1`).
  - 返回 `{delay = 0.2, message = localize{type = 'variable', key = 'a_xmult', vars = {self.ability.x_mult}}, colour = G.C.RED}`.
- 分支 B: 否则 `self.ability.yorick_discards = self.ability.yorick_discards - 1`.
- 两个分支都会走到第 2800 行的 `return`, 返回 `nil`.
- 读取状态: `self.ability.yorick_discards`, `self.ability.extra`, `self.ability.x_mult`.
- 备注: 计数器是"还需弃多少张牌"; 由于每张被弃的牌都调用一次, 弃 5 张就消耗 5 点计数.

### 21.3 交易卡 / Trading Card (`j_trading`)

- 源码: 第 2802-2812 行. 原型: `config = {extra = 3}` (game.lua:468), `blueprint_compat = false`.
- 触发条件: `context.discard`, 且 `self.ability.name == 'Trading Card'`, 且 `not context.blueprint`, 且 `G.GAME.current_round.discards_used <= 0` (本回合第一次弃牌), 且 `#context.full_hand == 1` (这次只弃了一张牌).
- 返回: `{message = localize('$')..self.ability.extra, colour = G.C.MONEY, delay = 0.45, remove = true, card = self}`, 即 `remove = true` 会把被弃的那张牌直接销毁 (不进弃牌堆).
- 副作用: `ease_dollars(self.ability.extra)` 立即加 `$3`.
- 读取状态: `G.GAME.current_round.discards_used`, `context.full_hand`, `self.ability.extra`.
- 备注: `card = self` 只是让飘字对齐到小丑本身; 被销毁的是打出的那张牌, 不是交易卡.

### 21.4 城堡 / Castle (`j_castle`)

- 源码: 第 2814-2824 行. 原型: `config = {extra = {chips = 0, chip_mod = 3}}` (game.lua:476).
- 触发条件: `context.discard`, 且 `self.ability.name == 'Castle'`, 且 `not context.other_card.debuff` (被弃的牌没被禁用), 且 `context.other_card:is_suit(G.GAME.current_round.castle_card.suit)`, 且 `not context.blueprint`.
- 副作用: `self.ability.extra.chips = self.ability.extra.chips + self.ability.extra.chip_mod` (每弃一张目标花色的牌 +3 筹码).
- 返回: `{message = localize('k_upgrade_ex'), card = self, colour = G.C.CHIPS}`.
- 读取状态: `context.other_card` 的 `debuff` 与花色, `G.GAME.current_round.castle_card.suit`, `self.ability.extra`.
- 备注: `castle_card.suit` 由 `reset_castle_card()` 每回合重抽 (回合结束时调用, 见 `state_events.lua:285`); 筹码结算在 `context.joker_main` 默认分支 (第 3880-3885 行).

### 21.5 邮件回扣 / Mail-In Rebate (`j_mail`)

- 源码: 第 2825-2834 行. 原型: `config = {extra = 5}` (game.lua:455).
- 触发条件: `context.discard`, 且 `self.ability.name == 'Mail-In Rebate'`, 且 `not context.other_card.debuff`, 且 `context.other_card:get_id() == G.GAME.current_round.mail_card.id`.
- 返回: `{message = localize('$')..self.ability.extra, colour = G.C.MONEY, card = self}`.
- 副作用: `ease_dollars(self.ability.extra)` 立即加 `$5`.
- 读取状态: `context.other_card` 的 `debuff` 与 id, `G.GAME.current_round.mail_card.id`, `self.ability.extra`.
- 备注: 没有 `not context.blueprint` 检查, 蓝图, 头脑风暴可以再拿一次 `$5`; `mail_card` 由 `reset_mail_rank()` 每回合重抽.

### 21.6 上路吧杰克 / Hit the Road (`j_hit_the_road`)

- 源码: 第 2835-2845 行. 原型: `config = {extra = 0.5}` (game.lua:505).
- 触发条件: `context.discard`, 且 `self.ability.name == 'Hit the Road'`, 且 `not context.other_card.debuff`, 且 `context.other_card:get_id() == 11` (J), 且 `not context.blueprint`.
- 副作用: `self.ability.x_mult = self.ability.x_mult + self.ability.extra` (每弃一张 J `X0.5`).
- 返回: `{message = localize{type = 'variable', key = 'a_xmult', vars = {self.ability.x_mult}}, colour = G.C.RED, delay = 0.45, card = self}`.
- 读取状态: `context.other_card` 的 `debuff` 与 id, `self.ability.x_mult`, `self.ability.extra`.
- 备注: 因为按牌触发, 一次弃 4 张 J 就是 `X2`; 重置在回合结束 (见 22.10 节).

### 21.7 绿色小丑 / Green Joker (`j_green_joker`)

- 源码: 第 2846-2856 行. 原型: `config = {extra = {hand_add = 1, discard_sub = 1}}` (game.lua:428).
- 触发条件: `context.discard`, 且 `self.ability.name == 'Green Joker'`, 且 `not context.blueprint`, 且 `context.other_card == context.full_hand[#context.full_hand]` (只有整批弃牌里的最后一张会命中).
- 行为: `prev_mult = self.ability.mult`; `self.ability.mult = math.max(0, self.ability.mult - self.ability.extra.discard_sub)`; 若数值变了, 返回 `{message = localize{type = 'variable', key = 'a_mult_minus', vars = {self.ability.extra.discard_sub}}, colour = G.C.RED, card = self}`; 已经是 0 时返回 `nil`.
- 读取状态: `context.other_card`, `context.full_hand`, `self.ability.mult`, `self.ability.extra.discard_sub`.
- 备注: 弃牌侧只减不增, `-1` 每次弃牌只发生一次 (靠"最后一张牌"去重); 出牌侧的 `+1` 在 `context.before` 的第 3563-3569 行.

### 21.8 无面小丑 / Faceless Joker (`j_faceless`)

- 源码: 第 2858-2872 行. 原型: `config = {extra = {dollars = 5, faces = 3}}` (game.lua:427).
- 触发条件: `context.discard`, 且 `self.ability.name == 'Faceless Joker'`, 且 `context.other_card == context.full_hand[#context.full_hand]` (只在整批弃牌的最后一张上判定). 没有 `not context.blueprint` 检查.
- 行为: 统计 `context.full_hand` 里 `is_face()` 为真的张数; 若 `>= self.ability.extra.faces` (3):
  - 排队事件: `ease_dollars(self.ability.extra.dollars)` (加 `$5`) 加飘字 (`localize('$')..5`, 颜色 `G.C.MONEY`, `delay = 0.45`).
  - 然后 `return` (返回 `nil`).
- 读取状态: `context.full_hand` 各牌的 `is_face()`, `context.other_card`, `self.ability.extra`.
- 备注: 一次弃牌最多触发一次 (因为只看最后一张); 加钱是延后到事件里执行的; 可被蓝图, 头脑风暴复制.

## 22. context.end_of_round

入口有三个, 对应三种子语义:

1. `state_events.lua:101`, 每个小丑一次 `{end_of_round = true, game_over = game_over}`, 走"主效果"分支 (`context.end_of_round` 且没有 `individual` / `repetition`).
2. `state_events.lua:183`, 手里每张牌 `{cardarea = G.hand, other_card = ..., individual = true, end_of_round = true}`, 走 `context.individual` 子分支.
3. `state_events.lua:202`, 手里每张牌 `{cardarea = G.hand, other_card = ..., repetition = true, end_of_round = true, card_effects = effects}`, 走 `context.repetition` 子分支.

本段的结构是: `context.individual` 子分支为空 (本段没有任何小丑在"回合结束 + individual"里做事); `context.repetition` 子分支只处理手牌区 (`context.cardarea == G.hand`) 的哑剧演员; 其余全部进入 `elseif not context.blueprint then` 的大块, 该块的守卫是 `not context.blueprint`, 所以里面所有小丑都不会被蓝图, 头脑风暴复制.

主效果块的执行顺序: 篝火, 火箭, 黑龟豆, 隐形小丑, 爆米花, 待办清单, 鸡蛋, 礼品卡, 上路吧杰克, 大麦克香蕉/卡文迪什, 骷髅先生, 每个命中即返回. 注意 `context.end_of_round` 里 `game_over` 由调用方传入 (`G.GAME.chips - G.GAME.blind.chips >= 0` 时为 false), `G.RESET_JIGGLES` 在这个循环开始时已被置为真 (`state_events.lua:96`).

### 22.1 哑剧演员 / Mime (`j_mime`)

- 源码: 第 2879-2886 行. 原型: `config = {extra = 1}` (game.lua:387).
- 触发条件: `context.end_of_round`, 且 `context.repetition`, 且 `context.cardarea == G.hand`, 且 `self.ability.name == 'Mime'`, 且 `(next(context.card_effects[1]) or #context.card_effects > 1)`. 没有 `not context.blueprint` 检查.
- 返回: `{message = localize('k_again_ex'), repetitions = self.ability.extra, card = self}`. 注意字段名是 `repetitions` (复数).
- 读取状态: `context.card_effects` (这张手牌本次已经收集到的效果列表: 第 1 项来自牌自身 `Card:get_end_of_round_effect`, 后面依次是小丑的 `individual` 返回值).
- 备注: 条件的意思是"手里这张牌确实有若干效果", 没有效果的牌不会被重复; 调用方用 `eval.jokers.repetitions` 追加重复次数 (`state_events.lua:202-206`); 蓝图, 头脑风暴会让重复次数再加 1 (因为它没有 `not context.blueprint` 守卫). 非回合结束的 `context.repetition` 分支在第 3387-3393 行, 见 [joker-effects-02.md](<./joker-effects-02.md>).

### 22.2 篝火 / Campfire (`j_campfire`)

- 源码: 第 2889-2895 行.
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint`, 且 `self.ability.name == 'Campfire'`, 且 `G.GAME.blind.boss`, 且 `self.ability.x_mult > 1`.
- 返回: `{message = localize('k_reset'), colour = G.C.RED}`.
- 副作用: `self.ability.x_mult = 1` (打完 Boss 盲注后归零).
- 读取状态: `G.GAME.blind.boss`, `self.ability.x_mult`.
- 备注: 满值也为 1 时不返回任何东西 (不飘字); 成长在 7.1 节 (每卖一张牌 `+0.25`).

### 22.3 火箭 / Rocket (`j_rocket`)

- 源码: 第 2896-2902 行. 原型: `config = {extra = {dollars = 1, increase = 2}}` (game.lua:445), `blueprint_compat = false`.
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint`, 且 `self.ability.name == 'Rocket'`, 且 `G.GAME.blind.boss`.
- 返回: `{message = localize('k_upgrade_ex'), colour = G.C.MONEY}`.
- 副作用: `self.ability.extra.dollars = self.ability.extra.dollars + self.ability.extra.increase` (每次打完 Boss, 下回合起每回合多 `$2`).
- 读取状态: `G.GAME.blind.boss`, `self.ability.extra`.
- 备注: 本分支只成长, 真正的发钱在 `Card:calculate_dollar_bonus` (第 1664-1666 行) 返回 `self.ability.extra.dollars`.

### 22.4 黑龟豆 / Turtle Bean (`j_turtle_bean`)

- 源码: 第 2903-2933 行. 原型: `config = {extra = {h_size = 5, h_mod = 1}}` (game.lua:452), `blueprint_compat = false`.
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint` (外层块 + 内层重复判断), 且 `self.ability.name == 'Turtle Bean'`.
- 分支 A: `self.ability.extra.h_size - self.ability.extra.h_mod <= 0`: 吃自己, 事件结构与拉面相同 (`play_sound('tarot1')`, `self.T.r = -0.2`, `juice_up(0.3, 0.4)`, `states.drag.is`, `children.center.pinch.x`, 再排 `delay = 0.3, blockable = false` 的事件执行 `G.jokers:remove_card(self)`, `self:remove()`, `self = nil`); 返回 `{message = localize('k_eaten_ex'), colour = G.C.FILTER}`.
- 分支 B: 否则 `self.ability.extra.h_size = self.ability.extra.h_size - self.ability.extra.h_mod`; `G.hand:change_size(-self.ability.extra.h_mod)`; 返回 `{message = localize{type = 'variable', key = 'a_handsize_minus', vars = {self.ability.extra.h_mod}}, colour = G.C.FILTER}`.
- 读取状态: `self.ability.extra.h_size`, `self.ability.extra.h_mod`, `G.hand`.
- 备注: `CardArea:change_size` (cardarea.lua:94-111) 改的是持久的 `config.real_card_limit` 与 `config.card_limit`, 所以每回合 -1 是永久减手牌上限, 不是本回合临时效果; 减到 `h_size - h_mod <= 0` 时自毁.

### 22.5 隐形小丑 / Invisible Joker (`j_invisible`)

- 源码: 第 2934-2944 行.
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint` (外层块 + 内层重复判断), 且 `self.ability.name == 'Invisible Joker'`.
- 行为: `self.ability.invis_rounds = self.ability.invis_rounds + 1`; 若 `self.ability.invis_rounds == self.ability.extra` (刚到 2) 则 `juice_card_until(self, function(card) return not card.REMOVED end, true)` (视觉提示"已就绪").
- 返回: `{message = (self.ability.invis_rounds < self.ability.extra) and (self.ability.invis_rounds..'/'..self.ability.extra) or localize('k_active_ex'), colour = G.C.FILTER}`. 即未满时飘字形如 `1/2`, 满时飘 `k_active_ex` (激活).
- 读取状态: `self.ability.invis_rounds`, `self.ability.extra`.
- 备注: 与 6.3 节的卖出效果配套: 回合数达标后再卖出才会复制一张小丑; 计数只增不清零 (除复制体初始化为 0).

### 22.6 爆米花 / Popcorn (`j_popcorn`)

- 源码: 第 2945-2974 行. 原型: `config = {mult = 20, extra = 4}` (game.lua:470), 即 `self.ability.mult` 初始 20, 每回合 -4.
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint` (外层块 + 内层重复判断), 且 `self.ability.name == 'Popcorn'`.
- 分支 A: `self.ability.mult - self.ability.extra <= 0`: 吃自己 (事件结构同黑龟豆); 返回 `{message = localize('k_eaten_ex'), colour = G.C.RED}`.
- 分支 B: 否则 `self.ability.mult = self.ability.mult - self.ability.extra`; 返回 `{message = localize{type = 'variable', key = 'a_mult_minus', vars = {self.ability.extra}}, colour = G.C.MULT}`.
- 读取状态: `self.ability.mult`, `self.ability.extra`.
- 备注: 倍率结算在 `context.joker_main` 默认分支 (第 4004-4008 行).

### 22.7 待办清单 / To Do List (`j_todo_list`)

- 源码: 第 2975-2984 行. 原型: `config = {extra = {dollars = 4, poker_hand = 'High Card'}}` (game.lua:430).
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint` (外层块 + 内层重复判断), 且 `self.ability.name == 'To Do List'`.
- 行为: 遍历 `G.handlist`, 收集满足 `G.GAME.hands[k]` 存在, `G.GAME.hands[k].visible` 为真, 且 `k ~= self.ability.to_do_poker_hand` 的牌型键; 然后 `self.ability.to_do_poker_hand = pseudorandom_element(_poker_hands, pseudoseed('to_do'))`.
- 返回: `{message = localize('k_reset')}`.
- 读取状态: `G.handlist`, `G.GAME.hands[k].visible`, `self.ability.to_do_poker_hand`.
- 备注: 每回合结束都重抽目标, 且一定和上一回合的目标不同 (排除式); 抽签用固定种子 `'to_do'`, `pseudorandom_element` 会先把候选列表按 key 排序再取随机下标 (misc_functions.lua:253-268). 真正的发钱在 `context.before` (第 3491-3500 行).

### 22.8 鸡蛋 / Egg (`j_egg`)

- 源码: 第 2985-2992 行. 原型: `config = {extra = 3}` (game.lua:416), `blueprint_compat = false`.
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint` (外层块), 且 `self.ability.name == 'Egg'`.
- 返回: `{message = localize('k_val_up'), colour = G.C.MONEY}`.
- 副作用: `self.ability.extra_value = self.ability.extra_value + self.ability.extra` (售价 +3), 然后 `self:set_cost()` 重算 `cost` 与 `sell_cost`.
- 读取状态: `self.ability.extra_value`, `self.ability.extra`.
- 备注: 只给鸡蛋自己加价, 与礼品卡 (给全场加价) 区分开.

### 22.9 礼品卡 / Gift Card (`j_gift`)

- 源码: 第 2993-3010 行. 原型: `config = {extra = 1}` (game.lua:451), `blueprint_compat = false`.
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint` (外层块), 且 `self.ability.name == 'Gift Card'`.
- 返回: `{message = localize('k_val_up'), colour = G.C.MONEY}`.
- 副作用: 遍历 `G.jokers.cards` 与 `G.consumeables.cards`, 对有 `set_cost` 方法的牌执行 `v.ability.extra_value = (v.ability.extra_value or 0) + self.ability.extra` 并 `v:set_cost()`. 因为 `G.jokers.cards` 包含礼品卡自己, 所以它自己也会 +1.
- 读取状态: `G.jokers.cards`, `G.consumeables.cards`, `v.ability.extra_value`, `self.ability.extra`.
- 备注: 只影响售价, 不影响效果; 对消耗牌也生效.

### 22.10 上路吧杰克 / Hit the Road (`j_hit_the_road`)

- 源码: 第 3011-3017 行.
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint` (外层块), 且 `self.ability.name == 'Hit the Road'`, 且 `self.ability.x_mult > 1`.
- 返回: `{message = localize('k_reset'), colour = G.C.RED}`.
- 副作用: `self.ability.x_mult = 1`.
- 读取状态: `self.ability.x_mult`.
- 备注: 与 21.6 节配合: 本回合弃几张 J 就涨几倍, 回合结束回到 1; 若 `x_mult` 已经是 1 则不飘字.

### 22.11 大麦克香蕉 / Gros Michel (`j_gros_michel`) 与 卡文迪什 / Cavendish (`j_cavendish`)

- 源码: 第 3019-3046 行 (两者共用一段). 原型: 大麦克 `config = {extra = {odds = 6, mult = 15}}` (game.lua:407); 卡文迪什 `config = {extra = {odds = 1000, Xmult = 3}}` (game.lua:432).
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint` (外层块), 且 `self.ability.name == 'Gros Michel'` 或 `'Cavendish'`.
- 概率判定: `pseudorandom(self.ability.name == 'Cavendish' and 'cavendish' or 'gros_michel') < G.GAME.probabilities.normal / self.ability.extra.odds`. 即大麦克每次 `1/6` 概率被吃掉, 卡文迪什每次 `1/1000`.
- 命中 (被吃) 分支:
  1. 排队事件: `play_sound('tarot1')`, `self.T.r = -0.2`, `self:juice_up(0.3, 0.4)`, `self.states.drag.is = true`, `self.children.center.pinch.x = true`, 内部再排 `trigger = 'after', delay = 0.3, blockable = false` 的事件执行 `G.jokers:remove_card(self)`, `self:remove()`, `self = nil`.
  2. 若 `self.ability.name == 'Gros Michel'` 则 `G.GAME.pool_flags.gros_michel_extinct = true` (大麦克从卡池里绝迹).
  3. 返回 `{message = localize('k_extinct_ex')}`.
- 未命中分支: 返回 `{message = localize('k_safe_ex')}`.
- 读取状态: `self.ability.name`, `self.ability.extra.odds`, `G.GAME.probabilities.normal`, `G.GAME.pool_flags`.
- 备注: 两个随机种子是固定字符串 `'cavendish'` 与 `'gros_michel'`; 大麦克的 `extra.mult` (15) 与卡文迪什的 `extra.Xmult` (3) 在本段没用到, 它们分别在 `context.joker_main` 的第 4022-4027 行与 4028-4033 行结算.

### 22.12 骷髅先生 / Mr. Bones (`j_mr_bones`)

- 源码: 第 3047-3063 行. 原型: `config = {}` (game.lua:481), `blueprint_compat = false`, `eternal_compat = false`.
- 触发条件: `context.end_of_round` (主效果), 且 `not context.blueprint` (外层块), 且 `self.ability.name == 'Mr. Bones'`, 且 `context.game_over` 为真, 且 `G.GAME.chips / G.GAME.blind.chips >= 0.25` (分数至少达到盲注要求的 25%).
- 返回: `{message = localize('k_saved_ex'), saved = true, colour = G.C.RED}`.
- 副作用: 排队事件: `G.hand_text_area.blind_chips:juice_up()`, `G.hand_text_area.game_chips:juice_up()`, `play_sound('tarot1')`, `self:start_dissolve()` (自毁).
- 读取状态: `context.game_over`, `G.GAME.chips`, `G.GAME.blind.chips`.
- 备注: 调用方 (state_events.lua:104-106) 见到 `saved` 就把 `game_over` 改回 false, 于是这一局不结束; 条件是"盲注未完成但差距不超过 75%".

## 23. context.individual (cardarea == G.play)

入口: `state_events.lua:695`, 每张计分牌在每一轮重复结算时对每个小丑调用 `{cardarea = G.play, full_hand = G.play.cards, scoring_hand = scoring_hand, scoring_name = text, poker_hands = poker_hands, other_card = scoring_hand[i], individual = true}`.

返回字段的消费方式 (`state_events.lua:704-756`): `chips` 加成到本手筹码, `mult` 加成到本手倍率, `dollars` 直接加钱, `x_mult` 乘到本手倍率, `extra` 里的 `mult_mod` / `chip_mod` / `swap` 会改本手数值, 而 `extra.func()` 会被直接调用.

本文件只覆盖到第 3100 行, 因此这一段只写完前 4 个 (照片的返回语句跨过第 3100 行, 这里一并写全), 第 3106 行起的八号球属于姊妹文件范围, 列在最后一节以免断档.

### 23.1 徒步者 / Hiker (`j_hiker`)

- 源码: 第 3067-3075 行. 原型: `config = {extra = 5}` (game.lua:426).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `self.ability.name == 'Hiker'`. 没有 `not context.blueprint` 检查.
- 行为: `context.other_card.ability.perma_bonus = (context.other_card.ability.perma_bonus or 0) + self.ability.extra`, 即给正在打分的这张牌永久加 5 筹码.
- 返回: `{extra = {message = localize('k_upgrade_ex'), colour = G.C.CHIPS}, colour = G.C.CHIPS, card = self}` (纯飘字, 没有数值字段).
- 读取状态: `context.other_card.ability.perma_bonus`, `self.ability.extra`.
- 备注: `perma_bonus` 是写进牌组存档的永久加成, 参与筹码计算 (`Card:get_chip_bonus`, 第 979-981 行: `base.nominal + ability.bonus + perma_bonus`); 因此重复结算 (例如红封, 哑剧演员) 会把徒步者的加筹码也重复叠加; 蓝图, 头脑风暴复制时也会再叠一次.

### 23.2 招财猫 / Lucky Cat (`j_lucky_cat`)

- 源码: 第 3076-3082 行. 原型: `config = {Xmult = 1, extra = 0.25}` (game.lua:464).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `self.ability.name == 'Lucky Cat'`, 且 `context.other_card.lucky_trigger` 为真, 且 `not context.blueprint`.
- 行为: `self.ability.x_mult = self.ability.x_mult + self.ability.extra` (每次 `X0.25`).
- 返回: `{extra = {focus = self, message = localize('k_upgrade_ex'), colour = G.C.MULT}, card = self}`.
- 读取状态: `context.other_card.lucky_trigger`, `self.ability.x_mult`, `self.ability.extra`.
- 备注: `lucky_trigger` 由 `Card:get_p_dollars` (第 1068-1088 行) 在"幸运牌给钱"命中时置为真 (`pseudorandom('lucky_money') < G.GAME.probabilities.normal / 15`), 并且在每张牌开始打分前由调用方重置 (`state_events.lua:701`); 因此招财猫只在幸运牌的"给钱"触发上成长, 与幸运牌的"倍率"触发无关.

### 23.3 小小丑 / Wee Joker (`j_wee`)

- 源码: 第 3083-3092 行. 原型: `config = {extra = {chips = 0, chip_mod = 8}}` (game.lua:499).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `self.ability.name == 'Wee Joker'`, 且 `context.other_card:get_id() == 2`, 且 `not context.blueprint`.
- 行为: `self.ability.extra.chips = self.ability.extra.chips + self.ability.extra.chip_mod` (每张被打分的 2 加 8 筹码).
- 返回: `{extra = {focus = self, message = localize('k_upgrade_ex')}, card = self, colour = G.C.CHIPS}`.
- 读取状态: `context.other_card` 的 id, `self.ability.extra`.
- 备注: 成长值存在 `extra.chips`, 结算在 `context.joker_main` 默认分支 (第 3873-3878 行, `chip_mod = self.ability.extra.chips`).

### 23.4 照片 / Photograph (`j_photograph`)

- 源码: 第 3093-3105 行. 原型: `config = {extra = 2}` (game.lua:450).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `self.ability.name == 'Photograph'`; 还要在 `context.scoring_hand` 里从头找到第一张 `is_face()` 为真的牌 `first_face`, 且 `context.other_card == first_face` (只有"第一张计分的人头牌"命中).
- 返回: `{x_mult = self.ability.extra, colour = G.C.RED, card = self}`, 即 `x_mult = 2`, 在本段语境里表示"把本手倍率乘 2" (`state_events.lua:751-756`).
- 读取状态: `context.scoring_hand`, `context.other_card`, `self.ability.extra`.
- 备注: 字段名是 `x_mult` 而不是 `Xmult_mod`, 两者消费位置不同; 没有 `not context.blueprint` 检查, 蓝图, 头脑风暴复制会再乘一次; 该分支跨越第 3100 行的本文件边界, 姊妹文件 2.1 节也写了它.

### 23.5 八号球 / 8 Ball (`j_8_ball`) (越界条目)

- 源码: 第 3106-3126 行 (超出本文件声明的 3100 行边界, 属于 [joker-effects-02.md](<./joker-effects-02.md>) 的范围, 这里列出以免规格断档).
- 原型: `config = {extra = 4}` (game.lua:394).
- 触发条件: `context.individual` 且 `context.cardarea == G.play`, 且 `self.ability.name == '8 Ball'`, 且 `#G.consumeables.cards + G.GAME.consumeable_buffer < G.consumeables.config.card_limit`, 且 `context.other_card:get_id() == 8`, 且 `pseudorandom('8ball') < G.GAME.probabilities.normal / self.ability.extra` (1/4).
- 返回: `{extra = {focus = self, message = localize('k_plus_tarot'), func = function() ... end}, colour = G.C.SECONDARY_SET.Tarot, card = self}`; 返回前已经执行 `G.GAME.consumeable_buffer = G.GAME.consumeable_buffer + 1`, `func` 在调用方执行 `extra.func()` 时 (第 744 行) 再排一个事件生成 `create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, '8ba')`, `card:add_to_deck()`, `G.consumeables:emplace(card)`, 并把缓冲归零.
- 读取状态: `context.other_card` 的 id, `#G.consumeables.cards`, `G.GAME.consumeable_buffer`, `G.consumeables.config.card_limit`, `G.GAME.probabilities.normal`.
- 备注: 没有 `not context.blueprint` 检查, 蓝图, 头脑风暴可各自再触发一次; 每张被打分的 8 都会独立判定.

## 24. 跨段补充与边界说明

同一批小丑在 `Card:calculate_joker` 别处的分支 (细节见各文件, 这里只给位置, 实现时必须一起看):

| 小丑 | 本段之外的分支 |
| --- | --- |
| 篝火 `j_campfire` | `x_mult` 的结算走 `joker_main` 通用规则 (第 3653-3659 行) |
| 闪示卡 `j_flash` | `mult_mod` 结算 (第 3998-4002 行) |
| 红牌 `j_red_card` | `mult_mod` 结算 (第 4034-4039 行) |
| 占卜师 `j_fortune_teller` | `mult_mod` 结算 (第 4016-4021 行) |
| 星座 `j_constellation` | `joker_main` 通用规则 (第 3653-3659 行) |
| 全息影像 `j_hologram` | `joker_main` 通用规则 (第 3653-3659 行) |
| 大麦克香蕉 `j_gros_michel` | `mult_mod` 结算 (第 4022-4027 行) |
| 卡文迪什 `j_cavendish` | `Xmult_mod` 结算 (第 4028-4033 行) |
| 绿色小丑 `j_green_joker` | 每手牌 `+1` 倍率 (第 3563-3569 行), `mult_mod` 结算 (第 4010-4014 行) |
| 小小丑 `j_wee` | `chip_mod` 结算 (第 3873-3878 行) |
| 城堡 `j_castle` | `chip_mod` 结算 (第 3880-3885 行) |
| 爆米花 `j_popcorn` | `mult_mod` 结算 (第 4004-4008 行) |
| 卡尼奥 `j_caino` | `Xmult_mod` 结算 (第 4052-4057 行) |
| 待办清单 `j_todo_list` | 命中目标牌型时发钱 (第 3491-3500 行) |
| DNA `j_dna` | 真正复制手牌 (第 3501-3524 行, 返回 `playing_cards_created`) |
| 哑剧演员 `j_mime` | 出牌时的重复 (第 3387-3393 行) |
| 火箭 `j_rocket` | 发钱在 `Card:calculate_dollar_bonus` (第 1655-1679 行) |
| 照片 `j_photograph` | 见 [joker-effects-02.md](<./joker-effects-02.md>) |
| 八号球 `j_8_ball` | 见 [joker-effects-02.md](<./joker-effects-02.md>) |

与"销毁"相关的其它位置:

- `Card:calculate_seal` (第 2242 行起): 红封, 蓝封, 金封, 紫封, 与 `context.repetition` / `repetition_only` 配合.
- `Card:get_end_of_round_effect` (第 1033-1065 行): 蓝封生成星球牌, `h_dollars`.
- `Card:get_p_dollars` (第 1068-1089 行): 金封, 幸运牌的 `lucky_trigger`.
- `Card:update` (第 4176-4178 行): 回溯的 `x_mult = 1 + G.GAME.skips * extra`, 每帧重算.
- `Card:set_ability` (第 277-338 行): `to_do_poker_hand` 抽取, `caino_xmult = 1`, `invis_rounds = 0`, `yorick_discards = extra.discards`, `perma_bonus` 保留.
- `CardArea:change_size` (cardarea.lua:94-111): 黑龟豆每回合的手牌上限修改.

不可达分支提醒: 第 2622-2671 行的 `context.cards_destroyed` (卡尼奥与玻璃小丑的第一份实现) 在本仓库的任何 Lua (含 `mods/`) 里都没有派发方, 原版运行不会走到; 真正生效的是第 2672-2707 行的 `context.remove_playing_cards`. 实现时不要漏掉后者, 也不要因为前者不可达而误删后者的语义.

边界说明: 本文件声明覆盖第 2291-3100 行, 为了不出现断档, 第 3101-3126 行 (照片的返回语句, 八号球) 也一并写出; 第 3127 行起 (偶像) 归 [joker-effects-02.md](<./joker-effects-02.md>).

## 25. 覆盖清单

| id | 中文名 | 类别 | 触发 context | 主要返回字段 / 效果 | 源码行 |
| --- | --- | --- | --- | --- | --- |
| `v_observatory` | 天文台 (优惠券) | 消耗牌 | `joker_main`, set == Planet | `Xmult_mod` = 1.5 | 2293-2302 |
| `j_blueprint` | 蓝图 | 小丑 (复制) | 全部 context | 转发右侧小丑的返回值 | 2304-2320 |
| `j_brainstorm` | 头脑风暴 | 小丑 (复制) | 全部 context | 转发最左侧小丑的返回值 | 2321-2334 |
| `j_hallucination` | 幻觉 | 小丑 | `open_booster` | 无 (生成塔罗牌) | 2336-2351 |
| `j_luchador` | 摔跤手 | 小丑 | `selling_self` | 无 (禁用 Boss 盲注) | 2355-2360 |
| `j_diet_cola` | 零糖可乐 | 小丑 | `selling_self` | 无 (双倍标签) | 2361-2370 |
| `j_invisible` | 隐形小丑 | 小丑 | `selling_self`, `end_of_round` | 无 (复制小丑, 回合计数) | 2371-2394, 2934-2944 |
| `j_campfire` | 篝火 | 小丑 | `selling_card`, `end_of_round` | 无 (`x_mult` 成长与重置) | 2396-2402, 2889-2895 |
| `j_flash` | 闪示卡 | 小丑 | `reroll_shop` | 无 (`mult` 成长) | 2404-2411 |
| `j_perkeo` | 帕奇欧 | 小丑 | `ending_shop` | 无 (复制消耗牌, 加负片) | 2413-2427 |
| `j_throwback` | 回溯 | 小丑 | `skip_blind` | 无 (仅飘字, 数值每帧重算) | 2429-2440 |
| `j_red_card` | 红牌 | 小丑 | `skipping_booster` | 无 (`mult` 成长) | 2442-2455 |
| `j_hologram` | 全息影像 | 小丑 | `playing_card_added` | 无 (`x_mult` 成长) | 2457-2461 |
| `j_certificate` | 证书 | 小丑 | `first_hand_drawn` | 无 (生成带封印的牌) | 2463-2482 |
| `j_dna` | DNA | 小丑 | `first_hand_drawn` | 无 (仅闪烁提示) | 2483-2486 |
| `j_trading` | 交易卡 | 小丑 | `first_hand_drawn`, `discard` | `remove` (销毁被弃牌), `$3` | 2487-2490, 2802-2812 |
| `j_chicot` | 希科 | 小丑 | `setting_blind` | 无 (禁用 Boss 盲注) | 2492-2502 |
| `j_madness` | 疯狂 | 小丑 | `setting_blind` | 无 (`x_mult` 成长 + 随机销毁) | 2503-2521 |
| `j_burglar` | 窃贼 | 小丑 | `setting_blind` | 无 (弃牌清零, 出牌 +3) | 2522-2528 |
| `j_riff_raff` | 乌合之众 | 小丑 | `setting_blind` | 无 (生成至多 2 张小丑) | 2529-2544 |
| `j_cartomancer` | 卡牌术士 | 小丑 | `setting_blind` | 无 (生成塔罗牌) | 2545-2560 |
| `j_ceremonial` | 仪式匕首 | 小丑 | `setting_blind` | 无 (销毁右侧, `mult` 成长) | 2561-2579 |
| `j_marble` | 大理石小丑 | 小丑 | `setting_blind` | 无 (加一张石头牌) | 2580-2601 |
| `j_sixth_sense` | 第六感 | 小丑 | `destroying_card` | `true` (销毁打出的 6) | 2604-2621 |
| `j_caino` | 卡尼奥 | 小丑 | `cards_destroyed` (不可达), `remove_playing_cards` | 无 (`caino_xmult` 成长) | 2623-2646, 2673-2685 |
| `j_glass` | 玻璃小丑 | 小丑 | `cards_destroyed` (不可达), `remove_playing_cards`, `using_consumeable` | 无 (`x_mult` 成长) | 2647-2670, 2687-2707, 2709-2721 |
| `j_fortune_teller` | 占卜师 | 小丑 | `using_consumeable` | 无 (仅飘字) | 2722-2726 |
| `j_constellation` | 星座 | 小丑 | `using_consumeable` | 无 (`x_mult` 成长) | 2727-2733 |
| `j_matador` | 斗牛士 | 小丑 | `debuffed_hand` | `dollars` = 8 | 2736-2747 |
| `j_burnt` | 烧焦小丑 | 小丑 | `pre_discard` | 无 (升级牌型 1 级) | 2749-2755 |
| `j_ramen` | 拉面 | 小丑 | `discard` | 无 (`x_mult` 递减, 触发自毁) | 2757-2787 |
| `j_yorick` | 约里克 | 小丑 | `discard` | 无 (计数, 每 23 次 `X1`) | 2788-2801 |
| `j_castle` | 城堡 | 小丑 | `discard` | 无 (`extra.chips` 成长) | 2814-2824 |
| `j_mail` | 邮件回扣 | 小丑 | `discard` | 无 (`$5`) | 2825-2834 |
| `j_hit_the_road` | 上路吧杰克 | 小丑 | `discard`, `end_of_round` | 无 (`x_mult` 成长与重置) | 2835-2845, 3011-3017 |
| `j_green_joker` | 绿色小丑 | 小丑 | `discard` | 无 (`mult` 递减) | 2846-2856 |
| `j_faceless` | 无面小丑 | 小丑 | `discard` | 无 (`$5`) | 2858-2872 |
| `j_mime` | 哑剧演员 | 小丑 | `end_of_round` + `repetition` | `repetitions` = 1 | 2879-2886 |
| `j_rocket` | 火箭 | 小丑 | `end_of_round` | 无 (`extra.dollars` 成长) | 2896-2902 |
| `j_turtle_bean` | 黑龟豆 | 小丑 | `end_of_round` | 无 (手牌上限 -1, 触发自毁) | 2903-2933 |
| `j_popcorn` | 爆米花 | 小丑 | `end_of_round` | 无 (`mult` 递减, 触发自毁) | 2945-2974 |
| `j_todo_list` | 待办清单 | 小丑 | `end_of_round` | 无 (重抽目标牌型) | 2975-2984 |
| `j_egg` | 鸡蛋 | 小丑 | `end_of_round` | 无 (售价 +3) | 2985-2992 |
| `j_gift` | 礼品卡 | 小丑 | `end_of_round` | 无 (全场售价 +1) | 2993-3010 |
| `j_gros_michel` | 大麦克香蕉 | 小丑 | `end_of_round` | 无 (1/6 概率自毁并绝迹) | 3019-3046 |
| `j_cavendish` | 卡文迪什 | 小丑 | `end_of_round` | 无 (1/1000 概率自毁) | 3019-3046 |
| `j_mr_bones` | 骷髅先生 | 小丑 | `end_of_round` | `saved = true` | 3047-3063 |
| `j_hiker` | 徒步者 | 小丑 | `individual` / play | 无 (`perma_bonus` +5) | 3067-3075 |
| `j_lucky_cat` | 招财猫 | 小丑 | `individual` / play | 无 (`x_mult` 成长) | 3076-3082 |
| `j_wee` | 小小丑 | 小丑 | `individual` / play | 无 (`extra.chips` 成长) | 3083-3092 |
| `j_photograph` | 照片 | 小丑 | `individual` / play | `x_mult` = 2 | 3093-3105 |
| `j_8_ball` | 八号球 | 小丑 | `individual` / play (越界) | `extra.func` (生成塔罗牌) | 3106-3126 |




