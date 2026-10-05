# 录像

按局录下画面与声音, 写时间轴. 代码在独立的 mod `bbreplay` 里 (`mods/bbreplay/record/`),
只依赖 `bbcore`, 不装 balatrobot 也能录手动打的局. 环境变量与输出文件见 [agent-api.md](<agent-api.md>).
回放文件与录像同名, 见 [replay.md](<replay.md>).

## 设置

模组 -> BB Replay -> 配置:

| 项 | 可选 | 默认 |
|---|---|---|
| 录制视频 | 开 / 关 | 关 |
| 录制回放文件 | 开 / 关 | 关 |
| 保留方式 | skip (合成成功后删掉中间文件) / keep (保留, 供事后重跑) | skip |
| 清晰度 | 默认, 360p, 540p, 720p, 1080p (画面高度, 宽度按窗口比例) | 桌面 720p, Android 540p |
| 帧率 | 默认, 24, 30, 60 | 桌面 30, Android 24 |
| 码率 | 自动, 2M, 4M, 8M, 16M (Mbps) | 自动 |

- `record_video` 与 `record_replay` 是独立开关, 可以只录视频, 只录回放文件, 同时录制或全部关闭.
  两者都开时共用同一局的文件夹, 只录回放文件不需要视频编码器. 旧配置的 `record` 自动迁移到两个开关.
- 视频关闭时结束当前录像段; 回放文件关闭时保存当前记录, 再次打开从下一局开始, 不补录缺少前半局的文件.
  保留方式从下一段起生效; 清晰度, 帧率与码率也从下一段录像起生效, 正在录的一段不变.
- 设了对应的环境变量 (`BALATROBOT_RECORD_VIDEO`, `BALATROBOT_RECORD_REPLAY`, `BALATROBOT_RECORD_KEEP`,
  `BALATROBOT_RECORD_HEIGHT`, `BALATROBOT_RECORD_FPS`, `BALATROBOT_RECORD_BITRATE`) 时以环境变量为准,
  设置页上那一项只显示环境变量的值. Android 没有环境变量, 全部在这里设.
- 码率自动时, 桌面 (ffmpeg) 用固定画质参数 (videotoolbox `-q:v 65`, x264 `-crf 20`), 体积随画面复杂度变化;
  Android 按像素数与帧率估算. 指定码率时是目标值, 画面简单时实际码率会低于它. x264 另限峰值为 1.5 倍.
- 局末合成只把画面直接复制并混入声音, 不重新编码.
- 60fps 要游戏本身跑得到 60 帧, 跑不到时会重复帧, 只是文件变大. Android 退到软编时 60fps 可能跟不上.
- 参数的可选值与取舍在 `record/quality.lua`.

## 落盘

各平台通用:

1. 编码参数设置约 2 秒一个关键帧. 画面本来就写成 fragmented mp4, 这样崩溃时最多丢约 2 秒画面.
2. 音频线程每秒 flush 一次 pcm.
3. 开局时就写出合成脚本, 局末再用最终版覆盖. 崩溃后也能合成出 `-full.mp4`.
4. 一局一个文件夹 `<stem>/`, 里面放这一局的全部产物 (视频, 时间轴, 回放文件, agent 转录与中间文件),
   文件名仍带这一局的 `<stem>` 前缀. 建不出文件夹时退回平铺写法, 只记一行警告. 回放列表两种布局都认.
5. 新增 `just macos recordings-recover` (Windows 上是 `just windows recordings-recover`): 扫描 `recordings/`
   里残留的中间文件 (每局一个文件夹, 与旧版平铺的两种布局都扫), 加 `--run` 补做合成. 脚本本身跨平台,
   只依赖 python3 与 ffmpeg; 判断游戏与合成脚本是否运行, macOS 上用 pgrep, Windows 上用 tasklist 与 PowerShell.

## Windows

桌面录像的流程与 macOS 相同 (ffmpeg 实时编码画面, 声音另写 .pcm, 局末合成), 以下几处不同:

- 启动子进程不经过 shell, 由 [win_proc.lua](<../mods/bbreplay/record/win_proc.lua>) 用 LuaJIT FFI 直接调
  `CreateProcessW`. 原因: `Balatro.exe` 是 GUI 程序, `io.popen` 每次都会弹出控制台窗口, 录像期间一直开着;
  而且 popen 是文本模式, 写进去的画面字节里每个 0x0A 都会变成 0x0D 0x0A, 画面全部错位.
  现在 ffmpeg 不开窗口, 标准输入是二进制管道, 输出写进 `.ffmpeg.txt`.
- 合成脚本是批处理 `<stem>.post.cmd`, 内容与 `.post.sh` 一致. 局末用 `cmd /d /s /c` 在后台运行, 不开窗口,
  新进程组, 并尽量脱离游戏所在的作业, 游戏退出不影响它. 崩溃后可以直接双击运行草稿脚本, 带 `--clean` 时成功后删除中间文件.
  局末脚本删掉自身后退出码不可靠, `recordings-recover` 以 `-full.mp4` 是否生成为准.
- 编码器固定用 x264 (videotoolbox 只有 macOS 有), 可用 `BALATROBOT_RECORD_CODEC` 指定. x264 占 CPU,
  动画多时游戏可能掉帧; 掉帧时把清晰度或帧率调低.
