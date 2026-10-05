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
| 端点协议 | 缺少或多重购买目标拒绝, 第二张券索引, 重排阶段门, 未知动作不静默成功 | [动作审计测试](<../../engine/tests/audit-actions.rs>) |

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
封蜡权重函数与最终注册池顺序必须分别验证, 不能用手写池的裁判结果证明真实注入顺序.

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

两份完整原始记录已保存为回归基准:

- [Cloud 9 记录](<../../engine/tests/data/rec-20261005-23z315qp.jsonl>): 55 个摘要, 1 个拒绝动作.
- [Swashbuckler 记录](<../../engine/tests/data/rec-20261005-t5tf8s49.jsonl>): 18 个摘要, 1 个拒绝动作.

原始记录还包含两个已确认的非稳定时点:

1. `9AF1BGS8` 第 40 步 cash_out 仍记录普通 j_swashbuckler,
   第 41 步购买没有扣费且持有牌已经是 Polychrome.
   这是版本标签回调在摘要之后结算, 不能据此将正确的版本生成改为普通牌.
2. `A48X6ZYM` 第 31 步 skip 记录现金 4, 下一次 select 已是 11.
   Handy 给本局累计 7 次出牌的奖励, 不应把引擎改成未结算的 4.

严格原始记录校验仍报告这两处差异. 不全局忽略 money 或 edition,
也不把后继动作尚未检查的前缀描述成完整对齐.
`MSH9AC7V` 只有 1 个可比较摘要, 随后成功出牌缺摘要, 不能称为完整对局验证.

## 证明范围

全原型源码枚举不等于穷尽小丑顺序, 重触发数, 所有随机种子及任意第三方模组回调.
挑战局, 教程局和中途读档的完整恢复不在普通开局重建范围.
动画显示的瞬时状态与规则稳定状态也不能混为一谈.

最终整合仍须同时通过完整 Rust 测试, clippy, 实际 Lua 裁判和七份记录的后续动作检查.
已知的多实例钩子, 动态被动能力与 debuff 更新等红项不能仅通过修改断言消除.
