"""改写 macOS 应用包的 Info.plist.

用标准库 plistlib 处理, 因此不依赖 plutil, 逻辑也更直观.
"""
import os
import plistlib

from . import log


def load(path):
    with open(path, "rb") as fh:
        return plistlib.load(fh)


def save(path, data):
    with open(path, "wb") as fh:
        plistlib.dump(data, fh, fmt=plistlib.FMT_XML, sort_keys=False)


def update(path, values, remove=()):
    """更新 plist 中的键值, 并删除指定的键.

    values 里的键不存在时会新增, 已存在时覆盖. remove 里的键不存在时忽略.
    """
    if not os.path.isfile(path):
        log.die("找不到 Info.plist: %s" % path)
    data = load(path)
    for key, value in values.items():
        data[key] = value
    for key in remove:
        data.pop(key, None)
    save(path, data)
    changed = ", ".join(sorted(values)) or "无"
    log.info("已更新 Info.plist: %s" % changed)
    if remove:
        log.info("已移除 Info.plist 键: %s" % ", ".join(sorted(remove)))
    return data
