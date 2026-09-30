"""项目布局与公共常量.

集中定义目录位置与标识, 避免各个打包脚本各自硬编码. 版本号的解析与派生见 version 模块.
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


def icon_path():
    """图标源图, 供各平台生成各自格式的图标."""
    return os.path.join(ASSETS_DIR, "icon.png")


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    return path
