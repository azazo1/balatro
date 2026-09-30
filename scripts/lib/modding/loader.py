"""发现 mod, 把它们整理到暂存目录, 并按 lovely 的顺序加载补丁文件.

顺序规则与 lovely-core 的 patch/loader.rs 一致:

- Mods 目录下先是文件夹, 后是 zip, 各自按小写文件名排序.
- 每个 mod 内先读 lovely.toml, 再读 lovely/ 下递归找到的 *.toml, 按小写文件名排序.
- 跳过 Mods/lovely/blacklist.txt 里列出的名字, 以及含 .lovelyignore 的文件夹.

zip 在暂存时解开成文件夹: 运行时 smods 按真实文件读取 mod, 解开后行为与文件夹 mod 相同.
"""
import os
import posixpath
import shutil
import tomllib
import zipfile
from dataclasses import dataclass

from .. import log
from .patches import LoadedPatch, Origin, PatchError, parse_patch

# lovely 自己的工作目录, 放日志, dump 与 blacklist, 不是 mod.
LOVELY_DIR = "lovely"
# 不进入暂存目录的文件, 与 .love 打包时的忽略项一致.
SKIP_NAMES = {".DS_Store", ".git", ".gitignore", "__MACOSX", ".tmp"}
# 补丁文件里 {{lovely_hack:patch_dir}} 的替身, 运行时换成该 mod 在存档目录里的真实路径.
PATCH_DIR_SENTINEL = "@@LOVELY_SHIM_MOD_DIR_%d@@"


@dataclass
class ModSource:
    """一个已暂存的 mod."""
    folder: str   # 暂存后的文件夹名, 也是运行时 Mods 下的文件夹名
    path: str     # 暂存目录中的绝对路径
    origin: str   # 来源: 原始文件夹或 zip 的路径
    index: int    # 在 mod 列表中的序号, 从 1 开始, 对应补丁目录替身里的编号


def read_blacklist(mods_dir):
    path = os.path.join(mods_dir, LOVELY_DIR, "blacklist.txt")
    if not os.path.isfile(path):
        return set()
    with open(path, encoding="utf-8") as fh:
        return {line.rstrip("\r\n") for line in fh
                if line.strip() and not line.startswith("#")}


def _ignore(_dir, names):
    return [name for name in names if name in SKIP_NAMES]


def _safe_member(name):
    """zip 条目的规范化相对路径, 拒绝绝对路径与 .. 以防写出暂存目录."""
    norm = posixpath.normpath(name.replace("\\", "/"))
    if norm.startswith("/") or norm == ".." or norm.startswith("../") or ":" in norm.split("/")[0]:
        raise PatchError("zip 条目路径不安全: %s" % name)
    return norm


def _extract_zip(zip_path, dest):
    """解开 zip 到 dest. 若 zip 内只有一个顶层文件夹 (且不是 lovely), 以它为 mod 根目录."""
    with zipfile.ZipFile(zip_path) as zf:
        members = []
        for info in zf.infolist():
            norm = _safe_member(info.filename)
            parts = norm.split("/")
            if norm == "." or any(part in SKIP_NAMES for part in parts):
                continue
            members.append((info, norm))
        tops = {norm.split("/")[0] for _, norm in members}
        strip = None
        if len(tops) == 1:
            top = next(iter(tops))
            if top != LOVELY_DIR and any("/" in norm for _, norm in members):
                strip = top + "/"
        count = 0
        for info, norm in members:
            if strip:
                if not norm.startswith(strip):
                    continue
                norm = norm[len(strip):]
            target = os.path.join(dest, *norm.split("/"))
            if info.is_dir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as fh:
                fh.write(zf.read(info))
            count += 1
    return count


def stage_mods(mods_dir, stage_dir):
    """把 mods_dir 里的 mod 整理到 stage_dir, 返回按 lovely 加载顺序排列的 ModSource 列表."""
    if not os.path.isdir(mods_dir):
        log.die("找不到 mod 目录: %s" % mods_dir)
    blacklist = read_blacklist(mods_dir)
    dirs, zips = [], []
    for name in os.listdir(mods_dir):
        full = os.path.join(mods_dir, name)
        if name in SKIP_NAMES or name == LOVELY_DIR or name.startswith("."):
            continue
        if name in blacklist:
            log.info("跳过 blacklist.txt 中的 %s" % name)
            continue
        if os.path.isdir(full):
            if os.path.isfile(os.path.join(full, ".lovelyignore")):
                log.info("跳过含 .lovelyignore 的 %s" % name)
                continue
            dirs.append(name)
        elif name.lower().endswith(".zip"):
            zips.append(name)
        else:
            log.warn("忽略 mod 目录顶层的文件 %s, 每个 mod 应放在自己的文件夹或 zip 里" % name)

    os.makedirs(stage_dir, exist_ok=True)
    sources = []
    for name in sorted(dirs, key=str.lower):
        dest = os.path.join(stage_dir, name)
        shutil.copytree(os.path.join(mods_dir, name), dest, ignore=_ignore)
        sources.append(ModSource(name, dest, os.path.join(mods_dir, name), len(sources) + 1))
    for name in sorted(zips, key=str.lower):
        folder = name[:-4]
        if any(s.folder.lower() == folder.lower() for s in sources):
            log.die("zip %s 解开后与已有的 mod 文件夹 %s 重名" % (name, folder))
        dest = os.path.join(stage_dir, folder)
        os.makedirs(dest)
        count = _extract_zip(os.path.join(mods_dir, name), dest)
        log.info("解开 %s (%d 个文件)" % (name, count))
        sources.append(ModSource(folder, dest, os.path.join(mods_dir, name), len(sources) + 1))
    return sources


