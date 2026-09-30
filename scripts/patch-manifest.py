#!/usr/bin/env python3
"""改写 APK 中二进制 AndroidManifest.xml 的字符串与整数属性.

Android 的二进制 XML 里, XML 节点通过字符串池的 *索引* 引用字符串, 而不是字节偏移,
所以重建字符串池并修好池内偏移之后, 长度不同的替换也是安全的.

用法:
    patch-manifest.py <输入 apk> <输出 apk> <规则 json>

规则 json 形如:
    {
      "strings": {"旧字符串": "新字符串"},
      "ints": {"screenOrientation": 5, "versionCode": 101}
    }

整数属性按属性名匹配, 只改写 XML 体里的值, 不改变长度.
"""
import json
import struct
import sys
import zipfile

RES_STRING_POOL = 0x0001
RES_XML_START_ELEMENT = 0x0102

UTF8_FLAG = 0x100
TYPE_INT_DEC = 0x10
TYPE_INT_HEX = 0x11

# 属性名在池中的索引无法预知, 但属性名本身是普通字符串, 直接按名字匹配.
INT_ATTR_NAMES = {"screenOrientation", "versionCode", "versionCodeMajor"}


def decode_utf8_string(buf, off):
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
    text = buf[o:o + length8].decode("utf-8", errors="surrogateescape")
    return text


def encode_utf8_string(text):
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
    out += raw
    out += b"\x00"
    return bytes(out)


def decode_utf16_string(buf, off):
    length, = struct.unpack_from("<H", buf, off)
    o = off + 2
    if length & 0x8000:
        length = ((length & 0x7FFF) << 16) | struct.unpack_from("<H", buf, o)[0]
        o += 2
    return buf[o:o + length * 2].decode("utf-16-le", errors="surrogateescape")


def encode_utf16_string(text):
    raw = text.encode("utf-16-le", errors="surrogateescape")
    length = len(raw) // 2
    out = bytearray()
    if length > 0x7FFF:
        out += struct.pack("<HH", (length >> 16) | 0x8000, length & 0xFFFF)
    else:
        out += struct.pack("<H", length)
    out += raw
    out += b"\x00\x00"
    return bytes(out)


class StringPool:
    def __init__(self, blob, off):
        type_, _header_size, size = struct.unpack_from("<HHI", blob, off)
        if type_ != RES_STRING_POOL:
            raise ValueError("偏移 %d 处不是字符串池 (type=0x%04X)" % (off, type_))
        (self.string_count, self.style_count, self.flags,
         self.strings_start, self.styles_start) = struct.unpack_from("<IIIII", blob, off + 8)
        self.utf8 = bool(self.flags & UTF8_FLAG)
        self.offsets = [struct.unpack_from("<I", blob, off + 28 + 4 * i)[0]
                        for i in range(self.string_count)]
        base = off + self.strings_start
        decode = decode_utf8_string if self.utf8 else decode_utf16_string
        self.strings = [decode(blob, base + o) for o in self.offsets]
        self.styles = blob[off + self.styles_start:off + size] if self.style_count else b""
        self.old_size = size

    def rebuild(self):
        """按当前 self.strings 重建池字节, 返回 (新池字节, 大小差)."""
        data = bytearray()
        new_offsets = []
        encode = encode_utf8_string if self.utf8 else encode_utf16_string
        for text in self.strings:
            new_offsets.append(len(data))
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
        for o in new_offsets:
            out += struct.pack("<I", o)
        for _ in range(self.style_count):
            out += struct.pack("<I", 0)
        out += data
        out += self.styles
        if len(out) != size:
            raise ValueError("重建后的池大小 %d 与声明 %d 不一致" % (len(out), size))
        return bytes(out), size - self.old_size


def patch_ints(blob, pool, int_rules):
    """遍历 XML 体, 就地改写指定属性名的整数值."""
    pos = 8 + pool.old_size
    patched = []
    while pos + 8 <= len(blob):
        type_, _hs, size = struct.unpack_from("<HHI", blob, pos)
        if size < 8:
            break
        if type_ == RES_XML_START_ELEMENT:
            # ResXMLTree_node 为 16 字节, 其后的 attrExt 里 ns/name 各占 4 字节,
            # 之后才是 attributeStart/attributeSize/attributeCount.
            ext = pos + 16
            attr_start, attr_size, attr_count = struct.unpack_from("<HHH", blob, ext + 8)
            for i in range(attr_count):
                a = ext + attr_start + i * attr_size
                _ns, name_idx, _raw = struct.unpack_from("<III", blob, a)
                val = a + 12
                _v_size, _res0, v_type, v_data = struct.unpack_from("<HBBI", blob, val)
                if name_idx >= len(pool.strings):
                    continue
                name = pool.strings[name_idx]
                if name in int_rules and v_type in (TYPE_INT_DEC, TYPE_INT_HEX):
                    struct.pack_into("<I", blob, val + 4, int_rules[name])
                    patched.append((name, v_data, int_rules[name]))
        pos += size
    return patched


def main():
    if len(sys.argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src_apk, dst_apk, rules_path = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(rules_path, encoding="utf-8") as fh:
        rules = json.load(fh)
    str_rules = rules.get("strings", {})
    int_rules = {k: v for k, v in rules.get("ints", {}).items() if k in INT_ATTR_NAMES}

    with zipfile.ZipFile(src_apk) as zin:
        entries = [(i, zin.read(i.filename)) for i in zin.infolist()]

    manifest = None
    for info, data in entries:
        if info.filename == "AndroidManifest.xml":
            manifest = bytearray(data)
    if manifest is None:
        print("错误: 输入 APK 里没有 AndroidManifest.xml", file=sys.stderr)
        return 1

    pool = StringPool(bytes(manifest), 8)
    print("字符串池: %d 项, 编码 %s, 原大小 %d 字节"
          % (pool.string_count, "UTF-8" if pool.utf8 else "UTF-16", pool.old_size))

    changed = 0
    for idx, text in enumerate(pool.strings):
        if text in str_rules:
            print("  字符串 [%d] %r -> %r" % (idx, text, str_rules[text]))
            pool.strings[idx] = str_rules[text]
            changed += 1
    if str_rules and changed != len(str_rules):
        missing = set(str_rules) - {t for t in str_rules if t in set(pool.strings)}
        print("  警告: 以下规则未匹配到: %s" % ", ".join(sorted(missing)), file=sys.stderr)

    new_pool, delta = pool.rebuild()
    new_manifest = bytearray(manifest[:8]) + new_pool + manifest[8 + pool.old_size:]
    struct.pack_into("<I", new_manifest, 4, len(new_manifest))
    print("池大小变化: %+d 字节, manifest 新大小 %d" % (delta, len(new_manifest)))

    if int_rules:
        for name, old, new in patch_ints(new_manifest, StringPool(bytes(new_manifest), 8), int_rules):
            print("  整数属性 %s: %d -> %d" % (name, old, new))

    with zipfile.ZipFile(dst_apk, "w", zipfile.ZIP_DEFLATED) as zout:
        for info, data in entries:
            payload = bytes(new_manifest) if info.filename == "AndroidManifest.xml" else data
            zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zi.internal_attr = info.internal_attr
            zi.create_system = info.create_system
            zout.writestr(zi, payload)
    print("已写出 %s" % dst_apk)
    return 0


if __name__ == "__main__":
    sys.exit(main())
