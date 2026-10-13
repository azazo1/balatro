"""在引擎的 Python 绑定上自动对局, 目标是在**任意种子**下尽量打高.

它替 agent 做掉确定性计算, 把判断留给搜索:
- 出牌: 先用牌型估算预筛候选, 再对前几名落到引擎里真打, 往前看几手取整回合总分最高
- 弃牌: 只留目标点数与主花色的牌 (追同花), 值不值得换交给上面那层搜索
- 商店: 每个买得起的动作都在克隆出来的分支上推进两个商店, 按"最紧一关的余量"挑
- 消耗牌: 行星牌升级牌型, 太阳与符印并花色, 死神与神秘生物把杂牌换成目标牌

强度用一批种子上的**平均**到达底注衡量, 不挑种子 —— 换种子只该看到波动, 不该换出一套水平.

用法:
    just engine-py                                  # 先装好绑定
    CATALOG=docs/game/data/catalog.json python3 engine/py/autoplay.py [局数] [种子...]

环境变量 (都可选):
    STAKE        赌注 1..8, 默认 8 (金注)
    DEPTH/WIDTH  出牌搜索的深度与宽度, 默认 5 / 2
    SHOP_SEARCH  1 用前瞻搜索决定买什么 (默认), 0 退回按优先级买
    HOPS         商店前瞻往前看几个商店, 默认 2
    VERBOSE      1 打印每个盲注的目标, 钱与小丑
    JOKER_ONLY / REFRESH_AT / MIN_VALUE / NO_BUY   对照实验用的开关
"""

import itertools
import json
import os
import re
import sys

import balatro_engine as be

CATALOG_PATH = os.environ.get("CATALOG", "docs/game/data/catalog.json")
# 只买升级这几类牌型的行星牌: 出的多, 等级涨得快, 分数才跟着涨.
WANT_PLANETS = ("金星", "海王星", "水星", "天王星", "火星")
ALL_PLANETS = ("水星", "金星", "地球", "火星", "木星", "土星", "天王星", "海王星", "冥王星")
# 改造类消耗牌: 它们是"把牌组往同一张牌上坍缩"的全部手段, 优先级高于行星牌.
TRANSFORM_KEYS = (
    "c_sigil", "c_ouija", "c_death", "c_sun", "c_cryptid", "c_aura",
    "c_deja_vu", "c_talisman", "c_devil", "c_world", "c_star", "c_moon",
    "c_chariot", "c_strength", "c_magician",
)
PACK_RE = re.compile(r"^  \[(\d+)\] (.+?)(?: \(|:|$)")
# 券的取舍来自攻略: 反物质 (小丑位) 与导演剪辑版 (重掷 Boss) 最重要, 其次是库存过剩与油漆刷.
# 塔罗商人, 星球商人, 魔术打磨那类只改商店出货种类, 攻略明确说不要买.
GOOD_VOUCHERS = ("反物质", "导演剪辑版", "库存过剩", "油漆刷", "水晶球", "重构", "占卜")
BAD_VOUCHERS = ("塔罗商人", "星球商人", "魔术打磨", "魔法把戏", "星球牌商人", "塔罗牌商人")
SHOP_RE = re.compile(r"^  (card|voucher|pack) \[(\d+)\] (.+?) \$([\d.]+)")
TAG_RE = re.compile(r"跳过奖励: (.+)$")
# 攻略里靠标签拿负片小丑与双倍标签, 这两类才值得放弃一次商店.
GOOD_TAGS = ("负片", "双倍")

# 攻略里的关键小丑: 反复触发 / 倍率源 / 经济与循环件.
WANTED = {
    "j_blueprint", "j_brainstorm", "j_mime", "j_dusk", "j_sock_and_buskin",
    "j_idol", "j_bloodstone", "j_photograph", "j_baron", "j_steel_joker",
    "j_burglar", "j_golden_ticket", "j_golden_joker", "j_rocket", "j_business_card",
    "j_diet_cola", "j_ring_master", "j_showman", "j_perkeo", "j_certificate",
    "j_midas_mask", "j_dna", "j_troubadour", "j_juggler", "j_abstract",
    "j_hologram", "j_constellation", "j_obelisk", "j_campfire", "j_green_joker",
    "j_ride_the_bus", "j_smeared", "j_gros_michel", "j_fortune_teller", "j_golden",
}

