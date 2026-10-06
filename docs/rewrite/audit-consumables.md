# 消耗牌与卡牌审计

## 基准与验证层级

范围为 52 张消耗牌, 32 张优惠券, 15 副牌组, 8 种强化, 4 种蜡封与 4 种版本. 基准是已套用 Lovely 补丁的游戏源码及 Steamodded runtime 覆写, 而非只看原版 Lua. 端点可用状态以 bbcore 的 use/buy/pack 规则为准. Installed Steamodded 与仓库版本在本范围内一致.

- S: 对照 patched source 和 runtime 分支, 覆盖分类表的全部原型.
- R: 本地 Rust 行为回归, 包括全部 52 张在有效上下文执行并消耗.
- L: 执行补丁树真实 Lua 函数的隔离 oracle, 验证复制/排序/终端随机选择及 Grim 关键链路.
- G: 真实游戏整局 oracle. 由主审计会话统一执行, 本报告不把 S/R/L 说成 G.

主要源码入口是 [原型注册表](<../../game/game.lua>), [Steamodded 原型与消耗牌覆写](<../../mods/Steamodded/src/game_object.lua>), [随机选择补丁](<../../mods/Steamodded/lovely/pool.toml>), [消耗牌使用端点](<../../mods/bbcore/src/lua/endpoints/use.lua>) 和 [目标规则](<../../mods/bbcore/src/lua/utils/target_rules.lua>). 隔离 Lua oracle 使用 [实际补丁树](<../../.tmp/engine-audit/modded-tree/card.lua>) 的函数, 不修改上游游戏源码.

## 已确认差异和处理

| 项目 | 游戏规则 | 原实现问题 | 处理范围 |
| --- | --- | --- | --- |
| 消耗牌拒绝 | can_use 通过后才更新统计/使用 | 错误目标先涨 Fortune Teller/塔罗数 | flow 原子执行 + consumable validate_use |
| Wraith | 创建稀有小丑后清零全部现金, 含负现金 | 未清钱 | flow 协作补丁 |
| Hermit | 加 max(0, min(cash, 20)) | 负现金被翻倍 | flow 协作补丁 |
| Wheel | probability normal/4, 按对象位置选 eligible | 固定 1/4, 同名小丑回找错对象 | flow 协作补丁 |
| Fool | 只复制上一次 Tarot/Planet | Spectral 覆写 last | flow 协作补丁 |
| Aura/Hex/Ecto/Ankh/creator | 可用性/空位必须成立 | 无目标成功或消费; Shop/Pack 临时 push 借槽 | validator + flow 来源校验 |
| Sigil/Ouija | 使用 SMODS 的终端 picker 顺序 | 用字符构建牌堆顺序 | flow 协作补丁 |
| Familiar/Grim/Incantation | face/number 后 suit, 单独 spe_card 池不含 Stone | 花色池错且 fraction cast 导致全 Bonus | flow 协作补丁 |
| 随机销毁 | 终端 picker 按对象 sort_id 排候选手牌 | 直接用当前 UI 手牌位置选对象 | flow 协作补丁 |
| Immolate | 按 Card.sort_id 排, immolate shuffle, 取前 5 | 五次 random_destroy | flow 协作补丁 |
| Ankh | 副本剥 Negative, 其余非 Eternal 销毁执行 loss | 保负片, 遗漏 loss/forget | flow 协作补丁 |
| 6 张计数券 | 即刻同时改 resets 和 left | 只改 defaults | voucher 已修改 |
| Overstock 两张 | 立即补货到扩容上限, 含买空格子 | voucher.apply 只改 slots | voucher 已修改; flow 原有 topup 保留但不多造 |
| Death 与新复制 | 前者保目标首次花色/身份, 后者空 base 首次值 0 | 直接 clone 来源首次花色 | cards helpers + nominal wrapper |
| Card:get_nominal | patched rank*10, suit 倍率 10000, 首次值同 suit 名义值 | 原版缩放数值, 复制历史值偏差 | playing/instance 已修改并 L oracle |
| Gift Card / Perkeo | 每张小丑及消耗牌累加 sell extra; Perkeo/Blueprint 完整复制能力 | 消耗牌无字段, 多张 Gift 只一次, Perkeo 只拷贝 key/edition | Consumable extra_value 新增, flow 协作 |
| 销毁/创建生命周期 | 主动销毁和新建牌通知对应小丑 | 遗漏 Canio/Glass/Hologram 成长 | flow/joker 协作, 关键互作回归 |

