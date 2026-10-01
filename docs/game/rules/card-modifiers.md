# 卡牌修饰

适用版本: Balatro 1.0.1o. 本文列出 `8` 种增强, `5` 种版本(含基础版), `4` 种蜡封与永恒/易腐/租赁的数值和触发边界. 精确顺序见 [计分与结算](<scoring.md>), 牌型变化见 [扑克牌型](<poker-hands.md>).

## 修饰的层次

- 普通扑克牌可同时持有 `1` 种增强, `1` 种版本和 `1` 种蜡封. 新增强替换旧增强, 新蜡封替换旧蜡封, 不在同一层叠加. 无增强不是第 `9` 种增强.
- Joker 可以有 `1` 种版本以及兼容的运行中贴纸. 增强与蜡封不是普通 Joker 的修饰层.
- 普通玩法的负片用于 Joker, 或由 Perkeo 等生成的消耗牌, 不把它当作可给扑克牌的常规版本. 普通消耗牌没有增强/蜡封; 负片消耗牌的容量是消耗区容量.
- 增强, 版本和蜡封存储分离. 给黄金增强不会抹掉闪箔版本或蓝蜡封. 改点数/花色也不应默认清除其他层.
- 本地 `Card:set_edition` 能替换内部版本状态, 但正常加版本的卡牌效果通常只选无版本目标. 不能据此假设已有多彩牌可用 Aura 再覆盖成闪箔.
- Joker 的胜利难度贴纸是展示记录, 不等于永恒/易腐/租赁.

