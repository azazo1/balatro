"""产物完整性级别 (Windows 的 Low 标志) 的修复.

沙箱会把工作区目录标成低完整性级别 (Low), 新建的文件与目录都从父目录继承这个标志,
因此 dist/ 下的产物会带上 Low. 产物要拿去分发, 不该留打包环境的痕迹, 所以在打包收尾时
把产物重置回 Medium.

抬高完整性级别要写入属主, 沙箱内的进程自身就是 Low, 那时这里只能报告失败, 交给沙箱外的
终端处理, 见 scripts/fix_acl.py.
"""
import os
import subprocess
import sys

from . import log

# 产物应有的级别: 普通用户进程创建的文件就是 Medium.
MEDIUM = "Medium"


def supported():
    """完整性级别是 Windows 的概念, 其余平台无需处理."""
    return sys.platform == "win32"


def reset(path, recursive=True):
    """重置单个文件或目录的完整性级别, 返回 (是否成功, 失败原因).

    目录要带上继承标志并连子项一起处理, 否则目录修好了, 里面的 exe 与 dll 还是 Low.
    抬高完整性级别要写入属主, 沙箱内的进程自身就是 Low, 那时这里只能报告失败.
    """
    if not supported():
        return True, ""
    if not os.path.exists(path):
        return False, "路径不存在"

    is_dir = os.path.isdir(path)
    level = "(OI)(CI)%s" % MEDIUM if is_dir else MEDIUM
    cmd = ["icacls", path, "/setintegritylevel", level]
    if is_dir and recursive:
        cmd.append("/T")
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except OSError as exc:
        return False, str(exc)
    if result.returncode == 0:
        return True, ""
    # icacls 会把被拒的原因写在输出里, 取第一行足够定位.
    lines = [line.strip() for line in (result.stdout or "").splitlines() if line.strip()]
    return False, lines[0] if lines else "icacls 退出码 %d" % result.returncode


def reset_all(paths, recursive=True):
    """依次重置多个产物的完整性级别, 返回没能修复的路径列表."""
    if not supported():
        return []
    failed = []
    for path in paths:
        ok, reason = reset(path, recursive)
        if ok:
            log.info("完整性级别已重置为 %s: %s" % (MEDIUM, path))
        else:
            log.warn("无法重置 %s 的完整性级别: %s" % (path, reason))
            failed.append(path)
    return failed
