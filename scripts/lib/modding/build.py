"""生成带 mod 的游戏源码树: 应用全部 lovely 补丁, 附上运行时替身与包内 mod.

输出目录的结构:

    <out>/                      游戏源码, 已打好补丁
    <out>/lovely_shim/runtime.lua
    <out>/lovely_shim/manifest.lua   本次构建的清单, 由这里生成
    <out>/lovely_shim/modules/       模块补丁的源码, 已打好补丁
    <out>/lovely_shim/content/<n>/   按内容哈希查表的虚拟目标结果
    <out>/lovely_shim/mods/          要释放到存档目录 Mods 下的 mod, 已打好补丁

main.lua 开头会插入对运行时的调用, conf.lua 末尾追加存档标识的覆盖.
"""
import hashlib
import os
import re
import shutil
from dataclasses import dataclass, field

from .. import log
from . import loader, metadata, targets
from .patches import (Outcome, PatchError, apply_all, ordered_for_target, rust_lines,
                      rust_trim)
from .targets import module_chunk_name

# 与 lua/runtime.lua 中的 SHIM_DIR 一致.
SHIM_DIR = "lovely_shim"
RUNTIME_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lua", "runtime.lua")
# 运行时的版本, 改动 runtime.lua 或清单格式时递增. 它参与包内 mod 的哈希, 变化后会重新释放.
RUNTIME_VERSION = "1"
# 对 mod 报告的 lovely 版本, 与补丁语义所参照的 lovely 版本一致.
LOVELY_VERSION = "0.10.0"
MANIFEST_FORMAT = 1
# 标记目录由本工具生成, 允许下次构建时整体替换.
TREE_MARKER = ".lovely-shim-tree"

_SENTINEL_RE = re.compile(rb"@@LOVELY_SHIM_MOD_DIR_[0-9]+@@")
_TEXT_EXTS = (".lua", ".toml", ".json", ".txt", ".fs", ".vs", ".glsl", ".frag", ".vert", ".md")
_BEFORE_CALL = "require(%s).before(%s);"
_CONF_CALL = "\nrequire(%s).wrap_conf()\n"


# ---------------------------------------------------------------- 工具

def lua_literal(value, indent=""):
    """把 python 值写成 lua 字面量."""
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        out = ['"']
        for ch in value:
            code = ord(ch)
            if ch == "\\":
                out.append("\\\\")
            elif ch == '"':
                out.append('\\"')
            elif ch == "\n":
                out.append("\\n")
            elif ch == "\r":
                out.append("\\r")
            elif ch == "\t":
                out.append("\\t")
            elif code < 32 or code == 127:
                out.append("\\%03d" % code)
            else:
                out.append(ch)
        out.append('"')
        return "".join(out)
    inner = indent + "    "
    if isinstance(value, (list, tuple)):
        if not value:
            return "{}"
        items = ",\n".join(inner + lua_literal(v, inner) for v in value)
        return "{\n%s,\n%s}" % (items, indent)
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = ",\n".join("%s[%s] = %s" % (inner, lua_literal(k), lua_literal(v, inner))
                           for k, v in sorted(value.items()))
        return "{\n%s,\n%s}" % (items, indent)
    raise TypeError("无法写成 lua 字面量: %r" % (value,))


def wildcard_to_lua(line):
    """把 pattern 的一行 (已去除首尾空白) 转成锚定的 lua 模式."""
    out = ["^"]
    for ch in line:
        if ch == "*":
            out.append(".*")
        elif ch == "?":
            out.append(".")
        elif ch.isascii() and not ch.isalnum():
            out.append("%" + ch)
        else:
            out.append(ch)
    out.append("$")
    return "".join(out)


def _read(path):
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read()


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def _rel(path, root):
    return os.path.relpath(path, root).replace(os.sep, "/")


def list_files(root):
    files = []
    for dirpath, dirnames, names in os.walk(root):
        dirnames.sort()
        for name in sorted(names):
            files.append(_rel(os.path.join(dirpath, name), root))
    return sorted(files)


def bundle_hash(mods_root, files):
    digest = hashlib.sha256(("lovely-shim-runtime-%s\0" % RUNTIME_VERSION).encode())
    for rel in files:
        with open(os.path.join(mods_root, *rel.split("/")), "rb") as fh:
            data = fh.read()
        digest.update(rel.encode("utf-8") + b"\0" + str(len(data)).encode() + b"\0")
        digest.update(data)
    return digest.hexdigest()


# ---------------------------------------------------------------- 报告

