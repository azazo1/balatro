# 商店与补充包

以本仓库 Balatro 1.0.1n 源码为准. 本文说明商店库存, 购买与重掷, 补充包生成和选择规则. 单卡定义见 [卡牌目录](<../cards/>), 通用生成资格和去重见 [随机池](<random-pools.md>).

## 1. 状态与库存周期

普通流程是击败盲注 -> 结算并领取收入 -> 商店 `SHOP` -> 下一个盲注选择. 跳过盲注不产生一次普通商店访问. 标签可在普通商店之外直接打开免费包, 这不等于进入商店.

| 库存区域 | 默认数量 | 生成与补货时机 |
| --- | ---: | --- |
| `G.shop_jokers` | 2 | 每个新商店生成, 重掷时清空剩余卡并重新填满 |
| `G.shop_vouchers` | 1 | 一局开始确定本底注优惠券; 击败 Boss 后确定下一张; 已兑换后不立即补货 |
| `G.shop_booster` | 2 | 每个新商店生成 2 个包; 打开一个后不会立即补货 |

- 上方区域的名字虽是 `shop_jokers`, 却也容纳塔罗牌, 星球牌, 游戏牌和幻灵牌.
- 库存过剩 Overstock `v_overstock_norm` 和库存过剩加强版 Overstock Plus `v_overstock_plus` 各使上方槽位 +1, 正常累计为 3 和 4. 在当前商店兑换时会立即补满新增槽位.
- 买走上方卡牌不会自动补满空位, 必须重掷或进入新商店.
- 同底注内未兑换的普通优惠券会在后续商店继续出现. Boss 后重新抽券, 不是保证保留上一张未购买的券.
- 包的位置用 `current_round.used_packs[1..2]` 记录. 打开时记为 `USED`, 关闭包界面回到同一个商店不会再生成这个位置的包.
- 包界面保留原商店对象, 返回时不重建库存. 存档加载还原库存, 不重新抽卡.

