"""二进制 AndroidManifest 的属性改写.

官方 LÖVE 把 resizeableActivity 设成 false, 系统会拒绝分屏与小窗. 打包时必须改成 true,
漏改的话装得上但进不了小窗, 所以对着真实运行时 APK 的 manifest 锁住这一条.
"""
import os
import struct
import unittest

from lib import android_manifest, layout, runtime


def attr_values(blob, attr_name):
    """返回名为 attr_name 的属性的 (类型, 值) 列表, 按文档顺序."""
    pool = android_manifest.StringPool(blob, 8)
    pos = 8 + pool.old_size
    found = []
    while pos + 8 <= len(blob):
        type_, _hs, size = struct.unpack_from("<HHI", blob, pos)
        if size < 8:
            break
        if type_ == android_manifest.RES_XML_START_ELEMENT:
            ext = pos + 16
            attr_start, attr_size, attr_count = struct.unpack_from("<HHH", blob, ext + 8)
            for i in range(attr_count):
                attr = ext + attr_start + i * attr_size
                _ns, name_idx, _raw = struct.unpack_from("<III", blob, attr)
                _v_size, _res0, v_type, v_data = struct.unpack_from("<HBBI", blob, attr + 12)
                if name_idx < len(pool.strings) and pool.strings[name_idx] == attr_name:
                    found.append((v_type, v_data))
        pos += size
    return found


def vendor_manifest():
    name, _, _ = runtime.RUNTIMES["android"]
    path = os.path.join(layout.VENDOR_DIR, name)
    if not os.path.isfile(path):
        raise unittest.SkipTest("缺少 Android 运行时")
    return android_manifest.read_manifest_bytes(path)


class ManifestPatchTest(unittest.TestCase):
    def test_enables_resizeable_activity(self):
        original = vendor_manifest()
        self.assertEqual(attr_values(original, "resizeableActivity"),
                         [(android_manifest.TYPE_INT_BOOLEAN, 0)])

        patched, changes = android_manifest.patch_manifest(
            original,
            ints={"screenOrientation": 5, "versionCode": 100115010,
                  "resizeableActivity": True},
        )
        self.assertEqual(attr_values(patched, "resizeableActivity"),
                         [(android_manifest.TYPE_INT_BOOLEAN, android_manifest.BOOL_TRUE)])
        self.assertEqual(attr_values(patched, "screenOrientation"),
                         [(android_manifest.TYPE_INT_DEC, 5)])
        self.assertEqual(attr_values(patched, "versionCode"),
                         [(android_manifest.TYPE_INT_DEC, 100115010)])
        # 其它布尔属性不能被误改.
        self.assertTrue(all(v == 0 for _t, v in attr_values(patched, "required")))
        self.assertIn(("resizeableActivity=false", "resizeableActivity=true"), changes)

    def test_unknown_int_attrs_ignored(self):
        original = vendor_manifest()
        patched, changes = android_manifest.patch_manifest(
            original, ints={"launchMode": 1, "exported": True})
        self.assertEqual(attr_values(patched, "launchMode"),
                         attr_values(original, "launchMode"))
        self.assertEqual(attr_values(patched, "exported"),
                         attr_values(original, "exported"))
        self.assertFalse(any("launchMode" in item or "exported" in item
                             for pair in changes for item in pair))


if __name__ == "__main__":
    unittest.main()
