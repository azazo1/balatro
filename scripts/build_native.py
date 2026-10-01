"""编译与测试 native/ 下的原生库.

原生库只有一个 bbnet (Rust): 网络 (HTTP/TLS/SSE) 与录像用的颜色转换. 因此这里不做 "哪个库" 的分支,
只按目标平台出产物:

    python3 scripts/build_native.py test                    # 跑单元测试与集成测试
    python3 scripts/build_native.py build macos             # 输出到 mod 目录
    python3 scripts/build_native.py build windows           # 输出到 dist/native/windows/
    python3 scripts/build_native.py build android arm64-v8a # 输出到 dist/native/android/<abi>/

放在 python 而不是 justfile 里的 shell: 这份脚本要在 Windows, macOS 和 Linux 上都能用, 而 NDK 查找,
目标三元组映射, 产物复制这些逻辑在 shell 里要为每个平台写一份分支.
"""
import argparse
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import layout, log  # noqa: E402

MANIFEST = os.path.join(layout.ROOT_DIR, "native", "bbnet", "Cargo.toml")

# 库文件名按平台.
LIB_NAMES = {
    "macos": "libbbnet.dylib",
    "windows": "bbnet.dll",
    "android": "libbbnet.so",
    "linux": "libbbnet.so",
}

# Rust target 三元组.
TARGETS = {
    "macos": "aarch64-apple-darwin",
    "windows": "x86_64-pc-windows-msvc",
    "linux": "x86_64-unknown-linux-gnu",
    "android-arm64-v8a": "aarch64-linux-android",
    "android-armeabi-v7a": "armv7-linux-androideabi",
    "android-x86_64": "x86_64-linux-android",
    "android-x86": "i686-linux-android",
}

# 产物落到哪里: macos 直接进 mod 的原生目录 (随 mod 树进各平台安装包);
# windows 与 android 放 dist/native/, 由打包脚本按需放进安装包.
def output_path(platform, abi=None):
    name = LIB_NAMES[platform]
    if platform == "macos":
        return os.path.join(layout.ROOT_DIR, "mods", "balatrobot", "native", "macos", name)
    if platform == "windows":
        return os.path.join(layout.DIST_DIR, "native", "windows", name)
    if platform == "android":
        return os.path.join(layout.DIST_DIR, "native", "android", abi, name)
    return os.path.join(layout.DIST_DIR, "native", platform, name)


def target_dir(target):
    return os.path.join(layout.ROOT_DIR, "native", "bbnet", "target", target, "release")


def find_ndk():
    """按 ANDROID_NDK_HOME, ANDROID_HOME/ndk/<最新>, ~/Library/Android/sdk/ndk/<最新> 的顺序找 NDK.

    cargo-ndk 认 ANDROID_NDK_HOME, 所以这里找到之后要写回环境变量.
    """
    explicit = os.environ.get("ANDROID_NDK_HOME")
    if explicit:
        if os.path.isdir(explicit):
            return explicit
        log.die("ANDROID_NDK_HOME 指向的目录不存在: %s" % explicit)

    def latest_under(parent):
        if not os.path.isdir(parent):
            return None
        candidates = [d for d in os.listdir(parent) if os.path.isdir(os.path.join(parent, d))]

        def key(name):
            # 按版本号的各段数值排序, 而不是字符串排序 (否则 r9 会排在 r28 之后).
            parts = []
            for chunk in name.split("."):
                digits = "".join(c for c in chunk if c.isdigit())
                parts.append(int(digits) if digits else 0)
            return parts

        if not candidates:
            return None
        return os.path.join(parent, sorted(candidates, key=key)[-1])

    for parent in (
        os.path.join(os.environ.get("ANDROID_HOME", ""), "ndk") if os.environ.get("ANDROID_HOME") else None,
        os.path.join(os.path.expanduser("~"), "Library", "Android", "sdk", "ndk"),
        os.path.join(os.path.expanduser("~"), "Android", "Sdk", "ndk"),
    ):
        if not parent:
            continue
        found = latest_under(parent)
        if found:
            return found
    log.die("找不到 Android NDK. 请设置 ANDROID_NDK_HOME, 或把 NDK 装到 ANDROID_HOME/ndk/ 下")


