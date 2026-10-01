# 赌注与贴纸

适用版本: Balatro 1.0.1o. 赌注 Stake 是一局开始时选定的难度, 共 8 级, 后一级累计之前所有效果. 本文区分战斗贴纸与收藏中的胜利颜色贴纸, 并给出生成概率和寿命语义.

## 1. 8 级累计效果

| 等级 | id | 中文 / 英文 | 本级新增效果 | 分数 scaling |
| --- | --- | --- | --- | ---: |
| 1 | `stake_white` | 白注 / White Stake | 基础规则 | 1 |
| 2 | `stake_red` | 红注 / Red Stake | 小盲注固定盲注奖金为 $0, 但余手钱, 小丑收益和利息仍可获得 | 1 |
| 3 | `stake_green` | 绿注 / Green Stake | 盲注基础分改用第二档增长表 | 2 |
| 4 | `stake_black` | 黑注 / Black Stake | 商店商品小丑和包内小丑可能永恒 | 2 |
| 5 | `stake_blue` | 蓝注 / Blue Stake | 起始每回合弃牌次数 -1, 在牌组加成前应用 | 2 |
| 6 | `stake_purple` | 紫注 / Purple Stake | 盲注基础分改用第三档增长表, 取代第二档而非再相乘 | 3 |
| 7 | `stake_orange` | 橙注 / Orange Stake | 商店商品小丑和包内小丑可能易腐 | 3 |
| 8 | `stake_gold` | 金注 / Gold Stake | 商店商品小丑和包内小丑可能租赁, 即中文卡面中的租用 | 3 |

