#!/usr/bin/env python3
"""把 game/ 装进官方 LÖVE 11.5 Android 运行时, 用本地密钥签名, 产出可安装的 APK.

liblove.so 直接用官方发行包里编译好的, 只替换游戏负载, 改写 AndroidManifest, 换图标并重新签名,
不需要 gradle. 原版包不编译任何原生代码; 带 mod 的包会顺带编译 bbnet (见 bbnet_replacements),
需要 NDK, cargo-ndk 与对应的 rust target, 不需要时加 --no-native.

用法:
    python3 scripts/package_android.py
    python3 scripts/package_android.py --package com.foo.bar
    python3 scripts/package_android.py --keystore 我的.jks --keystore-pass 密码
    python3 scripts/package_android.py --mods   # 带 mod 的版本, 包名与原版不同, 可同时安装
"""
import argparse
import os
import shutil
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import (android_manifest, archive, gamezip, layout, log, modding, pngutil, runtime,
                 version as versionlib)
import build_native  # noqa: E402  打包带 mod 的版本时顺带编译 bbnet

log.set_prefix("android")

ASSET_NAME = "game.love"
# LÖVE for Android 从这个固定路径读取游戏, 不能放在归档根目录.
ASSET_PATH = "assets/%s" % ASSET_NAME
# 应用图标在 APK 中已有的资源路径, 逐密度替换, 不能只提供部分密度:
# resources.arsc 里记录了每个密度对应的文件, 缺文件会导致图标加载异常.
ICON_DENSITIES = (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                  ("xxhdpi", 144), ("xxxhdpi", 192))
# 运行时的原始图标资源名, manifest 里以 @drawable/love 引用.
ICON_RESOURCE = "love.png"

KEYSTORE_DEFAULT_ALIAS = "balatro"

BBNET_LIB = "libbbnet.so"
# 带 mod 的包必须带 bbnet 的 ABI. 几乎所有在用的设备都是 arm64; armeabi-v7a 能编就带上.
REQUIRED_ABIS = ("arm64-v8a",)


def parse_args():
    parser = argparse.ArgumentParser(description="打包 Android 安装包")
    parser.add_argument("--package", default=None,
                        help="应用包名, 默认 %s, 带 mod 时为 %s"
                        % (layout.VANILLA.android_package, layout.MODDED.android_package))
    parser.add_argument("--keystore", default=None,
                        help="签名密钥, 默认 secrets/%s.keystore" % KEYSTORE_DEFAULT_ALIAS)
    parser.add_argument("--keystore-pass", default=None,
                        help="密钥库口令, 也可用环境变量 BALATRO_KEYSTORE_PASS")
    parser.add_argument("--key-alias", default=KEYSTORE_DEFAULT_ALIAS,
                        help="密钥别名, 默认 %s" % KEYSTORE_DEFAULT_ALIAS)
    parser.add_argument("--key-pass", default=None,
                        help="密钥口令, 缺省与密钥库口令相同")
    parser.add_argument("--icon", default=None, help="图标源图, 默认 assets/icon.png")
    parser.add_argument("--version-code", type=int, default=None,
                        help="Android 版本号整数, 默认按游戏版本折算")
    parser.add_argument("--install", action="store_true",
                        help="打包完成后安装到已连接的设备")
    parser.add_argument("--keep-work", action="store_true", help="保留临时目录")
    parser.add_argument("--no-native", action="store_true",
                        help="带 mod 时不编译也不放入原生库 bbnet (内置 agent 与录像不可用), 默认必须带")
    modding.add_arguments(parser)
    return parser.parse_args()


