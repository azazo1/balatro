# 生成与随机数审计

范围: LuaJIT PRNG, keyed 递推, 候选池, 商店生成与定价, 补充包, 标签与 sticker 兼容性. 行为基准是带完整 Lovely 补丁和 Steamodded 的目标游戏, 不是未打补丁的上游. 本报告记录生成域证据与边界, 全局验收及今日录像逐局结论由中央报告汇总.

## 域矩阵与证据层次

| 子域 | 基准 | 验证方式 | 结论边界 |
| --- | --- | --- | --- |
| PRNG 与 keyed 递推 | 目标游戏的 Lua.framework, 游戏 pseudohash/pseudoseed/pseudorandom | 81 个新种子, hash, pseudoseed, 播种后前两颗 global random 逐位比较; 现有 parity 测试 | 验证这些种子和入口, 不等于全部 key 与所有浮点输入均已穷举. |
| Edition | 实际 Steamodded poll_edition 与 Edition.get_weight | 1944 条件, 受控候选池, 比较选择与之后一颗 global random | 验证原版四个 in_shop 版本的概率函数, 不覆盖任意 mod 的自定义权重与注册流程. |
| Seal | 完整 Lovely 补丁初始化, 接管, 注册, 注入, 补丁后 get_current_pool, 实际 poll_seal | 101 个种子, 普通/Red banned 各 3 张, 共 606 张 | 只认可完整补丁链产生的 Red/Blue/Gold/Purple 池; 两版旧裁判结论撤销. |
| Pool 与标签前置 | 补丁后 get_current_pool, Catalog 与原型字段 | banned, used, Showman, 空池, min_ante, discovered, enhancement gate 定向回归 | 主要是源码审计加定向回归, 不是所有原型状态组合的外部对拍. |
| Joker 创建与 sticker | 补丁 create_card, Card:set_eternal/set_perishable | 80 个种子共 1920 张, incompat 与互斥检查 | 不声称覆盖所有原型的抽取频率. |
| 商店, 标签与价格 | Tag, Card:set_cost, 商店生成和重算 | 免费标记, 单次消费, 正常持有价, Astronomer, 相关既有测试 | 可视异步事件和所有裸 random 消费时机不在纯函数 oracle 范围. |
| 标准包与 Hallucination | SMODS Booster.create_card, 补丁 Card.calculate_joker | 创建顺序, global PRNG, 每有效实例/Blueprint 的触发与容量 buffer | 不覆盖任意第三方 booster 与事件调度扩展. |
| Tarot_Planet | 原始原型合并表与实际 Lua 排序 | 外部成员/重复 order 核验, 三个目标 Lua VM 的次序观察 | 同 order 次序不稳定, 创建 API 明确报 NotImplemented, 不提供错误的半合并结果. |

## 已确认并修复的 18 类差异