def patch_files(mod_path):
    """mod 内的补丁文件, 顺序与 lovely 一致."""
    files = []
    top = os.path.join(mod_path, "lovely.toml")
    if os.path.isfile(top):
        files.append(top)
    lovely_dir = os.path.join(mod_path, LOVELY_DIR)
    found = []
    if os.path.isdir(lovely_dir):
        for dirpath, _dirs, names in os.walk(lovely_dir):
            for name in names:
                if name.endswith(".toml"):
                    found.append(os.path.join(dirpath, name))
    # lovely 只按文件名排序, 同名时取决于遍历顺序; 这里再按相对路径排, 保证结果稳定.
    found.sort(key=lambda p: (os.path.basename(p).lower(), os.path.relpath(p, lovely_dir)))
    return files + found


_TOP_KEYS = {"manifest", "patches", "vars", "args"}
_MANIFEST_KEYS = {"version", "dump_lua", "priority"}


def _read_source(mod, rel, where):
    full = os.path.normpath(os.path.join(mod.path, rel))
    if os.path.commonpath([full, mod.path]) != os.path.normpath(mod.path):
        raise PatchError("%s: 源文件路径越出 mod 目录: %s" % (where, rel))
    try:
        with open(full, encoding="utf-8", newline="") as fh:
            return fh.read()
    except OSError as exc:
        raise PatchError("%s: 读取源文件 %s 失败: %s" % (where, rel, exc)) from exc


def load_patches(sources):
    """加载全部补丁, 返回 (补丁列表, 合并后的 vars)."""
    patches = []
    variables = {}
    for mod in sources:
        sentinel = PATCH_DIR_SENTINEL % mod.index
        files = patch_files(mod.path)
        count = 0
        for path in files:
            rel = os.path.relpath(path, mod.path).replace(os.sep, "/")
            where = "%s/%s" % (mod.folder, rel)
            with open(path, encoding="utf-8", newline="") as fh:
                text = fh.read().replace("{{lovely_hack:patch_dir}}", sentinel)
            try:
                data = tomllib.loads(text)
            except tomllib.TOMLDecodeError as exc:
                raise PatchError("%s: TOML 解析失败: %s" % (where, exc)) from exc
            for key in data:
                if key not in _TOP_KEYS:
                    log.warn("%s: 忽略未知字段 %s" % (where, key))
            manifest = data.get("manifest")
            if not isinstance(manifest, dict) or not isinstance(manifest.get("version"), str):
                raise PatchError("%s: 缺少 [manifest] 或 manifest.version" % where)
            for key in manifest:
                if key not in _MANIFEST_KEYS:
                    log.warn("%s: 忽略未知字段 manifest.%s" % (where, key))
            priority = manifest.get("priority", 0)
            if not isinstance(priority, int) or isinstance(priority, bool):
                raise PatchError("%s: manifest.priority 应为整数" % where)
            entries = data.get("patches")
            if not isinstance(entries, list):
                raise PatchError("%s: 缺少 [[patches]]" % where)
            file_vars = data.get("vars", {})
            if not isinstance(file_vars, dict) or not all(isinstance(v, str) for v in file_vars.values()):
                raise PatchError("%s: [vars] 的值必须都是字符串" % where)

            for index, entry in enumerate(entries):
                entry_where = "%s#%d" % (where, index)
                kind, body = parse_patch(entry, entry_where, log.warn)
                if kind == "module":
                    body.content = _read_source(mod, body.source, entry_where)
                elif kind == "copy":
                    body.contents = [_read_source(mod, src, entry_where) for src in body.sources or []]
                patches.append(LoadedPatch(kind, body, priority, Origin(mod.folder, rel, index)))
                count += 1
            variables.update(file_vars)
        if files:
            log.info("%s: %d 个补丁文件, %d 个补丁" % (mod.folder, len(files), count))
        else:
            log.info("%s: 没有 lovely 补丁" % mod.folder)
    return patches, variables
