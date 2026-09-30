#!/usr/bin/env python3
"""把 game/ 装进官方 LÖVE 11.5 macOS 运行时, 产出可双击运行的应用包.

做法是复制官方 love.app, 换掉里面的图标与标识, 再把游戏资源作为 .love 放进
Contents/Resources. LÖVE 会在此目录查找 .love 并进入伪融合模式, 存档目录名取自
该文件名, 因此为 Balatro.

用法:
    python3 scripts/package_macos.py
    python3 scripts/package_macos.py --icon 自定义图标.png
    python3 scripts/package_macos.py --no-icon
"""
import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import archive, gamezip, icns, info_plist, layout, log, runtime, version as versionlib

log.set_prefix("macos")

# 官方 love.app 里与图标相关的资源, 换成我们自己的图标后需要清掉,
# 否则 Assets.car 里的命名图标会盖过新的 .icns.
LOVE_ICON_ASSETS = ("Assets.car", "OS X AppIcon.icns", "GameIcon.icns")


def parse_args():
    parser = argparse.ArgumentParser(description="打包 macOS 应用")
    parser.add_argument("--icon", default=layout.icon_path(),
                        help="图标源图, 默认使用 assets/icon.png")
    parser.add_argument("--no-icon", action="store_true",
                        help="不替换图标, 沿用 LÖVE 自带图标")
    parser.add_argument("--bundle-id", default=layout.BUNDLE_ID,
                        help="应用标识, 默认 %s" % layout.BUNDLE_ID)
    parser.add_argument("--keep-work", action="store_true",
                        help="保留临时工作目录便于排查")
    return parser.parse_args()


def main():
    args = parse_args()

    if sys.platform != "darwin":
        log.die("macOS 应用包只能在 macOS 上生成 (需要 codesign 与 xattr)")

    version = versionlib.build_version()
    log.info("游戏版本: %s" % version)

    runtime_zip = runtime.require("macos")
    icon_src = None if args.no_icon else args.icon
    if icon_src and not os.path.isfile(icon_src):
        log.die("找不到图标源图: %s" % icon_src)

    out_dir = layout.ensure_dir(layout.MACOS_DIST)
    app_dir = os.path.join(out_dir, "%s.app" % layout.APP_NAME)

    work_dir = tempfile.mkdtemp(prefix=".macos-", dir=out_dir)
    try:
        log.info("展开运行时")
        count = archive.extract_zip(runtime_zip, work_dir)
        src_app = os.path.join(work_dir, "love.app")
        if not os.path.isdir(src_app):
            log.die("运行时里没有 love.app, 压缩包结构可能已变化")

        log.info("组装应用包 (%d 个条目)" % count)
        if os.path.exists(app_dir):
            shutil.rmtree(app_dir)
        shutil.copytree(src_app, app_dir, symlinks=True)

        contents = os.path.join(app_dir, "Contents")
        resources = os.path.join(contents, "Resources")

        love_name = "%s.love" % layout.APP_NAME
        gamezip.build(layout.GAME_DIR, os.path.join(resources, love_name))

        values = {
            "CFBundleName": layout.APP_NAME,
            "CFBundleDisplayName": layout.APP_NAME,
            "CFBundleIdentifier": args.bundle_id,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "CFBundleGetInfoString": "%s %s (LÖVE 11.5)" % (layout.APP_NAME, version),
        }
        remove = []
        if icon_src:
            icns_path = os.path.join(resources, "AppIcon.icns")
            sizes = icns.build(icon_src, icns_path)
            log.info("已生成 %s (尺寸: %s)"
                     % (os.path.basename(icns_path),
                        ", ".join(str(s) for s in sorted(set(sizes)))))
            values["CFBundleIconFile"] = "AppIcon"
            # 让新的 .icns 生效, 需要同时去掉 CFBundleIconName 与旧的图标资源.
            remove.append("CFBundleIconName")
            for name in LOVE_ICON_ASSETS:
                target = os.path.join(resources, name)
                if os.path.exists(target):
                    os.remove(target)
        info_plist.update(os.path.join(contents, "Info.plist"), values, remove)

        log.info("清除隔离属性")
        log.run(["xattr", "-cr", app_dir], quiet=True)

        log.info("ad-hoc 签名")
        # --deep 会连带签内部框架, 否则签名校验不通过.
        log.run(["codesign", "--force", "--deep", "--sign", "-", app_dir], quiet=True)
        log.run(["codesign", "--verify", "--deep", "--strict", app_dir], quiet=True)
        log.info("签名校验通过")
    finally:
        if args.keep_work:
            log.info("保留工作目录: %s" % work_dir)
        else:
            shutil.rmtree(work_dir, ignore_errors=True)

    total = archive.dir_size(app_dir)
    log.info("完成: %s (%s)" % (app_dir, archive.human_size(total)))
    log.info("运行: open \"%s\"" % app_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
