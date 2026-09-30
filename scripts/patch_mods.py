#!/usr/bin/env python3
"""按 lovely 的规则把 mods/ 里的 mod 打进游戏源码, 输出补丁后的源码树.

打包脚本加 --mods 时会自动做这一步, 这里单独提供, 便于检查补丁命中情况或直接用 love 运行.

用法:
    python3 scripts/patch_mods.py                 # 输出到 dist/modded-tree
    python3 scripts/patch_mods.py --check         # 只检查补丁, 不保留输出
    python3 scripts/patch_mods.py --mods 别处/Mods --strict -v
"""
import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import layout, log, modding, version as versionlib

log.set_prefix("mods")


def parse_args():
    parser = argparse.ArgumentParser(description="应用 mod 补丁, 生成带 mod 的游戏源码树")
    parser.add_argument("--mods", default=layout.MODS_DIR, help="mod 目录, 默认 mods/")
    parser.add_argument("--out", default=layout.MODDED_TREE, help="输出目录, 默认 dist/modded-tree")
    parser.add_argument("--check", action="store_true", help="只检查补丁命中情况, 不保留输出")
    parser.add_argument("--strict", action="store_true", help="有补丁未命中时返回失败")
    parser.add_argument("-v", "--verbose", action="store_true", help="输出每个目标的处理细节")
    return parser.parse_args()


def prepare_out(path):
    """清理上次的输出. 只删除本工具生成过的目录, 防止误删别的内容."""
    if not os.path.exists(path):
        return
    if not os.path.isfile(os.path.join(path, modding.TREE_MARKER)):
        log.die("输出目录已存在且不是本工具生成的, 拒绝覆盖: %s" % path)
    shutil.rmtree(path)


def main():
    args = parse_args()
    log.set_verbose(args.verbose)
    build_version = versionlib.build_version()
    mods_dir = os.path.abspath(args.mods)

    temp = None
    if args.check:
        temp = tempfile.mkdtemp(prefix=".mods-check-", dir=layout.ensure_dir(layout.DIST_DIR))
        out = os.path.join(temp, "game")
    else:
        out = os.path.abspath(args.out)
        prepare_out(out)
    try:
        modding.build_tree(layout.GAME_DIR, mods_dir, out, layout.MODDED.identity,
                           build_version, args.strict)
    except modding.PatchError as exc:
        log.die(str(exc))
    finally:
        if temp:
            shutil.rmtree(temp, ignore_errors=True)

    if not args.check:
        log.info("完成: %s" % out)
        log.info("运行: love \"%s\"" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
