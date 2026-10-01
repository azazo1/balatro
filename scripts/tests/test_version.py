"""Android versionCode 折算的单调性测试.

折算错了不会报错, 只会在设备上覆盖安装失败, 所以按真实的发布顺序逐对检查.
"""
import unittest

from lib.version import android_version_code


class VersionCodeTest(unittest.TestCase):
    def test_monotonic_in_release_order(self):
        # 依次为: 仓库升版本, 上游升字母后缀, 无后缀的新补丁版本, 再升 minor 与 major.
        ordered = [
            "1.0.1n-0.1.0",
            "1.0.1n-0.2.0",
            "1.0.1n-1.0.0",
            "1.0.1o-0.1.0",
            "1.0.1z-9.9.9",
            "1.0.2-0.1.0",
            "1.0.2a-0.1.0",
            "1.1.0-0.1.0",
            "2.0.0-0.1.0",
        ]
        codes = [android_version_code(v) for v in ordered]
        for (a, ca), (b, cb) in zip(zip(ordered, codes), zip(ordered[1:], codes[1:])):
            self.assertLess(ca, cb, "%s (%d) 应小于 %s (%d)" % (a, ca, b, cb))

    def test_exceeds_previous_scheme(self):
        # 旧方案下已发布的 1.0.1n-0.1.0 是 10001010, 新方案的任何版本都必须比它大才能覆盖安装.
        self.assertGreater(android_version_code("1.0.1n-0.1.0"), 10001010)

    def test_build_metadata_ignored(self):
        self.assertEqual(android_version_code("1.0.1o+deadbee"), android_version_code("1.0.1o"))


if __name__ == "__main__":
    unittest.main()
