# impls/ 下引擎, 调试台与绑定的对局, 回放, Web, 打包与回归入口.
# 用法: just impls <子命令>, 例如 just impls play step --deck RED --stake GOLD.
python := "uv run --no-project python"
# 模块文件不继承主 justfile 的设置, 内联脚本的解释器只能在这里再写一份.
set script-interpreter := ['uv', 'run', '--no-project', 'python']

[private]
default:
    @just --justfile {{ quote(source_file()) }} --list

# just impls play <子命令> [参数]
# 让 agent 在引擎里逐步对局与查规则, 不需要游戏与图形环境.
# 子命令见 impls/engine/README.md 的 "让 agent 玩" 一节.
[positional-arguments]
[script]
play *args:
    import subprocess
    import sys
    sys.exit(subprocess.run([
        "cargo", "run", "--release", "--quiet",
        "--manifest-path", "impls/engine/cli/Cargo.toml", "--bin", "balatro", "--",
        "play", *sys.argv[1:],
    ]).returncode)

# just impls replay <回放文件或 fixture> [更多文件]
# 离线逐步核对游戏回放, 不启动游戏, 每局报告首次分歧.
# 与启动游戏的 `just macos replay` 不同, 这里只跑引擎.
[positional-arguments]
[script]
replay *args:
    import subprocess
    import sys
    sys.exit(subprocess.run([
        "cargo", "run", "--release", "--offline", "--quiet",
        "--manifest-path", "impls/engine/cli/Cargo.toml", "--bin", "balatro", "--",
        "replay-check", *sys.argv[1:],
    ]).returncode)

# 统一构建 CLI, Python wheel, HTTP 服务与 Web/WASM, 每个平台一个综合归档.
# macOS 上要通用二进制时使用 just impls dist --universal.
dist *args:
    {{ python }} scripts/package_impls.py {{ args }}

# just impls web [启动参数]
# 构建并运行双模式对局调试页面, 默认 http://127.0.0.1:12347.
web *args:
    {{ python }} scripts/web.py run {{ args }}

# just impls web-dev [启动参数]
# 启动 Vite 与 Rust 开发服务, 任一进程退出时收尾另一进程.
web-dev *args:
    {{ python }} scripts/web.py dev {{ args }}

# 仅构建纯静态 Web/WASM 页面, 无需启动 HTTP 计算服务.
web-build:
    {{ python }} scripts/web.py build

# 运行历史模型, HTTP, 前端关键测试与双模式构建检查.
test-web:
    {{ python }} scripts/web.py test

# 运行完整引擎回归, 已有 Lua 源码裁判, 零警告检查和永久记录基准.
[script]
audit:
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
        ["cargo", "test", "--offline", "--quiet", "--manifest-path", "impls/engine/Cargo.toml", "--no-fail-fast", "--", "--include-ignored"],
        ["cargo", "clippy", "--offline", "--manifest-path", "impls/engine/Cargo.toml", "--all-targets", "--", "-D", "warnings"],
        ["just", "impls", "replay", "--strict", *[f"impls/engine/core/tests/data/{name}.jsonl" for name in fixtures]],
    ]
    for command in commands:
        print("运行: " + " ".join(command), flush=True)
        result = subprocess.run(command, env=env)
        if result.returncode:
            sys.exit(result.returncode)
