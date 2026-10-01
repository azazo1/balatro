# Android

Android 上的存储位置, 存档目录的权限修正, 以及触摸流程. 录像编码见 [recording.md](<recording.md>) 的 "Android" 一节.

## 存储位置

`game/conf.lua` 设置了 `t.externalstorage = true`, 所以存档目录在 `/storage/emulated/0/Android/data/<包名>/files/save/<存档名>`, 不在需要 root 才能访问的 `/data/data/<包名>` (即 `/data/user/0/<包名>`). 原版的存档名是 `game` (取自 `assets/game.love`), modded 是 `Balatro-Modded`.

这一点已经用系统备份核实过:

- 存档文件都在外部 files 域 (`ef/save/game/...`).
- 内部 files 域 (`f/`) 下只有 LÖVE 启动时建的几个空目录.

所以不需要迁移.

外部工具看不到内容, 是权限问题, 不是位置问题. 真机 (小米 23013RK75C, Android 14) 上查清的三件事:

1. PhysicsFS 建目录用 0700, 建文件用 0600, 组位全是 0; 而且它的 mkdir 不补父目录, 新装的包第一次
   启动时 `files/save` 还不存在, 存档目录直接建失败 (日志 `Could not create save directory`),
   于是连存档目录都没有.
2. 应用的 umask 是 `0077`, 所以自己 mkdir 时请求的组位同样会被削掉 (`2770` 落成 `2700`); chmod 本身
   有效, 所以先 mkdir 再 chmod 是可行的. chmod 只能改 mode, 改不了属组.
3. 应用建的条目属组是应用自己 (`u0_aXXX`), 而系统给 `Android/data/<包名>` 与 vold 建的内容用的属组是
   `ext_data_rw`. adb shell, MT 管理器这类工具都在 `ext_data_rw` 组里, 所以属组不匹配时, 0660 的组位
   对它们没有意义; 而且普通应用不在 `ext_data_rw` 组里, `chown` 到该组会 `EPERM`.

`game/android_storage.lua` 因此做三件事:

- 缺的目录层级补建 (`mkdir` 逐级), 再 chmod, 让 PhysicsFS 的存档目录能建成功.
- 补权限: 目录 2770, 文件 0660; 每次都先试把属组改成从 `Android/data/<包名>` 读出来的
  `ext_data_rw`; 改不动就用 other 位兜底 (目录 0777, 文件 0666). 兜底在真机上让 `settings.jkr` 等
  存档能被 adb shell 读到, 而 `Android/data/<包名>` 本身由系统的 FUSE 拦着: 能进来读的只有本应用,
  adb shell 和有存储权限的文件管理器.
- 修正存档目录与包目录之间那几级 (`files`, `save`, 存档目录本身): 它们很少被写, 扫描 (从存档目录
  往下) 够不到, 不修的话外部工具连进都进不去.

时机有三个:

- 存档目录确定时, 整棵树扫一遍.
- 主线程经 `love.filesystem` 写入之后, 立即修正.
- 失去焦点或切到后台时, 再扫一遍.

有一个例外: 内置 agent 的配置文件含 key, 写入后要改回 0600, 不给组权限也不给 other 位, 兜底时同样
不参与 (`PRIVATE_FILES`). 真机上核对过: 目录可以被 shell 进入, `config/balatrobot.jkr` 的内容读不到.

要求所有写入都经过存档目录, 不写应用内部目录:

| 内容 | 位置 (相对存档目录) |
|---|---|
| 存档, 进度, 设置 (`settings.jkr`, `<档位>/profile.jkr`, `meta.jkr`, `save.jkr`) | 根目录与档位目录 |
| mod 配置, 包括内置 agent 的 endpoint 和 key | `config/` |
| lovely shim 释放的 mod 和日志 | `Mods/` 与 shim 的日志目录 |
| 录像, 时间轴, 回放文件, agent 转录 (每局一个 `<stem>/` 文件夹) | `recordings/` |

- 新增的写入 (bbnet 的 media 模块, 转录等) 一律用 `love.filesystem.getSaveDirectory()` 下的路径, 不用 Android 的内部目录.
- 不经过 `love.filesystem` 的写入 (`io.open`, `os.rename`, 编码线程等) 写完要调用 `android_storage.fix_path`,
  否则新文件是 0600, 外部工具读不到. 录像的时间线, 回放文件, 视频都是这样处理的. 失去焦点时的整树扫描不能兜底
  这类文件: 切出去时录像暂停, 时间线紧接着又重写一次, 扫描刚改好的权限马上被新文件盖掉.
- 原生库 `libbbnet.so` 由系统装在应用的 native 库目录, 只读, 不属于数据.

安全: key 以明文存在外部存储.

- 配置文件保持 0600, 靠组权限的 MT 管理器读不到 (真机已核对).
- Android 10 及以前, 有存储权限的应用可能仍能读到.
- 存档, 录像与回放文件没有秘密, 兜底时是 other 可读可写; 但能进到 `Android/data/<包名>` 的工具本来
  就只有本应用, adb shell 和有存储权限的文件管理器.

设置页要注明这一点.

## 权限与流程

权限: 运行时 APK 的 manifest 已声明 `android.permission.INTERNET`.

触摸流程:

1. 主菜单 → 模组 → balatrobot: 选内置模式, 粘贴 endpoint 和 key, 填模型名, 打开录像.
2. 开始: 主菜单打开 选项 → Agent → 开始, 或者手动开局后点 HUD 的 "选项" → Agent → 开始.
3. 暂停或停止: 选项 → Agent.
4. 回放: 主菜单 → 选项 → 回放, 选一个文件开始. 长按屏幕 1.5 秒中止.
5. 取出录像: USB 或 `adb pull` 访问 `Android/data/<包名>/files/save/<存档名>/recordings/`. 每局一个文件夹, 里面的文件带这一局的前缀. Android 11 起, 部分文件管理器不能浏览 `Android/data`, 这是系统限制. 用同样的方式把其他设备录下的回放文件放进这个目录 (放一个文件夹里, 或直接放根下都认), 就能在列表里看到.

生命周期:

- 切到后台: agent 自动暂停, 录像不补帧, 这一段按暂停处理 (剪辑版剪掉, 记入时间轴). 回放进行中时, 回放计时同样暂停, 回到前台后继续.
- agent 运行或回放进行时调用 `love.window.setDisplaySleepEnabled(false)`, 防止熄屏.
