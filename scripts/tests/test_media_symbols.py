"""核对 media 绑定层声明的 AMedia* 函数在真实 libmediandk.so 里确实存在.

起因: 真机点 "录制对局" 时报 `undefined symbol: AMediaCodecList_getCodecCount`.
AMediaCodecList 是 C++ 的类 (符号被 mangle), C 侧没有这个函数, 而 Lua 的
ffi.cdef 只是声明, 不校验, 只有真机上第一次调用才会撞上. 所以这里拿 NDK sysroot 里的
libmediandk.so 当基准, 逐条核对声明.

没有 NDK 时跳过 (开发机可能只装了 Android SDK 的一部分). 用 NDK 自带的 llvm-nm, 三个平台都能跑.
"""
import os
import re
import subprocess
import unittest

from lib import layout

FFI_LUA = os.path.join(layout.ROOT_DIR, "mods", "balatrobot", "agent", "record", "android", "ffi.lua")


def find_ndk():
    """按 ANDROID_NDK_HOME, ANDROID_HOME/ndk/<最新>, ~/Library/Android/sdk/ndk/<最新> 找 NDK."""
    explicit = os.environ.get("ANDROID_NDK_HOME")
    if explicit and os.path.isdir(explicit):
        return explicit

    def latest_under(parent):
        if not os.path.isdir(parent):
            return None
        names = [d for d in os.listdir(parent) if os.path.isdir(os.path.join(parent, d))]
        if not names:
            return None

        def key(name):
            return [int("".join(c for c in part if c.isdigit()) or 0) for part in name.split(".")]

        return os.path.join(parent, sorted(names, key=key)[-1])

    for parent in filter(None, [
        os.path.join(os.environ.get("ANDROID_HOME", ""), "ndk") if os.environ.get("ANDROID_HOME") else None,
        os.path.join(os.path.expanduser("~"), "Library", "Android", "sdk", "ndk"),
        os.path.join(os.path.expanduser("~"), "Android", "Sdk", "ndk"),
    ]):
        found = latest_under(parent)
        if found:
            return found
    return None


def find_libmediandk(ndk):
    """NDK sysroot 里的 libmediandk.so (链接用的存根, 动态符号与设备上一致)."""
    sysroot = os.path.join(ndk, "toolchains", "llvm", "prebuilt")
    for host in sorted(os.listdir(sysroot)) if os.path.isdir(sysroot) else []:
        arch_root = os.path.join(sysroot, host, "sysroot", "usr", "lib")
        if not os.path.isdir(arch_root):
            continue
        for arch in sorted(os.listdir(arch_root)):
            api_root = os.path.join(arch_root, arch)
            for api in sorted(os.listdir(api_root)):
                candidate = os.path.join(api_root, api, "libmediandk.so")
                if os.path.isfile(candidate):
                    return candidate, host
    return None, None


def declared_functions():
    """ffi.lua 的 CDECL 块里声明的 AMedia* 函数名 (注释里的引用不算)."""
    with open(FFI_LUA, encoding="utf-8") as handle:
        text = handle.read()
    start = text.index("local CDECL = [[")
    block = text[start:]
    block = block[: block.index("\n]]")]
    # 去掉行注释, 免得把注释里提到的类型名当成函数
    block = re.sub(r"//[^\n]*", "", block)
    return sorted(set(re.findall(r"\b(AMedia[A-Za-z_]+)\s*\(", block)))


class MediaSymbolsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ndk = find_ndk()
        cls.lib, cls.host = find_libmediandk(cls.ndk) if cls.ndk else (None, None)

    @unittest.skipUnless(find_ndk() is not None, "本机没有 Android NDK, 跳过符号核对")
    def test_every_declared_symbol_exists(self):
        self.assertIsNotNone(self.lib, "NDK 里找不到 libmediandk.so")
        nm = os.path.join(self.ndk, "toolchains", "llvm", "prebuilt", self.host, "bin", "llvm-nm")
        self.assertTrue(os.path.isfile(nm), "NDK 里找不到 llvm-nm: %s" % nm)

        output = subprocess.run(
            [nm, "-D", "--defined-only", self.lib],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True,
        ).stdout
        available = set()
        for line in output.splitlines():
            parts = line.split()
            if parts:
                available.add(parts[-1].split("@")[0])

        missing = [name for name in declared_functions() if name not in available]
        self.assertEqual(
            missing, [],
            "ffi.lua 声明了 libmediandk 里不存在的符号: %s (C++ 类方法不会被导出, 要改用 C 接口)"
            % ", ".join(missing),
        )

    def test_declarations_are_not_empty(self):
        self.assertGreater(len(declared_functions()), 20, "声明解析似乎失效了")


if __name__ == "__main__":
    unittest.main()
