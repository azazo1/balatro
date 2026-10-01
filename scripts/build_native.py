"""编译与测试原生库 native/bbnet (网络与录像用的颜色转换都在这一个库里).

    python3 scripts/build_native.py test                    # 跑单元测试与集成测试
    python3 scripts/build_native.py build macos             # 输出到 mod 目录
    python3 scripts/build_native.py build windows           # 输出到 dist/native/windows/
    python3 scripts/build_native.py build android [abi...]  # 输出到 dist/native/android/<abi>/

用 python 而不是 justfile 里的 shell, 是为了在 Windows 上也能跑.
"""
import argparse
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import layout, log  # noqa: E402

CRATE_DIR = os.path.join(layout.ROOT_DIR, "native", "bbnet")
MANIFEST = os.path.join(CRATE_DIR, "Cargo.toml")

# 桌面平台: (Rust target, 库文件名, 产物位置).
# macOS 直接进 mod 的原生目录, 随 mod 树进安装包; Windows 放 dist/, 打包时放在 exe 旁边.
DESKTOP = {
    "macos": ("aarch64-apple-darwin", "libbbnet.dylib",
              os.path.join(layout.MODS_DIR, "balatrobot", "native", "macos")),
    "windows": ("x86_64-pc-windows-msvc", "bbnet.dll",
                os.path.join(layout.DIST_DIR, "native", "windows")),
}
ANDROID_OUT = os.path.join(layout.DIST_DIR, "native", "android")
# Android ABI -> Rust target. cargo-ndk 自己也有这张表, 这里只用来检查 target 有没有装.
ANDROID_TARGETS = {
    "arm64-v8a": "aarch64-linux-android",
    "armeabi-v7a": "armv7-linux-androideabi",
    "x86_64": "x86_64-linux-android",
    "x86": "i686-linux-android",
}


def android_lib(abi):
    """just native build android 产出的 libbbnet.so 路径."""
    return os.path.join(ANDROID_OUT, abi, "libbbnet.so")


def _probe(cmd):
    """跑一个探测命令, 返回 (是否成功, 输出). 命令不存在时视为失败."""
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except FileNotFoundError:
        return False, ""
    return result.returncode == 0, result.stdout or ""


def android_missing(abi):
    """编译这个 ABI 还缺什么, 返回说明; 都齐了返回 None. 不退出进程, 供打包时判断."""
    target = ANDROID_TARGETS.get(abi)
    if not target:
        return "不认识的 ABI %s" % abi
    if not shutil.which("cargo"):
        return "找不到 cargo"
    if not _probe(["cargo", "ndk", "--version"])[0]:
        return "找不到 cargo-ndk (cargo install cargo-ndk)"
    ok, installed = _probe(["rustup", "target", "list", "--installed"])
    # 没有 rustup (例如发行版自带的 rust) 时不判断, 交给编译报错.
    if ok and target not in installed.split():
        return "没装 rust target %s (rustup target add %s)" % (target, target)
    return None


def find_ndk():
    """按 ANDROID_NDK_HOME, <SDK>/ndk/<最新版本> 的顺序找 NDK. SDK 依次取 ANDROID_HOME 与各平台默认位置."""
    explicit = os.environ.get("ANDROID_NDK_HOME")
    if explicit:
        if os.path.isdir(explicit):
            return explicit
        log.die("ANDROID_NDK_HOME 指向的目录不存在: %s" % explicit)

    def version_key(name):
        # 按各段数值比较, 字符串比较会把 9.x 排在 27.x 之后.
        return [int("".join(c for c in part if c.isdigit()) or 0) for part in name.split(".")]

    home = os.path.expanduser("~")
    sdks = [os.environ.get("ANDROID_HOME"),
            os.path.join(home, "Library", "Android", "sdk"),
            os.path.join(home, "Android", "Sdk")]
    for sdk in filter(None, sdks):
        parent = os.path.join(sdk, "ndk")
        if os.path.isdir(parent):
            versions = [d for d in os.listdir(parent) if os.path.isdir(os.path.join(parent, d))]
            if versions:
                return os.path.join(parent, max(versions, key=version_key))
    log.die("找不到 Android NDK. 请设置 ANDROID_NDK_HOME, 或把 NDK 装到 ANDROID_HOME/ndk/ 下")


def build_desktop(platform):
    # Windows 需要 MSVC 链接器, 在 macOS 上交叉编译会因缺少 link.exe 失败, 请在 Windows 或 CI 上运行.
    target, name, out_dir = DESKTOP[platform]
    log.run(["cargo", "build", "--manifest-path", MANIFEST, "--release", "--target", target])
    out = os.path.join(layout.ensure_dir(out_dir), name)
    shutil.copyfile(os.path.join(CRATE_DIR, "target", target, "release", name), out)
    log.info("已生成 %s" % os.path.relpath(out, layout.ROOT_DIR))


def build_android(abis):
    ndk = find_ndk()
    log.info("使用 NDK: %s" % ndk)
    # cargo-ndk 从环境变量读 NDK, 也负责 ABI 到 target 的映射与链接参数 (NDK r27 起默认 16KB 页对齐).
    os.environ["ANDROID_NDK_HOME"] = ndk
    cmd = ["cargo", "ndk"]
    for abi in abis:
        cmd += ["-t", abi]
    cmd += ["-o", ANDROID_OUT, "build", "--release"]
    # cargo-ndk 读当前目录的 Cargo.toml, 不认 --manifest-path.
    log.run(cmd, cwd=CRATE_DIR)
    for abi in abis:
        log.info("已生成 %s" % os.path.relpath(android_lib(abi), layout.ROOT_DIR))


def main():
    parser = argparse.ArgumentParser(description="编译与测试原生库 native/bbnet")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("test", help="跑单元测试与集成测试")
    build = sub.add_parser("build", help="编译原生库")
    build.add_argument("platform", choices=sorted(DESKTOP) + ["android"])
    build.add_argument("abis", nargs="*", help="android 的 ABI, 默认 arm64-v8a")
    args = parser.parse_args()

    log.set_prefix("native")
    if args.command == "test":
        log.run(["cargo", "test", "--manifest-path", MANIFEST])
    elif args.platform == "android":
        build_android(args.abis or ["arm64-v8a"])
    else:
        build_desktop(args.platform)


if __name__ == "__main__":
    main()
