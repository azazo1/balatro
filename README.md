# Balatro macOS 重打包

把 Windows 版 Balatro 发行包 (`assets/Balatro.exe`) 中的游戏资源提取出来, 用官方 LÖVE 11.5
macOS 运行时重新组装成可在 macOS 上直接运行的应用包.

游戏版本为 `1.0.1n-FULL`.

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `assets/Balatro.exe` | 原始 Windows 自解压发行包, 仅作来源保留, 不参与构建 |
| `assets/icon.png` | 应用图标源图, 1024x1024, 由 `game/resources/textures/2x/Jokers.png` 第一格裁出 |
| `game/` | 从发行包中提取的游戏资源, 构建输入 |
| `vendor/love-11.5-macos.zip` | 官方 LÖVE 11.5 macOS 运行时, 通用二进制 (x86_64 + arm64) |
| `scripts/package-macos.sh` | 打包脚本 |
| `dist/` | 构建输出, 不纳入版本控制 |

`game/` 里的内容与发行包中的原始文件逐字节一致, 仅 `main.lua` 为适配 macOS 做过改动.

## 打包

```shell
just package-macos
```

产物为 `dist/Balatro.app`, 可以整体拷贝到 `/Applications` 后双击运行. 默认使用
`assets/icon.png` 作为应用图标, 需要换图标时传入自己的正方形 png (建议 1024x1024 以上):

```shell
just package-macos-icon icon.png
```

打包 Android 安装包:

```shell
just package-android
```

产物为 `dist/Balatro-1.0.1n.apk`, 用 `adb install -r <apk>` 安装. 该流程不编译原生代码,
详见下文的 Android 一节. 覆盖包名或指定密钥:

```shell
just package-android-package com.foo.bar
just package-android-keystore 我的.jks
```

其它 recipe:

```shell
just check-lua   # 用 LuaJIT 校验 game/ 下的 lua 语法
just clean       # 删除 dist/
```

## macOS 适配说明

游戏本体是 LÖVE fused 发行版, 资源部分跨平台可用, 但 Windows 版自带的 `love.dll` 与
`luasteam.dll` 无法在 macOS 上加载, 因此运行时替换为官方 macOS 版 LÖVE 11.5, 游戏资源
打包为 `Balatro.love` 放入 `Contents/Resources/`. LÖVE 会在该目录下查找 `.love` 并进入伪
融合模式, 存档目录由此落在 `~/Library/Application Support/Balatro`.

`main.lua` 的改动只有一处: 原版在 macOS 分支中直接 `require 'luasteam'` 并在初始化失败时
调用 `love.event.quit()`, 而该模块是需要随包分发的原生扩展, 缺失时游戏会立即退出. 现在改为
尝试加载, 失败则按无 Steam 模式继续运行.

无 Steam 模式下的行为:

- 成就与进度由本地存档记录, 游戏内成就通知照常显示.
- 通过 Steam 同步的统计数据不生效, 不影响玩法.
- 游戏内所有跳转 Steam 商店或社区的外链按钮照常打开浏览器.

## 存档

存档位于:

```
~/Library/Application Support/Balatro
```

其中 `1/` 对应第 1 个存档槽, 槽位 2 和 3 依次为 `2/` 与 `3/`.

| 路径 | 内容 |
| --- | --- |
| `settings.jkr` | 全局设置, 如音量, 语言, 显示选项 |
| `metrics.jkr` | 统计指标, 运行后生成 |
| `<槽位>/profile.jkr` | 进度, 如解锁项, 最高分, 成就 |
| `<槽位>/meta.jkr` | 已解锁, 已发现, 已提示的条目 |
| `<槽位>/unlock_notify.jkr` | 待显示的解锁通知队列 |
| `<槽位>/save.jkr` | 进行中的对局, 中途退出后用于继续 |

存档目录名取自 `.love` 归档去掉扩展名后的文件名, 也就是打包脚本中的 `APP_NAME`. 当前为
`Balatro`, 所以没有 `LOVE` 这一层目录. 若改动该变量重新打包, 游戏会认到一个空目录, 需要
把旧目录改名或搬迁过去才能继续使用原有存档.

`.jkr` 是 deflate 压缩后的 Lua 表序列化结果, 不是纯文本, 无法直接当 JSON 编辑. 迁移时整个
目录拷贝即可, Windows 版存档在 `%AppData%\Balatro`, 与这里使用同一个身份标识, 可以直接
整目录覆盖. 需要重开时删除该目录, 或只删除对应的槽位子目录.

存档路径为 `~/Library/Application Support/Balatro` 而非 `~/Library/Containers/` 下的沙箱
容器, 因为应用包为 ad-hoc 签名且未启用 App Sandbox.

## 游戏配置

游戏没有单独的配置文件, 相关设置分散在四个地方, 按可修改程度从低到高排列.

| 位置 | 性质 | 是否随包固定 |
| --- | --- | --- |
| `game/version.jkr` | 发行标记, 记录完整版本, 基础版本与构建变体 | 是, 运行时不读取 |
| `game/conf.lua` | LÖVE 引擎配置, 如窗口尺寸与标题 | 是, 重新打包才能改 |
| `game/globals.lua` 的 `G.F_*` | 功能开关, 并按操作系统覆盖 | 是, 重新打包才能改 |
| `settings.jkr` | 玩家设置, 在游戏内选项菜单中修改 | 否 |

