# 跨平台的 python 调用方式: Windows 上是 python, 其余平台是 python3
python := if os_family() == "windows" { "python" } else { "python3" }
python_shebang := if os_family() == "windows" { "python" } else { "/usr/bin/env python3" }

[private]
default:
    @just --list

# 打包 macOS 应用包, 用法: just macos dist
mod macos

# 打包 Android 安装包, 用法: just android dist
mod android

# 打包 Windows 免安装版, 用法: just windows dist
mod windows

# 编译与测试原生库, 用法: just native test / just native build android arm64-v8a
mod native

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
    {{ python }} scripts/check_lua.py

# 校验打包脚本的 python 语法.
check-scripts:
    {{ python }} -m compileall -q scripts

# 运行打包脚本的单元测试.
test-scripts:
    {{ python }} -m unittest discover -s scripts/tests -t scripts

# 用 LuaJIT 运行 agent mod 的纯逻辑单元测试 (录制, 回放, 回放列表, 端点在进程内调用, 模型协议, UTF-8 截断, 出牌计分记录, 动态值, 补充包等待, 流式条回放, 工具调用文案, 内置 agent 主循环).
test-agent:
    luajit scripts/tests/lua/agent_record_test.lua
    luajit scripts/tests/lua/agent_record_toggle_test.lua
    luajit scripts/tests/lua/agent_replay_record_toggle_test.lua
    luajit scripts/tests/lua/agent_media_ffi_test.lua
    luajit scripts/tests/lua/agent_replay_test.lua
    luajit scripts/tests/lua/agent_replay_stream_test.lua
    luajit scripts/tests/lua/agent_replay_library_test.lua
    luajit scripts/tests/lua/agent_replay_manual_test.lua
    luajit scripts/tests/lua/agent_replay_tutorial_test.lua
    luajit scripts/tests/lua/agent_local_call_test.lua
    luajit scripts/tests/lua/agent_gate_test.lua
    luajit scripts/tests/lua/agent_text_test.lua
    luajit scripts/tests/lua/agent_llm_test.lua
    luajit scripts/tests/lua/agent_decision_test.lua
    luajit scripts/tests/lua/agent_decision_loop_test.lua
    luajit scripts/tests/lua/bbcoring_test.lua
    luajit scripts/tests/lua/bbdynamics_test.lua
    luajit scripts/tests/lua/bbpack_wait_test.lua
    luajit scripts/tests/lua/bbboss_reroll_test.lua
    luajit scripts/tests/lua/bbslots_test.lua
    luajit scripts/tests/lua/bbcall_note_test.lua
    luajit scripts/tests/lua/agent_loop_test.lua
    luajit scripts/tests/lua/agent_knowledge_test.lua
    luajit scripts/tests/lua/agent_ui_test.lua
    luajit scripts/tests/lua/agent_hud_test.lua
    luajit scripts/tests/lua/bbinput_gate_test.lua
    luajit scripts/tests/lua/android_storage_test.lua
    luajit scripts/tests/lua/smods_config_path_test.lua

# just mods-check [mod 目录]
# 检查 mod 补丁在当前游戏版本上的命中情况, 不产出文件.
mods-check mods="mods":
    {{ python }} scripts/patch_mods.py --mods {{ mods }} --check

# just mods-tree [mod 目录]
# 生成补丁后的游戏源码树 dist/modded-tree, 便于查看补丁结果.
mods-tree mods="mods":
    {{ python }} scripts/patch_mods.py --mods {{ mods }}

# just agent-call play '{"cards":[0,1]}' [端口]
# 参数由 just 直接传给 Python, 避免 Windows shell 改写 JSON 的引号与反斜杠.
# 调用 mod 版内置的 agent 接口 (需先开启), 输出 JSON-RPC 响应, 见 docs/agent-api.md.
[positional-arguments]
agent-call method params="{}" port="12346":
    #!{{ python_shebang }}
    import sys
    sys.path.insert(0, "scripts")
    from agent_rpc import main
    sys.argv = ["agent_rpc.py", "call", *sys.argv[1:]]
    main()

# just agent-wait [状态] [超时秒数] [端口]
# 轮询 agent 接口直到游戏进入指定状态 (默认 MENU), 用于等开场动画播完; 超时返回非 0.
[positional-arguments]
agent-wait state="MENU" timeout="60" port="12346":
    #!{{ python_shebang }}
    import sys
    sys.path.insert(0, "scripts")
    from agent_rpc import main
    sys.argv = ["agent_rpc.py", "wait", *sys.argv[1:]]
    main()

# 从游戏源码生成静态卡牌目录, 不运行游戏或访问存档.
game-docs:
    luajit scripts/gen-card-docs.lua

# 校验游戏手册的覆盖率, 原型定位与本地链接.
check-game-docs:
    {{ python }} scripts/check-game-docs.py

# just play <子命令> [参数]
# 让 agent 在引擎里逐步对局与查规则, 不需要游戏与图形环境.
# 子命令见 engine/README.md 的 "让 agent 玩" 一节.
[positional-arguments]
play *args:
    #!{{ python_shebang }}
    import subprocess
    import sys
    sys.exit(subprocess.run([
        "cargo", "run", "--release", "--quiet",
        "--manifest-path", "engine/Cargo.toml", "--bin", "play", "--",
        *sys.argv[1:],
    ]).returncode)

# just engine-replay <回放文件或 fixture> [更多文件]
# 离线逐步核对游戏回放, 不启动游戏, 每局报告首次分歧.
[positional-arguments]
engine-replay *args:
    #!{{ python_shebang }}
    import subprocess
    import sys
    sys.exit(subprocess.run([
        "cargo", "run", "--release", "--offline", "--quiet",
        "--manifest-path", "engine/Cargo.toml", "--bin", "replay_check", "--",
        *sys.argv[1:],
    ]).returncode)

# 运行完整 engine 回归, 已有 Lua 源码裁判, 零警告检查和永久记录基准.
engine-audit:
    #!{{ python_shebang }}
    import os
    from pathlib import Path
    import subprocess
    import sys
    tree = Path(".tmp/engine-audit/modded-tree").resolve()
    if not all((tree / name).is_file() for name in ["game.lua", "functions/common_events.lua"]):
        sys.exit("需要已有完整 Lovely 补丁树 .tmp/engine-audit/modded-tree; 不自动安装或启动游戏")
    env = dict(os.environ, BALATRO_PATCHED_TREE=str(tree))
    fixtures = [
        "rec-20261005-23z315qp", "rec-20261005-t5tf8s49",
        "rec-20261005-s6cftc2v", "rec-20261005-vv8pfes1",
        "diagnostic-20261005-9af1bgs8", "diagnostic-20261005-a48x6zym",
    ]
    commands = [
        ["cargo", "test", "--offline", "--quiet", "--manifest-path", "engine/Cargo.toml", "--no-fail-fast", "--", "--include-ignored"],
        ["cargo", "clippy", "--offline", "--manifest-path", "engine/Cargo.toml", "--all-targets", "--", "-D", "warnings"],
        ["just", "engine-replay", "--strict", *[f"engine/tests/data/{name}.jsonl" for name in fixtures]],
    ]
    for command in commands:
        print("运行: " + " ".join(command), flush=True)
        result = subprocess.run(command, env=env)
        if result.returncode:
            sys.exit(result.returncode)

# 删除打包产物 dist/.
clean:
    {{ python }} scripts/clean.py