SUIT_SIDE = {"S": "dark", "C": "dark", "H": "light", "D": "light"}
NAME_TO_ID = {}
CATEGORY = {}
EFFECT = {}
RANKS = {"2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
         "T": 10, "J": 11, "Q": 12, "K": 13, "A": 14}


def rank_part(token):
    """token 形如 `S_K`; 后面还可能跟版本与强化标记 (`J#purple`, `A~lucky`), 这里只取点数."""
    rank = token.split("_")[1]
    found = re.match(r"[0-9A-Za-z]+", rank)
    return found.group(0) if found else rank


def load_names():
    """catalog 里的中文名 -> 原型键, 以及原型键 -> 类别与效果文本."""
    with open(CATALOG_PATH, encoding="utf-8") as fh:
        records = json.load(fh)["records"]
    names = {}
    categories = {}
    effects = {}
    for record in records:
        if record.get("name_zh"):
            names[record["name_zh"]] = record["id"]
        categories[record["id"]] = record.get("category")
        effects[record["id"]] = "".join(record.get("effect_zh") or [])
    return names, categories, effects


# 攻略里的循环件: 出牌次数与复制能力最值钱 (次数就是分数与收入), 其次是倍率源.
PRIORITY = {
    "j_burglar": 200.0, "j_blueprint": 150.0, "j_brainstorm": 150.0, "j_perkeo": 150.0,
    "j_baron": 130.0, "j_midas_mask": 120.0, "j_golden_ticket": 120.0, "j_mime": 110.0,
    "j_invisible": 110.0,
    "j_diet_cola": 100.0, "j_ring_master": 100.0, "j_smeared": 100.0, "j_idol": 90.0,
    "j_bloodstone": 90.0, "j_photograph": 80.0, "j_dusk": 70.0, "j_sock_and_buskin": 70.0,
    "j_crafty": 60.0, "j_certificate": 60.0, "j_showman": 60.0, "j_steel_joker": 60.0,
    "j_dna": 100.0, "j_seance": 90.0,
    "j_golden_joker": 50.0, "j_satellite": 40.0,
}
# 同花流的核心件: 它们互相加成, 一件在手里时另一件更值钱.
FLUSH_CORES = {"j_smeared", "j_bloodstone", "j_crafty", "j_idol", "j_photograph"}


def synergy_bonus(game, key):
    """协同加成: 路数是"一手同花", 所以同花类的件凑在一起才有威力."""
    if key in FLUSH_CORES and set(game.jokers()) & FLUSH_CORES:
        return 20.0
    return 0.0


def joker_value(key):
    """优先级表里的按表算, 其余按效果文本粗排: 乘倍率 > 加倍率 > 筹码, 经济牌另算."""
    if key in PRIORITY:
        return PRIORITY[key]
    text = EFFECT.get(key, "")
    value = 0.0
    if "倍率" in text:
        value += 10.0
        if "X" in text:
            value += 20.0
    if "筹码" in text:
        value += 3.0
    if "$" in text or "资金" in text:
        value += 5.0
    return value


def key_of(name):
    """货架上的名字可能带后缀 (例如 '黄金小丑 (永恒)'), 所以取最长的匹配."""
    for candidate in sorted(NAME_TO_ID, key=len, reverse=True):
        if candidate in name:
            return NAME_TO_ID[candidate]
    return None


def act(game, method, **params):
    return game.apply(json.dumps({"method": method, "params": params}, ensure_ascii=False))


def try_act(game, method, **params):
    """做一步, 不合法就算了 (例如卡位满了还去买)."""
    try:
        act(game, method, **params)
        return True
    except ValueError:
        return False


def shelf(game):
    """商店货架: [(种类, 下标, 名字, 价格)]."""
    items = []
    for line in game.summary().splitlines():
        found = SHOP_RE.match(line)
        if found:
            items.append(
                (found.group(1), int(found.group(2)), found.group(3), float(found.group(4)))
            )
    return items


