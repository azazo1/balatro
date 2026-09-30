# 一局流程与可用操作

适用版本: Balatro 1.0.1n. 本文用于 agent 判断当前阶段能做什么, 以及行动会如何消耗资源和推进盲注. 单次出牌的计分规则见 [计分流程](<scoring.md>), 分数目标见 [盲注与 Boss](<blinds.md>).

## 1. 起始状态

以下是未应用牌组, 赌注, 挑战和教程覆盖之前的基础参数. 不要将基础弃牌次数 `3` 误当作红色牌组的实际弃牌次数.

| 参数 | 基础值 | 状态字段 |
| --- | --- | --- |
| 金钱 | $4 | `G.GAME.dollars` |
| 手牌上限 | 8 | `G.hand.config.card_limit` |
| 每回合出牌次数 | 4 | `G.GAME.round_resets.hands` |
| 每回合弃牌次数 | 3 | `G.GAME.round_resets.discards` |
| 小丑牌槽位 | 5 | `G.jokers.config.card_limit` |
| 消耗牌槽位 | 2 | `G.consumeables.config.card_limit` |
| 商店卡牌槽位 | 2 | `G.GAME.shop.joker_max` |
| 初始刷新费 | $5 | `G.GAME.base_reroll_cost` |
| 底注 Ante | 1 | `G.GAME.round_resets.ante` |
| 已开始的回合数 | 0 | `G.GAME.round` |
| 胜利所需底注 | 8 | `G.GAME.win_ante` |
| 本回合累积得分 | 0 | `G.GAME.chips` |
| 概率基础分子 | 1 | `G.GAME.probabilities.normal` |

