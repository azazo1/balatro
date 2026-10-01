"""PNG 读写与缩放.

只用标准库实现, 不依赖 Pillow 等第三方库, 这样在 Windows 与 CI 上都能直接运行.

支持 8 位深度的灰度, 灰度加透明, RGB 与 RGBA 四种颜色类型, 覆盖图标源图的常见情况.
缩放采用区域平均 (box filter), 并在计算前做预乘处理, 避免透明边缘出现暗边.
macOS 应用图标另外提供圆角矩形遮罩, 只改 alpha, 源图像素风缩放仍走最近邻.
"""
import math
import struct
import zlib

PNG_SIG = b"\x89PNG\r\n\x1a\n"

# PNG 颜色类型到每像素字节数的映射, 只处理 8 位深度.
CHANNELS = {
    0: 1,  # 灰度
    2: 3,  # RGB
    4: 2,  # 灰度加透明
    6: 4,  # RGBA
}


class PngError(Exception):
    """PNG 解析或写入失败."""


def _paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter(raw, width, height, bpp, stride):
    """逐行还原 PNG 的过滤器, 返回紧凑的像素字节."""
    out = bytearray(height * stride)
    pos = 0
    for y in range(height):
        if pos >= len(raw):
            raise PngError("图像数据在第 %d 行处提前结束" % y)
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        if len(line) != stride:
            raise PngError("第 %d 行数据长度不足" % y)
        pos += stride
        prev = out[(y - 1) * stride:y * stride] if y > 0 else bytes(stride)
        if ftype == 0:
            pass
        elif ftype == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                upleft = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], upleft)) & 0xFF
        else:
            raise PngError("未知的过滤器类型: %d" % ftype)
        out[y * stride:(y + 1) * stride] = line
    return bytes(out)


def load_rgba(path):
    """读取 PNG, 返回 (宽, 高, RGBA 字节串)."""
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(PNG_SIG):
        raise PngError("%s 不是 PNG 文件" % path)

    pos = len(PNG_SIG)
    header = None
    idat = bytearray()
    palette = None
    transparency = None
    while pos + 8 <= len(data):
        length, ctype = struct.unpack_from(">I4s", data, pos)
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length  # 长度, 类型, 数据与 CRC
        if ctype == b"IHDR":
            header = struct.unpack(">IIBBBBB", chunk)
        elif ctype == b"PLTE":
            palette = chunk
        elif ctype == b"tRNS":
            transparency = chunk
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break

    if header is None:
        raise PngError("%s 缺少 IHDR" % path)
    width, height, depth, color_type, comp, filt, interlace = header
    if depth != 8:
        raise PngError("只支持 8 位深度的 PNG, %s 是 %d 位" % (path, depth))
    if interlace != 0:
        raise PngError("不支持隔行扫描的 PNG: %s" % path)
    if color_type not in CHANNELS:
        raise PngError("不支持的颜色类型 %d: %s" % (color_type, path))

    bpp = CHANNELS[color_type]
    stride = width * bpp
    pixels = _unfilter(zlib.decompress(bytes(idat)), width, height, bpp, stride)

    # 统一转换为 RGBA.
    rgba = bytearray(width * height * 4)
    if color_type == 6:
        return width, height, bytes(pixels)
    if color_type == 2:
        for i in range(width * height):
            rgba[i * 4] = pixels[i * 3]
            rgba[i * 4 + 1] = pixels[i * 3 + 1]
            rgba[i * 4 + 2] = pixels[i * 3 + 2]
            rgba[i * 4 + 3] = 255
        return width, height, bytes(rgba)
    if color_type == 0:
        for i in range(width * height):
            v = pixels[i]
            rgba[i * 4] = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
            rgba[i * 4 + 3] = 255
        return width, height, bytes(rgba)
    if color_type == 4:
        for i in range(width * height):
            v = pixels[i * 2]
            rgba[i * 4] = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
            rgba[i * 4 + 3] = pixels[i * 2 + 1]
        return width, height, bytes(rgba)

    # 调色板: 展开为 RGBA.
    if palette is None:
        raise PngError("%s 是索引色但没有 PLTE" % path)
    count = len(palette) // 3
    for i in range(width * height):
        idx = pixels[i]
        if idx >= count:
            raise PngError("调色板索引越界: %d" % idx)
        rgba[i * 4] = palette[idx * 3]
        rgba[i * 4 + 1] = palette[idx * 3 + 1]
        rgba[i * 4 + 2] = palette[idx * 3 + 2]
        rgba[i * 4 + 3] = transparency[idx] if transparency and idx < len(transparency) else 255
    return width, height, bytes(rgba)


