"""把补丁的 target 字符串对应到打包时能处理的对象.

lovely 在运行时拦截 luaL_loadbuffer, target 就是代码块名. 打包时没有这个钩子, 只能按
代码块名的来源分别处理:

- game: 游戏自身的 lua 文件, 如 `card.lua`. 着色器文件名如 `CRT.fs` 也归到这里,
  smods 读取 resources/shaders 下的文件后以文件名调用 apply_patches.
- module: `=[lovely <名字> "<源文件>"]`, lovely 模块补丁注入的代码.
- smods: `=[SMODS <id> "<路径>"]`, smods 加载的 mod 文件与着色器.
- content: 运行时对任意内容调用 apply_patches 的虚拟目标, 按内容哈希预先算好结果.
- love: LÖVE 内置脚本, 打包时改不到源码, 由运行时替身在结果上重放 pattern 补丁.
"""
import os
import re
from dataclasses import dataclass, field

MODULE_RE = re.compile(r'^=\[lovely (\S+) "([^"]+)"\]$')
SMODS_RE = re.compile(r'^=\[SMODS (\S+) "([^"]+)"\]$')
LOVE_RE = re.compile(r'^=\[love "([^"]+)"\]$')

SHADER_DIR = "resources/shaders"
# 运行时以着色器内容调用 apply_patches 的目标, 见 smods 的 love.graphics.newShader 覆盖.
CONTENT_TARGETS = ("GLSL_ES_PATCHES.fs",)
# 能在运行时重放的 LÖVE 内置脚本. wrap_GraphicsShader.lua 负责拼接着色器头部.
LOVE_TARGETS = ("wrap_GraphicsShader.lua",)
SHADER_EXTS = (".fs", ".vs", ".glsl", ".frag", ".vert")


def module_chunk_name(patch):
    return '=[lovely %s "%s"]' % (patch.name, patch.source)


@dataclass
class Target:
    name: str
    kind: str                 # game / module / smods / content / love / unresolved / absent
    paths: list = field(default_factory=list)
    detail: str = ""


def _inside(root, rel):
    full = os.path.normpath(os.path.join(root, rel))
    if os.path.commonpath([full, os.path.normpath(root)]) != os.path.normpath(root):
        return None
    return full


def resolve(name, tree_dir, module_names, mod_roots):
    """解析一个 target. module_names 为全部模块代码块名, mod_roots 为 {id: [根目录]}."""
    if name in CONTENT_TARGETS:
        return Target(name, "content")
    if name in module_names:
        return Target(name, "module")
    match = LOVE_RE.match(name)
    if match:
        if match.group(1) in LOVE_TARGETS:
            return Target(name, "love", detail=match.group(1))
        return Target(name, "unresolved", detail="打包时无法修改 LÖVE 内置脚本 %s" % match.group(1))
    match = SMODS_RE.match(name)
    if match:
        mod_id, rel = match.groups()
        roots = mod_roots.get(mod_id)
        if not roots:
            return Target(name, "absent", detail="没有打包 id 为 %s 的 mod" % mod_id)
        paths = []
        for root in roots:
            for base in (root, os.path.join(root, "assets", "shaders")):
                full = _inside(base, rel)
                if full and os.path.isfile(full) and full not in paths:
                    paths.append(full)
        if not paths:
            return Target(name, "absent", detail="mod %s 中没有文件 %s" % (mod_id, rel))
        return Target(name, "smods", paths)
    if MODULE_RE.match(name):
        return Target(name, "absent", detail="没有名为此的模块补丁")
    if name.startswith("=") or name.startswith("@"):
        return Target(name, "unresolved", detail="无法确定这个代码块名对应的文件")
    for base in (tree_dir, os.path.join(tree_dir, SHADER_DIR)):
        full = _inside(base, name)
        if full and os.path.isfile(full):
            return Target(name, "game", [full])
    return Target(name, "absent", detail="游戏中没有文件 %s" % name)


def shader_files(tree_dir, mod_roots):
    """运行时可能交给 love.graphics.newShader 的着色器文件."""
    dirs = [os.path.join(tree_dir, SHADER_DIR)]
    for roots in mod_roots.values():
        for root in roots:
            dirs.append(os.path.join(root, "assets", "shaders"))
    files = []
    for directory in dirs:
        if not os.path.isdir(directory):
            continue
        for dirpath, _dirs, names in os.walk(directory):
            for name in sorted(names):
                if name.lower().endswith(SHADER_EXTS):
                    full = os.path.join(dirpath, name)
                    if full not in files:
                        files.append(full)
    return sorted(files)
