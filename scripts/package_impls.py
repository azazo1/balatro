#!/usr/bin/env python3
"""统一归档 CLI, Python wheel, HTTP 服务与 Web/WASM, 每个平台一个包."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform as hostlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import archive, layout, log, version as versionlib
import web

MANIFEST = os.path.join(layout.ROOT_DIR, "impls", "engine", "Cargo.toml")
WEB_MANIFEST = os.path.join(layout.ROOT_DIR, "impls", "web", "Cargo.toml")
TARGET_DIR = os.path.join(layout.ROOT_DIR, "impls", "engine", "target")
BINARIES = ("balatro", "balatro-web-server")
TRIPLES = {
    "macos": {"aarch64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"},
    "linux": {"aarch64": "aarch64-unknown-linux-gnu", "x86_64": "x86_64-unknown-linux-gnu"},
    "windows": {"aarch64": "aarch64-pc-windows-msvc", "x86_64": "x86_64-pc-windows-msvc"},
}
EXTENSIONS = {"macos": "tar.gz", "linux": "tar.gz", "windows": "zip"}
UNIVERSAL = "universal"


def host_platform():
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform.startswith("linux"):
        return "linux"
    log.die("不支持的平台: " + sys.platform)


def host_arch():
    machine = hostlib.machine().lower()
    if machine in ("arm64", "aarch64"):
        return "aarch64"
    if machine in ("x86_64", "amd64"):
        return "x86_64"
    log.die("不支持的架构: " + machine)


def binary_name(binary, platform):
    return binary + ".exe" if platform == "windows" else binary


def bundle_name(version, platform, arch):
    return "balatro-engine-%s-%s-%s" % (version, platform, arch)


def archive_name(version, platform, arch):
    return "%s.%s" % (bundle_name(version, platform, arch), EXTENSIONS[platform])


def built_binary(triple, binary, platform):
    return os.path.join(TARGET_DIR, triple, "release", binary_name(binary, platform))


def parse_args():
    parser = argparse.ArgumentParser(description="构建 impls 综合包, 不单独发布 wheel 或 Web")
    parser.add_argument("--platform", choices=sorted(TRIPLES), default=host_platform())
    parser.add_argument("--arch", choices=["aarch64", "x86_64"])
    parser.add_argument("--universal", action="store_true", help="macOS 通用 CLI 与 universal2 wheel")
    parser.add_argument("--keep-work", action="store_true", help="保留 .tmp 下的组装目录")
    return parser.parse_args()


def ensure_triples(triples):
    installed = subprocess.run(["rustup", "target", "list", "--installed"], capture_output=True, text=True, check=True).stdout.split()
    missing = [triple for triple in triples if triple not in installed]
    if missing:
        log.die("缺少 Rust 编译目标: %s, 请先安装这些目标" % ", ".join(missing))


def build(triples, version):
    env = dict(os.environ, PROJECT_BUILD_VERSION=version, CARGO_TARGET_DIR=TARGET_DIR)
    for triple in triples:
        log.run(["cargo", "build", "--release", "--locked", "--manifest-path", MANIFEST,
                 "--target", triple, "-p", "balatro-engine-cli", "--bin", "balatro"], env=env)
        log.run(["cargo", "build", "--release", "--locked", "--manifest-path", WEB_MANIFEST,
                 "--target", triple, "-p", "balatro-web-server"], env=env)


def assemble(bundle_dir, triples, platform):
    directory = os.path.join(bundle_dir, "bin")
    os.makedirs(directory, exist_ok=True)
    files = {}
    for binary in BINARIES:
        name = binary_name(binary, platform)
        sources = [built_binary(t, binary, platform) for t in triples]
        if any(not os.path.isfile(s) for s in sources):
            log.die("缺少二进制: " + binary)
        target = os.path.join(directory, name)
        if len(sources) == 1:
            shutil.copy2(sources[0], target)
        else:
            log.run(["lipo", "-create", "-output", target] + sources)
        if platform != "windows":
            os.chmod(target, 0o755)
        files[name] = target
    return files


def build_python(bundle_dir, platform, arch, version):
    destination = os.path.join(bundle_dir, "python")
    target = "universal2-apple-darwin" if arch == UNIVERSAL else TRIPLES[platform][arch]
    command = ["maturin", "build", "--release", "--locked", "--manifest-path",
               os.path.join(layout.ROOT_DIR, "impls", "py", "Cargo.toml"),
               "--target", target, "--out", destination, "--interpreter", sys.executable]
    if platform == "linux":
        # 与 GNU CLI 一样跟随构建主机的 glibc, 不冒充 manylinux 可移植包.
        command += ["--compatibility", "linux"]
    log.run(command, env=dict(os.environ, PROJECT_BUILD_VERSION=version))
    wheels = sorted(Path(destination).glob("*.whl"))
    if len(wheels) != 1:
        log.die("综合包必须且只能包含一份对应平台的 Python wheel")
    return wheels[0]


def runnable_here(platform, arch):
    return platform == host_platform() and arch in (host_arch(), UNIVERSAL)


def smoke(files, version, runnable):
    if not runnable:
        log.warn("交叉架构不能执行版本 smoke")
        return
    for name, path in sorted(files.items()):
        result = subprocess.run([path, "--version"], capture_output=True, text=True)
        output = (result.stdout or "").strip()
        if result.returncode != 0 or version not in output.split():
            log.die("%s 的版本 smoke 失败: %s" % (name, output or result.stderr))
        log.info("版本 smoke: " + output)


def smoke_python(wheel, version, runnable):
    if not runnable:
        return
    code = "import balatro_engine as be; assert be.build_version == %r; g=be.Game('ALEEB','RED',1); g.apply('{\"method\":\"select\"}'); assert len(g.hand()) > 0; assert g.copy().hand() == g.hand()" % version
    log.run(["uv", "run", "--no-project", "--with", str(wheel), "python", "-c", code])


def bundle_files(directory):
    return sorted(p for p in Path(directory).rglob("*") if p.is_file())


def write_manifest(directory, version, platform, arch):
    files = {}
    for path in bundle_files(directory):
        if path.is_symlink():
            log.die("impls 综合包不接受符号链接: " + str(path))
        relative = path.relative_to(directory).as_posix()
        if relative != "manifest.json":
            files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    document = {"format_version": 1, "version": version, "platform": platform, "arch": arch, "files": files}
    (Path(directory) / "manifest.json").write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_archive(bundle_dir, bundle, platform, out_path):
    paths = bundle_files(bundle_dir)
    if EXTENSIONS[platform] == "zip":
        with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            for path in paths:
                name = bundle + "/" + path.relative_to(bundle_dir).as_posix()
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (path.stat().st_mode & 0o777) << 16
                zf.writestr(info, path.read_bytes())
        return
    with open(out_path, "wb") as raw, gzip.GzipFile(fileobj=raw, filename="", mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as tf:
            for path in paths:
                info = tf.gettarinfo(str(path), arcname=bundle + "/" + path.relative_to(bundle_dir).as_posix())
                info.mode = path.stat().st_mode & 0o777
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = 0
                with path.open("rb") as file:
                    tf.addfile(info, file)


def verify_archive(out_path, bundle, platform):
    """回读必需组件, 可执行位, wheel/WASM 格式和每个文件的校验和."""
    if EXTENSIONS[platform] == "zip":
        with zipfile.ZipFile(out_path) as zf:
            found = {i.filename: (i.external_attr >> 16, zf.read(i)) for i in zf.infolist()}
    else:
        with tarfile.open(out_path) as tf:
            found = {i.name: (i.mode, tf.extractfile(i).read()) for i in tf.getmembers() if i.isfile()}
    for name in found:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or not name.startswith(bundle + "/"):
            log.die("归档条目逃逸: " + name)
    manifest_path = bundle + "/manifest.json"
    if manifest_path not in found:
        log.die("综合包缺少 manifest.json")
    manifest = json.loads(found[manifest_path][1])
    if manifest.get("format_version") != 1 or manifest.get("platform") != platform:
        log.die("综合包 manifest 版本或平台无效")
    expected_name = bundle_name(manifest["version"], platform, manifest["arch"])
    if expected_name != bundle:
        log.die("归档名与 manifest 不一致")
    expected = {bundle + "/" + name for name in manifest["files"]} | {manifest_path}
    if set(found) != expected:
        log.die("归档内容与 manifest 不一致")
    for name, digest in manifest["files"].items():
        if hashlib.sha256(found[bundle + "/" + name][1]).hexdigest() != digest:
            log.die("归档校验和不一致: " + name)
    required = ["README.md", "web/index.html", "web/wasm/engine_lab.js", "web/wasm/engine_lab_bg.wasm"]
    required += ["bin/" + binary_name(b, platform) for b in BINARIES]
    for name in required:
        if bundle + "/" + name not in found:
            log.die("综合包缺少组件: " + name)
    if platform != "windows":
        for binary in BINARIES:
            name = bundle + "/bin/" + binary
            if not found[name][0] & 0o111:
                log.die("归档丢失可执行位: " + name)
    wheels = [name for name in found if name.startswith(bundle + "/python/") and name.endswith(".whl")]
    if len(wheels) != 1:
        log.die("综合包缺少唯一 Python wheel")
    wheel_platform = {"linux": {"x86_64": "linux_x86_64", "aarch64": "linux_aarch64"},
                      "windows": {"x86_64": "win_amd64", "aarch64": "win_arm64"},
                      "macos": {"x86_64": "x86_64", "aarch64": "arm64", UNIVERSAL: "universal2"}}[platform][manifest["arch"]]
    if not wheels[0].endswith(wheel_platform + ".whl") or "-cp38-abi3-" not in wheels[0]:
        log.die("wheel 的 Python ABI, 平台或架构与综合包不符")
    with zipfile.ZipFile(io.BytesIO(found[wheels[0]][1])) as wheel:
        native = [n for n in wheel.namelist() if n.endswith(".pyd" if platform == "windows" else ".so")]
        metadata = [n for n in wheel.namelist() if n.endswith(".dist-info/WHEEL")]
        if len(native) != 1 or len(metadata) != 1 or b"Tag: cp38-abi3-" not in wheel.read(metadata[0]):
            log.die("wheel 缺少唯一原生扩展或正确的 ABI 元数据")
        if platform == "macos" and manifest["arch"] == UNIVERSAL:
            header = wheel.read(native[0])[:8]
            if len(header) < 8 or header[:4] not in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf") or int.from_bytes(header[4:8], "big") < 2:
                log.die("universal2 wheel 内没有真正的双架构 Mach-O 扩展")
    if not found[bundle + "/web/wasm/engine_lab_bg.wasm"][1].startswith(b"\0asm"):
        log.die("Web 引擎不是有效的 WASM 文件")
    if not any(n.startswith(bundle + "/web/assets/") and n.endswith(".js") for n in found):
        log.die("Web 页面缺少前端 JavaScript")


def main():
    log.set_prefix("impls-dist")
    args = parse_args()
    platform = args.platform
    if args.universal and platform != "macos":
        log.die("--universal 只适用于 macOS")
    if platform != host_platform():
        log.die("综合包包含 Python 扩展, 请在目标平台原生构建")
    arch = UNIVERSAL if args.universal else (args.arch or host_arch())
    triples = list(TRIPLES[platform].values()) if arch == UNIVERSAL else [TRIPLES[platform][arch]]
    version = versionlib.build_version()
    ensure_triples(triples + ["wasm32-unknown-unknown"])
    log.info("统一构建 %s / %s / %s" % (version, platform, arch))
    # 浏览器版游戏约 100 MB 且含完整游戏资源, 综合归档只放调试台.
    assets = web.build_assets(version, game=False)
    build(triples, version)
    bundle = bundle_name(version, platform, arch)
    out_dir = Path(layout.ensure_dir(layout.ENGINE_DIST)).resolve()
    temporary_root = Path(layout.ROOT_DIR, ".tmp").resolve()
    temporary_root.mkdir(exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="engine-dist-", dir=temporary_root)).resolve()
    assert staging.parent == temporary_root and staging.name.startswith("engine-dist-")
    try:
        directory = staging / bundle
        directory.mkdir()
        files = assemble(str(directory), triples, platform)
        wheel = build_python(str(directory), platform, arch, version)
        shutil.copytree(assets, directory / "web")
        shutil.copy2(Path(layout.ROOT_DIR, "impls", "web", "bundle-readme.md"), directory / "README.md")
        runnable = runnable_here(platform, arch)
        smoke(files, version, runnable)
        smoke_python(wheel, version, runnable)
        write_manifest(directory, version, platform, arch)
        temporary_archive = staging / archive_name(version, platform, arch)
        write_archive(directory, bundle, platform, temporary_archive)
        verify_archive(temporary_archive, bundle, platform)
        destination = (out_dir / temporary_archive.name).resolve()
        if destination.parent != out_dir:
            log.die("归档目标不在 dist/engine 内")
        os.replace(temporary_archive, destination)
        log.info("综合包完成: %s (%s)" % (destination, archive.human_size(destination.stat().st_size)))
    finally:
        if args.keep_work:
            log.info("保留组装目录: " + str(staging))
        else:
            assert staging.resolve().parent == temporary_root and staging.name.startswith("engine-dist-")
            shutil.rmtree(staging)
    return 0


if __name__ == "__main__":
    sys.exit(main())
