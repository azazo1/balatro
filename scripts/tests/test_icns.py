"""macOS 图标: 圆角遮罩与 icns 容器."""
import os
import shutil
import tempfile
import unittest

from lib import icns, pngutil


def solid(size, rgb=(200, 40, 40)):
    r, g, b = rgb
    buf = bytearray(size * size * 4)
    for i in range(size * size):
        buf[i * 4:i * 4 + 4] = bytes((r, g, b, 255))
    return bytes(buf)


def alpha_at(rgba, size, x, y):
    return rgba[(y * size + x) * 4 + 3]


class RoundRectTest(unittest.TestCase):
    def test_corners_and_outer_edges_cut(self):
        size = 64
        rgba = pngutil.apply_round_rect_mask(size, size, solid(size))
        self.assertEqual(alpha_at(rgba, size, 0, 0), 0)
        self.assertEqual(alpha_at(rgba, size, size - 1, 0), 0)
        self.assertEqual(alpha_at(rgba, size, 0, size - 1), 0)
        self.assertEqual(alpha_at(rgba, size, size - 1, size - 1), 0)
        self.assertEqual(alpha_at(rgba, size, size // 2, 0), 0)
        self.assertEqual(alpha_at(rgba, size, 0, size // 2), 0)
        self.assertEqual(alpha_at(rgba, size, size // 2, size // 2), 255)
        inset = pngutil.macos_icon_inset(size)
        self.assertEqual(alpha_at(rgba, size, size // 2, inset + 1), 255)
        self.assertEqual(alpha_at(rgba, size, inset + 1, size // 2), 255)

    def test_center_rgb_unchanged(self):
        size = 32
        src = solid(size, (10, 20, 30))
        out = pngutil.apply_round_rect_mask(size, size, src)
        mid = ((size // 2) * size + size // 2) * 4
        self.assertEqual(out[mid:mid + 4], src[mid:mid + 4])


class IcnsBuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.src = os.path.join(self.tmp.name, "icon.png")
        pngutil.save_rgba(self.src, 64, 64, solid(64))

    def test_python_icns_has_toc_and_small_sizes(self):
        dst = os.path.join(self.tmp.name, "app.icns")
        icns.build(self.src, dst, round_rect=True, prefer_iconutil=False)
        tags = [tag for tag, _payload in icns.iter_blocks(dst)]
        self.assertEqual(tags[0], b"TOC ")
        self.assertIn(b"icp4", tags)
        self.assertIn(b"ic10", tags)

    def test_python_icns_png_is_rounded(self):
        dst = os.path.join(self.tmp.name, "app.icns")
        icns.build(
            self.src, dst, types=[(b"ic07", 128)],
            round_rect=True, prefer_iconutil=False,
        )
        blocks = dict(icns.iter_blocks(dst))
        png_path = os.path.join(self.tmp.name, "out.png")
        with open(png_path, "wb") as fh:
            fh.write(blocks[b"ic07"])
        width, height, rgba = pngutil.load_rgba(png_path)
        self.assertEqual((width, height), (128, 128))
        self.assertEqual(alpha_at(rgba, 128, 0, 0), 0)
        self.assertEqual(alpha_at(rgba, 128, 64, 0), 0)
        self.assertEqual(alpha_at(rgba, 128, 64, 64), 255)

    @unittest.skipUnless(shutil.which("iconutil"), "需要 macOS 的 iconutil")
    def test_iconutil_adds_legacy_small_icons(self):
        dst = os.path.join(self.tmp.name, "app.icns")
        icns.build(self.src, dst, round_rect=True, prefer_iconutil=True)
        tags = [tag for tag, _payload in icns.iter_blocks(dst)]
        self.assertIn(b"ic04", tags)
        self.assertIn(b"ic05", tags)
        self.assertIn(b"ic10", tags)


if __name__ == "__main__":
    unittest.main()
