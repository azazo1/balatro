# Balatro 1.0.1n Agent 手册

这是面向自动玩游戏 agent 的规则知识库, 不是自动化框架. 适用版本由 [游戏版本文件](<../../game/version.jkr>) 的 `1.0.1n-FULL` 确认. 所有概率, 数值和事件顺序以本仓库源码为准; wiki 用于交叉核对, 版本和已知差异见 [来源说明](<sources.md>).

## 阅读顺序

不要一次加载全部卡牌目录. 先建立基本规则, 再根据当前状态和内部 ID 按需检索.

1. [一局流程与状态](<rules/run-flow.md>): 起始资源, 选择盲注, 抽牌, 出牌, 弃牌, 结算, 胜负和无尽模式.
2. [牌型](<rules/poker-hands.md>) -> [计分流水线](<rules/scoring.md>) -> [卡牌修饰](<rules/card-modifiers.md>): 分清打出的牌, 计分牌和留在手中的牌.
3. [盲注与 Boss](<rules/blinds.md>) -> [赌注难度](<rules/stakes.md>): 根据当前 Boss 和累计赌注修改默认规则.
4. [经济](<rules/economy.md>) -> [商店与补充包](<rules/shop-and-packs.md>) -> [随机池](<rules/random-pools.md>): 金钱, 利息, 容量, 购买与生成条件.
5. 根据实际持有对象查 [小丑机制](<mechanics/joker-mechanics.md>), [消耗牌机制](<mechanics/consumable-mechanics.md>), [牌组/优惠券/标签/挑战机制](<mechanics/run-modifiers.md>).
6. 如果任务涉及新档或解锁, 再读 [长期进度](<mechanics/progression.md>).

## 按决策查阅

| 当前任务 | 必须读取 | 特别关注 |
| --- | --- | --- |
| 选牌出牌 | [牌型](<rules/poker-hands.md>), [计分](<rules/scoring.md>), [小丑机制](<mechanics/joker-mechanics.md>) | 可选 1-5 张; 非计分牌仍会消耗出牌并进入弃牌堆; 重触发的完整效果 |
| 弃牌换牌 | [流程](<rules/run-flow.md>), [小丑机制](<mechanics/joker-mechanics.md>), [蜡封](<rules/card-modifiers.md>) | 弃牌次数, 成长/重置, 紫色蜡封, 当前剩余抽牌堆 |
| 面对 Boss | [盲注](<rules/blinds.md>) | 无效牌型, 被削弱牌, 出牌数量, 翻面, 下一次抽牌规则 |
| 排列小丑和手牌 | [计分](<rules/scoring.md>), [小丑机制](<mechanics/joker-mechanics.md>) | +Mult 与 XMult 顺序; 蓝图目标; 仪式匕首右邻; 逐牌触发 |
| 购买或卖出 | [经济](<rules/economy.md>), [商店](<rules/shop-and-packs.md>) | 实际价格/售价, 信用额度, 空槽, 负片容量, 永恒限制, 利息损失 |
| 使用塔罗或幻灵 | [使用机制](<mechanics/consumable-mechanics.md>) | 选择张数, 左右顺序, 空槽, 随机对象, 永恒保护和摧毁副作用 |
| 跳过盲注或补充包 | [流程](<rules/run-flow.md>), [标签/牌组机制](<mechanics/run-modifiers.md>) | 跳过不进入该盲注后的商店; 标签触发时机; 红牌/复古效果 |
| 打挑战模式 | [挑战目录](<cards/challenges.md>), [挑战规则语义](<mechanics/run-modifiers.md>) | 默认规则是否被自定义规则覆盖, 初始资源和禁用池 |

## 卡牌和对象目录

每个目录提供内部 ID, 中英名称, 卡面效果, 原型参数和源码位置. 动态倍率, 当前目标花色/点数和累计计数使用方括号占位符. **卡面说明不一定完整反映实现**, 同一对象的精确行为要同时查机制文档.

| 类别 | 数量 | 目录 |
| --- | ---: | --- |
| 小丑牌 Joker | 150 | [小丑目录](<cards/jokers.md>) |
| 塔罗牌 Tarot | 22 | [塔罗目录](<cards/tarots.md>) |
| 星球牌 Planet | 12 | [星球目录](<cards/planets.md>) |
| 幻灵牌 Spectral | 18 | [幻灵目录](<cards/spectrals.md>) |
| 优惠券 Voucher | 32 | [优惠券目录](<cards/vouchers.md>) |
| 牌组 Deck / Back | 15 | [牌组目录](<cards/decks.md>) |
| 标签 Tag | 24 | [标签目录](<cards/tags.md>) |
| 补充包 Booster | 32 原型, 15 类规格 | [补充包目录](<cards/boosters.md>) |
| 盲注 Blind | 30, 含 28 个 Boss | [盲注目录](<cards/blinds.md>) |
| 增强 Enhancement | 8 | [增强目录](<cards/enhancements.md>) |
| 版本 Edition | 5, 含基础版本 | [版本目录](<cards/editions.md>) |
| 蜡封 Seal | 4 | [蜡封目录](<cards/seals.md>) |
| 赌注 Stake | 8 | [赌注目录](<cards/stakes.md>) |
| 基础扑克牌 Playing Card | 52 | [扑克牌目录](<cards/playing-cards.md>) |
| 挑战 Challenge | 20 | [挑战目录](<cards/challenges.md>) |
| 其他修饰 | 5 | [贴纸/固定位置/负片消耗牌](<cards/modifiers.md>) |

