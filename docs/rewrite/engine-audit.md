# Engine 行为审计

## 行为基准

行为基准为仓库附带模组的 Balatro, 不以纯净原版代替 Steamodded 运行时.
核查原型包括 150 张小丑, 52 张消耗牌, 32 张优惠券, 24 种标签,
15 副牌组, 30 种盲注, 8 档赌注及卡牌修饰. 原型逐项源码核查与组合验证是不同的证据层级.

- **源码**: 应用 Lovely 补丁后的调用点, Steamodded 动态覆写及 bbcore 端点规则.
- **Rust 回归**: 对隐藏缺陷敏感的具体场景, 不以文案或分支计数替代行为断言.
- **隔离 Lua 裁判**: 提取并执行真实游戏函数, 只替换 GUI 和外部事件依赖.
- **记录对拍**: 按原局解锁快照重建, 比较每个成功动作的 digest 和失败动作是否被拒绝.
- **完整 GUI 对拍**: 新生成的引擎对局由游戏全过程重放. 这一层需要图形运行权限,
  不能用前三层全部通过来替代.

目标游戏安装的规则源码与仓库基本一致. Steamodded 的 Boss 候选池在安装版中额外按键排序,
因此排序基准以实际安装版及现有记录为准, 不为消除差异修改游戏源码.
补丁树的严格构建仍有 4 处未命中, 虽然完整输出和运行时模块已生成, 也不将它描述成严格构建成功.

## 关键修复类别

| 领域 | 关键差异 | 行为回归 |
| --- | --- | --- |
| 计分调度 | 复制覆盖 individual/held/repetition/other_joker, before 时机, 卡牌和小丑版本顺序, Baseball 逐格响应 | [计分审计测试](<../../engine/tests/audit-scoring.rs>) |
| 持有与重触发 | Mime 和红封重触发完整持有效果, 无首遍效果不额外推进随机数 | [小丑审计测试](<../../engine/tests/audit-jokers.rs>) |
| 即时成长 | Wee 同手成长, Hiker 每次触发永久筹码, Lucky Cat 不因复制重复成长 | [计分入口](<../../engine/src/scoring/engine.rs>) |
| 身份与修饰 | 同牌面克隆不共享首牌身份, 复制牌首次排序花色为 0, ability 历史标记完整复制 | [卡牌审计测试](<../../engine/tests/audit-consumables.rs>) |
| 全局计数与经济 | Cloud 9 整副牌统计, Handy/Garbage 累计量, Investment 在 Boss 结算, Swashbuckler 正确卖价总和 | [流程审计测试](<../../engine/tests/audit-flow.rs>) |
| 商店与池子 | Coupon 只标当前货架, 标签逐份消费, 永恒兼容性, soul 双门, edition 权重和 bans, forced-card 用过标记 | [生成审计测试](<../../engine/tests/audit-generation.rs>) |
| 消耗牌与事务 | 先验证可用性再消费, 买并使用先扣费, 不借临时持有槽, Wraith/Hermit/Fool/Immolate/Sigil/Summon | [消耗牌审计测试](<../../engine/tests/audit-consumables.rs>) |
| 生命周期 | gain/loss, 创建与销毁反馈, Gold/Blue Seal/Mime 回合末, 多实例和复制钩子 | [流程扩展测试](<../../engine/tests/audit-extra-flow.rs>) |
| 端点协议 | 缺少或多重购买目标拒绝, 任意券索引与压紧, 重排阶段门, 未知动作不静默成功 | [动作审计测试](<../../engine/tests/audit-actions.rs>) |
| 多券货架 | Double Tag 与 Voucher Tag 产生的全部券保留, 仅展示一次, 购买实际压紧下标 | [流程审计测试](<../../engine/tests/audit-flow.rs>) |
| 出生与转移身份 | 候选牌生成时分配身份, 购买和选取保留身份, 复制获得新身份 | [身份审计测试](<../../engine/tests/audit-identity.rs>) |
| 对象随机选择 | Ankh/Wheel/Ectoplasm/Hex/Perkeo/Invisible/Madness/Heart/Bell 按对象身份排序, 不按重排后的界面位置抽取 | [消耗牌审计测试](<../../engine/tests/audit-consumables.rs>) |

