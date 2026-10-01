"""生成 macOS 的 .icns 图标文件.

用纯 Python 拼装 icns 容器, 内部直接放 PNG 数据. macOS 10.7 起支持这种形式,
因此不必依赖 sips 与 iconutil, 也就避免了平台工具差异.

icns 结构: 文件头 ('icns' + 大端总长度) 之后跟若干数据块, 每块为
4 字节类型 + 4 字节大端长度 (含这 8 字节) + 数据.
"""
import struct

from . import pngutil

ICNS_MAGIC = b"icns"

# 图标类型到像素尺寸的映射. 数字类型是 1x, 字母类型多为 2x 变体.
ICON_TYPES = [
    (b"ic07", 128),
    (b"ic08", 256),
    (b"ic09", 512),
    (b"ic10", 1024),
    (b"ic11", 32),
    (b"ic12", 64),
    (b"ic13", 256),
    (b"ic14", 512),
]


class IcnsError(Exception):
    """icns 生成失败."""


def build(src_png, dst_icns, types=None):
    """把一张正方形 PNG 转成 .icns, 返回写入的各尺寸列表.

    图标是像素风格, 各尺寸一律最近邻缩放, 免得区域平均把色块边界糊掉.
    """
    width, height, rgba = pngutil.load_rgba(src_png)
    if width != height:
        raise IcnsError("图标源图必须是正方形, 当前为 %dx%d" % (width, height))

    blocks = []
    written = []
    for tag, size in (types or ICON_TYPES):
        resized = pngutil.resize_rgba(width, height, rgba, size, size, nearest=True)
        blocks.append((tag, pngutil.encode_png(size, size, resized)))
        written.append(size)

    body = b"".join(struct.pack(">4sI", tag, len(data) + 8) + data
                    for tag, data in blocks)
    with open(dst_icns, "wb") as fh:
        fh.write(ICNS_MAGIC)
        fh.write(struct.pack(">I", len(body) + 8))
        fh.write(body)
    return written
