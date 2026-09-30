"""vendor 目录里各平台运行时的定位与校验.

运行时都是官方 LÖVE 发行包, 校验 sha256 可以确保内容没有被替换或损坏.
"""
import hashlib
import os

from . import log
from .layout import VENDOR_DIR

# 平台名 -> (文件名, sha256, 来源说明)
RUNTIMES = {
    "macos": (
        "love-11.5-macos.zip",
        "6795bb3a1656af6a2fdfe741e150787b481886d3a280327a261a3fdded586913",
        "https://github.com/love2d/love/releases/download/11.5/love-11.5-macos.zip",
    ),
    "android": (
        "love-11.5-android-embed.apk",
        "dcf71c1b54c5b5a09598ef1e6cf4852ced5e5e612de3d0f30cfdd39b5014e889",
        "https://github.com/love2d/love-android/releases/download/11.5a/love-11.5-android-embed.apk",
    ),
    "windows": (
        "love-11.5-win64.zip",
        "ba6e56be2685e53c817749c4a5007f51137136fe5a3ab64920508babc2e74369",
        "https://github.com/love2d/love/releases/download/11.5/love-11.5-win64.zip",
    ),
}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require(platform):
    """返回校验通过的运行时路径, 失败时给出可执行的修复提示."""
    try:
        name, expected, url = RUNTIMES[platform]
    except KeyError:
        log.die("没有为平台 %s 登记运行时" % platform)
    path = os.path.join(VENDOR_DIR, name)
    if not os.path.isfile(path):
        log.die("缺少 %s 运行时: %s\n可以这样获取:\n  curl -L -o %s %s"
                % (platform, path, path, url))
    actual = sha256(path)
    if actual != expected:
        log.die("运行时哈希不符\n  期望: %s\n  实际: %s\n文件: %s"
                % (expected, actual, path))
    log.info("运行时校验通过: %s" % name)
    return path
