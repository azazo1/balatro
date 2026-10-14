#!/usr/bin/env python3
"""把带 mod 的游戏打包成浏览器版 (love.js compat, 不需要 SharedArrayBuffer).

产物写到 impls/web/client/public/play/, 前端构建时随调试台一起进入 dist/play/.
兼容层源码在 impls/web/game/lua/, 页面模板是 impls/web/game/shell.html.

用法:
    uv run --no-project python scripts/web_game.py
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib import layout, log  # noqa: E402

ROOT = Path(layout.ROOT_DIR)
GAME_WEB = ROOT / "impls" / "web" / "game"
COMPAT = GAME_WEB / "lua"
SHELL = GAME_WEB / "shell.html"
LOVEJS = GAME_WEB / "node_modules" / "love.js" / "index.js"
TREE = ROOT / ".tmp" / "web-game" / "tree"
OUT = ROOT / "impls" / "web" / "client" / "public" / "play"
# 可选: 有 Lua 5.1 的 luac 时做语法检查 (love.js 用 PUC Lua 5.1, 不认 goto).
LUAC51 = os.environ.get("LUAC51") or shutil.which("luac5.1")
TITLE = "Balatro Modded"


def read(rel):
    return (TREE / rel).read_text(encoding="utf-8")


def write(rel, text):
    (TREE / rel).write_text(text, encoding="utf-8")


def replace_once(text, old, new, where):
    n = text.count(old)
    if n != 1:
        log.die("%s: 期望命中 1 次, 实际 %d 次: %r" % (where, n, old[:80]))
    return text.replace(old, new)


# ---------------------------------------------------------------- goto 改写
# PUC Lua 5.1 没有 goto. 这里的 goto 都是 continue 语义, 改写成 repeat ... until true 加 break.

def rewrite_card():
    t = read("card.lua")
    t = replace_once(t, "    if G.in_delete_run then goto skip_game_actions_during_remove end\n",
                     "    if not G.in_delete_run then\n", "card.lua")
    t = replace_once(t, "    ::skip_game_actions_during_remove::\n", "    end\n", "card.lua")
    write("card.lua", t)


def rewrite_game():
    t = read("game.lua")
    t = replace_once(t, "            for k, v in pairs(self.P_CARDS) do\n",
                     "            for k, v in pairs(self.P_CARDS) do\n            local __skip = false\n            repeat\n",
                     "game.lua")
    t = replace_once(t, "                    goto continue\n                end\n                if self.GAME.selected_back_key.initial_deck then",
                     "                    break\n                end\n                if self.GAME.selected_back_key.initial_deck then",
                     "game.lua")
    t = replace_once(t, "                                goto continue\n",
                     "                                __skip = true\n                                break\n", "game.lua")
    # 内层 for 被 break 打断后, 再跳出 repeat.
    t = replace_once(t, "                local _ = nil\n                if self.GAME.starting_params.erratic_suits_and_ranks then",
                     "                if __skip then break end\n                local _ = nil\n"
                     "                if self.GAME.starting_params.erratic_suits_and_ranks then", "game.lua")
    t = replace_once(t, "                ::continue::\n", "            until true\n", "game.lua")
    write("game.lua", t)


def rewrite_smods_utils():
    w = "lovely_shim/mods/Steamodded/src/utils.lua"
    t = read(w)
    # jokers
    t = replace_once(t, "            for _, _card in ipairs(area.cards) do\n                --calculate the joker effects\n"
                        "                if SMODS.check_looping_context(_card) then\n                    goto skip\n",
                     "            for _, _card in ipairs(area.cards) do\n            repeat\n                --calculate the joker effects\n"
                     "                if SMODS.check_looping_context(_card) then\n                    break\n", w)
    t = replace_once(t, "                ::skip::\n            end\n            if area == G.consumeables",
                     "            until true\n            end\n            if area == G.consumeables", w)
    # playing_cards: 概率分支里的内层循环
    t = replace_once(t, "                    for _, card in ipairs(area.cards) do\n                        if SMODS.check_looping_context(card) then\n"
                        "                            goto skip\n",
                     "                    for _, card in ipairs(area.cards) do\n                    repeat\n"
                     "                        if SMODS.check_looping_context(card) then\n                            break\n", w)
    t = replace_once(t, "                        ::skip::\n", "                    until true\n", w)
    # playing_cards: 主循环
    t = replace_once(t, "            for _, card in ipairs(area.cards) do\n                if SMODS.check_looping_context(card) then\n"
                        "                    goto skip\n",
                     "            for _, card in ipairs(area.cards) do\n            repeat\n"
                     "                if SMODS.check_looping_context(card) then\n                    break\n", w)
    t = replace_once(t, "                ::skip::\n            end\n            ::continue::\n",
                     "            until true\n            end\n            until true\n", w)
    t = replace_once(t, "        for _, area in ipairs(SMODS.get_card_areas('playing_cards')) do\n",
                     "        for _, area in ipairs(SMODS.get_card_areas('playing_cards')) do\n        repeat\n", w)
    t = replace_once(t, "                goto continue\n", "                break\n", w)
    # individual
    t = replace_once(t, "        for _, area in ipairs(SMODS.get_card_areas('individual')) do\n"
                        "            if SMODS.check_looping_context(area.object) then\n                goto skip\n",
                     "        for _, area in ipairs(SMODS.get_card_areas('individual')) do\n        repeat\n"
                     "            if SMODS.check_looping_context(area.object) then\n                break\n", w)
    t = replace_once(t, "            ::skip::\n        end\n    end\n    return flags",
                     "        until true\n        end\n    end\n    return flags", w)
    write(w, t)


# ---------------------------------------------------------------- 着色器
# WebGL1 (GLSL ES 1.00) 要求 for 的循环下标用常量表达式初始化, 把用作循环边界的局部变量改成 const.
# lovely_shim/content 下是预先算好的补丁结果, 按输入内容的哈希命中, 改输出不影响命中.
SHADER_CONSTS = [
    ("int glow_samples = 4;", "const int glow_samples = 4;"),
    ("float glow_samples = 4.;", "const float glow_samples = 4.;"),
]


def fix_smods_scaling_shader():
    # smods 图集缩放着色器: 数组构造器与 float/int 比较在 GLSL ES 1.00 下不合法.
    # 按 3x3 行优先下标算偏移并跳过中心, 遍历顺序与原数组一致.
    rel = "lovely_shim/mods/Steamodded/src/game_object.lua"
    t = read(rel)
    t = replace_once(t, "        vec2 neigbours[8] = vec2[8](vec2(-1, -1),vec2(0, -1),vec2(1, -1),vec2(-1, 0),vec2(1, 0),vec2(-1, 1),vec2(0, 1),vec2(1, 1));\n",
                     "", rel)
    t = replace_once(t, "            for (int i = 0; i < 8; i++) {\n                vec2 c = uv + (neigbours[i] * dim);\n"
                        "                if (c.x < 0 || c.x > 1) continue;\n                if (c.y < 0 || c.y > 1) continue;\n",
                     "            for (int i = 0; i < 9; i++) {\n                if (i == 4) continue;\n"
                     "                vec2 off = vec2(float(i - (i / 3) * 3) - 1.0, float(i / 3) - 1.0);\n"
                     "                vec2 c = uv + (off * dim);\n"
                     "                if (c.x < 0.0 || c.x > 1.0) continue;\n                if (c.y < 0.0 || c.y > 1.0) continue;\n",
                     rel)
    write(rel, t)


def fix_shaders():
    fix_smods_scaling_shader()
    count = 0
    for directory in [TREE / "resources" / "shaders", *(TREE / "lovely_shim" / "content").glob("*")]:
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8", errors="surrogateescape")
            new = text
            for old, rep in SHADER_CONSTS:
                if rep not in new:
                    new = new.replace(old, rep)
            if new != text:
                path.write_text(new, encoding="utf-8", errors="surrogateescape")
                count += 1
    if count == 0:
        log.die("着色器循环边界补丁一个也没命中, 上游着色器可能变了")
    log.info("着色器循环边界改为常量: %d 个文件" % count)


# ---------------------------------------------------------------- 注入

def module_file(manifest, name):
    marker = '["name"] = "%s",' % name
    idx = manifest.find(marker)
    if idx < 0:
        log.die("manifest 里找不到模块 " + name)
    start = manifest.rfind('["file"] = "', 0, idx) + len('["file"] = "')
    return "lovely_shim/" + manifest[start:manifest.index('"', start)]


def rehash_bundle():
    """打包后又改过 mod 文件, 按改后的内容重算 bundle_hash, 否则存档目录里的旧释放记录会被沿用."""
    digest = hashlib.sha256()
    mods_root = TREE / "lovely_shim" / "mods"
    for path in sorted(p for p in mods_root.rglob("*") if p.is_file()):
        digest.update(path.relative_to(mods_root).as_posix().encode())
        digest.update(path.read_bytes())
    manifest = read("lovely_shim/manifest.lua")
    key = '["bundle_hash"] = "'
    start = manifest.index(key) + len(key)
    end = manifest.index('"', start)
    write("lovely_shim/manifest.lua", manifest[:start] + "web-" + digest.hexdigest() + manifest[end:])


def inject():
    shutil.copytree(COMPAT, TREE / "web_compat")
    # nativefs 依赖 ffi: 包内两份模块源码与 smods 释放到存档目录的那份都换成替身.
    nfs = (COMPAT / "nativefs.lua").read_text(encoding="utf-8")
    manifest = read("lovely_shim/manifest.lua")
    targets = ["lovely_shim/mods/Steamodded/libs/nativefs/nativefs.lua"]
    targets += [module_file(manifest, name) for name in ("nativefs", "SMODS.nativefs")]
    for rel in targets:
        write(rel, nfs)
    log.info("nativefs 替身: %d 处" % len(targets))
    rehash_bundle()
    # 兼容层要先于 lovely 运行时 (它用 load(string) 加载模块); conf.lua 阶段只需要语言差异部分.
    write("main.lua", 'require("web_compat.boot")\n' + read("main.lua"))
    write("conf.lua", 'require("web_compat.lang")\n' + read("conf.lua"))


def check_syntax():
    if not LUAC51:
        log.info("没有 Lua 5.1 的 luac (可用 LUAC51 指定), 跳过语法检查")
        return
    bad = []
    for path in TREE.rglob("*.lua"):
        if "lsp_def" in path.parts:
            continue
        result = subprocess.run([LUAC51, "-p", str(path)], capture_output=True, text=True)
        if result.returncode != 0:
            bad.append(result.stderr.strip())
    if bad:
        log.die("Lua 5.1 语法检查失败:\n" + "\n".join(bad[:20]))
    log.info("Lua 5.1 语法检查通过")


def package():
    if not LOVEJS.is_file():
        log.run(["bun", "install", "--frozen-lockfile"], cwd=str(GAME_WEB))
    total = sum(p.stat().st_size for p in TREE.rglob("*") if p.is_file())
    # 资源整体装进 wasm 内存, 再留出运行余量; 按 16 MiB 对齐.
    memory = max(256 << 20, (total // (16 << 20) + 8) * (16 << 20))
    log.info("资源 %.1f MB, 初始内存 %d MB" % (total / 1e6, memory >> 20))
    if OUT.exists():
        shutil.rmtree(OUT)
    log.run(["node", str(LOVEJS), "-c", "-t", TITLE, "-m", str(memory), str(TREE), str(OUT)])
    # love.js 自带的页面换成我们的模板, 它也会带一份 theme 目录, 用不上.
    shutil.rmtree(OUT / "theme", ignore_errors=True)
    page = SHELL.read_text(encoding="utf-8").replace("__MEMORY__", str(memory))
    (OUT / "index.html").write_text(page, encoding="utf-8")


def build():
    started = time.monotonic()
    log.info("生成 modded 源码树")
    if TREE.exists():
        shutil.rmtree(TREE)
    log.run([sys.executable, str(ROOT / "scripts" / "patch_mods.py"), "--out", str(TREE)], cwd=str(ROOT))
    rewrite_card()
    rewrite_game()
    rewrite_smods_utils()
    fix_shaders()
    inject()
    check_syntax()
    package()
    log.info("浏览器版游戏构建完成, %.1f 秒: %s" % (time.monotonic() - started, OUT))
    return OUT


if __name__ == "__main__":
    log.set_prefix("web-game")
    build()
