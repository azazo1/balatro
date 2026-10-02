# 内置 agent loop

内置模式下游戏自己运行的主循环, 以及它用来请求模型的原生网络库 bbnet. 模式, 设置页, 运行控制与流式条见
[builtin-agent.md](<builtin-agent.md>).

## 主循环

代码在 `agent/loop/`: `driver.lua` 是主循环, 依赖全部注入, 有单测; `summary.lua`, `tools.lua`, `prompt.lua`,
`history.lua` 是纯逻辑; `local_call.lua` 在进程内调用端点.

每一步:

1. 读取游戏状态. 动画没停, 游戏暂停或人打开了设置等菜单 (`overlay` 为 `other`) 时等待.
2. 能自动处理的直接处理, 不问模型: `unlock` 时调用 `continue`, 结算 (`ROUND_EVAL`) 调用 `cash_out`.
   做了什么以一句说明附在下一轮的状态前面.
3. 其余情况下组装状态摘要和历史, 以流式方式请求模型. 思维链和正文推给流式条.
4. 拿到工具调用后逐个执行, 结果回灌给模型. 动作的结果直接带上新的状态摘要, 下一轮不再重复.
   一个动作失败后, 同一次回复里剩下的调用不执行, 都回 "未执行", 保证每个 tool_call 都有结果.
   出牌那一步的结果开头还带这一手的计分过程, 见下面 "出牌计分过程".
5. 胜利后按设置进入无尽模式, 或回主菜单; 输了回主菜单. 回到主菜单后按设置停止 loop, 或保留对话历史由模型自己开下一局.

执行动作不经过 HTTP: `local_call.lua` 直接调用 dispatcher, 并包一层 `send_response` 截获结果.
这样照样经过弹窗拦截与活动追踪, 录像的剪辑和时间线与外部 agent 一致. 内置模式与外部模式互斥, 所以两者不会争抢.

工具: 在 `tools.lua` 里手写一份精简的中文定义, 不从 `rpc.discover` 生成. 那份规格缺少 `pack` 等方法, 描述是英文且偏长.
端点参数变化时要同步修改. 不给模型的方法:

- `gamestate`: 每次结果里已经带状态摘要.
- `cash_out`, `continue`, `endless`: loop 自己处理.
- `menu`, `save`, `load`, `set`, `add`, `screenshot`: 与游玩无关或会破坏进度.

只读工具分两类: 查静态手册的 `docs_index` / `docs_read` / `docs_search` / `lookup` (手册没打包时不提供),
以及查当前局动态值的 `dynamics`. 后者对应 bbcore 的同名只读端点, 给出每回合重抽的认牌目标 (古老小丑的花色,
偶像的花色与点数, 邮件回扣的点数, 城堡的花色, 待办清单的牌型), 盲注公牛要用的最常打出牌型, 以及持有卡与
手牌特殊牌的实时效果文本 (成长值, 概率都已代入). 手册是版本快照, 这些位置在里面只能写成 `[当前乘倍率]`
这样的占位, 所以提示词要求模型查它而不是猜. 它还能按参数给摸牌堆与弃牌堆: `deck` 与 `discard` 传 `stats`
得到张数与按花色点数的统计, 传 `list` 再加完整列表, 不传就不返回 (算同花与顺子的概率时用得上);
`targets` 与 `cards` 传 `false` 可以省掉默认那两项.

动作工具都带 `reason`, 调用时拆出来作为决策消息. 解说仍按 [agent-commentary.md](<agent-commentary.md>) 使用 `notify` 和 `reason`, 和流式条的思考流分开.
每次调用还会在屏幕左侧记一条工具记录 (标题是工具中文名, 正文是参数含义, `bbcore/runtime/call_note.lua` 里按方法名写死,
手册查询那几个由 balatrobot 自己登记): 等讲解退去、动作真正执行时才弹, 只反映这次调用本身, 与 loop 无关, 也不需要模型给内容.

提示与上下文:

- 系统提示 (`prompt.lua`) 是 [手册 README](<game/README.md>) 的 "Agent 必须区分的概念" 和 "每次动作前的规则检查" 两节,
  以及解说规范的压缩版. 那两份文档改动时同步这里. 规则要点里有通关条件 (打完底注 8 的 Boss 即通关,
  见 [run-flow.md](<game/rules/run-flow.md>) 的 "胜负与无尽模式").
