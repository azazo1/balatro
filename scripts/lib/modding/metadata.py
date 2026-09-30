"""找出每个 smods mod 的 id 与根目录.

smods 加载 mod 文件时使用 `=[SMODS <id> "<相对路径>"]` 作为代码块名, lovely 补丁以此为目标.
打包时需要知道 id 对应哪个目录才能预先打好补丁. 这里按 smods 的扫描规则
(src/preflight/loader.lua 的 processDirectory) 查找元数据:

- mod 文件夹及其下一层子文件夹里的 json, 带字符串 id 字段.
- 同样范围内以 `--- STEAMODDED HEADER` 开头, 含 `--- MOD_ID:` 的 lua 文件.

跳过 localization 与 assets 子目录. Steamodded 自身在代码块名里用 `_` 作为 id.
"""
import json
import os
import re

from .. import log

_HEADER = "--- STEAMODDED HEADER"
_MOD_ID_RE = re.compile(r"--- MOD_ID: ([^ \n]+)\n")
SMODS_ID = "Steamodded"
SMODS_ALIAS = "_"


def is_steamodded(path):
    return os.path.isfile(os.path.join(path, "src", "preflight", "core.lua"))


def _ids_in_dir(directory):
    """directory 下直接包含的元数据文件声明的 id."""
    found = []
    for name in sorted(os.listdir(directory)):
        full = os.path.join(directory, name)
        if not os.path.isfile(full):
            continue
        lower = name.lower()
        if ".json" in lower:
            try:
                with open(full, encoding="utf-8") as fh:
                    data = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(data, dict) and isinstance(data.get("id"), str):
                found.append(data["id"])
        elif lower.endswith(".lua"):
            try:
                with open(full, encoding="utf-8", errors="replace") as fh:
                    text = fh.read().replace("\r\n", "\n")
            except OSError:
                continue
            if text.split("\n", 1)[0] == _HEADER:
                match = _MOD_ID_RE.search(text)
                if match:
                    found.append(match.group(1))
    return found


def scan_ids(sources):
    """返回 {mod id: [mod 根目录, ...]}. 同一个 id 可能出现在多个目录 (多版本并存)."""
    roots = {}

    def add(mod_id, path):
        roots.setdefault(mod_id, [])
        if path not in roots[mod_id]:
            roots[mod_id].append(path)

    for mod in sources:
        if is_steamodded(mod.path):
            add(SMODS_ID, mod.path)
            add(SMODS_ALIAS, mod.path)
            continue
        candidates = [mod.path]
        for name in sorted(os.listdir(mod.path)):
            full = os.path.join(mod.path, name)
            if os.path.isdir(full) and name.lower() not in ("localization", "assets", "lovely"):
                candidates.append(full)
        for directory in candidates:
            for mod_id in _ids_in_dir(directory):
                add(mod_id, directory)
    for mod_id, paths in sorted(roots.items()):
        for path in paths:
            log.debug("mod id %s -> %s" % (mod_id, path))
    return roots