独占实现入口为 [消耗牌可用性](<../../engine/src/run/consumable.rs>), [优惠券效果](<../../engine/src/run/voucher.rs>), [卡牌实例复制](<../../engine/src/cards/instance.rs>) 和 [扑克牌排序名义值](<../../engine/src/cards/playing.rs>). 跨模块行为由 flow/scoring/joker/pool 协作者接入.

## 52 张消耗牌逐组清单

每一行列出的原型都进行了 S 检查, 并纳入 R 的有效上下文执行测试. 功能族的关键断言另由 [审计回归](<../../engine/tests/audit-consumables.rs>) 和 [既有 Tarot 测试](<../../engine/tests/tarot.rs>) 覆盖.

| 功能族 | 原型键 | 核查内容 |
| --- | --- | --- |
| Tarot - 创建/历史 (4) | c_fool, c_high_priestess, c_emperor, c_judgement | 上次记录, 使用来源, 空位, 每张产物 |
| Tarot - 强化 (8) | c_magician, c_empress, c_heirophant, c_lovers, c_chariot, c_justice, c_devil, c_tower | 数量上限, 增强替换, 永久 bonus, blind 刷新 |
| Tarot - 变花色 (4) | c_star, c_moon, c_sun, c_world | 最多 3, 底牌身份, 首次花色历史 |
| Tarot - 其它 (6) | c_hermit, c_wheel_of_fortune, c_strength, c_hanged_man, c_death, c_temperance | 负现金, 概率, 循环 rank, 永久销毁, 右端 source, 卖价 sum |
| Planet (12) | c_mercury, c_venus, c_earth, c_mars, c_jupiter, c_saturn, c_uranus, c_neptune, c_pluto, c_planet_x, c_ceres, c_eris | 对应 12 牌型 level+1, usage, Constellation, Fool 历史, 隐藏牌型 softlock 生成 |
| Spectral - 销毁生成 (4) | c_familiar, c_grim, c_incantation, c_immolate | 摧毁上下文, rank/suit/enhancement RNG, ID 顺序, 现金 |
| Spectral - 蜡封/复制 (5) | c_talisman, c_deja_vu, c_trance, c_medium, c_cryptid | 单目标, 替换 seal, 2 份新牌, 永久 modifier 与 ID |
| Spectral - 版本 (4) | c_aura, c_ectoplasm, c_hex, c_ankh | eligible, 保证 edition, Negative 容量, 递增 Ecto 减 size, Eternal/loss |
| Spectral - 整手 (2) | c_sigil, c_ouija | 手中至少 2, 最终随机池, 减 size |
| Spectral - 其它 (3) | c_wraith, c_soul, c_black_hole | 稀有/传奇, 空位, cash0, 全部 12 level |

合计为 22 Tarot + 12 Planet + 18 Spectral = 52. 全部有效上下文执行属于 R 的功能入口覆盖, 并非每张的全部状态组合都获得 G 验证.

## 32 张优惠券逐组清单

| 原型键 | 核查结果/效果路径 |
| --- | --- |
| v_overstock_norm, v_overstock_plus | apply 立即补当前货架, 之后 restock/reroll 保持容量 |
| v_clearance_sale, v_liquidation | discount 设置 25/50, 所有价格重算不叠乘 |
| v_hone, v_glow_up | edition rate 2/4, poll_edition 读取 |
| v_reroll_surplus, v_reroll_glut | 基础重掷价各 -2, 当前价由 base+rerolls 推导 |
| v_crystal_ball, v_omen_globe | 前者 +1 消耗槽; 后者 Arcana 生成 Spectral 分支 |
| v_telescope, v_observatory | 第一个 Celestial 按最常打牌型, 同次数按牌型顺序; 手持对应 Planet 按份 X1.5 |
| v_grabber, v_nacho_tong | 默认/当前 hands 都 +1 |
| v_wasteful, v_recyclomancy | 默认/当前 discards 都 +1 |
| v_tarot_merchant, v_tarot_tycoon | Tarot 权重 9.6/32, 不累计乘前者 |
| v_planet_merchant, v_planet_tycoon | Planet 权重 9.6/32 |
| v_seed_money, v_money_tree | 利息本金 cap 50/100 |
| v_blank, v_antimatter | Blank 仅前置记录; Antimatter +1 Joker 槽 |
| v_magic_trick, v_illusion | Playing card 商店权重 4, Illusion 强化/版本随机生成 |
| v_hieroglyph, v_petroglyph | ante-1, 对应默认/当前 hand 或 discard-1, blind_ante 协作核查 |
| v_directors_cut, v_retcon | Boss 重掷 10, 一次/无限, 事务错误校验 |
| v_paint_brush, v_palette | hand size 各 +1, SelectingHand 需要立刻补抽 |

