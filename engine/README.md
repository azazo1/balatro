# balatro-engine

Balatro 的规则引擎, 用 Rust 重写. 无界面, 不依赖 LÖVE 与图形环境, 每步状态可快照与回滚,
可批量并行跑对局.

`Cargo.toml` 的 `[dependencies]` 是**空的** —— 只用 std, 所以"不需要图形环境"不是靠约定,
而是编译期就成立的: 这个 crate 连一个能开窗口的依赖都没有.

## 行为基准是**带 mod 的构建**, 不是纯净原版

这条最要紧, 写在最前面.

仓库重打包的游戏附带 Steamodded 与几个自建 mod, 而录像 (`recordings/`) 是**那个构建**产出的.
所以引擎对齐的是"Steamodded 版 Balatro 的行为", 不是纯净的 1.0.1o. 两者有实际差别:

- Steamodded 用 lovely 的**字节级补丁**改动了大批原版文件 —— 重灾区是 `card.lua`,
  `functions/common_events.lua` 与 `functions/UI_definitions.lua`;
- 它还用 `overrides.lua` 覆写了几十个游戏类方法 (其中一部分是"先存下原函数再覆写"那种写法),
  有些直接**改变了原版规则的行为** —— 例如把 `Card:init` 里 `discard_pos` 那几颗全局随机数
  换成常量, 用 `SMODS.get_next_vouchers` 换掉券的抽取, 给 `pseudoseed` 加"暂停时改走全局随机数";
- 验收基准因此以**游戏实际跑出来的 digest** 为准, 而不是以 `game/` 下的原版源码为准. 遇到
  引擎与源码读出来的行为不一致时, 先去看 mod 有没有改过那一处.

想看当时**具体**改了多少, 不要凭这里的文字 —— 直接量 (数字随 mod 版本变化, 写死在文档里会过期):

```shell
just mods-check          # 打印补丁命中与未命中情况
just mods-tree           # 生成补丁后的源码树 dist/modded-tree, 可以直接对着看
```

"只覆盖原版内容不含 mod" 指的是**内容**层面: 引擎不实现 Steamodded 加进来的新卡, 新机制.
但**行为**层面要跟着那个附带 mod 的构建走, 否则对不上录像.

## 用法

跑测试与 lint:

```shell
cd engine
cargo test --no-fail-fast
cargo clippy --all-targets
```

跑回放对拍 (引擎照着 `recordings/` 折出来的 fixture 逐步重放, 比每一步的 digest):

```shell
cd engine
cargo test --test dump_replay -- --nocapture
```

不启动游戏即可检查原始回放或带解锁快照的 fixture:

```shell
just engine-replay <回放文件.replay.json> [更多回放文件]
just engine-replay --strict <fixture.jsonl>
```

入口复用正式动作适配器, 保留原局 `snapshot.uda`, 区分游戏拒绝与缺少摘要的动作,
并报告每局首次分歧. 只容忍游戏回放器已有的卡包图案编号和旧效果名称差异,
不会忽略金钱, 贴纸或强化差异. 缺少摘要不代表该动作后的状态已经验证.
源码审计, 实际 Lua 函数裁判与完整对拍的证明范围见 [行为审计](<../docs/rewrite/engine-audit.md>).

**反向校验**: 换引擎先走一遍, 写下每一步预测的 digest, 再由真游戏照着重放逐步核对.
这样可以跳出"录像里恰好有什么"的限制, 换一个种子 / 牌组 / 赌注就是一条新路径:

```shell
just macos replay-check <种子> <牌组> <赌注> [步数]
just macos replay-check-decks <种子> <赌注> [步数]    # 十五副牌组各跑一遍
```

它需要**启动游戏** (GUI), 所以只能在能跑图形环境的机器上执行; 退出码即结论 ——
0 全程预测正确, 1 在第 N 步跑偏, 2 中止, 3 文件无法回放.

## 让 agent 玩

`play` 是给 agent 用的对局与查询入口. 它**不需要游戏**, 也不需要图形环境:
agent 在引擎里走完一局, 再由游戏照着重放核对 (上面那条反向校验的路线).

