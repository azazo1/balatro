#!/usr/bin/env python3
"""把 game/ 装进官方 LÖVE 11.5 Windows 运行时, 产出免安装的融合 exe.

Windows 版的做法是把 .love 追加到 love.exe 末尾: LÖVE 内部用 PhysicsFS 从自身文件尾部
读取游戏, 因此出来的是单文件可执行程序, 不需要额外的游戏文件, 但需要同目录的 DLL.

由于这个仓库里的运行时是重新分发的官方 LÖVE, 不含 Steam 原生模块, 游戏会以无 Steam
模式运行: 成就与进度由本地存档记录, 与 macOS 版行为一致.

原版包可以在任何平台打. 带 mod 的包要编译 bbnet.dll, 只能在 Windows 上打; 在别的系统上加 --no-native.

用法:
    python3 scripts/package_windows.py
    python3 scripts/package_windows.py --console   # 同时产出带控制台的版本, 便于看日志
    python3 scripts/package_windows.py --mods      # 带 mod 的版本, mod 取自 mods/
"""
import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import archive, gamezip, layout, log, modding, runtime, version as versionlib, win_icon
import build_native  # noqa: E402  打包带 mod 的版本时顺带编译 bbnet

log.set_prefix("windows")

# 融合 exe 之外还需要随目录分发的文件. love.exe 与 lovec.exe 由本脚本生成, 不直接复制.
SUPPORT_FILES = ("love.dll", "lua51.dll", "mpg123.dll", "msvcp120.dll", "msvcr120.dll",
                 "OpenAL32.dll", "SDL2.dll")
# 便于使用者了解来源与授权, 一并带上.
EXTRA_FILES = ("license.txt", "changes.txt", "readme.txt")


def parse_args():
    parser = argparse.ArgumentParser(description="打包 Windows 免安装版")
    parser.add_argument("--console", action="store_true",
                        help="额外产出带控制台窗口的 exe, 便于查看 print 输出")
    parser.add_argument("--keep-work", action="store_true", help="保留临时目录")
    modding.add_arguments(parser)
    return parser.parse_args()


def main():
    args = parse_args()
    flavor = modding.flavor(args)
    version = versionlib.build_version()
    log.info("游戏版本: %s, 变体: %s" % (version, flavor.key))

    runtime_zip = runtime.require("windows")

    out_dir = layout.ensure_dir(layout.WINDOWS_DIST)
    # exe 名固定为 Balatro.exe, 变体只体现在目录名上.
    bundle_name = "%s-%s-win64" % (flavor.file_stem, version)
    bundle_dir = os.path.join(out_dir, bundle_name)
    zip_out = os.path.join(out_dir, "%s.zip" % bundle_name)

    work_dir = tempfile.mkdtemp(prefix=".windows-", dir=out_dir)
    try:
        log.info("展开运行时")
        count = archive.extract_zip(runtime_zip, work_dir)
        # 压缩包里有一层 love-11.5-win64 目录.
        roots = [os.path.join(work_dir, name) for name in os.listdir(work_dir)]
        src_dir = next((p for p in roots if os.path.isdir(p)), work_dir)
        log.info("解出 %d 个条目" % count)

        if os.path.exists(bundle_dir):
            shutil.rmtree(bundle_dir)
        os.makedirs(bundle_dir)

        love_payload = os.path.join(work_dir, "%s.love" % layout.APP_NAME)
        native = build_native.desktop_native_files("windows", args.no_native) if args.mods else None
        gamezip.build(modding.game_source(args, work_dir, version, native), love_payload)

        exe_name = "%s.exe" % layout.APP_NAME

        def fuse(base_name, target_name):
            base = os.path.join(src_dir, base_name)
            if not os.path.isfile(base):
                log.die("运行时里找不到 %s" % base_name)
            # 官方 love.exe 自带的图标是 LÖVE 的, 换成游戏自己的图标后再融合 (见 lib/win_icon.py).
            sizes = win_icon.replace(base, layout.icon_path())
            log.info("%s 图标已替换: %s" % (base_name, ", ".join(str(s) for s in sizes)))
            target = os.path.join(bundle_dir, target_name)
            size = archive.fuse_executable(base, love_payload, target)
            log.info("已融合 %s (%s)" % (target_name, archive.human_size(size)))

        fuse("love.exe", exe_name)
        if args.console:
            fuse("lovec.exe", "%s-console.exe" % layout.APP_NAME)

        for name in SUPPORT_FILES:
            src = os.path.join(src_dir, name)
            if not os.path.isfile(src):
                log.die("运行时里缺少依赖 %s" % name)
            shutil.copy2(src, os.path.join(bundle_dir, name))
        for name in EXTRA_FILES:
            src = os.path.join(src_dir, name)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(bundle_dir, name))

        log.info("打包 %s" % os.path.basename(zip_out))
        archive.zip_dir(bundle_dir, zip_out)
    finally:
        if args.keep_work:
            log.info("保留工作目录: %s" % work_dir)
        else:
            shutil.rmtree(work_dir, ignore_errors=True)

    log.info("完成: %s (%s)" % (bundle_dir,
                                archive.human_size(os.path.getsize(zip_out))))
    log.info("压缩包: %s" % zip_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
