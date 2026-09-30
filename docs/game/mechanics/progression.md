# 解锁与长期进度

本文件解释新档解锁, 发现, 挑战开放和成就. 它们改变未来可选择内容和候选池, 但不是当前局内倍率或计分奖励. 每张卡的具体门槛见 [小丑](<../cards/jokers.md>), [优惠券](<../cards/vouchers.md>) 和 [牌组](<../cards/decks.md>) 目录.

## 解锁, 发现和可生成的区别

- `unlocked`: 能否进入通常候选池. 新档有 105 张默认解锁的小丑和 45 张非默认解锁的小丑, 后者包括 5 张传奇.
- `discovered`: 图鉴是否已记录. 已解锁未发现的卡仍可能生成, 只是图鉴显示未发现. 小丑 `j_joker` 初始已发现.
- 能生成: 还要通过本局重复限制, 牌组增强门槛, 池标记, 优惠券前置和禁用表. 例如解锁卡文迪什不意味着大麦克香蕉未灭绝时就能生成它.
- 实际存档状态必须另行读取. [结构化目录](<../data/catalog.json>) 的 `initially_unlocked` 只记录原型新档默认值.

来源: [原型](<../../../game/game.lua#L368-L526>), [元进度合并](<../../../game/game.lua#L745-L761>), [候选池](<../../../game/functions/common_events.lua#L1933-L2055>). 候选算法见 [随机池](<../rules/random-pools.md>).

## 哪些模式记录进度

| 模式 | 普通卡牌解锁/发现 | 普通胜利记录与小丑胜利贴纸 | 挑战完成记录 |
| --- | --- | --- | --- |
| 普通非指定种子局 | 可以 | 可以 | 不适用 |
| 指定种子局 `seeded` | 不记录 | 不记录 | 不应据此推断挑战合法 |
| 挑战局 `challenge` | 不记录普通解锁/发现 | 不记录普通胜利贴纸 | 按挑战完成路径记录 |

`check_for_unlock` 先排除指定种子, 对 `win_challenge` 处理挑战成就后再排除挑战的普通解锁. `unlock_card` 与 `discover_card` 本身也排除 seeded/challenge. 普通胜利的统计写入和挑战胜利的统计写入是不同分支.

来源: [`check_for_unlock`](<../../../game/functions/common_events.lua#L1163-L1178>), [`unlock_card`](<../../../game/functions/common_events.lua#L1628-L1639>), [`discover_card`](<../../../game/functions/common_events.lua#L1879-L1893>), [`win_game`](<../../../game/functions/state_events.lua#L1-L24>).

## 解锁条件原型如何解释

卡面解锁说明有时省略实现细节. `unlock_condition.type` 是事件名或职业统计名, 不是可以任意轮询求值的字符串.

| 条件类型 | 实际判定 |
| --- | --- |
| `c_*` 职业统计 | 在 `career_stat` 事件, 对应存档累计统计 `>= extra` |
| `discover_amount` | 对应已发现数量达到 `amount`, 或塔罗数量达到 `tarot_count`, 或星球数量达到 `planet_count` |
| `hand` | 本次实际判定牌型 `args.handname == extra`, 不按牌型的子结构匹配 |
| `run_card_replays` | 本局仍存在的某张扑克牌 `base.times_played >= extra`, 这是打出计数而非逐牌重触发次数 |
| `discover_planets` | 保留接收分支要求已发现星球原型至少 9. 当前原型没有用此 type, 也未找到发送事件; 天文学家 `j_astronomer` 实际走 `discover_amount` 的 `planet_count=12` |
| `chip_score` | 某一次出牌的分数 `>= chips`, 不是当前盲注累计分数 |
| `money` | 当前金钱 `>= extra` |
| `ante_up` | 本次上升到的底注 `== ante`, 不是任意 `>=` |
| `win_deck` | 指定牌组已有任意赌注的胜利记录 |
| `win_stake` | 最高牌组胜利赌注达到指定 `stake` |
| `win` | 胜利时实际回合数 `<= n_rounds`; 跳过盲注不计作实际挑战回合 |
| `win_no_hand` | 胜利时指定牌型的 `played == 0`, 指牌型判定结果, 不等于出牌不含其子结构 |
| `min_hand_size` | `G.hand.config.card_limit <= extra` |
| `interest_streak` | 达到利息上限的连续回合统计 `>= extra` |
| `run_redeem` | 本局 `used_vouchers` 的键数 `>= extra`; 这个解锁分支没有减去起始优惠券数 |
| `have_edition` | 当前有 `edition` 的小丑张数 `>= extra`, 并非要求各版本互异 |
| `modify_deck` + `suit` | 完整牌组中的基础花色 `base.suit` 达到 `count`, 不按万能牌的视为花色扩展 |
| `modify_deck` + `enhancement` | 完整牌组的 `ability.name` 对应增强达到 `count` |
| `modify_deck` + `tally` | 完整牌组中 `ability.set == 'Enhanced'` 张数达到 `count` |
| `modify_jokers` + `polychrome` | 当前多彩版本小丑张数达到 `count` |
| `blind_discoveries` | 已发现盲注数达到 `extra` |
| `blank_redeems` | 存档空白优惠券使用计数达到 `extra` |
| `double_gold` | 已发出金增强加金蜡封事件 |
| `continue_game` | 加载保存的局时发出的继续游戏事件, 不是进入无尽模式 |

来源: [`check_for_unlock` 条件匹配](<../../../game/functions/common_events.lua#L1309-L1529>), [胜利事件发送](<../../../game/functions/state_events.lua#L1-L24>). 目录中个别原型存在已默认解锁后的遗留条件或隐藏空条件, 不应把它们当成新的玩法要求.

条件达成不意味着通知立即显示. 主菜单初始化也会检查全部 `career_stat` 和 `blind_discoveries`, 见 [菜单检查](<../../../game/game.lua#L1672-L1676>). 职业统计增加函数本身不统一派发解锁检查. `discover_planets` 的旧接收分支不能覆盖 [天文学家的当前原型](<../../../game/game.lua#L519>), 也不能代替对应事件是否实际发出的判断.

## 特殊小丑解锁

| ID | 实际条件 |
| --- | --- |
| `j_blueprint` | 普通非指定种子局胜利 |
| `j_invisible` | 胜利且本局 `max_jokers <= 4`, 不是只在胜利瞬间最多 4 张 |
| `j_matador` | 一次出牌击败 Boss, 且当前剩余弃牌数等于 `round_resets.discards` |
| `j_troubadour` | 职业统计中的单次出牌结束回合连续次数达到 5 |
| `j_hanging_chad` | 击败 Boss 且最后打出的判定牌型为高牌 |
| `j_seeing_double` | 一次打出的牌中至少 4 张 `get_id()==7` 且 `is_suit('Clubs')` |
| `j_ticket` | 一次打出的牌中至少 5 张黄金增强牌 |
| `j_hit_the_road` | 一次弃牌至少 5 张 J |
| `j_brainstorm` | 一次弃牌判定含同花顺, 且所有弃牌的 `get_id() >= 10`. 实现的最小值变量以 10 初始化, 四指存在时不能额外强加必须严格 5 张 `10/J/Q/K/A` |
| `j_shoot_the_moon` | 检查时抽牌堆和留手牌中没有非石头的基础红桃牌; 实现不是简单查看丢弃堆某一标签 |
| 5 张传奇 | 从灵魂牌生成. 隐藏原型的空条件不是常规任务解锁 |

`max_jokers` 在小丑加入卡槽时更新本局最大同时持有张数, 会按实际对象数量计算, 负片小丑也计数. 出牌和弃牌特殊解锁检查的输入是本次打出/弃掉的全部牌, 不应改成只检查计分牌.

来源: [特殊解锁](<../../../game/functions/common_events.lua#L1500-L1618>), [最大持有数](<../../../game/cardarea.lua#L55-L61>), [出牌特殊检查](<../../../game/functions/state_events.lua#L507-L521>), [弃牌特殊检查](<../../../game/functions/state_events.lua#L431>), [灵魂机制](<consumable-mechanics.md>).

## 牌组, 赌注与挑战开放

- 红色牌组初始开放; 其他 14 个普通牌组按发现数量, 指定牌组获胜或最高赌注获胜开放. 完整对应表见 [牌组机制](<run-modifiers.md>).
- 每个牌组的赌注开放与该牌组胜利记录关联. 高赌注胜利会补齐该牌组低于该赌注的胜利记录, 不代表每个其他牌组都已通关.
- 在 5 个不同普通牌组取得白赌注胜利记录后, 初次开放前 5 个挑战. 高赌注胜利补齐白赌注记录, 因此也可计入这 5 个牌组.
- 已开放挑战时, 开放数量为 `min(20, 已完成挑战数 + 5)`. 完成一个新挑战增加一个可选挑战, 重复完成同一挑战不增加独立完成数量.

来源: [牌组胜利](<../../../game/functions/misc_functions.lua#L1097-L1108>), [`set_challenge_unlock`](<../../../game/functions/misc_functions.lua#L1112-L1134>), [所需牌组数](<../../../game/globals.lua#L340>), [挑战菜单](<../../../game/functions/UI_definitions.lua#L4939-L4970>).

## 胜利赌注贴纸

普通非指定种子局胜利时, 对当时仍持有的每张小丑登记该赌注胜利. 图鉴显示它参与胜利的最高赌注颜色. 小丑只被削弱不等于消失, 仍可登记; 已卖出或摧毁的小丑不在胜利持有集合中.

这些图鉴贴纸没有倍率或租金效果. 它们与 `eternal`, `perishable`, `rental` 的局内修饰是两回事.

来源: [`set_joker_win` / `get_joker_win_sticker`](<../../../game/functions/misc_functions.lua#L1047-L1071>), [胜利调用条件](<../../../game/functions/state_events.lua#L1-L4>).

## 31 个成就条件

成就本身不改卡牌属性. 下表列出与玩法相关的事件条件, 不要求自动玩 agent 把完成成就作为普通通关目标.

| 成就 ID | 条件 |
| --- | --- |
| `ante_up`, `ante_upper` | 底注上升事件达到 4/8 |
| `heads_up` | 普通胜利 |
| `low_stakes`, `mid_stakes`, `high_stakes` | 最高牌组胜利赌注达到 2/4/8 |
| `card_player`, `card_discarder` | 累计打出/弃掉 2500 张牌 |
| `nest_egg` | 当前金钱至少 $400 |
| `flushed` | 判定为同花的计分集合全部为万能增强牌 |
| `speedrunner` | 不超过 12 个实际回合获胜 |
| `roi` | 本局优惠券数减去起始优惠券数至少 5, 且当前底注不超过 4 |
| `shattered` | 同一次 `shatter` 事件至少 2 张牌 |
| `royale` | 出牌显示名为皇家同花顺 |
| `retrograde` | 升级牌型到等级至少 10 |
| `_10k`, `_1000k`, `_100000k` | 单次出牌至少 10,000 / 1,000,000 / 100,000,000 分 |
| `tiny_hands`, `big_hands` | modify_deck 事件时 `G.deck.config.card_limit <= 20` / `>= 80` |
| `you_get_what_you_get` | 获胜且商店重掷次数为 0 |
| `rule_bender`, `rule_breaker` | 完成一个挑战 / 所有挑战 |
| `legendary` | 生成传奇小丑事件 |
| `astronomy`, `cartomancy`, `clairvoyance`, `extreme_couponer` | 分别发现全部星球/塔罗/幻灵/优惠券 |
| `completionist` | 总发现进度完成 |
| `completionist_plus` | 所有牌组赌注进度完成 |
| `completionist_plus_plus` | 所有小丑胜利赌注贴纸进度完成 |

来源: [成就判定](<../../../game/functions/common_events.lua#L1163-L1305>), [31 项 ID](<../../../game/functions/common_events.lua#L1643-L1675>). 平台可能禁用成就设施; `all_unlocked` 档的成就写入也会被跳过, 不影响本手册中的局内计分规则.
