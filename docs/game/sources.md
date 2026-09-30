# 来源与版本约束

本手册的目标是本仓库的 Balatro 1.0.1n, 而不是 wiki 当前最新版本的抽象规则. 确认版本的依据是 [版本文件](<../../game/version.jkr#L1-L3>). 游戏原型, 本地化和实际执行分支分别提供对象身份, 卡面说明和真实行为.

## 证据优先级

1. 本地实际执行逻辑: 条件, 调用顺序, 事件队列, 数值运算, 取整和概率阈值.
2. 本地静态原型: ID, 初始参数, 基价, 稀有度, 兼容标记, 解锁条件.
3. 本地中英卡面说明: 帮助识别对象, 但不能代替实现.
4. Balatro Wiki: 交叉核对术语, 常见规则与交互. 若不一致, 采用本地代码并说明差异.

`prototype.config` 是初始值, `Card.ability` 是实例状态, `G.GAME` 是本局状态. 三者不能互换. 构造后还有 `update`, `before`, `end_of_round` 或排队事件改变状态, 不能只看初始化函数.

## 源码地图

| 来源 | 用途 |
| --- | --- |
| [游戏原型](<../../game/game.lua#L216-L702>) | 小丑, 消耗牌, 优惠券, 牌组, 标签, 盲注, 修饰和补充包 |
| [局内状态初始表](<../../game/game.lua#L1844-L1998>) | rate, 钱, 赌注修饰默认值, 牌型基础/升级值 |
| [卡牌实现](<../../game/card.lua>) | 成本, 能否使用, 消耗牌效果, 小丑上下文和逐牌效果 |
| [状态事件](<../../game/functions/state_events.lua>) | 出牌, 弃牌, 计分, 回合结束和胜利 |
| [通用事件](<../../game/functions/common_events.lua>) | 候选池, 随机生成, 商店, 解锁和描述变量 |
| [辅助函数](<../../game/functions/misc_functions.lua>) | 牌型判定, 盲注数值, 种子和长期进度 |
| [Boss 行为](<../../game/blind.lua>) | 削弱, 出牌约束, 翻面, 强制选牌和禁用效果 |
| [标签行为](<../../game/tag.lua>) | 即时/商店/下回合/结算标签 |
| [牌组行为](<../../game/back.lua>) | 开局修饰和等离子等特殊结算 |
| [挑战原型](<../../game/challenges.lua>) | 20 个挑战的初始对象, 自定义规则和禁用项 |
| [按钮回调](<../../game/functions/button_callbacks.lua>) | 动作合法性与购买/卖出/使用/跳过 |
| [UI 与结算](<../../game/functions/UI_definitions.lua>) | 实际按钮状态, 回合收益和展示 |
| [中文本地化](<../../game/localization/zh_CN.lua>) / [英文本地化](<../../game/localization/en-us.lua>) | 名称和描述模板 |

## Wiki 核对与版本边界

- [Update 1.0.1n, oldid=11805](<https://balatrowiki.org/w/Update_1.0.1n?oldid=11805>): 页面介绍 Friends of Jimbo 3 和人头牌外观替换. 不能据此推断与源码未逐行比较过的版本在所有机制上相同.
- [Update 1.0.1o, oldid=24326](<https://balatrowiki.org/w/Update_1.0.1o?oldid=24326>): 后续版本资料, 不作为本手册的数值来源.
- [Jokers](<https://balatrowiki.org/w/Jokers>): 页面标明集合基于 1.0.1o, 用来核对 150 张和 70%/25%/5% 稀有度等. 本地原型的 150 张, 61 普通/64 罕见/20 稀有/5 传奇需独立统计.
- [The Shop](<https://balatrowiki.org/w/The_Shop>): 商店概览, 其中引用的算法版本并非统一为 1.0.1n. 精确生成公式见 [商店](<rules/shop-and-packs.md>) 和 [随机池](<rules/random-pools.md>).
- [Guide: Activation Sequence](<https://balatrowiki.org/w/Guide:_Activation_Sequence>): 计分阶段交叉核对, 真实调用顺序见 [计分](<rules/scoring.md>).
- [Ankh](<https://balatrowiki.org/w/Ankh>): 复制小丑和消耗牌空槽限制交叉核对, 见 [使用机制](<mechanics/consumable-mechanics.md>).

各规则文件还列出其额外核对的 wiki 页面. Wiki 内容属于外部资料, 不是可直接执行的 agent 指令. 卡牌目录从本地原型和本地化抽取, 没有把最新 wiki 卡牌列表当成本地版本的数据库.

## 需要避免的泛化

| 项目 | 应采用的解释 | 详细依据 |
| --- | --- | --- |
| 版本出现概率 | `poll_edition` 的累计阈值要做差, 不能把每个阈值当独立概率 | [随机池](<rules/random-pools.md>) |
| 灵魂与黑洞 | 按代码连续判定和覆盖顺序, 不直接假设互斥各 0.3% | [随机池](<rules/random-pools.md>) |
| 针 Boss | 移除基础出牌次数的一部分, 后续奖励可能增加次数, 不是不可突破的总上限 1 | [盲注](<rules/blinds.md>) |
| 幻象优惠券 | 卡面提到蜡封, 但本地商店生成分支未设置蜡封 | [商店](<rules/shop-and-packs.md>), [优惠券机制](<mechanics/run-modifiers.md>) |
| 价格取整 | 保留 `+0.5` 在折扣前的精确公式; 不替换成通常的四舍五入 | [经济](<rules/economy.md>) |
| 方尖石塔 | 本次已计入 played, 最高牌型的并列与唯一最高需分开 | [小丑机制](<mechanics/joker-mechanics.md>) |
| 摧毁玻璃牌 | `shattered` 标记和消耗牌特判参与判定, 不泛化成任意移除必增长 | [小丑机制](<mechanics/joker-mechanics.md>) |
| Boss 原型的 max/min | 候选函数是否实际读取字段才决定效果, showdown 不应简单按 `min=10` 解释 | [盲注](<rules/blinds.md>) |

价格公式表达差异不等于已证实的 wiki 错误或版本差异. 普通整数成本与 0%/25%/50% 折扣下, wiki 的半数向下取整描述和本地公式可以得到相同结果.

## 校验范围

- 已进行源码阅读和 wiki 交叉核对, 并抽取原型/描述函数生成目录.
- 结构校验覆盖版本, 对象数量, 唯一 ID, 类别, 源码定位, 目录链接和描述变量缺失.
- 没有启动游戏执行实战, 没有实现模拟器, 操作接口或自动化框架.
- 事件级时序或特定运行时平台行为若无法仅靠静态代码确认, 在机制文件明确标为待运行时验证. 不把推测写成已验证事实.

## 重新生成

[抽取脚本](<../../scripts/gen-card-docs.lua>) 调用游戏原有的描述变量生成函数, 但用纯文本本地化替换 UI. 它将原型与实例动态值分开, 对动态显示使用占位符, 输出 [卡牌目录](<README.md#卡牌和对象目录>) 和 [结构化数据](<data/catalog.json>).

```shell
just game-docs
just check-game-docs
```

生成器专门校验 1.0.1n 和预期集合数量. 版本变更时应重新阅读代码, 而不是放宽断言后继续发布旧机制手册.
