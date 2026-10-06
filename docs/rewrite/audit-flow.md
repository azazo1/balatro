# 流程与状态审计

## 基准与范围

基准是当前安装的 Steamodded 和内置 mod 生成的 Lovely 补丁树, 不是只读上游资源的推断. 范围包含对局状态, 盲注, 标签, 经济结算, 所有权事件与拒绝动作原子性. 生产实现集中在 [flow.rs](<../../engine/src/run/flow.rs>), 累计状态在 [state.rs](<../../engine/src/run/state.rs>), 标签结算字段在 [blind.rs](<../../engine/src/run/blind.rs>). [snapshot.rs](<../../engine/src/run/snapshot.rs>) 深拷贝完整状态, 不需要额外手写新增字段.

主要证据入口:

- [补丁版 Card](<../../.tmp/engine-audit/modded-tree/card.lua>): `calculate_joker`, `calculate_seal`, `redeem`, `set_cost`, `copy_card` 的实际事件行为.
- [补丁版 Blind](<../../.tmp/engine-audit/modded-tree/blind.lua>): `set_blind`, `press_play`, `debuff_hand`, `disable`, `drawn_to_hand`.
- [补丁版状态事件](<../../.tmp/engine-audit/modded-tree/functions/state_events.lua>): `evaluate_play`, `discard_cards_from_highlighted`, 手牌回合末效果与抽牌时序.
- [补丁版 Tag](<../../.tmp/engine-audit/modded-tree/tag.lua>): 整局计数, 标签支付, `voucher_add`, `shop_start` 和 Double 复制.
- [补丁版 Steamodded 工具](<../../.tmp/engine-audit/modded-tree/lovely_shim/mods/Steamodded/src/utils.lua>): `poll_seal`, 手牌上限稳定后补牌与对象注册后的随机池处理.
- [buy 端点](<../../mods/bbcore/src/lua/endpoints/buy.lua>): 端点返回的真实拒绝条件和实际货架索引由端点源及动作回归核对, 不把 UI 临时摘要当成结算规则.

补丁树属于本地审计产物. 其源链接在生成该产物后可用, 不是永久上游分发文件.

## 已修正的行为

下表中的 Card, Blind, Tag, 状态事件和工具分别对应上述补丁证据入口. 数值配置以实际 Catalog 为准, 不以消息中转述的常数代替.

