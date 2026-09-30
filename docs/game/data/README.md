# 结构化目录数据

[目录数据](<catalog.json>) 是静态知识库, 来自本地 1.0.1n 源码与中英卡面文本. 适合按 ID 查询, 不包含当前存档, 当前局或屏幕状态. 总入口见 [Agent 手册](<../README.md>).

## 顶层字段

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `schema_version` | integer | 本数据结构版本, 当前 1, 与游戏版本不同 |
| `game_version` | string | `1.0.1n` |
| `description_semantics` | string | 描述与动态值的语义约束 |
| `counts` | object | 每种类别的覆盖数量 |
| `records` | array | 360 个原型, 包含小丑, 消耗牌, 优惠券, 牌组, 标签, 补充包, 盲注, 增强, 版本, 蜡封, 赌注 |
| `playing_cards` | array | 52 张标准扑克牌, 含点数/花色及基础筹码 |
| `challenges` | array | 20 个挑战的完整初始条件和限制 |
| `hands` | object | 12 种牌型的初始筹码/倍率/等级/每级增长和示例 |
| `modifiers` | array | 永恒, 易腐, 租赁, 固定位置和负片消耗牌的卡面信息 |

空列表用 `[]`, 空参数对象用 `{}`. 可选字段无值时省略, 不将省略的兼容标记或初始解锁状态解释为 `false`.

## records 的公共字段

| 字段 | 含义 |
| --- | --- |
| `id` | 游戏内部稳定键, 保留游戏自身拼写, 例如 `j_gluttenous_joker`, `c_heirophant`, `j_selzer` |
| `category` | 原型 set: `Joker`, `Tarot`, `Planet`, `Spectral`, `Voucher`, `Back`, `Tag`, `Booster`, `Blind`, `Enhanced`, `Edition`, `Seal`, `Stake` |
| `order` | 游戏集合展示顺序, 不表示计分顺序 |
| `name_zh`, `name_en` | 本地化名称, 只正规化标点和中英数字间距 |
| `effect_zh`, `effect_en` | 已填规则常量的描述行数组. 动态值保留为方括号占位符 |
| `base_cost` | 原型基价; 非所有类别都有. 不是实际商店价格或售价 |
| `config` | 原型初始参数, 不是实例 `Card.ability` |
| `initially_unlocked` | 新档原型初始解锁值, 不是当前存档状态 |
| `unlock_condition` | 源码解锁条件原型. 事件类型的含义见 [长期进度](<../mechanics/progression.md>) |
| `unlock_zh`, `unlock_en` | 可用的卡面解锁描述行数组, 不保证每个条件都有卡面说明 |
| `source.path`, `source.line` | 相对仓库根的源码位置 |

### 类别特有字段

- 小丑: `rarity` 为 1/2/3/4, 分别普通/罕见/稀有/传奇. `blueprint_compat`, `eternal_compat`, `perishable_compat` 是兼容性, 不意味着一定抽中该修饰. 蓝图只能复制允许的触发返回值, 不会自动复制成长副作用.
- 候选限制: `hidden`, `enhancement_gate`, `yes_pool_flag`, `no_pool_flag`, `requires`. 标签的 `requires` 检查目标原型已在存档发现, 优惠券的 `requires` 检查本局已兑换, 不能统一理解为当前持有. 它们的联合筛选规则见 [随机池](<../rules/random-pools.md>).
- 标签: `min_ante` 仅在原型设值时存在; `config.type` 是应用事件类型. 即时, 商店生成, 商店修饰, 选盲注等不能混用.
- 补充包: `kind`, `weight`, `config.extra`, `config.choose` 分别为内容类别, 原型权重, 展示候选数, 可选数. 32 个原型包含重复规格的不同外观.
- 盲注: `blind_multiplier`, `reward_dollars`, `debuff`, `boss`. `boss.min`/`boss.max` 是原型数据, 不代表生成函数一定读取它们; showdown 出现规则见 [盲注](<../rules/blinds.md>).

## challenges 与 hands

挑战保留 `rules.custom`, `rules.modifiers`, `jokers`, `consumeables`, `vouchers`, `deck`, `restrictions`. 原字段 `consumeables` 的拼写保留不改. 每个对象的参数必须结合 [挑战机制](<../mechanics/run-modifiers.md>) 解读. 显式牌列表可能包含重复, 不能转成集合去重.

牌型中的 `chips`/`mult` 和 `s_chips`/`s_mult` 是等级 1 初始值, `l_chips`/`l_mult` 是每级增长量. `visible=false` 表示开局隐藏, 不表示不能判定该牌型. `played=0` 是初始计数, 不是当前一局使用次数.

## 读取方式

推荐先解析 JSON, 只取当前持有 ID 和相关牌型. 例如查询 `records` 中 `id == "j_blueprint"` 的对象, 再读取 [复制机制](<../mechanics/joker-mechanics.md>). 查询结果不能代替实际 `ability`, 容量或概率倍率.

方括号占位符是说明文本, **不是数值表达式**, 不应直接求值. 实例状态应独立读出再按照规则计算. 中英文说明只是同一原型的两个显示版本, 不是两张不同卡牌.

## 生成与校验

- 生成工具: [LuaJIT 抽取脚本](<../../../scripts/gen-card-docs.lua>).
- 静态校验: [目录校验脚本](<../../../scripts/check-game-docs.py>).

```shell
just game-docs
just check-game-docs
```

生成器只加载源代码中的静态原型和描述函数, 在内存中构造展示对象. 不会打开游戏, 读取存档或修改任何游戏资源. 动态文本以显式占位符替换; 目录不是伪造的可供游玩的运行时环境.
