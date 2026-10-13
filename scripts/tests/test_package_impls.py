"""综合归档的组件完整性, 校验和与可执行位, 不调用编译工具链."""
import os
from pathlib import Path
import tempfile
import unittest
import zipfile

import package_impls as package

VERSION = "1.0.1o-0.1.1"


def make_bundle(directory, platform, mode=0o755):
    bundle = package.bundle_name(VERSION, platform, "x86_64")
    root = Path(directory, bundle)
    files = {"README.md": b"readme", "web/index.html": b"<html></html>",
             "web/assets/index.js": b"export {}", "web/wasm/engine_lab.js": b"export {}",
             "web/wasm/engine_lab_bg.wasm": b"\0asm\x01\0\0\0"}
    files.update({"bin/" + package.binary_name(b, platform): b"placeholder" for b in package.BINARIES})
    for name, content in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        if name.startswith("bin/"):
            path.chmod(mode)
    python = root / "python"
    python.mkdir()
    tag = "win_amd64" if platform == "windows" else "linux_x86_64"
    wheel = python / f"balatro_engine-0.1.0-cp38-abi3-{tag}.whl"
    with zipfile.ZipFile(wheel, "w") as archive:
        archive.writestr("balatro_engine/balatro_engine.abi3.pyd" if platform == "windows" else "balatro_engine/balatro_engine.abi3.so", b"native")
        archive.writestr("balatro_engine-0.1.0.dist-info/WHEEL", "Tag: cp38-abi3-" + tag)
    package.write_manifest(root, VERSION, platform, "x86_64")
    return bundle, root


class ArchiveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_archive_names_keep_repository_version_rules(self):
        self.assertEqual(package.archive_name(VERSION, "linux", "x86_64"), "balatro-engine-1.0.1o-0.1.1-linux-x86_64.tar.gz")
        self.assertEqual(package.archive_name("1.0.1o+32cfe92", "macos", "universal"), "balatro-engine-1.0.1o+32cfe92-macos-universal.tar.gz")
        self.assertEqual(package.archive_name(VERSION, "windows", "x86_64"), "balatro-engine-1.0.1o-0.1.1-windows-x86_64.zip")

    def test_recursive_roundtrip_and_reproducible_archives(self):
        for platform in ["linux", "windows"]:
            with self.subTest(platform=platform):
                bundle, root = make_bundle(self.tmp.name, platform)
                first, second = Path(self.tmp.name, platform + "-first"), Path(self.tmp.name, platform + "-second")
                package.write_archive(root, bundle, platform, first)
                package.verify_archive(first, bundle, platform)
                package.write_archive(root, bundle, platform, second)
                self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_missing_components_and_corrupt_wasm_are_refused_even_with_consistent_manifest(self):
        components = ["bin/replay_check", "python", "web/wasm/engine_lab_bg.wasm", "web/assets/index.js"]
        for index, component in enumerate(components):
            with self.subTest(component=component):
                area = Path(self.tmp.name, str(index))
                bundle, root = make_bundle(area, "linux")
                path = root / component
                if path.is_dir():
                    next(path.iterdir()).unlink()
                elif component.endswith(".wasm"):
                    path.write_bytes(b"not wasm")
                else:
                    path.unlink()
                package.write_manifest(root, VERSION, "linux", "x86_64")
                output = area / "archive.tar.gz"
                package.write_archive(root, bundle, "linux", output)
                with self.assertRaises(SystemExit):
                    package.verify_archive(output, bundle, "linux")

    def test_tampered_file_is_refused(self):
        bundle, root = make_bundle(self.tmp.name, "linux")
        (root / "web/assets/index.js").write_bytes(b"modified")
        output = Path(self.tmp.name, "archive.tar.gz")
        package.write_archive(root, bundle, "linux", output)
        with self.assertRaises(SystemExit):
            package.verify_archive(output, bundle, "linux")

    @unittest.skipUnless(os.name == "posix", "仅在 POSIX 检查可执行位")
    def test_lost_executable_bit_is_refused(self):
        bundle, root = make_bundle(self.tmp.name, "linux", mode=0o644)
        output = Path(self.tmp.name, "archive.tar.gz")
        package.write_archive(root, bundle, "linux", output)
        with self.assertRaises(SystemExit):
            package.verify_archive(output, bundle, "linux")
