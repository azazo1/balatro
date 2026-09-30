"""改写 APK 中二进制 AndroidManifest.xml 的字符串与整数属性.

Android 的二进制 XML 里, XML 节点通过字符串池的 *索引* 引用字符串, 而不是字节偏移,
所以重建字符串池并修好池内偏移之后, 长度不同的替换也是安全的. 这一点很重要:
包名的新旧长度通常不同, 用文本替换的做法会破坏文件.

需要注意 android:name 指向的是 Java 类名 (org.love2d.android.GameActivity), 它在
classes.dex 里被编译引用, 必须保持原样. 只有 package 与 provider 的 authorities 需要改.
"""
import json
import struct
import zipfile

from . import log

RES_STRING_POOL = 0x0001
RES_XML_START_ELEMENT = 0x0102

UTF8_FLAG = 0x100
TYPE_INT_DEC = 0x10
TYPE_INT_HEX = 0x11

# 允许通过规则改写的整数属性, 其余一律忽略以免误改.
INT_ATTR_NAMES = {"screenOrientation", "versionCode", "versionCodeMajor"}


class ManifestError(Exception):
    """manifest 解析或改写失败."""


def _decode_utf8(buf, off):
    """解码二进制 XML 里的 UTF-8 字符串, 返回 (文本, 新偏移)."""
    o = off
    length16 = buf[o]
    if length16 & 0x80:
        length16 = ((length16 & 0x7F) << 8) | buf[o + 1]
        o += 2
    else:
        o += 1
    length8 = buf[o]
    if length8 & 0x80:
        length8 = ((length8 & 0x7F) << 8) | buf[o + 1]
        o += 2
    else:
        o += 1
    return buf[o:o + length8].decode("utf-8", errors="surrogateescape")


def _encode_utf8(text):
    """按二进制 XML 的 UTF-8 格式编码: [utf16 长度][字节长度][数据][0x00]."""
    raw = text.encode("utf-8", errors="surrogateescape")
    length16 = len(text.encode("utf-16-le")) // 2
    out = bytearray()
    if length16 > 0x7F:
        out += struct.pack(">H", length16 | 0x8000)
    else:
        out += bytes((length16,))
    if len(raw) > 0x7F:
        out += struct.pack(">H", len(raw) | 0x8000)
    else:
        out += bytes((len(raw),))
    out += raw + b"\x00"
    return bytes(out)


def _decode_utf16(buf, off):
    length, = struct.unpack_from("<H", buf, off)
    o = off + 2
    if length & 0x8000:
        length = ((length & 0x7FFF) << 16) | struct.unpack_from("<H", buf, o)[0]
        o += 2
    return buf[o:o + length * 2].decode("utf-16-le", errors="surrogateescape")


def _encode_utf16(text):
    raw = text.encode("utf-16-le", errors="surrogateescape")
    length = len(raw) // 2
    out = bytearray()
    if length > 0x7FFF:
        out += struct.pack("<HH", (length >> 16) | 0x8000, length & 0xFFFF)
    else:
        out += struct.pack("<H", length)
    return bytes(out) + raw + b"\x00\x00"


class StringPool:
    """二进制 XML 的字符串池."""

    def __init__(self, blob, off):
        type_, _header_size, size = struct.unpack_from("<HHI", blob, off)
        if type_ != RES_STRING_POOL:
            raise ManifestError("偏移 %d 处不是字符串池 (type=0x%04X)" % (off, type_))
        (self.string_count, self.style_count, self.flags,
         self.strings_start, self.styles_start) = struct.unpack_from("<IIIII", blob, off + 8)
        self.utf8 = bool(self.flags & UTF8_FLAG)
        self.offsets = [struct.unpack_from("<I", blob, off + 28 + 4 * i)[0]
                        for i in range(self.string_count)]
        base = off + self.strings_start
        decode = _decode_utf8 if self.utf8 else _decode_utf16
        self.strings = [decode(blob, base + o) for o in self.offsets]
        self.styles = blob[off + self.styles_start:off + size] if self.style_count else b""
        self.old_size = size

    def rebuild(self):
        """按当前 self.strings 重建池, 返回 (新池字节, 大小变化量)."""
        data = bytearray()
        offsets = []
        encode = _encode_utf8 if self.utf8 else _encode_utf16
        for text in self.strings:
            offsets.append(len(data))
            data += encode(text)
        while len(data) % 4:
            data += b"\x00"

        header_size = 28
        offsets_size = 4 * self.string_count + 4 * self.style_count
        strings_start = header_size + offsets_size
        styles_start = strings_start + len(data) if (self.style_count and self.styles) else 0
        size = strings_start + len(data) + len(self.styles)

        out = bytearray()
        out += struct.pack("<HHI", RES_STRING_POOL, header_size, size)
        out += struct.pack("<IIIII", self.string_count, self.style_count,
                           self.flags, strings_start, styles_start)
        for value in offsets:
            out += struct.pack("<I", value)
        for _ in range(self.style_count):
            out += struct.pack("<I", 0)
        out += data + self.styles
        if len(out) != size:
            raise ManifestError("重建后的池大小 %d 与声明 %d 不一致" % (len(out), size))
        return bytes(out), size - self.old_size