- 本局设置 (`prompt.system`): 设置页的 "赢下一局之后" (`after_win`) 决定通关后进无尽还是回主菜单.
  开无尽时告诉模型第 8 底注不是结束, 要按 "一直打下去" 规划; 回主菜单时说明不用为底注 9 以后留余量.
  "打完一局之后" (`after_run`) 决定回到主菜单后 loop 停止还是保留对话, 由模型自己 `start` 开下一局.
  提示词和策略一样只在从停止状态开始时重建; `after_win` / `after_run` 的实际分支在一局结束时读当前配置.
- 状态摘要 (`summary.lua`): 把 gamestate 转成中文精简文本, 每行开头写下标. 小丑, 消耗牌, 优惠券, 商店与卡包里的牌
  第一次出现时, 从 catalog 取中文名和一句效果附上, 之后只写名字. 手册文本里还剩 `[ ]` 占位的是会变的值
  (每回合换的花色点数, 成长值), 这类牌每次都附 gamestate 里的实时文本, 免得模型拿着占位去猜.
  整副牌只给张数; 牌型只列出等级高于 1 或本局打过的, 打过时附本赛局与本回合的次数
  (超新星把牌型本赛局的打出次数加成倍率, 卡面上看不到这个数).
  另外带一行 `上一手: 同花 Lv1 = 10125` (上一手的牌型与总分), 出牌列表与逐项明细不塞进摘要.
- 压缩历史 (`history.lua`, 由 `driver.lua` 触发): 设置页的 "最大上下文" (默认 256K) 决定压缩点.
  - 触发: 上一次请求报的 `prompt_tokens + completion_tokens` 超过最大上下文的 80% 时, 在下一轮开始前压缩;
    服务端没报用量时按字数估算. 压缩后到下一次正常请求返回之前不再判断, 免得只凭估算反复压缩.
  - 切分: 从后往前留出最近约 30% 最大上下文的原文 (对话本身还没到这么多时留后一半), 切点总在 assistant 或
    user 消息之前, 不会拆开 tool_calls 和对应的结果. 较早的部分 (含上一次的摘要) 渲染成文字.
  - 写摘要: 同一个 endpoint 和模型, 单独发一次不带工具的请求, 不限长度. 流式条行首固定显示 "压缩中: ",
    摘要输出接在后面滚动. 用量计入请求次数和单局 token 上限, 摘要正文写进转录 (`compact` 条目).
  - 完成后历史变成: 系统提示, 一条带摘要的用户消息, 最近的原文.
  - 退路: 写摘要失败 (重试用完, 包括它自己超长) 或摘要为空时, 丢掉旧消息, 只留系统提示, 最近约 40 步的
    简要记录和当前状态, 继续打, 不停下.
  - 服务端以上下文超长拒绝请求时, 压缩后重发一次; 再超长才停下.
  - 压缩中暂停会取消写摘要的请求, 历史不变, 继续时重新判断.

### 出牌计分过程

出牌那一步的结果开头是这一手的计分过程, 内容是 user 在屏幕上看到的那些飘字, 由 bbcore 的
[runtime/scoring.lua](<../mods/bbcore/runtime/scoring.lua>) 记下 (挂在 `update_hand_text` 与
`card_eval_status_text` 上), 写进 gamestate 的 `round.last_hand`:

```
计分过程:
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

完成. 当前状态:
...
```

- 每行三列: 变动原因 (哪张牌或哪个小丑), 变动因素 (加了多少筹码或倍率, 乘了几倍), 变动后筹码x倍率.
- 出牌行里带 `*` 的是真计入牌型的牌, 没带星号的只是被打出去, 用来核对有没有选错牌.
- 被盲注封禁这一手总分为 0, 明细里给一行 `被盲注封禁 | 本手不计分 | 0x0`.
- 明细只在这一次结果里给一次, 摘要里只有 `上一手` 那一行, 免得每一轮都重发十几行.
- 只有 `play` 会记, 且只记这一手刚开始到算完 (游戏写出本手总分) 之间的部分, 结算界面与回合结束的小丑效果不进明细.
- 同一份数据外部 agent 也拿得到, 字段说明见 [agent-api.md](<agent-api.md>) 的 "出牌计分".

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