| 分支 | 原来的差异 | 当前行为与源证据 |
| --- | --- | --- |
| Handy / Garbage | 按当前回合统计 | Handy 按整局出牌累计, Garbage 按已存活回合未用弃牌累计. Tag 的整局计数. |
| Investment | 跳过时立即支付 | 存活的 Boss 结算后支付一次并移除标签, 独立计入 `RoundEval.tag_bonus`. Tag 的 `eval` 分支. |
| Cloud Nine | 只统计部分区域 | 统计牌堆, 手牌, 弃牌与出牌区全部存活非 Stone 9. Card 的回合末美元奖励. |
| Swashbuckler | 计分后更新, 自带额外 1 | 计分前读取其他对象当前卖价, 不含自己, 同名其他实例仍计入. Card 的对象列表累加. |
| Mr. Bones | 未达标保存仍给盲注奖金 | 保存局面但未达分数要求时盲注奖金为 0, 其他合法结算项保留. Card 的保存条件与状态事件奖金判定. |
| 黄金手牌 | 领取结算时才给钱 | 回合末效果直接到账, Red 和 Mime 重复生效, 利息读取到账后现金. 领取结算不重复支付. 状态事件的手牌结算. |
| Blue Seal | 重复来源与容量不完整 | 按 Red 与每个有效 Mime 来源重复生成对应最后出牌牌型的行星, 遵守容量. Card 的回合末手牌和蜡封事件. |
| Gift Card | `.any()` 合并实例且忽略消耗牌 | 每个有效本体与复制来源分别增加全部持有小丑和消耗牌额外卖价. 在易腐失效前处理. Card 的 end_round. |
| Perkeo | 只处理一张, 按键重建丢失额外卖价 | 按有效来源逐次选择实际对象, 克隆完整状态后改为 Negative. 同键对象仍可区分. Card 的 ending_shop. |
| 所有权事件 | 购入, 包取出和销毁重复或遗漏 gain/loss | 统一经 `add_joker` / `remove_joker`, 同步被动规则, 当前弃牌, 免费重抽与池排除键. Card 的 add/remove_to_deck. |
| Debuff 过渡 | 直接改 bool, 被动没有撤销与恢复 | 真正过渡才调用 loss/gain. 耗尽易腐卡保持失效. Negative 容量与 debuff 无关. Card 和 Steamodded 的削弱重算. |
| Chaos / Drunkard / Merry Andy | 合并多实例, 当前次数变负 | Chaos 按有效本体计数, loss 下限为 0. 弃牌默认完整撤销, 当前剩余下限为 0. Card 被动与 ease_discard. |
| Turtle Bean | 衰减与死亡不释放上限 | 存活衰减和死亡同步当前被动增量. Card 的 end_round 与所有权移除. |
| Astronomer | 成员和削弱变化后价格不更新 | 变化完成后刷新价格, 多有效实例仍使 Planet 与 Celestial 包免费. Card 的 set_cost 与被动过渡. |
| 手牌上限变化 | 上限稳定增加后不补牌 | SelectingHand 最终上限增加后补满并排序. Heart 两次过渡间不瞬态补牌, 减少上限不扔现有牌. 工具的 handle_card_limit. |
| setting_blind | 发牌后执行且合并有效来源 | 设置阶段依来源处理 Riff-raff, Cartomancer, Burglar, Marble, Madness 与 Dagger. 标记已销毁对象避免重复销毁或继续触发. Card 的 setting_blind. |
| Certificate / Marble | 花色和点数各掷一次 | 从整张牌面池一次选择. Certificate 在 first_hand_drawn 直接加入手牌, Marble 在 setting_blind 入牌堆. Card 和状态事件. |
| Certificate 蜡封 | 使用未对齐硬码池 | 共用 `shop::poll_seal`, guaranteed 分支只消耗 `certsl`. 基准必须从补丁版初始蜡封表进入真实注册与权重链. 工具的 poll_seal. |
| Hook | 计分后直接移两张, 不运行弃牌效果 | 计分前选择剩余手牌, 运行紫蜡封和正常小丑钩子, 不消耗弃牌次数, 不触发 Burnt. 候选按 sort_id 排序. Blind 和状态事件的 hook 标记. |
| Mail / Trading / Burnt | `.any()` 合并来源 | 每个本体和兼容复制分别结算. Trading 的销毁亦通知 Glass Joker 与 Canio. Card 的 discard/pre_discard. |
| Water / Needle / Manacle / Heart 停用 | 只清 flag 或卡牌削弱 | 保存并撤销原扣除次数, 恢复手牌上限和临时小丑削弱, 不恢复耗尽易腐卡. Blind 的 disable. |
| 花色和人头牌削弱 | Wild / Stone / Smeared 及改牌状态错误 | 使用现时花色和 Pareidolia 规则. 成员变化和点数, 花色, 强化转换后重算存活牌. 复制类保留实际复制的 debuff. Blind 的 debuff_card. |
| before 序列 | DNA 对拦截手触发, Midas / Vampire 太晚改牌 | 未拦截手执行, DNA 造入手牌, Space 每来源独立掷骰, Midas / Vampire 仅本体改牌并防重复吸取. Card 的 before. |
| 原计分选择 | 去除 Stone 后重判牌型 | before 前保存牌型与 scoring 下标, 改牌后使用新牌面计分但不重判牌型. 状态事件的 poker/scoring 顺序. |
| before 环境计数 | DNA / Vampire 后读取旧存活计数 | 更新全部存活牌, Stone, Steel, 强化数与抽牌堆张数, 包含已出牌. Card 的主计分读取时点. |
| Hiker | 流程重复加永久成长 | 按计分结果原下标永久增量写回后处理碎牌. Card 的 individual 事件. |
| Sixth Sense | 无槽不销毁, Stone 6 也触发 | 首手单张非 Stone 6 仍销毁, 有槽才生成 Spectral. Card 的销毁和容量分支. |
| 新增与销毁扑克牌 | 直接 push/remove 漏上下文 | 新增通知 Hologram, 销毁通知 Glass Joker 和 Canio. DNA, Cryptid, 召唤, 包取牌与塔罗销毁共用入口. Card 的 playing_card_added/remove_playing_cards. |
| Glass | 固定 1/4 | 破碎遵守 `probability_scale / 4`, 主动销毁 Glass 同样通知 Glass Joker. Card 的概率和 remove_playing_cards. |
| To Do List | 命中即换任务 | before 依匹配牌型与有效复制给钱, end_round 换任务, 拦截手不付. Card 的 before/end_round. |
| Rocket / Campfire | Boss 成长缺失或无条件重置 | 易腐失效前, 每个有效本体调用 Boss 回合钩子. Rocket 增加配置美元, Campfire 重置, 不复制成长. Card 的 end_round. |
| Satellite | 重复同一 Planet 被多算 | 独立记录已用 Planet 键集合, Constellation 总使用次数仍保留. Card 的 dollar_bonus. |
| 售出消耗牌 | Campfire 不长, Gift 额外卖价丢失 | 卖价含额外卖价, 有效 Campfire 增长. Card 的 selling_card 和 set_cost. |
| Coupon | 永久全局免费且持有价格为 0 | 仅首批实际优惠货架免费, 持有小丑保存正常价格, 离店清全局状态. Tag 与 Card 的 set_cost. |
| 即买即用 | 未扣购买费 | 先扣费再执行 Hermit / Wraith, 失败克隆不提交. 状态事件使用顺序和端点 can_use. |
| 包和商店创造型消耗牌 | 借临时持有槽绕过 can_use | 原局面满槽时拒绝 Priestess / Emperor / Fool, 保留包选择数与 RNG. Card 的可用条件. |
| Spectral 与 Fool | Spectral 覆盖上一张 Tarot / Planet | 只有实际 Tarot / Planet 使用更新 Fool 记录. Card 的使用历史字段. |
| 随机销毁 | 按 UI 手牌次序抽样 | `random_destroy` 按 sort_id 排序后映射原位置. Immolate 保留独立建牌序号洗牌规则. pseudorandom_element 和 Card 使用效果. |
| Ankh / Invisible / Death | 按键重建, Negative 与身份复制不准确 | 选择对象后克隆, 仅指定的新 Joker 副本剥离 Negative. Death 保留目标身份, 新建副本取新序号. Card 的 copy_card. |
| 出生与转移身份 | 包内与货架物件取得时才重发序号, 玩家选择次序改变未来洗牌 | 创建 Shop / Pack 实体时分配序号, 未被选中的物件也消耗序号. 转移保留预创建身份, 只有合成测试物件的 0 序号使用后备分配. 克隆分配新身份, 不复用源序号. Card:init / copy_card 与实际 Standard 包反序选择证据. |
| 对象随机选择 | 合法 UI 重排改变随机对象对应关系 | Ankh, Wheel, Ectoplasm, Hex, Invisible, Perkeo, Madness, Heart 和 Bell 按源 sort_id 排序候选后映射实际位置. 不重排 UI 本身. Perkeo 保留被选对象数据, 新副本取新身份. pseudorandom_element 的对象排序. |
| Voucher 货架 | 单额外槽覆盖, 购买后 index 0 错位 | 待铺货与实际货架都使用 Vec. Double 后两个标签生成两个对象, 购买指定位置后压紧, 不按同键猜身份. Tag voucher_add 与端点实际索引. |
| Voucher RNG | 使用普通券池键 | 固定 `Voucher_fromtag`, 不拼 ante. Tag 与实际 get_next_voucher_key. |
| D6 | 整店重抽永久免费 | 只将当前商店基础价置 0, 随后仍按次数涨价. 每店只消费一个 Coupon / D6, 重复标签留给后续店. Tag 的 shop_start. |
| Matador | 只认 Eye / Mouth 且合并来源 | 普通手在 main 处理实际 Boss 触发标记, 保持复制和现金读取顺序. 整手拦截时按每个有效来源单独处理. Card 的 debuffed_hand/joker_main. |
| Loyalty | 拦截手循环不推进 | 被拦截的出牌仍推进持有期间出牌次数, 不产生分数效果. Card 的出牌计数时点. |
| Throwback | 买入后首手乘倍率未更新 | main 前用已有 skips 和配置增量刷新本体. Card 的实时更新. |

