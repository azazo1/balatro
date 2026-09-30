# 消耗牌使用机制

适用版本: Balatro 1.0.1n. 本文件定义塔罗牌 Tarot, 星球牌 Planet 和幻灵牌 Spectral 的合法使用动作及其状态变化, 不代替卡面目录. 名称和原型 ID 分别见 [塔罗牌](<../cards/tarots.md>), [星球牌](<../cards/planets.md>) 和 [幻灵牌](<../cards/spectrals.md>).

## 1. 所有消耗牌共享的动作约束

### 1.1 状态门控

可用性分两层, agent 必须同时满足而不能只看卡面:

1. 不能正在出牌结算: `G.play.cards` 非空, `G.CONTROLLER.locked` 为真, 或 `G.GAME.STOP_USE > 0` 时, 普通 `can_use_consumeable()` 返回 false.
2. `HAND_PLAYED`, `DRAW_TO_HAND`, `PLAY_TAROT` 三个状态禁止普通使用. 内部参数 `any_state=true` 可绕过这三个状态, `skip_check=true` 可绕过第 1 层, 不是玩家动作的许可.
3. 不依赖手牌的牌可以在稳定的商店, 盲注选择, 回合结算或补充包界面使用. 它们的专属条件仍然生效.
4. 需要高亮选择或修改全手牌的牌, 通常只能在 `SELECTING_HAND`, `TAROT_PACK`, `SPECTRAL_PACK`, `PLANET_PACK` 使用. 但光环 `c_aura` 的独立分支只检查恰好选中一张无版本手牌, 不在这一状态集合分支内.
5. 状态允许不等于有目标. 天体包通常没有为修改而抽出的手牌, 空手牌时仍不能满足选择条件. 修改对象是当前 `G.hand`, 不是尚未抽出的牌堆, 弃牌堆或整个牌组.

