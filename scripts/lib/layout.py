"""项目布局与公共常量.

集中定义目录位置与版本号, 避免各个打包脚本各自硬编码.
"""
import os

# scripts/lib/layout.py 向上三级就是仓库根目录.
ROOT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GAME_DIR = os.path.join(ROOT_DIR, "game")
ASSETS_DIR = os.path.join(ROOT_DIR, "assets")
VENDOR_DIR = os.path.join(ROOT_DIR, "vendor")
DIST_DIR = os.path.join(ROOT_DIR, "dist")
SCRIPTS_DIR = os.path.join(ROOT_DIR, "scripts")

# 应用标识, 同时决定 .love 归档名与存档目录名.
APP_NAME = "Balatro"
BUNDLE_ID = "local.balatro"
ANDROID_PACKAGE = "com.azazo1.balatro"

# 各平台的产物目录.
MACOS_DIST = os.path.join(DIST_DIR, "macos")
ANDROID_DIST = os.path.join(DIST_DIR, "android")
WINDOWS_DIST = os.path.join(DIST_DIR, "windows")


def game_version():
    """读取本次构建要使用的版本号.

    优先使用 PROJECT_BUILD_VERSION 环境变量 (由 CI 或发布流程注入, 可能形如
    v1.0.1n 或 1.0.1n+abc1234), 未设置时从 game/version.jkr 读取游戏自身版本.

    该文件首行为完整版本 (如 1.0.1n-FULL), 第二行为基础版本 (如 1.0.1n).
    """
    injected = os.environ.get("PROJECT_BUILD_VERSION", "").strip()
    if injected:
        return injected[1:] if injected.startswith("v") else injected

    path = os.path.join(GAME_DIR, "version.jkr")
    try:
        with open(path, encoding="utf-8") as fh:
            first = fh.readline().strip()
    except OSError:
        return "0.0.0"
    return first[:-5] if first.endswith("-FULL") else first


def android_version_code(version=None):
    """把 x.y.z 形式的游戏版本折算为 Android 的整数版本号.

    例如 1.0.1n 会忽略结尾的字母, 得到 1*10000 + 0*100 + 1 = 10001.
    """
    text = version or game_version()
    digits = []
    for part in text.split("."):
        num = ""
        for ch in part:
            if ch.isdigit():
                num += ch
            else:
                break
        digits.append(int(num) if num else 0)
    while len(digits) < 3:
        digits.append(0)
    return digits[0] * 10000 + digits[1] * 100 + digits[2]


def icon_path():
    """图标源图, 供各平台生成各自格式的图标."""
    return os.path.join(ASSETS_DIR, "icon.png")


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    return path
