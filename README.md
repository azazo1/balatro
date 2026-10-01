# Balatro 多平台重打包

把 Windows 版 Balatro 发行包 (`assets/Balatro.exe`) 中的游戏资源提取出来, 用官方 LÖVE 11.5
运行时重新组装成 macOS, Android 与 Windows 三个平台可直接运行的产物.

游戏版本为 `1.0.1n-FULL`. 本项目用于学习和编辑游戏代码, 以及研究 LÖVE 游戏在多个平台上的
打包方式.

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `assets/Balatro.exe` | 原始 Windows 自解压发行包, 仅作来源保留, 不参与构建 |
| `assets/icon.png` | 应用图标源图, 1024x1024, 由 `game/resources/textures/2x/Jokers.png` 第一格裁出 |
| `game/` | 从发行包中提取的游戏资源, 构建输入 |
| `vendor/` | 各平台官方 LÖVE 11.5 运行时, 打包时校验 sha256 |
| `scripts/lib/` | 打包用的可复用模块 (PNG 与 icns, 二进制 manifest, zip 等) |
| `scripts/package_*.py` | 各平台的打包入口 |
| `scripts/lib/modding/` | 打包时应用 lovely 补丁, 见 [docs/modding.md](docs/modding.md) |
| `mods/` | 打包进带 mod 版本的 mod |
| `dist/` | 构建输出, 不纳入版本控制 |
| `docs/changelog/` | 各版本的发布说明 |

`game/` 里的内容与发行包中的原始文件逐字节一致, 只有少数文件为平台适配做过改动,
每一处都在下文的适配说明中列出.

## 打包

三个平台各有独立入口, 也可以让 just 按当前平台自动选择:

```shell
just dist            # 按当前平台打包
just macos dist      # 打包 macOS 应用包
just android dist    # 打包 Android 安装包
just windows dist    # 打包 Windows 免安装版
```

产物都在 `dist/` 下按平台分目录. 每个平台另有 `dist-modded`, 打包内置 `mods/` 中 mod 的版本,
它与原版可同时安装, 存档互不影响, 详见 [docs/modding.md](docs/modding.md). mod 版内置供 agent
游玩的 HTTP 接口 (默认关闭), 支持在游戏内显示决策消息和按局录制, 见 [docs/agent-api.md](docs/agent-api.md).
游戏内直接连接大模型的内置 agent 正在开发, 设计见 [docs/builtin-agent.md](docs/builtin-agent.md),
它的流式网络库 `native/bbnet` 用 Rust 编写, 需要先编译 (`just native build macos`, `just native build android`). 其它 recipe:

```shell
just check-lua       # 用 LuaJIT 校验 game/ 下的 lua 语法
just check-scripts   # 校验打包脚本的 python 语法
just test-scripts    # 运行打包脚本的单元测试
just test-agent      # 运行 agent mod 的纯逻辑单元测试 (需要 luajit)
just native test     # 运行原生库 bbnet 的单元测试 (需要 cargo)
just mods-check      # 检查 mod 补丁的命中情况
just clean           # 删除 dist/
```

打包脚本只用 Python 标准库, 不需要安装第三方依赖, 也不会修改系统环境.

### macOS

```shell
just macos dist
```

产物 `dist/macos/Balatro.app`, 可以整体拷贝到 `/Applications` 后双击运行. 应用包为 ad-hoc
签名并已清除隔离属性, 首次打开无需放行.

换图标时传入自己的正方形 png, 建议 1024x1024 以上:

```shell
just macos icon 图标.png
```

### Android

```shell
just android dist
```

产物 `dist/android/Balatro-<版本>.apk`, 包名 `com.azazo1.balatro`. 安装:

```shell
just android install          # 打包并安装到已连接设备
adb install -r dist/android/Balatro-*.apk
```

需要 Android SDK 里装有 `build-tools` (提供 `apksigner` 与 `zipalign`) 以及 JDK 17
(用于首次生成签名密钥). 不需要 NDK 与 gradle, 因为运行时用的是官方预编译产物.

