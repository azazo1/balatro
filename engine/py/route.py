"""查一个种子的商店路线.

攻略作者用一个外部工具看"每个底注的商店会摆什么", 这里用引擎自己算 —— 商店格子是按键独立
的伪随机, 所以每个底注的序列与其他底注无关, 与你怎么出牌也无关, 开局就能把整条路线查出来.

用法:
    just engine-py
    CATALOG=docs/game/data/catalog.json python3 engine/py/route.py <种子> [牌组] [赌注] [最大底注] [每底注刷新次数]

输出只列攻略点名的关键牌 (循环件, 倍率源, 经济与改造), 以及它出现在该底注的第几次刷新.
"""

import json
import os
import sys

import balatro_engine as be

CATALOG_PATH = os.environ.get("CATALOG", "docs/game/data/catalog.json")

WANTED_JOKERS = {
    "j_baron": "男爵", "j_mime": "哑剧", "j_blueprint": "蓝图", "j_brainstorm": "头脑风暴",
    "j_burglar": "窃贼", "j_ring_master": "马戏团长", "j_dna": "DNA", "j_invisible": "隐形小丑",
    "j_perkeo": "帕奇欧", "j_golden_ticket": "黄金门票", "j_midas_mask": "迈达斯面具",
    "j_diet_cola": "可乐", "j_certificate": "证书", "j_showman": "表演者",
    "j_smeared": "模糊小丑", "j_steel_joker": "钢铁小丑", "j_golden_joker": "黄金小丑",
    "j_business_card": "名片", "j_rocket": "火箭", "j_satellite": "卫星",
}
WANTED_VOUCHERS = {
    "v_antimatter": "反物质", "v_directors_cut": "导演剪辑版",
    "v_overstock_norm": "库存过剩", "v_overstock_plus": "库存过剩加强版",
    "v_paint_brush": "油漆刷", "v_reroll_surplus": "重构", "v_reroll_glut": "重构加强版",
    "v_crystal_ball": "水晶球", "v_seed_money": "种子基金", "v_money_tree": "摇钱树",
}


def load_names():
    """原型键 -> 中文名 (只为了看得懂输出)."""
    with open(CATALOG_PATH, encoding="utf-8") as fh:
        records = json.load(fh)["records"]
    names = {}
    for record in records:
        name = record.get("name_zh")
        if name:
            names.setdefault(record["id"], name)
    return names


def label(key, names):
    if key in WANTED_JOKERS:
        return WANTED_JOKERS[key]
    if key in WANTED_VOUCHERS:
        return WANTED_VOUCHERS[key]
    return names.get(key, key)


def scan(seed, deck="RED", stake=8, max_ante=24, rolls=40):
    """逐底注扫一遍, 返回 {底注: [(第几次刷新, 名字)]}."""
    game = be.Game(seed, deck, stake)
    route = {}
    for ante in range(1, max_ante + 1):
        hits = []
        for step, (jokers, vouchers, _packs) in enumerate(game.preview_shop(ante, rolls)):
            for key in jokers + vouchers:
                if key in WANTED_JOKERS or key in WANTED_VOUCHERS:
                    hits.append((step, label(key, {})))
        if hits:
            route[ante] = hits
    return route


def main():
    if len(sys.argv) < 2:
        sys.exit("用法: route.py <种子> [牌组] [赌注] [最大底注] [每底注刷新次数]")
    seed = sys.argv[1]
    deck = sys.argv[2] if len(sys.argv) > 2 else "RED"
    stake = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    max_ante = int(sys.argv[4]) if len(sys.argv) > 4 else 24
    rolls = int(sys.argv[5]) if len(sys.argv) > 5 else 40
    names = load_names()
    game = be.Game(seed, deck, stake)
    total = 0
    for ante in range(1, max_ante + 1):
        hits = []
        for step, (jokers, vouchers, _packs) in enumerate(game.preview_shop(ante, rolls)):
            for key in jokers:
                if key in WANTED_JOKERS:
                    hits.append((step, label(key, names)))
            # 券一底只摆一张, 不跟着刷新变, 所以只在第一次记一次.
            if step == 0:
                for key in vouchers:
                    if key in WANTED_VOUCHERS:
                        hits.append((step, label(key, names)))
        if hits:
            total += len(hits)
            print("底注 %-3d %s" % (ante, " | ".join("第%d次:%s" % (step, name) for step, name in hits)))
    print("共 %d 处关键牌" % total)


if __name__ == "__main__":
    main()
