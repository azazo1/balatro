#!/usr/bin/env python3
"""校验 Windows 融合产物: PE 头完好, 且尾部确实带着可读取的游戏载荷.

单独成脚本是为了让 CI 与本机都能用同一条命令验证, 也避免把多行 python 嵌进
workflow 的 YAML 块标量里造成缩进问题.

用法:
    python3 scripts/verify_windows_bundle.py dist/windows/Balatro-1.0.1n-win64
"""
import io
import os
import sys
import zipfile

# love.exe 在官方 win64 发行包中的大小. 融合产物跳过这么多字节后应当是游戏 zip 的起点.
LOVE_EXE_SIZE = 387072
REQUIRED_DEPS = ("love.dll", "SDL2.dll", "OpenAL32.dll", "lua51.dll", "mpg123.dll")


def fail(message):
    print("校验失败: %s" % message, file=sys.stderr)
    raise SystemExit(1)


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    bundle = sys.argv[1]
    exe = os.path.join(bundle, "Balatro.exe")
    if not os.path.isfile(exe):
        fail("缺少 %s" % exe)
    for name in REQUIRED_DEPS:
        if not os.path.isfile(os.path.join(bundle, name)):
            fail("缺少依赖 %s" % name)

    with open(exe, "rb") as fh:
        data = fh.read()

    if data[:2] != b"MZ":
        fail("不是 PE 文件")
    if len(data) <= LOVE_EXE_SIZE:
        fail("文件不比 love.exe 大, 游戏载荷可能没有写入")

    tail = data[LOVE_EXE_SIZE:]
    if tail[:4] != b"PK\x03\x04":
        fail("偏移 %d 处不是 zip 起点, 实际为 %r" % (LOVE_EXE_SIZE, tail[:4]))

    try:
        with zipfile.ZipFile(io.BytesIO(tail)) as zf:
            names = set(zf.namelist())
            # 真正读一个文件, 确认数据未损坏而不只是目录能解析.
            sample = zf.read("version.jkr").decode("utf-8", errors="replace").strip()
    except zipfile.BadZipFile as exc:
        fail("尾部 zip 无法解析: %s" % exc)

    for need in ("main.lua", "conf.lua"):
        if need not in names:
            fail("载荷缺少 %s" % need)

    print("PE 头与游戏载荷校验通过")
    print("  载荷文件数: %d" % len(names))
    print("  内含版本标记: %s" % sample.splitlines()[0] if sample else "")
    print("  exe 总大小: %d 字节" % len(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