def keep_suits(game, tokens):
    """当前该往哪些花色上凑.

    没有模糊小丑时同花必须是同一个花色; 有模糊小丑 (黑桃与梅花同色, 红桃与方片同色) 才
    按两色一组的算.
    """
    if "j_smeared" in game.jokers():
        dark = sum(1 for _, token in tokens if token[0] in ("S", "C"))
        return ("S", "C") if dark * 2 >= len(tokens) else ("H", "D")
    counts = {}
    for _, token in tokens:
        counts[token[0]] = counts.get(token[0], 0) + 1
    if not counts:
        return ("S",)
    return (max(counts, key=lambda suit: counts[suit]),)


def rank_of(token):
    return RANKS.get(rank_part(token), 0)


def target_rank(game, tokens):
    """牌组同质化的目标点数.

    手里有男爵就锁定 K: 钢 K 流的分数来自手牌里的钢铁 K (男爵给 K 额外倍率, 哑剧让手牌
    反复触发), 这时目标点数不该再按"手上最多的那个"来定.
    """
    if "j_baron" in game.jokers():
        return "K"
    counts = {}
    for _, token in tokens:
        rank = rank_part(token)
        counts[rank] = counts.get(rank, 0) + 1
    if not counts:
        return None
    return max(counts, key=lambda rank: (counts[rank], RANKS.get(rank, 0)))


def keep_indices(game, tokens):
    """该留哪些牌: 先留目标点数的牌, 再留主花色里的牌."""
    rank = target_rank(game, tokens)
    suits = keep_suits(game, tokens)
    keep = set()
    for index, (_, token) in enumerate(tokens):
        if rank is not None and rank_part(token) == rank:
            keep.add(index)
        elif token[0] in suits:
            keep.add(index)
    return keep if keep else set(range(len(tokens)))


def hand_size(game):
    """这一回合的手牌上限 (灵质与占卜会扣掉 1, 用之前得看一眼)."""
    found = re.search(r"手牌上限 (\d+) 张", game.summary())
    return int(found.group(1)) if found else 8


def consume_step(game):
    """用掉一张消耗牌: 行星牌先升级牌型, 太阳把杂色并进主花色, 光环与既视感强化高牌.

    攻略里牌组改造就是这一步: 花色统一之后同花才凑得出来, 而牌型等级是分数的基础.
    """
    held = game.consumables()
    tokens = game.hand()
    if not held or not tokens:
        return False
    suits = keep_suits(game, tokens)
    rank = target_rank(game, tokens)
    on_target = [i for i, (_, token) in enumerate(tokens) if rank_part(token) == rank]
    off_target = [i for i, (_, token) in enumerate(tokens) if rank_part(token) != rank]
    for slot, key in enumerate(held):
        if CATEGORY.get(key) == "Planet":
            act(game, "use", consumable=slot, cards=[])
            return True
        if key == "c_sigil":
            # 符印把整手牌变成同一种随机花色: 无论变成哪一组, 同花都稳了.
            act(game, "use", consumable=slot, cards=[])
            return True
        if key == "c_death" and off_target and on_target:
            # 死神把靠左的牌变成靠右的: 拿杂牌去换目标牌.
            act(game, "use", consumable=slot, cards=[off_target[0], on_target[0]])
            return True
        if key == "c_cryptid" and on_target:
            act(game, "use", consumable=slot, cards=on_target[:1])
            return True
        if key == "c_sun":
            targets = [i for i, (_, token) in enumerate(tokens) if token[0] not in suits][:3]
            if targets:
                act(game, "use", consumable=slot, cards=targets)
                return True
        if key in ("c_aura", "c_deja_vu", "c_talisman", "c_devil", "c_chariot"):
            # 强化优先给目标点数的牌 (手里有男爵时那就是 K), 其余按点数从大到小.
            ranked = sorted(
                (i for i, (_, token) in enumerate(tokens) if token[0] in suits),
                key=lambda index: (rank_part(tokens[index][1]) != rank, -rank_of(tokens[index][1])),
            )
            if ranked:
                act(game, "use", consumable=slot, cards=ranked[:1])
                return True
        if key == "c_ectoplasm" and hand_size(game) > 5:
            # 灵质给一张随机小丑加负片 (负片不占卡位), 代价是手牌上限 -1, 所以留够余量再用.
            act(game, "use", consumable=slot, cards=[])
            return True
    return False


