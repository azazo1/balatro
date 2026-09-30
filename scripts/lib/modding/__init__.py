"""打包时按 lovely 的规则应用 mod 补丁, 生成带 mod 的游戏源码树.

lovely 在游戏运行时拦截 Lua 代码加载来打补丁, 这依赖向进程注入原生库, 在 Android 等平台上
做不到. 这里改为在打包时完成同样的事, 再附上一个 Lua 写的 lovely 运行时替身, 让 Steamodded
等依赖 lovely 的框架照常工作. 详见 docs/modding.md.

入口是 build.build_tree; 打包脚本通过 add_arguments 与 game_source 接入.
"""
import os

from .. import layout, log
from .build import TREE_MARKER, build_tree
from .patches import PatchError

__all__ = ["TREE_MARKER", "PatchError", "add_arguments", "build_tree", "flavor", "game_source"]


def add_arguments(parser):
    """为打包脚本添加 --mods 与 --strict-mods 参数."""
    parser.add_argument("--mods", nargs="?", const=layout.MODS_DIR, default=None, metavar="DIR",
                        help="打包带 mod 的版本, 从 DIR 读取 mod, 省略 DIR 时使用 mods/")
    parser.add_argument("--strict-mods", action="store_true",
                        help="有补丁未命中时构建失败")


def flavor(args):
    return layout.MODDED if args.mods else layout.VANILLA


def game_source(args, work_dir, build_version):
    """返回要打包的游戏源码目录. 未启用 mod 时就是 game/, 否则在 work_dir 下生成补丁后的源码树."""
    if not args.mods:
        return layout.GAME_DIR
    out = os.path.join(work_dir, "game")
    try:
        build_tree(layout.GAME_DIR, os.path.abspath(args.mods), out,
                   layout.MODDED.identity, build_version, args.strict_mods)
    except PatchError as exc:
        log.die(str(exc))
    return out
