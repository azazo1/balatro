# 内置 agent

游戏内自带 agent loop: 在设置页填好 chat completions 的 endpoint, key 和模型名, agent 就在游戏里自动玩. 模型的思考过程以一行流式文字显示在画面顶部, 观众能看出模型正在思考, 不会把长时间静止误认为游戏卡死. 本文是需求与实现方案, 已实现的接口说明见 [agent-api.md](<agent-api.md>).

## 目标

- 只需配置 endpoint, key 和模型名, 不依赖外置 agent 框架.
- 思考流实时显示. 目标是让观众知道模型在工作, 不要求每个字都看得清.
- 游戏内可以随时暂停, 停止, 切换模式, 防止失控.
- 录像及时落盘, 崩溃时尽量少丢.
- Android 上整个流程都能用触摸完成. 存档, 配置和录像全部放在外部存储 (`Android/data/...`).
- 现有的外部 agent 用法 (`just agent-call`) 保持不变, 和内置 agent 互斥.
- 在游戏内浏览录下的回放文件并回放, 不需要命令行. Android 上同样能用.

## 总体结构

| 部分 | 语言 | 负责 |
|---|---|---|
| mod 本体 | Lua | agent loop, 执行动作, 设置页, Agent 面板, 流式条, 手册查询, 回放列表 |
| `bbnet` | Rust, 编译为 cdylib | HTTPS 流式请求, SSE 分帧, Android 上的录像编码 |

只把网络放进原生库, 原因是游戏里的 Lua 发不出 HTTPS 流式请求:

- LÖVE 自带的 socket 不支持 TLS.
- Steamodded 的 `SMODS.https` 要等整个响应收完才返回, 而且在 Android 上没有可用的后端.

loop 留在 Lua 里, 因为动作本来就在游戏的 Lua 里执行, 调用动作就是普通的函数调用. 如果把 loop 也放进原生库, 每次动作都要在 FFI 两侧往返传一次, 等于在进程内部又搭一套 RPC.

## agent 模式

设置页里有一个单选 "agent 模式", 三个选项互斥:

| 模式 | 行为 |
|---|---|
| 关闭 | 不监听端口, 不运行 loop |
| 外部 | 和现在一样, HTTP 服务监听端口, 由 `just agent-call` 控制. 没有思考流, 流式条不出现 |
| 内置 | 游戏自己运行 loop, HTTP 端口不监听 |

