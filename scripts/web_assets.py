#!/usr/bin/env python3
"""从原版游戏资源生成 impls/web 使用的贴图清单, 并复制图集与字体.

贴图坐标全部来自 game/game.lua 中各原型表的 pos / soul_pos 字段, 不手写.
蜡封, 贴纸, 魂层这类共享精灵在 game.lua 里直接以 Sprite(...) 构造, 位置写成常量并注明出处.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import struct
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib import layout, log  # noqa: E402

ROOT = Path(layout.ROOT_DIR)
GAME = ROOT / "game"
TEXTURES = GAME / "resources" / "textures" / "2x"
OUT = ROOT / "impls" / "web" / "client" / "public" / "game"
FORMAT_VERSION = 1

# 名称与单格尺寸见 game.lua 的 asset_atli / animation_atli, 这里存 1x 单格, 文件用 2x.
ATLASES = {
    "Joker": ("Jokers.png", 71, 95),
    "Tarot": ("Tarots.png", 71, 95),
    "Voucher": ("Vouchers.png", 71, 95),
    "Booster": ("boosters.png", 71, 95),
    "centers": ("Enhancers.png", 71, 95),
    "cards": ("8BitDeck.png", 71, 95),
    "stickers": ("stickers.png", 71, 95),
    "tags": ("tags.png", 34, 34),
    "chips": ("chips.png", 29, 29),
    "blind_chips": ("BlindChips.png", 34, 34),
    "shop_sign": ("ShopSignAnimation.png", 113, 57),
    "logo": ("balatro.png", 333, 216),
}
# 原型表 set 到图集的默认映射, 见 card.lua Card:set_sprites.
SET_ATLAS = {
    "Joker": "Joker", "Tarot": "Tarot", "Planet": "Tarot", "Spectral": "Tarot",
    "Voucher": "Voucher", "Booster": "Booster", "Back": "centers", "Enhanced": "centers",
    "Default": "centers", "Edition": "Joker", "Tag": "tags", "Stake": "chips",
}
# game.lua:175-193 的共享精灵.
SHARED = {
    "seal_gold": ("centers", 2, 0), "seal_purple": ("centers", 4, 4),
    "seal_red": ("centers", 5, 4), "seal_blue": ("centers", 6, 4),
    "sticker_eternal": ("stickers", 0, 0), "sticker_perishable": ("stickers", 0, 2),
    "sticker_rental": ("stickers", 1, 2),
    "shop_sign": ("shop_sign", 0, 0),
}
FONT = GAME / "resources" / "fonts" / "m6x11plus.ttf"

ENTRY = re.compile(r"^\s*([A-Za-z0-9_]+)\s*=\s*\{(.*)\}\s*,?\s*(--.*)?$")
POS = re.compile(r"(?<![a-z_])pos\s*=\s*\{\s*x\s*=\s*(\d+)\s*,\s*y\s*=\s*(\d+)\s*\}")
SOUL = re.compile(r"soul_pos\s*=\s*\{\s*x\s*=\s*(\d+)\s*,\s*y\s*=\s*(\d+)\s*\}")
ATLAS = re.compile(r"atlas\s*=\s*['\"](\w+)['\"]")
SET = re.compile(r"(?<![a-z_])set\s*=\s*['\"](\w+)['\"]")
COLOUR = re.compile(r"boss_colour\s*=\s*HEX\(\s*['\"](\w+)['\"]\s*\)")


def png_size(path):
    """读取 PNG IHDR 中的宽高."""
    header = path.read_bytes()[:24]
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        log.die("不是 PNG 文件: %s" % path)
    return struct.unpack(">II", header[16:24])


def table_lines(lines, name):
    """返回 `self.<name> = {` 到同缩进 `}` 之间的行."""
    head = "    self.%s = {" % name
    start = next((i for i, line in enumerate(lines) if line.rstrip() == head), None)
    if start is None:
        log.die("game.lua 中找不到 " + name)
    end = next(i for i in range(start + 1, len(lines)) if lines[i].rstrip() == "    }")
    return lines[start + 1:end]


def parse_table(lines, name, default_atlas=None):
    sprites = {}
    for line in table_lines(lines, name):
        match = ENTRY.match(line)
        if not match:
            continue
        key, body = match.group(1), match.group(2)
        pos = POS.search(body)
        if not pos:
            continue
        atlas = ATLAS.search(body)
        kind = SET.search(body)
        atlas = atlas.group(1) if atlas else SET_ATLAS.get(kind.group(1)) if kind else default_atlas
        if atlas not in ATLASES:
            log.debug("跳过无法识别图集的条目 %s" % key)
            continue
        sprite = {"a": atlas, "x": int(pos.group(1)), "y": int(pos.group(2))}
        soul = SOUL.search(body)
        if soul:
            sprite["soul"] = [int(soul.group(1)), int(soul.group(2))]
        colour = COLOUR.search(body)
        if colour:
            sprite["colour"] = "#" + colour.group(1)
        sprites[key] = sprite
    return sprites


def build_manifest():
    lines = (GAME / "game.lua").read_text(encoding="utf-8").splitlines()
    sprites = {}
    sprites.update(parse_table(lines, "P_CENTERS"))
    sprites.update(parse_table(lines, "P_TAGS", "tags"))
    sprites.update(parse_table(lines, "P_STAKES", "chips"))
    sprites.update(parse_table(lines, "P_BLINDS", "blind_chips"))
    sprites.update(parse_table(lines, "P_CARDS", "cards"))
    # 魂石的魂层是 game.lua:171 的 shared_soul, 取 P_CENTERS.soul 的位置, 在 centers 图集里.
    soul = parse_table(lines, "P_CENTERS", "centers").get("soul")
    if not soul:
        log.die("game.lua 中找不到 P_CENTERS.soul")
    sprites["c_soul"]["soul"] = [soul["x"], soul["y"], "centers"]
    for key, (atlas, x, y) in SHARED.items():
        sprites[key] = {"a": atlas, "x": x, "y": y}
    # 引擎的赌注按 1..8 编号, 按原型表 order 排序对应.
    stakes = [line for line in table_lines(lines, "P_STAKES") if ENTRY.match(line)]
    order = sorted(stakes, key=lambda line: int(re.search(r"order\s*=\s*(\d+)", line).group(1)))
    stake_keys = [ENTRY.match(line).group(1) for line in order]
    atlases = {}
    for name, (file, w, h) in ATLASES.items():
        width, height = png_size(TEXTURES / file)
        # 文件是 2x 贴图, 网格数按 2 倍单格计算, 前端据此算 background-position.
        atlases[name] = {"file": file, "w": w, "h": h, "cols": width // (w * 2), "rows": height // (h * 2)}
    return {"format_version": FORMAT_VERSION, "atlases": atlases, "stakes": stake_keys, "sprites": sprites}


def check(manifest):
    """抽样核对几个已知位置, 防止 game.lua 格式变化导致静默错位."""
    expect = {
        "j_joker": ("Joker", 0, 0), "c_mercury": ("Tarot", 0, 3), "c_fool": ("Tarot", 0, 0),
        "H_2": ("cards", 0, 0), "c_base": ("centers", 1, 0), "m_bonus": ("centers", 1, 1),
        "b_red": ("centers", 0, 0), "bl_small": ("blind_chips", 0, 0), "bl_hook": ("blind_chips", 0, 7),
        "tag_uncommon": ("tags", 0, 0), "stake_black": ("chips", 4, 0),
        "p_arcana_normal_1": ("Booster", 0, 0), "v_overstock_norm": ("Voucher", 0, 0),
    }
    sprites = manifest["sprites"]
    for key, (atlas, x, y) in expect.items():
        got = sprites.get(key)
        if not got or (got["a"], got["x"], got["y"]) != (atlas, x, y):
            log.die("贴图清单核对失败: %s 期望 %s, 实际 %s" % (key, (atlas, x, y), got))
    if sprites["c_soul"].get("soul") != [0, 1, "centers"]:
        log.die("贴图清单核对失败: c_soul 缺少魂层")
    if sprites["j_hologram"].get("soul") != [2, 9]:
        log.die("贴图清单核对失败: j_hologram 缺少魂层")
    if not sprites["bl_hook"].get("colour"):
        log.die("贴图清单核对失败: Boss 缺少颜色")
    grid = {name: (a["cols"], a["rows"]) for name, a in manifest["atlases"].items()}
    if grid["Joker"] != (10, 16) or grid["cards"] != (13, 4) or grid["blind_chips"] != (21, 31):
        log.die("贴图清单核对失败: 图集网格 %s" % grid)
    if len(manifest["stakes"]) != 8 or manifest["stakes"][3] != "stake_black":
        log.die("贴图清单核对失败: 赌注顺序 %s" % manifest["stakes"])
    counts = {}
    for sprite in sprites.values():
        counts[sprite["a"]] = counts.get(sprite["a"], 0) + 1
    log.info("贴图清单核对通过, 共 %d 项: %s" % (len(sprites), ", ".join("%s %d" % kv for kv in sorted(counts.items()))))


def main():
    parser = argparse.ArgumentParser(description="生成 impls/web 的原版贴图资源")
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()
    log.set_prefix("web-assets")
    started = time.monotonic()
    manifest = build_manifest()
    check(manifest)
    args.out.mkdir(parents=True, exist_ok=True)
    for file, _w, _h in ATLASES.values():
        shutil.copy2(TEXTURES / file, args.out / file)
    shutil.copy2(FONT, args.out / FONT.name)
    (args.out / "sprites.json").write_text(json.dumps(manifest, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    log.info("原版资源已写入 %s, %.2f 秒" % (args.out.relative_to(ROOT), time.monotonic() - started))
    return 0


if __name__ == "__main__":
    sys.exit(main())
