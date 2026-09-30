"""校验静态游戏知识库的覆盖率和链接, 不执行游戏逻辑."""
from __future__ import annotations

import json
import logging
import re
from collections import Counter
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs/game"
EXPECTED = {
    "Joker": (150, "jokers"), "Tarot": (22, "tarots"),
    "Planet": (12, "planets"), "Spectral": (18, "spectrals"),
    "Voucher": (32, "vouchers"), "Back": (15, "decks"),
    "Tag": (24, "tags"), "Booster": (32, "boosters"),
    "Blind": (30, "blinds"), "Enhanced": (8, "enhancements"),
    "Edition": (5, "editions"), "Seal": (4, "seals"), "Stake": (8, "stakes"),
}
REQUIRED = [
    "README.md", "sources.md", "data/README.md",
    "rules/run-flow.md", "rules/blinds.md", "rules/stakes.md",
    "rules/economy.md", "rules/scoring.md", "rules/poker-hands.md",
    "rules/card-modifiers.md", "rules/shop-and-packs.md", "rules/random-pools.md",
    "mechanics/joker-mechanics.md", "mechanics/consumable-mechanics.md",
    "mechanics/run-modifiers.md", "mechanics/progression.md",
    "cards/challenges.md", "cards/playing-cards.md", "cards/modifiers.md",
]
LOG = logging.getLogger("game-docs")


