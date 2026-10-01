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

# 用 LuaJIT 运行 agent mod 的纯逻辑单元测试 (录制, 回放, 模型协议, 内置 agent 主循环).
test-agent:
    luajit scripts/tests/lua/agent_record_test.lua
    luajit scripts/tests/lua/agent_replay_test.lua
    luajit scripts/tests/lua/agent_llm_test.lua
    luajit scripts/tests/lua/agent_loop_test.lua
    luajit scripts/tests/lua/agent_knowledge_test.lua
    luajit scripts/tests/lua/agent_ui_test.lua

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

# just agent-wait [状态] [超时秒数] [端口]
# 轮询 agent 接口直到游戏进入指定状态 (默认 MENU), 用于等开场动画播完; 超时返回非 0.
agent-wait state="MENU" timeout="60" port="12346":
    #!/usr/bin/env bash
    set -uo pipefail
    body='{"jsonrpc":"2.0","method":"gamestate","params":{},"id":1}'
    deadline=$((SECONDS + {{ timeout }}))
    last=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        resp=$(curl -sS -m 5 -X POST "http://127.0.0.1:{{ port }}" -H "Content-Type: application/json" -d "$body" 2>/dev/null || true)
        current=$(printf '%s' "$resp" | sed -n 's/.*"state":"\([A-Z_]*\)".*/\1/p')
        if [ "$current" = {{ quote(state) }} ]; then
            echo "游戏已进入 {{ state }}"
            exit 0
        fi
        if [ -n "$current" ] && [ "$current" != "$last" ]; then
            echo "当前状态: $current"
            last="$current"
        fi
        sleep 0.5
    done
    echo "等待 {{ state }} 超时 ({{ timeout }}s), 最后状态: ${last:-无响应}" >&2
    exit 1

# 从游戏源码生成静态卡牌目录, 不运行游戏或访问存档.
game-docs:
    luajit scripts/gen-card-docs.lua

# 校验游戏手册的覆盖率, 原型定位与本地链接.
check-game-docs:
    {{ python }} scripts/check-game-docs.py

# 删除打包产物 dist/.
clean:
    {{ python }} -c "import shutil; shutil.rmtree('dist', ignore_errors=True)"

# 运行原生网络库 bbnet 的单元测试与端到端测试 (本地起 TCP 服务, 不联网).
bbnet-test:
    cargo test --manifest-path native/bbnet/Cargo.toml

# 目前只编译 arm64. 需要 universal 时再 rustup target add x86_64-apple-darwin,
# 分别编译两个 target 后用 lipo -create 合并成一个 dylib.
# 编译 macOS arm64 版 bbnet, 复制到 mods/balatrobot/native/macos/libbbnet.dylib.
bbnet-macos:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build --manifest-path native/bbnet/Cargo.toml --release --target aarch64-apple-darwin
    mkdir -p mods/balatrobot/native/macos
    cp native/bbnet/target/aarch64-apple-darwin/release/libbbnet.dylib mods/balatrobot/native/macos/libbbnet.dylib
    echo "已生成 mods/balatrobot/native/macos/libbbnet.dylib"

# just bbnet-android [abi...]
# 需要 cargo-ndk, 以及对应的 rust target (aarch64-linux-android, armv7-linux-androideabi).
# NDK 按 ANDROID_NDK_HOME, ANDROID_HOME/ndk/<最新>, ~/Library/Android/sdk/ndk/<最新> 的顺序查找.
# NDK r27 起默认 16KB 页对齐, 不需要额外链接参数.
# 编译 Android 版 bbnet, 输出到 dist/native/android/<abi>/libbbnet.so, 供打包 APK 时放进 lib/<abi>/.
bbnet-android *abis="arm64-v8a armeabi-v7a":
    #!/usr/bin/env bash
    set -euo pipefail
    latest_ndk() {
        [ -d "$1" ] || return 1
        local found
        found=$(ls -1 "$1" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
        [ -n "$found" ] && echo "$1/$found"
    }
    ndk="${ANDROID_NDK_HOME:-}"
    if [ -z "$ndk" ] && [ -n "${ANDROID_HOME:-}" ]; then
        ndk=$(latest_ndk "$ANDROID_HOME/ndk" || true)
    fi
    if [ -z "$ndk" ]; then
        ndk=$(latest_ndk "$HOME/Library/Android/sdk/ndk" || true)
    fi
    if [ -z "$ndk" ] || [ ! -d "$ndk" ]; then
        echo "找不到 Android NDK, 请设置 ANDROID_NDK_HOME 或安装到 ANDROID_HOME/ndk/" >&2
        exit 1
    fi
    echo "使用 NDK: $ndk"
    targets=()
    for abi in {{ abis }}; do
        targets+=(-t "$abi")
    done
    out="$PWD/dist/native/android"
    mkdir -p "$out"
    cd native/bbnet
    ANDROID_NDK_HOME="$ndk" cargo ndk "${targets[@]}" -o "$out" build --release
    for abi in {{ abis }}; do
        echo "已生成 dist/native/android/$abi/libbbnet.so"
    done

# 需要 MSVC 链接器, 在 macOS 上交叉编译通常会因缺少 link.exe 失败, 请在 Windows 或 CI 上运行.
# 编译 Windows x64 版 bbnet, 输出到 dist/native/windows/bbnet.dll, 打包时放在 exe 旁边.
bbnet-windows:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build --manifest-path native/bbnet/Cargo.toml --release --target x86_64-pc-windows-msvc
    mkdir -p dist/native/windows
    cp native/bbnet/target/x86_64-pc-windows-msvc/release/bbnet.dll dist/native/windows/bbnet.dll
    echo "已生成 dist/native/windows/bbnet.dll"
