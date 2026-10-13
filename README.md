# Balatro 多平台移植与规则工具

围绕 Balatro 的实验项目: 移植到 macOS, Android, Windows 三个平台, 用 Rust 重写游戏规则引擎,
提供 Web 调试台和 AI 自动游玩工具.

游戏版本 `1.0.1o-FULL`, 用于学习游戏代码, 研究多平台打包, 以及用另一份实现验证规则.

## 在线试玩

<img src="assets/engine-web-screenshot.png" width="640" alt="Web 调试台对局画面">

<https://azazo1.github.io/balatro/> 是在线调试台, 打开就能玩, 不用装任何东西. 除了正常的手牌和
小丑牌, 还能看到盲注信息, 回合分数和完整的对局历史.

规则用 Rust 引擎计算, 贴图来自原版, 但没有动画. 本地运行用 `just engine-web`, 详见
[Web 调试台](<engine/web/README.md>).

## 项目亮点

**Rust 规则引擎**: 把游戏规则用 Rust 重写了一遍, 不依赖图形, 能存快照, 回滚, 可以批量跑很多局.
验收标准是和真游戏逐步对拍, 而不是 "读源码读出来的行为", 详见 [引擎说明](<engine/README.md>).

```shell
just play step --deck RED --stake GOLD --actions .tmp/run.actions.jsonl
just engine-audit       # 完整回归测试
just engine-dist        # 打包引擎发行版 (CLI + Python + Web)
```

**Web 对局调试台**: React + TypeScript 做的调试界面, 在浏览器里用 WASM 跑真实引擎, 也能切本地
HTTP 计算. 能配置种子, 牌组, 赌注, 在历史里回溯, 查看真实牌堆和随机状态.

```shell
just engine-web         # 启动调试台
just engine-web-dev     # 前端热更新模式
just test-engine-web    # 跑测试
```

**AI 自动玩**: 带 mod 的版本内置了 HTTP 接口, 可以让 AI 在游戏里自动打牌, 还能在游戏内显示决策
消息和按局录像. 接口见 [agent 接口](docs/agent-api.md), 解说要求见
[agent 解说](docs/agent-commentary.md).

```shell
just macos run-agent    # 或 just windows run-agent, 打包带 mod 版本并启动
just agent-wait         # 在另一个终端里等开场动画播完
just agent-call <方法> '<参数 JSON>'
```

游戏内直接连大模型的内置 AI 还在开发, 设计见 [内置 agent](docs/builtin-agent.md), 它的流式网络库
`native/bbnet` 用 Rust 写, 测试用 `just native test`.

**录像与回放**: 能按局录制视频, 时间线和回放文件, 也能在游戏里回放任意一局, 手打的局也可以.
录像与回放用 `BB_CONTROL` 互斥, 详见 [录像](docs/recording.md) 与 [回放](docs/replay.md).

回放有两个入口: 游戏主菜单的 选项 -> 回放, 以及命令行 `just macos replay <回放文件>`, 后者按退出码
结束, 适合放进 CI 与对拍.

**规则手册**: [docs/game](docs/game/README.md) 是面向自动游玩 agent 的规则知识库, 覆盖一局流程,
牌型与计分, 盲注与赌注, 经济与商店, 以及全部卡牌条目. [docs/rewrite](docs/rewrite/README.md) 记录
重写过程中的行为审计与对拍基准.

## 重打包

三个平台都能打, 也可以让 just 按当前平台自动选择:

```shell
just dist               # 按当前平台打包
just macos dist         # 打包 macOS 应用包
just android dist       # 打包 Android 安装包
just windows dist       # 打包 Windows 免安装版
```

产物在 `dist/` 下按平台分目录. 每个平台另有 `dist-modded`, 打包内置 `mods/` 中 mod 的版本, 它与
原版可同时安装, 存档互不影响, 详见 [modding.md](docs/modding.md).