def main() -> int:
    errors: list[str] = []
    data = json.loads((DOCS / "data/catalog.json").read_text(encoding="utf-8"))
    version = (ROOT / "game/version.jkr").read_text(encoding="utf-8").splitlines()[0].removesuffix("-FULL")
    if data["schema_version"] != 1 or data["game_version"] != version or version != "1.0.1n":
        errors.append("数据结构或游戏版本不匹配")
    records = data["records"]
    ids = [r["id"] for r in records]
    if len(set(ids)) != len(ids):
        errors.append("目录 ID 重复")
    source_lines = (ROOT / "game/game.lua").read_text(encoding="utf-8").splitlines()
    count = Counter(r["category"] for r in records)
    for category, (expected, filename) in EXPECTED.items():
        if count[category] != expected or data["counts"][category] != expected:
            errors.append(f"{category} 数量错误: {count[category]}")
        path = DOCS / f"cards/{filename}.md"
        if not path.is_file():
            errors.append(f"缺失卡牌目录: {path.relative_to(ROOT)}")
            continue
        anchors = set(re.findall(r'<a id="([^"]+)">', path.read_text(encoding="utf-8")))
        for r in (r for r in records if r["category"] == category):
            if r["id"].replace("_", "-") not in anchors:
                errors.append(f"缺少卡牌锚点: {r['id']}")
            line = r["source"]["line"]
            if not 1 <= line <= len(source_lines) or not re.match(
                rf"\s*{re.escape(r['id'])}\s*=", source_lines[line - 1]
            ):
                errors.append(f"源码定位不准确: {r['id']}:{line}")
            for language in ("zh", "en"):
                if not r.get(f"name_{language}"):
                    errors.append(f"缺少本地化名称: {r['id']}:{language}")
                if not isinstance(r.get(f"effect_{language}"), list):
                    errors.append(f"效果应为数组: {r['id']}:{language}")
    if set(count) != set(EXPECTED):
        errors.append("目录类别不匹配")
    for field, expected in (("playing_cards", 52), ("challenges", 20), ("hands", 12), ("modifiers", 5)):
        if len(data[field]) != expected:
            errors.append(f"{field} 数量错误")
    if Counter(r["rarity"] for r in records if r["category"] == "Joker") != {1: 61, 2: 64, 3: 20, 4: 5}:
        errors.append("小丑稀有度分布错误")
    for challenge in data["challenges"]:
        for field in ("jokers", "consumeables", "vouchers"):
            if not isinstance(challenge[field], list):
                errors.append(f"挑战列表类型错误: {challenge['id']}:{field}")
        for field in ("custom", "modifiers"):
            if not isinstance(challenge["rules"][field], list):
                errors.append(f"挑战规则列表类型错误: {challenge['id']}:{field}")
        for field in ("banned_cards", "banned_tags", "banned_other"):
            if not isinstance(challenge["restrictions"][field], list):
                errors.append(f"挑战禁用列表类型错误: {challenge['id']}:{field}")
    for relative in REQUIRED:
        if not (DOCS / relative).is_file():
            errors.append(f"缺失手册: {relative}")
    mechanism_groups = {
        "mechanics/joker-mechanics.md": {"Joker"},
        "mechanics/consumable-mechanics.md": {"Tarot", "Planet", "Spectral"},
        "mechanics/run-modifiers.md": {"Voucher", "Tag", "Back"},
        "rules/card-modifiers.md": {"Enhanced", "Edition"},
        "rules/blinds.md": {"Blind"},
        "rules/stakes.md": {"Stake"},
    }
    for relative, categories in mechanism_groups.items():
        path = DOCS / relative
        if not path.is_file():
            continue
        tables = "\n".join(line for line in path.read_text(encoding="utf-8").splitlines() if line.startswith("|"))
        listed = set(re.findall(r"`([a-z][a-z_0-9]+)`", tables))
        expected_ids = {r["id"] for r in records if r["category"] in categories}
        if absent := expected_ids - listed:
            errors.append(f"机制表缺少对象 ID: {relative}: {', '.join(sorted(absent))}")
    forbidden = re.compile("[\u3002\uff0c\u201c\u201d\u2018\u2019\uff1b\uff1a\uff01\uff1f\uff08\uff09\u3010\u3011\u3001]")
    paths = sorted(DOCS.rglob("*.md"))
    links_checked = 0
    for path in paths:
        text = path.read_text(encoding="utf-8")
        for number, line in enumerate(text.splitlines(), 1):
            if forbidden.search(line):
                errors.append(f"全角标点: {path.relative_to(ROOT)}:{number}")
        for target in re.findall(r"\]\(<?([^\n]*?)>?\)", text):
            target = target.strip()
            if urlsplit(target).scheme or target.startswith("//"):
                continue
            file_part, _, fragment = target.partition("#")
            local = (path.parent / unquote(file_part)).resolve() if file_part else path
            links_checked += 1
            if not local.exists():
                errors.append(f"断链: {path.relative_to(ROOT)} -> {target}")
                continue
            if not local.is_relative_to(ROOT):
                errors.append(f"链接越出仓库: {path.relative_to(ROOT)} -> {target}")
                continue
            if local.is_file() and fragment and not fragment.startswith("L") and local.suffix == ".md":
                destination = local.read_text(encoding="utf-8")
                anchors = set(re.findall(r'<a id="([^"]+)">', destination))
                used: Counter[str] = Counter()
                for heading in re.findall(r"^#{1,6}\s+(.+)$", destination, re.MULTILINE):
                    slug = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
                    suffix = f"-{used[slug]}" if used[slug] else ""
                    anchors.add(slug + suffix)
                    used[slug] += 1
                if unquote(fragment) not in anchors:
                    errors.append(f"标题锚点不存在: {path.relative_to(ROOT)} -> {target}")
            if local.is_file() and (match := re.fullmatch(r"L(\d+)(?:-L(\d+))?", fragment)):
                end = int(match[2] or match[1])
                length = len(local.read_text(encoding="utf-8").splitlines())
                if int(match[1]) < 1 or int(match[1]) > end or end > length:
                    errors.append(f"行号越界: {path.relative_to(ROOT)} -> {target}")
    LOG.info("检查 %d 个原型, %d 个 Markdown, %d 个本地链接", len(records), len(paths), links_checked)
    if errors:
        for error in errors:
            LOG.error("%s", error)
        return 1
    LOG.info("静态覆盖率和链接校验通过, 不代表运行时机制已实战验证")
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="[%(name)s] %(levelname)s %(message)s")
    raise SystemExit(main())
