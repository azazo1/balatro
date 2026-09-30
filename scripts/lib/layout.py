"""项目布局与公共常量.

集中定义目录位置与标识, 避免各个打包脚本各自硬编码. 版本号的解析与派生见 version 模块.
"""
import os
from dataclasses import dataclass

# scripts/lib/layout.py 向上三级就是仓库根目录.
ROOT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GAME_DIR = os.path.join(ROOT_DIR, "game")
ASSETS_DIR = os.path.join(ROOT_DIR, "assets")
VENDOR_DIR = os.path.join(ROOT_DIR, "vendor")
DIST_DIR = os.path.join(ROOT_DIR, "dist")
# 本机私密文件, 如 Android 签名密钥. 不入库, 也不随 just clean 删除.
SECRETS_DIR = os.path.join(ROOT_DIR, "secrets")
SCRIPTS_DIR = os.path.join(ROOT_DIR, "scripts")

# 应用标识, 同时决定 .love 归档名与存档目录名.
APP_NAME = "Balatro"
BUNDLE_ID = "local.balatro"
ANDROID_PACKAGE = "com.azazo1.balatro"

# 各平台的产物目录.
MACOS_DIST = os.path.join(DIST_DIR, "macos")
ANDROID_DIST = os.path.join(DIST_DIR, "android")
WINDOWS_DIST = os.path.join(DIST_DIR, "windows")

# 打包进带 mod 版本的 mod 默认从这里读取, 目录不入库.
MODS_DIR = os.path.join(ROOT_DIR, "mods")
# scripts/patch_mods.py 默认输出的补丁后源码树.
MODDED_TREE = os.path.join(DIST_DIR, "modded-tree")


@dataclass(frozen=True)
class Flavor:
    """产物的一种变体. 各变体的标识互不相同, 因此可以同时安装, 存档也互不影响."""
    key: str
    app_name: str          # 显示名
    file_stem: str         # 产物文件名前缀, 不含空格
    bundle_id: str         # macOS
    android_package: str   # Android
    identity: str = None   # 存档目录名, None 表示沿用游戏默认值


VANILLA = Flavor("vanilla", APP_NAME, APP_NAME, BUNDLE_ID, ANDROID_PACKAGE)
MODDED = Flavor("modded", "Balatro Modded", "Balatro-Modded", BUNDLE_ID + ".modded",
                ANDROID_PACKAGE + ".modded", "Balatro-Modded")


def icon_path():
    """图标源图, 供各平台生成各自格式的图标."""
    return os.path.join(ASSETS_DIR, "icon.png")


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    return path
