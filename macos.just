# macOS 平台的打包入口.
python := if os_family() == "windows" { "python" } else { "python3" }
# 内联脚本 (下面 [script] 那些) 用哪个解释器. 这个设置只能在**本文件**里生效:
# mod 文件不会继承主 justfile 的 settings, 所以每个有内联脚本的文件都得自己写一行.
# 注意 `set` 是 const 上下文 —— 不能引用上面的 `python` 变量, 也不能调 os_family(),
# 所以只能写字面量; 本文件是 macOS 专用的, 写 python3 就是对的.
set script-interpreter := ['python3']

[private]
default:
    @just --justfile {{ quote(source_file()) }} --list

# 打包 macOS 应用包, 产出 dist/macos/Balatro.app.
dist:
    {{ python }} scripts/package_macos.py

# 打包并运行, 便于马上验证产物.
run: dist
    open dist/macos/Balatro.app

# just macos dist-modded [mod 目录]
# 打包带 mod 的应用, 产出 dist/macos/Balatro-Modded.app, 与原版可同时安装.
dist-modded mods="mods":
    {{ python }} scripts/package_macos.py --mods {{ mods }}

# 在终端里运行带 mod 的应用, 便于直接看到日志.
run-modded: dist-modded
    dist/macos/Balatro-Modded.app/Contents/MacOS/love

# just macos run-agent [on|off] [fast]
# 打包带 mod 的应用并开启 agent 接口运行, 使用独立存档 Balatro-Agent, 默认正常速度, 按局录制视频到 recordings/.
run-agent record="on" fast="0":
    {{ python }} scripts/run_agent.py macos {{ record }} {{ fast }}

# just macos replay recordings/<stem> [tight|original|fast]
# 按回放文件重玩一局并录制到 recordings/, 使用临时存档 Balatro-Replay, 期间锁定输入, 按住 Esc 1 秒中止.
# 参数可以是这一局的文件夹 (每局一个文件夹), 也可以是里面的 .replay.json 文件本身.
# 退出码由游戏给出并原样透传: 0 回放完成, 1 跑偏, 2 中止, 3 文件无法回放.
replay file pacing="tight": dist-modded
    {{ python }} scripts/replay_game.py {{ quote(file) }} {{ pacing }} --invocation-dir {{ quote(invocation_directory()) }}

# just macos replay-check <seed> <deck> <stake> [步数]
# 引擎先跑一局并写下每一步的预测状态, 再让真游戏照着重放逐步核对.
# 退出码 0 = 引擎全程预测正确; 1 = 在第 N 步跑偏 (日志里打印差在哪一项).
# 覆盖哪条路径由参数决定, 不再受已有录像限制; 换一副牌组/赌注就是一条新路径.
replay-check seed deck stake steps="240": dist-modded
    {{ python }} scripts/replay_check.py --seed {{ quote(seed) }} --deck {{ quote(deck) }} --stake {{ quote(stake) }} --steps {{ quote(steps) }} --invocation-dir {{ quote(invocation_directory()) }}

# just macos replay-check-decks <seed> <stake> [步数]
# 十五副牌组各让引擎跑一局, 再逐个交给真游戏重放核对, 最后打印一张结果表.
# 一副牌组一次游戏启动, 所以整条要跑十来分钟.
# 每副牌的**开局就是它的特征**: 无面牌组 40 张, 棋盘牌组只有两种颜色, 错乱牌组牌面随机,
# 画师牌组手牌上限 10 —— 全在 digest 的 `deck=` 与 `hand=` 里, 游戏点头才算数.
replay-check-decks seed stake steps="400": dist-modded
    {{ python }} scripts/replay_check.py --seed {{ quote(seed) }} --stake {{ quote(stake) }} --steps {{ quote(steps) }} --all-decks --invocation-dir {{ quote(invocation_directory()) }}

# just macos recordings-recover [--run] [--clean] [录像目录]
# 扫描 recordings/ 里崩溃后残留的中间文件并补做合成, 默认只列出,
# --run 执行, --clean 成功后删中间文件.
# 用 [script] 而不是把参数拼进命令行: `{{ args }}` 是不加引号拼的, 路径里有空格时
# 会被拆成两个参数 (实测 "/tmp/a b" 变成 `/tmp/a` 与 `b`). [positional-arguments]
# 会把每个参数按原样放进 argv, 空格和引号都不动.
[positional-arguments]
[script]
recordings-recover *args:
    import sys
    sys.path.insert(0, {{ quote(justfile_directory() + "/scripts") }})
    from recordings_recover import main
    sys.exit(main(sys.argv[1:]))

# 用指定 png 作为应用图标打包, 例如: just macos icon 图标.png
icon path:
    {{ python }} scripts/package_macos.py --icon {{ path }}

# 打包时沿用 LÖVE 自带图标, 不生成自定义图标.
default-icon:
    {{ python }} scripts/package_macos.py --no-icon
