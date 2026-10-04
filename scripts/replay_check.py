#!/usr/bin/env python3
"""引擎先跑一局并写下每一步的预测状态, 再让真游戏照着重放逐步核对.

    just macos replay-check <seed> <deck> <stake> [步数]
    just macos replay-check-decks <seed> <stake> [步数]

这是把对拍的**方向反过来**的做法: 以前只能照录像重放 (覆盖哪条路径全看录像里恰好有什么),
现在换一个种子 / 牌组 / 赌注就是一条新路径, 而不用等人去玩.

`replay-check-decks` 是同一件事对十五副牌组各做一遍: 每副牌的**开局就是它的特征** ——
无面牌组 40 张, 棋盘牌组只有两种颜色, 错乱牌组牌面随机, 画师牌组手牌上限 10 ——
而这些全在 digest 的 `deck=` 与 `hand=` 里, 游戏点头才算数.

退出码: 0 全部一致, 1 有跑偏 (逐行打印是哪些).

模板那一份录像只用来借 `snapshot` 段 (存档进度 / 解锁 / 发现): 那是 LÖVE 自己的序列化格式
(里面是个要 `STR_UNPACK` 的 profile 字符串), 引擎造不出来, 而它与种子 / 牌组 / 赌注都无关.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import layout, log
from replay_game import run_replay

# 十五副牌组, 顺序与 `RunState::with_deck` 能认的键一致.
DECKS = ["RED", "BLUE", "YELLOW", "GREEN", "BLACK", "MAGIC", "NEBULA", "GHOST",
         "ABANDONED", "CHECKERED", "ZODIAC", "PAINTED", "ANAGLYPH", "PLASMA", "ERRATIC"]


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="引擎生成回放, 再由真游戏重放核对")
    parser.add_argument("--seed", default="ALEEB", help="开局种子")
    parser.add_argument("--stake", default="GOLD", help="赌注的显示名 (WHITE ... GOLD)")
    parser.add_argument("--deck", action="append", default=None,
                        help="牌组的显示名, 可重复; 与 --all-decks 二选一")
    parser.add_argument("--all-decks", action="store_true", help="十五副牌组各跑一遍")
    parser.add_argument("--steps", default="400", help="引擎最多走多少步")
    parser.add_argument("--invocation-dir", default=os.getcwd(),
                        help="相对路径与 recordings 按这个目录解析")
    args = parser.parse_args(argv)
    if args.all_decks and args.deck:
        parser.error("--all-decks 与 --deck 不能同时给")
    if not args.all_decks and not args.deck:
        parser.error("要么给 --deck, 要么给 --all-decks")
    return args


def find_template(invocation_dir):
    """找一份可当模板的录像 (只需要它里面的 snapshot 段)."""
    recordings = Path(invocation_dir) / "recordings"
    found = sorted(candidate for candidate in recordings.glob("*/*.replay.json") if candidate.is_file())
    if not found:
        log.die("recordings/ 里没有可当模板的录像 (只需要其中的 snapshot 段)")
    return found[0]


def generate(seed, deck, stake, steps, template, out_dir):
    """让引擎跑一局并写出回放文件, 返回是否成功.

    失败**不中断整批**: 一副牌组生成不出来时, 后面十四副照样该跑完, 最后一起报.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "replay.json"
    command = [
        "cargo", "run", "--quiet", "--release",
        "--manifest-path", str(Path(layout.ROOT_DIR) / "engine/Cargo.toml"),
        "--example", "gen_replay", "--",
        "--seed", seed, "--deck", deck, "--stake", stake,
        "--template", str(template), "--out", str(out), "--steps", str(steps),
    ]
    result = subprocess.run(command, cwd=layout.ROOT_DIR)
    if result.returncode != 0:
        log.warn("生成失败: %s (退出码 %d)" % (deck, result.returncode))
        return False
    return True


def main(argv=None):
    args = parse_args(argv)
    log.set_prefix("replay-check")
    invocation_dir = args.invocation_dir
    template = find_template(invocation_dir)
    decks = DECKS if args.all_decks else args.deck

    out_root = Path(invocation_dir) / ".tmp/replay-check"
    matched = 0
    failed = []
    for deck in decks:
        # 单副的目录名带上赌注, 十五副那种按牌组分目录 —— 两者互不覆盖, 可以同时留着.
        name = "%s-%s-%s" % (args.seed, deck, args.stake) if len(decks) == 1 \
            else "%s-%s/%s" % (args.seed, args.stake, deck)
        out_dir = out_root / name
        if not generate(args.seed, deck, args.stake, args.steps, template, out_dir):
            failed.append(deck)
            continue
        # 重放. 退出码就是结论, 日志里带每步的 digest 差异.
        code = run_replay(out_dir / "replay.json", "tight", invocation_dir)
        if code == 0:
            matched += 1
            log.info("一致   %s" % deck)
        else:
            failed.append(deck)
            log.warn("跑偏   %s (退出码 %d, 日志见 recordings/replay-*-game.log)" % (deck, code))

    if not failed:
        log.info("%d 副牌组全部与引擎预测一致: %s / %s" % (matched, args.seed, args.stake))
        return 0
    log.warn("%d 副牌组对不上: %s" % (len(failed), ", ".join(failed)))
    return 1


if __name__ == "__main__":
    sys.exit(main())