def find_build_tools():
    """定位 Android SDK 的 build-tools, 返回目录."""
    candidates = [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
                  os.path.expanduser("~/Library/Android/sdk"),
                  os.path.expanduser("~/Android/Sdk")]
    for root in candidates:
        if not root or not os.path.isdir(root):
            continue
        bt_root = os.path.join(root, "build-tools")
        if not os.path.isdir(bt_root):
            continue
        versions = sorted(os.listdir(bt_root))
        for version in reversed(versions):
            path = os.path.join(bt_root, version)
            if os.path.isfile(os.path.join(path, "apksigner")):
                log.info("使用 build-tools %s (来自 %s)" % (version, root))
                return path
    log.die("找不到 Android SDK 的 build-tools\n"
            "请安装 Android SDK 并设置 ANDROID_HOME, 或放入默认位置 ~/Library/Android/sdk\n"
            "需要 build-tools (提供 apksigner 与 zipalign); 带 mod 的包另需 NDK 编译 bbnet")


def tool(build_tools, name):
    """优先用 PATH 里的工具, 找不到时回退到 build-tools 目录."""
    path = shutil.which(name)
    if path:
        return path
    candidate = os.path.join(build_tools, name)
    if os.path.isfile(candidate):
        return candidate
    log.die("找不到工具 %s" % name)


def find_keytool():
    """定位 JDK 的 keytool, 用于生成自签名密钥."""
    candidates = []
    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        candidates.append(os.path.join(java_home, "bin", "keytool"))
    candidates.append(shutil.which("keytool"))
    candidates += [
        "/opt/homebrew/opt/openjdk@17/bin/keytool",
        "/usr/local/opt/openjdk@17/bin/keytool",
        "/usr/libexec/java_home/bin/keytool",
    ]
    for path in candidates:
        if path and os.path.isfile(path):
            return path
    log.die("找不到 keytool, 生成签名密钥需要 JDK 17")


def find_adb():
    """定位 adb, 用于把 APK 安装到设备."""
    path = shutil.which("adb")
    if path:
        return path
    for root in (os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
                 os.path.expanduser("~/Library/Android/sdk"),
                 os.path.expanduser("~/Android/Sdk")):
        if not root:
            continue
        candidate = os.path.join(root, "platform-tools", "adb")
        if os.path.isfile(candidate):
            return candidate
    log.die("找不到 adb, 请安装 Android SDK 的 platform-tools 或改用 adb 手动安装")


def generate_keystore(path, alias, store_pass, key_pass, app_name):
    """生成自签名密钥库, 供本地安装使用."""
    keytool = find_keytool()
    layout.ensure_dir(os.path.dirname(path))
    log.info("生成新密钥: %s" % path)
    log.run([keytool, "-genkeypair", "-v", "-keystore", path, "-alias", alias,
             "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
             "-storetype", "PKCS12", "-storepass", store_pass, "-keypass", key_pass,
             "-dname", "CN=%s Local Build, OU=Personal, O=Personal, C=CN" % app_name],
            quiet=True)
    log.warn("请妥善保存该密钥: 换密钥后无法覆盖安装, 只能先卸载. "
             "此文件不应提交进仓库.")


def bbnet_replacements(base_apk, skip):
    """编译并返回要放进 APK 的 bbnet 原生库, 归档内路径 -> 本地文件.

    没有 bbnet 时内置 agent 连不上模型 (Android 上没有 SMODS.https 的退路), 录像也拿不到 mp4,
    而游戏照常启动, 看不出问题. 所以打包时每次都重新编译 (cargo 增量编译, 没改动时很快),
    既不会漏带, 也不会带上改代码之前编的旧库:
    - REQUIRED_ABIS 编不出来就报错退出.
    - 其余 ABI 缺编译条件 (例如没装对应的 rust target) 时警告并跳过, 那类设备上没有这两项功能.
    - skip 为真 (--no-native) 时整个跳过, 只打一条警告.

    只放运行时 APK 已有的 ABI: 多出一个没有 liblove.so 的 ABI 目录会让系统在该架构的设备上
    选中它, 游戏反而无法启动. 运行时里的 .so 是压缩存储的 (安装时解出), 按同样方式压缩即可.
    """
    if skip:
        log.warn("--no-native: 不带 bbnet, 内置 agent 连不上模型, 录像只有时间轴")
        return {}
    with zipfile.ZipFile(base_apk) as zf:
        abis = sorted({name.split("/")[1] for name in zf.namelist()
                       if name.startswith("lib/") and name.count("/") == 2})
    buildable = []
    for abi in abis:
        missing = build_native.android_missing(abi)
        if not missing:
            buildable.append(abi)
        elif abi in REQUIRED_ABIS:
            log.die("编译不了 %s 的 bbnet: %s\n确实不需要内置 agent 与录像时, 加 --no-native 打包" % (abi, missing))
        else:
            log.warn("跳过 %s 的 bbnet: %s. 这类设备上内置 agent 连不上模型, 录像只有时间轴" % (abi, missing))
    if buildable:
        build_native.build_android(buildable)
    found = {}
    for abi in buildable:
        path = build_native.android_lib(abi)
        if not os.path.isfile(path):
            log.die("编译后没有找到 %s" % os.path.relpath(path, layout.ROOT_DIR))
        found["lib/%s/%s" % (abi, BBNET_LIB)] = path
    return found


