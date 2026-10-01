# 整局修饰机制

适用版本: Balatro 1.0.1o. 说明优惠券 Voucher, 标签 Tag, 牌组 Deck 和挑战 Challenge 对一局状态的实际修改. 卡面名称/全文/原型列表分别见 [优惠券](<../cards/vouchers.md>), [标签](<../cards/tags.md>), [牌组](<../cards/decks.md>), [挑战](<../cards/challenges.md>). 本文件以源码 ID 为精确索引, 不把卡面概括误当完整算法.

## 1. 优惠券: 32 张, 16 对

### 1.1 兑换与升级

- 兑换扣除当前实际价格, 写入 `G.GAME.used_vouchers[id]=true`, 立即修改整局状态或启用后续代码分支. 不占消耗牌槽, 不能卖回.
- 原型基础价格均 `$10`, 但折扣/通胀等仍会改变实际价格. 解锁高级券是账号条件; 同一局还必须已兑换对应基础券, 才加入普通生成池.
- 已兑换券不会再次正常生成. 同商店已有的同 ID 券也从池中排除. 不要因两个券看起来属于 "升级" 就把所有数字相乘: 有些是新增量, 有些是覆盖字段, 有些只是布尔开关.
- 开局赠送券写入 used_vouchers 并应用效果, 不花钱, 不等同玩家点击兑换统计. 某些券的 `config.extra` 仅用于展示或无关旧值, 不应机械把它当真实效果值.