16 对共 32 张全部进行了 S 分类. 即时数值关键路径由 [优惠券测试](<../../engine/tests/voucher.rs>) 和 [审计回归](<../../engine/tests/audit-consumables.rs>) 覆盖, 生成/算分/flow 路径分别由对应协作者覆盖. 不声称 32 张都已独立执行真实游戏 oracle. 货架保留断言使用当前多优惠券集合, 不依赖已撤销的临时来源字段.

## 15 副牌组逐项清单

| 原型 | 核查效果 |
| --- | --- |
| b_red | +1 discards |
| b_blue | +1 hands |
| b_yellow | +10 起始 cash |
| b_green | 每剩 hand 2, discard 1, 无 interest |
| b_black | hands-1, Joker+1 |
| b_magic | Crystal Ball 与 2 张 Fool, 强制 create 调用/RNG 顺序 |
| b_nebula | Telescope, consumable 槽 -1 |
| b_ghost | shop Spectral rate 2, Hex |
| b_abandoned | 去掉 J/Q/K 但保 A, 40 张 |
| b_checkered | Clubs->Spades, Diamonds->Hearts, 保首次花色历史 |
| b_zodiac | Tarot Merchant/Planet Merchant/Overstock 三张 |
| b_painted | hand size+2, Joker 槽 -1 |
| b_anaglyph | 击败 Boss 给 Double Tag |
| b_plasma | target x2, Chips/Mult 平均后相乘, 浮点不提前 floor |
| b_erratic | Erratic 哈希池重抽 52, 重复允许, 按字符身份排序后编号 |

15 张配置逐项与 patched Back:apply_to_run 和 runtime 所有权核对. [既有牌组测试](<../../engine/tests/decks.rs>) 覆盖全部配置; Anaglyph/Plasma 的回合结算由 flow/scoring 回归覆盖. 未确认本范围存在额外 deck 差异, 不据此保证每副牌组的所有交互都已获得 G 验证.

## 卡牌修饰与身份

- 8 种 Enhancement: Bonus 30, Mult 4, Wild(all suits 但 debuff 时不当 Wild), Glass X2/概率碎裂, Steel 持有 X1.5, Stone 50 且无 rank/suit, Gold 持有现金 3, Lucky 概率 Mult 20/现金 20. Debuff 阻止能力, 底牌保留身份便于解除后恢复.
- 4 种 Seal: Red 重触发, Blue 最后打出牌型 Planet, Gold 打出 3 现金, Purple 弃牌 Tarot. 对应 availability 与 creator 槽位由 flow 覆盖, 计分重触发由 scoring 覆盖.
- 4 种 Edition: Foil +50 Chips, Holo +10 Mult, Polychrome X1.5, Negative +1 相应槽位. Playing cards 版本不参与小丑/消耗牌持有区 capacity. 卖价按基础成本+inflation+edition 后 discount, Gift 额外卖价最后加.
- 复制保留来源 ability/enhancement/seal/edition/perma_bonus/debuff/forced_selection. `played_this_ante` 对应 `ability.played_this_ante`, 同样完整复制来源. 不能因 Rust 把它平铺存成字段就误当对象身份. 保目标值或清空新副本标记的先前判断已撤销, 真实 Lua 回归断言目标和新副本均复制来源标记.
- Death 保留目标的首次排序花色与对象身份. 新复制对象从空 base 初始化, 首次排序花色为 0, 不是 source 历史或当前 suit. Lua 的数字 0 为真值, 后续 set_base 不覆盖它. 把新副本首次花色设为来源当前花色的先前判断已撤销.
- 使用 Negative 持有消耗牌期间, Steamodded 的 `G.TAROT_INTERRUPT` 暂时冻结 card_limit. 产物生成时仍按使用前上限计算, 最后 dissolve 再降容量, 因此结果暂时超容量是合法的. 不能仅为防止超容量提前扣负片位. Shop/Pack 未持有来源则没有释放持有牌的位置, 不能借临时 push 冒充.
- Permanent changes 在 hand/deck/discard 三分区按对象传播, 新复制 ID 唯一, 销毁不能只是挪进弃牌堆. Remove/create contexts 需要触发 Glass/Hologram 等小丑, 由 flow/joker 协作.

## 独立 Lua 复制排序与最终随机选择 oracle

