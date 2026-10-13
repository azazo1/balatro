#!/usr/bin/env python3
"""构建 engine 的两个命令行二进制, 并归档成发布产物.

engine 是独立的 Rust crate (依赖为空, 不需要图形环境), 产物是两个可执行文件:
`play` 让 agent 在引擎里逐步对局与查规则, `replay_check` 离线核对游戏回放.
两者的用法见 engine/README.md.

macOS 默认只编当前架构, 加 `--universal` 会同时编 arm64 与 x86_64, 再用 lipo 合成通用
二进制 —— 与仓库其他 macOS 产物一致. 归档前会运行 `--version` 做一次 smoke, 断言二进制
报出的版本就是本次注入的版本; 已经编好的归档还会被回读一次, 少文件或丢可执行位都算失败.

用法:
    python3 scripts/package_engine.py
    python3 scripts/package_engine.py --universal
    python3 scripts/package_engine.py --arch x86_64
"""
import argparse
import os
import platform as hostlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import archive, layout, log, version as versionlib

log.set_prefix("engine")

MANIFEST = os.path.join(layout.ROOT_DIR, "engine", "Cargo.toml")
# 构建目录固定下来, 让缓存与产物查找不依赖调用者的环境变量.
TARGET_DIR = os.path.join(layout.ROOT_DIR, "engine", "target")
# 一起发布的命令行二进制, 名字与 Cargo.toml 里的 bin target 一致.
BINARIES = ("play", "replay_check")
# 各平台可用的架构, 值是 rust 的 target triple.
TRIPLES = {
    "macos": {"aarch64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"},
    "linux": {"aarch64": "aarch64-unknown-linux-gnu", "x86_64": "x86_64-unknown-linux-gnu"},
    "windows": {"aarch64": "aarch64-pc-windows-msvc", "x86_64": "x86_64-pc-windows-msvc"},
}
# linux 与 macOS 用 tar.gz, Windows 用 zip, 与仓库其他产物一致.
EXTENSIONS = {"macos": "tar.gz", "linux": "tar.gz", "windows": "zip"}
# macOS 通用二进制的架构段, 与仓库现有的 macos 产物命名保持一致.
UNIVERSAL = "universal"


def host_platform():
    """当前平台, 取值与 TRIPLES 的键一致."""
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform.startswith("linux"):
        return "linux"
    log.die("不支持的平台: %s" % sys.platform)


def host_arch():
    """当前架构, 取值与 TRIPLES 里的架构段一致."""
    machine = hostlib.machine().lower()
    if machine in ("arm64", "aarch64"):
        return "aarch64"
    if machine in ("x86_64", "amd64"):
        return "x86_64"
    log.die("不支持的架构: %s" % machine)


def binary_name(binary, platform):
    """二进制文件名, Windows 上加 .exe."""
    return "%s.exe" % binary if platform == "windows" else binary


def bundle_name(version, platform, arch):
    """产物目录名, 也是归档名的前缀."""
    return "balatro-engine-%s-%s-%s" % (version, platform, arch)


def archive_name(version, platform, arch):
    """归档文件名, 与 bundle_name 同名不同扩展名."""
    return "%s.%s" % (bundle_name(version, platform, arch), EXTENSIONS[platform])


def built_binary(triple, binary, platform):
    """某个 target 编出来的二进制路径."""
    return os.path.join(TARGET_DIR, triple, "release", binary_name(binary, platform))


def parse_args():
    parser = argparse.ArgumentParser(description="构建并归档 engine 命令行二进制")
    parser.add_argument("--platform", choices=sorted(TRIPLES), default=host_platform(),
                        help="目标平台, 默认当前平台")
    parser.add_argument("--arch", choices=["aarch64", "x86_64"], default=None,
                        help="目标架构, 默认当前架构")
    parser.add_argument("--universal", action="store_true",
                        help="macOS 通用二进制 (arm64 + x86_64 合成)")
    parser.add_argument("--keep-work", action="store_true", help="保留组装的中间目录")
    return parser.parse_args()


def ensure_triples(triples):
    """缺少 rust 目标时给一句能照做的提示, 而不是把 cargo 的报错原样丢出来."""
    if not log.have("rustup"):
        return
    installed = (log.run(["rustup", "target", "list", "--installed"],
                         check=False, capture=True, quiet=True) or "").split()
    missing = [triple for triple in triples if triple not in installed]
    if missing:
        log.die("缺少 rust 目标: %s\n先执行: rustup target add %s"
                % (", ".join(missing), " ".join(missing)))


def build(triples, version):
    """按 target 逐个构建. 版本通过 PROJECT_BUILD_VERSION 注入二进制, 见 lib.rs 的 VERSION."""
    env = dict(os.environ, PROJECT_BUILD_VERSION=version, CARGO_TARGET_DIR=TARGET_DIR)
    for triple in triples:
        command = ["cargo", "build", "--release", "--locked",
                   "--manifest-path", MANIFEST, "--target", triple]
        for binary in BINARIES:
            command += ["--bin", binary]
        log.run(command, env=env)