来源: [card.lua:1813-1865](<../../../game/card.lua#L1813-L1865>), `Card:redeem`, [common_events.lua:1987-2007](<../../../game/functions/common_events.lua#L1987-L2007>), `get_current_pool`, [back.lua:174-180](<../../../game/back.lua#L174-L180>).

### 1.2 完整效果表

| 基础券 ID / 中文名 / English | 基础实际效果 | 升级券 ID / 中文名 / English | 升级效果与两券合计 |
|---|---|---|---|
| `v_overstock_norm` 库存过剩 / Overstock | 卡牌展示槽 `+1` | `v_overstock_plus` 库存过剩加强版 / Overstock Plus | 再 `+1`; 普通 2 槽到 4 槽, 不增加补充包或优惠券槽 |
| `v_clearance_sale` 清仓特卖 / Clearance Sale | `discount_percent=25` | `v_liquidation` 清算 / Liquidation | 覆盖为 50%, 不是 25% 与 50% 连乘. 当前所有牌重算价格 |
| `v_hone` 打磨 / Hone | `edition_rate=2` | `v_glow_up` 焕彩 / Glow Up | 覆盖为 4, 不是 8. 影响普通版本抽取的闪箔/镭射/多彩阈值, 不提升负片阈值, 不影响 guaranteed 版本分支 |
| `v_reroll_surplus` 多次重掷 / Reroll Surplus | 永久重掷基础费用 `-2`, 当前费用也 `-2` 且不低于 0 | `v_reroll_glut` 重掷加強版 / Reroll Glut | 再 `-2`; 默认起价 5 到 1. 单次商店多次刷新仍继续涨价 |
| `v_crystal_ball` 水晶球 / Crystal Ball | 消耗牌栏上限 `+1`, 普通 2 到 3 | `v_omen_globe` 预兆球 / Omen Globe | 每个秘术包候选有 20% 改为 Spectral 生成路径; 不再增加槽位 |
| `v_telescope` 望远镜 / Telescope | 天体包第 1 个候选强制为最多出过的可见牌型的星球 | `v_observatory` 天文台 / Observatory | 每张持有的对应当前牌型星球牌在 `joker_main` 给 `X1.5` 倍率, 多张逐张相乘; 望远镜效果继续保留 |
| `v_grabber` 抓手 / Grabber | 永久每回合出牌次数 `+1`, 当前剩余也加 1 | `v_nacho_tong` 玉米片夹 / Nacho Tong | 再 `+1`; 默认每回合 4 到 6 |
| `v_wasteful` 常弃常新 / Wasteful | 永久每回合弃牌次数 `+1`, 当前剩余也加 1 | `v_recyclomancy` 回收魔法 / Recyclomancy | 再 `+1`; 默认 3 到 5 |
| `v_tarot_merchant` 塔罗牌商人 / Tarot Merchant | 商店 `tarot_rate=9.6` | `v_tarot_tycoon` 塔罗大亨 / Tarot Tycoon | 覆盖为 32, 不将 9.6 再乘 4. 基准 rate 为 4, 文案 X2/X4 不是精确 rate 系数 |
| `v_planet_merchant` 星球牌商人 / Planet Merchant | 商店 `planet_rate=9.6` | `v_planet_tycoon` 星球大亨 / Planet Tycoon | 覆盖为 32. 两种商人都提高对应权重, 因而相互影响归一化后的概率 |
| `v_seed_money` 种子基金 / Seed Money | `interest_cap=50`, 默认每 `$5` 利息 `$1`, 上限 `$10` | `v_money_tree` 摇钱树 / Money Tree | 覆盖为 100, 利息上限 `$20`, 不是两券给 `$30` |
| `v_blank` 空白 / Blank | 不修改计分/经济; 计入兑换与解锁统计 | `v_antimatter` 反物质 / Antimatter | 小丑槽 `+1`; 虽原型 extra=15, 实际不是增加 15 槽 |
| `v_magic_trick` 魔术 / Magic Trick | `playing_card_rate=4`, 商店可出普通游戏牌 | `v_illusion` 幻象 / Illusion | rate 仍为 4; 游戏牌 40% 为随机增强; 独立 20% 获版本, 分布闪箔 50%/镭射 35%/多彩 15%; 见 1.3 |
| `v_hieroglyph` 象形文字 / Hieroglyph | 当前底注与计分使用的 `blind_ante` 各 `-1`, 永久每回合出牌次数 `-1`, 当前剩余也 `-1` | `v_petroglyph` 岩画 / Petroglyph | 再底注 `-1`, 但这次永久/当前弃牌次数 `-1`; 不再扣出牌次数 |
| `v_directors_cut` 导演剪辑版 / Director's Cut | 每个底注可付 `$10` 重掷一次将要面对的 Boss | `v_retcon` 重构 / Retcon | 无每底注次数限制, 仍每次 `$10`; 没有第二档折扣 |
| `v_paint_brush` 油漆刷 / Paint Brush | 永久手牌上限 `+1` | `v_palette` 调色板 / Palette | 再 `+1`; 默认 8 到 10 |

原型数值: [game.lua:590-624](<../../../game/game.lua#L590-L624>). 应用: [card.lua:1880-1971](<../../../game/card.lua#L1880-L1971>), `Card:apply_to_run`. 后续分支: [card.lua:1730-1755](<../../../game/card.lua#L1730-L1755>), `Card:open`, [card.lua:2291-2301](<../../../game/card.lua#L2291-L2301>), `Card:calculate_joker`, [UI_definitions.lua:764-795](<../../../game/functions/UI_definitions.lua#L764-L795>), `create_card_for_shop`.

### 1.3 不能直接从文案推导的效果

- 幻象卡面说游戏牌可能有蜡封, 但本地 `create_card_for_shop` 的相关分支和通用 `create_card` 都没有给这些游戏牌加蜡封. 精确模拟本地规则时, 不为幻象额外增加蜡封概率; 标准包自己的蜡封逻辑不受这个结论影响.
- 望远镜只固定第一张, 不是整个包. 遍历 `G.handlist` 并用严格 `played > 当前最大值`, 所以并列最多时优先 handlist 中更前的牌型. 如果所有可见牌型都从未出过, `_tally=0` 不选到任何牌型, 第一张仍随机. 强制 ID 的这一张绕过灵魂/黑洞替换路径.
- 预兆球按每候选独立检查 `random > 0.8`, 不是整包 20% 变成幻灵包. 无预兆球时秘术包也可能因隐藏牌替换出现灵魂, 不应把所有非塔罗候选都归因于预兆球.
- 折扣核心公式: `max(1, floor((base_cost + edition_extra + inflation + 0.5) * (100-discount_percent)/100))`, 再处理包底注涨价和免费等特例. 不保证折扣恰好按比例降低取整后的标价.
- Boss 重掷的按钮还要求资金减破产额度足够支付 `$10`. Boss 标签调用同一重掷函数但不扣钱, 仍把 `boss_rerolled` 置真. 若只有导演剪辑版, 此后本底注的付费重掷按钮不可用, 直到下个底注重置标记; 重构不受该次数标记限制.

来源: [UI_definitions.lua:772-795](<../../../game/functions/UI_definitions.lua#L772-L795>), [common_events.lua:2082-2152](<../../../game/functions/common_events.lua#L2082-L2152>), [card.lua:369-384](<../../../game/card.lua#L369-L384>), [button_callbacks.lua:2769-2789](<../../../game/functions/button_callbacks.lua#L2769-L2789>).

## 2. 标签: 24 个

标签不是手里可主动使用的牌, 而是加入 `G.GAME.tags` 后等待自身 type 对应 context. 一次性标签触发后被移除. 跳过小/大盲注先增加整局 `skips`, 再处理新标签, 所以速度标签收益包括刚跳过的那一次.

### 2.1 触发时机与实际效果

| ID / 中文名 / English | context | 精确效果 |
|---|---|---|
| `tag_uncommon` 罕见标签 / Uncommon Tag | `store_joker_create` | 优先占用下一次商店卡牌生成, 生成免费罕见小丑; 不是直接放进库存 |
| `tag_rare` 稀有标签 / Rare Tag | `store_joker_create` | 同上, 改稀有. 如果全部稀有原型都已持有, 可能 nope 后消耗标签 |
| `tag_negative` 负片标签 / Negative Tag | `store_joker_modify` | 下一张商店无版本小丑变负片且免费 |
| `tag_foil` 闪箔标签 / Foil Tag | `store_joker_modify` | 下一张商店无版本小丑变闪箔且免费 |
| `tag_holo` 镭射标签 / Holographic Tag | `store_joker_modify` | 下一张商店无版本小丑变镭射且免费 |
| `tag_polychrome` 多彩标签 / Polychrome Tag | `store_joker_modify` | 下一张商店无版本小丑变多彩且免费 |
| `tag_investment` 投资标签 / Investment Tag | `eval` | 下一次成功击败 Boss 的回合结算加 `$25`, 不是拿到标签马上加钱 |
| `tag_voucher` 优惠券标签 / Voucher Tag | `voucher_add` | 下个商店新增一张可购买优惠券与一个券展示槽; 该券不免费 |
| `tag_boss` Boss 标签 / Boss Tag | `new_blind_choice` | 重掷将要面对的 Boss, 不扣 `$10`, 无需券 |
| `tag_standard` 标准标签 / Standard Tag | `new_blind_choice` | 免费打开超级标准包 Mega Standard, 5 选 2 |
| `tag_charm` 吊饰标签 / Charm Tag | `new_blind_choice` | 免费打开超级秘术包 Mega Arcana, 5 选 2 |
| `tag_meteor` 流星标签 / Meteor Tag | `new_blind_choice` | 免费打开超级天体包 Mega Celestial, 5 选 2 |
| `tag_buffoon` 小丑标签 / Buffoon Tag | `new_blind_choice` | 免费打开超级小丑包 Mega Buffoon, 4 选 2 |
| `tag_handy` 顺手标签 / Handy Tag | `immediate` | `$1 * G.GAME.hands_played`, 是已实际出过的总手数, 不是剩余出牌次数 |
| `tag_garbage` 垃圾标签 / Garbage Tag | `immediate` | `$1 * G.GAME.unused_discards`, 是已完成回合累计剩余未用弃牌, 不是累计弃掉卡牌数 |
| `tag_ethereal` 空灵标签 / Ethereal Tag | `new_blind_choice` | 免费打开普通幻灵包 Spectral, 2 选 1, 不是超级幻灵包 |
| `tag_coupon` 代金券标签 / Coupon Tag | `shop_final_pass` | 下个商店初始卡牌与补充包免费, 不含优惠券与刷新费用 |
| `tag_double` 双倍标签 / Double Tag | `tag_add` | 下一次加入的非双倍标签额外复制 1 个, 见 2.2 |
| `tag_juggle` 杂耍标签 / Juggle Tag | `round_start_bonus` | 下个实际玩的回合临时手牌上限 `+3`, 回合结束移除临时增量 |
| `tag_d_six` D6 标签 / D6 Tag | `shop_start` | 下个商店刷新基础价 0; 以后每次刷新仍涨价, 不是永久免费刷新 |
| `tag_top_up` 充值标签 / Top-up Tag | `immediate` | 最多添加 2 张普通小丑到库存, 每张先检查是否有小丑空位 |
| `tag_skip` 速度标签 / Skip Tag | `immediate` | 加 `$5 * G.GAME.skips`, 包括当次跳过 |
| `tag_orbital` 轨道标签 / Orbital Tag | `immediate` | 指定的 `orbital_hand` 升 3 级, 不是使用时再随机改一个牌型 |
| `tag_economy` 经济标签 / Economy Tag | `immediate` | 加钱 `min(40, max(0, 当前资金))`, 不把债务翻倍 |

来源: [game.lua:224-248](<../../../game/game.lua#L224-L248>), 标签原型, [tag.lua:115-468](<../../../game/tag.lua#L115-L468>), `Tag:apply_to_run`. 补充包数值: [game.lua:664-696](<../../../game/game.lua#L664-L696>). 结束清理: [state_events.lua:270-271](<../../../game/functions/state_events.lua#L270-L271>).

### 2.2 双倍, 免费与顺序

- 双倍标签只在 `add_tag` 收到非 `tag_double` 的新标签时触发, 不复制双倍标签自身. 已存 `n` 个双倍标签, 下一个非双倍标签总计获得 `n+1` 个, 不是 `2^n` 个. 它们在安排复制前置 triggered, 所以递归加标签不造成指数倍增.
- 轨道标签复制品继承原牌型选择, 不重新随机. 多个轨道标签各升 3 级. 多个经济标签依次读实际资金, 可连续翻倍, 每次新增最多 `$40`.
- 投资标签可以同时保留多个, 击败 Boss 时每个各给 `$25`. 非 Boss 回合不消耗它们. 无盲注基础奖励的挑战也不自动取消投资收入, 因为是独立标签结算行.
- 商店强制罕见/稀有牌生成后, 仍走版本标签修改流程, 所以可以同时得到免费稀有负片等组合. 版本标签只接受无版本且未被临时标记的小丑, 不覆盖已随机带版本的小丑; 找不到候选时可留待以后生成/刷新.
- 多个版本标签不能都堆到同一张小丑上: 修改成功即标记 temp_edition, 外层也只处理首个成功修改. 免费不清除永恒/易腐/租赁贴纸; 免费购买租赁牌仍要承担后续租金.
- `ability.couponed=true` 只让处于商店卡牌/补充包区域的买价变 0, `sell_cost` 在这一步之前计算, 因而免费拿到的牌不必只有 `$1` 售价, 出商店后也不是永远标价 0.
- 代金券/D6 标签分别以 shop_free/shop_d6ed 保证一个商店不会重复应用. 多个同类标签不会把所有后续商店合并为一次永久优惠, 尚未触发者可留后续商店.
- 包类标签按 `new_blind_choice` 一个成功就中断遍历, 多个免费包会依次开, 不是同时显示多个包. 标签免费包的选牌与使用仍受槽位和消耗牌目标条件限制.

来源: [UI_definitions.lua:1252-1270](<../../../game/functions/UI_definitions.lua#L1252-L1270>), `add_tag`, [tag.lua:319-465](<../../../game/tag.lua#L319-L465>), [UI_definitions.lua:750-781](<../../../game/functions/UI_definitions.lua#L750-L781>), [card.lua:369-384](<../../../game/card.lua#L369-L384>), [button_callbacks.lua:2758-2761](<../../../game/functions/button_callbacks.lua#L2758-L2761>).

## 3. 牌组: 15 种

普通基准: `$4`, 出牌 4, 弃牌 3, 手牌上限 8, 小丑槽 5, 消耗牌槽 2, 52 张游戏牌. 表中为白赌注的相对改动, 高赌注还会按 [赌注规则](<../rules/stakes.md>) 叠加.

| ID / 中文名 / English | 实际开局/整局修改 | 常规解锁条件 |
|---|---|---|
| `b_red` 红色牌组 / Red Deck | 弃牌 `+1`, 即 4 | 初始解锁 |
| `b_blue` 蓝色牌组 / Blue Deck | 出牌 `+1`, 即 5 | 发现 20 项收藏 |
| `b_yellow` 黄色牌组 / Yellow Deck | 资金 `+10`, 即 `$14` | 发现 50 项收藏 |
| `b_green` 绿色牌组 / Green Deck | 剩余每次出牌付 `$2`, 剩余每次弃牌付 `$1`, 不收利息 | 发现 75 项收藏 |
| `b_black` 黑色牌组 / Black Deck | 小丑槽 `+1` 到 6, 出牌 `-1` 到 3 | 发现 100 项收藏 |
| `b_magic` 魔法牌组 / Magic Deck | 免费已兑换水晶球 `v_crystal_ball`, 消耗牌槽 3; 开局 2 张愚者, 但尚无 last_tarot_planet, 不能开局空复制 | 用红色牌组获胜 |
| `b_nebula` 星云牌组 / Nebula Deck | 免费已兑换望远镜 `v_telescope`, 消耗牌槽 `-1` 到 1 | 用蓝色牌组获胜 |
| `b_ghost` 幽灵牌组 / Ghost Deck | 商店 Spectral 权重设为 2, 初始 1 张妖法 `c_hex`, 不把所有牌免费变多彩 | 用黄色牌组获胜 |
| `b_abandoned` 废弃牌组 / Abandoned Deck | 初始去掉全部 J/Q/K, 40 张; A 保留, 之后仍可生成/加入人头牌 | 用绿色牌组获胜 |
| `b_checkered` 方格牌组 / Checkered Deck | 梅花改黑桃, 方片改红桃, 得到 26 黑桃和 26 红桃; 每个点数每种剩余花色各 2 张 | 用黑色牌组获胜 |
| `b_zodiac` 黄道牌组 / Zodiac Deck | 已兑换塔罗牌商人, 星球牌商人, 库存过剩; 商店卡槽 3, 两种权重各 9.6 | 在红赌注获胜 |
| `b_painted` 彩绘牌组 / Painted Deck | 手牌上限 `+2` 到 10, 小丑槽 `-1` 到 4 | 在绿赌注获胜 |
| `b_anaglyph` 浮雕牌组 / Anaglyph Deck | 每次 Boss 成功结算时获得 1 个双倍标签, 小/大盲注不发 | 在黑赌注获胜 |
| `b_plasma` 等离子牌组 / Plasma Deck | 每手最终计分前平衡筹码和倍率, 盲注目标乘 2 | 在蓝赌注获胜 |
| `b_erratic` 古怪牌组 / Erratic Deck | 初始生成 52 张, 每张独立从全部 52 基础点数/花色组合随机抽取, 允许重复, 不保证 13 张每花色 | 在橙赌注获胜 |

来源: [game.lua:628-642](<../../../game/game.lua#L628-L642>), 解锁原型, [misc_functions.lua:1868-1880](<../../../game/functions/misc_functions.lua#L1868-L1880>), `get_starting_params`, [back.lua:174-278](<../../../game/back.lua#L174-L278>), `Back:apply_to_run`, [game.lua:2310-2331](<../../../game/game.lua#L2310-L2331>).

### 3.1 等离子牌组的最终步骤

所有前面的牌型, 游戏牌, 手牌, 小丑和版本触发结束后, 令 `T = chips + mult`, 最终二者均为 `floor(T/2)`, 一手得分为 `floor((chips+mult)/2)^2`. 不是取几何平均, 不保持原筹码乘倍率不变, 也不是分别把二者乘 2. 后续回合仍重复平衡, 不永久改变牌型基数.

来源: [back.lua:125-170](<../../../game/back.lua#L125-L170>), `Back:trigger_effect`. 浮雕发标签在 [back.lua:111-119](<../../../game/back.lua#L111-L119>).

## 4. 挑战模式

### 4.1 基础差异与数据语义

- 正常挑战入口强制白赌注 `stake=1`, 使用独立挑战牌组和给定开局数据, 不是普通牌组加一条文案.
- `rules.modifiers` 覆盖 `starting_params[id]` 为指定值, 不是加到默认值. 如 hands=1 就是每回合 1 次, dollars=10 就是初始 `$10`.
- `rules.custom` 进入 `G.GAME.modifiers`, 或转写奖励/商店权重字段, 效果将在各游戏流程处检查. 它是运行规则而非展示用提示.
- `deck.cards` 存在就逐条创建指定游戏牌, 保留重复点数/花色, 并应用条目里的增强/版本/蜡封. 缺失时建立普通基础牌组, 再应用 rank/suit 筛选等字段.
- `jokers`, `consumeables`, `vouchers` 是开局赠品. 小丑的 edition/eternal/pinned 是真实状态, 负片会增加实际槽位. 已赠送券视为本局 used_vouchers, 升级券的依赖仍按此状态判断.
- restrictions 中 banned_cards 的 `id` 和 `ids` 批量列表, banned_tags, banned_other 都进入同一 `banned_keys`. 禁止是按 ID 的生成限制, 不是把已经拥有的同类实物自动销毁.
- 解锁挑战需要 5 种不同普通牌组的白赌注胜利. 先开前 5 个挑战, 以后可用挑战数 `min(20, 已完成挑战数+5)`, 不要求严格按顺序完成. 挑战完成单独记录, 不等同普通牌组/赌注胜利解锁.

来源: [button_callbacks.lua:1832-1834](<../../../game/functions/button_callbacks.lua#L1832-L1834>), [game.lua:2045-2130](<../../../game/game.lua#L2045-L2130>), `Game:start_run`, [misc_functions.lua:1112-1132](<../../../game/functions/misc_functions.lua#L1112-L1132>), `set_challenge_unlock`, [globals.lua:340](<../../../game/globals.lua#L340>).

### 4.2 所有实际 custom rules

| custom ID | 实际行为 | 生效位置 |
|---|---|---|
| `no_reward` | 将 Small/Big/Boss 的基础盲注奖励全设为无; 不禁止小丑收入, 标签收入, 打牌收入 | [game.lua:2091-2098](<../../../game/game.lua#L2091-L2098>) |
| `no_reward_specific` | 仅关闭 value 对应类型基础奖励, 如 Small/Big | 同上 |
| `no_extra_hand_money` | 回合结算不付剩余出牌钱; 不削减出牌次数本身 | [state_events.lua:1165-1168](<../../../game/functions/state_events.lua#L1165-L1168>) |
| `no_interest` | 不付普通利息, 提高利息上限的券无法绕过 | [state_events.lua:1191-1202](<../../../game/functions/state_events.lua#L1191-L1202>) |
| `chips_dollar_cap` | 每次 `mod_chips` 返回 `min(筹码, max(资金,0))`, 限制的是筹码字段而非最终得分; 负债可把筹码压至 0 | [misc_functions.lua:684-688](<../../../game/functions/misc_functions.lua#L684-L688>) |
| `flipped_cards=4` | 进入当前手牌的牌有 `1/4` 概率背面朝上; 是随机抽牌信息限制, 不是每 4 张固定 1 张. 分母直接使用 4, 不用 probabilities.normal | [common_events.lua:403-404](<../../../game/functions/common_events.lua#L403-L404>), [cardarea.lua:601-602](<../../../game/cardarea.lua#L601-L602>) |
| `minus_hand_size_per_X_dollar=5` | 更新时动态扣 `floor(资金/5)` 的手牌上限; 资金花掉后恢复这部分. 代码没有 `max(资金,0)`, 负债会产生负扣减即增加上限 | [cardarea.lua:243-249](<../../../game/cardarea.lua#L243-L249>) |
| `all_eternal` | 通用 create_card 生成小丑时调用 set_eternal(true), 包括非商店来源. 该方法仍要求 eternal_compat 且非 perishable | [common_events.lua:2133-2135](<../../../game/functions/common_events.lua#L2133-L2135>), [card.lua:506-510](<../../../game/card.lua#L506-L510>) |
| `debuff_played_cards` | 一手结算尾部仅对 scoring_hand 中的牌设 `ability.perma_debuff=true`, 此后 update 保持 debuff. 非计分踢脚牌不因只被打出而永久削弱, 且不在本次计分之前削弱 | [state_events.lua:1077-1083](<../../../game/functions/state_events.lua#L1077-L1083>), [card.lua:4157-4158](<../../../game/card.lua#L4157-L4158>) |
| `set_eternal_ante=4` | 成功击败底注 4 的 Boss 时对当前小丑调用 set_eternal(true), 不是进入底注 4 时提前永恒, 也不是持续 all_eternal | [state_events.lua:238-248](<../../../game/functions/state_events.lua#L238-L248>) |
| `set_joker_slots_ante=4` | 同一时刻将实际小丑槽上限直接设为 0, 不删除当前小丑. 不永久拦截以后其他槽位增量 | 同上 |
| `inflation` | 每购买卡牌, 打开任意补充包, 兑换优惠券后 inflation `+1`, 重算全部卡价. `$0` 买入及标签赠送的免费包也进入增长分支; 刷新本身不是买牌不增加它 | [button_callbacks.lua:2440-2446](<../../../game/functions/button_callbacks.lua#L2440-L2446>), [card.lua:1800-1806](<../../../game/card.lua#L1800-L1806>), [card.lua:1858-1864](<../../../game/card.lua#L1858-L1864>) |
| `no_shop_jokers` | 仅把商店 joker_rate 设为 0, 不自动禁止小丑包/审判/灵魂/充值/强制标签; 完整禁小丑还依赖 bans 和槽位 | [game.lua:2101-2104](<../../../game/game.lua#L2101-L2104>) |
| `discard_cost=1` | 每次正常弃牌动作扣 `$1`, 与一次弃几张无关; Hook 自动弃牌不扣该费用, 也不减一次玩家弃牌 | [state_events.lua:432-437](<../../../game/functions/state_events.lua#L432-L437>) |

挑战原型开头的大段 TEST 已注释, 不属于 20 个可玩挑战. 其 daily/set_seed 等样例不应被当作本版本的可玩挑战规则.

### 4.3 20 个挑战的规则组合

这里列出行为区别, 完整开局卡列表及 banned ID 列表保留在 [挑战目录](<../cards/challenges.md>). 顺序与源原型一致.

| ID / 中文名 / English | 相对普通白赌注的实际区别 |
|---|---|
| `c_omelette_1` 煎蛋卷 / The Omelette | 初始 5 张 Egg, no_reward + no_extra_hand_money + no_interest; 主要被关闭的是三类常规结算收入, 不是所有赚钱手段. bans 禁部分被动赚钱小丑/利息券 |
| `c_city_1` 15 分钟都市 / 15 Minute City | 初始永恒 Ride the Bus + Shortcut. 每花色 4..10 各一张, J/Q/K 各两张, 共 52 张; 无 A/2/3. 无 custom modifier, 靠小丑与牌组构成改变判定/成长 |
| `c_rich_1` 富者愈富 / Rich get Richer | 初始 `$100`, 已有种子基金+摇钱树, 利息上限 `$20`; chips_dollar_cap, 资金同时限制可计筹码 |
| `c_knife_1` 刀锋之上 / On a Knife's Edge | 初始永恒且 pinned 的 Ceremonial Dagger. pinned 是锁定最左位置, 不等同禁用该小丑. 无 custom modifier |
| `c_xray_1` X 光视界 / X-ray Vision | flipped_cards=4, 抽牌随机背面; 其他默认 |
| `c_mad_world_1` 疯狂世界 / Mad World | 初始负片永恒 Pareidolia + 永恒 Business Card, 32 张 2..9; no_extra_hand_money + no_interest, Boss The Plant 禁止 |
| `c_luxury_1` 奢侈税 / Luxury Tax | 基础手牌上限设 10, 动态减 floor(资金/5); 财富增加会降低上限, 花钱可恢复 |
| `c_non_perishable_1` 不腐之物 / Non-Perishable | all_eternal, 不兼容永恒的自毁/出售类小丑由 bans 排除, Verdant Leaf 禁止. 不是易腐贴纸规则 |
| `c_medusa_1` 美杜莎 / Medusa | 初始永恒 Marble Joker, J/Q/K 全部石头增强; 52 张, 无 custom modifier |
| `c_double_nothing_1` 孤注一掷 / Double or Nothing | 全初始牌红蜡封, debuff_played_cards; 首次计分可以正常重触发, 之后那些计分牌永久削弱 |
| `c_typecast_1` 角色固化 / Typecast | 底注 4 Boss 击败后当前兼容小丑永恒且槽位设 0; 不在底注 4 开始前发生. Verdant Leaf 禁止 |
| `c_inflation_1` 通货膨胀 / Inflation | 初始 Credit Card, 每次买牌/买包/兑换造成后续价格基数加 1; 两张折扣券被禁 |
| `c_bram_poker_1` 布莱姆·扑克 / Bram Poker | 初始永恒 Vampire, 皇后+皇帝, 魔术+幻象. no_shop_jokers 只取消商店自然小丑权重, 不是完整无小丑挑战 |
| `c_fragile_1` 易碎品 / Fragile | 初始两张负片永恒 Oops! All 6s, 全 52 张玻璃增强; 概率分子变 4, 玻璃正常 1/4 破碎变必碎. bans 禁多数替代增强和新牌来源, 但非另一个 custom rule |
| `c_monolith_1` 巨石 / Monolith | 初始永恒 Obelisk + 负片永恒 Marble Joker, 标准牌组; 无 custom modifier, 保留两小丑各自成长机制 |
| `c_blast_off_1` 点火升空 / Blast Off | 每回合出牌 2/弃牌 2, 小丑槽 4; 永恒 Constellation+Rocket, 已有星球牌商人+星球大亨, planet_rate=32; 禁加出牌券/窃贼 |
| `c_five_card_1` 五连抽 / Five-Card Draw | 手牌上限 5, 小丑槽 7, 弃牌 6; 初始 Card Sharp+Joker; 禁部分加手牌上限小丑, 但未普遍禁手牌上限变化 |
| `c_golden_needle_1` 金针 / Golden Needle | 出牌 1, 弃牌 6, 初始 `$10` 和 Credit Card; 正常弃牌每次 `$1`; 禁增加出牌次数的两券和 Burglar |
| `c_cruelty_1` 残酷 / Cruelty | 小丑槽 3, no_reward_specific Small + Big; Boss 基础奖励仍存在, 小/大盲注仍可有其他结算收益 |
| `c_jokerless_1` 无小丑 / Jokerless | 小丑槽 0 + 商店 joker_rate=0 + 审判/幽灵/灵魂/反物质/全部小丑包及相关标签 bans; 是组合封锁而非单一全局无小丑开关. 末关中依赖小丑的 Acorn/Heart/Leaf 禁止 |

来源: [challenges.lua:62-738](<../../../game/challenges.lua#L62-L738>), `G.CHALLENGES`. 原型决定开局和禁用项, 各 custom 行为按 4.2 的实际调用解释.

## 5. 决策所需状态字段

每次获得/兑换/使用这类修饰后, agent 至少重新观测:

- `used_vouchers`, 商店槽数, 各生成权重, 实际卡价, 当前及永久刷新基础价.
- 当前和永久出牌/弃牌次数, 当前手牌上限, `temp_handsize`, 小丑/消耗牌实际槽位与负片来源.
- 标签队列与各标签 triggered 状态, 投资待兑现数量, 下一次轨道牌型, 双倍待复制数量.
- challenge 的 modifiers, banned_keys, 当前 ante 与 blind_ante. 规则相同的卡面在不同挑战下可能有不同合法购买/生成空间.

Wiki 交叉核对: [Balatro Wiki - Ankh](https://balatrowiki.org/w/Ankh) 对不腐之物挑战中永恒保护, 角色固化导致生命十字章因槽位不足不可用, 无小丑挑战禁生成来源的描述与本地组合规则一致. 页面不是固定 1.0.1o 快照, 精确生效时刻, 数值与源码细节仍按本文链接处为准.