## 验证状态

本域已收集的终验退出码均为 0, 最后的多券专项编译没有 warning:

- [audit-flow.rs](<../../engine/tests/audit-flow.rs>): 20 个测试通过. 包含 Throwback 首手, D6 递增与重复标签保留, Double + Voucher 三券链, 压紧索引与拒绝动作原子性, Standard 包逆出生顺序选取保身份, 货架 Joker 移动与 Ankh 新生身份分离, Heart / Madness / Bell 在合法重排后选择同一出生对象.
- [audit-extra-flow.rs](<../../engine/tests/audit-extra-flow.rs>): 12 个 before, Hook, 多来源创建, 盲注停用和动态削弱测试通过.
- [audit-passives.rs](<../../engine/tests/audit-passives.rs>): 8 个被动过渡与稳定补牌测试通过.
- [audit-consumables.rs](<../../engine/tests/audit-consumables.rs>): 18 个测试通过, 包含合法重排后的 Joker 随机对象选择和 Perkeo 元数据, 出生身份与克隆新身份. 1 个真实 LuaJIT oracle 在默认环境未配置时忽略. 有效上下文下执行全部 52 张消耗牌的测试通过.

最终同一冻结实现的专项命令为 `cargo test --manifest-path engine/Cargo.toml --offline --test audit-flow --test audit-consumables --test audit-extra-flow --test audit-passives`, 共 58 passed, 1 ignored, 退出码 0. 编译没有 warning. 不将本域专项结果包装为一次全仓库验收.