签名密钥默认生成在 `secrets/balatro.keystore`, 该目录不纳入版本控制, `just clean` 也不会删它.
同一个应用要覆盖安装必须用同一个密钥, 换密钥只能先卸载. 也可以指定自己的密钥与口令:

```shell
just android keystore 我的.jks
BALATRO_KEYSTORE_PASS=口令 just android dist
```

### Windows

```shell
just windows dist
```

产物 `dist/windows/Balatro-<版本>-win64.zip`, 解压后运行 `Balatro.exe`. 这是单文件融合形态,
游戏资源直接附在 exe 末尾, 因此不需要额外的游戏文件, 但 `love.dll` 等同目录 DLL 必须保留.

需要看 `print` 输出时再产出带控制台窗口的版本:

```shell
just windows console
```

## 存档

各平台的存档位置:

| 平台 | 位置 |
| --- | --- |
| macOS | `~/Library/Application Support/Balatro` |
| Windows | `%AppData%\Balatro` |
| Android | `/storage/emulated/0/Android/data/com.azazo1.balatro/files/save/game` |

存档内容在三个平台上格式相同, 可以互相拷贝迁移. 目录名不同: 桌面是 `Balatro`, Android 是 `game`,
原因见下文.

Android 的存档通过 `t.externalstorage` 写入外置存储, 而不是应用内部的
`/data/user/0/com.azazo1.balatro/files/`. 前者可以用文件管理器或 `adb pull` 直接取出备份,
后者无 root 权限无法访问. PhysicsFS 建的目录和文件只有属主权限, 外部工具只能看到空目录,
`game/android_storage.lua` 会补上组权限, 与其他应用在 `Android/data` 下的权限一致.

目录内容:

| 路径 | 内容 |
| --- | --- |
| `settings.jkr` | 全局设置, 如音量, 语言, 显示选项 |
| `metrics.jkr` | 统计指标, 运行后生成 |
| `<槽位>/profile.jkr` | 进度, 如解锁项, 最高分, 成就 |
| `<槽位>/meta.jkr` | 已解锁, 已发现, 已提示的条目 |
| `<槽位>/unlock_notify.jkr` | 待显示的解锁通知队列 |
| `<槽位>/save.jkr` | 进行中的对局, 中途退出后用于继续 |

存档目录名取自 `.love` 归档去掉扩展名后的文件名. 桌面上是打包脚本中的 `APP_NAME`, 当前为
`Balatro`; Android 运行时固定从 `assets/game.love` 读取游戏, 所以是 `game`. 若改动 `APP_NAME`
重新打包, 桌面版会认到一个空目录, 需要把旧目录改名或搬迁过去.

`.jkr` 是 deflate 压缩后的 Lua 表序列化结果, 不是纯文本, 无法直接当 JSON 编辑.

## 游戏配置

游戏没有单独的配置文件, 相关设置分散在四个地方, 按可修改程度从低到高排列.

| 位置 | 性质 | 是否随包固定 |
| --- | --- | --- |
| `game/version.jkr` | 发行标记, 记录完整版本, 基础版本与构建变体 | 是, 运行时不读取 |
| `game/conf.lua` | LÖVE 引擎配置, 如窗口尺寸与存档位置 | 是, 重新打包才能改 |
| `game/globals.lua` 的 `G.F_*` | 功能开关, 并按操作系统覆盖 | 是, 重新打包才能改 |
| `settings.jkr` | 玩家设置, 在游戏内选项菜单中修改 | 否 |

`settings.jkr` 是通常所说的游戏配置, 与存档位于同一目录, 默认值定义在 `globals.lua`,
主要字段包括 `SOUND`, `GRAPHICS`, `WINDOW`, `language`, `GAMESPEED` 与 `ACHIEVEMENTS_EARNED`
等. 其中的 `version` 字段用于设置文件自身的版本比对, 以便在不兼容时迁移.