`version.jkr` 内容形如:

```
1.0.1n-FULL
1.0.1n
PROD_PC_Console
```

依次为完整版本, 基础版本和构建变体, 其中基础版本即打包脚本写入 `CFBundleVersion` 的值.

`conf.lua` 中 `t.window` 的宽高为 0, 实际窗口由游戏按玩家设置自行创建. 该文件未设置
`t.identity`, 因此存档目录名只能取自 `.love` 归档的文件名, 这也是上一节所述目录名的由来.

`G.F_*` 是一组编译进包里的常量, 例如 `F_NO_ACHIEVEMENTS`, `F_VIDEO_SETTINGS`,
`F_SAVE_TIMER`, `F_EXTERNAL_LINKS`. 定义之后会按平台覆盖, 其中已包含 macOS 分支, 会设置
存档节流间隔, 语言选择与崩溃上报等. 游戏本身即以 macOS 为目标平台之一, 移植只需补齐
`main.lua` 中缺失的 Steam 模块.

`settings.jkr` 是通常所说的游戏配置, 与存档位于同一目录, 默认值定义在 `globals.lua`.
游戏内选项菜单的改动会经 `save_settings` 写回该文件. 主要字段:

| 字段 | 内容 |
| --- | --- |
| `SOUND` | `volume`, `music_volume`, `game_sounds_volume` |
| `GRAPHICS` | `texture_scaling` (1x 或 2x), `shadows`, `crt`, `bloom` |
| `WINDOW` | `screenmode`, `vsync`, `selected_display`, `DISPLAYS` |
| `language` | 语言代码, 如 `zh_CN` |
| `GAMESPEED` | 0.5, 1, 2, 4 倍速 |
| `colourblind_option`, `screenshake`, `rumble` | 辅助显示与手感 |
| `ACHIEVEMENTS_EARNED` | 成就达成记录 |
| `CUSTOM_DECK` | 自定义牌组 |
| `version` | 该文件自身的版本号 |

末项用于设置的版本比对, 读取时会与游戏版本比较, 以便在不兼容时迁移.

本仓库未改动以上任何一层, 仅 `main.lua` 等文件因移植需要做过修改. 打包参数位于
`scripts/package-macos.sh` 与 `scripts/package-android.sh` 顶部的常量, 包括应用名, 版本号
与运行时校验值.

## Android 适配说明

Android 版不重新编译原生代码. `vendor/love-11.5-android-embed.apk` 是官方 LÖVE 11.5 的
embed 模板, 其中已编译好 `liblove.so` (arm64-v8a 与 armeabi-v7a 两套), 打包只需:

1. 把 `game/` 压成 `game.love` 放进 `assets/`;
2. 改写 `AndroidManifest.xml` 的包名, 应用名, 版本号与屏幕方向;
3. 替换各密度图标;
4. 用本地密钥签名.

因此不需要 NDK, 不需要 gradle, 也不需要下载 SDK platform 或 NDK 组件. 只要 Android SDK 里
有 `build-tools` (提供 `apksigner` 与 `zipalign`) 即可, 脚本会自动定位, 也可用 `ANDROID_HOME`
指定 SDK 路径.

`AndroidManifest.xml` 是二进制 XML, 其中字符串以 UTF-16 存储, 无法直接文本替换.
`scripts/patch-manifest.py` 会解析字符串池并按索引替换, 再重建池与内部偏移, 所以新包名与
原包名长度不同也没问题. 其中 `android:name` 指向的 `org.love2d.android.GameActivity` 是
Java 类名, 必须保持原样, 只有 `package` 与 provider 的 `authorities` 需要跟着改.

屏幕方向设为 `sensorLandscape`, 即锁定横屏但允许随手机方向左右翻转.

签名密钥默认生成在 `dist/balatro-local.keystore`, 该目录不纳入版本控制. 同一个应用要覆盖
安装必须用同一个密钥, 换密钥只能先卸载. 注意不要把私钥提交进仓库.

### 与官方移动版的差异

官方 Android 版是另一套构建, 本次打包直接使用 PC 版资源, 因此:

- 触摸操控可用. 相关逻辑本来就在 `engine/controller.lua` 中, 与移动版逐行一致, 包括用
  长按 (`MIN_HOVER_TIME`) 替代鼠标悬停.
- 界面按 PC 版布局缩放, 没有移动版专门调整过的默认分辨率与旋转处理.
- 无 Steam 集成, 成就由本地存档记录.

移植时另有一处必要修改: 在 arm 系列平台关闭 LuaJIT. LÖVE 自身的注释说明, ARM64 上
LuaJIT 的编译内存范围有限, 被 SDL 等库占用后 JIT 编译会失败且耗时很长, 官方移动版正是
为此在 Android 上调用 `jit.off()`. 本仓库把这处判断扩展到 `OS X` 与 `Android` 两个平台.

## 已知情况

- 应用包为 ad-hoc 签名, 已清除隔离属性, 首次打开无需放行操作.
- 启动验证需要在图形界面中进行, macOS 版已在目标机器上人工确认可以正常进入游戏.
- Android 版尚未在真机上验证.