32 个补充包原型包含多张外观不同但规格相同的包, 不能解释为 32 种不同玩法. 普通挑战牌组 `b_challenge` 是内部入口, 不算可选择的 15 个普通牌组.

机器读取可用 [结构化目录](<data/catalog.json>), 字段语义见 [数据说明](<data/README.md>). 其中 `records` 有 360 项, 挑战, 扑克牌, 牌型和特殊修饰分别在独立字段中. 这不是运行时状态快照.

## Agent 必须区分的概念

| 中文 | 英文 / 源码 | 含义 |
| --- | --- | --- |
| 筹码 | Chips | 当前手牌计分的一个乘数, 不是金钱 |
| 倍率 | Mult | 当前手牌计分的另一个乘数 |
| 乘倍率 | XMult / `x_mult` | 乘当前 Mult, 不能和 +Mult 无序合并 |
| 底注 | Ante | 一轮小/大/Boss 盲注的阶段编号 |
| 赌注 | Stake | 开局选择的难度, 效果逐级累计 |
| 盲注 | Blind | 当前需要达到分数的关卡 |
| 一回合 | Round | 一次实际挑战的盲注; 跳过不等于完成回合 |
| 出牌次数 | Hands | 回合内可出几次牌, 不是手牌数量 |
| 弃牌次数 | Discards | 回合内可主动换牌几次 |
| 手牌上限 | hand size | 通常补牌至多少张, 默认 8, 不等于最多出 5 张; 巨蟒或直接新增牌可能超过该数 |
| 打出牌集合 | `full_hand` / `G.play.cards` | 本次选出的全部牌 |
| 计分牌集合 | `scoring_hand` | 按牌型/石头牌/飞溅等规则参与逐牌计分的牌 |
| 留手牌 | `G.hand.cards` | 本次未打出的牌, 钢铁, 男爵等在这里触发 |
| 完整牌组 | `G.playing_cards` | 本局所有尚存在的扑克牌 |
| 剩余抽牌堆 | `G.deck.cards` | 当前还没抽到手上的牌, 不含手牌和弃牌 |
| 增强 | Enhancement | 同一扑克牌最多一种, 例如玻璃或钢铁 |
| 版本 | Edition | 与增强独立, 例如闪箔, 镭射, 多彩, 负片 |
| 蜡封 | Seal | 与增强/版本独立, 同一牌最多一种 |
| 削弱 | debuff | 对象效果受抑制; 易腐到期可持续失效. 不等于移除, 不等于抹去基础点数/花色 |
| 解锁 | unlocked | 可否进入正常候选池 |
| 发现 | discovered | 图鉴是否已经记录, 不等于解锁 |
| 永恒/易腐/租赁 | Eternal / Perishable / Rental | 实际影响效果的修饰; 不同于胜利赌注纪念贴纸 |

## 每次动作前的规则检查

1. 确认稳定的游戏状态, 当前盲注, 当前底注和累计赌注规则. 动画期间不要把尚未完成的事件结果当成最终状态.
2. 读取实际资源: 分数差, 出牌/弃牌次数, 金钱, 容量, 剩余牌, 小丑的当前成长值和目标.
3. 先检查动作合法性, 再比较收益. 不能用卡面文字绕过空槽, 选牌数, 永恒或当前状态限制.
4. 估分按实际左到右顺序, 保留逐牌重触发和概率分支. 期望分不是保证分, 必须区分确定能过关和概率能过关.
5. 动作完成后重新读取状态. 不从原型参数推断当前倍率, 目标牌型, 剩余贴纸回合或已经变化的商店价格.

## 维护

原型/卡面目录由 [抽取脚本](<../../scripts/gen-card-docs.lua>) 生成. 它只加载静态原型和描述函数, 不启动游戏, 不访问存档. [校验脚本](<../../scripts/check-game-docs.py>) 检查数量, ID, 源码位置和本地链接, 不替代运行时机制验证.

```shell
just game-docs
just check-game-docs
```

手写规则和机制不会被生成命令覆盖. 更新上游版本时必须重新核对机制, 不能只更新卡面文本.
