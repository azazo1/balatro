# 盲注目标与 Boss 机制

适用版本: Balatro 1.0.1n. 本文给出盲注目标公式, 30 种盲注的机制和 Boss 抽取约束. 完整卡面目录另见 [盲注目录](<../cards/blinds.md>); 下述机制以执行代码而非卡面简写为准.

## 1. 目标分数

实际开始盲注时:

```text
目标 = base(ante, scaling) * blind.mult * starting_params.ante_scaling
```

- `ante` 为 `G.GAME.round_resets.ante`.
- `scaling` 为 `G.GAME.modifiers.scaling`: 白/红为 1 或未设置, 绿/黑/蓝为 2, 紫/橙/金为 3.
- 牌组目标系数 `starting_params.ante_scaling` 正常为 1, 等离子牌组为 2.
- 小盲注系数 1, 大盲注 1.5, 通常 Boss 2, 围墙 4, 针 1, 靛紫之杯 6.
- 比较条件是累积得分 `>=` 目标, 而不是严格大于. 乘盲注系数后代码不再统一取整.

来源: [Blind:set_blind](<../../../game/blind.lua#L78-L108>), [盲注原型](<../../../game/game.lua#L263-L294>), [get_blind_amount](<../../../game/functions/misc_functions.lua#L919-L954>).

### Ante 1-8 基础分表

| Ante | 白注/红注 | 绿注/黑注/蓝注 | 紫注/橙注/金注 |
| --- | ---: | ---: | ---: |
| 1 | 300 | 300 | 300 |
| 2 | 800 | 900 | 1000 |
| 3 | 2000 | 2600 | 3200 |
| 4 | 5000 | 8000 | 9000 |
| 5 | 11000 | 20000 | 25000 |
| 6 | 20000 | 36000 | 60000 |
| 7 | 35000 | 60000 | 110000 |
| 8 | 50000 | 100000 | 200000 |

这是 `base`, 不是所有 Boss 的最终目标. 例如金注 Ante 8 通常决战 Boss 是 `200000*2 = 400000`, 靛紫之杯是 `200000*6 = 1200000`; 等离子牌组再全部乘 2. Ante 小于 1 时三种 scaling 都返回基础值 100.

### Ante 9 以后的公式

令 `a = 本 scaling 的 Ante 8 基础分`, `c = ante - 8`, `d = 1 + 0.2*c`:

```text
raw = floor(a * (1.6 + (0.75*c)^d)^c)
unit = 10^floor(log10(raw) - 1)
base = raw - raw % unit
```

最后一步向下保留两位有效数字, 不是通常四舍五入. 再乘盲注系数和牌组系数. 数值随底注快速增长, 极高底注受 Lua 数字浮点范围限制; 不应预先声称所有底注都能用有限整数表示.

来源: [get_blind_amount](<../../../game/functions/misc_functions.lua#L919-L954>).

## 2. Boss 出现规则

1. 普通 Boss 候选要求 `boss.min <= max(1, ante)`.
2. 当 `max(1, ante) % win_ante != 0` 或 `ante <2`, 只选择普通 Boss.
3. 当 `ante % win_ante ==0` 且 `ante >=2`, 只选择 `boss.showdown` 的决战 Boss. 默认 `win_ante =8`.
4. 移除 `banned_keys` 中的 Boss.
5. 在当前合格候选里, 只保留本局 `bosses_used` 次数最少的一组, 再按伪随机选一个.
6. Boss 一旦被抽中就增加使用次数, 无需实际击败; 重掷消耗掉的旧 Boss 也已经计为使用过.
7. 预定 `perscribed_bosses[ante]` 或强制 Boss 可绕过正常候选逻辑, 不属于普通运行默认行为.

注意: 原型中的 `boss.max =10` 并没有被抽取函数检查. 决战 Boss 原型的 `min =10` 也不是实际出现最低底注; 决战分支只检查周期, 正常 Ante 8 就能出现. 不能仅解析原型表推断这些条件.

来源: [get_new_boss](<../../../game/functions/common_events.lua#L2338-L2383>).

### 重掷

`v_directors_cut` 允许每底注一次, `v_retcon` 允许不限次数. 每次 $10, 要满足支付能力 `dollars - bankrupt_at >=10`; Boss 标签提供的重掷不扣这 $10. 重掷仍用同一个候选规则, 所以 Ante 8 重掷不可能换成普通 Boss. 新底注 `reset_blinds` 清除 `boss_rerolled`.

来源: [reroll_boss_button / reroll_boss](<../../../game/functions/button_callbacks.lua#L2769-L2806>), [reset_blinds](<../../../game/functions/common_events.lua#L2326-L2336>).

## 3. 普通盲注与 Boss 总表

普通 Boss 固定奖励 $5; 决战 Boss $8; 奖励需实际分数达标. 最低底注是普通 Boss 的候选下限, 不表示一定会出现.

| id | 中文名 / 英文名 | 最低 Ante | 目标系数 | 精确效果 |
| --- | --- | ---: | ---: | --- |
| `bl_small` | 小盲注 / Small Blind | 任意 | 1 | 无特殊效果, 奖励 $3; 红注及以上固定奖金为 $0; 可跳过 |
| `bl_big` | 大盲注 / Big Blind | 任意 | 1.5 | 无特殊效果, 奖励 $4; 可跳过 |
| `bl_hook` | 钩子 / The Hook | 1 | 2 | 每次出牌转移到出牌区后, 从剩余手牌随机强制弃最多 2 张, 不花主动弃牌次数 |
| `bl_ox` | 公牛 / The Ox | 6 | 2 | 打出指定的全局最常用牌型时, 金钱立即归 $0; 不导致该手牌型本身不计分 |
| `bl_house` | 房屋 / The House | 2 | 2 | 当本回合尚未出牌且未主动弃牌时, 抽到手中的牌背面朝上 |
| `bl_wall` | 围墙 / The Wall | 2 | 4 | 目标是基础分的 4 倍, 无额外牌型限制 |
| `bl_wheel` | 车轮 / The Wheel | 2 | 2 | 每张抽入手牌的牌以 `probabilities.normal/7` 概率背面朝上 |
| `bl_arm` | 手臂 / The Arm | 2 | 2 | 打出的最终牌型等级若 >1, 永久下降 1 级, 该次计分使用降低后的基础数值; 不低于 1 级 |
| `bl_club` | 梅花 / The Club | 1 | 2 | 所有算作梅花的扑克牌被削弱 |
| `bl_fish` | 鱼 / The Fish | 2 | 2 | 出牌后的补牌背面朝上; 初始抽牌和普通主动弃牌后的补牌不因鱼而翻背面 |
| `bl_psychic` | 灵媒 / The Psychic | 1 | 2 | 必须打出 5 张; 少于 5 张使整次出牌被判无效, 不是要求 5 张都实际计分 |
| `bl_goad` | 挑衅 / The Goad | 1 | 2 | 所有算作黑桃的扑克牌被削弱 |
| `bl_water` | 水 / The Water | 2 | 2 | 设置盲注时移除当前所有弃牌次数 |
| `bl_window` | 窗口 / The Window | 1 | 2 | 所有算作方片的扑克牌被削弱 |
| `bl_manacle` | 镣铐 / The Manacle | 1 | 2 | 本盲注期间手牌上限 -1, 成功离开或禁用时恢复 |
| `bl_eye` | 眼睛 / The Eye | 3 | 2 | 当前回合已经打出过的最终牌型不可再打; 重复牌型使整次出牌无效 |
| `bl_mouth` | 嘴巴 / The Mouth | 2 | 2 | 第一次实际打出的最终牌型固定为本回合唯一许可牌型, 其他牌型使整次出牌无效 |
| `bl_plant` | 植物 / The Plant | 4 | 2 | 所有人头牌被削弱, 包括幻视赋予的人头属性; A 不是默认人头牌 |
| `bl_serpent` | 巨蟒 / The Serpent | 5 | 2 | 初始抽牌正常; 出牌或主动弃牌后补牌固定最多 3 张, 可以超出手牌上限 |
| `bl_pillar` | 支柱 / The Pillar | 1 | 2 | 当前底注中已打出过的扑克牌被削弱, 包括之前出牌里不计分的牌; 单纯弃过的不算 |
| `bl_needle` | 针 / The Needle | 2 | 1 | 开始盲注时扣除 `round_resets.hands - 1` 次出牌; 没有其他临时加成时剩 1 次 |
| `bl_head` | 头部 / The Head | 1 | 2 | 所有算作红桃的扑克牌被削弱 |
| `bl_tooth` | 牙齿 / The Tooth | 3 | 2 | 每张打出的牌扣 $1, 包括非计分牌; 可以扣到负数 |
| `bl_flint` | 燧石 / The Flint | 2 | 2 | 牌型的基础倍率与筹码分别减半后四舍五入, 倍率至少 1, 筹码至少 0 |
| `bl_mark` | 标记 / The Mark | 2 | 2 | 所有人头牌抽入手牌时背面朝上, 包括幻视效果认定的人头牌 |

原型与最低 Ante: [Game:init_item_prototypes](<../../../game/game.lua#L263-L294>). 中文名称: [中文盲注本地化](<../../../game/localization/zh_CN.lua#L129-L330>). 各效果执行位置如下.

## 4. 关键边界与执行时机

### 卡牌削弱不是牌型禁止

梅花/挑衅/窗口/头部调用 `card:is_suit(suit, true)`, 忽略卡牌之前的削弱状态. 万能牌对四个花色都返回真, 因而被任何花色 Boss 削弱. 石头牌没有花色, 不受这些花色限制. 涂抹小丑会使相同颜色的花色同时被匹配, 所以花色 Boss 的实际影响可扩展到另一同色花色.

植物和标记调用 `card:is_face(true)`, 同样绕过已有削弱, 并参考幻视小丑. 石头牌不会以原来的 J/Q/K 身份成为默认人头牌, 但幻视仍可使它算人头牌.

被削弱的扑克牌仍留在手牌/出牌中, 仍可参与牌型判定; 其卡牌筹码/增强/蜡封等计分效果被抑制. 整手无效的灵媒/眼睛/嘴巴则是另一层限制. 详细计分接口见 [计分流程](<scoring.md>).

来源: [Blind:debuff_card](<../../../game/blind.lua#L624-L652>), [Card:is_suit](<../../../game/card.lua#L4064-L4089>), [Card:is_face](<../../../game/card.lua#L957-L969>).

### 钩子, 牙齿与主动弃牌区别

`press_play` 在所选牌移到出牌区后执行. 钩子从仍留在手中的牌里抽样, 不会把刚打出的牌拿走. 钩子强制弃牌仍经过蜡封/小丑的弃牌触发管线, 但带 `hook =true`; 不消耗主动弃牌次数, 不增加 `discards_used`, 不额外立即补牌, 不收挑战的主动弃牌费用. 牙齿按 `#G.play.cards` 扣钱, 不看其中多少张计分.

来源: [Blind:press_play](<../../../game/blind.lua#L464-L508>), [强制/主动弃牌分支](<../../../game/functions/state_events.lua#L379-L448>), [出牌顺序](<../../../game/functions/state_events.lua#L450-L488>).

### 针和水是开始时修改, 不是持续硬限制

水记录 `discards_sub = current_round.discards_left`, 再减去这部分, 所以初始为 0. 随后通过小丑或其他效果增加的次数仍可用. 针记录 `hands_sub = round_resets.hands -1`, 从已带 `round_bonus.next_hands` 的剩余次数中减去. 因此额外临时出牌次数, 或之后 `setting_blind` 的增加效果, 能使针有多于 1 次出牌. 禁用时分别把记录的数量加回来.

来源: [Blind:set_blind](<../../../game/blind.lua#L179-L188>), [new_round 设置顺序](<../../../game/functions/state_events.lua#L296-L337>), [Blind:disable](<../../../game/blind.lua#L356-L389>).

### 手牌上限与抽牌隐藏信息

- 房屋检查 `hands_played ==0 && discards_used ==0`, 通常只隐藏最初抽到的一手. 第一次主动弃牌后新补牌是正面, 不会揭示仍留手中的旧背面牌.
- 鱼通过出牌时设置 `prepped` 控制下一次补牌隐藏, 抽牌完成后清掉; 普通主动弃牌不会设置它.
- 车轮的分子是概率系统变量, 不永远固定为 1, 六六大顺 等效果可影响它.
- 巨蟒把补牌数量覆盖成 `min(剩余牌堆数, 3)`, 而非 `min(空余手牌槽, 3)`. 只打/弃 1 张时可能净增 2 张, 手牌可能超过名义上限.
- 镣铐禁用时恢复 1 个上限并主动尝试抽 1 张; 成功结束该盲注时只恢复上限, 下一盲注会正常重抽.
- 背面牌不是削弱牌. agent 没有正面观测时应保留不确定性, 不应把本地源码可访问性当作在局观测.

来源: [Blind:stay_flipped / drawn_to_hand](<../../../game/blind.lua#L572-L622>), [抽牌函数](<../../../game/functions/state_events.lua#L355-L377>), [成功恢复镣铐](<../../../game/blind.lua#L338-L343>), [禁用恢复](<../../../game/blind.lua#L364-L389>).

### 牌型与历史

- 眼睛和嘴巴按最高最终牌型名称比较, 不按所包含的低级子牌型. 例如葫芦不等同于对子或三条.
- 预览调用的 `check =true` 不会登记牌型历史, 不会真的降级或清钱. 只有实际出牌改变历史/等级/金钱.
- 手臂永久降级, 不在禁用或结束后恢复.
- 公牛引用 `current_round.most_played_poker_hand`, 在上次 Boss 成功后的全局累计牌型次数里选出; 本 Boss 期间不会随每手变化. 并列规则实现使用 `pairs` 且 `_order` 没有随候选更新, 不要为 1.0.1n 硬编造确定的并列排序; 以界面展示/当前字段为准.
- 公牛将负债也归零, 是设置当前金钱为 0, 不仅仅移除正数余额.
- 支柱标记 `played_this_ante` 在每张选中牌被打出时写入, 不只计分牌. Boss 成功后清除, 主动弃牌不会写入.
- 燧石公式为 `max(floor(mult*0.5+0.5),1)` 和 `max(floor(chips*0.5+0.5),0)`, 仅针对该手牌型基础数值, 不把之后所有小丑和卡牌加成一起除 2.

来源: [Blind:debuff_hand / modify_hand](<../../../game/blind.lua#L510-L570>), [最常用牌型更新](<../../../game/functions/state_events.lua#L129-L138>), [打出标记](<../../../game/functions/state_events.lua#L478-L483>), [清除标记](<../../../game/functions/state_events.lua#L263-L267>).

## 5. 决战 Boss

全部只在正常 Ante 8 的倍数中随机出现, 奖励 $8. 除靛紫之杯外目标系数均为 2.

| id | 中文名 / 英文名 | 精确机制 |
| --- | --- | --- |
| `bl_final_acorn` | 琥珀之实 / Amber Acorn | 设置盲注时翻转当前所有小丑, 多于 1 张时连续洗乱 3 次. 小丑能力仍正常, 只是身份和顺序隐藏; 新增小丑不会自动参加这次开始时洗乱 |
| `bl_final_leaf` | 翠绿之叶 / Verdant Leaf | 所有扑克牌削弱, 直到在其生效期间卖出 1 张小丑后调用 `blind:disable()`. 卖消耗牌无效, 在选择盲注前先卖小丑不算 |
| `bl_final_vessel` | 靛紫之杯 / Violet Vessel | 目标系数 6, 无额外牌型限制 |
| `bl_final_heart` | 绯红之心 / Crimson Heart | 初始抽牌结束及每次出牌后的补牌结束, 随机削弱当前 1 张小丑. 候选是处理前未削弱的小丑, 或总数只有 1 时那张; 多张时排除上次已削弱者和已到期易腐者. 先尝试解除旧削弱再设置新削弱, 候选为空则不新增削弱. 主动弃牌后的补牌不重新随机 |
| `bl_final_bell` | 蔚蓝之铃 / Cerulean Bell | 抽牌结束若没有仍在手中的强制牌, 随机选 1 张并标记 `forced_selection`, 清除其他选择并选中它. 可以出掉或弃掉, 但不能仅取消选择; 下次补牌会重新指定 |

来源: [设置琥珀之实](<../../../game/blind.lua#L190-L204>), [drawn_to_hand](<../../../game/blind.lua#L572-L603>), [press_play 设置绯红之心](<../../../game/blind.lua#L488-L496>), [翠绿之叶削弱](<../../../game/blind.lua#L650-L652>), [卖小丑解除翠绿之叶](<../../../game/card.lua#L1613-L1621>), [强制牌不可取消选择](<../../../game/cardarea.lua#L187-L212>).

## 6. 禁用与恢复

禁用 Boss 不是把所有已经造成的后果回滚:

- 立即解除正常 Boss 卡牌削弱, 翻正仍在手中的隐藏牌, 清除强制选中标记; 易腐已到期的小丑的削弱不被恢复.
- 水/针恢复之前扣去的次数; 镣铐恢复上限并抽 1 张.
- 围墙目标除 2, 靛紫之杯目标除 3, 都回到通常 Boss 的 `base*2*牌组系数`.
- 针目标保持 `base*1*牌组系数`, 禁用不提高目标.
- 手臂已经降掉的等级, 公牛已经清零的金钱, 牙齿已经扣的钱, 钩子已经弃掉的牌不会回滚.
- 琥珀之实会翻正小丑, 但不会还原它们被洗乱之前的顺序.
- 禁用后若当前累计分已经满足新目标, 直接进入回合终结, 不要求再打一手.

来源: [Blind:disable](<../../../game/blind.lua#L356-L415>), [易腐优先的 Card:set_debuff](<../../../game/card.lua#L526-L536>).

## 7. Wiki 核对和版本边界

[Balatro Wiki: Blinds and Antes](<https://balatrowiki.org/w/Blinds>) 的 30 种盲注, Ante 1-8 三档分数, 决战周期和普通 Boss 奖金与本地代码一致. 需要比 wiki 摘要更精确的点包括:

- "所有 Boss 出现过才重复" 应理解为当前合格候选里取使用次数最少者, 新达到最低底注门槛的 Boss 会影响候选集.
- "针只能打一手" 是一般描述, 本版本执行的是开始时减次数, 允许上述额外次数交互.
- 原型 `min/max` 不能直接作为决战实际出现条件.
- 数字, 并列历史和禁用回滚范围以本文列出的本地执行代码为准.