来源: [get_starting_params](<../../../game/functions/misc_functions.lua#L1868-L1881>), [Game:init_game_object](<../../../game/game.lua#L1844-L1998>).

### 应用顺序与牌组差异

1. 创建基础游戏对象, 应用选定赌注.
2. 执行牌组 `Back:apply_to_run`.
3. 如果是挑战, 应用挑战的起始小丑, 消耗牌, 优惠券, 参数覆盖和禁用项.
4. 从最终 `starting_params` 写入金钱, 出牌/弃牌次数和刷新费用, 创建牌区.
5. 建立游戏牌组, 洗牌, 生成第一个 Boss, 本底注优惠券和小/大盲注跳过标签.
6. 新局进入 `BLIND_SELECT`, 而非商店. 所有扑克牌在牌堆, 尚未开始抽手牌.

基础牌组有 52 张, 四花色各含 `2..10, J, Q, K, A`, 没有通用意义上的两张鬼牌. 小丑牌是独立的被动效果牌, 不加入抽牌堆. 例如红色牌组在基础值上增加 1 次弃牌, 蓝色牌组增加 1 次出牌, 黄色牌组增加 $10; 其他牌组可以改变牌堆, 槽位或起始消耗牌. 最终参数要读取实际状态, 不能硬编码成同一套值.

来源: [Game:start_run 的初始化顺序](<../../../game/game.lua#L2000-L2163>), [扑克牌堆生成](<../../../game/game.lua#L2309-L2375>), [牌组参数](<../../../game/game.lua#L628-L642>), [Back:apply_to_run](<../../../game/back.lua#L174-L288>).

## 2. 状态机与操作边界

`G.STATE` 是主状态, 但它不是唯一的操作许可. 动画事件队列, `G.CONTROLLER.locked`, `STOP_USE`, 暂停覆盖层和按钮的可用性都可能暂时阻止操作. agent 应在界面稳定且目标按钮可用后才提交下一步; 不应连续重复点击正在执行的动作.

| 状态 | 数值 | agent 可用操作 / 行为 |
| --- | --- | --- |
| `BLIND_SELECT` | 7 | 选择当前可选盲注; 小/大盲注可跳过拿标签; 已有相应优惠券且资金足够时重掷 Boss. 可查看运行信息, 在条件满足时使用已有消耗牌或卖牌 |
| `DRAW_TO_HAND` | 3 | 抽牌和触发初始抽牌效果的过渡阶段, 等待 |
| `SELECTING_HAND` | 1 | 选择并调整手牌顺序, 出牌, 弃牌; 调整小丑顺序; 满足条件时使用消耗牌或卖牌 |
| `HAND_PLAYED` | 2 | 出牌动画和计分阶段, 等待. 牌已经转移到出牌区, 不要再提交一次出牌 |
| `NEW_ROUND` | 19 | 名称容易误读: 实际调用 `end_round()` 做本回合终结判定, 并非直接开始下一盲注 |
| `ROUND_EVAL` | 8 | 收入结算画面. 等总额和领取按钮完成后领取, 进入商店 |
| `SHOP` | 5 | 购买/购买并使用, 卖牌, 兑换优惠券, 开包, 刷新普通商品; 离开商店后进入 `BLIND_SELECT` |
| `TAROT_PACK` | 9 | 塔罗补充包: 在允许范围内选用牌或跳过 |
| `PLANET_PACK` | 10 | 天体补充包: 选用星球牌或跳过 |
| `SPECTRAL_PACK` | 15 | 幻灵补充包: 按可用条件选用牌或跳过 |
| `STANDARD_PACK` | 17 | 标准补充包: 选择加入牌组的扑克牌或跳过 |
| `BUFFOON_PACK` | 18 | 小丑补充包: 按槽位限制选择小丑牌或跳过 |
| `PLAY_TAROT` | 6 | 消耗牌效果执行中的过渡状态, 等待完成 |
| `GAME_OVER` | 4 | 本局结束, 只能通过覆盖菜单重新开局/回主菜单等 |
| `MENU, TUTORIAL, SPLASH, SANDBOX, DEMO_CTA` | 11, 12, 13, 14, 16 | 非正常回合决策状态, 不发送出牌动作 |

状态枚举: [globals.lua](<../../../game/globals.lua#L276-L296>). 实际转换: [Game:update_hand_played / update_draw_to_hand / update_new_round](<../../../game/game.lua#L3169-L3237>), [cash_out](<../../../game/functions/button_callbacks.lua#L2897-L2941>), [toggle_shop](<../../../game/functions/button_callbacks.lua#L2466-L2495>). 购买/包内使用的具体约束由 [商店](<shop-and-packs.md>) 和 [消耗牌机制](<../mechanics/consumable-mechanics.md>) 描述.

### 手牌行动的合法性

- 出牌选择数为 `1..5`; 空选择和超过 5 张时按钮不可用. Boss 宣告效果时 `blind.block_play` 可暂时禁止出牌.
- 弃牌要求至少选 1 张且 `discards_left > 0`; 正常手牌选择上限为 5 张. 每次主动弃牌消耗 1 次弃牌次数, 与弃掉几张无关.
- 每次出牌消耗 1 次出牌次数, 与几张实际计分无关. Boss 判定本次牌型无效时仍消耗次数和所打出的牌.
- 出牌以手牌的左右顺序转入出牌区, 所以顺序本身也是行动的一部分.
- 弃牌后从牌堆补至手牌上限, 最多只能抽剩余牌堆数量. 巨蟒 Boss 改为抽最多 3 张, 详见 [Boss 机制](<blinds.md>).
- 未使用的出牌/弃牌次数不自动结转下回合. 临时加成和永久修改应分开记录.

来源: [can_play / can_discard](<../../../game/functions/button_callbacks.lua#L2033-L2085>), [手牌默认选择上限](<../../../game/cardarea.lua#L13-L19>), [主动弃牌](<../../../game/functions/state_events.lua#L379-L448>), [play_cards_from_highlighted](<../../../game/functions/state_events.lua#L450-L488>), [抽牌](<../../../game/functions/state_events.lua#L355-L377>).

## 3. 一底注内的顺序

```text
小盲注 -> 大盲注 -> Boss 盲注 -> 底注 +1 -> 新的小盲注
```

每个盲注的选择状态属于 `Upcoming / Select / Current / Defeated / Skipped`. 必须按次序推进, 不能直接选后面的 `Upcoming` 盲注.

### 选择并完成盲注

1. `select_blind` 将回合数加 1, 记录当前盲注并调用 `new_round`.
2. 重设 `discards_left = max(0, round_resets.discards + round_bonus.discards)`, `hands_left = max(1, round_resets.hands + round_bonus.next_hands)`.
3. 清空本回合出牌/弃牌统计, 牌型本回合使用次数, 商店刷新增量和已开包记录. 初始化免费刷新次数.
4. 消耗一次性的 `round_bonus` 加成, 设置 Boss, 再触发小丑的 `setting_blind` 效果.
5. 洗牌, 抽手牌, 进入选择手牌状态.
6. 本回合得分在多次出牌间累积, 不是要求某一手单独达标.
7. 达标或次数用尽时结束回合. 成功后触发回合结束效果, 清理手牌并把弃牌重新放回牌堆. 后续每个盲注都重新使用仍然存在的完整牌组, 不是从上回合剩余牌堆接着抽.
8. 成功击败 Boss 时底注加 1, 清除 `played_this_ante`, 重新指定下底注优惠券. 在领取收入时刷新小/大盲注标签, `reset_blinds` 生成新 Boss 并重置 Boss 重掷使用标记.
9. 领取后每次都进入商店, 即使刚完成的是小盲注或最后一个 Boss. 离店再选下一盲注.

来源: [select_blind](<../../../game/functions/button_callbacks.lua#L2498-L2541>), [new_round](<../../../game/functions/state_events.lua#L290-L353>), [end_round 成功路径](<../../../game/functions/state_events.lua#L124-L281>), [reset_blinds](<../../../game/functions/common_events.lua#L2326-L2336>).

`ante` 是实际游戏参数, `blind_ante` 是在领取 Boss 结算后同步的展示/盲注阶段字段. 优惠券可以降低 `ante`, 所以有相关优惠券时不要把两者强行合并; 分数公式用实际 `round_resets.ante`.

### 跳过盲注

- 只有小盲注和大盲注提供正常跳过入口; Boss 必须面对, 可重掷或禁用效果但不能直接跳过.
- 跳过获得界面展示的标签, `skips +1`, 当前盲注标为 `Skipped`, 紧邻下一个标为 `Select`.
- 跳过不调用 `select_blind` 或 `end_round`, 不增加已开始回合数, 不触发回合结算, 不发盲注奖金/余手奖金/利息, 不访问商店, 不扣租金, 不减少易腐寿命.
- 跳过会触发小丑 `skip_blind`, 再处理标签 `immediate` 和 `new_blind_choice`; 标签可能直接给钱, 开包或重掷 Boss. 这些收益是标签收益而非回合结算.
- 可以连续跳过小/大盲注, 直接面对本底注 Boss, 但因此失去两个实际战斗回合和两次正常商店访问.

来源: [skip_blind](<../../../game/functions/button_callbacks.lua#L2725-L2767>), [只有 Small / Big 有标签入口](<../../../game/functions/UI_definitions.lua#L1520-L1527>).

## 4. 胜负与无尽模式

### 回合和本局失败

回合结束先检查 `G.GAME.chips - blind.chips >= 0`. 达标则成功; 未达标默认为失败, 接着逐个小丑执行 `end_of_round` 并允许 `saved` 效果改变结果. 骷髅先生 Mr. Bones (`j_mr_bones`) 未失效时可在总分达到目标的 25% 后救场并销毁自身. 救场继续推进盲注, 但不领取本盲注固定奖励金.

除了出牌次数耗尽, 当手牌/牌堆/出牌区都空时也进入终结判定. 当手牌上限 `<=0` 且手牌为空时, 正常抽牌函数直接进入 `GAME_OVER`, 不经过普通 `end_round` 救场路径. 塔罗/幻灵开包抽牌不走这条直接失败检查.

来源: [end_round 的成功与 saved 判定](<../../../game/functions/state_events.lua#L87-L123>), [Mr. Bones](<../../../game/card.lua#L3047-L3061>), [无牌终结](<../../../game/game.lua#L3038-L3046>), [手牌上限直接失败](<../../../game/functions/state_events.lua#L355-L360>), [救场无盲注奖](<../../../game/functions/state_events.lua#L1139-L1146>).

### 一局胜利

正常目标是成功通过 `ante == win_ante == 8` 的 Boss. 胜利通知在 `ROUND_EVAL` 出现, 是暂停覆盖菜单, 不一定是新的 `G.STATE`. 选择无尽模式只是关闭覆盖菜单, 保留当前牌组/小丑/钱/牌型等级和后续结算流程, 不重开一局.

- 无尽模式从后续 Ante 9 继续, 基础目标增长公式改变, 详见 [目标分数](<blinds.md>).
- 决战 Boss 在 `ante % win_ante == 0` 且 `ante >=2` 的底注出现, 正常是 8, 16, 24, 32.
- 达成胜利后仍可能在无尽模式失败; 不要把后续失败当作此前未赢过.
- 普通非种子且非挑战胜利会登记牌组/小丑胜利与相关解锁, 种子局不走普通解锁路径; 挑战有自己的完成登记.
- 实现细节: `end_round` 在检查 `game_over` 分支前就写 `G.GAME.won = true` 条件标记. 因此 agent 判断真正胜利应看成功路径的 `win_notified`/胜利菜单或实际 Boss 成功, 不应单独依赖 `won` 字段.

来源: [win_game](<../../../game/functions/state_events.lua#L1-L85>), [胜利判定与通知](<../../../game/functions/state_events.lua#L111-L169>), [胜利菜单的无尽按钮](<../../../game/functions/UI_definitions.lua#L2785>).

## 5. 决策前最小检查清单

- 读取实际状态和按钮许可, 不在过渡阶段操作.
- 记录当前底注, 盲注 id, 是否 disabled, 目标分和当前累计得分.
- 记录剩余出牌/弃牌次数, 手中牌和剩余牌堆; 背面牌不得当作已观测正面牌使用.
- 开始盲注前查看 Boss 效果和将到期/租赁的小丑; 跳过不是免费的经济轮次.
- 达标后没有额外出牌机会; 自动进入回合结束效果和结算.
- 结算收入与当前金钱不同, 未领取之前不要将全部结算栏收入视为可支付现金.

## 6. Wiki 核对

[Balatro Wiki: Blinds and Antes](<https://balatrowiki.org/w/Blinds>) 与本地代码一致地描述小/大/Boss 顺序, 跳过不打 Boss, 完成 Ante 8 后可继续无尽模式. 数字和状态边界以上述本地 1.0.1n 源码为准; 本文不以 wiki 的其他版本或技巧描述覆盖代码规则.
