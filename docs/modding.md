# 带 mod 的构建

原版 Balatro 的 mod 生态依赖两层: [lovely](https://github.com/ethangreen-dev/lovely-injector)
在游戏运行时拦截 Lua 代码加载并按 toml 补丁改写源码, [Steamodded](https://github.com/Steamodded/smods)
在它之上提供 mod 加载器与 API. lovely 需要向进程注入原生库, Android 上做不到, 本仓库的官方
LÖVE 运行时也不含它.

这里改为在打包时完成 lovely 的工作: 按 lovely 0.10.0 的规则把补丁预先打进游戏与 mod 源码,
再在包内附上一个 Lua 写的 lovely 运行时替身. Steamodded 以及依赖它的 mod 因此不必修改就能运行,
三个平台共用同一套产物.

## 用法

mod 放在仓库的 `mods/` 目录, 结构与游戏存档目录下的 `Mods/` 相同, 每个 mod 一个文件夹或 zip.
该目录纳入版本管理, CI 用它构建带 mod 的版本.

```shell
just mods-check              # 检查补丁在当前游戏版本上的命中情况
just mods-tree               # 生成补丁后的源码树 dist/modded-tree, 便于查看结果
just macos dist-modded       # 打包 dist/macos/Balatro-Modded.app
just macos run-modded        # 打包后在终端运行, 直接看到日志
just android dist-modded     # 打包 dist/android/Balatro-Modded-<版本>.apk
just windows dist-modded     # 打包 dist/windows/Balatro-Modded-<版本>-win64
```

各 recipe 都可以另传 mod 目录, 例如 `just mods-check 别处/Mods`. 打包脚本对应的参数是
`--mods [目录]`, 加 `--strict-mods` 时有补丁未命中则构建失败.

`mods/lovely/blacklist.txt` 与 mod 文件夹内的 `.lovelyignore` 仍然有效, 被屏蔽的 mod 不会打包.

## 与原版的区别

带 mod 的版本使用独立标识, 与原版可以同时安装, 存档互不影响:

| 平台 | 应用 | 存档目录 |
| --- | --- | --- |
| macOS | `Balatro-Modded.app`, `local.balatro.modded` | `~/Library/Application Support/Balatro-Modded` |
| Windows | `Balatro-Modded-<版本>-win64/Balatro.exe` | `%AppData%\Balatro-Modded` |
| Android | `com.azazo1.balatro.modded` | `/storage/emulated/0/Android/data/com.azazo1.balatro.modded/files/save/Balatro-Modded` |

想沿用原版进度, 把原版存档目录里的内容拷过去即可.

首次启动时, 包内的 mod 会释放到存档目录的 `Mods/` 下, Steamodded 从这里读取它们, mod 的配置
也写在这里. 之后只在包内 mod 变化时重新释放. 与包内 mod 同名的文件夹会被覆盖, 其余文件夹不动,
因此也可以手动往 `Mods/` 里放不含 lovely 补丁的纯 Steamodded mod.

运行时替身的日志写在 `Mods/lovely/log/lovely-shim.log`.

启动时设环境变量 `BALATRO_SAVE_IDENTITY=<目录名>` 可以临时换一个存档目录, 例如给 agent 单独一份存档.
只接受单层目录名, mod 会同样释放到该目录下.

## 内置 mod

| mod | 来源 | 说明 |
| --- | --- | --- |
| Steamodded | [26.829.0](https://github.com/Steamodded/smods/releases/tag/26.829.0) | mod 加载器与 API |
| balatrobot | [v1.5.2](https://github.com/coder/balatrobot/releases/tag/v1.5.2) | 供 agent 游玩的 HTTP 接口, 默认关闭, 见 [agent-api.md](agent-api.md) |
| compat-1.0.1n | 本仓库 | Steamodded 在 1.0.1n 上的兼容补丁, 不改玩法 |
| vanilla-ui | 本仓库 | 沿用原版的选牌组开局界面和 Run Info 的 Stake 页 |

Steamodded 默认把 "开始游戏" 的选牌组界面换成分页式, 把 Run Info 的 Stake 页换成自己的样式.
vanilla-ui 在运行时打开 Steamodded 自带的 `vanilla_run_select` 与 `vanilla_stake` 开关, 恢复原版界面,
不写入 Steamodded 的配置, 在 Steamodded 设置里关掉只对当次运行有效. 想要 Steamodded 的界面时,
从 `mods/` 删掉这个目录再打包. 装了新增开局页的 mod 时, Steamodded 会忽略这个开关.
主菜单的 Steamodded 版本号, MODS 按钮等小改动保留.

Steamodded 按较新的游戏版本编写, 在 1.0.1n 上有 3 个补丁未命中, `just mods-check` 会列出:

- `fixes.toml` 的 luasteam 补丁: 仓库移植 macOS 时已经做了同样的修改, 无需处理.
- `deck_skins.toml` 的 Production / Collabs 两条: 1.0.1n 的制作人员界面没有 Collabs 页.
  配套代码依赖该页生成的 `G.collab_credits`. 缺少它时, 每次切换阶段都会打开再关闭一次
  制作人员界面, Customize Deck 预览联名皮肤时也会报错. compat-1.0.1n 提前放一个空表规避.

## 实现

代码在 `scripts/lib/modding/`:

| 文件 | 职责 |
| --- | --- |
| `loader.py` | 发现并暂存 mod, 按 lovely 的顺序加载补丁文件 |
| `patches.py` | 补丁的字段校验与应用, 逐行对照 lovely-core 复刻 |
| `rust_regex.py` | 把 Rust regex 语法翻译为 Python re, 复刻匹配迭代与替换插值 |
| `metadata.py` | 按 Steamodded 的扫描规则找出 mod id 与根目录 |
| `targets.py` | 把补丁目标对应到游戏文件, 模块, mod 文件或运行时对象 |
| `build.py` | 串起整个流程, 生成源码树与运行时清单 |
| `lua/runtime.lua` | 运行时替身 |

lovely 的补丁目标是代码块名. 打包时没有加载钩子, 按来源分别处理:

| 目标 | 例子 | 处理 |
| --- | --- | --- |
| 游戏文件 | `card.lua`, `CRT.fs` | 直接改写源码树中的文件 |
| 模块补丁 | `=[lovely SMODS.version "version.lua"]` | 打好补丁后登记到 `package.preload` |
| mod 文件 | `=[SMODS _ "src/core.lua"]` | 改写包内 mod 的文件 |
| 按内容处理的目标 | `GLSL_ES_PATCHES.fs` | 对所有已知着色器预先算好结果, 运行时按内容哈希查表 |
| LÖVE 内置脚本 | `=[love "wrap_GraphicsShader.lua"]` | 运行时在生成的着色器头部上重放 pattern 补丁 |

`load_now` 模块在目标文件的代码执行前求值, 实现方式是在目标文件开头插入对运行时的调用,
不增加行数, 报错行号与原文件一致.

补丁里的 `{{lovely_hack:patch_dir}}` 在打包时换成占位符, 释放 mod 或加载模块时再换成真实路径.
它若出现在游戏文件里则无法处理, 构建会报错.

## 限制

- 补丁在打包时固定. 在 Steamodded 的界面里禁用带 lovely 补丁的 mod, 只会停止加载它的 Lua 代码,
  补丁仍然生效; 要彻底去掉需要从 `mods/` 移除后重新打包.
- 运行时动态生成, 打包时无法枚举的内容不会经过补丁, 例如 mod 用 Lua 字符串拼出的着色器.
- LÖVE 启动时生成的默认着色器早于替身接管, 不受 `wrap_GraphicsShader.lua` 补丁影响.
- 不支持 `before = "conf.lua"` 的 `load_now` 模块, 因为此时存档目录尚未确定.
- 正则补丁遇到 Python 无法等价表达的写法 (unicode 属性类, 字符类集合运算等) 时构建报错,
  不会生成行为不同的正则.
