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

# 运行打包脚本的单元测试.
test-scripts:
    {{ python }} -m unittest discover -s scripts/tests -t scripts

# just mods-check [mod 目录]
# 检查 mod 补丁在当前游戏版本上的命中情况, 不产出文件.
mods-check mods="mods":
    {{ python }} scripts/patch_mods.py --mods {{ mods }} --check

# just mods-tree [mod 目录]
# 生成补丁后的游戏源码树 dist/modded-tree, 便于查看补丁结果.
mods-tree mods="mods":
    {{ python }} scripts/patch_mods.py --mods {{ mods }}

# just agent-call play '{"cards":[0,1]}' [端口]
# 调用 mod 版内置的 agent 接口 (需先开启), 输出 JSON-RPC 响应, 见 docs/agent-api.md.
agent-call method params="{}" port="12346":
    @curl -sS -X POST http://127.0.0.1:{{ port }} -H "Content-Type: application/json" -d {{ quote('{"jsonrpc":"2.0","method":"' + method + '","params":' + params + ',"id":1}') }}

# 从游戏源码生成静态卡牌目录, 不运行游戏或访问存档.
game-docs:
    luajit scripts/gen-card-docs.lua

# 校验游戏手册的覆盖率, 原型定位与本地链接.
check-game-docs:
    {{ python }} scripts/check-game-docs.py

# 删除打包产物 dist/.
clean:
    {{ python }} -c "import shutil; shutil.rmtree('dist', ignore_errors=True)"