@dataclass
class Report:
    mods: list = field(default_factory=list)
    patches: int = 0
    results: list = field(default_factory=list)       # (补丁, target, Outcome)
    unresolved: list = field(default_factory=list)    # (Target, 补丁列表)
    absent: list = field(default_factory=list)
    content_entries: int = 0
    modules: int = 0

    def record(self, patch, target, outcome):
        self.results.append((patch, target, outcome))

    def failures(self):
        return [r for r in self.results if r[2].status in ("miss", "mismatch")]

    def log_summary(self):
        counts = {}
        for _patch, _target, outcome in self.results:
            counts[outcome.status] = counts.get(outcome.status, 0) + 1
        log.info("mod %d 个, 补丁 %d 个, 模块 %d 个" % (len(self.mods), self.patches, self.modules))
        log.info("补丁结果: 命中 %d, 未命中 %d, 次数不符 %d, 运行时重放 %d"
                 % (counts.get("ok", 0), counts.get("miss", 0), counts.get("mismatch", 0),
                    counts.get("runtime", 0)))
        if self.content_entries:
            log.info("按内容查表的预计算结果 %d 条" % self.content_entries)
        for patch, target, outcome in self.failures():
            body = patch.body
            head = getattr(body, "pattern", "").strip().split("\n")[0][:80]
            log.warn("%s: %s -> %s %s %s" % (outcome.status, patch.origin, target, head,
                                             outcome.detail))
        for target, patches in self.unresolved:
            first = patches[0].origin if patches else "?"
            log.warn("无法处理的目标 %s (%s), 涉及 %d 个补丁, 首个来自 %s"
                     % (target.name, target.detail, len(patches), first))
        for target, patches in self.absent:
            log.debug("目标不存在 %s (%s), 涉及 %d 个补丁" % (target.name, target.detail, len(patches)))


# ---------------------------------------------------------------- 构建

def _module_entries(patches):
    """按优先级排好的模块条目. 同名模块后者覆盖前者, 与 lovely 注入 package.preload 的顺序一致."""
    modules = [p for p in patches if p.kind == "module"]
    ordered = sorted([p for p in modules if not p.body.load_now], key=lambda p: p.priority)
    ordered += sorted([p for p in modules if p.body.load_now], key=lambda p: p.priority)
    entries = []
    for index, patch in enumerate(ordered, 1):
        entries.append({
            "patch": patch,
            "name": patch.body.name,
            "chunk": module_chunk_name(patch.body),
            "file": "modules/%03d.lua" % index,
            "load_now": patch.body.load_now,
            "before": patch.body.before,
            "text": patch.body.content,
        })
    return entries


