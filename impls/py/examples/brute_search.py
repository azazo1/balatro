"""暴力搜索演示: 枚举这一手的各种出法, 在克隆出来的分支上真打一遍, 挑分最高的那个.

跑法 (先 `maturin develop --release` 装好模块):

    python3 examples/brute_search.py
"""

import itertools

import balatro_engine as be


def best_plays(game, limit=5):
    """把 1..5 张的所有组合都在分支上试打一遍, 按真实得分排序返回."""
    hand = game.hand()
    before = game.chips()
    results = []
    for size in range(1, min(limit, len(hand)) + 1):
        for combo in itertools.combinations(range(len(hand)), size):
            branch = game.copy()
            try:
                branch.apply('{"method": "play", "params": {"cards": %s}}' % list(combo))
            except ValueError:
                # 这一步不合法 (例如选中的牌不构成牌型), 跳过.
                continue
            results.append((branch.chips() - before, list(combo)))
    results.sort(key=lambda item: -item[0])
    return hand, results


def main():
    game = be.Game("QFG8ZBBC", "RED", 8)
    game.apply('{"method": "select"}')
    print("阶段 %s, 目标 %.0f 分" % (game.phase_key(), game.target()))
    hand, results = best_plays(game)
    print("试了 %d 种出法, 前五名:" % len(results))
    for score, combo in results[:5]:
        names = [hand[index][1] for index in combo]
        print("  %-28s %.0f 分" % (",".join(names), score))


if __name__ == "__main__":
    main()
