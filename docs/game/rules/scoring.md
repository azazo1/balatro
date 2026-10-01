# 计分与结算

适用版本: Balatro 1.0.1o. 本文区分一次出牌的计分与一个盲注回合结束的结算. 以本地 Lua 代码为准, 不把动画先后当作另一套规则.

## 计分对象与算式

- `full_hand = G.play.cards`: 全部打出的牌. 消耗一次出牌次数, 即使整手被 Boss 判为不允许也不退还.
- `scoring_hand`: 最高优先级牌型的计分牌, 加上打出的石头牌. 有生效的 `Splash` 时改为全部打出的牌. 再按屏幕横坐标 `T.x` 从左到右排序.
- `G.hand.cards`: 打出后仍留在手中的牌. 它们不提供点数筹码, 但可能触发钢铁牌或持有类 Joker.
- 本次得分为 `floor(hand_chips * mult)`, 加到本盲注累计分数 `G.GAME.chips`. 钱款不是分数. 乘倍率是乘当前 `mult`, 不是乘最终得分.
- 普通点数筹码: `2` 到 `10` 等于点数, `J/Q/K` 为 `10`, `A` 为 `11`. 强化与永久奖励另加; 石头牌忽略底牌点数.

入口见 [state_events.lua](<../../../game/functions/state_events.lua#L450-L538>) 的 `G.FUNCS.play_cards_from_highlighted`, 主结算见 [state_events.lua](<../../../game/functions/state_events.lua#L571-L1086>) 的 `G.FUNCS.evaluate_play`. 牌型与修饰分别见 [扑克牌型](<poker-hands.md>) 和 [卡牌修饰](<card-modifiers.md>).

## 一次出牌的严格顺序

### 1. 出牌前置与 Boss 的 press_play

选中的牌先按位置排序, 消耗一次出牌次数, 从手牌移到出牌区, 标记本底注已打出. 随后调用 `Blind:press_play`:

- `The Hook`: 从剩余手牌随机弃掉最多 `2` 张. 属于弃牌流程, 可触发紫蜡封和弃牌 Joker, 不消耗普通弃牌次数.
- `The Tooth`: 每张打出的牌扣 `$1`, 包括不计分的牌.
- `The Fish` 与 `Crimson Heart`: 设置后续抽牌/禁用 Joker 的准备状态. 不等于在本次乘积算出后立即更换红心禁用目标.

见 [blind.lua](<../../../game/blind.lua#L464-L508>) 的 `Blind:press_play` 和 [state_events.lua](<../../../game/functions/state_events.lua#L379-L438>) 的 `G.FUNCS.discard_cards_from_highlighted`.

### 2. 识别牌型, 更新记录, 构造计分牌

调用 `G.FUNCS.get_poker_hand_info` 取得固定优先级最高的牌型, 而不是预期分数最高的牌型. 立刻增加该牌型的全局/回合出牌记录, 设置 `last_hand_played`, 将该牌型置为可见. 这些操作先于整手 Boss 检查, 所以零分出牌仍有牌型记录, 隐藏牌型也可因此变为可见.

计分牌名单在 `before` Joker 之前确定. 后续 Joker 改变增强不重新识别牌型或重建名单. 例如 `Vampire` 去掉已入选石头牌的增强后, 它仍在本次名单内.

### 3. Boss 整手检查与持久降级

调用 `Blind:debuff_hand(full_hand, poker_hands, scoring_name)`:

- 对禁牌型, 出牌张数限制, `The Eye` 重复牌型, `The Mouth` 非指定牌型等, 若返回真, 本次筹码和倍率均设 `0`. 跳过 `before`, 出牌逐卡, 手牌逐卡, Joker 主效果, Observatory, 最终牌背效果和正常销毁检查. 只调用 `debuffed_hand` Joker 分支, 然后仍走计分后的 `after` 分支.
- `The Arm`: 当前牌型等级大于 `1` 才永久降 `1` 级, 在 `before` Joker 之前发生; 不会把等级 `1` 降到 `0`.
- `The Ox`: 若是指定最常用牌型, 将当前钱款归零. 它不使整手零分.
- 判定用完整 `poker_hands` 结果与实际打出张数, 不只看最终显示牌型或计分张数.

见 [blind.lua](<../../../game/blind.lua#L519-L570>) 的 `Blind:debuff_hand`.

### 4. before Joker, 重读牌型基础值, 再执行 The Flint

整手允许计分时, 先处理首次出牌等级奖励 `first_used_hand_level`, 再按 Joker 从左到右调用 `before = true`. 成长, 转换增强, DNA 复制, Space Joker 升级等在此发生. Space Joker 返回 `level_up` 时立即调用 `level_up_hand`.

随后重新读取该牌型当前等级的筹码和倍率. 因此刚发生的降级/升级用于本次. 再调用 `Blind:modify_hand`; `The Flint` 只对这时的牌型基础值处理:

- `mult = max(floor(mult * 0.5 + 0.5), 1)`.
- `hand_chips = max(floor(hand_chips * 0.5 + 0.5), 0)`.

之后的点数筹码, 加倍率和乘倍率不被再减半. 不能把 Wiki 的简化概括理解为所有 Boss 都早于所有 `before` Joker.

见 [state_events.lua](<../../../game/functions/state_events.lua#L614-L647>) 的 `G.FUNCS.evaluate_play`, [blind.lua](<../../../game/blind.lua#L510-L517>) 的 `Blind:modify_hand`, [card.lua](<../../../game/card.lua#L3411-L3569>) 的 `Card:calculate_joker`.

### 5. 计分牌从左到右, 每张先完成全部重触发

每张计分牌的完整激活次数为 `1 + 红蜡封重触发次数 + 各 Joker 重触发次数之和`. 先收集红蜡封, 再按 Joker 顺序收集 `repetition` 返回值. 本张所有激活完成后才移到右边下一张, 不是整手再从头播放一遍.

- 被削弱的计分牌直接跳过本阶段的自身效果, 红蜡封, 重触发 Joker 和逐卡 Joker. 它仍可参与牌型识别.
- 每次激活先调用本牌的 `eval_card`, 然后按 Joker 从左到右调用 `individual = true, cardarea = G.play`, 将返回效果加入列表.
- 按效果列表顺序应用. 普通计分牌自身的数值顺序是: 点数/奖励/永久筹码 -> 加倍率 -> 出牌钱款(幸运牌与金蜡封在同一个 `p_dollars` 中合并) -> 玻璃牌乘倍率 -> 本牌版本 -> 逐卡 Joker 效果.
- 通用效果表更完整的字段消费顺序是 `chips`, `mult`, `p_dollars`, `dollars`, `extra`, `x_mult`, `edition`. `extra` 内先加倍率, 再加筹码, 再交换筹码和倍率, 再执行回调. 版本内部依次加筹码, 加倍率, 乘倍率.
- 每次重触发重新调用本牌与逐卡 Joker, 所以幸运牌重新抽概率, 金蜡封重新给钱, 逐卡成长再次发生. 红蜡封本身不递归, 不把其他重触发再次乘 `2`.
- 效果先收集再应用, 不全是边查边加. 例如 `Hiker` 在本牌点数筹码已取值后增加永久筹码, 本次首次激活不回补, 后续重触发或下次出牌才读取增加后的值.

见 [state_events.lua](<../../../game/functions/state_events.lua#L648-L780>) 的 `G.FUNCS.evaluate_play`, [common_events.lua](<../../../game/functions/common_events.lua#L580-L622>) 的 `eval_card`, [card.lua](<../../../game/card.lua#L3065-L3104>) 和 [card.lua](<../../../game/card.lua#L3342-L3395>) 的 `Card:calculate_joker`.

### 6. 留在手中的牌从左到右

每张手牌先求自身持有效果, 再从左到右求持有类逐卡 Joker 效果, 然后处理本张所有重触发:

1. 自身增强的持有加倍率/乘倍率, 通常只有钢铁牌 `X1.5` 生效.
2. 该牌对应的逐卡 Joker, 如 `Raised Fist`, `Shoot the Moon`, `Baron`, 按 Joker 位置依次应用.
3. 重触发重复 1 和 2. 原始激活只收集一次重触发来源, 红蜡封在前, `Mime` 等 Joker 在后. 没有任何持有效果的普通红蜡封牌不凭空激活.

这里不加点数筹码, 不激活扑克牌版本, 不支付金蜡封, 不抽幸运牌奖励, 不进行玻璃牌破碎检查. 黄金牌与蓝蜡封不在每次出牌时结算, 而在成功结束回合时结算. 被削弱牌的自身持有效果无效, 对应 Joker 的逐卡分支也有削弱检查.

见 [state_events.lua](<../../../game/functions/state_events.lua#L784-L872>) 的 `G.FUNCS.evaluate_play` 和 [common_events.lua](<../../../game/functions/common_events.lua#L624-L639>) 的 `eval_card`.

### 7. Joker 主效果与版本, 然后消耗牌

完成所有出牌和手牌逐卡效果后, 逐张处理 Joker, 最后逐张处理消耗牌. 不是先汇总所有加倍率, 再统一乘倍率. 每张对象的顺序:

1. 该对象闪箔版本 `+50` 筹码或全息版本 `+10` 倍率.
2. `joker_main` 主效果. 同一个返回表中依次处理 `mult_mod`, `chip_mod`, `Xmult_mod`.
3. 其他 Joker 从左到右响应 `other_joker = 当前对象`, 如 `Baseball Card`.
4. 当前对象多彩版本 `X1.5`.

因此多彩 Joker 的乘倍率在它自己的主效果和针对它的 Baseball Card 之后. Blueprint/Brainstorm 调用复制目标的 `calculate_joker`, 并不复制目标版本; 自己的版本仍按自身位置结算. 主效果不会因为某张扑克牌的重触发再执行一次.

持有 Observatory 时, 消耗区中与本次 `scoring_name` 匹配的每张星球牌在 `joker_main` 给 `X1.5`, 消耗牌从左到右, 不消耗星球. 皇家同花顺仍使用 `Straight Flush` 键匹配 Neptune.

见 [state_events.lua](<../../../game/functions/state_events.lua#L877-L944>) 的 `G.FUNCS.evaluate_play`, [card.lua](<../../../game/card.lua#L2291-L2333>) 的 `Card:calculate_joker`.

### 8. 最终牌背处理, 销毁检查, 入账与 after

1. 调用牌背 `final_scoring_step`. 等离子牌组令筹码与倍率都等于 `floor((筹码 + 倍率) / 2)`, 再相乘. 不是保留带 `.5` 的平均值.
2. 对每张计分牌, 按 Joker 顺序询问 `destroying_card`; 首个要求销毁的返回值结束该 Joker 查询. 随后非削弱玻璃牌再独立做一次破碎概率检查, 默认 `1/4`. 一张玻璃牌只检查一次, 不因重触发增加检查次数.
3. 向 Joker 通知 `remove_playing_cards`, 实际移除销毁牌. 销毁在数值已算完后, 不撤销这次得分. 未计分的玻璃牌不走此随机检查.
4. 将 `floor(hand_chips * mult)` 加到盲注累计分数.
5. 按 Joker 从左到右执行 `after = true`, 如 Ice Cream/Seltzer 递减. 这发生在每次出牌后, 包括整手被 Boss 拒绝的零分出牌.
6. 出牌牌移到弃牌堆, 更新本局和本回合 `hands_played`. 若已达到目标, 结束盲注; 否则补抽手牌并处理 Boss 的 `drawn_to_hand` 等接口.

见 [back.lua](<../../../game/back.lua#L125-L170>) 的 `Back:trigger_effect`, [state_events.lua](<../../../game/functions/state_events.lua#L946-L1086>) 的 `G.FUNCS.evaluate_play`, [blind.lua](<../../../game/blind.lua#L572-L603>) 的 `Blind:drawn_to_hand`.

## 成功结束回合的顺序

`end_round` 是全局函数, 不是 `G.FUNCS.end_round`. 见 [state_events.lua](<../../../game/functions/state_events.lua#L87-L237>) 的 `end_round`:

1. 先比较累计分数与盲注目标, 得到 `game_over`.
2. 按 Joker 从左到右, 对每张先调用 `end_of_round = true`, 可能由救命效果把 `game_over` 改为假; 随即收租 `$3`, 随即递减易腐计数, 然后才移到下一张 Joker. 回合末小丑效果仍受 `calculate_joker` 开头的削弱早退约束; 只有租赁与易腐这两项不因削弱而跳过, 所以禁用租赁牌仍收租, 禁用易腐牌仍计时.
3. 若仍失败, 不执行成功分支的剩余手牌奖励.
4. 若成功, 按剩余手牌从左到右, 每张先执行 `Card:get_end_of_round_effect`, 如黄金牌 `$3` 与蓝蜡封星球生成, 再派发回合结束持有类逐卡 Joker context. 本版本 `end_of_round + individual` 分支为空, 不会因此再执行男爵, 射月或预留车位的普通留手计分效果. 红蜡封和 `Mime` 等重触发重复本张结束效果; 仍要求本张实际有可重复的效果. 来源: [回合末逐卡分支](<../../../game/card.lua#L2874-L2888>).
5. 蓝蜡封每次激活都重新检查消耗槽和缓冲占用. 已无空间时不会预支或延迟兑现. 生成的是 `last_hand_played` 对应星球, 不是随机星球或最常用牌型星球.
6. 之后才把剩余手牌移走, 处理 Boss 后底注提升等, 进入回合现金结算. 盲注奖金, 剩余出牌次数奖励, Joker 常规收入与利息见 [经济规则](<economy.md>).

边界: 恰在第 `5` 次结束回合腐坏的 Mime, 在后续黄金牌/蓝蜡封阶段已被禁用, 不能再贡献该阶段重触发. 租赁成本发生于持有黄金牌给钱之前.

## 排序与预测要点

- 加倍率在同一阶段通常应放在乘倍率之前. 基础 `40 x 4`, 左边 `+4` 再右边 `X2` 得 `640`; 反向得到 `480`.
- 比较的是实际阶段, 不只是卡面文案. 持有钢铁的 `X1.5` 先于所有 Joker 主效果, 所以不会放大后来的主效果加倍率.
- 先确定计分名单, 再排计分牌. 没有 Splash 的垫牌不会触发金蜡封或本牌版本, 但仍会被 Tooth 收费, 也可能满足 `full_hand` 条件.
- Joker 位置同时控制复制目标, `before` 改牌顺序, 逐卡顺序和主效果顺序. Midas Mask 放在 Vampire 左侧可先加黄金增强再被吸收, 反向则留下黄金增强.
- 预测应保留随机分支, 不能把幸运牌概率奖励视为确定入账. 涉及存量永久筹码或动态增强时, 使用卡牌当前值而非仅用初始常量.
- `mod_mult` 在此版本直接返回输入. `mod_chips` 在启用 `chips_dollar_cap` 挑战修饰时把每次经过接口的筹码限制为 `min(筹码, max(当前钱款, 0))`. 不可只在末尾统一限额.

见 [misc_functions.lua](<../../../game/functions/misc_functions.lua#L684-L693>) 的 `mod_chips`/`mod_mult`, [card.lua](<../../../game/card.lua#L3443-L3489>) 的 `Card:calculate_joker`.

## 交叉验证与版本边界

[Wiki: Guide: Activation Sequence](https://balatrowiki.org/w/Guide:_Activation_Sequence) 验证了逐卡从左到右, 重触发加法叠加, 手牌先于 Joker 主效果, Joker 闪箔/全息在主效果前而多彩在后, Observatory 先于等离子平衡. Wiki 是跨版本的辅助概括; The Flint 的精确位置, 玻璃销毁检查, 取整, 回合租赁/易腐顺序采用上面的本地实现.