[可复用 Lua oracle](<../../engine/tests/lua/audit_copy.lua>) 从补丁树读取并执行真实 Card:set_base, Card:get_nominal, copy_card, 外部 GUI/构造/解锁依赖通过 stub 隔离. 不打开游戏, 无玩家存档读写. 默认忽略的 Rust 测试显式运行时动态比对实际输出, 同时断言复制 ability.played_this_ante. 设置 `BALATRO_PATCHED_TREE` 可换补丁树目录, 不会安装 LuaJIT.

样例为来源最初 Diamonds_A 改成 Hearts_A, 目标 Clubs_2. source/target/新 duplicate 的 original 名义值分别为 0.01/0.02/0.0. 使用 sort_id 29/17/31 作 unique 替身:

```text
source rank=114.030001999981906 suit=414.010000999981912
target rank=114.030002999989392 suit=414.020000999989406
duplicate rank=114.030000999980672 suit=414.000000999980671
stone rank=-186.009999000018070 suit=-186.009999000018070
```

数值已写 Rust 关键断言. 真实 GUI 的 unique_val 取全局 Node ID, 引擎用 sort_id 保持先后, 不是字节相同 ID 仿真. 排序优先级仍精确到 rank/current_suit/original_suit, 最后才 ID.

随机选择完整链执行真实 `GameObject:__internal_register`, `GameObject:obj_list` 和 `pseudorandom_element`, 并加载真实 Suit/Rank 注册声明:

| 阶段 | Suit 顺序 | 含义 |
| --- | --- | --- |
| 注册 buffer | D,C,H,S | 按注册顺序追加 |
| `obj_list(true)` buffer | S,H,C,D | 逆转注册缓冲区, 仅是中间态 |
| 真实 picker final | S,H,D,C | 按对象 sort_id 再排序, 才是最终随机选择顺序 |

Rank 的最终顺序为 `2,3,4,5,6,7,8,9,T,J,Q,K,A`. 仅执行 obj_list 后就把中间态当最终随机池的结论已废弃. 永久 Lua 回归分别断言并标注 buffer 和 final_pool, Rust 预期根据完整终端结果设置. 不把自我参照或半链验证当成真实行为证明.

## S6 Grim 关键链路复核

S6CFTC2V 的 Grim 独立复核执行实际入口 use, random_destroy, create_playing_card 和全部延迟回调. GUI Card 构造/通知函数以 stub 隔离, 构成 L 层而非新 G 游戏对拍. 在该记录前 91 步没有 summon/spe_card 使用的条件下, 选中 C_7 销毁, 按创建先后生成 S_A Gold 和 C_A Steel, 与 Rust 身份探针一致. Rust 第 94/95 步手牌与保存的真实游戏摘要逐项匹配.

临时 [Grim oracle](<../../.tmp/engine-audit/grim-oracle.lua>) 与 [只读追踪器](<../../.tmp/engine-audit/grim-trace/main.rs>) 保留可复核输入. 其中 sort_id 59/60 为引擎相对身份参照, 不声称复刻 GUI 全局对象 ID. 不根据无摘要步骤编造当时全部真实牌组内容. 临时产物不是永久测试依赖, 复制/排序/完整 picker 的永久 oracle 位于 [Lua 测试](<../../engine/tests/lua/audit_copy.lua>).

## 创建身份的追加核查

9AF1BGS8 诊断回放的第 62 步标准包按顺序生成 `D_Q#blue,H_A,C_A~glass,C_J+h#purple,D_K#gold~glass`, 第 63 步先选第 4 张 D_K, 第 64 步后选第 2 张 C_A. 第 82 步出牌为 S_K/H_K/S_T/H_T, 没有 Glass. 因而补抽时 D_K 与 C_A 的互换不能归因于该步的 Glass 碎裂顺序.

