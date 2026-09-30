"""把 game/ 目录打包为 .love 归档.

.love 就是一个 zip, 但要求 main.lua 位于归档根部, 且不应混入 .DS_Store 之类的元数据.
这里统一处理这些约束, 并让打包结果可复现 (固定时间戳与固定顺序).
"""
import os
import zipfile

from . import log

# 不进入归档的文件与目录.
SKIP_NAMES = {".DS_Store", ".git", ".gitignore", "__MACOSX", ".tmp"}
# 固定时间戳, 让同样的输入产生同样的归档.
FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def iter_files(game_dir):
    """按相对路径排序后逐个产出文件路径."""
    entries = []
    for dirpath, dirnames, filenames in os.walk(game_dir):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_NAMES)
        for name in sorted(filenames):
            if name in SKIP_NAMES:
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, game_dir).replace(os.sep, "/")
            entries.append((rel, full))
    entries.sort()
    return entries


def build(game_dir, out_path, required=("main.lua", "conf.lua")):
    """把 game_dir 打包为 out_path, 返回写入的文件数."""
    for name in required:
        if not os.path.isfile(os.path.join(game_dir, name)):
            log.die("game 目录缺少 %s: %s" % (name, game_dir))

    entries = iter_files(game_dir)
    if not entries:
        log.die("game 目录为空: %s" % game_dir)

    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel, full in entries:
            info = zipfile.ZipInfo(rel, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            # 保留可执行位, 其余用常规文件权限.
            mode = 0o755 if os.access(full, os.X_OK) else 0o644
            info.external_attr = mode << 16
            with open(full, "rb") as fh:
                zf.writestr(info, fh.read())

    # 复核归档根部确实有必需文件, 避免打包出一个无法启动的游戏.
    with zipfile.ZipFile(out_path) as zf:
        names = set(zf.namelist())
    for name in required:
        if name not in names:
            log.die("归档根部缺少 %s: %s" % (name, out_path))

    log.info("已打包 %d 个文件为 %s" % (len(entries), os.path.basename(out_path)))
    return len(entries)
