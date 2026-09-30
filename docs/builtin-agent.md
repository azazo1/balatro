# 内置 agent

游戏内自带 agent loop: 在设置页填好 chat completions 的 endpoint, key 和模型名, agent 就在游戏里自动玩. 模型的思考过程以一行流式文字显示在画面顶部, 观众能看出模型正在思考, 不会把长时间静止误认为游戏卡死. 本文是需求与实现方案, 已实现的接口说明见 [agent-api.md](<agent-api.md>).

## 目标

- 只需配置 endpoint, key 和模型名, 不依赖外置 agent 框架.
- 思考流实时显示. 目标是让观众知道模型在工作, 不要求每个字都看得清.
- 游戏内可以随时暂停, 停止, 切换模式, 防止失控.
- 录像及时落盘, 崩溃时尽量少丢.
- Android 上整个流程都能用触摸完成, 录像落在外部存储.
- 现有的外部 agent 用法 (`just agent-call`) 保持不变, 和内置 agent 互斥.

## 总体结构

| 部分 | 语言 | 负责 |
|---|---|---|
| mod 本体 | Lua | agent loop, 执行动作, 设置页, Agent 面板, 流式条, 手册查询 |
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

每一步:

1. 读取游戏状态.
2. 能自动处理的直接处理, 不问模型: `overlay` 为 `unlock` 时调用 `continue`; 结算这类没有选择的步骤直接执行.
3. 其余情况下组装状态摘要和历史, 以流式方式请求模型. 思维链和正文推给流式条.
4. 拿到工具调用后执行, 结果和错误回灌给模型.

工具: 由 `rpc.discover` 生成, 排除 loop 自己处理的方法. 解说仍按 [agent-commentary.md](<agent-commentary.md>) 使用 `notify` 和 `reason`, 和流式条的思考流分开.

提示与上下文:

- 系统提示内置 [手册 README](<game/README.md>) 的 "Agent 必须区分的概念" 和 "每次动作前的规则检查" 两节, 以及解说规范.
- 状态摘要: 把 gamestate 转成中文精简文本. 小丑, 消耗牌, 优惠券第一次出现时, 从 catalog 取中文名和一句效果附上.
- 每过一个盲注压缩一次历史.

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

- 手写 HTTP/1.1: 每个请求开一个线程, 用 `std::net::TcpStream`. 解析状态行和头, 支持 chunked 和 Content-Length 两种响应体.
- 同时支持 `http://`, 方便连接本地的 ollama, vLLM.
- 不支持代理和重定向.
- SSE 分帧放在 Rust 里, 同时认 `\n\n` 和 `\r\n\r\n` 作分隔. JSON 解析交给 Lua, 游戏里已经有 `json` 库.
- 非 2xx 响应返回状态码和响应体, 由 Lua 判断是否重试.

接口用轮询, 不用回调, 因为 LuaJIT 的 ffi 回调不能从别的线程调用:

```c
// 发起请求, 返回句柄. headers 为 "Name: value\n" 拼接的文本.
int64_t bbnet_request(const char *url, const char *headers, const char *body);
// 主线程每帧调用: 取出已到达的完整 SSE 事件, 没有新数据时返回 NULL.
// state 取值: 进行中 / 完成 / 出错. 出错时返回错误信息.
const char *bbnet_poll(int64_t id, int *state);
void bbnet_free(const char *s);
void bbnet_cancel(int64_t id);
```

导出函数内部都用 `catch_unwind` 包住, panic 不会带崩游戏.

构建:

- macOS: 分别编译 aarch64 和 x86_64, 用 lipo 合并, 放进 `.app` 后随整个包 codesign.
- Windows: x64 dll, 放在 exe 旁边.
- Android: `cargo ndk -t arm64-v8a -t armeabi-v7a build --release`. 产物放进 APK 的 `lib/<abi>/`. 运行时 APK 里的原生库是压缩存储的, 说明安装时会解出来, 所以不需要特殊对齐. 编译时要保证 16KB 页对齐 (NDK r27 起默认开启).
- CI 在各平台预编译, 本地打包直接取用. 编译命令写成 just recipe.

加载:

- 桌面: 从可执行文件或 `.app` 所在位置拼出库路径.
- Android: 先试 `ffi.load("libbbnet.so")`. 不行就从 `/proc/self/maps` 找到 liblove.so 所在的目录, 再拼完整路径.
- 加载失败时退回 `SMODS.https`: 不能流式, 流式条只显示 "思考中" 加计时. Android 上没有这个退路, 内置模式不可用.

## 录像

落盘 (各平台通用):

1. 编码参数设置约 2 秒一个关键帧. 画面本来就写成 fragmented mp4, 这样崩溃时最多丢约 2 秒画面.
2. 音频线程每秒 flush 一次 pcm.
3. 开局时就写出合成脚本, 局末再用最终的剪辑区间覆盖. 崩溃后至少能合成出 `-full.mp4`.
4. 新增 `just recordings-recover`: 扫描 `recordings/` 里残留的中间文件并补做合成.

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

## Android

输出位置: 打包用的 conf.lua 设置了 `t.externalstorage = true`, 存档目录在 `/storage/emulated/0/Android/data/<包名>/files/save/<存档名>`. 录像默认写在存档目录下的 `recordings/`, 不在需要 root 才能访问的 `/data/data`.

权限: 运行时 APK 的 manifest 已声明 `android.permission.INTERNET`.

触摸流程:

1. 主菜单 → 模组 → balatrobot: 选内置模式, 粘贴 endpoint 和 key, 填模型名, 打开录像.
2. 开始: 主菜单打开 选项 → Agent → 开始, 或者手动开局后点 HUD 的 "选项" → Agent → 开始.
3. 暂停或停止: 选项 → Agent.
4. 取出录像: USB 或 `adb pull` 访问 `Android/data/<包名>/files/save/<存档名>/recordings/`. Android 11 起, 部分文件管理器不能浏览 `Android/data`, 这是系统限制.

生命周期:

- 切到后台: agent 自动暂停, 录像不补帧, 这一段按暂停处理 (剪辑版剪掉, 记入时间轴).
- agent 运行时调用 `love.window.setDisplaySleepEnabled(false)`, 防止熄屏.

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
3. 录像落盘改进和 `just recordings-recover`.
4. Android: `bbnet` 交叉编译, APK 打包, 触摸流程.
5. Android 录像编码.

每一步同步更新 [agent-api.md](<agent-api.md>) 和 AGENTS.md. 测试只覆盖关键逻辑: SSE 分帧, tool call 累积, 手册的路径校验与分页, 错误分类.

## 待定与待核实

- 是否适配 Responses API. OpenAI 的 reasoning summary 只在 Responses API 里返回, 走 chat completions 拿不到.
- 内置 agent 赢下一局后默认进入无尽模式还是回主菜单, 要不要做成设置项.
- 顶部居中的流式条在商店和补充包界面是否被原版 UI 占用, 实现后截图确认.
- `ring` 用 NDK 交叉编译是否顺利.
- Android 上 `ffi.load` 能否只用库名找到 `libbbnet.so`.
- 手机上逐帧读回画面的性能能否撑住 540p 24fps, 需要真机测试.
