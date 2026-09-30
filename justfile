# 跨平台的 python 调用方式: Windows 上是 python, 其余平台是 python3
python := if os_family() == "windows" { "python" } else { "python3" }

[private]
default:
    @just --list

# 打包 macOS 应用包, 用法: just macos dist
mod macos

# 打包 Android 安装包, 用法: just android dist
mod android

# 打包 Windows 免安装版, 用法: just windows dist
mod windows

# 根据当前平台生成发布产物, 等价于对应平台模块的 dist.
# 需要指定平台时用 just macos dist / just android dist / just windows dist.
[macos]
dist:
    {{ python }} scripts/package_macos.py

[windows]
dist:
    {{ python }} scripts/package_windows.py

[linux]
dist:
    @echo "Linux 没有 LÖVE 官方运行时归档, 本仓库不为该平台打包." >&2
    @echo "想在 Linux 上验证代码, 可自行安装 LÖVE 后运行 game/ 目录." >&2
    @exit 1

# 用 LuaJIT 校验 game/ 下所有 lua 脚本的语法.
check-lua:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=0
    for f in $(find game -name '*.lua' | sort); do
        if ! luajit -e "assert(loadfile('$f'))" 2>&1; then
            echo "语法错误: $f"
            failed=1
        fi
    done
    if [ "$failed" -eq 0 ]; then
        echo "game/ 下 lua 脚本语法校验通过"
    fi
    exit "$failed"

# 校验打包脚本的 python 语法.
check-scripts:
    {{ python }} -m compileall -q scripts

# 从游戏源码生成静态卡牌目录, 不运行游戏或访问存档.
game-docs:
    luajit scripts/gen-card-docs.lua

# 校验游戏手册的覆盖率, 原型定位与本地链接.
check-game-docs:
    {{ python }} scripts/check-game-docs.py

# 删除打包产物 dist/.
clean:
    {{ python }} -c "import shutil; shutil.rmtree('dist', ignore_errors=True)"
