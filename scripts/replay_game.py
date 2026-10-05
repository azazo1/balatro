#!/usr/bin/env python3
"""按回放文件重玩一局并录制到 recordings/.

    just macos replay <回放文件|这一局的文件夹> [tight|original|fast]

用临时存档 Balatro-Replay 隔离, 期间锁定输入, 按住 Esc 1 秒中止.
参数可以是这一局的文件夹 (每局一个文件夹), 也可以是里面的 .replay.json 文件本身.

退出码: 由**游戏**给出并原样透传 —— 0 回放完成, 1 跑偏, 2 中止, 3 文件无法回放.
脚本自己的问题 (参数不对, 找不到文件) 用 2, 与"中止"同码, 因为它们都不会让游戏跑起来.

这一层以前是 just 里的一段 bash. 换过来的原因与打包脚本一样: 跨平台时 bash 不通用,
而且 shell 里的引号与路径拼接在 Windows 上会出问题.
"""
import argparse
from datetime import datetime
import os
from pathlib import Path
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import gameproc, layout, log, version as versionlib

# 参数不对或找不到回放文件时的退出码, 与 bash 版保持一致.
EXIT_USAGE = 2
PACINGS = ("tight", "original", "fast")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="按回放文件重玩一局并录制")
    parser.add_argument("file", help="这一局的文件夹, 或里面的 .replay.json 文件")
    parser.add_argument("pacing", nargs="?", default="tight", choices=PACINGS,
                        help="节奏: tight 去掉思考时间, original 按原局间隔, fast 不等讲解")
    parser.add_argument("--invocation-dir", default=os.getcwd(),
                        help="相对路径按这个目录解析 (just 传用户敲命令时的目录)")
    return parser.parse_args(argv)


def resolve_replay_file(given, invocation_dir):
    """把参数解成一个确定的回放文件.

    给文件夹时要求里面**只有一个** .replay.json: 一局一个文件夹是正常布局,
    多于一个说明这个目录混着好几局, 猜错就是回放了别的一局, 所以宁可报错.
    """
    path = Path(given)
    if not path.is_absolute():
        path = Path(invocation_dir) / path
    if path.is_dir():
        found = sorted(candidate for candidate in path.glob("*.replay.json") if candidate.is_file())
        if len(found) != 1:
            raise ValueError("文件夹里没有唯一的回放文件 (找到 %d 个): %s" % (len(found), path))
        path = found[0]
    if not path.is_file():
        raise ValueError("找不到回放文件: %s" % path)
    return path


def replay_environment(base, replay_file, pacing, recordings):
    """回放模式的环境变量.

    与 agent 模式互斥, 所以两边都要把对方那几项清掉: 留着 `BALATROBOT_FAST` 会让回放不等讲解,
    而 agent 那边留着回放的变量会以回放模式启动.
    """
    return gameproc.game_environment(
        base,
        BALATROBOT_ENABLE="1",
        BALATRO_SAVE_IDENTITY="Balatro-Replay",
        BALATROBOT_REPLAY=str(replay_file),
        BALATROBOT_REPLAY_PACING=pacing,
        BALATROBOT_RECORD_VIDEO="on",
        BALATROBOT_RECORD_DIR=str(recordings),
        BALATROBOT_RECORD_PREFIX="replay-",
        BALATROBOT_FAST=None,
    )


def run_replay(replay_file, pacing, invocation_dir):
    """起游戏跑这一局回放, 返回游戏的退出码."""
    recordings = Path(invocation_dir) / "recordings"
    recordings.mkdir(parents=True, exist_ok=True)
    log_path = recordings / (datetime.now().strftime("%Y%m%d-%H%M%S-%f") + "-game.log")

    version = versionlib.build_version()
    executable = gameproc.game_executable("macos", version)
    if not executable.is_file():
        log.die("找不到本次打包的游戏: %s (先跑 just macos dist-modded)" % executable)

    env = replay_environment(os.environ, replay_file, pacing, recordings)
    log.info("回放 %s (节奏 %s)" % (replay_file, pacing))
    log.info("游戏日志: %s" % log_path)
    result = gameproc.stream_game([str(executable)], env, layout.ROOT_DIR, log_path)
    if result != 0:
        log.warn("回放退出码 %d, 详情见 %s" % (result, log_path))
    return result


def main(argv=None):
    args = parse_args(argv)
    log.set_prefix("replay")
    try:
        replay_file = resolve_replay_file(args.file, args.invocation_dir)
    except ValueError as exc:
        log.warn(str(exc))
        return EXIT_USAGE
    try:
        return run_replay(replay_file, args.pacing, args.invocation_dir)
    except KeyboardInterrupt:
        log.info("回放已中止")
        return 130
    except OSError as exc:
        log.die("回放失败: %s" % exc)


if __name__ == "__main__":
    sys.exit(main())
