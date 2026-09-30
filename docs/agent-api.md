# Agent 游玩接口

带 mod 的版本内置 [balatrobot](https://github.com/coder/balatrobot) v1.5.2. 它在游戏里开一个
JSON-RPC 2.0 over HTTP 接口, 外部程序 (agent, 脚本) 可以读取完整游戏状态并操作游戏.
接口默认关闭.

## 开启

| 方式 | 做法 | 存档 | 游戏设置 |
| --- | --- | --- | --- |
| 终端启动 | `just macos run-agent`, 默认正常速度并录像, 见下方 "录制" | 独立的 `Balatro-Agent` 目录 | 跳过教程, 其余沿用存档 |
| 游戏内开关 | Mods > BalatroBot > Config, 打开 Enable Agent API | 当前存档 | 不改 |

- 游戏内开关可以随时切换, 状态保存在存档目录的 `config/balatrobot.jkr`, 下次启动沿用.
- 配置页会显示监听地址和状态 (`listening` / `off` / `bind failed`), 还有决策消息的开关和录制状态.
- 终端启动时, 开关界面仍显示存档里保存的值, 实际状态以 Status 为准.
- 终端启动时画面, 开场动画, 声音, 游戏速度都沿用存档, 与正常游玩一样. 下面的环境变量只在本次运行
  生效, 不会写回存档:

| 环境变量 | 作用 |
| --- | --- |
| `BALATROBOT_FAST=1` | 10 倍速, 动画 60fps, 不限帧率, 关 vsync (`run-agent skip 1` 即此项) |
| `BALATROBOT_HEADLESS=1` | 不显示窗口, 跳过开场动画 |
| `BALATROBOT_AUDIO=1` | 强制开声音, 不设时沿用存档音量 |
| `BALATROBOT_GAMESPEED`, `BALATROBOT_FPS_CAP`, `BALATROBOT_ANIMATION_FPS` | 显式设置时覆盖 |
| `BALATROBOT_PORT`, `BALATROBOT_HOST`, `BALATROBOT_RENDER_ON_API`, `BALATROBOT_NO_SHADERS` | 与 upstream 相同, 见 `mods/balatrobot/src/lua/settings.lua` 文件头 |

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

- 调用 `rpc.discover` 取得 OpenRPC 描述, 基于 `mods/balatrobot/src/lua/utils/openrpc.json`, 加上本仓库新增的 `notify` 与 `reason`.
- upstream 文档: <https://coder.github.io/balatrobot/api/>

## 决策消息

agent 的决策可以以原版成就通知的样式显示在游戏右侧: 黑底灰边, 从屏幕外滑入, 停留几秒后滑出.
最多同时显示 3 条, 新的在上面. 中文会自动换用带中文字形的字体. 录制时也会录进视频.

- 任意方法的 `params` 里加 `reason` 字符串, 标题显示为操作的中文名 (出牌, 购买等), 交给方法前会去掉,
  不影响原有参数.
- `notify {"message", "title"?, "duration"?, "wait"?}` 单独发一条消息, 任何状态都能用. `title` 默认 `Agent`.
  `duration` 为阅读秒数, 默认按字数估算 (中文每字约 0.18 秒, 2.5~12 秒), 读完后再停留 2 秒才滑出.
  `wait` 默认 `true`: 等阅读时长过去才返回, 连续调用时消息一条接一条出现. 关掉消息显示时立即返回.

```shell
just agent-call notify '{"message":"手里 4 张红桃, 牌堆还剩 9 张红桃, 弃 3 张追同花","title":"弃牌"}'
just agent-call discard '{"cards":[0,3,5],"reason":"弃 3 张杂牌追同花"}'
```

解说的内容与节奏见 [agent-commentary.md](agent-commentary.md).

消息最长 200 字符, 超出截断. 不想看消息时在 Config 页关掉 Show Agent Messages.

## 录制

`just macos run-agent` 默认就按局录制 mp4 和标记关键时间点的 JSON, 不需要另外设置:

```shell
just macos run-agent          # 默认 skip: 剪掉 agent 思考的等待时间, 正常速度
just macos run-agent keep     # keep: 保留等待时间, 视频时长等于实际时长
just macos run-agent off      # 不录制
just macos run-agent skip 1   # 10 倍速, 仅在需要时使用
```

- 一局从开局 (或读档) 开始, 到回主菜单, 开下一局或退出为止. 游戏结束后停留在结算界面的部分也会录.
- 输出在仓库根目录的 `recordings/`, 文件名为 `<开始时间>-<种子>.mp4/.json`, ffmpeg 的报错在同名 `.ffmpeg.txt`.
  每次启动的游戏日志 (含崩溃信息) 在 `recordings/<启动时间>-game.log`.
- 等待的判定: agent 没有请求在处理, 上次响应后超过 0.8 秒, 屏幕上也没有决策消息. 只查询状态和截图的
  请求 (`gamestate`, `health`, `screenshot`, `rpc.discover`) 不算活动.
- skip 模式只看 agent 的请求, 人手动玩时会被当成等待剪掉, 手动玩请用 keep.
- 画面与屏幕一致, 包括 CRT 效果和决策消息. 不录声音. fast 模式录到的就是加速后的画面.
- 需要 ffmpeg, 找不到时只写 JSON. macOS 上默认用 videotoolbox 硬件编码, 对游戏帧率影响很小.

`run-agent` 已经设好下面的变量. 表格供直接启动应用或调参时参考:

| 环境变量 | 默认 | 作用 |
| --- | --- | --- |
| `BALATROBOT_RECORD` | 关闭 | `skip` 或 `keep` |
| `BALATROBOT_RECORD_DIR` | `<存档目录>/recordings` | 输出目录, `run-agent` 设为 `recordings/` |
| `BALATROBOT_RECORD_FPS` | 30 | 视频帧率 |
| `BALATROBOT_RECORD_HEIGHT` | 720 | 视频高度, 宽度按窗口比例 |
| `BALATROBOT_RECORD_HOLD` | 0.8 | 响应后仍算活动的秒数 |
| `BALATROBOT_RECORD_CODEC` | 自动 | `videotoolbox` 或 `x264`; x264 更省体积, 但占 CPU, 动画多时游戏会掉帧 |
| `BALATROBOT_FFMPEG` | 自动查找 | ffmpeg 路径 |

JSON 的时间都是秒, `t` 为视频时间, `wall` 为开局起的实际时间:

```json
{
  "version": 1, "mode": "skip", "fps": 30, "size": [1152, 720], "video": "....mp4",
  "deck": "Red Deck", "stake": 1, "seed": "AGENTREC", "seeded": true, "resumed": false,
  "result": {"reason": "menu", "won": false, "ante": 1, "round": 1},
  "duration": {"video": 35.7, "wall": 135.6, "waited": 99.4},
  "gaps": [{"video_start": 9.567, "video_end": 9.567, "wall_seconds": 43.9}],
  "events": [
    {"t": 0, "wall": 0, "kind": "run_start", "resumed": false},
    {"t": 3.2, "wall": 11.3, "kind": "action", "method": "select", "reason": "选择小盲注", "ok": true, "t_end": 6.9},
    {"t": 6.9, "wall": 15.1, "kind": "blind", "key": "bl_small", "name": "Small Blind", "round": 1},
    {"t": 9.6, "wall": 61.8, "kind": "message", "title": "思考", "text": "..."}
  ]
}
```

| 字段 | 含义 |
| --- | --- |
| `gaps` | agent 的等待段. skip 模式下 `video_start == video_end`, 是视频里的剪辑点; keep 模式下是视频里的一段 |
| `duration.waited` | 等待段的实际总时长 |
| `result.reason` | 结束原因: `menu`, `restart` (开了下一局), `quit` |
| `action` | agent 的操作, `t_end` 为操作完成的时间, 失败时带 `error` |
| `message` | `notify` 发的消息 (`reason` 已记在对应的 `action` 里) |
| `blind` | 进入盲注 |
| `state` | 进入选盲注, 结算, 商店, 卡包等状态, 带 `ante`, `round`, `money` |
| `game_over`, `won`, `run_end` | 游戏结束, 打过第 8 底注, 录制结束 |

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

改写了入口 `mods/balatrobot/balatrobot.lua`, 新增了 `config.lua` 和 `agent/` 目录 (设置, 存档迁移,
决策消息, 录制), 另有兼容性修复, 其余文件保持 v1.5.2 原样:

- upstream 一加载就开端口并修改游戏设置. 这里改为默认关闭, 由开关或环境变量启用.
- 游戏内开关只启停 HTTP 服务, 不执行 upstream 的设置调整.
- upstream 的设置调整会跳过开场动画, 关 CRT/bloom/阴影, 静音, 4 倍速, 并写进存档. 这里不再调用它,
  见上方环境变量表. 存档里 `skip_splash` 为 `Yes` 时 (1.0.1n 没有这个选项, 只可能是早期版本写的),
  启动时把这些设置恢复为原版默认值.
- 跳过教程保留: 全新存档里教程进度要等第一帧才创建, 入口里提前把教程标记为完成.
- `src/lua/settings.lua` 末尾导出了 headless 等函数供 `agent/settings.lua` 调用.
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

Windows 与 Android 的 mod 版也带着这个 mod, 默认关闭, 不影响正常游玩. 这两个平台尚未验证,
录制只在 macOS 上实现与验证过:

- Windows: 在游戏内打开开关, 或者设置环境变量 `BALATROBOT_ENABLE=1` 后运行 `Balatro.exe`.
- Android: 在游戏内打开开关, 再用 `adb forward tcp:12346 tcp:12346` 把端口转发到电脑.