def best_play(game):
    """枚举 1..5 张的所有出法, 各自真打一遍, 返回 ((过关, 得分), 组合)."""
    hand = game.hand()
    before = game.chips()
    best = None
    for size in range(1, min(5, len(hand)) + 1):
        for combo in itertools.combinations(range(len(hand)), size):
            branch = game.copy()
            try:
                act(branch, "play", cards=list(combo))
            except ValueError:
                continue
            score = (branch.phase_key() != "SelectingHand", branch.chips() - before)
            if best is None or score > best[0]:
                best = (score, list(combo))
    return best


def round_candidates(game, width=2):
    """这一手值得考虑的候选: 预筛之后真打过的那几手, 外加一个换牌候选.

    候选先用牌型估算筛一遍再真打, 因为估算分不含小丑与重触发, 光看牌面会选错, 但全枚举
    真打又太贵 —— 两个一起用才既准又便宜.
    """
    before = game.chips()
    scored = []
    for combo in play_candidates(game, width=max(width, 4)):
        branch = game.copy()
        try:
            act(branch, "play", cards=combo)
        except ValueError:
            continue
        key = (branch.phase_key() != "SelectingHand", branch.chips() - before)
        scored.append((key, combo))
    scored.sort(key=lambda item: item[0], reverse=True)
    out = [{"method": "play", "params": {"cards": combo}} for _, combo in scored[:width]]
    if game.discards_left() > 0:
        tokens = game.hand()
        keep = keep_indices(game, tokens)
        victims = [i for i in range(len(tokens)) if i not in keep]
        if victims:
            out.append({"method": "discard", "params": {"cards": victims[:5]}})
    return out


def search_turn(game, depth=None, width=None):
    """搜这回合的打法: 每个节点试几个候选往前走, 取总分最高的那条路线.

    只看当前一手是短视的 (先换一手好牌再出, 常常比直接出更划算), 所以这里往前看几手.
    候选已用牌型估算预筛, 每个节点只真打几次, 所以还可以用 DEPTH / WIDTH 调深一点.
    """
    depth = depth or int(os.environ.get("DEPTH", "5"))
    width = width or int(os.environ.get("WIDTH", "2"))
    best = [None]

    def walk(node, actions, level):
        if node.phase_key() != "SelectingHand" or level >= depth or node.hands_left() <= 0:
            if best[0] is None or node.chips() > best[0][0]:
                best[0] = (node.chips(), list(actions))
            return
        for action in round_candidates(node, width=width):
            child = node.copy()
            try:
                apply_action(child, action)
            except ValueError:
                continue
            actions.append(action)
            walk(child, actions, level + 1)
            actions.pop()

    walk(game, [], 0)
    return best[0]


def play_round(game):
    """出牌阶段: 用回合内搜索定下要走的路线, 再照着走到回合结束."""
    found = search_turn(game)
    if not found:
        return
    for action in found[1]:
        if game.phase_key() != "SelectingHand":
            break
        apply_action(game, action)


HAND_BASE = {
    "同花五条": (160.0, 16.0), "同花葫芦": (140.0, 14.0), "五条": (120.0, 12.0),
    "同花顺": (100.0, 8.0), "四条": (60.0, 7.0), "葫芦": (40.0, 4.0),
    "同花": (35.0, 4.0), "顺子": (30.0, 4.0), "三条": (30.0, 3.0),
    "两对": (20.0, 2.0), "对子": (10.0, 2.0), "高牌": (5.0, 1.0),
}
LADDER = {rank: value for value, rank in enumerate(
    ["2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K", "A"], start=2)}


def card_chips(token):
    rank = rank_part(token)
    if rank == "A":
        return 11.0
    if rank in ("T", "J", "Q", "K"):
        return 10.0
    return float(rank)


