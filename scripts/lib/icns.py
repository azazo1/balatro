"""生成 macOS 的 .icns 图标文件.

像素风源图按最近邻缩到各尺寸, 再套一层抗锯齿圆角矩形遮罩, 避免 Dock / Finder
把满幅方图显示成直角矩形.

macOS 上优先调用 iconutil 打包: 它会写入 Finder 依赖的 ic04 / ic05 小图标
以及 TOC, 图标才能稳定显示. 没有 iconutil 时回退到纯 Python 的 PNG icns,
仍写入 TOC 与从 16px 起的各尺寸, 方便在非 macOS 上做校验.

icns 结构: 文件头 ('icns' + 大端总长度) 之后跟若干数据块, 每块为
4 字节类型 + 4 字节大端长度 (含这 8 字节) + 数据.
"""
import os
import shutil
import struct
import tempfile

from . import log, pngutil

ICNS_MAGIC = b"icns"

# 纯 Python 回退路径用的类型. 数字类型是 1x, 字母类型多为 2x 变体.
# icp4 / icp5 / icp6 补上原先缺失的 16 / 32 / 64, 否则小图标位会空.
ICON_TYPES = [
    (b"icp4", 16),
    (b"icp5", 32),
    (b"icp6", 64),
    (b"ic07", 128),
    (b"ic08", 256),
    (b"ic09", 512),
    (b"ic10", 1024),
    (b"ic11", 32),
    (b"ic12", 64),
    (b"ic13", 256),
    (b"ic14", 512),
]

# iconutil 要求的 iconset 文件名. 同一像素尺寸会出现两次 (1x 与另一档的 @2x).
ICONSET_FILES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


class IcnsError(Exception):
    """icns 生成失败."""


def iter_blocks(path):
    """依次产出 (类型, 数据), 供测试与排查."""
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(ICNS_MAGIC):
        raise IcnsError("%s 不是 icns 文件" % path)
    declared = struct.unpack(">I", data[4:8])[0]
    if declared != len(data):
        raise IcnsError("icns 长度字段为 %d, 实际为 %d" % (declared, len(data)))
    pos = 8
    while pos + 8 <= len(data):
        tag, length = struct.unpack_from(">4sI", data, pos)
        if length < 8 or pos + length > len(data):
            raise IcnsError("icns 块 %s 长度异常: %d" % (tag, length))
        yield tag, data[pos + 8:pos + length]
        pos += length
    if pos != len(data):
        raise IcnsError("icns 末尾有 %d 字节未解析" % (len(data) - pos))


def _pixels_at(width, height, rgba, size, round_rect):
    if round_rect:
        return pngutil.fit_macos_app_icon(width, height, rgba, size)
    return pngutil.resize_rgba(width, height, rgba, size, size, nearest=True)


def _write_python_icns(blocks, dst_icns):
    toc_data = b"".join(struct.pack(">4sI", tag, len(data) + 8) for tag, data in blocks)
    chunks = [(b"TOC ", toc_data)] + list(blocks)
    body = b"".join(struct.pack(">4sI", tag, len(data) + 8) + data
                    for tag, data in chunks)
    with open(dst_icns, "wb") as fh:
        fh.write(ICNS_MAGIC)
        fh.write(struct.pack(">I", len(body) + 8))
        fh.write(body)


def _build_iconutil(pixels_for, dst_icns):
    """用系统 iconutil 打包 iconset. 失败时返回 None, 由调用方回退."""
    tmp = tempfile.mkdtemp(suffix=".iconset")
    try:
        written = []
        for name, size in ICONSET_FILES:
            pngutil.save_rgba(os.path.join(tmp, name), size, size, pixels_for(size))
            written.append(size)
        log.run(
            ["iconutil", "--convert", "icns", "--output", dst_icns, tmp],
            check=False, capture=True, quiet=True,
        )
        if not os.path.isfile(dst_icns) or os.path.getsize(dst_icns) < 16:
            return None
        return written
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def build(src_png, dst_icns, types=None, round_rect=True, prefer_iconutil=True):
    """把一张正方形 PNG 转成 .icns, 返回写入的各尺寸列表.

    图标是像素风格, 各尺寸一律最近邻缩放, 免得区域平均把色块边界糊掉.
    默认再套圆角矩形遮罩. prefer_iconutil 为真且未指定 types 时优先走 iconutil.
    """
    width, height, rgba = pngutil.load_rgba(src_png)
    if width != height:
        raise IcnsError("图标源图必须是正方形, 当前为 %dx%d" % (width, height))

    cache = {}

    def pixels_for(size):
        if size not in cache:
            cache[size] = _pixels_at(width, height, rgba, size, round_rect)
        return cache[size]

    if prefer_iconutil and types is None and log.have("iconutil"):
        written = _build_iconutil(pixels_for, dst_icns)
        if written:
            return written
        log.warn("iconutil 未能生成 icns, 改用纯 Python 拼装")

    blocks = []
    written = []
    for tag, size in (types or ICON_TYPES):
        blocks.append((tag, pngutil.encode_png(size, size, pixels_for(size))))
        written.append(size)
    _write_python_icns(blocks, dst_icns)
    return written