实现见 [card.lua](<../../../game/card.lua#L223-L300>) 的 `Card:set_ability`, [card.lua](<../../../game/card.lua#L387-L418>) 的 `Card:set_edition`, [card.lua](<../../../game/card.lua#L464-L467>) 的 `Card:set_seal`.

## 8 种增强

下表默认没有削弱, `G.GAME.probabilities.normal = 1`. 筹码和倍率效果均要求该牌真的计分, 除持有效果明确写出的情况.

| 增强 / 内部中心 | 数值 | 触发条件与边界 |
| --- | --- | --- |
| 奖励牌 / `m_bonus`, Bonus Card | 额外 +30 筹码 | 加在底牌点数筹码上; 永久筹码也另加; 重触发再计完整值 |
| 倍率牌 / `m_mult`, Mult Card | +4 倍率 | 每次作为计分牌激活时加到当前倍率; 留手不加 |
| 万能牌 / `m_wild`, Wild Card | 匹配全部 4 种花色 | 也可解释为百搭花色; 保留真实点数, 不替代任意点数; 底牌点数照常给筹码; 花色 Boss 可按任意花色将它削弱 |
| 玻璃牌 / `m_glass`, Glass Card | X2 倍率, 默认 1/4 破碎概率 | 每次计分激活乘当前倍率; 正常计分结束后每张计分玻璃牌只检查 1 次破碎; 重触发不额外抽破碎 |
| 钢铁牌 / `m_steel`, Steel Card | 留手时 X1.5 倍率 | 每次出牌的手牌阶段激活; 打出时只给正常点数筹码, 不给钢铁乘倍率; 不在回合结束现金阶段单独乘倍率 |
| 石头牌 / `m_stone`, Stone Card | 50 筹码 | 无用于牌型的点数/花色; 忽略底牌点数筹码; 加上永久筹码; 打出后总加入计分名单 |
| 黄金牌 / `m_gold`, Gold Card | 成功结束回合时留手给 $3 | 不是每次出牌给钱; 打出黄金牌不因增强给钱; 与金蜡封是不同效果 |
| 幸运牌 / `m_lucky`, Lucky Card | 默认 1/5 给 +20 倍率, 1/15 给 $20 | 两个独立执行的概率检查, 可同次都成功, 也可都失败; 每次计分重触发重新检查; 普通点数筹码始终保留 |

初始常量见 [game.lua](<../../../game/game.lua#L648-L655>) 的增强中心定义. 取值见 [card.lua](<../../../game/card.lua#L976-L1014>) 的 `Card:get_chip_bonus`/`get_chip_mult`/`get_chip_x_mult`/`get_chip_h_mult`/`get_chip_h_x_mult`, 钱款见 [card.lua](<../../../game/card.lua#L1033-L1089>) 的 `Card:get_end_of_round_effect`/`get_p_dollars`.

### 增强的重要边界

- 概率比较实际使用 `probabilities.normal / 分母`. 幸运倍率分母 `5`, 幸运钱款分母 `15`, 玻璃用卡牌当前 `ability.extra`, 初始 `4`. Oops! All 6s 会改变概率分子, 不改变这些卡面基础分母; 不应把 `1/4` 等视为所有局面中的固定概率.
- 幸运牌任一抽奖成功会设置 `lucky_trigger`. `Lucky Cat` 在这次逐卡阶段可读取它, 然后该标记清除. 两项都成功也只是本次激活的一个真值标记, 不自动给 Lucky Cat 两次升级; 后续重触发可以再次升级.
- 玻璃牌不计分时不会做增强自带破碎检查. 仅留手或普通弃牌也不会自发抽 `1/4`; 若某个其他效果销毁它, 仍可能播放碎裂, 不能把动画误认成这项概率触发.
- 钢铁先于 Joker 主效果结算. 手牌中的版本不给额外倍率, 所以多彩钢铁留手只用钢铁 `X1.5`, 不是两个 `X1.5`.
- 石头牌被削弱后仍无牌型点数/花色, 但 `50` 筹码无效. 底牌实际属性没有被永久删除; 去掉石头增强可恢复. 详见 [扑克牌型](<poker-hands.md>).
- 改增强会保留 `perma_bonus` 永久筹码. Hiker 等累计值不属于单一增强, 不应在移除奖励增强时连同永久筹码清零.
- 黄金牌与蓝蜡封的持有奖励只在成功结束回合的手牌分支发放. 失败且没有被救回时不发放.

见 [card.lua](<../../../game/card.lua#L296>) 的 `Card:set_ability`, [card.lua](<../../../game/card.lua#L608-L612>) 的 `Card:add_to_deck`, [card.lua](<../../../game/card.lua#L3065-L3081>) 的 `Card:calculate_joker`, [state_events.lua](<../../../game/functions/state_events.lua#L950-L973>) 的 `G.FUNCS.evaluate_play`.

## 5 种版本

| 版本 / 中心 | 数值 | 普通适用对象 | 价格附加值 |
| --- | --- | --- | --- |
| 基础 / `e_base`, Base | 无额外效果 | 无版本扑克牌/Joker/消耗牌 | $0 |
| 闪箔 / `e_foil`, Foil | +50 筹码 | 扑克牌, Joker | +$2 |
| 镭射 / `e_holo`, Holographic | +10 倍率 | 扑克牌, Joker | +$3 |
| 多彩 / `e_polychrome`, Polychrome | X1.5 倍率 | 扑克牌, Joker | +$5 |
| 负片 / `e_negative`, Negative | 对应区容量 +1 | Joker, 特定效果生成的消耗牌 | +$5 |

价格附加值是在正常折扣与取整前加到基础价格上, 不是另收固定税. 租赁定价等可在后面覆盖. 版本常量见 [game.lua](<../../../game/game.lua#L658-L662>), 定价见 [card.lua](<../../../game/card.lua#L369-L384>) 的 `Card:set_cost`.

### 版本时机与负片槽位

- 扑克牌版本: 该牌每次计分激活在自身增强/金蜡封钱款之后, 逐卡 Joker 之前应用. 红蜡封或 Joker 重触发会再应用版本. 未计分或留手时不应用版本.
- Joker 版本: 主效果阶段按 Joker 从左到右, 闪箔/镭射在自身 `joker_main` 之前, 多彩在自身主效果及其他 Joker 的 `other_joker` 响应之后. 不能把多彩乘倍率挪到所有 Joker 最后一次性计算.
- Blueprint/Brainstorm 复制目标的能力, 不复制目标的版本. 复制牌自身的版本仍按其位置应用.
- 负片不是分数效果. 负片 Joker 获得时增加 Joker 容量, 负片消耗牌增加消耗容量; 它自身仍占一个位置. 移除该对象也减去容量, 不留下永久空槽.
- 因 Boss/易腐暂时进入削弱状态时, 负片槽位不立即丢失. `remove_from_deck(true)` 走队列标记而不是普通移除减槽路径. 分数版本则会停用.
- 牌组中有多少张闪箔牌, 不等于一次手牌就能获得多少个 `+50`; 必须逐一进入计分名单并成功激活.

见 [card.lua](<../../../game/card.lua#L1016-L1031>) 的 `Card:get_edition`, [card.lua](<../../../game/card.lua#L630-L640>) 的 `Card:add_to_deck`, [card.lua](<../../../game/card.lua#L687-L697>) 的 `Card:remove_from_deck`, [state_events.lua](<../../../game/functions/state_events.lua#L877-L944>) 的 `G.FUNCS.evaluate_play`.

## 4 种蜡封

| 蜡封 / `Card.seal` | 数值 | 条件与边界 |
| --- | --- | --- |
| 金 / `Gold` | $3 | 每次打出且计分时; 重触发再次给钱; 留手或弃牌不给 |
| 红 / `Red` | 额外重触发 1 次 | 计分牌效果, 留手时实际存在的持有效果, 或回合结束持有效果; 不生成独立分数, 不递归重触发 |
| 蓝 / `Blue` | 生成 1 张对应星球牌 | 成功结束回合时仍留手, 对应 `last_hand_played`; 必须有消耗空间 |
| 紫 / `Purple` | 生成 1 张塔罗牌 | 经弃牌流程弃掉此牌时; 必须有消耗空间; 打出后移入弃牌堆不算弃牌触发 |

金蜡封使用 [card.lua](<../../../game/card.lua#L1068-L1089>) 的 `Card:get_p_dollars`. 红/紫使用 [card.lua](<../../../game/card.lua#L2242-L2269>) 的 `Card:calculate_seal`. 蓝使用 [card.lua](<../../../game/card.lua#L1033-L1065>) 的 `Card:get_end_of_round_effect`.

### 重触发与生成容量

- 红蜡封与其他重触发来源加法叠加. 原始激活 `1` 次, 红蜡封 `1` 次, Hack `1` 次, 合计 `3` 次, 不是 `4` 次. 所有来源只在原始激活时收集, 不让重触发再生新的重触发.
- 红蜡封可以配黄金增强, 在成功结束回合留手时给两次 `$3`. 但同一张牌不能同时有红蜡封与蓝蜡封, 或红蜡封与金蜡封.
- 金蜡封仍可由 Sock and Buskin 等 Joker 重触发. 蓝蜡封可由 Mime 重触发, 每次重新检查容量. 无效果的普通红蜡封留手牌不会凭空给倍率或钱.
- 蓝/紫的容量门槛为 `#G.consumeables.cards + G.GAME.consumeable_buffer < G.consumeables.config.card_limit`. 缓冲代表已排队生成但尚未放入区域的牌, 不能只数屏幕上已有几张. 没有空间时本次生成失败, 不储存到以后领取.
- 蓝生成的是最后实际打出牌型的星球, 不随机, 不按当前等级最高或本局最常用牌型. 皇家同花顺对应 Neptune. 牌型记录包括被 Boss 拒绝的出牌.
- Hook 造成的弃牌调用同一个弃牌流程, 可以触发紫蜡封, 即使不扣普通弃牌次数. 弃牌蜡封先于对应的弃牌 Joker 响应, 所以随后被 Joker 销毁的紫蜡封牌仍可能已排队生成塔罗.
- 紫蜡封不因为红蜡封/Mime 再生成, 它是一次弃牌事件而非计分或持有激活.

见 [state_events.lua](<../../../game/functions/state_events.lua#L171-L233>) 的 `end_round`, [state_events.lua](<../../../game/functions/state_events.lua#L379-L438>) 的 `G.FUNCS.discard_cards_from_highlighted`, [state_events.lua](<../../../game/functions/state_events.lua#L665-L684>) 的 `G.FUNCS.evaluate_play`.

## 永恒, 易腐与租赁

| 运行中贴纸 | 数值/限制 | 生命周期与边界 |
| --- | --- | --- |
| 永恒 / Eternal | 不能出售或被正常销毁 | 需要中心 `eternal_compat`; 不防 Boss 削弱, 不保证能力永远有效 |
| 易腐 / Perishable | 初始 5 个回合 | 每次 `end_round` 递减; 从 1 变 0 时禁用, 不自动销毁或释放槽位; 需要 `perishable_compat` |
| 租赁 / Rental | 正常租赁买价 $1, 每回合结束扣 $3 | 无贴纸兼容门槛; 可与永恒或易腐并存; 禁用后仍付租 |

默认数值见 [game.lua](<../../../game/game.lua#L1894-L1897>) 的 `Game:init_game_object`. 黑注及以上启用商店永恒, 橙注及以上启用易腐, 金注启用租赁, 见 [game.lua](<../../../game/game.lua#L2034-L2041>) 的 `Game:start_run`.

### 永恒

- 永恒与易腐互斥, setter 同时检查兼容字段和另一贴纸. 不把兼容性描述为随机概率问题.
- 永恒禁止出售, 即使此牌已被 Boss 禁用. Ankh/Hex 等清除其他 Joker 的普通销毁路径以及 Madness/Ceremonial Dagger 等也检查永恒, 不销毁它.
- 不能因无用就直接腾出永恒牌的位置. 永恒不保护点数收益, 版本分数效果或负面租赁成本.

见 [card.lua](<../../../game/card.lua#L506-L519>) 的 `Card:set_eternal`/`set_perishable`, [card.lua](<../../../game/card.lua#L1640-L1653>) 的 `Card:can_sell_card`, [card.lua](<../../../game/card.lua#L1432>) 和 [card.lua](<../../../game/card.lua#L1491>) 的 `Card:use_consumeable`.

### 易腐

- 第 `1` 到第 `5` 个已玩回合的出牌过程中仍有效, 第 `5` 次 `end_round` 内归零禁用. 跳过盲注不调用此回合结束流程, 不减少计数.
- 对每张 Joker 的顺序是自身 `end_of_round` 能力 -> 收租 -> 腐坏计时. 计数归零早于成功分支的黄金牌/蓝蜡封与 Mime 手持重触发. 恰在这次腐坏的 Mime 不再为该阶段重触发.
- 计数下降不取决于本轮是否用该 Joker 得分. `calculate_perishable` 没有削弱早退, 已被 Boss 禁用的易腐牌仍递减.
- 归零的牌保留占位, 一般仍可出售. `Card:set_debuff(false)` 不会恢复归零易腐牌, 因为过期判断优先; 单纯击败或禁用 Boss 不能修复它.

见 [card.lua](<../../../game/card.lua#L526-L538>) 的 `Card:set_debuff`, [card.lua](<../../../game/card.lua#L2278-L2289>) 的 `Card:calculate_perishable`, [state_events.lua](<../../../game/functions/state_events.lua#L99-L110>) 的 `end_round`.

### 租赁

- `Card:set_cost` 在折扣和版本加价计算之后令租赁价格为 `$1`. 一般卖价为 `max(1, floor(cost / 2)) + extra_value`, 所以通常卖 `$1`, Egg 等额外卖价可提高它. 商店优惠券 `couponed` 在更后面可把购买价变为 `$0`, 不应宣称租赁永远买 `$1`.
- 每回合每张租赁牌各扣 `$3`, 不是整组只扣一次. 可以令钱款为负; 不是必须有 `$3` 才会收租.
- `calculate_rental` 没有削弱早退, 过期易腐租赁牌和 Boss 禁用租赁牌都继续扣钱. 永恒租赁不能通过出售止损.
- 收租发生在成功结束回合的黄金牌留手钱款和后续现金结算前, 不应只根据现金结算面板推断收租时余额.

见 [card.lua](<../../../game/card.lua#L369-L384>) 的 `Card:set_cost`, [card.lua](<../../../game/card.lua#L2271-L2276>) 的 `Card:calculate_rental`, [state_events.lua](<../../../game/functions/state_events.lua#L99-L110>) 的 `end_round`.

## 削弱总则与版本边界

削弱通常停用卡牌的点数筹码, 加/乘倍率, 版本计分, 蜡封, 黄金钱款与蓝蜡封生成. 本地 getter 多数直接返回 `0`/空表. 不应等同于销毁, 清空增强, 清空版本或恢复原始牌.

关键例外是石头的无点数/花色身份, 负片槽位, 永恒的不可卖/毁, 以及租赁/易腐生命周期. 万能牌被削弱时计算同花回到底牌花色, 但 Boss 使用绕过削弱的花色检测可再次识别万能牌.

正式中文名采用 [zh_CN.lua](<../../../game/localization/zh_CN.lua#L333-L426>) 的 `Edition`/`Enhanced` 表: Wild Card 为万能牌, Holographic 为镭射, 百搭/全息仅可作为解释性别称.

[Wiki: Card modifiers](https://balatrowiki.org/w/Card_modifiers) 交叉验证了上述 `8/5/4` 类别和常量, 蓝蜡封按最后打出牌型生成, 以及红蜡封与 Joker 重触发加法叠加. Wiki 的概括性削弱说明不覆盖租赁/易腐等所有生命周期例外, 以本地 setter/getter 与 `end_round` 为准. [Wiki: Guide: Activation Sequence](https://balatrowiki.org/w/Guide:_Activation_Sequence) 补充验证版本触发顺序.