def classify(indices, tokens):
    """判个牌型名. 这里只用来给候选排序, 不追求与引擎逐字一致."""
    ranks = [rank_part(tokens[i]) for i in indices]
    suits = [tokens[i][0] for i in indices]
    counts = {}
    for rank in ranks:
        counts[rank] = counts.get(rank, 0) + 1
    kinds = sorted(counts.values(), reverse=True)
    flush = len(indices) >= 5 and len(set(suits)) == 1
    values = sorted(LADDER.get(rank, 0) for rank in ranks)
    straight = False
    if len(indices) >= 5 and len(set(values)) == len(values):
        if values[-1] - values[0] == len(values) - 1 or values == [2, 3, 4, 5, 14]:
            straight = True
    if len(indices) == 5:
        if flush and kinds[0] == 5:
            return "同花五条"
        if flush and kinds[0] == 3 and len(kinds) > 1 and kinds[1] == 2:
            return "同花葫芦"
        if kinds[0] == 5:
            return "五条"
        if flush and straight:
            return "同花顺"
        if flush:
            return "同花"
        if straight:
            return "顺子"
        if kinds[0] == 4:
            return "四条"
        if kinds[0] == 3 and len(kinds) > 1 and kinds[1] == 2:
            return "葫芦"
    if kinds[0] == 4:
        return "四条"
    if kinds[0] == 3 and len(kinds) > 1 and kinds[1] == 2:
        return "葫芦"
    if kinds[0] == 3:
        return "三条"
    if len(kinds) > 1 and kinds[0] == 2 and kinds[1] == 2:
        return "两对"
    if kinds[0] == 2:
        return "对子"
    return "高牌"


def estimate(indices, tokens):
    """粗估这一手多少分 (牌型基准 + 牌面筹码, 不含小丑)."""
    name = classify(indices, tokens)
    chips, mult = HAND_BASE.get(name, (5.0, 1.0))
    chips += sum(card_chips(tokens[i]) for i in indices)
    return chips * mult


def fast_combos(tokens):
    """少量候选: 同花、按点数成组的牌、以及最大的几张 —— 覆盖绝大多数值得出的手.

    模拟要连着推进几十步, 每步枚举两百多个组合太贵, 这里只留十来个.
    """
    combos = []
    by_suit = {}
    by_rank = {}
    for index, token in enumerate(tokens):
        by_suit.setdefault(token[0], []).append(index)
        by_rank.setdefault(rank_part(token), []).append(index)
    for group in by_suit.values():
        if len(group) >= 5:
            combo = sorted(group, key=lambda i: -RANKS.get(rank_part(tokens[i]), 0))[:5]
            combos.append(combo)
    for group in by_rank.values():
        if len(group) >= 5:
            combos.append(group[:5])
        if len(group) >= 3:
            combos.append(group[:3])
        if len(group) >= 2:
            combos.append(group[:2])
    top = sorted(range(len(tokens)), key=lambda i: -RANKS.get(rank_part(tokens[i]), 0))
    combos.append(top[:5])
    combos.append(top[:1])
    return [combo for combo in combos if combo]


def play_candidates(game, width=2, fast=False):
    """挑出前几种出法 (纯计算, 不碰引擎), 供搜索与模拟共用.

    fast 只试少量候选, 给模拟用; 真实游玩时是全枚举, 准确性更重要.
    """
    tokens = [token for _, token in game.hand()]
    if fast:
        scored = [(estimate(list(combo), tokens), list(combo)) for combo in fast_combos(tokens)]
        scored.sort(key=lambda item: -item[0])
        return [combo for _, combo in scored[:width]]
    scored = []
    for size in range(1, min(5, len(tokens)) + 1):
        for combo in itertools.combinations(range(len(tokens)), size):
            scored.append((estimate(list(combo), tokens), list(combo)))
    scored.sort(key=lambda item: -item[0])
    return [combo for _, combo in scored[:width]]


def apply_action(game, action):
    return game.apply(json.dumps(action, ensure_ascii=False))


def quick_play(game):
    """模拟分支时用的出牌: 预筛出估算最高的一手, 只真打这一个.

    预筛是纯计算 (不碰引擎), 所以模拟里每步只花一次 apply, 但选出来的手已经比"有同花打
    同花"这种手写规则准得多.
    """
    tokens = game.hand()
    if not tokens:
        raise ValueError("没有手牌")
    act(game, "play", cards=play_candidates(game, width=1, fast=True)[0])