- 外部和内置之间不能直接切换, 必须先切到关闭. 内置 loop 运行中时, 先停止才能切换.
- 用 `just macos run-agent` 启动时, 由环境变量锁定为外部模式, 设置页的其他选项变灰并注明原因.
- 以内置模式启动的 recipe 另加一个, 复用 run-agent 的录像和日志逻辑.
- 游戏内回放进行时: 内置 loop 不能开始; 外部模式暂停监听, 回放结束后恢复. 见 [游戏内回放](#游戏内回放).
- 两种模式共用 dispatcher, 动作, 手册查询和解说. 区别只在调用方式: 外部 agent 经 HTTP 调用, 内置 loop 在进程内直接调用. 为此 dispatcher 的响应要能交给本地接收方, 而不只是交给 `Server.send_response`.

## 设置页

入口是 模组 → balatrobot, 即 mod 的 `config_tab`. 主菜单和局内 ESC 菜单都能进.

内容:

- agent 模式.
- 内置模式的配置: endpoint, 模型名, 鉴权方式 (Bearer 或 `x-api-key`, 默认 Bearer), key.
- 录像: 开关, 保留方式 (skip/keep), 分辨率和帧率. Android 没有环境变量, 只能在这里设置. 桌面端设置了 `BALATROBOT_RECORD*` 环境变量时以环境变量为准.
- 防失控: 单局 token 上限, 默认不限.
- 状态行: 外部模式显示监听地址, 内置模式显示 loop 状态和最近一次错误.
- 原有的消息显示开关.

输入: 原版文本框的字符表里没有 `/`, 并且会把 `0` 改成 `o`, URL 和 key 输不进去. 因此 endpoint, key 和模型名都用 "从剪贴板粘贴" 按钮输入, 读取 `love.system.getClipboardText()`. key 在界面上只显示掩码.

存储: 配置存在存档目录下的 mod 配置里, 带版本号, 迁移放在 `agent/migrate.lua`. key 是明文, 只存在本机, 不写进日志, 时间轴, 转录和录像画面.

## 运行控制

入口:

| 入口 | 平台 | 作用 |
|---|---|---|
| ESC 菜单的 "Agent" 按钮 | 全部 | 打开 Agent 面板 |
| HUD 左侧的 "选项" 按钮 | 全部, Android 主要靠它 | 打开的就是 ESC 菜单 |
| `F9` | 桌面 | 一键暂停/继续, 用 `SMODS.Keybind` 注册 |

"Agent" 按钮仿照 Steamodded 插入 "模组" 按钮的做法 ([menu.toml](<../mods/Steamodded/lovely/menu.toml>)), 用 lovely 补丁插进 `create_UIBox_options`. 只在内置模式下显示, 颜色跟随状态: 运行中为绿色, 暂停为黄色, 出错为红色.

Agent 面板:

- 状态: 已停止 / 运行中 / 请求中 / 执行动作中 / 等待重试 / 已暂停 / 出错停止.
- 本局统计: 请求次数, token 用量, 最近一次错误.
- 开始: 在主菜单开始时由 agent 自己选牌组开局; 在局内开始时从当前状态接着玩.
- 暂停/继续: 暂停会立刻取消正在进行的请求, 不再执行新动作, 保留对话上下文. 暂停期间可以手动操作游戏. 继续时读取最新状态重新发起请求.
- 停止: 取消请求, 清空上下文, loop 退出, 并立即结束当前录像段开始合成.
- 前往设置.

中断的边界:

- 打开 ESC 菜单时游戏已经暂停. loop 只要看到 `overlay` 不为空就不执行动作. 在路上的请求照常接收, 只是动作要等菜单关闭后才执行; 在面板里点暂停就连请求一起取消.
- 请求可以立即取消: `bbnet_cancel` 从另一个线程直接关闭 socket, 阻塞中的读取马上返回. 读取超时只作为兜底.
- 已经开始执行的动作不能中途打断, 比如出牌动画, 这是游戏事件队列本身的限制. 暂停在这个动作结束后生效, 通常只需要几秒.

防失控: 出现以下任一情况时, loop 自动暂停, 并在流式条上用红字说明原因.

- 连续 5 次调用返回参数错误或状态错误.
- 同一个失败的动作反复重试.
- 单局 token 用量超过设置的上限.

## 流式条

外观: 原版成就通知的样式 (参考 `agent/toast.lua`), 即黑底, 灰描边, 外圈半透明暗边. 位于顶部居中, 只有一行高, 从上方滑入, 收起时滑回屏幕外.

内容:

- 只显示最新输出的尾部, 一行. 增量中的换行替换成空格.
- 按真实字形宽度从右往左截取, 保证最右端始终是最新的字. 宽度用 `toast.lua` 里现成的 `text_width` 测量.
- 缓冲区存成分段列表 `{kind, text}`. 先对全部文字截取可见窗口, 再按分段拆成几个文本节点分别上色. 思维链用灰色 (`G.C.UI.TEXT_INACTIVE`), 正式输出用白色, 同一行里可以同时出现两种颜色.
- 工具调用参数的增量不显示.
- 可以设置每秒最多推进多少字, 让窗口平滑前进. 默认不限速.

渲染: 用 UIBox 的 `ref_table` 文本节点, 文字长度变化时引擎会自动重算布局. 刷新频率限制在每秒 15~20 次. 流式条会经过 CRT 效果, 也会进录像, 和现有的 toast 一致.

出现和收起:

- 没有请求, 或请求已发出但首个 token 还没到: 收起.
- 首个 token 到达: 滑入.
- 请求结束后停留约 1.5 秒再收起. 如果停留期间下一个请求已经开始输出, 就直接换成新内容, 不收起, 免得在执行动作的间隙里反复弹出收起.
- 外部模式下不出现.

报错:

- 请求失败时立刻滑入, 文字变红, 例如 `请求失败: 429 rate limit, 第 2/5 次重试, 3 秒后`, 倒计时实时更新.
- 可重试的错误 (429, 5xx, 连接断开, `server_is_overloaded`, `slow_down`) 按指数退避重试, 间隔 2, 4, 8, 16, 30 秒, 最多 5 次. 流在中途断开时整个请求重发, 已收到的半截输出丢掉.
- 重试成功后清掉红字, 恢复流式显示.
- 不可重试的错误 (401, 额度用尽, 上下文超长), 或重试次数用完: loop 停止, 红字停留约 8 秒后收起. 错误同时写进设置页的状态行.
- 暂停时显示 "已暂停 (F9 继续)" 一两秒后收起.

## agent loop

代码在 `agent/loop/`: `driver.lua` 是主循环, 依赖全部注入, 有单测; `summary.lua`, `tools.lua`, `prompt.lua`,
`history.lua` 是纯逻辑; `local_call.lua` 在进程内调用端点.

每一步:

1. 读取游戏状态. 动画没停, 游戏暂停或人打开了设置等菜单 (`overlay` 为 `other`) 时等待.
2. 能自动处理的直接处理, 不问模型: `unlock` 时调用 `continue`, 结算 (`ROUND_EVAL`) 调用 `cash_out`.
   做了什么以一句说明附在下一轮的状态前面.
3. 其余情况下组装状态摘要和历史, 以流式方式请求模型. 思维链和正文推给流式条.
4. 拿到工具调用后逐个执行, 结果回灌给模型. 动作的结果直接带上新的状态摘要, 下一轮不再重复.
   一个动作失败后, 同一次回复里剩下的调用不执行, 都回 "未执行", 保证每个 tool_call 都有结果.
5. 胜利后按设置进入无尽模式, 或回主菜单并停止; 输了回主菜单并停止.

执行动作不经过 HTTP: `local_call.lua` 直接调用 dispatcher, 并包一层 `send_response` 截获结果.
这样照样经过弹窗拦截与活动追踪, 录像的剪辑和时间线与外部 agent 一致. 内置模式与外部模式互斥, 所以两者不会争抢.

工具: 在 `tools.lua` 里手写一份精简的中文定义, 不从 `rpc.discover` 生成. 那份规格缺少 `pack` 等方法, 描述是英文且偏长.
端点参数变化时要同步修改. 不给模型的方法:

- `gamestate`: 每次结果里已经带状态摘要.
- `cash_out`, `continue`, `endless`: loop 自己处理.
- `menu`, `save`, `load`, `set`, `add`, `screenshot`: 与游玩无关或会破坏进度.

动作工具都带 `reason`, 调用时拆出来作为决策消息. 解说仍按 [agent-commentary.md](<agent-commentary.md>) 使用 `notify` 和 `reason`, 和流式条的思考流分开.

提示与上下文:

- 系统提示 (`prompt.lua`) 是 [手册 README](<game/README.md>) 的 "Agent 必须区分的概念" 和 "每次动作前的规则检查" 两节,
  以及解说规范的压缩版. 那两份文档改动时同步这里.
- 状态摘要 (`summary.lua`): 把 gamestate 转成中文精简文本, 每行开头写下标. 小丑, 消耗牌, 优惠券, 商店与卡包里的牌
  第一次出现时, 从 catalog 取中文名和一句效果附上, 之后只写名字. 整副牌只给张数; 牌型只列出等级高于 1 或打过的.
- 压缩历史 (`history.lua`): 进入新底注的选盲注时, 或估算的上下文超过约 6 万 token 时, 丢掉旧消息, 只留系统提示,
  最近约 40 步的简要记录和当前状态. 只在一轮完整结束的边界上压缩, 不会拆开 tool_calls 和对应的结果.

防失控 (都转为自动暂停, 红字显示原因, 保留历史, 处理后可以继续):

- 模型连续 3 次只回文字不调用工具. 每次先追加一条提醒.
- 同一个调用 (方法和参数都相同) 连续失败 3 次.
- 模型请求出现不可重试的错误, 或重试用完.
- 超过单局 token 上限 (由运行控制按每次请求的用量判断).

暂停时进行中的请求直接取消, 半截回复不进历史. 正在执行的动作做完为止. 继续时重新给一次状态摘要, 因为暂停期间 user 可能手动操作过.

chat completions 协议兼容:

- 推理内容按 `reasoning_content` → `reasoning` → `reasoning_details[].text` 的顺序读取. 都没有时只显示正文. 能拿到什么就显示什么, 模型隐藏思维链时显示它返回的 reasoning summary.
- tool call 按 `index` 累积: `id` 只取第一次出现的值, `name` 和 `arguments` 分段拼接.
- `data: {"error": ...}` 按失败处理. `finish_reason` 或 `[DONE]` 表示结束.
- 回填历史时, 同一条 assistant 消息里同时放 `reasoning_content` 和 `tool_calls`, 只有工具调用时 `content` 为 null. DeepSeek 思考模式下漏回填会返回 400.
- usage 规范化: 缓存命中同时兼容 `prompt_tokens_details.cached_tokens` 和 `prompt_cache_hit_tokens`.

转录与日志:

- 每局写一份 `<录像同名>-agent.jsonl`, 带时间戳, 能和录像的时间轴对上. 不含 key.
- 请求的开始, 结束, 耗时, 重试和错误写进游戏日志.

## 手册查询

范围是 [docs/game/](<game/README.md>) 下的游戏规则和数据, 不包括开发文档. 新增 4 个只读方法, 注册进 dispatcher, 内置 loop 和外部 HTTP agent 都能用, 弹窗期间也允许调用.

| 方法 | 参数 | 返回 |
|---|---|---|
| `docs_index` | 无 | 文件列表 (路径, 标题, 行数) 和 README 的 "按决策查阅" 表 |
| `docs_read` | `path`, 可选 `section` 或 `offset`/`limit` | 带行号的内容 |
| `docs_search` | `query`, 可选 `path`, `limit` | 命中行, 格式为 `路径:行号: 内容`, 默认最多 20 条 |
| `lookup` | `keys`: id, 中文名或英文名的数组 | 每张卡的精简记录, 加上机制文档中提到它的行 |

- `docs_read`:
  - 大文件不带 `section` 或 `offset` 时只返回大纲 (各级标题和行号).
  - `section` 可以写标题文字, 也可以写锚点 id, 比如 `j-blueprint`.
  - 单次上限约 200 行或 8KB, 超出时返回 `next_offset`.
- `lookup`: 返回中文名, 类别, 稀有度, 基价, 中文效果, 能否被蓝图复制. 同时在 `mechanics/` 里搜出提到这个 id 的行, 一次调用就能同时拿到卡面效果和实际机制.
- 链接改写: 文档内的相对链接改写成相对手册根目录的路径, 模型可以直接拿去调用 `docs_read`. 指向手册以外的链接 (源码位置等) 改成纯文本.
- 打包: 生成 mod 时, 把 `docs/game/` 下的 `README.md`, `rules/`, `mechanics/`, `cards/` 和 `data/catalog.json` 复制到 mod 内的 `knowledge/` 目录, 随 mod 发布到所有平台.
- 代码放在 `agent/knowledge/`: `docs.lua` 负责路径校验, 大纲, 章节切分和搜索; `catalog.lua` 在第一次调用时解析 catalog.json 并建立索引, 之后常驻内存.
- 路径只接受手册根目录下的相对路径, 拒绝 `..` 和绝对路径.

## bbnet

依赖只有两个 crate:

- `rustls`: 关掉默认 feature, 只开 `ring`, `std`, `tls12`.
- `webpki-roots`: 打包一份 Mozilla 根证书. Android 上不读系统证书, 所以不需要 JNI.

不用 tokio, hyper, reqwest 和 serde.

网络:

- 手写 HTTP/1.1: 每个请求开一个线程, 用 `std::net::TcpStream`. 支持 chunked, Content-Length 和读到 EOF 三种响应体.
- 同时支持 `http://`, 方便连接本地的 ollama, vLLM.
- 不支持代理和重定向, 3xx 原样交给调用方.
- SSE 分帧放在 Rust 里, 同时认 `\n\n` 和 `\r\n\r\n` 作分隔. JSON 解析交给 Lua, 游戏里已经有 `json` 库.
- 非 2xx 响应照常交出状态码和响应体, 由 Lua 判断是否重试.
- 没有日志设施, 错误信息都以 ERROR 字符串交给调用方, 前缀有 `invalid:`, `resolve:`, `connect:`, `tls:`,
  `timeout`, `read:`, `write:`, `http:`, `cancelled`, `internal:`, `spawn:`.

接口用轮询, 不用回调, 因为 LuaJIT 的 ffi 回调不能从别的线程调用:

```c
// 发起请求, 立即返回句柄 (>0), 参数错误返回 -1. headers 为 "Name: value\n" 拼接的文本, 值里不能有换行.
// timeout_ms 为连接与两次读之间的空闲超时, 0 表示默认 (连接 15 秒, 空闲 120 秒).
int64_t bbnet_request(const char *method, const char *url, const char *headers,
                      const char *body, size_t body_len, uint32_t timeout_ms);
// 主线程每帧调用, 每次取出一项. 返回种类:
//   0 没有新数据; 1 响应头到达 (*status 为状态码, out 为原始响应头);
//   2 一条完整的 SSE 事件 (只在 Content-Type 含 text/event-stream 时); 3 普通响应体的一段;
//   4 正常结束; 5 出错 (out 为错误描述). 4 和 5 是终态, 之后再 poll 返回同样的值.
// out 用完要 bbnet_free, 末尾另有一个不计入 out_len 的 NUL.
int bbnet_poll(int64_t id, int *status, char **out, size_t *out_len);
void bbnet_free(char *p);
// 取消: 从别的线程直接关闭 socket, 阻塞中的读取马上返回, 之后 poll 得到 "cancelled".
// 正在解析域名或建立连接时, 请求线程要等这一步结束才退出, 但 poll 马上就返回 cancelled.
void bbnet_cancel(int64_t id);
// 释放句柄, 未结束时先取消.
void bbnet_close(int64_t id);
const char *bbnet_version(void);
```

导出函数内部都用 `catch_unwind` 包住, panic 不会带崩游戏.

构建 (just recipe):

- `just bbnet-test`: 单元测试.
- `just bbnet-macos`: 编译 arm64, 放到 `mods/balatrobot/native/macos/libbbnet.dylib`, 打包时随 mod 进入游戏.
  x86_64 的 rust target 没装, 要做 universal 包时分别编译再用 lipo 合并.
- `just bbnet-android [abi...]`: 用 cargo-ndk 编译到 `dist/native/android/<abi>/libbbnet.so`, 默认 arm64-v8a
  和 armeabi-v7a. 后者需要先 `rustup target add armv7-linux-androideabi`. NDK r27 起默认 16KB 页对齐.
  `just android dist-modded` 打包时, 已有的 .so 会放进 APK 的 `lib/<abi>/`, 只放运行时 APK 已有的 ABI 目录, 缺的打印提示后继续.
- `just bbnet-windows`: 只能在 Windows 或 CI 上编译, macOS 上缺 MSVC 链接器.
- 编译产物不入库. 以后 CI 在各平台预编译.

加载 ([bbnet.lua](<../mods/balatrobot/agent/net/bbnet.lua>)), 按顺序尝试:

- 环境变量 `BALATROBOT_BBNET` 给的绝对路径 (开发用).
- 桌面: `<mod 目录>/native/<macos|windows|linux>/<库文件名>`. mod 在运行时释放到存档目录的 `Mods/` 下, 是真实文件.
- Android: `ffi.load("bbnet")`, `ffi.load("libbbnet.so")`, 再从 `/proc/self/maps` 找到 liblove.so 所在的目录拼完整路径.
- 都失败时退回 `SMODS.https`: 不能流式, 整段回复到齐后一次交出, 取消只丢弃结果, 整体时限 300 秒.
  Android 上没有这个退路, 内置模式报 "网络库不可用".

## 录像

落盘 (各平台通用):

1. 编码参数设置约 2 秒一个关键帧. 画面本来就写成 fragmented mp4, 这样崩溃时最多丢约 2 秒画面.
2. 音频线程每秒 flush 一次 pcm.
3. 开局时就写出合成脚本, 局末再用最终的剪辑区间覆盖. 崩溃后至少能合成出 `-full.mp4`.
4. 新增 `just macos recordings-recover`: 扫描 `recordings/` 里残留的中间文件, 加 `--run` 补做合成.
   脚本本身跨平台, 只依赖 python3, ffmpeg 和 pgrep.

实测 (7.3 秒时 kill -9): 只加 `-g` 仍然读不出任何帧, 因为分片小于 ffmpeg 的 32 KB 写缓冲, 一直没落盘.
加上 `-flush_packets 1` 后读出 6.0 秒, 关键帧在 0, 2, 4 秒.

与 agent 状态的关系:

- 暂停: 完整版照录, 暂停段在剪辑版里剪掉. 暂停期间的手动操作只保留在完整版里.
- 停止: 立即结束当前录像段并开始合成, 不等回到主菜单.

Android:

- 现有录像通过 `io.popen` 调用 ffmpeg, Android 上没有 ffmpeg, 目前只会写出时间轴 JSON.
- 在 `bbnet` 中加一个只在 Android 上编译的 media 模块: 用 NDK 的 `AMediaCodec` 编码 H.264 和 AAC, 用 `AMediaMuxer` 封装 mp4. 手写 `extern "C"` 声明, 直接链接 `libmediandk`, 不增加 crate.
- Lua 读回帧后把像素指针交给 Rust. RGBA 转 YUV 和编码在 Rust 的线程里做. 声音复用现有的 pcm 采集.
- 剪辑版不重新编码, 按关键帧截取拼接 (`AMediaExtractor` 加 `AMediaMuxer`). 关键帧间隔 1 秒, 剪切精度约 1 秒.
- 默认 540p 24fps, 可在设置页调整. 卡顿时按墙钟重复上一帧, 音画不会错位.
- 桌面端继续用 ffmpeg.

## 游戏内回放

现有回放 (`just macos replay`, 见 [agent-api.md](<agent-api.md>) 的 "回放" 一节) 的工作方式:

- 用环境变量指定回放文件.
- 用临时存档 `Balatro-Replay` 隔离, 放完后以退出码结束进程.

游戏内回放复用同一套播放器 (`agent/replay/player.lua`), 改动的是三处: 入口, 存档隔离方式, 结束后的处理. 命令行用法保持不变.

入口: ESC 菜单 (Android 上是 "选项") 新增 "回放" 按钮.

- 只在主菜单显示, 因为回放要从开局开始.
- 所有平台都有, 与 agent 模式无关.

回放列表:

- 扫描录像目录下的 `*.replay.json`, 按时间倒序分页显示.
- 每行显示: 开始时间, 牌组, 赌注, 种子, 结果 (胜负, 底注), 步数, 原局时长.
- 不能回放的文件 (版本不支持, 挑战模式, 非原版牌组, 文件损坏) 变灰, 并注明原因.
- 判断能否回放需要解析整个文件, 而文件里带存档快照, 可能较大. 解析结果按 文件名, 大小, 修改时间 缓存.
- 点一行进入确认页:
  - 显示回放前的提示 (原局有手动操作, 版本不一致).
  - 选择节奏 (tight / original), 是否录像.
  - 然后开始回放.

存档隔离:

- 运行中切换存档标识会和后台的存档线程冲突, 所以不切换存档, 改为拦截写入.
- 开始前等存档线程把排队的写入做完.
- 回放期间丢弃所有存档写入. 写入有两个出口: `G.SAVE_MANAGER.channel` 上的请求, 以及主线程直接调用的 `compress_and_save` (`game.lua` 和 `functions/misc_functions.lua`). 这样磁盘上的真实存档, 进度和设置都不会被改动, 回放中途崩溃也一样.
- 然后在内存里套用原局的快照.
- 结束后用 `load_profile` 从磁盘重新读回当前档位的进度, 设置恢复成开始前的副本.
- 主菜单 "继续" 读取的仍是真实的 `save.jkr`, 不受回放影响.
- 读档开局的回放需要先把存档写成临时文件交给 `load`. 这次写入要放行, 并且用完即删.

互斥:

- 回放进行时, 内置 loop 不能开始; 外部模式暂停监听, 回放结束后恢复.
- 内置 loop 正在运行时, 回放按钮不可用.

中止:

- 桌面: 按住 Esc 1 秒. 这是现有做法.
- 触摸: 长按屏幕 1.5 秒. 输入锁仍然丢弃触摸事件, 但要单独识别这个长按.
- 按住期间显示进度, 松手就消失. 回放开始时用一条消息说明中止方法.

录像: 和命令行回放一样, 输出 `replay-*` 的完整版和剪辑版, 按确认页的选择决定是否录制.

结束 (完成, 跑偏或中止都一样):

1. 结束录像段.
2. 用消息显示结果: 完成 / 在第 N 步跑偏 (注明不一致的项) / 已中止.
3. 回到主菜单, 按上面的方法恢复进度和设置, 恢复 agent 模式.

命令行回放仍然以退出码结束进程.

## Android

### 存储位置

`game/conf.lua` 设置了 `t.externalstorage = true`, 所以存档目录在 `/storage/emulated/0/Android/data/<包名>/files/save/<存档名>`, 不在需要 root 才能访问的 `/data/data/<包名>` (即 `/data/user/0/<包名>`). 原版的存档名是 `game` (取自 `assets/game.love`), modded 是 `Balatro-Modded`.

这一点已经用系统备份核实过:

- 存档文件都在外部 files 域 (`ef/save/game/...`).
- 内部 files 域 (`f/`) 下只有 LÖVE 启动时建的几个空目录.

所以不需要迁移.

外部工具看不到内容, 是权限问题, 不是位置问题:

- PhysicsFS 建目录用 0700, 建文件用 0600, 没有组权限.
- 系统给 `Android/data` 下的内容用 `ext_data_rw` 组管理访问. 其他应用的目录是 0770/2770, 文件是 0660.
- MT 管理器, adb shell 这类工具靠这个组权限读取, 因此只能看到一个空的 `save/`.

`game/android_storage.lua` 负责补上组权限 (目录 2770, 文件 0660), 时机有三个:

- 存档目录确定时, 整棵树扫一遍.
- 主线程经 `love.filesystem` 写入之后, 立即修正.
- 失去焦点或切到后台时, 再扫一遍.

有一个例外: 内置 agent 的配置文件含 key, 写入后要改回 0600, 不给组权限.

要求所有写入都经过存档目录, 不写应用内部目录:

| 内容 | 位置 (相对存档目录) |
|---|---|
| 存档, 进度, 设置 (`settings.jkr`, `<档位>/profile.jkr`, `meta.jkr`, `save.jkr`) | 根目录与档位目录 |
| mod 配置, 包括内置 agent 的 endpoint 和 key | `config/` |
| lovely shim 释放的 mod 和日志 | `Mods/` 与 shim 的日志目录 |
| 录像, 时间轴, 回放文件, agent 转录 | `recordings/` |

- 新增的写入 (bbnet 的 media 模块, 转录等) 一律用 `love.filesystem.getSaveDirectory()` 下的路径, 不用 Android 的内部目录.
- 原生库 `libbbnet.so` 由系统装在应用的 native 库目录, 只读, 不属于数据.

安全: key 以明文存在外部存储.

- 配置文件保持 0600, MT 管理器这类靠组权限的工具读不到.
- Android 10 及以前, 有存储权限的应用可能仍能读到.

设置页要注明这一点.

### 权限与流程

权限: 运行时 APK 的 manifest 已声明 `android.permission.INTERNET`.

触摸流程:

1. 主菜单 → 模组 → balatrobot: 选内置模式, 粘贴 endpoint 和 key, 填模型名, 打开录像.
2. 开始: 主菜单打开 选项 → Agent → 开始, 或者手动开局后点 HUD 的 "选项" → Agent → 开始.
3. 暂停或停止: 选项 → Agent.
4. 回放: 主菜单 → 选项 → 回放, 选一个文件开始. 长按屏幕 1.5 秒中止.
5. 取出录像: USB 或 `adb pull` 访问 `Android/data/<包名>/files/save/<存档名>/recordings/`. Android 11 起, 部分文件管理器不能浏览 `Android/data`, 这是系统限制. 用同样的方式把其他设备录下的回放文件放进这个目录, 就能在列表里看到.

生命周期:

- 切到后台: agent 自动暂停, 录像不补帧, 这一段按暂停处理 (剪辑版剪掉, 记入时间轴). 回放进行中时, 回放计时同样暂停, 回到前台后继续.
- agent 运行或回放进行时调用 `love.window.setDisplaySleepEnabled(false)`, 防止熄屏.

## 参考

协议处理参考 codex-switch (一个 Rust 写的 API 代理) 的以下部分. 它的网络层依赖 axum/hyper, 不照搬.

| 位置 | 内容 |
|---|---|
| `src/proxy/forward/error_policy.rs` | SSE 事件分隔; 可重试与不可重试的错误码 |
| `src/proxy/compat/chat_completions/shared.rs` | 推理字段的读取顺序; usage 规范化 |
| `src/proxy/compat/chat_completions/stream.rs` | 逐 chunk 取推理, 正文和 tool_calls; tool call 增量累积 |
| `src/proxy/compat/chat_completions.rs` | assistant 消息回填 `reasoning_content` 和 `tool_calls` |
| `src/core/models.rs` | Bearer 与 `x-api-key` 两种鉴权 |
| `src/live.rs`, `src/app/ui/active.rs`, `src/app/ui/active/scroll.rs` | 活跃请求的实时预览: 尾部缓冲, 按字形宽度截取, 限速推进, 结束后停留 |

## 交付顺序

每一步都能单独验证:

1. 设置页, 模式互斥, Agent 面板和 F9. 先接一个假数据的 loop, 验证控制和流式条.
2. `bbnet` 和桌面端的真实 loop, 包括手册查询, 重试和防失控.
3. 录像落盘改进和 `just macos recordings-recover`.
4. 游戏内回放: 列表, 写入拦截, 结束后恢复. 先在桌面上验证.
5. Android: `bbnet` 交叉编译, APK 打包, 触摸流程 (含回放).
6. Android 录像编码.

进度:

- 1~3 已实现, 有单测, 未在游戏里实际运行过 (界面外观, F9, 流式条位置, 真实模型请求都待实机验证).
- 5 完成了一部分: `bbnet` 的 arm64-v8a 交叉编译与 APK 打包 (`just android dist-modded` 已验证 .so 进入
  `lib/arm64-v8a/`), 切到后台自动暂停, 运行中防熄屏. armeabi-v7a 缺 rust target; 真机上的触摸流程未验证.
- 4 和 6 未开始.

每一步同步更新 [agent-api.md](<agent-api.md>) 和 AGENTS.md. 测试只覆盖关键逻辑: SSE 分帧, tool call 累积, 手册的路径校验与分页, 错误分类, 回放期间的存档写入拦截.

## 待定与待核实

- 是否适配 Responses API. OpenAI 的 reasoning summary 只在 Responses API 里返回, 走 chat completions 拿不到.
- 内置 agent 赢下一局后的默认处理: 先按回主菜单并停止实现 (配置 `after_win`, 可设 `endless`), 待 user 确认.
- 顶部居中的流式条在商店和补充包界面是否被原版 UI 占用, 实现后截图确认.
- 桌面的 `libbbnet.dylib` 在 `mods/balatrobot/native/macos/` 下, 随 mod 进入所有平台的包 (APK 里多约 1.4MB).
  按平台剔除要同时改 mod 清单与 bundle hash, 暂不处理.
- Android 上 `ffi.load` 能否只用库名找到 `libbbnet.so` (找不到时从 `/proc/self/maps` 拼路径), 需要真机确认.
- 手机上逐帧读回画面的性能能否撑住 540p 24fps, 需要真机测试.
- 回放时是否重现内置 agent 的思考流. 转录带时间戳, original 节奏可以原样重放; tight 节奏要压缩时间.
- 在桌面录下的回放文件拿到 Android 上能否得到同样的结果 (游戏和 mod 版本相同的前提下).
- `load_profile` 重新读档后, 内存里被回放改过的部分是否全部恢复, 要逐项核对 (解锁, 发现, profile, 待弹解锁通知).
- `android_storage.lua` 失去焦点时的补扫: 切到后台时 SDL 会不会先把失去焦点的事件交给主循环, 再挂起; 以及 MT 管理器在只有组权限时能否读到, 需要真机确认.
