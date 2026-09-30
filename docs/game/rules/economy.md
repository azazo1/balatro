# 经济与结算

适用版本: Balatro 1.0.1n. 本文区分立即入账的金钱和领取时入账的结算钱, 说明利息, 租金, 购入价, 卖价及支付条件. 商店商品生成和开包详见 [商店](<shop-and-packs.md>), 单卡完整效果见 [小丑目录](<../cards/jokers.md>) 和 [消耗牌机制](<../mechanics/consumable-mechanics.md>).

## 1. 金钱不是分数

`G.GAME.dollars` 是当前现金, `G.GAME.chips` 是本盲注累计得分. 不存在把分数直接按比例兑换金钱的通用规则. 超额打分不增加固定盲注奖; 同样, 余额再多也不能代替打分过关.

基础开局 $4, 黄色牌组增加 $10 到 $14. 挑战可覆盖余额. `ease_dollars(mod)` 做直接加法 `dollars += mod`, 没有默认下限夹到 $0. 金钱为负并不会单独触发本局失败.

来源: [基础参数](<../../../game/functions/misc_functions.lua#L1868-L1881>), [Back:apply_to_run](<../../../game/back.lua#L174-L288>), [ease_dollars](<../../../game/functions/common_events.lua#L68-L109>).

## 2. 回合结束的经济流水线

正常成功或被救场后按以下顺序处理. 失败也先执行步骤 1 和 2 的小丑部分, 然后直接进入失败画面而不正常领取结算.

1. 用累计得分判断是否达标, 小丑逐张接收 `end_of_round` 和初步 `game_over`, 允许救场和回合结束成长/收益.
2. 每张小丑在自己的回合结束处理之后执行租金扣款和易腐倒计时. 租金是立即金钱变动, 并非收入栏中的负数项目.
3. 成功路径处理仍在手中的扑克牌结束效果, 例如金牌每张 $3, 以及回合结束小丑的逐牌效果和重触发. 这些立即入账, 发生在利息计算前.
4. 收入结算栏计算固定盲注奖金, 余手钱, 特定牌组/挑战的余弃钱, 结算型小丑奖金, 标签奖金, 利息.
5. 收入栏合计写入 `G.GAME.current_round.dollars`, 此时不是把这些钱逐项加入当前现金.
6. 点击领取 `cash_out` 才执行 `ease_dollars(current_round.dollars)` 并进入商店.

因此利息能考虑步骤 1..3 已实际到账/扣掉的钱, 但不能考虑同一结算栏刚算出来的盲注奖金, 余手奖金, 黄金小丑等奖金或投资标签奖金.

来源: [end_round](<../../../game/functions/state_events.lua#L87-L233>), [evaluate_round](<../../../game/functions/state_events.lua#L1135-L1208>), [结算总额写入](<../../../game/functions/common_events.lua#L1087>), [cash_out](<../../../game/functions/button_callbacks.lua#L2897-L2941>), [create_UIBox_round_evaluation](<../../../game/functions/UI_definitions.lua#L1612-L1627>).

### 结算栏合计

```text
cash_out = blind_reward + hand_bonus + discard_bonus
         + sum(joker_dollar_bonus) + sum(tag_eval_bonus) + interest
```

| 项目 | 默认公式 | 覆盖/限制 |
| --- | --- | --- |
| 固定盲注奖金 | 小盲注 $3, 大盲注 $4, 普通 Boss $5, 决战 Boss $8 | 红注及以上小盲注固定奖 $0; 分数不达标但被救场时固定奖 $0; 挑战可设 `no_blind_reward` |
| 剩余出牌次数 | `hands_left *1` | `money_per_hand` 改单价; `no_extra_hand_money` 禁止该项; 达标出牌本身已扣次数 |
| 剩余弃牌次数 | 默认 $0 | 只有设了 `money_per_discard` 才支付 |
| 小丑结算奖金 | 逐小丑 `calculate_dollar_bonus()` | 小丑被削弱则没有该项, 不是复制全部 `end_of_round` 的任意效果 |
| 标签结算奖金 | 标签 `apply_to_run({type='eval'})` | 条件由标签指定, 如投资标签在 Boss 结束时支付 |
| 利息 | 见下一节 | `no_interest` 禁止 |

绿色牌组把余手单价改为 $2, 余弃单价改为 $1, 并禁用利息. 红注 "小盲注没有奖励金" 只清固定奖, 没有禁用其余收入, 所以打小盲注仍可能有经济收益.

来源: [evaluate_round](<../../../game/functions/state_events.lua#L1139-L1203>), [盲注奖励覆盖](<../../../game/blind.lua#L82-L84>), [绿色牌组参数](<../../../game/game.lua#L631>).

### 结算型小丑奖金

仅以下分支由 `calculate_dollar_bonus` 加入结算栏, 不包含每手即时获钱型小丑:

| id | 奖金公式 |
| --- | --- |
| `j_golden` | 黄金小丑 Golden Joker: 默认 $4 |
| `j_cloud_9` | 9 霄云外 Cloud 9: 当前整个牌组里每张 9 默认 $1 |
| `j_rocket` | 火箭 Rocket: 当前已成长的 `extra.dollars`; Boss 回合的成长先于这里读取 |
| `j_satellite` | 卫星 Satellite: 本局用过的不同星球牌种类数, 每类默认 $1 |
| `j_delayed_grat` | 延迟满足 Delayed Gratification: `discards_used ==0` 且剩余弃牌 >0 时, 每个剩余次数默认 $2 |

来源: [Card:calculate_dollar_bonus](<../../../game/card.lua#L1655-L1679>), [小丑基础经济数值](<../../../game/game.lua#L388-L515>). 金钱立即触发的小丑见 [小丑机制](<../mechanics/joker-mechanics.md>); 不要把所有经济小丑都计入上述结算栏.

## 3. 利息

令 `D` 为计算利息时的当前现金, `i = interest_amount`, `cap = interest_cap`:

```text
if D <5 or no_interest:
    interest =0
else:
    interest = i * min(floor(D/5), cap/5)
```

基础 `i =1`, `cap =25`, 所以每完整 $5 支付 $1, 最多 $5. `cap` 是参与利息的本金上限, 不是直接写成利息上限 $25.

| 现金 D | 基础利息 |
| --- | ---: |
| 0..4 或负数 | $0 |
| 5..9 | $1 |
| 10..14 | $2 |
| 15..19 | $3 |
| 20..24 | $4 |
| 25 及以上 | $5 |

- `v_seed_money` 将 `cap` 设为 50, 基础利息上限 $10.
- `v_money_tree` 将 `cap` 设为 100, 基础利息上限 $20, 替换 50 而不是相加.
- 冲向月球 To the Moon (`j_to_the_moon`) 每张有效牌使 `interest_amount` 增加 1, 因而基础 `i =1` 时, 持有一张支付每完整 $5 的 $2 利息. 多张按实际游戏字段累计; 不修改本金上限.
- 绿色牌组/相关挑战的 `no_interest` 使金额始终为 0, 即使有上述优惠券也不支付.
- 不发负利息, 不为负债收一般债务利息.
- 本回合租金已先扣款; 金牌等即时收益已先入账; 结算栏奖金尚未领取.

例: 当前现金 $23, 没有即时入账变化, 打败大盲注后剩 2 次出牌. 收入栏是 `$4 + $2 + $4 利息 = $10`, 领取后 $33. 不能先把盲注和余手奖励加成 $29 再按 $29 算 $5 利息.

来源: [利息计算](<../../../game/functions/state_events.lua#L1191-L1203>), [基础经济字段](<../../../game/game.lua#L1890-L1897>), [利息上限优惠券](<../../../game/card.lua#L1931-L1935>), [冲向月球增加利息单价](<../../../game/card.lua#L613-L615>).

## 4. 购入价格与折扣

### 通用 Card:set_cost

`B = base_cost`, `I = inflation`, `E = 版本溢价`, `d = discount_percent`:

```text
普通购入价 P = max(1, floor((B + I + E +0.5) * (100-d)/100))
```

这是准确执行顺序, 不是先把各项独立折扣或无条件标准四舍五入. 版本溢价:

| 版本 | 溢价 |
| --- | ---: |
| 基础 | $0 |
| 闪箔 Foil | $2 |
| 镭射 Holographic | $3 |
| 多彩 Polychrome | $5 |
| 负片 Negative | $5 |

基础价格来自原型: 塔罗/星球通常 $3, 幻灵 $4, 优惠券 $10; 小丑和包各有自己的基础价. 详细列表由 [完整卡牌目录](<../cards/jokers.md>) 和 [商店](<shop-and-packs.md>) 提供.

来源: [Card:set_cost](<../../../game/card.lua#L369-L385>), [消耗牌原型](<../../../game/game.lua#L532-L588>), [优惠券原型](<../../../game/game.lua#L592-L624>).

### 后续覆盖顺序

1. 普通价公式后, 若是补充包且有挑战 `booster_ante_scaling`, 加 `ante -1`.
2. 教程第一商店未完成时补充包额外 +$3, 这不是普通局的固定包价.
3. 持有有效天文学家 `j_astronomer` 时, 星球牌和名字包含 Celestial 的天体包价格设 0.
4. 租赁小丑价格覆盖为 $1.
5. 根据这时的价格计算卖价.
6. 商品带 `couponed` 且在商店普通卡/包商品区, 购入价最后覆盖为 0; 这个覆盖在卖价计算后, 所以免费商品不自动具有 $0 卖价.

例: 基础 $4 小丑的闪箔版本, 原价为 $6, 25% 折扣时 `floor(6.5*0.75)=4`; 租赁时无论此结果如何都购入 $1.

### 折扣来源

- `v_clearance_sale` 将 `discount_percent` 设为 25.
- `v_liquidation` 将其设为 50, 不和 25 叠加到 75.
- 兑换后遍历现有卡牌 `set_cost`, 持有牌卖价也可能随之改变. 卖价不保存为历史购买价格的一半.
- 普通售价有最低 $1, 免费类覆盖可以突破该下限.
- 物品折扣不自动打折商店刷新费或固定 $10 的 Boss 重掷费.
- 挑战的通胀 `inflation` 会增加价格; 正常局 `inflation =0`.

来源: [Card:set_cost](<../../../game/card.lua#L369-L385>), [Card:apply_to_run 折扣](<../../../game/card.lua#L1917-L1923>), [优惠券参数](<../../../game/game.lua#L593-L610>).

## 5. 卖价与出售

### 当前卖价

```text
sell_cost = max(1, floor(当前用于卖价计算的 cost/2)) + extra_value
```

- 原价 $2/$3 通常卖 $1; $4/$5 通常卖 $2. 默认最低卖价 $1.
- 蛋 `j_egg` 和礼品卡 `j_gift` 等增加 `extra_value`, 在基础卖价之外累计.
- 租赁覆盖购入价 $1 后, 基础卖价也是 $1, 但仍可加 `extra_value`.
- 免费商品由于免费覆盖在 `sell_cost` 后, 卖价可基于正常价计算.
- 背面朝上的持有牌显示卖价 `?`, 不代表内部价格为 0; 对 agent 来说是隐藏观测值.
- 不是退款, 不使用你过去实际支付的金额, 不能把免费获取的牌自动视为没卖出价值.

来源: [Card:set_cost](<../../../game/card.lua#L369-L385>).

### 出售是否合法

`Card:can_sell_card` 检查:

- 出牌区不能有正在计分的牌.
- 控制器未锁定, `STOP_USE` 没有正值.
- 卡牌处于类型为 `joker` 的持有牌区, 包括小丑区和消耗牌区.
- 不是永恒小丑.
- 教程会限制早期卖牌, 正常完成教程后不受该特殊限制.

因此卖牌不只限于商店, 可在正常选牌和盲注选择等稳定阶段执行; 扑克牌堆中的普通牌不可通过该通用出售入口卖掉. 不能出售易腐/租赁到期牌的说法不成立, 只要它不是永恒且其他条件满足, 仍可出售.

卖出先触发自身 `selling_self`, 之后获得卖价并销毁卡牌, 其他小丑收到 `selling_card` 事件. 翠绿之叶期间卖出小丑会禁用该 Boss, 卖消耗牌不会.

来源: [Card:can_sell_card](<../../../game/card.lua#L1640-L1653>), [Card:sell_card](<../../../game/card.lua#L1590-L1638>), [sell_card 回调](<../../../game/functions/button_callbacks.lua#L2303-L2311>).

## 6. 支付能力, 负债和租金

付费按钮普遍比较:

```text
可支出预算 = dollars - bankrupt_at
```

基础 `bankrupt_at =0`. 信用卡 Credit Card (`j_credit_card`) 在加入持有区时将其减去 20, 移除时加回来; 正常一张有效信用卡因此允许付费后到 -$20. 多张效果可进一步增加额度, 但须读取实际字段, 不固定永远 -20.

购买价为 0 的普通商品和补充包有专门豁免, 即使现金负数也能购买/打开, 仍需满足槽位/使用条件. 价格大于 0 时须有足够可支出预算; 刷新和 Boss 重掷也做对应预算检查. 优惠券兑换按钮 `can_redeem` 没有通用的零价豁免, 本版正常优惠券经折扣仍至少 $1.

强制扣款不通过这些付费按钮. 牙齿和租赁等可直接扣到负数, 即使没有信用卡. 信用卡提供的是自主消费许可, 不是全部金钱操作的强制下限. 移除信用卡也不会因已有负债立即结束一局, 只是后续付费预算收紧.

租赁每张每实际回合 -$3, 即使被 Boss 削弱或易腐到期仍收费. 卖掉租赁牌只拿卖价, 没有 "买断" 和预付租金退款. 租赁和其他贴纸的共存见 [赌注](<stakes.md>).

来源: [付费商品 / 兑换 / 开包检查](<../../../game/functions/button_callbacks.lua#L55-L119>), [can_reroll](<../../../game/functions/button_callbacks.lua#L2061-L2075>), [信用卡加入](<../../../game/card.lua#L593-L595>), [信用卡移除](<../../../game/card.lua#L655-L657>), [calculate_rental](<../../../game/card.lua#L2271-L2276>), [ease_dollars](<../../../game/functions/common_events.lua#L68-L109>).

## 7. 刷新与 Boss 重掷费用

### 普通商店刷新

基础 `round_resets.reroll_cost =5`. 剩余免费次数 >0 时刷新价 0. 否则:

```text
reroll_cost = (temp_reroll_cost or round_resets.reroll_cost) + reroll_cost_increase
```

每次没有 `skip_increment` 的更新将增量 +1. 免费刷新在消耗时用相应标记避免上涨; 下一实际回合重新清零增量并重算免费次数. 优惠券 `v_reroll_surplus` 和 `v_reroll_glut` 各降低基础费 $2; 不与物品折扣混为一谈. D6 标签是临时刷新基价, 具体恢复见 [标签机制](<../mechanics/run-modifiers.md>).

来源: [calculate_reroll_cost](<../../../game/functions/common_events.lua#L2263-L2269>), [new_round 重置](<../../../game/functions/state_events.lua#L300-L313>), [刷新优惠券](<../../../game/card.lua#L1925-L1929>).

### Boss 重掷

固定 $10, `v_directors_cut` 每底注一次, `v_retcon` 可重复. Boss 标签重掷免这笔费用. 需要在盲注选择阶段操作, 不是战斗中花钱更换已开始的 Boss.

来源: [Boss 重掷按钮与执行](<../../../game/functions/button_callbacks.lua#L2769-L2806>).

## 8. 对 agent 决策的直接影响

- 利息按完整 $5 阶梯计算, 购买前应计算这次消费是否跨阶梯, 而不是只看保留现金的大致比例.
- 剩余出牌次数能变现, 超额打分不能. 已有足够的过关得分时战斗立即结束, 不能为了多触发经济效果继续出牌.
- 跳过没有余手/利息/商店/易腐和租金轮次; 只能按实际标签和小丑跳过效果估值.
- 租赁强制扣款在利息前, 普通结算奖金在利息后; 保留到回合结束的租赁成本不止可能的 $3, 还可能使利息降一阶.
- 折扣重新影响持有牌卖价, 免费商品卖价又可能不按 0 计算. 必须读当前 `sell_cost`, 不从购入流水猜价格.

## 9. Wiki 核对

[Balatro Wiki: Money](<https://balatrowiki.org/w/Money>) 核对了起始 $4, 黄色牌组 $14, 盲注奖金, 余手金钱, 基础利息阶梯, 租赁扣款和救场无固定盲注奖. 其债务摘要中的 "最低 $0" 应理解为没有信用卡时自主付费的限制, 不能覆盖本地 `ease_dollars` 允许强制扣款到负数的事实. 本文以本地执行顺序给出利息与结算的时间边界, 不把 wiki 列表中的显示顺序误当作逐项立即入账.