文本截断 (都走 `agent/text.lua`):

- 请求体里的字符串是原样发出去的 (编码器只转义控制字符, 非 ASCII 字节直接写进请求体). 用 `string.sub`
  按字节截断时, 切点落在一个汉字中间就会写出非法 UTF-8, 服务端会拒掉**整个**请求并让 agent 停下
  (实测 400: `invalid unicode code point at line 1 column 22458`, 出现在手册内容超过上限被截断时).
  因此截断一律按字符边界切 (末尾不留半个字符), 哪一项都一样: 查询结果 (6000 字节, `driver.lua`),
  错误说明 (120 字节), 服务端返回的错误文本 (300 字节, 也会写进转录, 切一半会让那行 JSONL 不合法).
- 请求体编码前还有一层兜底: 内容里若出现非法字节 (例如有的卡牌文本来自模组), 换成 U+FFFD, 而不是让
  服务端拒掉整条请求. 纯 ASCII 直接跳过, 合法文本只扫一遍不重建.

转录与日志:

- 每局写一份 `<录像同名>-agent.jsonl`, 放在录像的那一局文件夹里, 带时间戳, 能和录像的时间轴对上. 不含 key.
- 请求的开始, 结束, 耗时, 重试和错误写进游戏日志.

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

构建 (`just native ...`, 实现见 [build_native.py](<../scripts/build_native.py>)):

- `just native test`: 单元测试与集成测试. 颜色转换的用例也在其中 ([yuv.rs](<../native/bbnet/src/yuv.rs>)).
- `just native build <平台>`: 编译到 `dist/native/<平台>/`, 一般不用单独跑, 打包时会自动编译.
  - macos: 只编 arm64. x86_64 的 rust target 没装, 要做 universal 包时分别编译再用 lipo 合并; Intel Mac 上退回 SMODS.https.
  - windows: 只能在 Windows 上编译, 别的系统上缺 MSVC 链接器.
  - android `[abi...]`: 用 cargo-ndk 编译到 `dist/native/android/<abi>/libbbnet.so`, 默认 arm64-v8a.
    armeabi-v7a 需要先 `rustup target add armv7-linux-androideabi`. NDK r27 起默认 16KB 页对齐.

打包 (三个平台的 `dist-modded` 都一样): 每次都重新编译本平台的 bbnet (cargo 增量编译, 没改动时只要几秒),
既不会漏带, 也不会带上改代码之前编的旧库. 编不出来就报错退出, 确实不需要时加 `--no-native`.

- 桌面: 放进 mod 树的 `balatrobot/native/<平台>/`, 随 mod 释放到存档目录后由 `ffi.load` 加载. mod 源码目录里
  `mods/balatrobot/native/` 的残留会先清掉, 免得一个平台的库混进别的平台的包.
- Android: 放进 APK 的 `lib/<abi>/`, 只放运行时 APK 已有的 ABI. arm64-v8a 是必需的; 其余 ABI 缺编译条件时
  警告并跳过, 那类设备上内置 agent 连不上模型, 录像只有时间轴.
- 编译产物不入库. 以后 CI 在各平台预编译.

这些 recipe 都只是转调 python: NDK 查找, target 映射与产物复制写在脚本里, 三个平台共用一份,
不用为 Windows 单写一套 shell.

加载 ([bbnet.lua](<../mods/balatrobot/agent/net/bbnet.lua>)), 按顺序尝试:

- 环境变量 `BALATROBOT_BBNET` 给的绝对路径 (开发用).
- 桌面: `<mod 目录>/native/<macos|windows|linux>/<库文件名>`. mod 在运行时释放到存档目录的 `Mods/` 下, 是真实文件.
- Android: `ffi.load("bbnet")`, `ffi.load("libbbnet.so")`, 再从 `/proc/self/maps` 找到 liblove.so 所在的目录拼完整路径.
- 都失败时退回 `SMODS.https`: 不能流式, 整段回复到齐后一次交出, 取消只丢弃结果, 整体时限 300 秒.
  Android 上没有这个退路, 内置模式报 "网络库不可用".

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
