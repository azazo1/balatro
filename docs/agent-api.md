# Agent 游玩接口

带 mod 的版本内置 [balatrobot](https://github.com/coder/balatrobot) v1.5.2. 它在游戏里开一个
JSON-RPC 2.0 over HTTP 接口, 外部程序 (agent, 脚本) 可以读取完整游戏状态并操作游戏.
接口默认关闭.

## 开启

| 方式 | 做法 | 存档 | 游戏设置 |
| --- | --- | --- | --- |
| 终端启动 | `just macos run-agent`, 加速运行用 `just macos run-agent 1` | 独立的 `Balatro-Agent` 目录 | 按 upstream 静音, 加速, 关 CRT, 跳过教程 |
| 游戏内开关 | Mods > BalatroBot > Config, 打开 Enable Agent API | 当前存档 | 不改 |

- 游戏内开关可以随时切换, 状态保存在存档目录的 `config/balatrobot.jkr`, 下次启动沿用.
- 配置页会显示监听地址和状态 (`listening` / `off` / `bind failed`).
- 终端启动时, 开关界面仍显示存档里保存的值, 实际状态以 Status 为准.
- 终端启动还支持 upstream 的其他环境变量, 例如 `BALATROBOT_PORT`, `BALATROBOT_HEADLESS`,
  `BALATROBOT_RENDER_ON_API`, 完整列表见 `mods/balatrobot/src/lua/settings.lua` 文件头.

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
- 所有下标都从 0 开始, 对应 `gamestate` 里各区域 `cards` 数组的顺序.
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

| 状态 | 常用方法 |
| --- | --- |
| `MENU` | `start {"deck","stake","seed"?}` |
| `BLIND_SELECT` | `select`, `skip` (Boss 不能跳过) |
| `SELECTING_HAND` | `play {"cards"}`, `discard {"cards"}`, `rearrange {"hand"}` |
| `ROUND_EVAL` | `cash_out` |
| `SHOP` | `buy {"card"或"voucher"或"pack"}`, `reroll`, `sell {"joker"或"consumable"}`, `next_round` |
| `SMODS_BOOSTER_OPENED` | `pack {"card","targets"?}` 或 `pack {"skip":true}` |
| 任意 | `gamestate`, `health`, `use {"consumable","cards"?}`, `rearrange`, `menu`, `save`/`load {"path"}`, `screenshot {"path"}` |

`set` 和 `add` 可以直接改金钱, 盲注分数, 添加卡牌, 用于调试, 正常游玩不要用.
`save`, `load`, `screenshot` 的 `path` 是本机的绝对路径.

完整的参数和返回结构:

- 调用 `rpc.discover` 取得 OpenRPC 描述, 内容与 `mods/balatrobot/src/lua/utils/openrpc.json` 相同.
- upstream 文档: <https://coder.github.io/balatrobot/api/>

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

只改写了入口 `mods/balatrobot/balatrobot.lua`, 新增了 `config.lua`, 其余文件保持 v1.5.2 原样:

- upstream 一加载就开端口并修改游戏设置. 这里改为默认关闭, 由开关或环境变量启用.
- 游戏内开关只启停 HTTP 服务, 不执行 upstream 的设置调整.
- upstream 用 lovely 注入并通过自带的 `balatrobot serve` 启动游戏. 本仓库不需要这个 python 包,
  直接启动 mod 版应用即可.

## 其他平台

Windows 与 Android 的 mod 版也带着这个 mod, 默认关闭, 不影响正常游玩. 这两个平台尚未验证:

- Windows: 在游戏内打开开关, 或者设置环境变量 `BALATROBOT_ENABLE=1` 后运行 `Balatro.exe`.
- Android: 在游戏内打开开关, 再用 `adb forward tcp:12346 tcp:12346` 把端口转发到电脑.