def build_tree(game_dir, mods_dir, out_dir, identity, build_version, strict=False):
    """在 out_dir 生成带 mod 的游戏源码树, 返回 Report. out_dir 必须不存在."""
    if os.path.exists(out_dir):
        raise PatchError("输出目录已存在: %s" % out_dir)
    report = Report()

    log.info("复制游戏源码")
    shutil.copytree(game_dir, out_dir, ignore=loader._ignore)
    if os.path.exists(os.path.join(out_dir, SHIM_DIR)):
        raise PatchError("游戏源码里已有 %s 目录, 与运行时替身冲突" % SHIM_DIR)
    with open(os.path.join(out_dir, TREE_MARKER), "w", encoding="utf-8") as fh:
        fh.write("generated by scripts/lib/modding\n")

    shim_dir = os.path.join(out_dir, SHIM_DIR)
    mods_root = os.path.join(shim_dir, "mods")
    log.info("整理 mod: %s" % mods_dir)
    sources = loader.stage_mods(mods_dir, mods_root)
    report.mods = [s.folder for s in sources]
    if not sources:
        log.warn("mod 目录里没有任何 mod")

    patches, variables = loader.load_patches(sources)
    report.patches = len(patches)
    mod_roots = metadata.scan_ids(sources)
    entries = _module_entries(patches)
    report.modules = len(entries)
    module_names = {e["chunk"] for e in entries}

    target_names = set()
    for patch in patches:
        target_names.update(patch.targets())
    target_names.discard("")

    game_texts = {}
    smods_texts = {}
    content_targets = []
    love_patches = {}

    for name in sorted(target_names):
        target = targets.resolve(name, out_dir, module_names, mod_roots)
        related = [p for p in patches if name in p.targets()]
        log.debug("目标 %s: %s, %d 个补丁" % (name, target.kind, len(related)))

        def report_to(patch, outcome, name=name):
            report.record(patch, name, outcome)

        if target.kind == "module":
            first = True
            for entry in entries:
                if entry["chunk"] == name:
                    callback = report_to if first else (lambda _p, _o: None)
                    entry["text"], _ = apply_all(patches, name, entry["text"], variables, callback)
                    first = False
        elif target.kind in ("smods", "game"):
            store = smods_texts if target.kind == "smods" else game_texts
            for index, path in enumerate(target.paths):
                callback = report_to if index == 0 else (lambda _p, _o: None)
                text = store.get(path)
                if text is None:
                    text = _read(path)
                store[path], _ = apply_all(patches, name, text, variables, callback)
        elif target.kind == "content":
            content_targets.append(name)
        elif target.kind == "love":
            items = []
            for patch in ordered_for_target(patches, name):
                if patch.kind != "pattern":
                    report.unresolved.append((targets.Target(name, "unresolved",
                                              detail="LÖVE 内置脚本只支持 pattern 补丁"), [patch]))
                    continue
                body = patch.body
                items.append({
                    "pattern": [wildcard_to_lua(rust_trim(line)) for line in rust_lines(body.pattern)],
                    "position": body.position,
                    "payload": body.payload,
                    "match_indent": body.match_indent,
                    "times": body.times,
                })
                report.record(patch, name, Outcome("runtime"))
            if items:
                love_patches[target.detail] = items
        elif target.kind == "absent":
            report.absent.append((target, related))
        else:
            report.unresolved.append((target, related))

    # load_now 模块在目标文件执行前求值. main.lua 总要插入调用, 它负责启动运行时.
    load_now = {}
    for entry in entries:
        if entry["load_now"]:
            load_now.setdefault(entry["before"], []).append(entry)
    call_module = lua_literal(SHIM_DIR + ".runtime")
    for before in sorted(set(load_now) | {"main.lua"}):
        prefix = _BEFORE_CALL % (call_module, lua_literal(before))
        if before == "conf.lua":
            raise PatchError("不支持 before = \"conf.lua\" 的 load_now 模块: 此时存档目录尚未确定")
        target = targets.resolve(before, out_dir, module_names, mod_roots)
        if target.kind == "game":
            path = target.paths[0]
            game_texts[path] = prefix + (game_texts[path] if path in game_texts else _read(path))
        elif target.kind == "smods":
            for path in target.paths:
                smods_texts[path] = prefix + (smods_texts[path] if path in smods_texts else _read(path))
        elif target.kind == "module":
            for entry in entries:
                if entry["chunk"] == before:
                    entry["text"] = prefix + entry["text"]
        else:
            raise PatchError("load_now 模块的 before 目标无法处理: %s (%s)" % (before, target.detail))

    conf_path = os.path.join(out_dir, "conf.lua")
    conf_text = game_texts[conf_path] if conf_path in game_texts else _read(conf_path)
    game_texts[conf_path] = conf_text + _CONF_CALL % call_module

    for path, text in sorted(game_texts.items()):
        if _SENTINEL_RE.search(text.encode("utf-8")):
            raise PatchError("游戏文件 %s 引用了 {{lovely_hack:patch_dir}}, 打包时无法确定该路径"
                             % _rel(path, out_dir))
        _write(path, text)
    for path, text in sorted(smods_texts.items()):
        _write(path, text)
    for entry in entries:
        _write(os.path.join(shim_dir, *entry["file"].split("/")), entry["text"])

    # 着色器在运行时以内容调用 apply_patches, 这里对每个可能的着色器预先算好结果.
    content_dirs = {}
    shaders = targets.shader_files(out_dir, mod_roots)
    for index, name in enumerate(content_targets, 1):
        directory = "content/%d" % index
        content_dirs[name] = directory
        for path in shaders:
            with open(path, "rb") as fh:
                raw = fh.read()
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                log.debug("跳过非 UTF-8 的着色器 %s" % path)
                continue
            patched, _ = apply_all(patches, name, text, variables, lambda _p, _o: None)
            if patched == text:
                continue
            if _SENTINEL_RE.search(patched.encode("utf-8")):
                raise PatchError("%s 的结果引用了 {{lovely_hack:patch_dir}}" % name)
            key = hashlib.sha1(raw).hexdigest()
            _write(os.path.join(shim_dir, "content", str(index), key), patched)
            report.content_entries += 1
        for patch in ordered_for_target(patches, name):
            report.record(patch, name, Outcome("runtime"))

    mod_files = list_files(mods_root)
    sentinel_files = []
    for rel in mod_files:
        if not rel.lower().endswith(_TEXT_EXTS):
            continue
        with open(os.path.join(mods_root, *rel.split("/")), "rb") as fh:
            if _SENTINEL_RE.search(fh.read()):
                sentinel_files.append(rel)

    manifest = {
        "format": MANIFEST_FORMAT,
        "runtime_version": RUNTIME_VERSION,
        "lovely_version": LOVELY_VERSION,
        "build_version": build_version,
        "identity": identity,
        "bundle_hash": bundle_hash(mods_root, mod_files),
        "mods": report.mods,
        "files": mod_files,
        "sentinel_files": {rel: True for rel in sentinel_files},
        "modules": [{
            "name": e["name"],
            "file": e["file"],
            "chunk": e["chunk"],
            "load_now": e["load_now"],
            "needs_mod_dir": bool(_SENTINEL_RE.search(e["text"].encode("utf-8"))),
        } for e in entries],
        "load_now": {before: [{
            "name": e["name"],
            "file": e["file"],
            "chunk": e["chunk"],
            "needs_mod_dir": bool(_SENTINEL_RE.search(e["text"].encode("utf-8"))),
        } for e in items] for before, items in load_now.items()},
        "content_targets": content_dirs,
        "love_patches": love_patches,
    }
    _write(os.path.join(shim_dir, "manifest.lua"),
           "-- 由 scripts/lib/modding/build.py 生成, 不要手动修改.\nreturn " + lua_literal(manifest) + "\n")
    shutil.copy2(RUNTIME_SOURCE, os.path.join(shim_dir, "runtime.lua"))

    report.log_summary()
    if strict and (report.failures() or report.unresolved):
        raise PatchError("严格模式: 存在未命中或无法处理的补丁")
    return report