完整源码覆盖矩阵分别见 [计分](<audit-scoring.md>), [150 张小丑](<audit-jokers.md>),
[流程与盲注](<audit-flow.md>), [生成与随机池](<audit-generation.md>)和[消耗牌与牌组](<audit-consumables.md>).

普通牌型 API 采用 Steamodded 的子结果和顺子路径定义. 正常出牌仍由运行层限制张数.
Steamodded 的等级升级不沿用原版筹码/倍率下界, 但这一公共 API 行为不意味着
The Arm 在正常游戏中能把牌型降到负等级.

## 独立随机数验证

目标运行时裁判直接加载游戏包内的 Lua.framework, 不打开窗口或写玩家存档.
81 组随机种子的 hash/pseudoseed/两颗全局 random 逐位一致;
1944 组版本条件包含 Hone/Glow Up, standard 倍率, no-negative 与 banned editions,
不仅比较返回版本, 也比较随后全局随机状态.

Homebrew LuaJIT 在 ARM64 的 random_seed 使用融合乘加, 游戏内 LuaJIT 不使用这一指令.
两者可对同一浮点种子产生不同序列. 引擎没有为了匹配非目标解释器而修改播种实现.

牌型裁判直接比较 10 个输入的 33 个牌型子组.
复制裁判直接执行 patched set_base/get_nominal/copy_card,
并执行真实 Suit/Rank 注册和 obj_list. Suit 中间列表为 S,H,C,D,
但真实 pseudorandom_element 会按 sort_id 重新排列, 随机选择终端为 S,H,D,C.
只验证注册列表不能证明最终随机选择顺序.
点数池为 2,3,4,5,6,7,8,9,T,J,Q,K,A.
封蜡裁判从完整 patched game.lua 初始化表开始, 执行实际 ownership/register/inject,
get_current_pool 和 poll_seal. 终端池为 Red,Blue,Gold,Purple, 606 张结果及后续随机状态匹配.
两版从错误初始表开始的封蜡裁判结论已撤销, 不作为目标一致性证据.
真实函数加上错误初始状态, 仍不等于目标游戏裁判.

标准包身份也通过后续真实记录发现差异. `9AF1BGS8` 在包生成顺序与选择顺序相反时,
两张新牌被错误交换出生身份, 后续洗牌在第 82 步才暴露位置差异.
候选牌现在在创建时分配身份, 选取只是转移对象; 当时出牌没有 Glass, 不修改碎裂随机顺序来拟合结果.

可复用裁判入口在 [Lua 测试目录](<../../engine/tests/lua/audit_copy.lua>) 与
[牌型裁判](<../../engine/tests/lua/audit_poker.lua>), 需要已有解释器和补丁树,
不自动安装软件. 常规离线构建不依赖这些解释器.

## 离线对拍

```shell
just engine-replay <回放文件.replay.json> [更多回放文件]
just engine-replay --strict <fixture.jsonl>
```

[回放校验模块](<../../engine/src/replay/mod.rs>) 复用正式动作适配器,
仅对真实手动拖动保留与端点阶段门不同的本地操作规则.
比较器不忽略金钱, 强化, 贴纸或不同大小的卡包.
原始 digest 不含逐手评分数值和完整内部状态, 因此逐步一致不能独自证明评分数值完全相同;
计分顺序和数值还需要独立回归与实际源码裁判.
允许的显示差异只有卡包贴图编号以及旧摘要的非扑克牌效果名称.

[fixture 转换脚本](<../../scripts/recording-to-fixture.py>) 保存开局参数,
原局 snapshot.uda, 原始规则动作和 source_index.
不导出 profile, 设置, 解说或代理凭据. 未知规则动作不能在转换时被悄悄删除.

四份完整原始记录已保存为脱敏回归基准:

- [Cloud 9 记录](<../../engine/tests/data/rec-20261005-23z315qp.jsonl>): 55 个摘要, 1 个拒绝动作.
- [Swashbuckler 记录](<../../engine/tests/data/rec-20261005-t5tf8s49.jsonl>): 18 个摘要, 1 个拒绝动作.
- [Grim 与销毁记录](<../../engine/tests/data/rec-20261005-s6cftc2v.jsonl>): 101 个摘要, 3 个拒绝动作.
- [Hermit 与购买记录](<../../engine/tests/data/rec-20261005-vv8pfes1.jsonl>): 118 个摘要, 3 个拒绝动作.