来源: [Game:start_run 难度应用](<../../../game/game.lua#L2031-L2043>), [赌注名称](<../../../game/localization/zh_CN.lua#L2538-L2600>), [贴纸生成](<../../../game/functions/common_events.lua#L2133-L2147>).

金注同时具有: 小盲注固定奖金为 0, 第三档盲注分数, 永恒/易腐/租赁生成, 弃牌 -1. 无牌组加成时弃牌是 `3-1=2`; 红色牌组则是 `3-1+1=3`. 金注并不会削减手牌上限. 橙注并不会按底注提高补充包售价. 这些是本地 1.0.1o 规则, 不要套用早期版本的橙/金注说明.

### 全部赌注的 Ante 1-8 基础目标

详见 [盲注分数表](<blinds.md#ante-1-8-基础分表>). 该表是小盲注基础, 大盲注乘 1.5, 普通 Boss 通常乘 2, 围墙/针/靛紫之杯各用自己的系数. 牌组目标系数另乘, 不被赌注替代.

## 2. 贴纸生成算法

`create_card` 只在创建小丑且目标牌区为 `G.shop_jokers` 或 `G.pack_cards` 时进行赌注贴纸抽样. 通常涵盖直接商店商品和小丑补充包. 普通效果在持有区直接生成的小丑不因难度自动抽这些贴纸, 但复制会继承既有贴纸, 挑战也可以另外强制永恒.

### 永恒与易腐共用一次抽样

令 `p = pseudorandom(...)`:

```text
if enable_eternals_in_shop and p > 0.7:
    尝试永恒
elseif enable_perishables_in_shop and 0.4 < p <= 0.7:
    尝试易腐
else:
    不设置这两种贴纸
```

| 赌注 | 尝试永恒 | 尝试易腐 | 没有这两种贴纸的基础比例 |
| --- | ---: | ---: | ---: |
| 白/红/绿 | 0 | 0 | 100% |
| 黑/蓝/紫 | 30% | 0 | 70% |
| 橙/金 | 30% | 30% | 40% |

这是抽样区间的名义比例, 不是保证总体可见卡牌都按这个比例带贴纸. `Card:set_eternal` 还检查 `center.eternal_compat`, `Card:set_perishable` 检查 `center.perishable_compat`; 不兼容就不设置. 抽到永恒区间但该卡不兼容时, 不会回退改抽易腐. 永恒和易腐互斥.

### 租赁另抽一次

金注另一次 `pseudorandom(...) >0.7` 尝试租赁, 名义比例 30%, 与永恒/易腐区间抽样分开. 租赁可和永恒或易腐共存, 也可单独存在. 版本 Edition 抽样是后续另一个维度, 负片或多彩不排斥这些贴纸.

来源: [create_card](<../../../game/functions/common_events.lua#L2133-L2151>), [set_eternal / set_perishable / set_rental](<../../../game/card.lua#L506-L524>).

## 3. 永恒 Eternal

- 不能正常卖出, 也不能被那些检查永恒保护的销毁效果摧毁.
- 永恒不等于不能被 Boss 削弱, 不等于停止扣租金, 也不代表其效果能复制.
- 在只能销毁非永恒小丑的效果中, 永恒通常保留; 不要把 "销毁所有其他小丑" 的卡面简写当作能破坏永恒的保证.
- 自毁型小丑通常 `eternal_compat =false`, 因此不会由赌注正常获得永恒; 详细卡牌兼容字段由 [卡牌目录](<../cards/jokers.md>) 给出.

来源: [Card:set_eternal](<../../../game/card.lua#L506-L511>), [Card:can_sell_card](<../../../game/card.lua#L1640-L1653>). 各销毁效果的额外条件见 [小丑机制](<../mechanics/joker-mechanics.md>) 和 [消耗牌机制](<../mechanics/consumable-mechanics.md>).

## 4. 易腐 Perishable

- 生成时 `perish_tally = G.GAME.perishable_rounds =5`.
- 每次实际盲注结束时, 先执行该小丑 `end_of_round` 效果, 再租赁扣款, 再易腐倒计时.
- 第 1..4 次结束: 寿命从 5 减到 1. 第 5 次结束: 寿命变 0, 调用 `set_debuff`, 长久失效. 第 5 次出牌期间仍能工作, 但之后结算栏调用 `calculate_dollar_bonus` 时已失效, 因而黄金小丑之类不会发这次结算型奖金.
- 计数单位是实际回合, 不是每次出牌, 不是每个底注. 跳过小/大盲注不减少寿命.
- 已经因 Boss 被削弱也继续减寿命. 易腐到 0 后不因 Boss 禁用或回合结束恢复.
- 失效牌仍占用槽位, 能卖出, 若同时租赁仍继续收租. 不是到期时自动从小丑区删除.
- 本版倒计时也位于失败分支判定之前, 所以失败回合会执行, 但本局随之结束时通常无后续决策意义.
- 对同一张牌再次合法调用 `set_perishable` 会重置寿命为 5; 普通结束/禁用不会调用它. 复制效果对寿命如何继承需按具体消耗牌逻辑处理.

来源: [初始参数](<../../../game/game.lua#L1896-L1897>), [end_round](<../../../game/functions/state_events.lua#L99-L110>), [calculate_perishable](<../../../game/card.lua#L2278-L2289>), [到期削弱的优先级](<../../../game/card.lua#L526-L533>).

## 5. 租赁 Rental

- 购入价格被 `Card:set_cost` 最后覆盖为 $1, 不受版本溢价和折扣改变这个覆盖值. 商品免费标签可以之后再覆盖为 $0.
- 每个实际盲注结束扣 `rental_rate =3`, 每张分别扣. 不要求卡牌有效, 不要求玩家有 $3.
- 扣款在回合结束小丑效果之后, 在手中金牌/蓝蜡封等回合结束效果与结算前执行. 因此能压低用于计算利息的现金.
- 跳过不扣款, 主动卖掉后不再承担以后的租金.
- 基础卖价 $1, 但蛋/礼品卡等 `extra_value` 可在此之上增加, 不是固定永远只能卖 $1.

来源: [Card:set_cost](<../../../game/card.lua#L369-L385>), [calculate_rental](<../../../game/card.lua#L2271-L2276>), [回合结束顺序](<../../../game/functions/state_events.lua#L99-L110>). 详见 [经济](<economy.md>).

## 6. 赌注解锁与胜利贴纸

正常非种子/非挑战局在完成 Ante 8 时登记牌组和当前小丑的胜利, 下一难度是按牌组的胜利进度开放, 不是赢一个牌组就能给所有牌组跳过前置赌注. 收藏里的白/红/.../金色胜利贴纸是完成记录, 没有永恒/易腐/租赁那样的战斗效果. 所有难度完成后的持牌记录与战斗贴纸应存成不同字段.

来源: [win_game](<../../../game/functions/state_events.lua#L1-L24>), [set_deck_win](<../../../game/functions/misc_functions.lua#L1097-L1109>), [Wiki: Stakes](<https://balatrowiki.org/w/Stakes>). wiki 的 8 级顺序和本地 [难度应用代码](<../../../game/game.lua#L2031-L2041>) 一致; 生成精确区间和包内作用范围以上述本地源码为准.
