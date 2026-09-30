# 扑克牌型

适用版本: Balatro 1.0.1n. 本地代码有 `12` 个独立牌型键, 皇家同花顺仅是同花顺的显示变体, 不是第 `13` 个独立牌型. 判定优先级固定, 不会选择升级后分数最高的较低牌型.

## 全部基础值与升级

按最高到最低优先级排列. 基础值均为等级 `1`, 尚未加入计分牌点数筹码和卡牌效果. 星球通常令对应牌型升 `1` 级.

| 优先级 | 牌型 / 内部键 | 基础筹码 | 基础倍率 | 每升 1 级筹码 | 每升 1 级倍率 | 星球 | 通常计分牌 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 同花五条 / `Flush Five` | 160 | 16 | +50 | +3 | Eris | 5 张同点数且同花 |
| 2 | 同花葫芦 / `Flush House` | 140 | 14 | +40 | +4 | Ceres | 同花的三条与另一点数对子, 共 5 张 |
| 3 | 五条 / `Five of a Kind` | 120 | 12 | +35 | +3 | Planet X | 5 张同点数 |
| 4 | 同花顺 / `Straight Flush` | 100 | 8 | +40 | +4 | Neptune | 同花且组成顺子的 5 张 |
| 5 | 四条 / `Four of a Kind` | 60 | 7 | +30 | +3 | Mars | 4 张同点数 |
| 6 | 葫芦 / `Full House` | 40 | 4 | +25 | +2 | Earth | 3 张同点数加另一点数的 2 张 |
| 7 | 同花 / `Flush` | 35 | 4 | +15 | +2 | Jupiter | 5 张同花 |
| 8 | 顺子 / `Straight` | 30 | 4 | +30 | +3 | Saturn | 5 个连续点数 |
| 9 | 三条 / `Three of a Kind` | 30 | 3 | +20 | +2 | Venus | 3 张同点数 |
| 10 | 两对 / `Two Pair` | 20 | 2 | +20 | +1 | Uranus | 两个不同点数的对子, 共 4 张 |
| 11 | 对子 / `Pair` | 10 | 2 | +15 | +1 | Mercury | 2 张同点数 |
| 12 | 高牌 / `High Card` | 5 | 1 | +10 | +1 | Pluto | 最高的 1 张牌 |