主审计随后在同一冻结实现完成全 targets 验收: 461 passed, 0 failed, 0 ignored, 包含显式启用的外部 Lua oracle; `clippy --all-targets -- -D warnings` 退出码 0. 永久 6 个基准全部通过. 原始 7 份录像的严格比较仍为 5/7, 另两份各有一个确认的事件时序摘要差异, 不能把诊断通过写成原始严格通过. 两份仅标注单个未稳定摘要的诊断基准尾部也全部通过, 包内出生身份导致的后续发牌差异不再出现. 完整计数和证据范围见 [统一验收报告](<engine-audit.md>).

真实注册, `obj_list`, `pseudorandom_element` 和权重选择是分开的阶段. 中间列表不等于终端随机池. 花色终端池为 S, H, D, C; Ouija 终端点数池为 2 到 9, T, J, Q, K, A. 蜡封以补丁版游戏初始表为起点, 不能拿原始游戏表验证后声称吻合补丁版. 对象池的完整 Lua 链由生成域另行验证.

## 范围边界

- 这是对已确认差异的修正, 不是全部 30 盲注与全部小丑, 标签, 消耗牌组合的穷尽证明. 全仓库旧测试, 计分专项, native 验证和真实回放由主审计统一验收, 这里不替其他域宣称通过.
- Matador 主计分和整手拦截已分别接线. 跨小丑现金读取顺序交由计分域回归核验, 不用流程统一后置发钱替代真实 main 顺序.
- UI 录像可能在相邻摘要间才完成标签到账或版本变化. Handy 与 Polychrome 标签的已见迟延摘要不能作为更改实际结算规则的理由. 未验证摘要仍应明确标注, 不全局忽略字段.
- 多券已使用真实对象列表. Double + Voucher 不再受单槽限制. 补丁版标签券赎回关闭普通券未来 spawn 标记, 不移除当前货架其他对象.
- 第三方新增牌面, 自定义对象权重和外部自定义 debuff 并非此处完整实现的通用插件协议. 基准内的默认对象池与已确认钩子已接线.
- first_hand_drawn 和 drawn_to_hand 是不同事件. Heart 只在首次盲注设置或 press_play 后 prepped 时重新选择, 普通弃牌不因此重选. 满牌低层补牌调用不应被测试误当成完整游戏状态转移.