原始记录还包含两个已确认的非稳定时点:

1. `9AF1BGS8` 第 40 步 cash_out 仍记录普通 j_swashbuckler,
   第 41 步购买没有扣费且持有牌已经是 Polychrome.
   这是版本标签回调在摘要之后结算, 不能据此将正确的版本生成改为普通牌.
2. `A48X6ZYM` 第 31 步 skip 记录现金 4, 下一次 select 已是 11.
   Handy 给本局累计 7 次出牌的奖励, 不应把引擎改成未结算的 4.

严格原始记录校验仍报告这两处差异, 退出码为 1. 不全局忽略 money 或 edition.
另外保存逐点标注的诊断副本, 原摘要保留在 unstable_digest, source_index 和原因完整保留:

- [9AF 诊断副本](<../../engine/tests/data/diagnostic-20261005-9af1bgs8.jsonl>): 91 个摘要, 2 个拒绝动作, 仅第 40 步未验证.
- [A48 诊断副本](<../../engine/tests/data/diagnostic-20261005-a48x6zym.jsonl>): 74 个摘要, 4 个拒绝动作, 仅第 31 步未验证.

两份副本的全部后续动作已经通过, 不是只检查报错之前的前缀.
[回放策略回归](<../../engine/tests/audit-replay.rs>)同时断言原摘要恢复后仍在原检查点报错,
防止诊断标注变成全局忽略规则. strict 检查摘要额外字段, 并不把缺少摘要变成已经验证.
`MSH9AC7V` 只有 1 个可比较摘要, 随后成功出牌缺摘要, 不能称为完整对局验证.

## 最终验收

```shell
just engine-audit
```

需要已有 Lua/LuaJIT 和完整 Lovely 补丁树. 该入口不自动安装解释器, 不启动图形游戏,
依次执行包括可选裁判的完整 Rust 测试, 全目标零警告 clippy, 四份原始基准和两份诊断副本.

最终同一冻结实现的结果:

| 验证 | 结果 |
| --- | --- |
| 完整 Rust 测试, 包括可选源码裁判和文档测试 | 461 passed, 0 failed, 0 ignored, exit 0 |
| 全目标 clippy -D warnings | 零警告, exit 0 |
| 六份永久基准严格比较 | 6/6 无其他摘要差异, 457 个摘要, 14 个拒绝动作, 2 个明确未验证时点 |
| 七份未改动的原始记录 | 5/7 无摘要差异, 两处已确认时序差异仍报错, exit 1 |
| 显式模板加载, 导出与本机严格回放 | 入口验证通过, 不作为独立游戏规则裁判 |

六份基准不包含证据稀少的 MSH, 也不把两个未验证时点算入 457 个匹配摘要.
原始七份记录的校验耗时约 0.6 秒, 六份 release 基准约 0.04 秒, 均不含构建时间.

## 证明范围

全原型源码枚举不等于穷尽小丑顺序, 重触发数, 所有随机种子及任意第三方模组回调.
挑战局, 教程局和中途读档的完整恢复不在普通开局重建范围.
动画显示的瞬时状态与规则稳定状态也不能混为一谈.

已确认的普通内容规则差异有对应修复和关键回归, 不以修改断言代替行为修复.
旧 Heart 测试改用真实进场分配身份和实际出牌后的重选路径; 直接塞入多张身份均为 0 的对象
不构成实际游戏可达状态. Marble 采用 setting_blind 之后的真实洗牌路径, 不假定新增牌留在牌堆第 0 位.

任意第三方原型和 Lua 回调, 挑战/教程/中途存档完整恢复, 完整图形宿主的事件与评分对拍均未覆盖.
混合 Tarot_Planet 池的 Lua 哈希表同权顺序存在跨 VM 不稳定性, 没有普通内容调用方;
引擎明确拒绝这一未实现随机池, 而不是继续伪装成 Tarot 池.
这里的完成是五域源码核查, 已确认差异修复与上述验收完成, 不是数学意义上的全组合等价证明.
