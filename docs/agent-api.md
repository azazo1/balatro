# Agent 游玩接口

带 mod 的版本内置 [balatrobot](https://github.com/coder/balatrobot) v1.5.2. 它在游戏里开一个
JSON-RPC 2.0 over HTTP 接口, 外部程序 (agent, 脚本) 可以读取完整游戏状态并操作游戏.
接口默认关闭. 内置 agent 的 LLM, Decision 与混合方式见 [Decision 接入](<decision-agent.md>),
`propose_actions` 只用于内置模型对话, 不注册为外部 JSON-RPC 方法.

## 开启

| 方式 | 做法 | 存档 | 游戏设置 |
| --- | --- | --- | --- |
| 终端启动 | `just windows run-agent` 或 `just macos run-agent`, 默认正常速度并录像, 见下方 "录制" | 独立的 `Balatro-Agent` 目录 | 跳过教程, 其余沿用存档 |
| 游戏内切换 | 模组 > BalatroBot > 配置, agent 模式选 "外部" | 当前存档 | 不改 |

启动入口共用 [Python 脚本](<../scripts/run_agent.py>), 会先打包带 mod 的版本再启动, 不需要 Bash 或 tee.
Windows 需要 Rust 与 MSVC 链接器来构建 bbnet, 启动控制台版 exe, 将游戏输出同时写入终端和日志.
`agent-call` 与 `agent-wait` 在两个平台上通用, JSON 参数由 just 直接传给 Python, 不经过 shell 二次解析.
Windows 命令示例建议在 PowerShell 7.3+ 中使用, 以原样传递 JSON 引号.

- agent 模式三选一: 关闭, 外部 (本文的 HTTP 接口), 内置 (游戏内直接连接大模型, 见 [builtin-agent.md](<builtin-agent.md>)).
  外部与内置互斥, 两者之间要经过关闭; 内置 agent 运行中不能切换.
- 模式可以随时切换, 保存在存档目录的 `config/balatrobot.jkr`, 下次启动沿用.
- 配置页会显示监听地址和状态 (`listening` / `off` / `bind failed`), 还有决策消息的开关和录制状态.
- 终端启动 (`BALATROBOT_ENABLE=1`) 时模式锁定为外部, 模式按钮变灰, 不写回配置.
- 终端启动时画面, 开场动画, 声音, 游戏速度都沿用存档, 与正常游玩一样. 下面的环境变量只在本次运行
  生效, 不会写回存档:

| 环境变量 | 作用 |
| --- | --- |
| `BALATROBOT_FAST=1` | 10 倍速, 动画 60fps, 不限帧率, 关 vsync (`run-agent on 1` 即此项) |
| `BALATROBOT_HEADLESS=1` | 不显示窗口, 跳过开场动画 |
| `BALATROBOT_AUDIO=1` | 强制开声音, 不设时沿用存档音量 |
| `BALATROBOT_GAMESPEED`, `BALATROBOT_FPS_CAP`, `BALATROBOT_ANIMATION_FPS` | 显式设置时覆盖 |
| `BALATROBOT_PORT`, `BALATROBOT_HOST`, `BALATROBOT_RENDER_ON_API`, `BALATROBOT_NO_SHADERS` | 与 upstream 相同, 见 `mods/bbcore/src/lua/settings.lua` 文件头 |

启动后游戏先播开场动画, 这时 `gamestate` 返回 `SPLASH`. 开局前等它进入主菜单:

```shell
just agent-wait          # 默认等 MENU, 最多 60 秒, 超时返回非 0
just agent-wait MENU 20
```

自己写 agent 时轮询 `gamestate` 直到 `state` 为 `MENU` 即可.

地址默认是 `http://127.0.0.1:12346`, 只监听本机.

注意: 接口没有认证, 本机任何进程都能控制游戏, 用完请关掉.

## 调用

```shell
just agent-call health
just agent-call gamestate
just agent-call start '{"deck":"RED","stake":"WHITE"}'
just agent-call play '{"cards":[0,1,2]}'
```

`agent-call` 就是发一个 POST 请求, 等价于:

```shell
curl -s -X POST http://127.0.0.1:12346 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"health","params":{},"id":1}'
```

成功时返回 `{"jsonrpc":"2.0","result":{...},"id":1}`. 操作类方法会等游戏动画和结算都结束后才返回,
`result` 是操作完成后的完整游戏状态, 一般不用另外再查 `gamestate`.

- 同一时间只服务一个连接, 请求要一个一个发.
- 操作类方法要等游戏内的条件满足才返回. 偶尔会一直不返回 (实测 `load` 出现过一次), 这时操作通常
  已经生效. 请求要设超时, 超时后用 `gamestate` 确认当前状态再继续.
- 所有下标都从 0 开始, 对应 `gamestate` 里各区域 `cards` 数组的顺序.
- 背面朝上的牌 (标记, 房屋, 车轮, 鱼把扑克牌翻过去; 琥珀之实把小丑翻过去洗乱) 只给
  `state.hidden`, 花色点数, 增强蜡封, 卖价和 `id` 都裁掉, 和人悬停看不到正面一样.
  选中状态仍保留, 出牌下标照常用. 打出之后身份出现在 `round.last_hand`.
- `gamestate` 返回的内容很多 (包括整副牌), 可以用 `jq` 只取需要的字段:

```shell
just agent-call gamestate | jq '.result | {state, ante_num, money, round}'
just agent-call gamestate | jq '.result.hand.cards | map({id, key, label})'
```

## 流程

```
MENU -> BLIND_SELECT -> SELECTING_HAND -> ROUND_EVAL -> SHOP -+
            ^                 |                               |
            |                 v                               |
            |             GAME_OVER                           |
            +-------------------------------------------------+
```

商店里打开卡包后进入 `SMODS_BOOSTER_OPENED`, 选完或跳过后回到 `SHOP`.
跳过盲注的标签 (魅力, 空灵, 流星, 标准, 丑角) 也会打开补充包, 选完后回到 `BLIND_SELECT`.
`skip` 会等包打开再返回 (返回里 `state` 已是 `SMODS_BOOSTER_OPENED`); `pack` 等包关掉后回到打开前的界面, 不是死等商店.

| 状态 | 常用方法 |
| --- | --- |
| `MENU` | `start {"deck","stake","seed"?}` |
| `BLIND_SELECT` | `select`, `skip` (Boss 不能跳过), `reroll_boss` (导演剪辑版 / 重构, 花 $10 重掷即将面对的 Boss) |
| `SELECTING_HAND` | `play {"cards"}`, `discard {"cards"}`, `rearrange {"hand"}` |
| `ROUND_EVAL` | `cash_out` |
| `SHOP` | `buy {"card"或"voucher"或"pack"}`, `buy {"card","use":true}` (消耗牌买下立即使用, 不占槽位), `reroll`, `sell {"joker"或"consumable"}`, `next_round` |
| `SMODS_BOOSTER_OPENED` | `pack {"card","targets"?}` 或 `pack {"skip":true}`, `sell {"joker"或"consumable"}` |
| 任意 | `gamestate`, `health`, `rearrange`, `menu`, `save`/`load {"path"}`, `screenshot {"path"}` |
| `SELECTING_HAND`, `SHOP`, `SMODS_BOOSTER_OPENED` | `use {"consumable","cards"?}`; 需要选牌的只能在出牌或发了手牌的卡包 (秘术, 幻灵) 里用 |

`set` 和 `add` 可以直接改金钱, 盲注分数, 添加卡牌, 用于调试, 正常游玩不要用.

弹窗打开时, 返回里带 `overlay` 字段. 此时除查询类方法, `menu`, `save`/`load`, `notify`, `endless`,
`continue` 外都返回 `INVALID_STATE`, 与人点不到弹窗底下的按钮一致. 请求在等游戏推进时弹窗出现,
会以当前状态先返回:

- `overlay` 为 `unlock`: 解锁了新牌组, 小丑等, 常在开局或回主菜单时出现. 调用 `continue` 关掉
  (等同点 "继续"). 被它打断的请求 (例如 `start`) 会在 `continue` 的返回里给出结果.
  连续解锁多项时, `continue` 的返回仍带 `unlock`, 继续调用即可.
- `overlay` 为 `win`: 打过第 8 底注的 Boss, 胜利界面打开. `play` 会等界面完全弹出 (约 3 秒) 后返回 `won: true` 与此值.
  调用 `endless` 进入无尽模式 (等同点 "无尽模式" 按钮, 返回时已在 `ROUND_EVAL`, 可以 `cash_out`),
  或 `menu` 回主菜单.
- `overlay` 为 `other`: 人在游戏里打开了设置等菜单, 等人关掉后用 `gamestate` 确认状态.
`save`, `load`, `screenshot` 的 `path` 是本机的绝对路径.

完整的参数和返回结构:

- 调用 `rpc.discover` 取得 OpenRPC 描述, 基于 `mods/balatrobot/src/lua/utils/openrpc.json`, 加上本仓库新增的
  `notify`, `endless`, `continue`, 手册查询 4 个方法与 `reason`.
- upstream 文档: <https://coder.github.io/balatrobot/api/>

## 出牌计分

出牌的返回里带 `round.last_hand`: 这一手怎么从牌型基础涨到总分, 内容就是 user 在屏幕上看到的那些飘字.
它记的是本局最近一次出牌, 下一次 `play` 时被覆盖, 弃牌与买卖不会动它; 还没出过牌时这个字段不出现.

```json
"round": {
  "chips": 18125,
  "hands_left": 3,
  "last_hand": {
    "name": "同花", "level": 1,
    "base": { "chips": 35, "mult": 4 },
    "chips": 125, "mult": 81, "total": 10125,
    "cards": [{ "key": "H_K", "suit": "H", "rank": "K", "label": "红桃K", "scoring": true }],
    "steps": [{ "by": "H_K", "name": "红桃K", "kind": "chips", "amount": 10, "chips": 45, "mult": 4 }],
    "line": "上一手: 同花 Lv1 = 10125",
    "text": "上一手: 同花 Lv1 = 10125\n出牌: 红桃K* 红桃Q* 红桃9* 红桃5* 黑桃2\n基础 35x4\n...\n= 10125"
  }
}
```

`text` 是拼好的整段, 卡牌名取游戏当前语言 (默认简体中文), 不想解析字段时直接读它:

```
上一手: 同花 Lv1 = 10125
出牌: 红桃K* 红桃Q* 红桃9* 红桃5* 黑桃2
基础 35x4
红桃K | +10 筹码 | 45x4
红桃Q | +10 筹码 | 55x4
红桃9 | +10 筹码 | 65x4
红桃5 | +10 筹码 | 75x4
闪箔红桃K | +50 筹码 | 125x4
狡诈小丑 | +50 倍率 | 125x54
全息小丑 | x1.5 倍率 | 125x81
= 10125
```

- 每行三列: 变动原因 (哪张牌或哪个小丑), 变动因素 (加了多少筹码或倍率, 乘了几倍), 变动后筹码x倍率.
- 出牌行里带 `*` 的是真计入牌型的牌, 没带星号的只是被打出去.
- 被盲注封禁这一手 (画面上的 `Not Allowed!`) 总分为 0, 明细里给一行 `被盲注封禁 | 本手不计分 | 0x0`.
- 版本加成与重触发这类不改数值的项, 第二列写游戏自己那句提示 (例如 `闪箔红桃K | 再次触发 | 125x81`).
- `steps[].by` 是卡牌 key, `kind` 取 `chips` / `mult` / `xmult` / `xchips` / `dollars` / `debuff` / `extra` / `blocked`,
  `chips` 与 `mult` 是这一步之后的当前值, 消费方不用自己从基础推.
- 只有 `play` 会记. `discard`, `buy`, `use` 等不记, 也不会清掉上一次的 `last_hand`.
- 记录挂在存档里, 读档继续时上一手仍能看到.

## 手册查询

`docs_index`, `docs_read`, `docs_search`, `lookup` 查询随 mod 打包的游戏手册, 内容是 `docs/game/` 的 README,
`rules/`, `mechanics/`, `cards/`, `data/`. 这 4 个方法只读, 任何游戏状态和弹窗期间都能调用, 不算 agent 活动,
也不写进回放文件.

用法: 先 `docs_index` 看目录, 大文件先读大纲再按 `section` 读; 按卡牌 id 或名称查询时直接用 `lookup`.

```shell
just agent-call lookup '{"keys":["j_blueprint","蓝色小丑"]}'
just agent-call docs_read '{"path":"cards/jokers.md","section":"j-blueprint"}'
just agent-call docs_search '{"query":"xmult","path":"mechanics"}'
```

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `docs_index` | 无 | `{files: [{path, title, lines}], guide, hint}`, `guide` 是 README "按决策查阅" 表 |
| `docs_read` | `path`, 可选 `section`, `offset`, `limit` | `{path, title, total_lines, section?, start_line, end_line, content, next_offset?}` |
| `docs_search` | `query`, 可选 `path`, `limit` | `{query, matches: ["路径:行号: 内容"], total, truncated}` |
| `lookup` | `keys`: id, 中文名或英文名的数组 | `{results: [{key, cards: [...], candidates?}]}`, 与 `keys` 一一对应 |

- `docs_read`:
  - `path` 相对手册根目录, 可以带 `#锚点`, 不接受 `..` 和绝对路径.
  - `section` 可以写锚点 id (例如 `j-blueprint`), GitHub 风格的标题链接, 标题全文或唯一的标题子串.
    匹配到多个标题时返回 `BAD_REQUEST`, 错误信息里列出候选.
  - `content` 每行形如 `行号: 文本`. 单次最多 200 行或 8KB, 没读完时带 `next_offset`,
    用同样的 `path`/`section` 加 `offset` 接着读.
  - 超过 300 行的文件不带 `section`/`offset` 时, 只返回 `{path, title, total_lines, outline, hint}`,
    `outline` 每行形如 `行号: ### 标题 {#锚点}`.
- `docs_search`: 纯子串, 英文不区分大小写. `path` 可以是文件或目录 (例如 `mechanics`). `limit` 默认 20, 最多 100.
  过长的行只保留命中位置附近约 200 字节.
- `lookup`: 最多 30 个 key, 名称不区分大小写, 忽略空格和标点. 同名对象全部返回, 最多 8 个.
  - 每张卡的字段: `id`, `name_zh`, `name_en`, `category`, `rarity` (只有小丑有), `base_cost`, `effect_zh`,
    `blueprint_compat` (只有小丑有), `doc` (目录位置, 可以直接传给 `docs_read`), `mechanics` (`mechanics/` 中提到这个 id 的行, 最多 5 条).
  - 找不到时 `cards` 为空数组, `candidates` 给出最多 5 个 "id 中文名 / 英文名".
  - 覆盖卡牌, 修饰和挑战, 不包括扑克牌和牌型. `catalog.json` 只供 `lookup` 使用, 不能用 `docs_read` 读.
  - 手册是版本快照, 会随局面变化的值在里面只能写成占位 (例如古老小丑的 `[本回合目标花色]`, 城堡的
    `(当前为+[当前筹码]筹码)`). 要看此刻的真实值, 用下面的 `dynamics`.
- 链接: 返回内容里 `[文字](<路径#锚点>)` 形式的是手册内链接, 路径可以直接传给 `docs_read`.
  `文字 (路径)` 形式的是手册以外的源码位置, 读不到.
- 直接用 `game/` 运行 (没有打包) 时没有手册, 调用返回 `INTERNAL_ERROR`. 开发时可以设 `BALATROBOT_KNOWLEDGE_DIR`
  指向仓库的 `docs/game/`.

## 动态值

`dynamics` 给出当前局里会变的值, 手册里那些占位在这里是真实值. 只读, 任何阶段和弹窗期间都能调用,
不算 agent 活动, 也不写进回放文件.

```shell
just agent-call dynamics | jq '.result.targets, .result.jokers'
just agent-call dynamics '{"deck":"stats"}' | jq '.result.deck.by_suit'
just agent-call dynamics '{"deck":"list","discard":"list","cards":false}' | jq '.result.deck'
```

| 参数 | 默认 | 内容 |
| --- | --- | --- |
| `targets` | `true` | 每回合重抽的认牌目标: 古老小丑的花色, 偶像的花色与点数, 邮件回扣的点数, 城堡的花色, 待办清单的牌型 |
| `cards` | `true` | 持有小丑, 消耗牌与手牌里特殊牌的实时效果文本 |
| `deck` | 不给 | 摸牌堆的详细程度: `stats` 或 `list` |
| `discard` | 不给 | 弃牌堆 (本回合弃掉与打出的牌) 的详细程度: `stats` 或 `list` |

结果里的键与请求的项对应: 传 `false` 的项不出现 (`targets` 为 `false` 时 `most_played_poker_hand` 也不给),
`deck`/`discard` 不传就不返回; 取值只能是 `stats` 或 `list`, 别的值返回 `BAD_REQUEST`.

- `targets` 每项是 `{key, name, suit?, suit_name?, rank?, rank_name?, poker_hand?, poker_hand_name?}`,
  `key` 是认牌的牌 (`j_ancient` 等), `*_name` 是游戏语言的名字 (默认简体中文, 例如 `黑桃`, `红桃Q`).
  没有的目标不出现, 例如本局没有古老小丑时就没有 `j_ancient` 项.
- `most_played_poker_hand` 是本局最常打出的牌型, 盲注公牛 (The Ox) 用它, 还没打过牌时不出现.
- `jokers` / `consumables` / `hand` 每项是 `{index, key, name, effect}`. 背面朝上的牌不出现 (人悬停也看不到). `effect` 取游戏自己生成的那一份
  (`Card:generate_UIBox_ability_table`), 就是玩家悬停看到的文字: 成长值 (拉面的当前倍率, 城堡的当前筹码)
  与概率 (幸运牌, 玻璃牌) 都已代入. `index` 与该区域在 `gamestate` 里的下标一致, 从 0 开始.
- `deck` / `discard` 每项是 `{count, by_suit, by_rank, cards?, truncated?}`: `count` 是张数,
  `by_suit` 与 `by_rank` 的键是游戏语言的花色名与点数名 (例如 `{"红桃": 4}`), `list` 时另给 `cards`
  完整列表 (每张 `{key, suit, suit_name, rank, rank_name}`, 超过 60 张截断并置 `truncated`).
  算同花与顺子的概率用它 (摸牌堆是接下来会抽到的牌, 弃牌堆是本回合已经出过局的牌).

## 决策消息

agent 干的事以原版成就通知的样式显示在屏幕上: 黑底灰边, 从屏幕外滑入, 停留几秒后滑出.
最多每侧同时显示 3 条, 新的在上面. 中文会自动换用带中文字形的字体. 录制时也会录进视频.

屏幕两侧各一条车道, 互不影响:

| 位置 | 内容 | 由谁决定 | 开关 |
| --- | --- | --- | --- |
| 右侧 | 决策消息: 模型的 `reason` 与 `notify` 的解说 | 模型自己给 (为什么这么做) | Show Agent Messages |
| 左侧 | 工具调用记录: 工具中文名 + 这次参数的含义 | mod 按方法名写死的模板 | Show Tool Calls |

左侧每条形如 `出牌` / `手牌下标 0, 1`, `购买` / `商店第 2 张`, `查动态值` / `摸牌堆统计`.
模板在 `mods/bbcore/runtime/call_note.lua` (手册查询那 4 个方法在 `mods/balatrobot/agent/knowledge/notes.lua`).
没有参数 (或只给了 `reason`) 时, 正文改成该工具功能的一句话, 例如 `刷新商店` / `花钱刷新商店`.

左侧的弹窗比右侧窄: 换行宽度单独设得更小 (4.4 游戏单位, 右侧 5.2), 标题超过 12 字截断, 框宽跟着内容走
(右侧沿用原版那种固定很宽, 只露出内容的做法), 所以它在水平方向不会拉长.

- 工具真正执行时记一条 (前面有讲解还没退去就等退去再弹, 与动作同时出现), 含手册查询 (docs_* / lookup) 与内置 loop 的本地调用; 两种模式 (内置与 `just agent-call`) 都有.
- 不上左侧的: `notify` (它自己在右侧弹), 只读的 `health` / `gamestate` / `screenshot`, `save` / `load` /
  `set` / `add`, 以及内置 loop 自己做的自动步骤 (`continue`, `cash_out`, `menu`, `endless`).
- 左侧只按参数记录, 不拦后面的操作; 停留时长按字数估, 比右侧的解说短.
- 游戏内回放时两侧都重现 (讲解与工具调用记录都是回放内容的一部分, 不受设置页开关影响).
- 消息节奏 (设置页, 以及 agent 运行时右上角 HUD): 阅读按阅读时长等讲解退去;
  快速几乎不等, 不拦后面的操作, 框停留约 1.5 秒, 新的叠在上面.
  回放进行时用回放自己的节奏, 结束后恢复这里的档位.

右侧的来源:

- 任意方法的 `params` 里加 `reason` 字符串, 标题显示为操作的中文名 (出牌, 购买等), 交给方法前会去掉,
  不影响原有参数. 它和 `notify` 一样算讲解: 先进队显示, 这个请求等它退去才执行, 效果等于先 `notify`
  再操作, 所以不必为同一步另发一条 `notify`. 只读方法与 `start` / `menu` 不等, `reason` 与动作同时出现.
- `notify {"message", "title"?, "duration"?, "wait"?}` 单独发一条消息, 任何状态都能用. `title` 默认 `Agent`.
  `duration` 为阅读秒数, 默认按字数估算 (中文每字约 0.18 秒), 读完后再停留 2 秒才滑出.
  `wait` 默认 `false`: 显示交给通知自己 (见下), 请求立刻返回. 传 `true` 则等这条读完再返回.
  关掉消息显示时立即返回 (消息不显示, 也没有要等的讲解).
- 一条条显示: 有消息正在显示时新的排队等着, 前一条退场时下一条才滑入.
- 讲解还没退去时, 后面的请求要等它退去才生效 (挂在 `BB_DISPATCHER.dispatch` 上), 这样观众总是先看到
  文字再看到动作. 等的是"自己那条", 也就是该请求之前最后发出的一条讲解, 队列先进先出, 等它等于等前面
  的都退去.
  - 不等的方法: 只读的 (`gamestate`, `health`, `screenshot`, 手册查询 `docs_*` / `lookup`) 与
    `start` / `menu`. `notify` 不是只读, 它也要等前一条讲解退去, 所以消息一条条出现.
  - 等的时候请求已经发出去了, 只是响应来得晚 (最长等一条讲解读完加停留再加滑出; 正常一两条约 10~40 秒).
    阶段在等待期间变了的话不执行, 直接返回 `INVALID_STATE`.

```shell
just agent-call notify '{"message":"手里 4 张红桃, 牌堆还剩 9 张红桃, 弃牌还有 2 次","title":"观察"}'
just agent-call discard '{"cards":[0,3,5],"reason":"弃 3 张杂牌追同花, 抽 3 张至少来 1 张红桃约 6 成"}'
```

解说的内容与节奏见 [agent-commentary.md](agent-commentary.md).

消息最多显示 12 行, 约 180 个汉字或 300 个英文字符, 超出截断. 不想看消息时在 Config 页关掉
Show Agent Messages (右侧) 与 Show Tool Calls (左侧), 见 [builtin-agent.md](<builtin-agent.md>) 的设置页一节.

## 录制

`run-agent` 在 Windows 与 macOS 上默认都按局录制, 每局输出一份带声音的视频和一份时间线 JSON,
不需要另外设置. 两个平台的参数相同:

```shell
just windows run-agent         # 录制, 正常速度
just windows run-agent off     # 不录制
just windows run-agent on 1    # 10 倍速, 仅在需要时使用
just macos run-agent           # macOS 使用同样的参数
```

一局的产物都放在 `recordings/<开始时间>-<种子>/` 里, 文件名仍带这一局的前缀:

| 文件 | 内容 |
| --- | --- |
| `<开始时间>-<种子>-full.mp4` | 视频, 与实际时长相同, 保留 agent 思考的时间 |
| `<开始时间>-<种子>.json` | 关键时间点 (视频里的时间) |
| `<开始时间>-<种子>.replay.json` | 回放文件, 见下方 "回放" |
| `<开始时间>-<种子>-agent.jsonl` | 内置 agent 的转录, 只在内置模式下有 |

- 一局从开局 (或读档) 开始, 到回主菜单, 开下一局或退出为止. 游戏结束后停留在结算界面的部分也会录.
- 输出在仓库根目录的 `recordings/`. 一局一个文件夹, 上面表格里的名字都是文件夹内的相对路径.
  视频在局末由后台进程合成, 画面直接复制, 一般几秒, 游戏可以继续玩或退出.
  ffmpeg 的报错在同名 `.ffmpeg.txt`. 每次启动的游戏日志 (含崩溃信息) 在 `recordings/<启动时间>-game.log`.
- 录制中只写中间文件: `.video.mp4` (约 2 秒一个分片, 写完即落盘), `.pcm` (每秒落盘) 和合成脚本 `.post.sh`
  (Windows 上是 `.post.cmd`).
  脚本开局时就写出, 局末换成最终版并运行, 成功后删除中间文件.
- 游戏崩溃时画面最多丢约 2 秒, 声音约 1 秒. `just windows recordings-recover` 或
  `just macos recordings-recover` 列出残留的局, 加 `--run` 补做合成,
  再加 `--clean` 在成功后删除中间文件.
  游戏在运行时, 中间文件 30 秒内还在变化的局会跳过. 局末合成失败时同样保留中间文件, 用同一条命令或
  `sh <文件名>.post.sh` (Windows 上直接运行 `<文件名>.post.cmd`) 重跑.
- 画面与屏幕一致, 包括 CRT 效果和决策消息. fast 模式录到的就是加速后的画面.
- 声音按游戏发给声音线程的指令另外混出, 与画面同步, 与实际听到的基本一致. 不跟随 Options 里的总音量,
  静音玩时录像仍有声音; 音乐与音效各自的音量照常生效.
- 需要 ffmpeg, 找不到时只写 JSON. macOS 上默认用 videotoolbox 硬件编码, 对游戏帧率影响很小.
- Android 上没有 ffmpeg, 改用系统的 MediaCodec 硬件编码 (取不到硬件编码器时退回软件编码器),
  默认 540p 24fps. 录制中写 `.video.mp4`, 局末封装成功后改名成同样的 `<开始时间>-<种子>-full.mp4`.
  目前**没有音轨**, 而且中途崩溃会丢掉这一局的视频 (moov 在收尾时才落盘, 留下的
  `.video.mp4` 播不了). 细节与实现要点见
  [recording.md](<recording.md>) 的 "Android" 一节.

`run-agent` 已经设好下面的变量. 表格供直接启动应用或调参时参考:

| 环境变量 | 默认 | 作用 |
| --- | --- | --- |
| `BALATROBOT_RECORD_VIDEO` | 设置页的值, 默认关闭 | `on` 开启视频与时间轴录制 |
| `BALATROBOT_RECORD_REPLAY` | 设置页的值, 默认关闭 | `on` 开启回放文件录制, 不依赖视频 |
| `BALATROBOT_RECORD_DIR` | `<存档目录>/recordings` | 输出目录, `run-agent` 设为 `recordings/` |
| `BALATROBOT_RECORD_FPS` | 设置页的值, 默认 30 | 视频帧率 |
| `BALATROBOT_RECORD_HEIGHT` | 设置页的值, 默认 720 | 视频高度, 宽度按窗口比例 |
| `BALATROBOT_RECORD_BITRATE` | 设置页的值, 默认自动 | 视频码率 (Mbps, 可带小数), 0 为自动 (固定画质, 体积随画面变化) |
| `BALATROBOT_RECORD_CODEC` | 自动 | `videotoolbox` 或 `x264`; x264 更省体积, 但占 CPU, 动画多时游戏会掉帧 |
| `BALATROBOT_RECORD_KEEP` | `skip` | `keep` 时合成成功也保留中间文件, 供事后重跑 |
| `BALATROBOT_RECORD_PREFIX` | 空 | 输出文件名前缀, 回放时为 `replay-` |
| `BALATROBOT_FFMPEG` | 自动查找 | ffmpeg 路径 |

录像由 bbreplay 负责, 设置在 模组 -> BB Replay -> 配置. 设置页的 "保留方式" 与 `BALATROBOT_RECORD_KEEP` 对应: `skip` 在局末合成成功后删掉 `.video.mp4` 与 `.pcm`,
`keep` 留着只删脚本自身 (想事后重跑时有用). 合成失败时无论哪种都保留中间文件.
视频与回放文件在设置页分别由 `record_video` 与 `record_replay` 控制, 环境变量也分别覆盖.
视频关闭时结束当前录像段, 回放文件关闭时保存当前记录, 再次开启从下一局起录制.
`run-agent` 的录制参数默认同时设置两者, 可以单独设 `BALATROBOT_RECORD_REPLAY=on/off` 覆盖回放文件开关.

JSON 的时间都是秒. `wall` 为开局起的实际时间, 即视频里的时间:

```json
{
  "version": 3, "fps": 30, "size": [1280, 720], "audio": true,
  "videos": {"full": "....-full.mp4"},
  "deck": "Red Deck", "stake": 1, "seed": "AUDIO1", "seeded": true, "resumed": false,
  "result": {"reason": "menu", "won": false, "ante": 1, "round": 1},
  "duration": 58.567,
  "events": [
    {"wall": 0, "kind": "run_start", "resumed": false},
    {"wall": 2.22, "kind": "action", "method": "select", "reason": "小盲注", "ok": true, "wall_end": 5.202},
    {"wall": 5.192, "kind": "blind", "key": "bl_small", "name": "Small Blind", "round": 1},
    {"wall": 25.252, "kind": "action", "method": "play", "reason": "出五张", "ok": true, "wall_end": 33.685}
  ]
}
```

| 字段 | 含义 |
| --- | --- |
| `duration` | 视频时长, 录制结束时写入 (崩溃留下的 JSON 没有) |
| `result.reason` | 结束原因: `menu`, `restart` (开了下一局), `quit`, `agent_user` / `agent_error` (内置 agent 被停止 / 出错停止), `replay` (游戏内回放结束), `disabled` (录像被关掉) |
| `result.paused` | 暂停中结束时为 true |
| `pause`, `resume` | 内置 agent 暂停与恢复, 带 `reason` |
| `action` | agent 的操作, `wall_end` 为操作完成的时间, 失败时带 `error` |
| `message` | `notify` 发的消息 (`reason` 已记在对应的 `action` 里) |
| `blind` | 进入盲注 |
| `state` | 进入选盲注, 结算, 商店, 卡包等状态, 带 `ante`, `round`, `money` |
| `game_over`, `won`, `run_end` | 游戏结束, 打过第 8 底注, 录制结束 |
| `run_start` | 录制开始. 同一局里重新开一段时带 `reason` |

## 回放

开启回放文件录制时每局写一份 `<开始时间>-<种子>.replay.json`, 不依赖视频录制, 记下开局参数, 开局那一刻的存档进度,
agent 的每一步操作 (含讲解), 以及内置 agent 的模型输出 (第一个字和结束的时间). 回放在真实游戏里
按顺序重做这些操作, 画面和声音都由游戏自己产生; 顶部流式条按这段时间的平均字速滚输出. 节奏有三种:
original (原速) 与原局思考时间对齐; tight (紧凑) 把这段输出压进两步之间的短等待, 讲解退去更快;
fast (快进) 间隔同 tight, 不等讲解读完就做下一步, 讲解仍会弹出并停留约 1.5 秒, 新的叠在上面.

游戏内回放: 主菜单的 选项 (手机上是 "选项") -> 回放, 选一行进确认页, 选节奏和是否录像后开始.
按钮只在主菜单出现, 与 agent 模式无关; 内置 agent 运行中时不可用. 右上角可暂停, 切换节奏
(原速 -> 紧凑 -> 快进 循环) 或中止. 中止是按住 Esc 或手柄 back 1 秒 (触摸长按屏幕 1.5 秒), 按住期间顶部
显示进度. 结束时显示结果 (完成 / 在第 N 步跑偏 / 已中止), 回到主菜单, 并把存档进度和设置恢复成
开始前的样子.

命令行回放从启动开始, 录制成 `recordings/replay-*` 的视频:

```shell
just macos replay recordings/<stem>            # tight: 去掉 agent 思考的时间
just macos replay recordings/<stem> original   # original: 按原局的实际间隔
just macos replay recordings/<stem> fast       # fast: 间隔同 tight, 不等讲解读完
```

参数是这一局的文件夹 (也可以给里面的 `.replay.json`); 这一局的回放录成 `recordings/replay-*` 的新文件夹.

- 开局前恢复原局的解锁, 发现, 累计数据和画面设置, 否则同一个种子也会抽出不同的牌. 命令行回放用临时
  存档 `Balatro-Replay` 隔离; 游戏内回放改成拦截写入: 回放期间丢掉 `G.SAVE_MANAGER.channel` 上的
  存档请求和主线程直接调用的 `compress_and_save`, 所以磁盘上的存档, 进度和设置都不会被改动.
  结束后用 `load_profile` 从磁盘读回当前档位, 再按开始前的快照恢复解锁与设置.
- 原局没指定种子时, 回放用同一个种子开局后恢复为 "未指定种子" 的状态.
- 回放期间锁定鼠标, 键盘和手柄, 游戏读到的光标停在左上角的空白处; 系统鼠标指针照常显示, 只是点了没反应.
- 命令行回放时讲解照常显示并按阅读时长等待, 不受 balatrobot 设置页 "显示 agent 消息" 的影响; 游戏内回放沿用这个开关.
  回放里关掉讲解门槛 (`BB_TOAST.gate_enabled`): 原局的操作是在讲解停留期间就执行的, 回放照原样重做, 不再被拦一次.
  tight 节奏下右侧消息改用更短的阅读与停留; 工具调用那条左侧无论哪种节奏都用短时长.
- 弹窗停留后再关: 解锁通知停 2.5 秒, 胜利界面在 Jimbo 出现后停 3 秒, 游戏结束界面停 3 秒;
  original 节奏下取原局的停留时长. 原局里关过的解锁通知回放时没弹出就跳过, 多出的同样停留后关掉.
- 人手动的操作也会记成步骤, 回放时照做: 出牌, 弃牌, 选或跳过盲注, 刷新商店, 结算, 离开商店, 购买,
  使用, 出售, 跳过卡包, 重掷 Boss, 理牌, 拖动排序, 以及胜利界面上点 "无尽模式", 局内回主菜单. 原局里有手动操作时回放开始前仍会提示
  结果可能不同 (换算不到的操作不会重做). 构建版本或 mod 版本不一致时同样提示.
- 每步完成后比对状态摘要 (状态, 底注, 回合, 金钱, 牌堆张数, 手牌, 小丑, 消耗牌, 商店, 卡包的顺序与修饰),
  2 秒内仍不一致就停止回放, 游戏日志记下哪一项不同, 录像保留到这里.
- 退出码 (仅命令行): 0 回放完成, 1 跑偏或超时, 2 中止, 3 回放文件无法使用. 游戏内以同样的数字作为
  结果回调给界面. 回放录像的时间线 JSON 里 `replay` 字段记着来源, 节奏和结果.
- 读档开局的回放会把存档写成一个临时文件交给 `load`, 用完即删.
- 不支持挑战模式和非原版牌组. 原局里的 `save` 不会重做. 回放自己不再写回放文件.
- 游戏内回放选了录像时按 `replay-` 前缀输出, 与命令行回放一致; 结束或回滚后恢复原来的录像设置.

可调的停留时长:

| 环境变量 | 默认 | 作用 |
| --- | --- | --- |
| `BALATROBOT_REPLAY_UNLOCK_HOLD` | 2.5 | 解锁通知的停留秒数 |
| `BALATROBOT_REPLAY_WIN_HOLD` | 3 | 胜利界面 Jimbo 出现后, 游戏结束界面的停留秒数 |
| `BALATROBOT_REPLAY_END_HOLD` | 3 | 最后一步之后的停留秒数 |
| `BALATROBOT_REPLAY_GAP` | 0.35 | tight 节奏下动画停下后再等的秒数 |

## 错误

```json
{"jsonrpc":"2.0","error":{"code":-32002,"message":"...","data":{"name":"INVALID_STATE"}},"id":1}
```

| 名称 | 代码 | 含义 |
| --- | --- | --- |
| `INTERNAL_ERROR` | -32000 | 执行时出错 |
| `BAD_REQUEST` | -32001 | 参数不对, 例如下标越界 |
| `INVALID_STATE` | -32002 | 当前状态不能执行这个方法 |
| `NOT_ALLOWED` | -32003 | 游戏规则不允许, 例如钱不够 |

## 与 upstream 的区别

upstream 是一个 mod, 这里拆成三个 (见 [modding.md](<modding.md>) 的内置 mod 一节): 端点, dispatcher,
gamestate 等 upstream 的公共代码搬进 `mods/bbcore/src/lua/`; HTTP 服务 (`src/lua/core/server.lua`) 留在
balatrobot; 录像与回放在 bbreplay. 改写了 balatrobot 的入口 `balatrobot.lua`, 新增了 `config.lua` 和 `agent/`
目录 (设置, 存档迁移, 内置 agent, 手册查询), 另有兼容性修复, upstream 的其余文件内容保持 v1.5.2 原样:

- upstream 一加载就开端口并修改游戏设置. 这里改为默认关闭, 由开关或环境变量启用.
- 游戏内开关只启停 HTTP 服务, 不执行 upstream 的设置调整.
- upstream 的设置调整会跳过开场动画, 关 CRT/bloom/阴影, 静音, 4 倍速, 并写进存档. 这里不再调用它,
  见上方环境变量表. 存档里 `skip_splash` 为 `Yes` 时 (原版游戏没有这个选项, 只可能是早期版本写的),
  启动时把这些设置恢复为原版默认值.
- 跳过教程保留: 全新存档里教程进度要等第一帧才创建, 入口里提前把教程标记为完成.
- bbcore 的 `src/lua/settings.lua` 末尾导出了 headless 等函数供 balatrobot 的 `agent/settings.lua` 调用.
- upstream 的 dispatcher 直接把结果交给 HTTP 服务. 这里交给 bbcore 的 `BB_TRANSPORT`, HTTP 服务, 内置 loop
  与回放都从这里取结果.
- 新增 `notify` 方法和各方法的 `reason` 参数, `rpc.discover` 返回的描述里也有.
- upstream 在弹窗打开时仍然执行操作. 胜利界面下直接 `cash_out` 进商店后, 再点 "无尽模式" 会让停着的
  结算事件访问已移除的 `G.round_eval` 而崩溃. 现在弹窗打开时拦截操作, 并新增 `endless` 方法和 `overlay` 字段.
- upstream 的服务端一次只处理一个请求, 请求等待中弹出解锁通知时会一直占着连接. 现在这种情况先返回,
  并新增 `continue` 方法. 连接断开后才完成的请求, 结果不会再发到下一个连接上.
- `endpoints/start.lua`: smods 26.x 默认的开局界面不创建 `G.GAME.viewed_back`, upstream
  直接调用它会报错, 改为缺失时创建.
- upstream 用 lovely 注入并通过自带的 `balatrobot serve` 启动游戏. 本仓库不需要这个 python 包,
  直接启动 mod 版应用即可.

## 其他平台

Windows 与 Android 的 mod 版也带着这个 mod, 默认关闭, 不影响正常游玩. 这两个平台的 agent 接口尚未验证.
录制在 macOS 上验证过; Android 用 MediaCodec, Windows 用 ffmpeg (需要另装), 细节见 [recording.md](<recording.md>):

- Windows: 在游戏内打开开关, 或者设置环境变量 `BALATROBOT_ENABLE=1` 后运行 `Balatro.exe`.
- Android: 在游戏内打开开关, 再用 `adb forward tcp:12346 tcp:12346` 把端口转发到电脑.
