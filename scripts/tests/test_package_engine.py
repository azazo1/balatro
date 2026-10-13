"""engine 产物的命名与归档.

产物名是发布页上直接可见的东西, 归档里少一个二进制或丢了可执行位则要等使用者解压才发现,
这里把这两条锁住, 不实际编译.
"""
import os
import tarfile
import tempfile
import unittest
import zipfile

import package_engine

VERSION = "1.0.1o-0.1.1"


class NamingTest(unittest.TestCase):
    def test_binary_names_follow_the_platform(self):
        self.assertEqual(package_engine.binary_name("play", "windows"), "play.exe")
        self.assertEqual(package_engine.binary_name("play", "linux"), "play")

    def test_archive_names_carry_version_platform_and_arch(self):
        self.assertEqual(package_engine.archive_name(VERSION, "linux", "x86_64"),
                         "balatro-engine-1.0.1o-0.1.1-linux-x86_64.tar.gz")
        self.assertEqual(package_engine.archive_name("1.0.1o+32cfe92", "macos", "universal"),
                         "balatro-engine-1.0.1o+32cfe92-macos-universal.tar.gz")
        self.assertEqual(package_engine.archive_name(VERSION, "windows", "x86_64"),
                         "balatro-engine-1.0.1o-0.1.1-windows-x86_64.zip")


def make_bundle(directory, platform, mode=0o755):
    """造一个产物目录, 里面放占位的两个二进制."""
    bundle = package_engine.bundle_name(VERSION, platform, "x86_64")
    bundle_dir = os.path.join(directory, bundle)
    os.makedirs(bundle_dir)
    for binary in package_engine.BINARIES:
        path = os.path.join(bundle_dir, package_engine.binary_name(binary, platform))
        with open(path, "wb") as fh:
            fh.write(b"placeholder\n")
        os.chmod(path, mode)
    return bundle, bundle_dir


class ArchiveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def entries(self, path, platform):
        if package_engine.EXTENSIONS[platform] == "zip":
            with zipfile.ZipFile(path) as zf:
                return sorted(info.filename for info in zf.infolist())
        with tarfile.open(path) as tf:
            return sorted(info.name for info in tf.getmembers())

    def test_tar_archive_round_trip(self):
        bundle, bundle_dir = make_bundle(self.tmp.name, "linux")
        out = os.path.join(self.tmp.name, "engine.tar.gz")
        package_engine.write_archive(bundle_dir, bundle, "linux", out)
        self.assertEqual(self.entries(out, "linux"),
                         ["%s/play" % bundle, "%s/replay_check" % bundle])
        package_engine.verify_archive(out, bundle, "linux")

    def test_zip_archive_round_trip(self):
        bundle, bundle_dir = make_bundle(self.tmp.name, "windows")
        out = os.path.join(self.tmp.name, "engine.zip")
        package_engine.write_archive(bundle_dir, bundle, "windows", out)
        self.assertEqual(self.entries(out, "windows"),
                         ["%s/play.exe" % bundle, "%s/replay_check.exe" % bundle])
        package_engine.verify_archive(out, bundle, "windows")

    def test_missing_binary_is_refused(self):
        bundle, bundle_dir = make_bundle(self.tmp.name, "linux")
        os.remove(os.path.join(bundle_dir, "replay_check"))
        out = os.path.join(self.tmp.name, "engine.tar.gz")
        package_engine.write_archive(bundle_dir, bundle, "linux", out)
        with self.assertRaises(SystemExit):
            package_engine.verify_archive(out, bundle, "linux")

    @unittest.skipUnless(os.name == "posix", "可执行位只在 posix 上有意义")
    def test_lost_executable_bit_is_refused(self):
        bundle, bundle_dir = make_bundle(self.tmp.name, "linux", mode=0o644)
        out = os.path.join(self.tmp.name, "engine.tar.gz")
        package_engine.write_archive(bundle_dir, bundle, "linux", out)
        with self.assertRaises(SystemExit):
            package_engine.verify_archive(out, bundle, "linux")
