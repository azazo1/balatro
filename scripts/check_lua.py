"""用 LuaJIT 校验 game/ 下所有 lua 脚本的语法.

放在 python 而不是 justfile 的 shell 循环里: Windows 上没有 sh, 而这里的遍历与错误汇总用 python 写
反而更短, 输出也统一走 log.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import layout, log  # noqa: E402

GAME_DIR = os.path.join(layout.ROOT_DIR, "game")


def lua_files():
    """game/ 下所有 .lua, 按路径排序, 保证每次输出顺序一致."""
    paths = []
    for root, dirs, files in os.walk(GAME_DIR):
        dirs.sort()
        for name in sorted(files):
            if name.endswith(".lua"):
                paths.append(os.path.join(root, name))
    return sorted(paths)


def main():
    log.set_prefix("check-lua")
    if not os.path.isdir(GAME_DIR):
        log.die("找不到 %s" % GAME_DIR)
    if not log.have("luajit"):
        log.die("找不到 luajit, 请先安装 LuaJIT")

    failed = []
    for path in lua_files():
        rel = os.path.relpath(path, layout.ROOT_DIR)
        # 逐个文件交给 luajit, 而不是把所有文件拼成一个 chunk:
        # 语法错误要能定位到文件, 也不受单个文件里 return 影响.
        result = subprocess.run(
            ["luajit", "-e", "assert(loadfile([[%s]]))" % path],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if result.returncode != 0:
            failed.append(rel)
            print((result.stdout or "").strip(), file=sys.stderr, flush=True)
            log.warn("语法错误: %s" % rel)

    if failed:
        log.die("%d 个文件语法错误: %s" % (len(failed), ", ".join(failed)))
    log.info("game/ 下 %d 个 lua 脚本语法校验通过" % len(lua_files()))


if __name__ == "__main__":
    main()
