# 计分审计

## 基准与证据

计分基准为完整 Lovely 补丁树和 Steamodded 运行时代码, 不以原版函数替代被覆写的入口.
[patched 计分入口](<../../.tmp/engine-audit/modded-tree/functions/state_events.lua#L646-L777>)规定阶段顺序,
[SMODS.trigger_effects](<../../mods/Steamodded/src/utils.lua#L1499-L1517>)规定效果应用顺序,
[SMODS.blueprint_effect](<../../mods/Steamodded/src/utils.lua#L2385-L2410>)规定复制兼容性和循环限制.

源码核查, Rust 回归, 真实 Lua 函数隔离执行和完整图形游戏对拍分别提供不同强度的证据.
这里的 Lua 裁判没有执行完整 GUI 和事件宿主, 不能据此声称所有组合都已完全对齐.

## 关键行为

| 项目 | 差异 | 对齐行为 |
| --- | --- | --- |
| Brainstorm/Blueprint | individual/held/repetition/other_joker 漏复制 | 逐格递归解析目标, 检查自身和目标 debuff/blueprint_compat, 循环无效果 |
| 复制成长 | 重复增长复制目标 | Lucky Cat/Wee/before 只增长本体, 复制读取结果; Hiker 改牌, 允许复制增加牌筹码 |
| before | 位于逐卡和 held 之后 | 位于逐卡评分之前, Space/DNA/Midas/Vampire 的副作用由运行层按同阶段执行 |
| 牌版本 | 逐卡小丑之后应用 | 自身 chips/mult/xmult/dollars/edition 先处理, 再 individual |
| 小丑版本 | 全部在主效果之后 | Foil/Holo 在同格主效果之前, Polychrome 在本格主效果和响应之后, 不复制目标版本 |
| Baseball | 预先整体乘倍率 | 每个被观察小丑主效果之后逐来源触发 |
| held 重触发 | Red seal 无效, Mime 只重复 Steel | 重触发完整 held 效果; 首遍没有效果时不额外推进随机序列 |
| Stone | 不自动加入评分, 高牌使用普通 nominal | 全部石头加入评分名单, nominal 按实际卡牌语义计算 |
| Hiker | 结束后统一增长 | 每次 individual 当场增长, 同手下一次重触发立即使用新增永久筹码 |
| Wee | 下一手才读成长 | 当前手 individual 成长, 当前主效果读新值, 复制不额外成长 |
| 相同牌实例 | 按牌面值认定首牌 | Photograph/Hanging Chad 按当前 slice 的对象引用身份判断 |
| Observatory/Plasma | 顺序反转, 1.5 提前取整 | Observatory 先乘, Plasma 最后平衡和取整 |
| 牌型子组 | 原版恰好 N 张和包含回填 | SMODS 不少于 N 张分组, Two Pair/Full House 合并符合定义的子组 |
| Straight/Flush | 原版扫描, 最多 5 张 | 使用 SMODS 点数图和完整候选, Straight Flush 合并全部候选 |
| 等级下界 | 使用原版筹码和倍率下界 | SMODS 直接加增量, 0 级 High Card 为 -5 chips/0 mult |
| Matador/Bull | 单一现金奖励, 槽位现金快照过旧 | boss_triggered 驱动每个主效果来源, Bull 读取本格之前已经到账的收入 |

实现见 [计分主流程](<../../engine/src/scoring/engine.rs>),
[牌型判定](<../../engine/src/scoring/poker_hand.rs>)和[等级表](<../../engine/src/scoring/hand_levels.rs>).

## 生命周期矩阵

| 阶段 | 主要源码依据 | 关键裁判与回归 |
| --- | --- | --- |
| 牌型选定 | [牌型定义](<../../mods/Steamodded/src/game_object.lua#L2983-L3045>), [顺子覆写](<../../mods/Steamodded/src/overrides.lua#L624-L688>) | 10 个输入的 33 个子组, 包括 Four Fingers/Shortcut/A/三对子/6 张顺子与同花/Smeared |
| before | [基础值落点](<../../.tmp/engine-audit/modded-tree/functions/state_events.lua#L646-L670>) | 提前选定牌型和石头名单, 之后读取新的增强和全牌组统计 |
| 牌自身效果 | [eval_card](<../../.tmp/engine-audit/modded-tree/functions/common_events.lua#L631-L755>) | 强化, 蜡封, 版本, 削弱, 自身金额 |
| individual | [逐卡小丑](<../../.tmp/engine-audit/modded-tree/card.lua#L3449-L3494>) | Even Steven 复制链, Lucky Cat, Wee, Hiker/Red seal, 同牌面克隆 |
| repetition | [calculate_repetitions](<../../mods/Steamodded/src/utils.lua#L1641-L1735>) | Red seal 与复制 Hack 重复整段, 失效对象不触发 |
| held | [score_card](<../../mods/Steamodded/src/utils.lua#L2216-L2257>) | Steel/Baron/Red seal/Mime/Reserved Parking, 不多推进无效重掷 |
| main/other_joker | [逐格效果组](<../../.tmp/engine-audit/modded-tree/functions/state_events.lua#L679-L746>) | Holo/Card Sharp/Baseball, 复制不复制版本, Matador 与 Bull 槽位顺序 |
| 消耗牌/牌背 | [最终结算](<../../.tmp/engine-audit/modded-tree/functions/state_events.lua#L740-L777>), [Plasma](<../../.tmp/engine-audit/modded-tree/back.lua#L157-L202>) | Observatory 1.5 不提前取整, Observatory 位于 Plasma 前 |
| after | [after 调度](<../../.tmp/engine-audit/modded-tree/functions/state_events.lua>) | Ice Cream/Seltzer 在本手评分之后消耗 |

## 跨阶段接口

- scoring_selection 返回 before 前的 EvaluatedHand 和输入下标形式的评分名单.
- score_play_with_creation_pre_evaluated 在实例变化之后沿用名单, 防止 Vampire 剥除 Stone/Wild 后重新判型.
- ScoreResult.perma_bonuses 按打出下标返回 Hiker 永久增量, 运行层在移牌和毁牌之前回写.
- EvalEnv 的 deck_steels/deck_stones/deck_enhanced/deck_total 由运行层在 before 副作用后刷新.
- boss_triggered 只控制应触发的普通评分阶段. 被盲注完全阻断的出牌由运行层处理 debuffed_hand 的独立奖励路径.
- 每个 main 来源执行前刷新当前现金, 避免前槽 Matador, Gold seal 或 Lucky 收入对 Bull 不可见.

## 验证

[计分回归](<../../engine/tests/audit-scoring.rs>)包含 22 个常规测试,
[实际 Lua 裁判](<../../engine/tests/lua/audit_poker.lua>)直接提取真实函数, 比较 10 个输入的 33 个牌型子组.
Lua 和 LuaJIT 都执行过该裁判. Rust 可选裁判需要已有解释器和 Lovely 补丁树,
不自动安装软件, 不把 Rust 算法翻译成 Lua 来自证.

[运行层补充回归](<../../engine/tests/audit-extra-flow.rs>)包含 12 个关键交互:
Hook 移牌, 全 front 池单次抽取, 多实例和复制生成, Certificate,
Water/Needle/Manacle 停用恢复, Heart 被动能力恢复及过期 Perishable,
Wild/Stone/Smeared/Pareidolia/rank 重判削弱, DNA/Erosion 与 Vampire/Stone/Driver License 的同手统计.

Certificate 的最终 Seal 预期来自完整 patched 初始化链 Red/Blue/Gold/Purple,
而不是原版初始化顺序或单独的注册列表. 最终整合状态见 [审计总览](<engine-audit.md>).

## 限制

评分接口可处理超过 5 张牌是 SMODS 行为; 普通出牌仍由运行层限制张数.
不声称正常 The Arm 能把等级降为负数. 自定义 rank/suit/scoring parameter 和任意第三方 Lua 回调不在普通内容引擎范围.
关键随机组合有确定种子或强制概率断言, 但未穷尽所有随机序列和小丑排列.
记录 digest 不含完整评分数值, 所以记录一致与评分数值一致不能混为同一结论.