基础表见 [game.lua](<../../../game/game.lua#L1983-L1996>) 的 `Game:init_game_object` 中 `hands`, 星球映射见 [game.lua](<../../../game/game.lua#L556-L568>) 的星球中心定义.

当前等级为 `L` 时:

- `chips = max(基础筹码 + 每级筹码 * (L - 1), 0)`.
- `mult = max(基础倍率 + 每级倍率 * (L - 1), 1)`.
- `level_up_hand` 把等级限制在至少 `0`, 不设升级上限. 但普通游戏中的 `The Arm` 只有等级大于 `1` 才降级, 所以它不会把等级 `1` 降成 `0`.
- 本次出牌的 `before` 升级和 Arm 降级都会影响本次基础值. 星球升级是持久改变牌型, 与一次出牌里的加倍率/乘倍率不同.

见 [common_events.lua](<../../../game/functions/common_events.lua#L464-L493>) 的 `level_up_hand`, [blind.lua](<../../../game/blind.lua#L550-L559>) 的 `Blind:debuff_hand`.

## 判定与计分名单

`evaluate_poker_hand` 返回所有满足的牌型结果, `G.FUNCS.get_poker_hand_info` 按上表优先级取首个非空结果的第一组为初始计分名单. 所以等级很高的同花也不能覆盖四条. 普通出牌可以打 `1` 到 `5` 张, 不要求凑满 `5` 张才可形成对子/三条等.

- 不属于所选牌型的垫牌通常不计分, 如四条旁的第五张, 对子旁的三张. 仍算实际打出的牌, 可影响出牌张数条件或 Tooth 扣款.
- 计分牌的激活顺序按横坐标从左到右, 与用于识别顺子的点数顺序无关. 顺子不需要按大小排列后打出.
- 石头牌额外加入名单. 有生效的 Splash 时全部打出的牌都加入. 这两者不把原本牌型改成另一种牌型.
- 削弱牌一般仍参与牌型判定, 但其自身计分, 版本, 蜡封和对应的逐卡计分效果停用. 万能牌花色是下述例外.

见 [misc_functions.lua](<../../../game/functions/misc_functions.lua#L376-L519>) 的 `evaluate_poker_hand`, [state_events.lua](<../../../game/functions/state_events.lua#L540-L600>) 的 `G.FUNCS.get_poker_hand_info`/`G.FUNCS.evaluate_play`. 完整阶段见 [计分与结算](<scoring.md>).

### 同点数组与包含关系

`get_X_same(n, hand)` 找的是恰好有 `n` 张的同点数组, 花色不影响. 从大点数到小点数返回组. 葫芦必须存在一组三条和另一组对子, 四条不能当作两对, 五条不能当作葫芦.

代码末尾补齐五条包含四条, 四条包含三条, 三条包含对子, 让检查 `poker_hands['Pair']` 等的 Joker 也能响应较高同点数牌型. 葫芦另外会使 `Two Pair` 结果非空. 因此要区分:

- `scoring_name == 'Pair'`: 实际所选牌型是对子.
- `next(poker_hands['Pair'])`: 全部打出的牌中满足对子包含条件, 也可来自三条/四条/五条.
- 检查 `Two Pair` 的条件可被葫芦满足, 不被四条/五条满足.

同花葫芦也满足普通葫芦, 同花五条也满足五条. 同花顺同时有顺子和同花结果. 这些包含结果供条件判断, 不表示额外叠加所有低阶基础分.

见 [misc_functions.lua](<../../../game/functions/misc_functions.lua#L592-L611>) 的 `get_X_same` 和 [misc_functions.lua](<../../../game/functions/misc_functions.lua#L479-L519>) 的 `evaluate_poker_hand`.

### 顺子与 A

`get_straight` 使用不同点数长度. `A` 可在低端组成 `A,2,3,4,5`, 或高端组成 `10,J,Q,K,A`, 但不首尾环绕, `Q,K,A,2,3` 不成立. 重复点数不增加长度.

检测范围是 `4/5` 张到 `5` 张, 依是否有 Four Fingers 而定. 代码把同一个被采用点数的所有牌都加入顺子结果. 因此四指时 `A,A,K,Q,J` 有 `4` 个不同点数并可形成顺子, 两张 `A` 都计分. 通常无四指时重复点数会使 `5` 张无法提供 `5` 个不同点数.

见 [misc_functions.lua](<../../../game/functions/misc_functions.lua#L548-L590>) 的 `get_straight`.

## 特殊 Joker 与石头牌

### 四指 / Four Fingers

有至少一张未削弱 Four Fingers 时, 同花与顺子的最低长度从 `5` 降至 `4`. 多张四指不进一步降至 `3`. 葫芦/五条的同点数张数要求不会降低.

关键是复合牌型分别判定:

- 同花顺要求这手同时存在同花和顺子, 不要求构成它们的是同一组 `4` 张. 计分名单为找到的同花组与顺子组的并集.
- 例如黑桃 `3,6,8,9` 加红桃 `7`, 黑桃 `3,6,8,9` 构成同花, `6,7,8,9` 构成顺子, 可判同花顺, `5` 张均计分.
- 同花葫芦要求三条 + 对子同时有至少 `4` 张同花, 不需要 `5` 张全同花. 例如黑桃 `8,8,6,6` 加红桃 `8`, 仍为同花葫芦, `5` 张计分.
- 同花五条要求 `5` 张同点数加至少 `4` 张同花. `4` 张同点数即使同花也不成为同花五条.
- 同花计分组包括该被匹配花色的所有打出牌, 不是只截取 `4` 张. 花色搜索顺序为 `Spades`, `Hearts`, `Clubs`, `Diamonds`, 返回首个满足组.

见 [misc_functions.lua](<../../../game/functions/misc_functions.lua#L404-L443>) 的 `evaluate_poker_hand`, [misc_functions.lua](<../../../game/functions/misc_functions.lua#L522-L590>) 的 `get_flush`/`get_straight`.

### 捷径 / Shortcut

允许顺子相邻采用点数之间缺 `1` 个点数, 可有多个这样的单点间隔, 不允许连续缺 `2` 个点数. 例如 `2,4,6,8,10` 可以, `2,5,6,7,8` 不可以. 与四指叠加时只需 `4` 个采用点数, 仍不改变 `A` 不可环绕的限制. 多张捷径不把允许间隔扩大.

见 [misc_functions.lua](<../../../game/functions/misc_functions.lua#L567-L585>) 的 `get_straight`.

### 模糊小丑 / Smeared Joker 与万能牌 / Wild Card

生效的模糊小丑令红桃与方片按同类花色处理, 黑桃与梅花按同类花色处理. 它改变花色匹配, 不改变点数. 与四指可叠加.

未削弱万能牌可匹配所有 `4` 种花色, 也可解释为百搭花色, 但不充当任意点数. 削弱后计算同花时不再具备万能花色, 按底牌花色处理, 仍可受生效模糊小丑的颜色合并影响. 花色 Boss 检查万能牌时可以命中任意花色, 不只命中底牌原花色.

见 [card.lua](<../../../game/card.lua#L4064-L4089>) 的 `Card:is_suit`, [blind.lua](<../../../game/blind.lua#L624-L651>) 的 `Blind:debuff_card`. 正式中文名见 [zh_CN.lua](<../../../game/localization/zh_CN.lua#L422-L426>) 的 `Enhanced.m_wild` 与 [zh_CN.lua](<../../../game/localization/zh_CN.lua#L1546-L1553>) 的 `Joker.j_smeared`.

### 石头牌

石头牌无可用于牌型的点数和花色, 不参与同点数组, 顺子或同花, 即使被削弱也保留这一身份. 底牌原点数/花色仍在卡对象中, 去除石头增强后可恢复, 不应因此把它当作当前正常点数牌.

打出的石头牌在牌型识别后总加入计分名单, 默认提供 `50` 筹码加永久筹码, 不另加底牌点数. 例如一个对子加石头牌仍是对子, 多计石头筹码. 全部打出牌都是石头牌时仍会得到高牌结果, 随后把所有打出的石头牌加入计分, 不是没有牌型或自动零分. 削弱石头牌仍加入名单但不提供筹码.

见 [card.lua](<../../../game/card.lua#L950-L981>) 的 `Card:get_nominal`/`get_id`/`get_chip_bonus`, [card.lua](<../../../game/card.lua#L4064-L4089>) 的 `Card:is_suit`, [state_events.lua](<../../../game/functions/state_events.lua#L580-L600>) 的 `G.FUNCS.evaluate_play`.

## 隐藏牌型与皇家同花顺

- 同花五条, 同花葫芦, 五条初始 `visible = false`. 本局第一次实际打出后变为可见, 对应星球随后加入普通星球随机池. 仅选中预览或弃掉该牌型不算已打出.
- 对应星球的普通入池条件是该独立牌型 `played > 0`, 不是只检查卡牌是否已全局发现. 打出同花五条并不直接增加五条的 `played`, 所以也不自动让 Planet X 入普通池.
- Black Hole 等全牌型升级可在隐藏牌型尚不可见时增加它们的等级. 等级改变不等于打出, 不单独解除星球池的 `softlock`.
- 皇家同花顺仍用 `Straight Flush` 基础值, 等级, Neptune, 出牌统计, Eye/Mouth 记录. `get_poker_hand_info` 只在同花顺计分名单的最低点数至少为 `10` 时改显示名为 `Royal Flush`. 四指/捷径存在时不应额外强制为精确的 `10,J,Q,K,A` 五张组合.

见 [game.lua](<../../../game/game.lua#L1983-L1987>) 的 `Game:init_game_object`, [state_events.lua](<../../../game/functions/state_events.lua#L557-L578>) 的 `G.FUNCS.get_poker_hand_info`/`G.FUNCS.evaluate_play`, [common_events.lua](<../../../game/functions/common_events.lua#L2008-L2011>) 的 `get_current_pool`.

## 交叉验证与版本边界

[Wiki: Poker hands](https://balatrowiki.org/w/Poker_hands) 交叉验证全部基础值/升级值, 皇家同花顺共用同花顺等级, 以及四指的同花顺/同花葫芦/同花五条复合判定. 表中的通常要求不覆盖所有四指/捷径/模糊小丑例外, 实际判定以上述本地函数为准.
