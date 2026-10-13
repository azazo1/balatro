# balatro-engine 的 Python 绑定

把引擎编成 Python 扩展, 让搜索直接在引擎状态上跑. 与命令行的区别只有一处, 但这一处决定了
搜索划不划算: **一局的状态可以克隆** —— 试一条分支只是复制一份内存, 不像 `play` 那样每次
都要把整段历史重放一遍, 于是"在某一步把前几名候选都真打一遍"才真的跑得动.

## 构建与安装

发行构建统一使用 `just impls dist`, wheel 在综合归档的 `python/` 内, 与 CLI 和 Web 一起发布.
开发绑定时可在当前项目虚拟环境内使用 `maturin develop --release --manifest-path impls/py/Cargo.toml`.
不再单独输出或发布一组 Python 发行产物.

按 abi3 编译, 一份 wheel 覆盖 Python 3.8 及以上.
`balatro_engine.build_version` 报告综合包的统一构建版本.

## 用法

```python
import balatro_engine as be

game = be.Game("QFG8ZBBC", "RED", 8)     # 种子 / 牌组 / 赌注 (8 是金注)
game.ante()                               # 底注
game.phase_key()                          # BlindSelect / SelectingHand / RoundEval / Shop / ...
game.hand()                               # [(0, "H_K"), (1, "C_Q"), ...]
game.apply('{"method":"select"}')         # 做一步, 返回引擎给的说明

# 搜索: 克隆出分支分别试, 互不干扰
best = None
for cards in candidates:
    branch = game.copy()
    try:
        branch.apply('{"method":"play","params":{"cards":%s}}' % cards)
    except ValueError:
        continue                          # 这一步不合法, 换一个候选
    if best is None or branch.chips() > best.chips():
        best = branch
```

动作与命令行完全相同 (见 [impls/engine/README.md](../engine/README.md) 的"让 agent 玩"一节), 报错消息也
相同 —— 报错里写着这一步该怎么办, 所以搜索撞到非法动作时不必查文档.

## API

| 调用 | 说明 |
| --- | --- |
| `Game(seed, deck, stake, uda=None)` | 开一局并走到选择盲注; `uda` 给 JSON 就用它, 否则用内置的全解锁档 |
| `apply(json) -> str` | 做一步; 不合法时抛 `ValueError`, 消息是"该怎么办" |
| `copy() -> Game` | 深拷贝, 供搜索分支 |
| `summary() -> str` | 给 agent 看的那份局面文本 |
| `phase()` / `phase_key()` | 阶段的中文名 / 英文枚举名 |
| `ante()` `chips()` `dollars()` | 底注 / 本回合得分 / 金钱 |
| `hands_left()` `discards_left()` | 剩余出牌与弃牌次数 |
| `target()` | 当前盲注的目标分 |
| `hand()` `jokers()` `consumables()` | 手牌 token / 小丑 key / 消耗牌 key |
| `won()` `over()` | 是否通关 / 是否已经结束 |
| `Game.full_unlock_uda()` | 内置解锁档的 JSON 原文 |

## 注意

- 这是**绑定**, 不是第二份实现: 规则一律走引擎, 所以引擎改了什么这里就跟着变.
- `impls/engine/core/Cargo.toml` 的依赖仍然是空的 —— 绑定放在这个独立 crate 里, 用 `path` 依赖引擎,
  所以引擎自己"只要 std"这条性质没有被破坏.