来源: [card.lua:1523-1579](<../../../game/card.lua#L1523-L1579>), `Card:can_use_consumeable`.

### 1.2 选择与空间

- 表中 `1..2`, `1..3` 是允许只选少于卡面张数的范围. 下限默认 1, 死神下限为 2. `mod_num = min(5, max_highlighted)`.
- 选择对象只能是 `G.hand.highlighted`. 不以点击先后决定复制方向, 不自动补选.
- 消耗牌空位条件: `#G.consumeables.cards < card_limit` 或使用牌自身在消耗牌栏. 后者允许满栏使用, 因为 `G.FUNCS.use_card` 会先把使用牌移出其区域, 再生成新牌.
- 小丑空位条件: `#G.jokers.cards < card_limit` 或使用牌自身在小丑区. 正常消耗牌不会在小丑区, 所以审判/灵魂/幽灵通常必须已有空位, 不假设生成牌随机带负片就可以超限.
- 生成的游戏牌可直接加入手牌, 并加入 `G.playing_cards`, 不受普通消耗牌槽位或小丑槽位限制.
- 负片消耗牌消耗后自身增加的槽位也会随移除失去. 生成效果使用事件执行时的实际槽位, 不应长期保留负片牌提供的容量.

来源: [card.lua:1550-1575](<../../../game/card.lua#L1550-L1575>), [card.lua:4153-4155](<../../../game/card.lua#L4153-L4155>), [button_callbacks.lua:2194-2205](<../../../game/functions/button_callbacks.lua#L2194-L2205>), `use_card`.

### 1.3 原子操作与副作用

玩家使用后, 该消耗牌被消耗, 不增加出牌或弃牌计数. `use_consumeable` 开始时记录使用统计, 随后若使用牌自身 `debuff` 为真会直接停止实际效果. 此函数本身未将被选目标牌的 debuff 当作不可修改条件.

使用动作会触发每张小丑的 `using_consumeable` context. 删除游戏牌会向小丑传递 `remove_playing_cards`, 新增游戏牌会传递 `playing_card_added`. 复制与摧毁不能简单视作同一类动作: 死神是原位覆盖, 不增加牌数, 不触发新增游戏牌通知.

来源: [card.lua:1091-1097](<../../../game/card.lua#L1091-L1097>), [card.lua:1368-1371](<../../../game/card.lua#L1368-L1371>), [button_callbacks.lua:2194-2205](<../../../game/functions/button_callbacks.lua#L2194-L2205>).

## 2. 塔罗牌: 22 张的使用条件

下表中的 "稳定状态" 指通过 1.1 的普通门控, "手牌状态" 指 1.1 第 4 项的状态集合. "增强" 会替换旧增强, 而不是叠加第二种增强; 版本和蜡封是独立字段, 不因此清除.

| ID / 中文名 / English | 选择与额外条件 | 精确效果 |
|---|---|---|
| `c_fool` 愚者 / The Fool | 稳定状态; 消耗牌空间条件; `last_tarot_planet` 存在且不是 `c_fool` | 生成一张该 ID 的新基础塔罗/星球牌. 不复制此前实物的版本 |
| `c_magician` 魔术师 / The Magician | 手牌状态, 选 `1..2` | 变为幸运牌 `m_lucky` |
| `c_high_priestess` 女祭司 / The High Priestess | 稳定状态; 消耗牌空间条件 | 按实际可用空间生成最多 2 张随机星球牌 |
| `c_empress` 皇后 / The Empress | 手牌状态, 选 `1..2` | 变为倍率牌 `m_mult` |
| `c_emperor` 皇帝 / The Emperor | 稳定状态; 消耗牌空间条件 | 按实际可用空间生成最多 2 张随机塔罗牌 |
| `c_heirophant` 教皇 / The Hierophant | 手牌状态, 选 `1..2` | 变为奖励牌 `m_bonus`; ID 的拼写 `heirophant` 必须保留 |
| `c_lovers` 恋人 / The Lovers | 手牌状态, 选 1 | 变为万能牌 `m_wild` |
| `c_chariot` 战车 / The Chariot | 手牌状态, 选 1 | 变为钢铁牌 `m_steel` |
| `c_justice` 正义 / Justice | 手牌状态, 选 1 | 变为玻璃牌 `m_glass` |
| `c_hermit` 隐者 / The Hermit | 稳定状态; 无目标或空间要求 | 加钱 `max(0, min(当前资金, 20))`; 负资金不加钱, 不是将债务翻倍 |
| `c_wheel_of_fortune` 命运之轮 / The Wheel of Fortune | 稳定状态; 至少一张无版本的小丑 | 以 `probabilities.normal / 4` 成功, 成功后给随机符合条件小丑添加闪箔/镭射/多彩 |
| `c_strength` 力量 / Strength | 手牌状态, 选 `1..2` | 每张基础点数加 1, `K -> A`, `A -> 2`; 保留花色和增强/版本/蜡封 |
| `c_hanged_man` 倒吊人 / The Hanged Man | 手牌状态, 选 `1..2` | 永久删除所选游戏牌. 玻璃牌用 shatter 路径, 非玻璃用 dissolve 路径 |
| `c_death` 死神 / Death | 手牌状态, 恰好选 2 | 以位置最右的牌为模板, 覆盖左侧牌, 见 2.2 |
| `c_temperance` 节制 / Temperance | 稳定状态; 可无小丑 | 加钱 `min(50, 所有当前小丑 sell_cost 之和)`, 不出售小丑. 数值由 `Card:update` 更新到 `ability.money` |
| `c_devil` 恶魔 / The Devil | 手牌状态, 选 1 | 变为黄金牌 `m_gold` |
| `c_tower` 塔 / The Tower | 手牌状态, 选 1 | 变为石头牌 `m_stone`; 底层点数/花色还在, 但石头增强的计分规则隐藏它们 |
| `c_star` 星星 / The Star | 手牌状态, 选 `1..3` | 花色变为方片 Diamonds |
| `c_moon` 月亮 / The Moon | 手牌状态, 选 `1..3` | 花色变为梅花 Clubs |
| `c_sun` 太阳 / The Sun | 手牌状态, 选 `1..3` | 花色变为红桃 Hearts |
| `c_judgement` 审判 / Judgement | 稳定状态; 小丑空位条件 | 从普通小丑生成逻辑生成一张随机小丑, 不是传奇生成 |
| `c_world` 世界 / The World | 手牌状态, 选 `1..3` | 花色变为黑桃 Spades |

数值原型: [game.lua:532-554](<../../../game/game.lua#L532-L554>). 实现: [card.lua:1101-1151](<../../../game/card.lua#L1101-L1151>), [card.lua:1269-1520](<../../../game/card.lua#L1269-L1520>), [card.lua:4167-4174](<../../../game/card.lua#L4167-L4174>).

### 2.1 愚者的记录时序

`set_consumeable_usage` 只对塔罗/星球安排 `last_tarot_planet` 更新, 使用幻灵不覆盖它. 愚者自身也会被写入记录, 因此成功用愚者后, 在另一张塔罗/星球使用之前不能连续用另一张愚者.

记录更新经过两层 immediate 事件, 当前愚者的生成过程仍引用先前记录, 不是误生成愚者自身. 被销毁/出售/购买而未使用的牌不更新记录. `copier` 模式不记录, 对应重复执行效果而非独立玩家使用. 该记录只存 ID, 不存实物成长/版本数据.

来源: [misc_functions.lua:1184-1225](<../../../game/functions/misc_functions.lua#L1184-L1225>), `set_consumeable_usage`, [card.lua:1373-1384](<../../../game/card.lua#L1373-L1384>).

### 2.2 死神的复制方向和字段

算法取所选牌中 `T.x` 最大者为源牌, 调用 `copy_card(源牌, 另一张牌)`. 所以动作的文字 "左变成右" 是覆盖方向, 信息流实际是右牌复制到左牌. 先调整手牌左右顺序, 再选中两张和使用; 高亮先后顺序没有意义.

覆盖包含基础点数/花色, 增强, 完整 ability 表及其中的永久筹码 `perma_bonus`/永久削弱字段, 版本, 蜡封, debuff, pinned. 牌组游戏牌总数不变. `copy_card` 不是只复制图案或花色的浅效果.

来源: [card.lua:1111-1119](<../../../game/card.lua#L1111-L1119>), [common_events.lua:2156-2180](<../../../game/functions/common_events.lua#L2156-L2180>), `copy_card`.

### 2.3 命运之轮和光环的概率

令 `p = G.GAME.probabilities.normal`, 默认 1. 命运之轮成功判定为随机数 `< p/4`, `j_oops` 会提高这个分子. 符合条件的候选仅是无版本小丑, 不覆盖已有版本; 永恒不排除成为目标.

成功后的 `poll_edition(..., nil, true, true)` 禁用负片并保证版本, 分布为闪箔 50%, 镭射 35%, 多彩 15%. 光环使用同一分布, 但没有前置 `p/4` 失败判定. 打磨/焕彩的 `edition_rate` 不影响这个 guaranteed 分支.

来源: [card.lua:1467-1486](<../../../game/card.lua#L1467-L1486>), [card.lua:4209-4222](<../../../game/card.lua#L4209-L4222>), [common_events.lua:2055-2079](<../../../game/functions/common_events.lua#L2055-L2079>), `poll_edition`.

## 3. 星球牌: 12 张

所有星球牌均在稳定状态可使用, 不需要选中游戏牌, 不要求有手牌, 不要求额外消耗牌空位. 使用一张使对应牌型等级 `+1`. 不修改单张游戏牌. 隐藏牌型是否已出现影响常规生成池, 不额外限制已经拿到的星球牌使用.

| ID / 中文名 / English | 对应牌型 | 每级筹码增量 | 每级倍率增量 |
|---|---|---:|---:|
| `c_mercury` 水星 / Mercury | 一对 Pair | 15 | 1 |
| `c_venus` 金星 / Venus | 三条 Three of a Kind | 20 | 2 |
| `c_earth` 地球 / Earth | 葫芦 Full House | 25 | 2 |
| `c_mars` 火星 / Mars | 四条 Four of a Kind | 30 | 3 |
| `c_jupiter` 木星 / Jupiter | 同花 Flush | 15 | 2 |
| `c_saturn` 土星 / Saturn | 顺子 Straight | 30 | 3 |
| `c_uranus` 天王星 / Uranus | 两对 Two Pair | 20 | 1 |
| `c_neptune` 海王星 / Neptune | 同花顺 Straight Flush | 40 | 4 |
| `c_pluto` 冥王星 / Pluto | 高牌 High Card | 10 | 1 |
| `c_planet_x` X 行星 / Planet X | 五条 Five of a Kind | 35 | 3 |
| `c_ceres` 谷神星 / Ceres | 同花葫芦 Flush House | 40 | 4 |
| `c_eris` 阋神星 / Eris | 同花五条 Flush Five | 50 | 3 |

新等级 `L = max(0, 旧等级 + amount)`, 新倍率为 `max(s_mult + l_mult * (L-1), 1)`, 新筹码为 `max(s_chips + l_chips * (L-1), 0)`. `level_up_hand` 通用公式允许 0 级, 但本版本手臂 The Arm 仅在旧等级大于 1 时降级, 不会把 1 级降至 0 级. 升级应按公式重算, 不能永远只在现值上加增量. 黑洞对全部 12 种牌型应用相同升级逻辑, 包括尚未显示的牌型. 手臂的下限见 [blind.lua:550-555](<../../../game/blind.lua#L550-L555>).

持有天文台 `v_observatory` 时, 消耗牌栏内对应当前牌型的每张星球牌分别给 `X1.5` 倍率, 而不消耗该星球牌. 使用它会失去这个持有收益, 但获得永久等级提升. 具体计分位置见 [计分规则](<../rules/scoring.md>).

来源: [game.lua:556-568](<../../../game/game.lua#L556-L568>), [game.lua:1984-1995](<../../../game/game.lua#L1984-L1995>), [common_events.lua:464-468](<../../../game/functions/common_events.lua#L464-L468>), `level_up_hand`, [card.lua:2291-2301](<../../../game/card.lua#L2291-L2301>).

## 4. 幻灵牌: 18 张

| ID / 中文名 / English | 合法目标与条件 | 实际效果与范围 |
|---|---|---|
| `c_familiar` 使魔 / Familiar | 手牌状态, 当前手牌数 `>1`, 不需高亮 | 随机删除当前手牌 1 张; 向当前手牌和牌组添加 3 张随机增强的 J/Q/K |
| `c_grim` 严峻 / Grim | 同上 | 随机删除当前手牌 1 张; 添加 2 张随机增强的 A |
| `c_incantation` 咒语 / Incantation | 同上 | 随机删除当前手牌 1 张; 添加 4 张随机增强的 2..10 |
| `c_talisman` 护身符 / Talisman | 手牌状态, 恰好选 1 | 设置金色蜡封 Gold, 覆盖旧蜡封 |
| `c_aura` 光环 / Aura | 稳定状态, 恰好选 1 张无版本手牌 | 设置闪箔/镭射/多彩, 分布见 2.3 |
| `c_wraith` 幽灵 / Wraith | 稳定状态; 小丑空位条件 | 创建一张稀有小丑, 然后将当前资金精确设为 0, 也可清除负债 |
| `c_sigil` 符印 / Sigil | 手牌状态, 手牌数 `>1`, 高亮不影响范围 | 全部当前手牌变为同一种随机花色, 四种花色等机会; 保留各自点数 |
| `c_ouija` 占卜 / Ouija | 手牌状态, 手牌数 `>1`, 高亮不影响范围 | 全部当前手牌变为同一个随机点数, 2..A 共 13 种; 保留各自花色; 永久手牌上限 `-1` |
| `c_ectoplasm` 灵质 / Ectoplasm | 稳定状态; 至少一张无版本小丑 | 随机符合条件小丑变负片; 永久手牌上限损失递增, 见 4.2 |
| `c_immolate` 火祭 / Immolate | 手牌状态, 手牌数 `>1`, 高亮不影响范围 | 随机不放回删除最多 5 张当前手牌, 加 `$20`. 源码可用检查不是至少 5 张 |
| `c_ankh` 生命十字章 / Ankh | 稳定状态; 有小丑; 总小丑槽位上限 `>1`; 实际使用还必须有空位 | 随机保留一个源小丑, 删除其他非永恒小丑, 创建源小丑复制品; 复制品去负片 |
| `c_deja_vu` 既视感 / Deja Vu | 手牌状态, 恰好选 1 | 设置红色蜡封 Red, 覆盖旧蜡封 |
| `c_hex` 妖法 / Hex | 稳定状态; 至少一张无版本小丑 | 随机符合条件小丑变多彩, 删除其他非永恒小丑, 无需额外空位 |
| `c_trance` 入迷 / Trance | 手牌状态, 恰好选 1 | 设置蓝色蜡封 Blue, 覆盖旧蜡封 |
| `c_medium` 灵媒 / Medium | 手牌状态, 恰好选 1 | 设置紫色蜡封 Purple, 覆盖旧蜡封 |
| `c_cryptid` 神秘生物 / Cryptid | 手牌状态, 恰好选 1 | 复制所选游戏牌 2 张, 源牌仍在; 副本直接加入当前手牌和牌组 |
| `c_soul` 灵魂 / The Soul | 稳定状态; 小丑空位条件 | `legendary=true` 生成一张传奇小丑, 不是普通稀有度随机 |
| `c_black_hole` 黑洞 / Black Hole | 稳定状态; 无目标和空间要求 | 全部 12 种牌型各升 1 级, 包括隐藏牌型 |

原型: [game.lua:570-588](<../../../game/game.lua#L570-L588>). 合法性: [card.lua:1523-1579](<../../../game/card.lua#L1523-L1579>). 效果: [card.lua:1153-1520](<../../../game/card.lua#L1153-L1520>).

### 4.1 新增, 移除与复制的精确行为

- 使魔/严峻/咒语: 随机删除不是选中删除. 新增牌的花色逐张随机, 点数依各自集合随机, 增强从全部增强中排除 `m_stone` 后随机选取. 不创建无增强牌, 不保证花色或增强相同. 这些新牌并非只放牌堆, 而是直接入当前手牌.
- 符印/占卜: 使用一个共同随机花色/点数转换整手牌, 不为每张独立抽取. 石头牌的底层点数/花色也会被修改, 石头增强仍保留. 旧增强, 版本, 蜡封不被此类 `set_base` 调用清除.
- 火祭: 复制当前手牌列表, 按 `playing_card` 排序后伪随机洗牌, 取前 5 个非空条目. 因为可用检查只要求至少 2 张, 手中 2..4 张时会全毁但仍加 `$20`; agent 不应误判无法使用. 该事实来自代码而非建议利用运行时漏洞.
- 神秘生物: 副本继承源牌全部 ability, 版本, 蜡封, 永久筹码和削弱状态, 各有新游戏牌标识; 手牌可暂时超过上限. 新牌通知发生在两张副本都创建后.
- 倒吊人/使魔/严峻/咒语/火祭: 无论排队执行 shatter 还是 dissolve, 都向小丑发送被移除的牌列表, 可供卡尼奥等根据通知中的牌成长. 但玻璃小丑 `j_glass` 要求通知当时已设 `shattered`, 而幻灵的异步 shatter 可能尚未执行; 倒吊人另有 `using_consumeable` 检查高亮玻璃牌的分支. 不得假定任意幻灵移除玻璃必定增长或把两分支重复相加, 精确限制见 [小丑机制:373-374](<joker-mechanics.md#L373-L374>). 随后读新的 `G.playing_cards` 而不是把删除仅当作本回合弃牌.

来源: [card.lua:1201-1257](<../../../game/card.lua#L1201-L1257>), [card.lua:1269-1371](<../../../game/card.lua#L1269-L1371>), [common_events.lua:2156-2180](<../../../game/functions/common_events.lua#L2156-L2180>).

### 4.2 灵质, 生命十字章与妖法

灵质 `c_ectoplasm` 第 `k` 次使用损失 `k` 个永久手牌上限, 因为 `ecto_minus` 首次为 1, 每次损失后加 1. 使用 `n` 次总损失 `n*(n+1)/2`. 候选仅无版本小丑, 不覆盖闪箔/镭射/多彩/负片. 负片带来的小丑槽位会随对应小丑被移除而失去, 但已经扣掉的手牌上限不返还.

生命十字章的随机源从全部小丑中选取, 不排除永恒. 删除候选是非永恒小丑且不是源牌. 复制完整 ability 表, 所以成长值, 永恒, 易腐剩余回合, 租赁和 pinned 都可继承; 仅负片不继承, 其他版本可继承. 被选源牌的负片仍保留. 小丑已满时 `check_use()` 会在执行复制/删除之前直接报 No Space, 不允许先假设删除会腾空位. 注释中讨论的特殊选择方案并未成为实际算法.

妖法的随机目标也只来自无版本小丑, 包含永恒. 给目标多彩后删其他非永恒小丑, 所以已有永恒小丑不会被它删除. 其他小丑的负片不会保护它们, 只有永恒保护. 目标本身不复制也不删除.

来源: [card.lua:1426-1452](<../../../game/card.lua#L1426-L1452>), [card.lua:1488-1498](<../../../game/card.lua#L1488-L1498>), [card.lua:1581-1588](<../../../game/card.lua#L1581-L1588>), [card.lua:4217-4222](<../../../game/card.lua#L4217-L4222>).

## 5. 补充包与后续操作

- 秘术/天体/幻灵包的消耗牌选择是立即使用, 不是先搬进消耗牌栏再等待回合. 所以包内皇帝/女祭司/愚者仍要求栏里有空间, 不能借用包内牌不存在于栏中的事实忽略容量.
- 在包界面使用自己原先消耗牌栏里的牌, 不消耗包的选择次数; 使用包内候选则扣一次选择, 最后一选后关包. 未选择的牌不会变成自己的库存.
- 一次使用后等动画锁解除, 状态回到原稳定状态, 重新读实际资金, 牌组, 手牌上限, 小丑槽位及剩余包选择. 不能立即基于操作前的空位和高亮重复动作.
- 修改类塔罗和蜡封类幻灵在效果完成后取消高亮, 不保证其他效果都统一清除高亮.

来源: [button_callbacks.lua:2140-2205](<../../../game/functions/button_callbacks.lua#L2140-L2205>), [button_callbacks.lua:2240-2269](<../../../game/functions/button_callbacks.lua#L2240-L2269>), `G.FUNCS.use_card`.

## 6. Wiki 核对与权威边界

核对页: [Balatro Wiki - Ankh](https://balatrowiki.org/w/Ankh). Wiki 的保留成长/贴纸, 永恒不被销毁, 复制品移除负片, 满小丑栏报 No Space 与本地实现一致. 页面还描述商店购买并使用时可能卡住及牌背视觉 bug; 本文没有运行游戏复现这些视觉/操作 bug, 不将它们作为 agent 的合法策略前提.

所有机制数字与状态条件以本地 1.0.1n 源码为准. 特别是火祭的 `>1` 合法性, 生命十字章的二层校验, 愚者的延迟记录, 不应被泛化 wiki 文案覆盖.
