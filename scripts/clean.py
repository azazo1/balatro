#!/usr/bin/env python3
"""删除打包产物.

修过完整性级别的产物是普通文件, 沙箱内的进程删不掉它们, 这时必须明确报出哪些没删掉,
否则旧产物会留在原地, 而被误以为已经清理干净.

用法:
    python3 scripts/clean.py            # 删除 dist/
    python3 scripts/clean.py 某个目录    # 删除指定目录 (便于排查)
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import layout, log

log.set_prefix("clean")


def remove(path):
    """删除一个文件或目录, 返回 None 表示成功, 否则返回失败原因."""
    try:
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
    except OSError as exc:
        return str(exc)
    return None


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else layout.DIST_DIR
    if not os.path.exists(target):
        log.info("没有打包产物: %s" % target)
        return 0

    failed = []
    for name in sorted(os.listdir(target)):
        path = os.path.join(target, name)
        reason = remove(path)
        if reason is None:
            log.info("已删除 %s" % path)
        else:
            log.warn("删除失败: %s (%s)" % (path, reason))
            failed.append(path)

    # 目录里还有东西说明没能清空, 这时保留目录本身, 便于按提示再处理.
    try:
        os.rmdir(target)
    except OSError:
        pass

    if failed:
        log.die("有 %d 项没能删除. 修过完整性级别的产物是普通文件, 沙箱内的进程删不掉, "
                "请在沙箱外的终端里删除它们." % len(failed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