来源: [Game:update_shop](<../../../game/game.lua#L3055-L3153>), [change_shop_size](<../../../game/functions/common_events.lua#L1097-L1116>), [end_round / new_round](<../../../game/functions/state_events.lua#L258-L313>), [cash_out](<../../../game/functions/button_callbacks.lua#L2897-L2940>), [use_card](<../../../game/functions/button_callbacks.lua#L2225-L2228>).

## 2. 上方每个卡牌槽位的生成

### 2.1 严格生成顺序

1. 教程若配置 `forced_shop`, 按其列表尾部依次取指定卡, 绕过普通抽样.
2. 尝试标签 `store_joker_create`, 如罕见/稀有标签. 若成功, 此槽直接成为相应小丑, 不抽类别权重; 再尝试 `store_joker_modify`.
3. 没有强制卡时, 计算下表权重之和 `T`.
4. 取 `u = pseudorandom(pseudoseed('cdt' .. ante))`, 令 `x=u*T`. 按 Joker -> Tarot -> Planet -> 游戏牌 -> Spectral 的累计区间选类别.
5. 以 `create_card(type, area, ..., key_append='sho')` 从类别池抽具体卡. 小丑再抽稀有度, 贴纸和版本.
6. 异步尝试 `store_joker_modify` 标签. 只作用于无版本且未预约版本修改的小丑.
7. 若抽到游戏牌且有幻象, 再走幻象专用版本抽样.

来源: [create_card_for_shop](<../../../game/functions/UI_definitions.lua#L742-L798>), [Tag:apply_to_run](<../../../game/tag.lua#L344-L446>).

### 2.2 类别权重

`P(type) = 当前该类 rate / T`, `T = joker_rate + tarot_rate + planet_rate + playing_card_rate + spectral_rate`. 先抽类别, 再抽其中的卡, 不按全卡目录合并均匀抽样.

| 类别 | 初始 rate | 改变规则 |
| --- | ---: | --- |
| 小丑牌 Joker | 20 | 普通优惠券不改此值 |
| 塔罗牌 Tarot | 4 | `v_tarot_merchant` 设置为 9.6; `v_tarot_tycoon` 设置为 32 |
| 星球牌 Planet | 4 | `v_planet_merchant` 设置为 9.6; `v_planet_tycoon` 设置为 32 |
| 游戏牌 Playing card | 0 | `v_magic_trick` / `v_illusion` 设置为 4 |
| 幻灵牌 Spectral | 0 | 幽灵牌组 Ghost Deck `b_ghost` 设置为 2 |

- 默认 `T=28`, 小丑 `20/28=5/7`, 塔罗和星球各 `4/28=1/7`.
- 单独有幽灵牌组时 `T=30`, 幻灵 `2/30=1/15`.
- 单独有魔术戏法时 `T=32`, 游戏牌 `4/32=1/8`.
- 商人/大亨是设置权重, 不是直接乘最终概率, 也不把两级数值再次相乘. 同时有其他增权效果时必须重新计算分母.
- 正常普通商店消耗牌调用的 `soulable` 为空, 所以幽灵牌组也不会在普通槽位抽出灵魂或黑洞.

来源: [Game:init_game_object](<../../../game/game.lua#L1882-L1887>), [Card:apply_to_run](<../../../game/card.lua#L1885-L1908>), [Back:apply_to_run](<../../../game/back.lua#L206-L208>), [优惠券原型](<../../../game/game.lua#L600-L618>), [create_card_for_shop](<../../../game/functions/UI_definitions.lua#L764-L776>).

### 2.3 小丑稀有度, 版本与贴纸

普通小丑生成先取 `r`:

| 区间 | 稀有度 | 理想均匀抽样概率 |
| --- | --- | ---: |
| `r <= 0.7` | 普通 Common | 70% |
| `0.7 < r <= 0.95` | 罕见 Uncommon | 25% |
| `r > 0.95` | 稀有 Rare | 5% |

传奇 Legendary 不能由普通稀有度抽样出现. 选中稀有度后只从该稀有度当前合资格卡中等概率抽取. 某稀有度池空时会落到普通 `j_joker`, 不重新抽另一稀有度.

默认小丑版本的互斥概率是无版本 96%, 闪箔 Foil 2%, 镭射 Holographic 1.4%, 多彩 Polychrome 0.3%, 负片 Negative 0.3%. 打磨/焕彩改变这些概率, 完整阈值公式与赌注贴纸规则见 [随机池](<random-pools.md#4-版本抽样>) 和 [贴纸抽样](<random-pools.md#5-商店和小丑包的贴纸抽样>).

来源: [get_current_pool](<../../../game/functions/common_events.lua#L1968-L1972>), [poll_edition / create_card](<../../../game/functions/common_events.lua#L2055-L2152>).

### 2.4 幻象对商店游戏牌的特殊处理

幻象 Illusion `v_illusion` 生效后, 每张商店游戏牌:

- 40% 选 `Enhanced`, 60% 选 `Base`; 增强从 8 种增强池等概率选取.
- 另一次抽样有 20% 获得版本. 在这 20% 内, 50% 闪箔, 35% 镭射, 15% 多彩. 换算全部游戏牌为 10%, 7%, 3%, 无版本 80%.
- 不生成负片或蜡封.
- 版本判断不调用 `poll_edition`, 所以不受打磨 Hone `v_hone`, 焕彩 Glow Up `v_glow_up` 的 `edition_rate` 影响.
- 增强与版本可同时存在; 概率是分开的判断, 不是互斥选项.

来源: [create_card_for_shop](<../../../game/functions/UI_definitions.lua#L768-L794>), [get_current_pool Enhanced](<../../../game/functions/common_events.lua#L1978-L1979>).

## 3. 购买, 可用资金与空间

### 3.1 普通购买

- 可用资金 `A = dollars - bankrupt_at`. 正价卡需要 `cost <= A`. 信用卡可以把 `bankrupt_at` 变为负数, 因此现金为负不必然不能买.
- 非正价普通卡和包可绕过资金不足判定. 优惠券的 `can_redeem` 没有这个非正价例外.
- 普通购买还要满足:

| 商品 | 空间条件 |
| --- | --- |
| 小丑 | `#jokers < joker_limit + (该新卡为负片 ? 1 : 0)` |
| 消耗牌 | `#consumeables < consumable_limit + (该新卡为负片 ? 1 : 0)` |
| 游戏牌 / 优惠券 | 不检查上述两种槽位 |
| 包 | 能买包不代表包中小丑能放入已有小丑区 |

默认小丑槽位 5, 消耗牌槽位 2. 用当前 `card_limit` 而不是固定值判断, 因为牌组, 优惠券, 负片会修改容量.

购买游戏牌加入整副牌和抽牌区; 购买小丑/消耗牌加入对应持有区域. 所有这些操作会触发 `buying_card`, 游戏牌还触发 `playing_card_added`. 普通购买不补货.

来源: [can_buy / can_buy_and_use / can_redeem / can_open](<../../../game/functions/button_callbacks.lua#L55-L118>), [check_for_buy_space / buy_from_shop](<../../../game/functions/button_callbacks.lua#L2377-L2458>), [get_starting_params](<../../../game/functions/misc_functions.lua#L1870-L1877>).

### 3.2 购买并立即使用

`buy_and_use` 跳过持有区空槽检查, 但同时检查资金和 `Card:can_use_consumeable()`. 它不是无条件绕过所有空间:

- 星球牌等直接生效卡可在消耗牌区满时购买并使用.
- 皇帝/女祭司/愚者等生成消耗牌仍需有生成空间, 从持有区使用时可把自身的槽位当成将要腾出的空间.
- 审判/灵魂/怨灵等生成小丑仍需小丑空槽.
- 要选择游戏牌的效果必须在允许操作手牌的状态并满足选择数量. 普通商店没有为这些效果额外抽出可修改的手牌.

具体卡的可用条件见 [消耗牌机制](<../mechanics/consumable-mechanics.md>). 来源: [buy_from_shop](<../../../game/functions/button_callbacks.lua#L2392-L2397>), [Card:can_use_consumeable](<../../../game/card.lua#L1523-L1567>).

### 3.3 精确标价公式

令 `B=base_cost`, `I=inflation`, `D=discount_percent` (无折扣 0, 促销 25, 清仓 50), `S=版本附加价`. 按以下顺序执行:

1. `C=max(1, floor((B + I + S + 0.5) * (100-D)/100))`.
2. 若挑战设置 `booster_ante_scaling` 且为包, 再加 `ante-1`.
3. 首次教程商店若尚未完成 `shop_1`, 包再加 3.
4. 持有有效天文学家时, 星球牌和天体包标价置 0.
5. 租赁卡标价置 1.
6. 出售价 `sell_cost=max(1,floor(C/2)) + extra_value`.
7. 若商品 `couponed` 且仍在上方卡区或包区, 购买标价置 0. 这个覆盖发生在出售价计算之后.

版本附加价: 闪箔 +$2, 镭射 +$3, 多彩 +$5, 负片 +$5. 塔罗/星球基价 $3, 幻灵 $4, 优惠券 $10, 包普通/巨型/超级 $4/$6/$8. 单个小丑基价查目录.

**必须保留括号位置**: `+0.5` 在乘折扣前, 不是 `floor((B+I+S)*(100-D)/100 + 0.5)`. 例如 `B=5,D=50` 得 $2. 折扣也会重新计算现有持牌的出售价, 不只是未来商品.

来源: [Card:set_cost](<../../../game/card.lua#L369-L384>), [Card:apply_to_run](<../../../game/card.lua#L1917-L1923>).

## 4. 重掷商店

### 4.1 重掷动作

1. 以动作前的 `current_round.reroll_cost` 支付.
2. 记录动作前是否仍有免费重掷 `final_free = free_rerolls > 0`, 然后免费次数减 1, 最低为 0.
3. 调用 `calculate_reroll_cost(final_free)` 更新下一次价格.
4. 移除并销毁所有剩余上方卡牌, 清除这些卡的占用标记.
5. 逐槽生成 `shop.joker_max` 张新卡.
6. 对持有的小丑发送 `reroll_shop`.

不刷新优惠券和包, 不限制累计次数. 重掷后的卡可以再次是之前见过但未持有的卡, 不是一局永久去重.

来源: [reroll_shop](<../../../game/functions/button_callbacks.lua#L2840-L2894>).

### 4.2 费用

若 `free_rerolls > 0`, 下一次价格为 0, 且 `calculate_reroll_cost` 提前返回, 不增加费用增量. 否则:

```text
若 skip_increment 为 false: reroll_cost_increase += 1
reroll_cost = (temp_reroll_cost 或 round_resets.reroll_cost) + reroll_cost_increase
```

- 默认基础 $5. 多次重掷 Reroll Surplus `v_reroll_surplus` 基础 -$2; 重掷加強版 Reroll Glut `v_reroll_glut` 再 -$2, 正常基础依次 $5/$3/$1.
- 普通付费序列 $5,$6,$7,...; 重掷费用优惠券对当前显示价也即时减 $2, 最低 0.
- 每个有效混沌小丑 Chaos the Clown `j_chaos` 提供一次免费重掷. 免费次数用尽后下一次回到当前基础价, 免费重掷不消耗通常的 +$1 阶梯.
- D6 标签把该商店临时基础设 0, 不是额外一次 `free_rerolls`. 无混沌免费次数时序列 $0,$1,$2,..., 第一次 $0 仍增加阶梯.
- 基础/增量和包库存重置发生在 `new_round`, 正常表现为每个新商店重置. 临时 D6 基础在后续回合结束时清除.
- 费用折扣优惠券 `discount_percent` 不作用于重掷费; 减重掷费的两张券才直接改此字段.

来源: [calculate_reroll_cost](<../../../game/functions/common_events.lua#L2263-L2268>), [new_round](<../../../game/functions/state_events.lua#L300-L313>), [Card:apply_to_run](<../../../game/card.lua#L1925-L1929>), [D6 标签](<../../../game/tag.lua#L382-L390>), [end_round](<../../../game/functions/state_events.lua#L270-L271>).

## 5. 包种类, 大小与抽中权重

`config.extra` 是展示卡数, `config.choose` 是最多选择数. 未修改的包价见下表. 同类不同图案是独立原型, 抽样时必须累计图案数量的权重.

| 包类别 | 普通: 卡数/选数/价 | 巨型 Jumbo | 超级 Mega | 普通图案数 x 单图权重 | 巨型图案数 x 单图权重 | 超级图案数 x 单图权重 |
| --- | --- | --- | --- | --- | --- | --- |
| 秘术 Arcana | 3/1/$4 | 5/1/$6 | 5/2/$8 | 4 x 1 | 2 x 1 | 2 x 0.25 |
| 天体 Celestial | 3/1/$4 | 5/1/$6 | 5/2/$8 | 4 x 1 | 2 x 1 | 2 x 0.25 |
| 标准 Standard | 3/1/$4 | 5/1/$6 | 5/2/$8 | 4 x 1 | 2 x 1 | 2 x 0.25 |
| 小丑 Buffoon | 2/1/$4 | 4/1/$6 | 4/2/$8 | 2 x 0.6 | 1 x 0.6 | 1 x 0.15 |
| 幻灵 Spectral | 2/1/$4 | 4/1/$6 | 4/2/$8 | 2 x 0.3 | 1 x 0.3 | 1 x 0.07 |

普通非保底抽样无禁用项时总权重 `W=3*6.5+1.95+0.97=22.42`. 各类别概率分别为秘术/天体/标准各 `6.5/22.42`, 小丑 `1.95/22.42`, 幻灵 `0.97/22.42`. 同类别再按各图案权重分配, 不应把五类当成各 20%.

每个普通包槽调用 `get_pack('shop_pack')`. 排除 `banned_keys` 后按累计权重抽样, 没有包图案去重, 因此 2 个槽可以相同.

### 5.1 首包保证

本局首次调用 `get_pack` 时, 若 `first_shop_buffoon` 尚未置位且 `p_buffoon_normal_1` 未被禁用, 直接置位并返回普通小丑包的两种图案之一. 这个提前返回在 `_type` 限制和权重计算之前执行.

普通流程首次调用就是首个商店的第一个包槽, 所以首次商店保证一个普通小丑包, 第二槽照常抽样. 不要求该商店在底注 1, 也不要求玩家此前未跳盲注. 内部图案用 `math.random(1,2)`, 不是单独的 `pack` 命名流. 分支只检查普通图案 1 的禁用, 不分别检查图案 2.

来源: [get_pack](<../../../game/functions/common_events.lua#L1944-L1960>), [包原型](<../../../game/game.lua#L665-L696>).

## 6. 包内卡牌生成

卡在打开时按位置 `i=1..size` 顺序生成, 不是购买前已经确定整包内容. 生成占用标记立即生效, 后面的卡会看到前面已生成的卡, 除非马戏团长取消去重.

| 类别 | 每个位置的生成流程 |
| --- | --- |
| 秘术 | 通常调用 `create_card('Tarot', ..., soulable=true, append='ar1')`; 有 `v_omen_globe` 时先掷 `omen_globe`, 大于 0.8 的 20% 改为 `Spectral` 和 `ar2` |
| 天体 | 通常 `Planet`, `soulable=true`, `pl1`; 有望远镜时位置 1 尝试强制最常出牌型的对应星球 |
| 幻灵 | `Spectral`, `soulable=true`, `spe` |
| 小丑 | `Joker`, `buf`, 普通稀有度分布, 版本和高赌注贴纸规则与商店小丑相同 |
| 标准 | 40% `Enhanced`, 60% `Base`, `sta`; 然后额外抽版本, 蜡封 |

望远镜 Telescope `v_telescope`: 遍历 `G.handlist`, 只考察 `visible=true`, 以严格 `played > 已记录最大值` 选牌型. 同次数保留顺序中先出现的牌型, 即牌型列表中较高优先级者. 若所有次数为 0, 不强制任何星球, 第一张也普通抽样. 一旦找到星球并指定 `forced_key`, 不受正常去重/隐藏替换约束, 可以与持有星球重复. 灵魂和黑洞的替换算法见 [随机池](<random-pools.md#3-灵魂与黑洞的隐藏替换>).

### 6.1 标准包概率

以下是在 `edition_rate=1`, 无禁用增强的默认条件下, 每张牌各步骤的概率:

| 属性 | 概率与分布 |
| --- | --- |
| 牌面 | 从 52 个 `P_CARDS` 原型等概率选取, 四花色各 1/4, 十三个点数各 1/13 |
| 无增强 | 60% |
| 增强 | 40%, 8 种各占全部卡的 5% |
| 无版本 | 92% |
| 闪箔 / 镭射 / 多彩 | 4% / 2.8% / 1.2% |
| 无蜡封 | 80% |
| 红 / 蓝 / 金 / 紫蜡封 | 各 5% |

版本调用 `poll_edition(key,2,true)`, 禁负片, 但会受打磨/焕彩提高的 `edition_rate` 影响: 全部非基础版本概率为 `0.08*edition_rate`, 当前正常 `edition_rate=1/2/4` 时为 8%/16%/32%. 蜡封先以 `seal_poll > 0.8` 判定 20% 出现, 再以四等区间选颜色.

增强, 版本和蜡封是不同步骤, 可叠加. 生成新的牌面而不是从玩家当前整副牌中抽取. 例如废弃/方格等牌组的起始牌组成不限制标准包的四花色十三点数原型池.

来源: [Card:open](<../../../game/card.lua#L1728-L1774>), [poll_edition](<../../../game/functions/common_events.lua#L2055-L2077>), [create_card front](<../../../game/functions/common_events.lua#L2124-L2126>).

## 7. 选择, 使用已有消耗牌, 跳过

- 秘术/天体/幻灵包的卡是立即使用, 不加入持有消耗牌槽. 可用性仍由 `can_use_consumeable` 逐卡检查.
- 标准包选中牌加入整副牌. 小丑包选中牌加入小丑区, 正常卡必须有空位; 负片卡有自己的额外槽位.
- 可少选, 甚至完全跳过. 已支付的包价不退还, 剩余卡销毁. `skip_booster` 向小丑发送 `skipping_booster`, 然后关闭包.
- 在包界面使用已经持有的消耗牌, 来源 `area==G.consumeables` 时不扣 `pack_choices`; 使用包内的卡才扣选择数. 已持有的卡也必须满足正常可用条件和状态约束.
- 当选择数降至最后一次并使用包内卡后, 自动关闭. Mega 包不是必须选完两张才能退出.
- 秘术/幻灵包界面等待相关手牌可用, 可以对这次包展示的手牌选择增强/改牌目标. 游戏正在播计分或抽牌动画, 控制锁定, `STOP_USE>0` 时不能强行提交使用动作.
- 打开包时消耗购买价, 并发送 `open_booster`. 通胀挑战购买包增加 `inflation`; 是否跳过不会撤销此增加.

来源: [can_select_card / can_skip_booster](<../../../game/functions/button_callbacks.lua#L2097-L2124>), [use_card](<../../../game/functions/button_callbacks.lua#L2196-L2270>), [skip_booster / end_consumeable](<../../../game/functions/button_callbacks.lua#L2543-L2600>), [Card:can_use_consumeable](<../../../game/card.lua#L1523-L1567>), [Card:open](<../../../game/card.lua#L1692-L1805>).

## 8. Wiki 交叉验证与版本边界

交叉验证页面: [The Shop](<https://balatrowiki.org/w/The_Shop>) 和 [The Soul](<https://balatrowiki.org/w/The_Soul>).

- 一致: 默认 2 卡/2 包/1 券, 首次普通小丑包, 类别权重 20/4/4, 稀有度 70%/25%/5%, 商人权重 9.6 和大亨 32, 幽灵牌组权重 2, 幻象 40% 增强/20% 版本, 重掷不补包/券.
- Wiki 价格章节标注其依据为 1.0.1f, 并用乘折扣后 round half down 描述结果. 对正常整数基价/附加价和 0%/25%/50% 折扣, 这与本地源码结果一致, 不是已确认的 f/n 行为差异. 此文仍保留 `+0.5` 位于折扣前的精确公式, 不替换成通常的半数向上四舍五入.
- Wiki 免费标签文案应按实际动作理解: 优惠券不免费, 优惠标签只把当次现有上方卡与包标为 `couponed`, 不自动让每次重掷后的新库存免费. 来源: [Coupon Tag](<../../../game/tag.lua#L447-L464>).
- 教程, 挑战 `banned_keys`, 强制标签, 强制卡, 容量修正都是上述默认概率的例外. 精确行动应读取当前库存/容量/标价, 不只按默认表猜测.