def assemble_apk(base_apk, out_apk, replacements):
    """复制 base_apk 到 out_apk, 用 replacements 里的文件替换或新增同名条目.

    replacements 是 归档内路径 -> 本地文件.
    """
    stored = {ASSET_NAME}
    with zipfile.ZipFile(base_apk) as src:
        infos = src.infolist()
        with zipfile.ZipFile(out_apk, "w", zipfile.ZIP_DEFLATED) as dst:
            for info in infos:
                if info.filename in replacements:
                    continue
                new_info = zipfile.ZipInfo(info.filename, date_time=info.date_time)
                new_info.compress_type = info.compress_type
                new_info.external_attr = info.external_attr
                new_info.internal_attr = info.internal_attr
                new_info.create_system = info.create_system
                dst.writestr(new_info, src.read(info.filename))
            for name, path in sorted(replacements.items()):
                new_info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                # .love 本身已是压缩包, 不再二次压缩.
                new_info.compress_type = (zipfile.ZIP_STORED
                                          if os.path.basename(name) in stored
                                          else zipfile.ZIP_DEFLATED)
                new_info.external_attr = 0o644 << 16
                with open(path, "rb") as fh:
                    dst.writestr(new_info, fh.read())


def main():
    args = parse_args()
    flavor = modding.flavor(args)

    package_name = args.package or flavor.android_package
    if not all(ch.isalnum() or ch in "._" for ch in package_name) or "." not in package_name:
        log.die("包名不合法: %s" % package_name)

    store_pass = args.keystore_pass or os.environ.get("BALATRO_KEYSTORE_PASS") or "balatro"
    key_pass = args.key_pass or store_pass
    version = versionlib.build_version()
    version_code = args.version_code or versionlib.android_version_code(version)
    icon_src = args.icon or layout.icon_path()
    if not os.path.isfile(icon_src):
        log.die("找不到图标源图: %s" % icon_src)

    log.info("游戏版本 %s, 版本号 %d, 包名 %s, 变体 %s"
             % (version, version_code, package_name, flavor.key))

    # CI 里别名来自 secret, 未配置时会传空字符串, 因此空值需要回退到默认值.
    key_alias = args.key_alias or KEYSTORE_DEFAULT_ALIAS

    runtime_apk = runtime.require("android")
    build_tools = find_build_tools()
    zipalign = tool(build_tools, "zipalign")
    apksigner = tool(build_tools, "apksigner")

    out_dir = layout.ensure_dir(layout.ANDROID_DIST)
    work_dir = tempfile.mkdtemp(prefix=".android-", dir=out_dir)
    try:
        love_path = os.path.join(work_dir, ASSET_NAME)
        gamezip.build(modding.game_source(args, work_dir, version), love_path)

        log.info("改写 AndroidManifest")
        base_apk = os.path.join(work_dir, "base.apk")
        strings = {
            "org.love2d.android": package_name,
            "org.love2d.android.androidx-startup": "%s.androidx-startup" % package_name,
            # androidx 声明的自定义权限, 名字以包名开头. 不改的话原版与 modded 两个包声明同名权限,
            # 签名不同时第二个装不上 (INSTALL_FAILED_DUPLICATE_PERMISSION).
            "org.love2d.android.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION":
                "%s.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION" % package_name,
            "LÖVE for Android": flavor.app_name,
            "11.5a": version,
        }
        # sensorLandscape: 锁定横屏, 但允许随手机方向左右翻转.
        ints = {"screenOrientation": 5, "versionCode": version_code}
        android_manifest.patch_apk(runtime_apk, base_apk, strings, ints)

        log.info("生成各密度图标")
        replacements = {ASSET_PATH: love_path}
        for density, size in ICON_DENSITIES:
            icon_path = os.path.join(work_dir, "love-%s.png" % density)
            pngutil.scaled_copy(icon_src, icon_path, size)
            replacements["res/drawable-%s-v4/%s" % (density, ICON_RESOURCE)] = icon_path

        # bbnet 只有 mod 里的内置 agent 使用, 原版不带.
        if flavor.key == layout.MODDED.key:
            native_libs = bbnet_replacements(base_apk, args.no_native)
            for name in sorted(native_libs):
                log.info("加入原生库 %s" % name)
            replacements.update(native_libs)

        log.info("组装 APK")
        out_apk = os.path.join(work_dir, "out.apk")
        assemble_apk(base_apk, out_apk, replacements)

        # 静默的路径错误会让 APK 装得上但启动即失败, 因此组装后逐项确认.
        with zipfile.ZipFile(out_apk) as zf:
            present = set(zf.namelist())
        for name in sorted(replacements):
            if name not in present:
                log.die("组装后的 APK 里缺少 %s" % name)

        log.info("对齐")
        aligned = os.path.join(work_dir, "aligned.apk")
        log.run([zipalign, "-f", "-p", "4", out_apk, aligned], quiet=True)

        keystore = args.keystore or os.path.join(layout.SECRETS_DIR, "%s.keystore" % key_alias)
        if not os.path.isfile(keystore):
            os.makedirs(os.path.dirname(os.path.abspath(keystore)), exist_ok=True)
            generate_keystore(keystore, key_alias, store_pass, key_pass, layout.APP_NAME)

        apk_out = os.path.join(out_dir, "%s-%s.apk" % (flavor.file_stem, version))
        log.info("签名")
        log.run([apksigner, "sign", "--ks", keystore,
                 "--ks-pass", "pass:%s" % store_pass,
                 "--key-pass", "pass:%s" % key_pass,
                 "--ks-key-alias", key_alias,
                 "--v1-signing-enabled", "true",
                 "--v2-signing-enabled", "true",
                 # 关闭 v4 以免额外产生 .idsig 文件, 安装并不需要它.
                 "--v4-signing-enabled", "false",
                 "--out", apk_out, aligned], quiet=True)

        log.info("校验签名")
        output = log.run([apksigner, "verify", "-v", "--print-certs", apk_out], capture=True)
        for line in output.splitlines():
            if line.startswith("Verified using") or line.startswith("Signer #1 certificate DN"):
                log.info("  %s" % line)
        if "Verifies" not in output:
            log.die("APK 签名校验未通过")
        log.run([zipalign, "-c", "4", apk_out], quiet=True)
        log.info("对齐校验通过")
    finally:
        if args.keep_work:
            log.info("保留工作目录: %s" % work_dir)
        else:
            shutil.rmtree(work_dir, ignore_errors=True)

    log.info("完成: %s (%s)" % (apk_out, archive.human_size(os.path.getsize(apk_out))))
    if args.install:
        adb = find_adb()
        log.info("安装到设备")
        log.run([adb, "install", "-r", apk_out])
    else:
        log.info("安装: adb install -r \"%s\"" % apk_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