```shell
# 开一局: 牌组与赌注必给, 种子不给就随机生成一个
just play step --deck RED --stake GOLD --actions .tmp/agent/RUN.actions.jsonl
just play step --seed ALEEB --deck RED --stake GOLD --actions .tmp/agent/RUN.actions.jsonl

# 之后不用再给开局参数 (它们记在动作文件的第一行)
just play step --actions .tmp/agent/RUN.actions.jsonl \
    --do '{"method":"play","params":{"cards":[1,2,3]}}'
just play step --actions .tmp/agent/RUN.actions.jsonl --emit .tmp/agent/RUN.replay.json  # 交给 just macos replay 逐步对拍

just play prompt                    # 系统提示词
just play lookup j_odd_todd 奇数托德 # 查卡牌的中文名与效果
just play docs                      # 手册目录
just play docs rules/economy.md     # 读某一节
just play search 利息               # 全局搜子串
```

每一步是一次**独立命令**: 每次调用把动作文件从头重放一遍再打印局面. 引擎是确定性的, 所以
重放换来的是无状态 —— 不需要常驻进程, 中途断开也不怕. 动作**先执行, 成功了才写进文件**,
所以被拒绝的动作不会留在历史里, agent 犯错不会把对局弄废.

导出游戏回放需要一份原始录像作为完整快照模板. 默认旧录像不存在时,
通过 `BALATRO_REPLAY_TEMPLATE` 指定模板; 对局与导出使用同一份解锁快照.
单元测试使用显式最小模板验证序列化, 不依赖用户机器上的录像路径.

```shell
BALATRO_REPLAY_TEMPLATE=<原始回放文件> just play step --deck RED --stake GOLD --actions .tmp/agent/RUN.actions.jsonl
```

### 开局参数

`--seed` / `--deck` / `--stake` 只在**新开一局**时给一次, 之后**记进动作文件的第一行**:

```json
{"method":"start","params":{"seed":"QSHVZSFR","deck":"RED","stake":"WHITE"}}
```

再给一遍就得与文件里记的一致, 不一致会报错而不是默默按其中一个走 —— 两者不一致时无论选哪个都是
在打"另一局", 而文件里的历史是按原来那局记的. 想换参数就换一个 `--actions` 文件.

不写 `--seed` 就**随机生成**一个, 形状与游戏"新开一局"时给的一样: 八位, 字母表是数字 `1-9`
与字母 `A-N`, `P-Z` (没有 `0` 与 `O`, 游戏特意跳过它们以免与对方看混). 生成的种子写进文件,
所以同一局能一直打下去, 也能交给游戏复现. 要复现别人的一局, 把 `--seed` 给它就行.

老格式的动作文件 (第一行是不带 `params` 的 `{"method":"start"}`) 仍能跑, 但要显式给 `--seed`
—— 文件里没记种子就无从推断, 随便生成一个就不是原来那一局了.

### 给 agent 的信息

输出照着内置 agent (`mods/balatrobot`) 给模型的那一份做. 这不是装饰: 同一个引擎, 给 agent
一串内部键名还是给一份带中文名与效果的局面, 打出来的结果会差很多, 而且输的原因会看起来像
"agent 水平不行", 实际是信息没给够. 每步给出:

- **阶段, 底注, 回合, 金钱**, 以及这一回合的得分与剩余出牌 / 弃牌次数.
- **三个盲注的名字, 状态, 效果**, 当前那个的**目标分**与奖金 (选盲注阶段就先预告, 否则没法决定
  跳不跳), 以及**跳过能拿到的标签**. Boss 的效果 (例如"所有方片牌都被削弱") 要在这里就看得见.
- **手牌**: 每张的花色点数 (中文), 修饰 (强化 / 版本 / 蜡封 / 被削弱), 以及**计分筹码**.
- **小丑与消耗牌**: 中文名, 效果文本, 卖价, 以及**当前成长值**.
- **商店与卡包**: 每格的名字, 价格, 修饰 (永恒 / 易腐 / 租赁), 刷新价.
- **牌型**: 只列等级高于 1 或这一局打过的, 带等级, 当前筹码与倍率, 已打次数 (含本回合).
- **上一手**: 逐来源的计分明细 —— 每行是 `来源 | 改了什么 | 改完之后的 筹码x倍率`, 最后一行是
  总分. 例如:

  ```text
  上一手: 两对 = 120
    出牌: [0]红桃J* [1]梅花J* [2]红桃10* [3]梅花10*
    基础 20x2
    [0]红桃J | +10 筹码 | 30x2
    开心小丑 | +8 倍率 | 30x10
    = 120
  ```

  带 `*` 的是真参与计分的那几张. 格式与内置 agent 拿到的 `round.last_hand.text` 一致
  (`mods/bbcore/runtime/scoring.lua`). 为什么要给到这个粒度: 只看一个总分, agent 无法知道
  哪张小丑贡献了多少, 也就无法从估错的那一手里学到东西 —— 下一手还会按同样的错法估.