| 问题 | 源码证据与修复 | 回归 |
| --- | --- | --- |
| 永恒与易腐忽略原型兼容性 | [原版 Card](<../../game/card.lua>) 与 [补丁后 Card](<../../.tmp/engine-audit/modded-tree/card.lua>) 的 setter 要求 compat. [Catalog](<../../engine/src/data/catalog.rs>) 解析 compat, [商店与小丑包](<../../engine/src/run/shop.rs>) 保留原骰, 不兼容时不贴 sticker. | 80 个种子, 每种 20 张商店小丑与 4 张包小丑, 检查 1920 张. 修前 j_gros_michel 错误永恒, 今日两局的首个 sticker 分歧属于同类. |
| 稀有度池漏 banned, debuffed Showman 放行, 空池省略默认抽取 | [补丁 get_current_pool](<../../.tmp/engine-audit/modded-tree/functions/common_events.lua>) 保留 UNAVAILABLE 并检查 banned. [SMODS.find_card](<../../mods/Steamodded/src/utils.lua>) 默认排除 debuffed. 商店与 Creation 的 Showman 判据统一, 小丑空池改为 j_joker 后仍抽取. | 30 个种子只允许 j_joker, 全部 common 已用且 Showman debuffed. 修前抽出被禁用的 j_smiley. |
| Tag pool 不检查 min_ante 与 discovered 前置 | 补丁 get_current_pool 的 Tag 分支检查 min_ante 和 required center.discovered, 不用 Joker 解锁判据. Catalog 保存 string requires 与 min_ante. | 底注 1/2, 无发现进度/已发现 Blueprint, 检查池长与 gated 标签入池. |
| TODO List 删除旧牌型后才抽取 | [原版 Card:set_ability](<../../game/card.lua>) 在完整可见池上反复抽到非旧牌型. 改为原池 rejection sampling, 每次拒绝仍推进 key. | 30 个种子同时检查牌型和下一次 to_do 递推. 修前 Pair, 源码规则期望 Straight. |
| 版本券 edition_rate 未参与抽取 | [实际 poll_edition](<../../mods/Steamodded/src/overrides.lua>) 与 [Edition.get_weight](<../../mods/Steamodded/src/game_object.lua>) 修改累计权重, 分母保留未修改权重及 96% 基础牌. 实现原始 3/3/14/20 权重, 各 get_weight, banned 排除和 no_neg 累计保留. 显式 aura/wheel 选项不按普通池 banned 筛选. | 500 个 portable 种子检查倍率和一次 RNG. 外部 oracle 1944 条件检查券倍率 1/2/4, standard 倍率 1/2, no_neg 和 foil banned, 连下一颗 global random 逐位比较. |
| Soul gate 调用遗漏和提前返回 | [补丁 create_card](<../../.tmp/engine-audit/modded-tree/functions/common_events.lua>) 先消耗 soul_smods, Soul/Black Hole 为两道独立 if, Black Hole 可覆盖 Soul. c_soul banned 跳过整个门, 已有 forced_key 同样跳过. | Soul 命中仍推进第二次 Spectral key, c_soul banned 不推进 Planet soul key, 四类 soulable 仍推进 soul_smods. |
| Forced 卡和 Telescope 不登记 used | Card:set_ability 统一登记 used_jokers. Forced 短路与 Telescope 同样登记, 不添加池骰. | Forced c_pluto 保持 global PRNG 不变但登记 used. |
| Creation 强化门只看 deck, 强化键缺 m_ 前缀 | 游戏遍历 G.playing_cards, 包含 hand/deck/discard. 修正三个区域与原型键前缀. | Steel 在 hand, Stone 在 discard, Creation 包含 m_steel/m_stone. |
| 标签生成省略 sticker/edition 骰, 非免费, 一次删除全部同类标签 | [原版 Tag](<../../game/tag.lua>) 强制原型后仍正常 create_card, couponed 限定当前卡. 标签只跳过 rarity 骰, 复用剩余 Joker 创建路径, 每张至多消费一个生成标签和一个版本标签. 普通小丑也应用版本标签, 已有版本时不消费. | 双 Uncommon 只消费一个, etperpoll 推进, 普通小丑首 Foil 标签免费而 Negative 标签保留. |
| Coupon 扩散到优惠券与之后 reroll | [补丁 Card:set_cost](<../../.tmp/engine-audit/modded-tree/card.lua>) 只在 shop_jokers/shop_booster 且当前卡 couponed 时覆盖购买价. ShopCard.couponed 保存标记, restock 仅标当时 Joker/Booster, 券不标, refresh_costs 不按全局 shop_free 覆盖. | 持有 Joker 正常重新标价, 不是永久免费卖价. 采购流程与离开商店状态由 flow/中央集成测试验证. |
| 标准包先强化/牌面后 edition/seal | [SMODS 标准包](<../../mods/Steamodded/src/game_object.lua>) 先 edition, seal, stdset, 再实际 create_card 的 soul_smods/Enhanced/front. 修正 keyed 和最终 global PRNG 顺序. | 三张 standard 后 global PRNG 完整状态符合源码 call sequence. |
| 蜡封池漏完整 Lovely 初始化补丁与 banned | [Lovely seal 补丁](<../../mods/Steamodded/lovely/seal.toml#L157-L170>) 将 Seal.order 改为 Red1/Blue2/Gold3/Purple4. [补丁后初始表](<../../.tmp/engine-audit/modded-tree/game.lua#L222-L227>) 接管后原位替换. Catalog 对原版快照叠加此 order, shared poll_seal 供 standard 和 guaranteed Cert 共用. | 完整补丁链 606 张全部一致. 修前 SEAL2 第 2 张 Lua Red, engine Gold, 修后通过. 旧硬编码注册顺序与旧未打补丁初始化链的结果均撤销, 不作为目标匹配证据. |
| Enhanced 池漏 banned | 补丁 get_current_pool 同样对 Enhanced 应用 banned, 保留位置, 空池仍使用默认原型抽取. 商店与标准包共用辅助. | 50 个种子只允许 m_bonus, 检查包内和 Illusion 商店强化. |
| Hallucination 合并为一次并使用 debuffed 实例 odds | [补丁 Card.calculate_joker](<../../.tmp/engine-audit/modded-tree/card.lua>) 对每个有效实例与兼容 Blueprint 触发, 先 buffer 预留后事件造 Tarot, 无 soulable. 使用统一 effect source helper, 所有 halu 骰之后才创建. | 20 个种子, debuffed odds100, 两张有效 Hallucination 和 Blueprint, 检查容量及 halu key 调用数. |
| 全部 Booster banned 时 panic | [SMODS.get_pack](<../../mods/Steamodded/src/overrides.lua>) 无命中时回退 p_buffoon_normal_1, engine 同样回退. | 全部 Booster banned 不崩溃并返回相同兜底. |
| Voucher Tag 使用普通底注池键 | 补丁 get_next_voucher_key 的 from_tag 分支固定使用 Voucher_fromtag, 不拼 ante. [候选池 API](<../../engine/src/run/pool.rs>) 提供 next_voucher_key_from_tag, flow 标签入口接入. | 两底注各 30 个种子, 比较标签 key 与之后递推. 修前 VTAG0 为 v_crystal_ball, 正确为 v_hieroglyph. |
| pseudoseed('seed') 被当成 keyed 递推 | [游戏 misc_functions](<../../game/functions/misc_functions.lua>) 的 seed 特例直接消耗 global math.random. | 与 clone 的 global stream 比较两次状态. |
| Astronomer 仅采购时覆盖, 价签仍收费 | 补丁 Card:set_cost_value 令 Planet/Celestial Booster 购买价为 0. 实际生成时标价, 不只在 buy 时覆盖. | 40 个种子, 强制 Planet 商店卡与实际 Celestial 包价签为 0. |

### 多张 Voucher Tag 的结构修复

[商店](<../../engine/src/run/shop.rs>) 使用统一 `Shop.vouchers: Vec<ShopCard>`, 不再用两个 Option 表示主券和单张标签券. 主券仍在售时位于首位, 之后保留全部标签券的事件顺序. `restock` 用 `std::mem::take` 消费 `extra_voucher_keys`, 下一商店不重生已经展示的标签券. 折扣重算遍历整个向量.

[补丁 Tag](<../../.tmp/engine-audit/modded-tree/tag.lua#L323-L337>) 每个 callback 先抽 key, 创建 Card, 再 emplace. 后续标签应看见已生成的券. 候选池同时排除 pending 中已生成券和当前实际货架券. flow 的 `buy_voucher_index(index)` 按真实索引删除并压紧, 不用同 key 对象值相等来定位. 补丁后的 redeem 对任意券清除主券再生成标记, 因此没有按标签来源错误区分这一状态. 多券采购, adapter 索引和 snapshot 的完整验收由中央集成测试汇总.

### 出生身份与移动身份

[补丁 Card:init](<../../.tmp/engine-audit/modded-tree/card.lua#L23-L25>) 在实体创建时递增 G.sort_id, 不等到玩家选择或买下才分配. 原模型在取走包牌时才发号, 选择顺序与出生顺序相反时会改变之后 pseudoshuffle 的预排序. 今日 9AF1BGS8 的后续诊断发现同包两张 Glass 先取第 4 张再取第 2 张, engine 的出生身份倒置, 后一轮两张牌的发牌位置交换. 这是来源身份错误, 不应倒转标准包生成或随机抽取顺序来拟合.

[ShopCard 和 PackCard](<../../engine/src/run/shop.rs>) 保存 `sort_id: u32`. 商店 Joker, 标签 Joker, 扑克牌, 消耗牌, Booster, Voucher 和所有包内实体, 都在实际生成时调用统一 next_sort_id. 未选包牌也消费出生号, 下一张不能重用它. Hallucination 实际创建的消耗牌同样分配. 仅返回原型 key 的纯选择 API 不发实体号, 避免调用方真正构建对象时重复分配.

移动到持有区域保留源身份, 新复制对象获得新号. `plain` 默认 0 只用于外部未赋号 fixture, 转移的 0 回退由 flow 处理, 不是生产实体出生规则. 新回归先证实连续生成两个商店 Joker 均为 0 的失败, 修后检查所有五类包的全部实体出生顺序及货架所有对象的连续唯一号. 生成域 25/25 含全部 RNG oracle 通过, 因此身份修复没有改变已验证的抽取顺序.

最终冻结实现的身份集成验收见 [中央审计报告](<engine-audit.md#L65-L67>) 与 [身份审计测试](<../../engine/tests/audit-identity.rs>). [9AF 诊断基准](<../../engine/tests/data/diagnostic-20261005-9af1bgs8.jsonl>) 保留第 40 步原摘要及未验证标注, 其余 91 个摘要和 2 个拒绝动作完整到最后通过, 包括第 62 步 Standard 蜡封和第 82 步身份相关发牌. 这不是仅验证错误前缀或预言后续应通过. 结论不扩展为原始七局全部严格通过: 两个 recorder 非稳定时点仍在原始严格检查中报错, MSH 的摘要不足也不算完整对局验证.

## 实际 Lua 运行时和 oracle

[生成域回归](<../../engine/tests/audit-generation.rs>) 包含 21 个 portable 回归与 4 个显式外部 oracle. 外部 oracle 执行源码函数而不是复制 Rust 公式, 但各自环境的范围不同:

- Edition 使用实际 poll_edition 和 get_weight, 四个已审计的原版候选置于受控池. 这是概率函数 oracle, 不是全注册链 oracle.
- Seal 在运行时读取 [完整补丁 game](<../../.tmp/engine-audit/modded-tree/game.lua>) 和 [补丁后 common_events](<../../.tmp/engine-audit/modded-tree/functions/common_events.lua>), 不回退到原版初始化. 执行初始表, 原 order 排序, GameObject 接管/注册, Seal.inject, insert_pool, add_to_pool, find_card/showman, 最后 get_current_pool/poll_seal. Atlas, sprite, UI 与无关发现状态保存使用空操作 stub; 原版蜡封无自定义 in_pool, 场景中无 Showman 和第三方对象.
- Keyed RNG 使用游戏原始 pseudohash/pseudoseed/pseudorandom, 分层比较 hash, pseudoseed 与播种后的 random.
- Tarot_Planet 验证合并成员与重复 order, 不将一次排序的 tie 次序宣称为确定的目标池.

默认通过 Python ctypes 加载 [目标游戏 Lua.framework](<../../dist/macos/Balatro-Modded.app/Contents/Frameworks/Lua.framework/Versions/A/Lua>) C API. 不启动 GUI 或游戏进程, 不修改游戏数据. `BALATRO_AUDIT_LUA` 可指定等价运行时. 框架不存在时工具回退到外部 luajit, 但必须先确认它与目标游戏的浮点运算语义相同, 否则其失败或通过都不能直接当目标证据.

### Brew FMA 不是目标随机数基准

本机 ARM64 brew LuaJIT 的原生 random_seed 在 `d*pi+e` 使用 fmadd, 目标游戏框架不使用融合乘加. ORACLE12 是可复现反例:

- 两边 hashed_seed 都为 `.96868748508097724`.
- 两边 pseudoseed 都为 `.81373344825488858`.
- 播种后第一颗 brew random 为 `.31426645169713807`.
- engine 与目标游戏第一颗 random 都为 `.337581881388475`.

二进制反汇编在播种的 `0x11090601` 状态阈值旁确认 brew fmadd, 目标框架 fmadd 数为 0. 未为 brew 这一非目标运行时改变 engine 的播种算法. PRNG 播种保持非融合运算, RNG 层功能修复是 seed 特殊 key.

### 唯一有效的蜡封目标顺序

完整目标链产生 `Red, Blue, Gold, Purple`. SMODS.poll_seal 按反向累计区间选择, 无 banned 时:

| seal_type | 蜡封 |
| --- | --- |
| `>.75` | Red |
| `>.5` 且 `<=.75` | Blue |
| `>.25` 且 `<=.5` | Gold |
| `<=.25` 的有效非零值 | Purple |

首次裁判手写注册 buffer 的 Purple/Gold/Blue/Red 顺序, 没证明最终池. 第二版补了接管/注入却用了原版 Gold/Red/Blue/Purple 初始化, 漏 Lovely 对初始表的覆盖. 这两版都不是完整目标裁判, 其结论明确撤销, 不贴目标匹配标签. 只有读取完整补丁初始表, 执行最后候选池与选择器的 606 张结果有效. 这避免用录像拟合阈值, 也避免把半条源码链当成实机证据.

## 验证结果

多券向量与出生身份接口整合后的生成域结果:

- `audit-generation --include-ignored`: 25/25 通过, 21 portable + 4 external.
- 1944 个 Edition 条件: 选择与之后一颗 global random 全部逐位一致.
- 606 张 Seal: 完整 Lovely 初始化/接管/注册/注入/补丁后池/选择链一致.
- 81 个 RNG 种子: hash, pseudoseed 和播种后前两颗 global random 全部逐位一致.
- `clippy --test audit-generation`: 退出码 0, 零警告.

较早的相关既有测试结果为 LuaJIT parity 7/7, shop_pool 2/2, shop_shelf 11/11, voucher 5/5. 最终同一冻结实现的完整验收见 [中央报告](<engine-audit.md#L117-L137>): Rust 461 passed, 0 failed, 0 ignored; 全目标 clippy -D warnings 零警告; 六份永久基准比较 457 个摘要和 14 个拒绝动作通过, 另保留 2 个明确未验证时点. 多券向量, 出生/转移身份和离开商店 Coupon 状态已纳入最终集成测试. 原始七份记录仍有两处已确认时序差异, 不将诊断标注当作原始严格检查通过.

多数 portable 回归通过保留的修前 engine rlib 先执行, 确认断言失败后修复. Astronomer 在完整套件先出现价签 3 而期望 0. 最终 Seal 裁判在修复前明确出现 Lua Red 与 engine Gold. 并行编辑产生的瞬时签名编译缺口不算有效规则红回归证据.

## 未支持入口和残余边界

### Tarot_Planet 明确未支持

当前创建 API 曾将 Tarot_Planet 静默当 Tarot, 丢失 Planet. 原型合并池有跨类别同 order, 实际目标 Lua.framework 的三个 VM 初始化产生不同次序, 包括 Fool/Mercury 和 Pluto/Justice 的交换. 原版 pairs 加非稳定 table.sort 的 tie 次序不能由固定 Catalog 稳定排序保证.

现在没有现役 engine caller 使用这个 kind. 未强制原型的创建入口明确 panic, 信息为 `NotImplemented: Tarot_Planet`, 不再返回看似正常却遗漏 Planet 的结果. 已有有效 forced_key 仍正常短路. 这不是完整组合池支持, 也不是具有 Result 的结构化错误接口. 真正支持需要快照提供当前进程的实际池顺序, 或目标游戏制定确定的 tie 规则. 没有为此修改游戏排序. Portable 回归验证明确拒绝, 外部 oracle 验证成员全集, order 单调性与确有重复 order.

### 其余边界

- 首个 Buffoon _1/_2 与 voucher 预抽时机仍有裸 global random 债务. [restock 的说明](<../../engine/src/run/shop.rs>) 保留. 没有为一份录像拟合 materialize/视觉事件的随机消费数. Keyed RNG 正确不代表所有裸 math.random 的时机都正确.
- 版本标签通过异步事件生效, raw digest 可能在 callback 前记录. 今日 9AF1BGS8 的 cash_out 摘要无 Polychrome, 紧接 buy 后持有卡带 Polychrome 且免费, 属已证实的 recorder 时间边界. 不为较早摘要关闭正确标签逻辑, 严格 raw checker 的结论由中央报告保留.
- 任意第三方 mod 的 custom in_pool/get_weight, 自定义 soulables/rarities/Seal, object_weights 可选路径, challenge 的 all_eternal/booster_ante_scaling 等, 不是当前原版静态 Catalog 能完整表达的范围. 当前 mods 未发现 object_weights=true 启用点, 不把可扩展 SMODS API 与原版数据条件通过混为一谈.
- 安装版与仓库 Steamodded weights.create_blind_pool 存在额外 table.sort 的基准差异, 属 Boss 选择域, 已交相应域处理, 此处不越界修改.
- 此域没有开启 GUI 回放. 外部裁判是目标 Lua 框架中的源码纯函数与初始化链执行, 不验证可视事件调度, 不宣称所有 key 或所有卡牌组合均已对拍.