def encode_png(width, height, rgba):
    """把 RGBA 数据编码为 PNG 字节串."""
    if len(rgba) != width * height * 4:
        raise PngError("像素数据长度与尺寸不符")

    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # 过滤器类型: 无
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (PNG_SIG + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def save_rgba(path, width, height, rgba):
    """把 RGBA 字节写为 PNG."""
    with open(path, "wb") as fh:
        fh.write(encode_png(width, height, rgba))


def resize_rgba(width, height, rgba, new_width, new_height, nearest=False):
    """把 RGBA 图像缩放到新尺寸.

    缩小用区域平均, 放大用最近邻. 平均前先按 alpha 预乘, 平均后再还原,
    这样透明边缘不会因为混入透明像素的黑色而发暗.

    像素风格的美术不该插值: 区域平均会把硬边抹成渐变, 因此这类图要传 nearest=True,
    全程取最近邻, 原图的色块边界能保持不变.
    """
    if (width, height) == (new_width, new_height):
        return rgba
    if new_width < 1 or new_height < 1:
        raise PngError("目标尺寸必须为正数")

    out = bytearray(new_width * new_height * 4)
    if new_width <= width and new_height <= height and not nearest:
        for dy in range(new_height):
            y0 = dy * height // new_height
            y1 = max(y0 + 1, (dy + 1) * height // new_height)
            for dx in range(new_width):
                x0 = dx * width // new_width
                x1 = max(x0 + 1, (dx + 1) * width // new_width)
                pr = pg = pb = pa = 0
                count = 0
                for y in range(y0, y1):
                    base = (y * width + x0) * 4
                    for x in range(x1 - x0):
                        i = base + x * 4
                        alpha = rgba[i + 3]
                        pr += rgba[i] * alpha
                        pg += rgba[i + 1] * alpha
                        pb += rgba[i + 2] * alpha
                        pa += alpha
                        count += 1
                o = (dy * new_width + dx) * 4
                if pa > 0:
                    out[o] = pr // pa
                    out[o + 1] = pg // pa
                    out[o + 2] = pb // pa
                    out[o + 3] = pa // count
                # 全透明像素保持默认的全零
    else:
        for dy in range(new_height):
            sy = min(height - 1, dy * height // new_height)
            for dx in range(new_width):
                sx = min(width - 1, dx * width // new_width)
                si = (sy * width + sx) * 4
                o = (dy * new_width + dx) * 4
                out[o:o + 4] = rgba[si:si + 4]
    return bytes(out)


def scaled_copy(src_path, dst_path, size, nearest=False):
    """读取源图, 缩放为 size x size 的正方形后写出."""
    width, height, rgba = load_rgba(src_path)
    out = resize_rgba(width, height, rgba, size, size, nearest)
    save_rgba(dst_path, size, size, out)


# 接近 iOS / macOS 图标模板的圆角半径 (228 / 1024).
ROUND_RECT_RATIO = 228 / 1024.0


def _round_rect_coverage(x, y, width, height, radius):
    """像素 (x, y) 落在圆角矩形内的覆盖率, 1 为完全在内, 0 为完全在外."""
    if radius <= 0:
        return 1.0
    cx = x + 0.5
    cy = y + 0.5
    if cx < radius and cy < radius:
        dist = math.hypot(cx - radius, cy - radius)
    elif cx > width - radius and cy < radius:
        dist = math.hypot(cx - (width - radius), cy - radius)
    elif cx < radius and cy > height - radius:
        dist = math.hypot(cx - radius, cy - (height - radius))
    elif cx > width - radius and cy > height - radius:
        dist = math.hypot(cx - (width - radius), cy - (height - radius))
    else:
        return 1.0
    return max(0.0, min(1.0, radius + 0.5 - dist))


def apply_round_rect_mask(width, height, rgba, radius_ratio=ROUND_RECT_RATIO):
    """给 RGBA 图像套一层抗锯齿圆角矩形遮罩, 四角变透明.

    在目标尺寸上切圆角, 而不是先切再缩放, 这样像素风色块仍走最近邻,
    只有外轮廓带一层平滑过渡. 完全透明的像素把 RGB 清零, 方便 PNG 压缩.
    """
    if len(rgba) != width * height * 4:
        raise PngError("像素数据长度与尺寸不符")
    if width < 1 or height < 1:
        raise PngError("目标尺寸必须为正数")
    radius = min(width, height) * float(radius_ratio)
    radius = min(radius, width / 2.0, height / 2.0)
    out = bytearray(rgba)
    for y in range(height):
        for x in range(width):
            cov = _round_rect_coverage(x, y, width, height, radius)
            if cov >= 1.0:
                continue
            i = (y * width + x) * 4
            if cov <= 0.0:
                out[i:i + 4] = b"\x00\x00\x00\x00"
                continue
            alpha = int(out[i + 3] * cov + 0.5)
            out[i + 3] = alpha
            if alpha == 0:
                out[i] = 0
                out[i + 1] = 0
                out[i + 2] = 0
    return bytes(out)