- **会变的值**: 每回合重掷的目标花色与点数 (古老小丑, 偶像, 邮件回扣, 城堡), 待办清单认的牌型,
  盲注公牛要用的最常打出牌型, 小丑的成长值, 容量, 利息, 以及**摸牌堆与弃牌堆的花色点数分布**
  (算同花与顺子的命中率靠它).

原则是: 凡是**决策要用**的就给, 哪怕它让输出变长; 凡是引擎**没记录**的就不编 (报"还没掷"而不是
猜一个). 与内置 agent 的一处刻意不同: 它是一段连续对话, 所以能"每张牌只介绍一次"省 token;
这里每步是新进程, 没有记忆可留, 于是**每次都写全** —— 省 token 该做在 agent 那一侧, 不该靠少给它.

规则信息走 `lookup` / `docs` / `search` 三个子命令, 与内置 agent 的 `lookup` / `docs_read` /
`docs_search` 对应, 数据源同为 `docs/game/data/catalog.json` 与 `docs/game/` 下的手册 (编译期内嵌,
所以从任何工作目录调用都对). 手册里带 `[...]` 占位的那类效果不携带实时值, 那种要看"会变的值".

## 结构与覆盖

```
src/
  rng/     LuaJIT 的 math.random 与游戏的 pseudoseed (按键独立) 的移植
  lua/     按 Lua 语义移植的 table.sort 等
  cards/   牌面, 强化, 版本, 蜡封, 建牌序号
  data/    只读的原型表 (从 docs/game/data/catalog.json 读入) 与 agent 用的知识查询
  scoring/ 一次出牌的计分: 牌型, 等级表, 小丑四段钩子, 逐卡增强 / 版本
  jokers/  小丑效果
  run/     一局的状态与流程: 建堆洗牌, 出牌, 弃牌, 盲注, 结算, 商店, 开包, 快照
  batch/   批量并行跑对局 (按种子分片, 无锁)
  agent/   给 agent 的一层 (不参与规则计算): 动作施加, 局面摘要, 动态值, 提示词
  replay/  原始游戏记录与 fixture 的离线解释和摘要校验
  bin/play/ 上面那条命令行的入口
  bin/replay_check.rs 无图形环境的批量回放校验入口
tests/     测试与 fixture 基准 (基准数据在 data/ 下)
```

原版内容的覆盖. 数量是游戏 1.0.1o 本身的原型数 (稳定的), 实现方式那栏只说明**做法**,
不写"有多少个显式分支"这类随代码变动的数:

| 类别 | 数量 | 实现方式 |
| --- | --- | --- |
| 小丑 | 150 | 多数逐个写; "手牌含某牌型就加乘"那一类按原型 `config` 通用处理 |
| 消耗牌 | 52 | 塔罗与幻灵逐个写; 行星牌按 `config.hand_type` 通用处理 |
| 优惠券 | 32 | 逐个实现 |
| 标签 | 24 | 逐个实现 |
| 牌组 | 15 | 数据驱动, 原型 `config` 里的字段全部读取 |
| 补充包 | 32 | 五种 `kind` 全映射, 张数按 `config.choose` |
| 盲注 | 30 | 逐个实现; 只影响"背面朝上"的那三个不影响计分 |
| 赌注 | 8 | 逐档参数与门槛 |

## 验收现状

当前的基准, 加上 `tests/aleeb.rs` 里那两条专项 (目标点名的 ALEEB 开局发牌与首个商店,
期望值取自真游戏产出的 digest):