def auto_step(game):
    """贪心推进一步 (不含商店). 返回 False 表示推不动了."""
    phase = game.phase_key()
    if phase == "BlindSelect":
        act(game, "select")
        return True
    if phase == "SelectingHand":
        while consume_step(game):
            pass
        guard = 0
        while game.phase_key() == "SelectingHand":
            if game.hands_left() <= 0 or not game.hand():
                return False
            quick_play(game)
            guard += 1
            if guard > 12:
                return False
        return True
    if phase == "RoundEval":
        try:
            act(game, "endless")
        except ValueError:
            act(game, "cash_out")
        return True
    if phase == "BoosterOpened":
        act(game, "pack", skip=True)
        return True
    return False


def simulate(game, action, hops=None, limit=400, track=None):
    """克隆一局, 做这个动作, 再用廉价策略往前推进 hops 个商店.

    路上遇到的商店一律走人 (近似): 这里只想知道"刚做的这步能不能扛过接下来的盲注".
    只看一个盲注太短, 好牌与坏牌会打平, 所以默认看两个, 也可用 HOPS 调.
    track 收下路上每个盲注的"得分 / 目标", 用来判断这步之后打得多勉强.
    """
    hops = hops or int(os.environ.get("HOPS", "2"))
    branch = game.copy()
    try:
        apply_action(branch, action)
    except ValueError:
        return None
    seen = 0
    for _ in range(limit):
        phase = branch.phase_key()
        if phase == "GameOver":
            break
        if phase == "Shop":
            seen += 1
            if seen >= hops:
                break
            act(branch, "next_round")
            continue
        if phase == "RoundEval" and track is not None:
            target = branch.target()
            if target > 0:
                track.append(branch.chips() / target)
        if not auto_step(branch):
            break
    return branch


def evaluate(game, ratios=None):
    """分支的好坏: 活着远好于死掉; 活着时看"最紧的一关打得多勉强", 再看底注, 钱与小丑.

    ratios 是路上每个盲注的 得分/目标: 它比"钱多不多"更接近真正的问题, 因为玩家死掉的原因
    永远是某一关的分数不够.
    """
    if game.phase_key() == "GameOver":
        return -1_000_000.0 + game.ante() * 100.0
    margin = min(ratios) * 100.0 if ratios else 50.0
    return (
        game.ante() * 1000.0
        + margin
        + game.dollars() * 0.5
        + sum(joker_value(key) for key in game.jokers()) * 0.2
    )


def shop_candidates(game):
    """值得模拟的商店动作: 买得起的东西各买一次, 以及刷新与走人."""
    money = game.dollars()
    out = []
    for kind, index, name, cost in shelf(game):
        if cost > money:
            continue
        if kind == "voucher":
            out.append({"method": "buy", "params": {"voucher": index}})
        elif kind == "pack":
            out.append({"method": "buy", "params": {"pack": index}})
        elif CATEGORY.get(key_of(name)) == "Planet":
            out.append({"method": "buy_and_use", "params": {"card": index}})
        else:
            out.append({"method": "buy", "params": {"card": index}})
    out.append({"method": "reroll", "params": {}})
    out.append({"method": "next_round", "params": {}})
    return out


def pack_targets(key, game, tokens):
    """这张塔罗该作用在哪些手牌上."""
    if not tokens:
        return []
    rank = target_rank(game, tokens)
    suits = keep_suits(game, tokens)
    on_target = [i for i, (_, token) in enumerate(tokens) if rank_part(token) == rank]
    off_target = [i for i, (_, token) in enumerate(tokens) if rank_part(token) != rank]
    off_suit = [i for i, (_, token) in enumerate(tokens) if token[0] not in suits]
    if key in ("c_sigil", "c_ouija", "c_world", "c_star", "c_moon"):
        return []
    if key == "c_sun":
        return off_suit[:3]
    if key == "c_death":
        return [off_target[0], on_target[0]] if off_target and on_target else []
    if key == "c_cryptid":
        return on_target[:1]
    ranked = sorted(
        (i for i, (_, token) in enumerate(tokens) if token[0] in suits),
        key=lambda index: -rank_of(tokens[index][1]),
    )
    return ranked[:1]


