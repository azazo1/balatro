# balatro-engine

Balatro 的规则引擎, 用 Rust 重写. 无界面, 不依赖 LÖVE 与图形环境, 每步状态可快照与回滚,
可批量并行跑对局.

`Cargo.toml` 的 `[dependencies]` 是**空的** —— 只用 std, 所以"不需要图形环境"不是靠约定,
而是编译期就成立的: 这个 crate 连一个能开窗口的依赖都没有.

## 行为基准是**带 mod 的构建**, 不是纯净原版

这条最要紧, 写在最前面.

仓库重打包的游戏附带 Steamodded 与几个自建 mod, 而录像 (`recordings/`) 是**那个构建**产出的.
所以引擎对齐的是"Steamodded 版 Balatro 的行为", 不是纯净的 1.0.1o. 两者有实际差别:

- Steamodded 用 lovely 的字节级补丁改了 **30 个原版文件, 共 1049 处** (重灾区是 `card.lua` 246 处,
  `functions/common_events.lua` 153 处, `functions/UI_definitions.lua` 149 处);
- 它还用 `overrides.lua` 猴补了 36 个游戏类方法 (其中 16 处是"先存下原函数再覆写"那种),
  有些直接**改变了原版规则的行为** —— 例如把 `Card:init` 里 `discard_pos` 那三颗全局随机数
  换成常量, 用 `SMODS.get_next_vouchers` 换掉券的抽取, 给 `pseudoseed` 加"暂停时改走全局随机数";
- 验收基准因此以**游戏实际跑出来的 digest** 为准, 而不是以 `game/` 下的原版源码为准. 遇到
  引擎与源码读出来的行为不一致时, 先去看 mod 有没有改过那一处.

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

**反向校验**: 换引擎先走一遍, 写下每一步预测的 digest, 再由真游戏照着重放逐步核对.
这样可以跳出"录像里恰好有什么"的限制, 换一个种子 / 牌组 / 赌注就是一条新路径:

```shell
just macos replay-check <种子> <牌组> <赌注> [步数]
just macos replay-check-decks <种子> <赌注> [步数]    # 十五副牌组各跑一遍
```

它需要**启动游戏** (GUI), 所以只能在能跑图形环境的机器上执行; 退出码即结论 ——
0 全程预测正确, 1 在第 N 步跑偏, 2 中止, 3 文件无法回放.

## 结构与覆盖

```
src/
  rng/     LuaJIT 的 math.random 与游戏的 pseudoseed (按键独立) 的移植
  lua/     按 Lua 语义移植的 table.sort 等
  cards/   牌面, 强化, 版本, 蜡封, 建牌序号
  data/    只读的原型表 (从 docs/game/data/catalog.json 读入)
  scoring/ 一次出牌的计分: 牌型, 等级表, 小丑四段钩子, 逐卡增强 / 版本
  jokers/  小丑效果
  run/     一局的状态与流程: 建堆洗牌, 出牌, 弃牌, 盲注, 结算, 商店, 开包, 快照
  batch/   批量并行跑对局 (按种子分片, 无锁)
tests/     22 个测试文件, 284 个用例; data/ 下是 fixture 基准
```

原版内容的覆盖 (逐类核对过):

| 类别 | 数量 | 实现方式 |
| --- | --- | --- |
| 小丑 | 150 | 135 个显式分支, 其余按 `config` 与牌型匹配 |
| 消耗牌 | 52 | 40 个显式分支, 12 张行星牌按 `config.hand_type` 加等级 |
| 优惠券 | 32 | 逐个实现 |
| 标签 | 24 | 逐个实现 |
| 牌组 | 15 | 数据驱动, 原型 `config` 里的字段全部读取 |
| 补充包 | 32 | 五种 `kind` 全映射, 张数按 `config.choose` |
| 盲注 | 30 | 27 个显式分支, 其余三个只改"背面朝上", 不影响计分 |
| 赌注 | 8 | 逐档参数与门槛 |

## 验收现状

基准是十九份录像 (逐项比对 1447 步) 加四份手写的记录: 三份 ALEEB 的录像 (41 / 68 / 133 步)
与一份 `bbdump` 导出的严格记录 (40 步). 比较器分两档:

- **严格档** (`plasma-purple-6j8x.dump.jsonl`, 40 步): 比阶段, 钱, 底注, 盲注;
- **批量档** (其余): 比 digest 的各个区域 —— 手牌, 牌堆, 小丑, 消耗牌, 货架, 券, 包.

`bbdump` 导出的那份是严格档, 因为它等动作彻底做完才取样; 录像那几份的取样时机在动作中途
(钱是分行动画加到一半的值), 所以只用来盯区域内容.

## 已知缺口

- **标签几乎没被真游戏验过**: 24 个标签都实现了, 但拿到标签只能靠跳盲注, 而 19 份录像里
  只出现过 **1 次** `skip`. 也就是说标签的效果基本没有外部证据.
- **秘术包的内容**那一项在批量对拍里被跳过: 记录与引擎不同, 追到"池子键少抽四次"就没再往下,
  因为 Steamodded 自己重写了开包逻辑. 小丑包与标准包都是对的.
- **白送的小丑包编号**在 XXWF71H9 上差一 (引擎 `_2`, 记录 `_1`). 它由一次**全局** `math.random(1, 2)`
  决定, 取决于"上一次 `pseudoseed` 之后又空转了几颗"; 这个颗数还没数准. 试过的修法能对上三份
  录像却把另外十七份弄红, 是拟合不是修好, 已回退.
- **无尽模式**只验到底注 39. 再往上目标分数会溢出成 `nan` (游戏本身如此, 引擎照抄).
- **挑战模式没有实现**: 回放的格式本身就拒绝挑战, 属于范围之外.

## 相关文档

- [`docs/rewrite/README.md`](../docs/rewrite/README.md): 逐轮的审计记录 —— 每处差异是怎么发现的,
  试过哪些修法, 哪些回退了, 以及为什么. 想知道"这条为什么这么写"时先查这里.
- [`docs/agent-api.md`](../docs/agent-api.md): mod 版游戏的对局接口, 反向校验与 agent 游玩都用它.
- [`docs/recording.md`](../docs/recording.md) 与 [`docs/replay.md`](../docs/replay.md): 录像与回放的格式.