- [`tests/data/plasma-purple-6j8x.dump.jsonl`](tests/data/plasma-purple-6j8x.dump.jsonl):
  `bbdump` 导出的一局 (PLASMA / PURPLE / `7GU9BJP9`). 它等动作**彻底做完**才取状态,
  所以字段最全, 钱也可靠.
- [`tests/data/rec-20261003-222131-ALEEB.jsonl`](tests/data/rec-20261003-222131-ALEEB.jsonl):
  一份录像折出来的, ALEEB / PLASMA / GOLD. 覆盖开局发牌, 首个商店 (含白送的包怎么开),
  第一个补充包, 以及第二回合.

- [Cloud 9 完整记录](<tests/data/rec-20261005-23z315qp.jsonl>): 55 个摘要与 1 个拒绝动作,
  原局解锁快照随头部保存, 覆盖整副牌计数与结算.
- [Swashbuckler 完整记录](<tests/data/rec-20261005-t5tf8s49.jsonl>): 18 个摘要与 1 个拒绝动作,
  覆盖卖价倍率和影响胜负的计分边界.

`rec_*` 那一族基准由 `rec_fixture_paths` **扫目录**收集, 所以新录像折好放进去就会自动参与对拍,
不用改代码.

**早先那批录像基准已经删掉**, 因为它们的 `money` 那一栏不可用: 游戏把钱一行一行**带着动画**
加上去 (最后一行是"未用出牌次数"的奖励), 而录像在动作返回时就把状态取走了, 于是记下来的是
还没加完的中间值. 三项独立证据:

- 游戏源码 `state_events.lua` 里 `hands_left * (modifiers.money_per_hand or 1)` 明确要给;
- `bbdump` 那份的钱**每一步都对得上** —— 引擎要是多给, 它也会红;
- 拿录像折出的回放让游戏实跑, 游戏给出的是**引擎那个值**: 记录写 `6`, 游戏跑到 `9`.

而这项误差不是瞬时的 —— 之后每一步的钱都跟着少那么多, 又因为钱会影响利息而一轮比一轮大
(`3 -> 6 -> 10`). 所以整条 `money` 线在那批记录上都不可用. 删掉的代价是它们本来盯着的
**别的东西**也一起没了, 其中不少是当时抓到的真 bug (池子裁剪, 灵魂那两扇门, 建牌序号,
停用 Boss 等等), 那些结论记在 [`docs/rewrite/README.md`](../docs/rewrite/README.md).
新的录像到位后按同一套接口加回来即可 (`rec_fixture_paths` 扫目录, 不用改代码).

## 已知缺口

- **完整组合验证仍有限**: 已有两份早期基准和两份带原局解锁快照的新完整记录,
  但它们不能覆盖所有小丑顺序, 牌组和赌注组合. 后续完整 GUI 对拍仍然有价值.
- **标签事件的稳定状态需要额外确认**: 源码和离线回归已覆盖关键标签规则,
  旧记录仍可抓到奖励或版本标签回调的中间状态. 校验器不会为此全局忽略钱或版本.
- **秘术包和谱系交互仍需更多完整记录**: 新离线入口比较所有已有 `pack` 字段,
  不主动跳过包内容; 这不等于所有事件序列已经获得真实游戏验证.
- **白送的小丑包编号**在某个种子上差一 (引擎给 `_2`, 记录是 `_1`). 它由一次**全局**
  `math.random(1, 2)` 决定, 取决于"上一次 `pseudoseed` 之后又空转了几颗"; 这个颗数还没数准.
  试过的修法能对上三份录像却把另外十几份弄红, 是拟合不是修好, 已回退.
- **无尽模式**只验到较低底注. 再往上目标分数会溢出成 `nan` (游戏本身如此, 引擎照抄).
- **挑战模式没有实现**: 回放的格式本身就拒绝挑战, 属于范围之外.

## 相关文档

- [`docs/rewrite/README.md`](../docs/rewrite/README.md): 逐轮的审计记录 —— 每处差异是怎么发现的,
  试过哪些修法, 哪些回退了, 以及为什么. 想知道"这条为什么这么写"时先查这里.
- [`docs/agent-api.md`](../docs/agent-api.md): mod 版游戏的对局接口, 反向校验与 agent 游玩都用它.
- [`docs/recording.md`](../docs/recording.md) 与 [`docs/replay.md`](../docs/replay.md): 录像与回放的格式.
