"""用 LuaJIT 校验 game/ 下所有 lua 脚本的语法."""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import layout, log  # noqa: E402


def lua_files():
    """game/ 下所有 .lua, 按路径排序, 保证每次输出顺序一致."""
    return sorted(
        os.path.join(root, name)
        for root, _, files in os.walk(layout.GAME_DIR)
        for name in files
        if name.endswith(".lua")
    )


def main():
    log.set_prefix("check-lua")
    if not os.path.isdir(layout.GAME_DIR):
        log.die("找不到 %s" % layout.GAME_DIR)
    if not log.have("luajit"):
        log.die("找不到 luajit, 请先安装 LuaJIT")

    paths = lua_files()
    failed = []
    for path in paths:
        # 逐个文件交给 luajit, 语法错误才能定位到文件.
        result = subprocess.run(
            ["luajit", "-e", "assert(loadfile([[%s]]))" % path],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if result.returncode != 0:
            rel = os.path.relpath(path, layout.ROOT_DIR)
            failed.append(rel)
            print(result.stdout.strip(), file=sys.stderr, flush=True)
            log.warn("语法错误: %s" % rel)

    if failed:
        log.die("%d 个文件语法错误" % len(failed))
    log.info("game/ 下 %d 个 lua 脚本语法校验通过" % len(paths))


if __name__ == "__main__":
    main()