def assemble(bundle_dir, triples, platform):
    """把各 target 编出来的二进制收进产物目录, macOS 的通用二进制在这里合成."""
    files = {}
    for binary in BINARIES:
        name = binary_name(binary, platform)
        sources = [built_binary(triple, binary, platform) for triple in triples]
        for source in sources:
            if not os.path.isfile(source):
                log.die("找不到编译产物: %s" % source)
        target = os.path.join(bundle_dir, name)
        if len(sources) == 1:
            shutil.copy2(sources[0], target)
        else:
            log.run(["lipo", "-create", "-output", target] + sources)
        # Windows 靠扩展名决定可执行, 其余平台显式补上可执行位.
        if platform != "windows":
            os.chmod(target, 0o755)
        files[name] = target
    return files


def runnable_here(platform, arch):
    """产物能否在本机运行. universal 含本机架构, 因此在本平台上可以跑."""
    if platform != host_platform():
        return False
    return arch in (host_arch(), UNIVERSAL)


def smoke(files, version, runnable):
    """跑一次 --version, 确认二进制报出的版本与注入的一致."""
    if not runnable:
        log.warn("交叉编译的产物不能在本机运行, 跳过版本 smoke: %s" % ", ".join(sorted(files)))
        return
    for name, path in sorted(files.items()):
        result = subprocess.run([path, "--version"], capture_output=True, text=True)
        output = (result.stdout or "").strip()
        if result.returncode != 0 or version not in output:
            log.die("产物 %s 报出的版本不对 (退出码 %d): %s"
                    % (name, result.returncode, output or (result.stderr or "").strip()))
        log.info("版本 smoke: %s" % output)


def write_archive(bundle_dir, bundle, platform, out_path):
    """归档产物目录. 条目时间固定, 同一份输入打出来的归档应当逐字节一致."""
    names = sorted(os.listdir(bundle_dir))
    if EXTENSIONS[platform] == "zip":
        with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            for name in names:
                full = os.path.join(bundle_dir, name)
                info = zipfile.ZipInfo("%s/%s" % (bundle, name), date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (os.stat(full).st_mode & 0o777) << 16
                with open(full, "rb") as fh:
                    zf.writestr(info, fh.read())
        return
    with tarfile.open(out_path, "w:gz") as tf:
        for name in names:
            full = os.path.join(bundle_dir, name)
            info = tf.gettarinfo(full, arcname="%s/%s" % (bundle, name))
            info.mode = os.stat(full).st_mode & 0o777
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            with open(full, "rb") as fh:
                tf.addfile(info, fh)


def verify_archive(out_path, bundle, platform):
    """回读归档: 少一个文件或丢了可执行位都在这里拦下, 而不是等使用者解压才发现."""
    expected = {"%s/%s" % (bundle, binary_name(binary, platform)) for binary in BINARIES}
    if EXTENSIONS[platform] == "zip":
        with zipfile.ZipFile(out_path) as zf:
            found = {info.filename: info.external_attr >> 16 for info in zf.infolist()}
    else:
        with tarfile.open(out_path) as tf:
            found = {info.name: info.mode for info in tf.getmembers()}
    if set(found) != expected:
        log.die("归档内容不对: %s, 期望 %s" % (sorted(found), sorted(expected)))
    if platform != "windows":
        for name, mode in sorted(found.items()):
            if not mode & 0o111:
                log.die("归档里的 %s 丢了可执行位: mode %o" % (name, mode))


def remove_old(path):
    if os.path.exists(path):
        try:
            os.remove(path)
        except OSError as exc:
            log.die("删除上次的产物失败: %s (%s)" % (path, exc))


def main():
    args = parse_args()
    platform = args.platform
    if args.universal and platform != "macos":
        log.die("通用二进制只在 macOS 上合成: %s" % platform)
    if platform == "macos" and host_platform() != "macos":
        log.die("macOS 产物只能在 macOS 上构建 (需要 Apple SDK)")
    arch = UNIVERSAL if args.universal else (args.arch or host_arch())
    triples = list(TRIPLES[platform].values()) if arch == UNIVERSAL else [TRIPLES[platform][arch]]

    version = versionlib.build_version()
    log.info("engine 版本: %s, 平台: %s, 架构: %s" % (version, platform, arch))

    ensure_triples(triples)
    build(triples, version)

    bundle = bundle_name(version, platform, arch)
    out_dir = layout.ensure_dir(layout.ENGINE_DIST)
    out_path = os.path.join(out_dir, archive_name(version, platform, arch))
    remove_old(out_path)

    staging = tempfile.mkdtemp(prefix=".engine-", dir=out_dir)
    bundle_dir = os.path.join(staging, bundle)
    try:
        os.makedirs(bundle_dir)
        files = assemble(bundle_dir, triples, platform)
        smoke(files, version, runnable_here(platform, arch))
        log.info("归档 %s" % os.path.basename(out_path))
        write_archive(bundle_dir, bundle, platform, out_path)
        verify_archive(out_path, bundle, platform)
    finally:
        if args.keep_work:
            log.info("保留中间目录: %s" % staging)
        else:
            shutil.rmtree(staging, ignore_errors=True)

    log.info("完成: %s (%s)" % (out_path, archive.human_size(os.path.getsize(out_path))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