def open_pack(game):
    """开包: 改造塔罗优先, 其次想要的行星牌, 再次白名单小丑; 都不合适就跳过."""
    tokens = game.hand()
    choices = []
    for line in game.summary().splitlines():
        found = PACK_RE.match(line)
        if found:
            choices.append((int(found.group(1)), found.group(2)))
    for index, name in choices:
        key = key_of(name)
        if key is None:
            continue
        if key in TRANSFORM_KEYS:
            targets = pack_targets(key, game, tokens)
            if targets or key in ("c_sigil", "c_ouija"):
                if try_act(game, "pack", card=index, targets=targets):
                    return True
        if CATEGORY.get(key) == "Planet" and any(p in name for p in WANT_PLANETS):
            if try_act(game, "pack", card=index, targets=[]):
                return True
        if key in WANTED:
            if try_act(game, "pack", card=index, targets=[]):
                return True
    return try_act(game, "pack", skip=True)


def rental_slots(game):
    """持有里带租赁标记的小丑槽位. 它们每回合扣钱, 该换血时优先卖掉."""
    slots = []
    for line in game.summary().splitlines():
        found = re.match(r"^  \[(\d+)\] (.+?) 卖 \$", line)
        if found and "租赁" in found.group(2):
            slots.append(int(found.group(1)))
    return slots


def sell_worst(game):
    """卡位满时卖掉最没用的小丑: 先卖每回合扣钱的, 再卖评分最低的.

    永恒小丑卖不掉, 所以逐个试, 失败了接着试下一张.
    """
    keys = game.jokers()
    if len(keys) < 5:
        return False
    rentals = [slot for slot in rental_slots(game) if slot < len(keys)]
    ordered = rentals + sorted(
        (slot for slot in range(len(keys)) if slot not in rentals),
        key=lambda index: joker_value(keys[index]),
    )
    for slot in ordered:
        if try_act(game, "sell", joker=slot):
            return True
    return False


def do_shop(game):
    """商店: 把每个买得起的动作都模拟一遍, 挑真打结果最好的那个.

    模拟用廉价策略推进到下一个商店, 于是"买这张"和"买那张"的差别不用手写启发式 —— 真打一遍
    就有答案. 设 SHOP_SEARCH=0 退回按优先级买的老路子.
    """
    while game.phase_key() == "Shop":
        if os.environ.get("SHOP_SEARCH", "1") == "0":
            greedy_shop(game)
            return
        best = None
        for action in shop_candidates(game):
            ratios = []
            branch = simulate(game, action, track=ratios)
            if branch is None:
                continue
            score = evaluate(branch, ratios)
            if best is None or score > best[0]:
                best = (score, action)
        if best is None:
            act(game, "next_round")
            continue
        apply_action(game, best[1])


def greedy_shop(game):
    """按优先级买: 券 -> 改造塔罗 -> 行星牌 -> 关键小丑 -> 评分最高的小丑 -> 钱多刷新 -> 走人.

    改造塔罗排在行星牌之前: 牌型等级再高也得先有牌可打, 牌组不往同一张牌上坍缩, 同花五条
    这条主线就无从谈起.
    """
    while game.phase_key() == "Shop":
        if os.environ.get("NO_BUY"):
            act(game, "next_round")
            continue
        money = game.dollars()
        keep = 0.0 if game.ante() <= 2 else (5.0 if game.ante() < 5 else 10.0)
        if buy_something(game, shelf(game), money, keep):
            continue
        if money >= float(os.environ.get("REFRESH_AT", "25")):
            act(game, "reroll")
            continue
        act(game, "next_round")