- ffmpeg 先在 PATH 里找, 再看 winget (`%LOCALAPPDATA%\Microsoft\WinGet\Links`), scoop (`%USERPROFILE%\scoop\shims`),
  choco (`%ProgramData%\chocolatey\bin`) 与 `C:\ffmpeg\bin`, 也可以用 `BALATROBOT_FFMPEG` 指定.
- `os.rename` 在 Windows 上不能覆盖已有文件. 时间轴, 回放文件与合成脚本都是先写临时文件再改名,
  改名失败时先删掉旧文件再改名.
- 已知限制: 存档目录路径里有非 ASCII 字符 (例如中文用户名) 时, Lua 的 `io.open` 按系统代码页解释路径,
  可能打不开文件. 子进程那一侧按 UTF-8 转成 UTF-16, 没有这个问题.

实测 (7.3 秒时 kill -9): 只加 `-g` 仍然读不出任何帧, 因为分片小于 ffmpeg 的 32 KB 写缓冲, 一直没落盘.
加上 `-flush_packets 1` 后读出 6.0 秒, 关键帧在 0, 2, 4 秒.

## 与 agent 状态的关系

- 暂停: 视频照录, 时间轴记 `pause` / `resume`.
- 停止: 立即结束当前录像段并开始合成, 不等回到主菜单.

## Android

方案:

- 桌面录像通过 `io.popen` 调用 ffmpeg, Android 上没有 ffmpeg (系统不提供这个二进制, 也塞不进 APK).
- 用 NDK 的 `AMediaCodec` 编码 H.264 与 AAC, `AMediaMuxer` 封装 mp4. 不新增 crate, 也不新增原生库:
  media 的 ffi 声明放在 [android/ffi.lua](<../mods/bbreplay/record/android/ffi.lua>), 直接加载
  系统的 `libmediandk`.
- 颜色转换 (RGBA -> NV12) 放在 bbnet 里 ([yuv.rs](<../native/bbnet/src/yuv.rs>), 导出 `bbnet_rgba_to_nv12`).
  540p 一帧 50 万像素, 逐像素在 Lua 里转达不到 24fps; 放在 bbnet 是因为那里已经有三个平台的交叉编译链路,
  不必为一次换算再养一个 C 库和一套构建. 系数按 BT.601 有限范围 (与硬件编码器一致), 色度按 2x2 平均.
- Lua 读回帧后把像素指针交给原生侧转换, 再喂给编码器. 声音复用现有的 pcm 采集.
- 默认 540p 24fps, 码率按像素数与帧率估算 (约 0.15 bit/像素/帧, 1~12 Mbps); 都可在设置页改.
  卡顿时按墙钟重复上一帧, 音画不会错位.
- 桌面端继续用 ffmpeg.

进度: 视频链路已在真机跑通 (640x360 自检: 30 帧 / 30 个样本 / 封装成功, 取出用 ffprobe 核对是
H.264 640x360 yuv420p 30fps 1.0 秒, 抽帧确认红绿蓝三块颜色正确). 声音还没做.

实现要点 (都是真机上试出来的):

- 编码器按顺序试: `createEncoderByType` (系统推荐, 通常是最省电的硬件编码器), 然后
  `c2.android.avc.encoder`, 再 `OMX.google.h264.encoder`. 第一个 `configure` 通过的用.
  实测高通设备上硬件编码器会以 `err(-22, BAD_VALUE)` 拒绝同一份 format, 而软件编码器直接通过 ——
  硬件编码器实例有限, 被别的应用 (例如 scrcpy, 系统录屏) 占用时就建不起来, 这时软编仍可用.
  软编占 CPU, 所以放在最后; 结束时会报告实际用了哪个, 以及编码队列被压满的次数 (次数多说明跟不上帧率).
- 只用 NV12 (`COLOR_FormatYUV420SemiPlanar`), 与 bbnet 的转换输出一致. 不换 I420 兜底:
  那是三平面布局, 喂 NV12 的数据会得到颜色错乱的视频.
- `i-frame-interval` 是 float 键 (Java 侧 `KEY_I_FRAME_INTERVAL` 也是 float), 用 `setFloat` 设.
- 文件用非变参声明的 `open` 建: LuaJIT 把变参里的 Lua 数字按 double 传, `mode` 会按 4 字节读成 0,
  文件权限就成了 0000 (连自己都读不到). 产物写完再走一次存档目录的权限修正, 外部工具才取得走.
- `AMediaMuxer` 只写普通 mp4, moov 在收尾时才落盘, 所以录制中途崩溃会丢掉这一局的视频 (桌面的
  ffmpeg 用 fragmented mp4 抗崩溃, 这个特性 Android 上没有对应做法).
- 整个编码线程包在 `xpcall` 里: LÖVE 会把线程里未捕获的错误抛到主线程并直接崩掉游戏, 而这里出错
  多半与设备相关, 不该让玩家的对局陪葬. 失败只记一条警告.
- Android 默认 540p 24fps (手机屏幕小, 软编时 24fps 比 30fps 省四分之一 CPU), 桌面仍是 720p30.

还没做:

- 声音: Android 的 mp4 目前没有音轨 (所以这一路不采 `.pcm`, 免得留下用不到的文件). 要加音轨得再用
  MediaCodec 编 AAC 并在封装器里多一条轨道.
- 崩溃恢复: 见上面的 moov 限制.
