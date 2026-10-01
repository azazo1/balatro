# macOS 平台的打包入口.
python := if os_family() == "windows" { "python" } else { "python3" }

[private]
default:
    @just --justfile {{ source_file() }} --list

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
# 打包带 mod 的应用并开启 agent 接口运行, 使用独立存档 Balatro-Agent, 默认正常速度, 按局录制完整版与剪辑版视频到 recordings/.
run-agent record="on" fast="0": dist-modded
    #!/usr/bin/env bash
    set -euo pipefail
    case {{ quote(record) }} in
        on|off) ;;
        *) echo "record 只能是 on 或 off, 收到: {{ record }}" >&2; exit 2 ;;
    esac
    case {{ quote(fast) }} in
        0|1) ;;
        *) echo "fast 只能是 0 或 1, 收到: {{ fast }}" >&2; exit 2 ;;
    esac
    mkdir -p recordings
    export BALATROBOT_ENABLE=1 BALATROBOT_FAST={{ quote(fast) }} BALATRO_SAVE_IDENTITY=Balatro-Agent
    if [ {{ quote(record) }} != off ]; then
        export BALATROBOT_RECORD={{ quote(record) }} BALATROBOT_RECORD_DIR="$PWD/recordings"
    fi
    # 游戏日志同时写进 recordings/, 崩溃后可以查.
    log="recordings/$(date +%Y%m%d-%H%M%S)-game.log"
    echo "游戏日志: $log"
    dist/macos/Balatro-Modded.app/Contents/MacOS/love 2>&1 | tee "$log"

# just macos replay recordings/<stem> [tight|original]
# 按回放文件重玩一局并录制到 recordings/, 使用临时存档 Balatro-Replay, 期间锁定输入, 按住 Esc 1 秒中止.
# 参数可以是这一局的文件夹 (每局一个文件夹), 也可以是里面的 .replay.json 文件本身.
replay file pacing="tight": dist-modded
    #!/usr/bin/env bash
    set -euo pipefail
    case {{ quote(pacing) }} in
        tight|original) ;;
        *) echo "pacing 只能是 tight 或 original, 收到: {{ pacing }}" >&2; exit 2 ;;
    esac
    file={{ quote(file) }}
    case "$file" in
        /*) ;;
        *) file={{ quote(invocation_directory()) }}/"$file" ;;
    esac
    if [ -d "$file" ]; then
        # 给的是文件夹: 进去找这一局的回放文件, 只有一个才认.
        found=()
        for candidate in "$file"/*.replay.json; do
            [ -f "$candidate" ] && found+=("$candidate")
        done
        if [ "${#found[@]}" -ne 1 ]; then
            echo "文件夹里没有唯一的回放文件 (找到 ${#found[@]} 个): $file" >&2
            exit 2
        fi
        file="${found[0]}"
    fi
    if [ ! -f "$file" ]; then
        echo "找不到回放文件: $file" >&2
        exit 2
    fi
    mkdir -p recordings
    export BALATROBOT_ENABLE=1 BALATRO_SAVE_IDENTITY=Balatro-Replay
    export BALATROBOT_REPLAY="$file" BALATROBOT_REPLAY_PACING={{ quote(pacing) }}
    export BALATROBOT_RECORD=on BALATROBOT_RECORD_DIR="$PWD/recordings" BALATROBOT_RECORD_PREFIX=replay-
    log="recordings/replay-$(date +%Y%m%d-%H%M%S)-game.log"
    echo "游戏日志: $log"
    # 退出码: 0 回放完成, 1 跑偏, 2 中止, 3 文件无法回放
    dist/macos/Balatro-Modded.app/Contents/MacOS/love 2>&1 | tee "$log"

# just macos recordings-recover [--run] [--clean] [录像目录]
# 扫描 recordings/ 里崩溃后残留的中间文件并补做合成, 默认只列出,
# --run 执行, --clean 成功后删中间文件.
recordings-recover *args:
    {{ python }} scripts/recordings_recover.py {{ args }}

# 用指定 png 作为应用图标打包, 例如: just macos icon 图标.png
icon path:
    {{ python }} scripts/package_macos.py --icon {{ path }}

# 打包时沿用 LÖVE 自带图标, 不生成自定义图标.
default-icon:
    {{ python }} scripts/package_macos.py --no-icon