def buy_something(game, items, money, keep):
    """按优先级买一件买得起的东西; 买成了返回 True, 调用方重看货架再决定下一步.

    设 JOKER_ONLY=1 可以只买小丑 (用来对照"钱花在别处"是否值得).
    """
    # 头两个底注只买小丑: 这阶段一张能计分的小丑比行星牌或塔罗顶用得多, 实测更差的是后者.
    # 再往后就得开始喂改造牌了, 牌组不往同一花色上坍缩, 同花流的天花板很快就到.
    only_jokers = os.environ.get("JOKER_ONLY") == "1" or game.ante() <= 2
    if not only_jokers:
        for want in (True, False):
            for kind, index, name, cost in items:
                if kind != "voucher" or cost > money:
                    continue
                if any(bad in name for bad in BAD_VOUCHERS):
                    continue
                if want != any(good in name for good in GOOD_VOUCHERS):
                    continue
                if try_act(game, "buy", voucher=index):
                    return True
        for kind, index, name, cost in items:
            if kind == "card" and cost <= money - keep and key_of(name) in TRANSFORM_KEYS:
                if try_act(game, "buy", card=index):
                    return True
        for kind, index, name, cost in items:
            if kind == "card" and cost <= money - keep and any(p in name for p in WANT_PLANETS):
                if try_act(game, "buy_and_use", card=index):
                    return True
        # 天体包能一次看到 5 张行星牌, 抽中金星的几率比单买高得多; 秘术包则是改造塔罗的来源.
        for kind, index, name, cost in items:
            if kind == "pack" and cost <= money - keep and ("天体包" in name or "秘术包" in name):
                if try_act(game, "buy", pack=index):
                    return True
    wanted = []
    others = []
    for kind, index, name, cost in items:
        if kind != "card" or cost > money - keep:
            continue
        # 金注下租赁与易腐很常见. 它们有代价 (每回合扣钱 / 到期消失), 所以降一档排在后面,
        # 但绝不能像以前那样一刀切排除 —— 空着的卡位等于零战力, 比每回合几块钱糟得多.
        key = key_of(name)
        if CATEGORY.get(key) != "Joker":
            continue
        value = joker_value(key) + synergy_bonus(game, key)
        if "租赁" in name or "易腐" in name:
            value -= 30.0
        (wanted if key in WANTED else others).append((value, cost, index))
    floor_value = float(os.environ.get("MIN_VALUE", "0"))
    for pool in (wanted, others):
        if not pool:
            continue
        pool.sort(key=lambda item: (-item[0], item[1]))
        if pool is others and pool[0][0] < floor_value:
            continue
        if try_act(game, "buy", card=pool[0][2]):
            return True
    if wanted:
        return sell_worst(game)
    return False


def skip_reward(game):
    """当前盲注跳过后能拿到的标签名 (没解析到就返回空串)."""
    for line in game.summary().splitlines():
        found = TAG_RE.search(line)
        if found:
            return found.group(1).strip()
    return ""


def run_once(seed, deck="RED", stake=8, limit=6000, verbose=False):
    game = be.Game(seed, deck, stake)
    for _ in range(limit):
        phase = game.phase_key()
        if phase == "GameOver":
            if verbose:
                print("  [结束] 底注 %d 目标 %.0f 得分 %.0f | 小丑 %s"
                      % (game.ante(), game.target(), game.chips(), ",".join(game.jokers())),
                      flush=True)
            return game
        if phase == "BlindSelect":
            reward = skip_reward(game)
            if verbose:
                print("  [底注 %d] 目标 %.0f 钱 %.0f 跳过奖励 %s | 小丑 %s"
                      % (game.ante(), game.target(), game.dollars(), reward or "-",
                         ",".join(game.jokers())),
                      flush=True)
            # 只有拿到负片或双倍标签才值得放弃商店, 而且头一个底注要先把钱与卡位做起来.
            if any(tag in reward for tag in GOOD_TAGS) and game.ante() >= 2:
                act(game, "skip")
            else:
                act(game, "select")
        elif phase == "SelectingHand":
            while consume_step(game):
                pass
            play_round(game)
        elif phase == "RoundEval":
            try:
                act(game, "endless")
            except ValueError:
                act(game, "cash_out")
        elif phase == "Shop":
            do_shop(game)
        elif phase == "BoosterOpened":
            open_pack(game)
        else:
            break
    return game


def main():
    global NAME_TO_ID, CATEGORY, EFFECT
    NAME_TO_ID, CATEGORY, EFFECT = load_names()
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    seeds = sys.argv[2:] or ["QFG8ZBBC"]
    verbose = os.environ.get("VERBOSE") == "1"
    stake = int(os.environ.get("STAKE", "8"))
    for index in range(rounds):
        seed = seeds[index % len(seeds)]
        game = run_once(seed, stake=stake, verbose=verbose)
        print(
            "种子 %s: 底注 %d, 阶段 %s, 通关 %s" % (seed, game.ante(), game.phase_key(), game.won()),
            flush=True,
        )


if __name__ == "__main__":
    main()