def build_macos():
    target = TARGETS["macos"]
    log.run(["cargo", "build", "--manifest-path", MANIFEST, "--release", "--target", target])
    out = output_path("macos")
    layout.ensure_dir(os.path.dirname(out))
    shutil.copyfile(os.path.join(target_dir(target), LIB_NAMES["macos"]), out)
    log.info("已生成 %s" % os.path.relpath(out, layout.ROOT_DIR))


def build_windows():
    # 需要 MSVC 链接器: 在 macOS/Linux 上交叉编译通常会因缺少 link.exe 失败, 请在 Windows 或 CI 上运行.
    target = TARGETS["windows"]
    log.run(["cargo", "build", "--manifest-path", MANIFEST, "--release", "--target", target])
    out = output_path("windows")
    layout.ensure_dir(os.path.dirname(out))
    shutil.copyfile(os.path.join(target_dir(target), LIB_NAMES["windows"]), out)
    log.info("已生成 %s" % os.path.relpath(out, layout.ROOT_DIR))


def build_linux():
    target = TARGETS["linux"]
    log.run(["cargo", "build", "--manifest-path", MANIFEST, "--release", "--target", target])
    out = output_path("linux")
    layout.ensure_dir(os.path.dirname(out))
    shutil.copyfile(os.path.join(target_dir(target), LIB_NAMES["linux"]), out)
    log.info("已生成 %s" % os.path.relpath(out, layout.ROOT_DIR))


def build_android(abis):
    ndk = find_ndk()
    log.info("使用 NDK: %s" % ndk)
    os.environ["ANDROID_NDK_HOME"] = ndk
    if not log.have("cargo"):
        log.die("找不到 cargo")
    # cargo-ndk 负责 abi -> target 的映射与链接参数 (NDK r27 起默认 16KB 页对齐, 不需要额外参数).
    out_root = os.path.join(layout.DIST_DIR, "native", "android")
    cmd = ["cargo", "ndk"]
    for abi in abis:
        if "android-%s" % abi not in TARGETS:
            log.die("未知 ABI: %s (可用: %s)" % (abi, ", ".join(sorted(
                k.split("android-", 1)[1] for k in TARGETS if k.startswith("android-")))))
        cmd += ["-t", abi]
    cmd += ["-o", out_root, "build", "--release"]
    # cargo-ndk 要在 crate 目录里跑 (它读当前目录的 Cargo.toml).
    log.run(cmd, cwd=os.path.join(layout.ROOT_DIR, "native", "bbnet"))
    for abi in abis:
        out = output_path("android", abi)
        if os.path.isfile(out):
            log.info("已生成 %s" % os.path.relpath(out, layout.ROOT_DIR))
        else:
            log.die("cargo-ndk 没有产出 %s" % os.path.relpath(out, layout.ROOT_DIR))


def run_tests():
    """单元测试与集成测试. 颜色转换的用例也在其中 (src/yuv.rs)."""
    log.run(["cargo", "test", "--manifest-path", MANIFEST])


def main():
    parser = argparse.ArgumentParser(description="编译与测试 native/ 下的原生库")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("test", help="跑单元测试与集成测试")
    build = sub.add_parser("build", help="编译原生库")
    build.add_argument("platform", choices=["macos", "windows", "linux", "android"])
    build.add_argument("abis", nargs="*", default=[], help="android 的 ABI, 默认 arm64-v8a")
    args = parser.parse_args()

    log.set_prefix("native")
    if args.command == "test":
        run_tests()
        return
    if args.platform == "macos":
        build_macos()
    elif args.platform == "windows":
        build_windows()
    elif args.platform == "linux":
        build_linux()
    else:
        build_android(args.abis or ["arm64-v8a"])


if __name__ == "__main__":
    main()
