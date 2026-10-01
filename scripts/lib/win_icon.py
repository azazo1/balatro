"""把 love.exe 里的图标换成游戏自己的图标.

融合只是把游戏载荷追加到 exe 末尾, 图标资源仍来自官方运行时, 所以直接融合出来的产物在
资源管理器里显示的是 LÖVE 的图标. 官方 love.exe 的图标资源里正好是 16/32/48/64/128/256
六个槽位, 每个槽位一张 32 位 DIB, 与我们要用的尺寸一一对应, 而且同一尺寸下两种图标都是
同一种位图格式, 字节长度完全相同 (见 _dib 与那句长度校验). 因此把每槽的像素数据原地覆盖
进去即可, 资源目录, 图标组描述与段表都不用碰, 载荷起点也不会变.
"""
import struct

from . import pngutil

RT_ICON = 3
RT_GROUP_ICON = 14

# 资源目录里的目录项最高位为 1 表示指向子目录, 名字最高位为 1 表示是字符串而不是序号.
DIRECTORY_FLAG = 0x80000000
NAME_IS_STRING = 0x80000000

# 数据目录里资源目录那一项的下标.
DD_RSRC = 2
SECTION_HEADER_SIZE = 40


class WinIconError(Exception):
    """图标替换失败."""


def _sections(blob):
    """返回 [(虚拟地址, 虚拟大小, 文件偏移, 文件大小)]."""
    pe_off = struct.unpack_from("<I", blob, 0x3C)[0]
    if blob[pe_off:pe_off + 4] != b"PE\0\0":
        raise WinIconError("不是 PE 文件")
    _machine, count, _t, _sp, _ns, opt_size, _ch = struct.unpack_from(
        "<HHIIIHH", blob, pe_off + 4)
    table_off = pe_off + 24 + opt_size
    out = []
    for i in range(count):
        off = table_off + SECTION_HEADER_SIZE * i
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", blob, off + 8)
        out.append((vaddr, vsize, raddr, rsize))
    return out


def _dd_off(blob):
    """数据目录在可选头里的偏移, PE32 与 PE32+ 不同."""
    pe_off = struct.unpack_from("<I", blob, 0x3C)[0]
    opt = pe_off + 24
    magic = struct.unpack_from("<H", blob, opt)[0]
    return opt + (112 if magic == 0x20B else 96)


def _offset(blob, sections, rva):
    for vaddr, vsize, raddr, rsize in sections:
        if vaddr <= rva < vaddr + max(vsize, rsize):
            return raddr + (rva - vaddr)
    raise WinIconError("RVA 0x%X 不在任何段内" % rva)


def _leaves(blob, sections, base):
    """摊平资源目录, 返回 [(类型, 名字, 文件偏移, 长度)]. 名字是图标序号或组号."""
    out = []

    def walk(node_off, path):
        named, ids = struct.unpack_from("<HH", blob, node_off + 12)
        for i in range(named + ids):
            name_id, offset = struct.unpack_from("<II", blob, node_off + 16 + 8 * i)
            name = ("str@%X" % name_id) if name_id & NAME_IS_STRING else name_id
            if offset & DIRECTORY_FLAG:
                walk(base + (offset & ~DIRECTORY_FLAG), path + (name,))
                continue
            rva, size, _cp, _res = struct.unpack_from("<IIII", blob, base + offset)
            out.append((path[0], path[1], _offset(blob, sections, rva), size))

    walk(base, ())
    return out


def _dib(size, rgba):
    """把 RGBA 编成图标槽位里的那种 32 位 DIB."""
    stride = size * 4
    body = bytearray()
    for y in range(size):
        row = bytearray(stride)
        src = (size - 1 - y) * stride  # DIB 自下而上存放
        for x in range(size):
            i = src + x * 4
            o = x * 4
            row[o] = rgba[i + 2]      # BGRA
            row[o + 1] = rgba[i + 1]
            row[o + 2] = rgba[i]
            row[o + 3] = rgba[i + 3]
        body += row
    # 后面的 1 位 AND 掩码在 32 位图里不参与显示, 但槽位长度算上了它, 必须补齐.
    body += bytes((((size + 31) // 32) * 4) * size)
    return struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0,
                       len(body), 0, 0, 0, 0) + bytes(body)


def replace(exe_path, icon_png):
    """就地把 exe 里各图标槽位换成 icon_png 缩放后的图, 返回换过的尺寸列表."""
    with open(exe_path, "rb") as fh:
        blob = bytearray(fh.read())

    sections = _sections(blob)
    rsrc_rva, _rsrc_size = struct.unpack_from("<II", blob, _dd_off(blob) + 8 * DD_RSRC)
    if not rsrc_rva:
        raise WinIconError("exe 里没有资源目录")
    base = _offset(blob, sections, rsrc_rva)

    leaves = _leaves(blob, sections, base)
    icons = {name: (off, size) for type_id, name, off, size in leaves if type_id == RT_ICON}
    groups = [(off, size) for type_id, _name, off, size in leaves if type_id == RT_GROUP_ICON]
    if len(groups) != 1:
        raise WinIconError("exe 里有 %d 组图标, 期望 1 组" % len(groups))

    group_off, group_size = groups[0]
    group = blob[group_off:group_off + group_size]
    count = struct.unpack_from("<H", group, 4)[0]

    width, height, rgba = pngutil.load_rgba(icon_png)
    if width != height:
        raise WinIconError("图标源图必须是正方形, 当前 %dx%d" % (width, height))

    sizes = []
    for i in range(count):
        w, h, _colors, _reserved, _planes, bpp, _length, icon_id = struct.unpack_from(
            "<BBBBHHIH", group, 6 + 14 * i)
        size = w or 256
        if bpp != 32:
            raise WinIconError("槽位不是 32 位图 (bpp=%d), 无法原地替换" % bpp)
        if size != (h or 256):
            raise WinIconError("槽位 %dx%d 不是正方形" % (size, h or 256))
        if icon_id not in icons:
            raise WinIconError("图标组引用了不存在的槽位 %s" % icon_id)

        slot_off, slot_size = icons[icon_id]
        # 图标是像素风格, 用最近邻缩放, 免得区域平均把色块边界糊掉.
        scaled = pngutil.resize_rgba(width, height, rgba, size, size, nearest=True)
        data = _dib(size, scaled)
        if len(data) != slot_size:
            raise WinIconError("槽位 %dx%d 期望 %d 字节, 生成出来是 %d 字节"
                               % (size, size, slot_size, len(data)))
        blob[slot_off:slot_off + slot_size] = data
        sizes.append(size)

    with open(exe_path, "wb") as fh:
        fh.write(bytes(blob))
    return sizes