[Card:init](<../../.tmp/engine-audit/modded-tree/card.lua#L5-L25>) 在构造时分配 sort_id. [标准包选择回调](<../../.tmp/engine-audit/modded-tree/functions/button_callbacks.lua#L2265-L2275>) 转移同一对象入牌堆, 只分配 playing_card, 不重新创建 Card 或改变 sort_id. [实际 pseudoshuffle](<../../.tmp/engine-audit/modded-tree/functions/misc_functions.lua#L206-L211>) 洗牌前按 sort_id 排列. 所以 C_A 的出生身份应早于 D_K, 即使玩家逆序选取. 把 sort_id 延迟到取牌时分配会反转它们, 属于创建/转移身份缺失, 不是应硬拟合的洗牌规则. 相对先后已获得 S 证据, GUI 绝对对象 ID 不在此结论之内. 修复及新增回归由生成/flow 协作者统一接入.

同一身份规则还影响正常 API 重排后的消耗牌随机选择. [Ankh](<../../.tmp/engine-audit/modded-tree/card.lua#L1751>), [Wheel/Ectoplasm/Hex](<../../.tmp/engine-audit/modded-tree/card.lua#L1785-L1795>) 和 [Perkeo](<../../.tmp/engine-audit/modded-tree/card.lua#L2788-L2799>) 的实际入口把 Card 对象池交给终端 picker, 后者按 sort_id 排序. 当前 UI 数组位置或只含 usize 的候选索引不能替代出生身份. 消耗牌结构补充 sort_id, 构造 fixture 的默认 0 由中心创建入口补号; 已存在对象转移保留出生身份, Perkeo 复制完整能力但必须获得新身份. Joker 候选索引按对应出生身份排序, 不改变区域的 UI 顺序. [新增关键回归](<../../engine/tests/audit-consumables.rs>) 分组检查 Ankh/Wheel/Ectoplasm/Hex 逆序重排后的选择对象与旧身份保持, 以及不同 key/edition/extra_value 的 Perkeo 源对象重排和副本新身份. [实际 Lua picker](<../../engine/tests/lua/audit_copy.lua>) 另直接断言同一对象池正序/逆序的终端选择相同. 不据相同 key 的单一测试推断重排后随机选择完全一致.

## 回归结果

[审计回归](<../../engine/tests/audit-consumables.rs>) 包含 18 条默认测试和 1 条可选 Lua 测试. 显式 `--include-ignored` 执行结果为 19/19 通过, 0 失败, 0 ignored. 所有 52 张有效执行, 原子拒绝, 来源容量/退款, 持有 Negative 期间冻结容量, Gift 累加/卖价, Perkeo + Blueprint 完整复制能力, 主动销毁 Canio/Glass, 创建 Hologram, 随机销毁按 sort_id 排池, 以及真实复制/排序/最终随机池均已通过. 这些回归覆盖关键规则, 不等于所有组合都得到真实游戏重放验证.

| 验证组 | 结果 | 层级 |
| --- | --- | --- |
| [消耗牌审计](<../../engine/tests/audit-consumables.rs>) 含可选 Lua oracle | 19/19 通过 | R/L |
| [既有牌组测试](<../../engine/tests/decks.rs>) | 8/8 通过 | R |
| [既有优惠券测试](<../../engine/tests/voucher.rs>) | 5/5 通过 | R |
| [既有 Tarot 测试](<../../engine/tests/tarot.rs>) | 35/35 通过 | R |
| [真实函数 Lua 比对](<../../engine/tests/lua/audit_copy.lua>) 单独显式执行 | 1/1 通过, 不安装软件 | L |

既有 Tarot 测试的空手 Hex 成功和黄金牌金额落在结算栏断言已由主会话按实际源码修正. 浮点常量使用最短同 IEEE 表示, 保留与实际 Lua 输出的 1e-12 比对精度, 不以全文件 allow 压制精度提示. 上表记录本子任务已实际完成的验证, 包括创建身份追加核查后的 2 组合法重排回归. 标准包逆序选择与全游戏出生身份的底层接口修复仍需主会话整体验收, 不能把本组 19 项通过当作全部来源和生命周期已获得 G 验证.

## 验证边界

- 全原型 S 分类不代表所有组合都得到 G 验证. 32 张券和 15 副牌组的清单是规则盘点, 不是 32/15 次独立真实游戏 oracle 的保证.
- Blueprint/Brainstorm 对 remove/create/Gift 的全部额外份数, Paint/Palette 在非商店即时补抽等仍需对应协作回归. 本组已直接验证 Blueprint + Perkeo 复制两次并保留卖价能力.
- 卡包 creator 满槽和持有 Negative 期间冻结容量的来源回归已通过, 不把临时 emplace 当真实持有来源.
- 重复手牌目标被当前 validator 明确拒绝, 比原端点的恶意重复高亮参数更严格, 不作为 exact API parity 的证明.
- S/R/L 的通过不替代 G 层真实游戏 oracle. 全游戏及七局完整 raw 对拍由主会话统一核验, 不根据子任务测试推断它们通过.
- 出生身份转移的最终记录验收及完整测试结果见 [总审计报告](<engine-audit.md>); 标准包逆序取牌后的 9AF 第 82 步已实际对拍通过, 不将两项显式未验证的时序摘要算作原始七局全部严格通过.
