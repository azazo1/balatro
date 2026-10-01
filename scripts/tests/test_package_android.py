"""带 mod 的 Android 包对 bbnet 的处理.

bbnet 缺失时游戏照常启动, 只是内置 agent 连不上模型, 录像只有时间轴, 看不出问题. 这里锁住
"必需的 ABI 编不出来就报错, 其余跳过并警告, 编出来的才放进包" 这几条, 不实际编译.
"""
import os
import tempfile
import unittest
import zipfile
from unittest import mock

import build_native
import package_android


def runtime_apk(directory, abis):
    """造一个只有各 ABI 的 liblove.so 的运行时 APK."""
    path = os.path.join(directory, "runtime.apk")
    with zipfile.ZipFile(path, "w") as zf:
        for abi in abis:
            zf.writestr("lib/%s/liblove.so" % abi, b"")
    return path


class BbnetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.apk = runtime_apk(self.tmp.name, ["arm64-v8a", "armeabi-v7a"])
        self.built = []

        def fake_build(abis):
            self.built = list(abis)
            for abi in abis:
                path = os.path.join(self.tmp.name, abi, "libbbnet.so")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                open(path, "wb").close()

        patches = [
            mock.patch.object(build_native, "build_android", fake_build),
            mock.patch.object(build_native, "android_lib",
                              lambda abi: os.path.join(self.tmp.name, abi, "libbbnet.so")),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def missing(self, table):
        return mock.patch.object(build_native, "android_missing", lambda abi: table.get(abi))

    def test_builds_every_time_and_skips_unbuildable_optional_abi(self):
        with self.missing({"armeabi-v7a": "没装 rust target"}):
            found = package_android.bbnet_replacements(self.apk, skip=False)
        self.assertEqual(self.built, ["arm64-v8a"])
        self.assertEqual(sorted(found), ["lib/arm64-v8a/libbbnet.so"])

    def test_required_abi_unbuildable_fails(self):
        with self.missing({"arm64-v8a": "找不到 cargo-ndk"}):
            with self.assertRaises(SystemExit):
                package_android.bbnet_replacements(self.apk, skip=False)
        self.assertEqual(self.built, [])

    def test_no_native_skips_entirely(self):
        with self.missing({"arm64-v8a": "找不到 cargo-ndk"}):
            found = package_android.bbnet_replacements(self.apk, skip=True)
        self.assertEqual(found, {})
        self.assertEqual(self.built, [])


if __name__ == "__main__":
    unittest.main()