**macOS**: 产物 `dist/macos/Balatro.app`, 可以整体拷贝到 `/Applications` 后双击运行. 应用包为
ad-hoc 签名并已清除隔离属性, 首次打开无需放行. 换图标用 `just macos icon 图标.png`.

**Android**: 产物 `dist/android/Balatro-<版本>.apk`, 包名 `com.azazo1.balatro`, 用
`just android install` 或 `adb install -r` 安装. 需要 Android SDK 的 build-tools (提供 `apksigner`
与 `zipalign`) 以及 JDK 17, 不需要 NDK 与 gradle.

**Windows**: 产物 `dist/windows/Balatro-<版本>-win64.zip`, 解压后运行 `Balatro.exe`. 这是单文件融合
形态, 游戏资源直接附在 exe 末尾, 但同目录的 `love.dll` 等 DLL 必须保留. 需要看 `print` 输出时用
`just windows console` 产出带控制台窗口的版本.

各平台的完整参数, 签名密钥, 沙箱注意事项, 目录清单, 以及为适配平台改动了游戏代码的哪些地方, 见
[打包与运行细节](docs/packaging.md).

## 存档

| 平台 | 位置 |
| --- | --- |
| macOS | `~/Library/Application Support/Balatro` |
| Windows | `%AppData%\Balatro` |
| Android | `/storage/emulated/0/Android/data/com.azazo1.balatro/files/save/game` |

存档内容在三个平台上格式相同, 可以互相拷贝迁移. Android 的存档写在外置存储而不是应用内部目录,
用文件管理器或 `adb pull` 就能备份, 不需要 root. 目录内容与游戏配置见
[打包与运行细节](docs/packaging.md).

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `game/` | 从发行包中提取的游戏资源, 构建输入 |
| `engine/` | Rust 规则引擎, 含 Web 调试台, HTTP 服务与 Python 绑定 |
| `mods/` | 打包进带 mod 版本的 mod |
| `native/bbnet/` | 内置 agent 的流式网络库, 用 Rust 编写 |
| `docs/` | agent 接口与解说, 录像回放, 规则手册等文档 |
| `scripts/` | 打包与工具脚本 |
| `vendor/` | 各平台官方 LÖVE 11.5 运行时 |
| `dist/` | 构建输出, 不纳入版本控制 |
| `recordings/` | agent 对局的录像与日志, 不纳入版本控制 |

完整的目录清单见 [打包与运行细节](docs/packaging.md).

## 版本号

版本号写作 `<上游版本>-<仓库版本>`, 例如 `1.0.1o-0.1.0`. 日常构建不带版本参数, 自动得到
`<上游版本>+<短哈希>`, 与发布版本区分. Android 的 `versionCode` 由两段版本折算, 保证单调递增,
否则无法覆盖安装, 详见 [打包与运行细节](docs/packaging.md).

## 开发

改了 Lua 想立刻看效果时不必重新打包, `vendor/` 里的 LÖVE 运行时本身不含游戏, 直接让它读取源码
目录即可, 改完存盘再跑就是新代码:

```shell
unzip -q vendor/love-11.5-macos.zip -d .tmp/love-run
.tmp/love-run/love.app/Contents/MacOS/love game
```

```shell
just check-lua          # 用 LuaJIT 校验 game/ 下的 lua 语法
just test-scripts       # 运行打包脚本的单元测试
just test-agent         # 运行 agent mod 的纯逻辑单元测试 (需要 luajit)
```

需要验证打包形态时再走 `just macos dist` 等完整流程, 其它开发方式见
[打包与运行细节](docs/packaging.md).

## 已知情况

- Windows, macOS 与 Android 产物均已在目标机器上人工确认可以正常进入游戏.
- 游戏资源取自 PC 版, 因此触摸操控可用但界面按 PC 版布局缩放, 没有官方移动版专门调整过的默认
  分辨率与旋转处理.
- 三个平台均无 Steam 集成, 成就与进度由本地存档记录.