## 平台适配说明

游戏本体是 LÖVE 的 fused 发行版, 资源部分跨平台可用, 但 Windows 版自带的 `love.dll` 与
`luasteam.dll` 等原生模块无法在其它平台加载, 因此三个平台都以官方 LÖVE 11.5 作为运行时.
各平台的做法:

| 平台 | 做法 |
| --- | --- |
| macOS | 复制官方 `love.app`, 游戏资源作为 `.love` 放入 `Contents/Resources` |
| Android | 在官方 embed APK 基础上替换游戏负载, 改写 manifest 后重新签名 |
| Windows | 把 `.love` 追加到 `love.exe` 末尾形成单文件可执行程序 |

为平台适配而对游戏代码做的改动集中在以下几处:

- `game/main.lua`: 原版在 macOS 与 Windows 分支中直接 `require 'luasteam'` 并在初始化失败时
  调用 `love.event.quit()`, 而该模块需要随包分发, 缺失时游戏会立即退出. 现在改为尝试加载,
  失败则按无 Steam 模式继续运行.
- `game/main.lua`: Android 上退出时直接把进程结束掉, 见下文 "Android 的退出处理".
- `game/conf.lua`: 增加 `t.externalstorage = true`, 让 Android 存档写入外置存储.
- `game/android_storage.lua` (新增, 由 `conf.lua` 加载): Android 上给存档目录补组权限, 让文件管理器能看到内容.

无 Steam 模式下的行为: 成就与进度由本地存档记录, 游戏内成就通知照常显示; 通过 Steam 同步的
统计数据不生效, 不影响玩法; 游戏内跳转商店或社区的外链按钮照常打开浏览器.

### Android 的实现细节

`AndroidManifest.xml` 是二进制 XML, 其中字符串以 UTF-16 存储, 无法直接文本替换.
`scripts/lib/android_manifest.py` 会解析字符串池并按索引替换, 再重建池与内部偏移, 所以新
包名与原包名长度不同也没问题. 其中 `android:name` 指向的 `org.love2d.android.GameActivity`
是 Java 类名, 必须保持原样, 只有 `package`, provider 的 `authorities` 与自定义权限
`<包名>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` 需要跟着改. 权限名不改的话, 原版与 modded
两个包会声明同名权限, 签名不同时第二个装不上.

屏幕方向设为 `sensorLandscape`, 即锁定横屏但允许随手机方向左右翻转.

#### 退出处理

Android 上 Activity 结束并不等于进程结束, 系统会把进程留着以便下次快速启动. 这与 LÖVE 的
假设冲突: LÖVE 的各模块是进程级单例, `love.filesystem` 底层是 PhysicsFS 的全局状态, 要等
`liblove.so` 卸载时模块析构才会把状态还回去, 而进程不结束就不会卸载它. 于是退出后残留的进程
会让下一次启动的 `love.filesystem.init()` 抛 `already initialized`, 线程随即结束, 表现为
点击图标进不去游戏.

`game/main.lua` 里的 `exit_process()` 在退出前结束进程来规避: 在 Android 上用 LuaJIT 的 FFI
调 libc 的 `_exit(0)`. 选 `_exit` 而不是 `exit`, 是因为前者只是一次系统调用, 不必运行 atexit
与动态库析构, 也就不会和音频等后台线程抢锁. 主循环与 `love.errhand` 的退出路径统一调用它,
这样无论是点退出键, 按返回键, 还是崩溃界面里退出, 下次都能正常启动. 取不到 FFI 时静默退回
LÖVE 自己的退出流程, 不影响其它平台 (它们本来就随退出结束进程).

### Windows 的实现细节

融合后的 exe 回读校验放在 `scripts/verify_windows_bundle.py`, 本机与 CI 共用同一份实现,
会检查 PE 头, 尾部 zip 的起点, 以及归档内确实含有 `main.lua` 与 `conf.lua`.

## 版本号

版本号分两段, 形式为 `<上游版本>-<仓库版本>`:

| 段 | 含义 | 来源 |
| --- | --- | --- |
| 上游版本 | 游戏自身版本 | `game/version.jkr` 首行 |
| 仓库版本 | 本仓库重打包的版本 | 由发布 tag 指定 |

例如 `1.0.1n-0.1.0` 表示上游游戏 `1.0.1n` 的第 `0.1.0` 次重打包.

这样分段是因为同一份游戏可能被重打包多次: 只写上游版本则一个版本只能发布一次, 之后修正
打包问题就无法再发新版. 分段后 `1.0.1n-0.1.0` 与 `1.0.1n-0.2.0` 是两次独立发布.

未发布的构建使用 `<上游版本>+<短哈希>`, 例如 `1.0.1n+32cfe92`, 与发布版本在形式上明确区分.

Android 的 `versionCode` 由两段版本折算而来, 保证单调递增, 否则设备上无法覆盖安装:

```
1.0.1n-0.1.0  ->  10001010
1.0.1n-0.2.0  ->  10001020
1.0.2n-0.1.0  ->  10002010
```

其中上游三段各占两位十进制, 仓库三段各占一位.

## 持续集成

`.github/workflows/build.yml` 在三种情况下运行:

每个平台的 job 按 `flavor` 矩阵并行构建原版与带 mod 的版本, 后者产物名以 `balatro-modded-` 开头.

- 推送到任意分支或提交 PR: 构建三个平台的产物并上传 Actions artifact, 不创建 release.
- 推送 `v*` 形式的 tag: 校验版本后构建, 汇总产物生成 `SHA256SUMS`, 创建或更新 GitHub Release.
- 手动触发: `tag` 留空表示只跑 CI, 填写已有 tag 表示发布该 tag.

发布前需要在仓库的 Actions secrets 中配置签名密钥, 私钥不入库:

| secret | 说明 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | 密钥库文件的 base64 编码, 例如 `base64 -i balatro.keystore` 的输出 |
| `ANDROID_KEYSTORE_PASS` | 密钥库口令 |
| `ANDROID_KEY_ALIAS` | 密钥别名, 通常是 `balatro` |

发布说明维护在 `docs/changelog/<版本>.md`, 打 tag 时其内容会同时用作 annotated tag 的正文,
CI 会校验两者一致; 同时还会校验 tag 中的上游版本与 `game/version.jkr` 相符, 免得打错版本:

```shell
git tag -a "v1.0.1n-0.1.0" --cleanup=verbatim -F "docs/changelog/1.0.1n-0.1.0.md"
git push origin main
git push origin "v1.0.1n-0.1.0"
```

## 学习与修改游戏代码

改代码有两种循环, 按需要选择.

**改了 Lua 想立刻看效果, 不必重新打包.** `vendor/` 里的 LÖVE 运行时本身不含游戏, 直接让它
读取源码目录即可:

```shell
unzip -q vendor/love-11.5-macos.zip -d .tmp/love-run
.tmp/love-run/love.app/Contents/MacOS/love game
```

改完存盘再跑就是新代码, 秒级. 注意这种方式下存档位于
`~/Library/Application Support/LOVE/game`, 与打包产物的存档目录不同, 属于正常现象.

**需要验证打包形态时**再走 `just macos dist` 等完整流程.

另外 LÖVE 会把存档目录挂进文件搜索路径且优先级高于游戏包, 所以把改过的文件放到存档目录里
同名覆盖也能生效, 适合不动源码做实验, 删掉文件即恢复. 例外是 `conf.lua`, 它加载得比存档
目录挂载更早, 因此无法用这种方式覆盖.

## 已知情况

- Windows 产物未在真机验证, macOS 和 Android 产物已在目标机器上人工确认可以正常进入游戏.
- 游戏资源取自 PC 版, 因此触摸操控可用但界面按 PC 版布局缩放, 没有官方移动版专门调整过的
  默认分辨率与旋转处理.
- 三个平台均无 Steam 集成.
