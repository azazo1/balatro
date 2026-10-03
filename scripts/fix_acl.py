#!/usr/bin/env python3
"""把打包产物的完整性级别修回 Medium, 去掉打包环境留下的 Low 标志.

沙箱里跑打包时, 产物会继承沙箱的低完整性级别, 而沙箱内的进程又改不动这个标志
(抬高完整性级别要写入属主), 所以本脚本要在沙箱外的终端里执行, 或者提权执行.

用法:
    python3 scripts/fix_acl.py --inside dist/windows      # 修目录里的产物, 目录自身不动
    python3 scripts/fix_acl.py dist/windows/Balatro-1.0.1o-win64

--inside 表示参数是存放产物的目录: 只重置目录里的内容, 目录自身保持原级别,
这样后续还能继续往这个目录里写新产物.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import log, win_acl

log.set_prefix("fix-acl")


def parse_args():
    parser = argparse.ArgumentParser(description="修复产物的 Windows 完整性级别")
    parser.add_argument("paths", nargs="+", help="产物路径; 配合 --inside 时是存放产物的目录")
    parser.add_argument("--inside", action="store_true",
                        help="把参数当作目录, 只修目录里的产物而不改目录自身")
    return parser.parse_args()


def collect(paths, inside):
    """把参数展开成待修复的产物列表."""
    targets = []
    for path in paths:
        if not inside:
            targets.append(path)
            continue
        if not os.path.isdir(path):
            log.die("--inside 需要一个目录: %s" % path)
        targets.extend(os.path.join(path, name) for name in sorted(os.listdir(path)))
    return targets


def main():
    args = parse_args()
    if not win_acl.supported():
        log.info("当前平台没有完整性级别标志, 无需处理")
        return 0

    targets = collect(args.paths, args.inside)
    if not targets:
        log.info("目录里没有产物, 无需处理")
        return 0
    failed = win_acl.reset_all(targets)
    if failed:
        log.die("有 %d 个产物没能修复, 沙箱内的进程抬不动完整性级别, 请在沙箱外的终端里重跑"
                % len(failed))
    log.info("完成: %d 个产物已重置为 %s" % (len(targets), win_acl.MEDIUM))
    return 0


if __name__ == "__main__":
    sys.exit(main())