def _patch_ints(blob, pool, int_rules):
    """就地改写指定属性名的整数值, 返回改动列表."""
    pos = 8 + pool.old_size
    patched = []
    while pos + 8 <= len(blob):
        type_, _hs, size = struct.unpack_from("<HHI", blob, pos)
        if size < 8:
            break
        if type_ == RES_XML_START_ELEMENT:
            # ResXMLTree_node 为 16 字节, 其后的 attrExt 里 ns 与 name 各占 4 字节,
            # 之后才是 attributeStart, attributeSize, attributeCount.
            ext = pos + 16
            attr_start, attr_size, attr_count = struct.unpack_from("<HHH", blob, ext + 8)
            for i in range(attr_count):
                attr = ext + attr_start + i * attr_size
                _ns, name_idx, _raw = struct.unpack_from("<III", blob, attr)
                value_off = attr + 12
                _v_size, _res0, v_type, v_data = struct.unpack_from("<HBBI", blob, value_off)
                if name_idx >= len(pool.strings):
                    continue
                name = pool.strings[name_idx]
                if name in int_rules and v_type in (TYPE_INT_DEC, TYPE_INT_HEX):
                    struct.pack_into("<I", blob, value_off + 4, int_rules[name])
                    patched.append((name, v_data, int_rules[name]))
        pos += size
    return patched


def patch_apk(src_apk, dst_apk, strings=None, ints=None):
    """把 src_apk 复制为 dst_apk 并改写其中的 AndroidManifest.xml.

    strings 是 旧字符串 -> 新字符串, ints 是 属性名 -> 新整数值.
    返回 (改动说明列表, manifest 新大小).
    """
    strings = strings or {}
    ints = {k: v for k, v in (ints or {}).items() if k in INT_ATTR_NAMES}

    with zipfile.ZipFile(src_apk) as zf:
        entries = [(info, zf.read(info.filename)) for info in zf.infolist()]

    manifest = None
    for info, data in entries:
        if info.filename == "AndroidManifest.xml":
            manifest = bytearray(data)
            break
    if manifest is None:
        raise ManifestError("输入 APK 里没有 AndroidManifest.xml: %s" % src_apk)

    pool = StringPool(bytes(manifest), 8)
    log.info("字符串池: %d 项, 编码 %s, 大小 %d 字节"
             % (pool.string_count, "UTF-8" if pool.utf8 else "UTF-16", pool.old_size))

    changes = []
    for idx, text in enumerate(pool.strings):
        if text in strings:
            new_text = strings[text]
            log.info("  字符串 [%d] %r -> %r" % (idx, text, new_text))
            pool.strings[idx] = new_text
            changes.append((text, new_text))
    missing = set(strings) - {old for old, _ in changes}
    if missing:
        log.warn("以下替换规则没有匹配到: %s" % ", ".join(sorted(missing)))

    new_pool, delta = pool.rebuild()
    new_manifest = bytearray(manifest[:8]) + new_pool + manifest[8 + pool.old_size:]
    struct.pack_into("<I", new_manifest, 4, len(new_manifest))
    log.info("字符串池变化 %+d 字节, manifest 新大小 %d 字节" % (delta, len(new_manifest)))

    if ints:
        for name, old, new in _patch_ints(new_manifest, StringPool(bytes(new_manifest), 8), ints):
            log.info("  整数属性 %s: %d -> %d" % (name, old, new))
            changes.append(("%s=%d" % (name, old), "%s=%d" % (name, new)))

    with zipfile.ZipFile(dst_apk, "w", zipfile.ZIP_DEFLATED) as zf:
        for info, data in entries:
            payload = bytes(new_manifest) if info.filename == "AndroidManifest.xml" else data
            new_info = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            new_info.compress_type = info.compress_type
            new_info.external_attr = info.external_attr
            new_info.internal_attr = info.internal_attr
            new_info.create_system = info.create_system
            zf.writestr(new_info, payload)

    return changes, len(new_manifest)


def read_manifest_bytes(apk_path):
    """取出 APK 里的 AndroidManifest.xml 原始字节, 便于测试与校验."""
    with zipfile.ZipFile(apk_path) as zf:
        return zf.read("AndroidManifest.xml")


def load_rules(path):
    """读取 json 规则文件, 返回 (strings, ints)."""
    with open(path, encoding="utf-8") as fh:
        rules = json.load(fh)
    return rules.get("strings", {}), rules.get("ints", {})
