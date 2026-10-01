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

# 声明文本在 cdef.lua (主线程与编码线程共用一份), 不在 ffi.lua 里.
CDEF_LUA = os.path.join(layout.ROOT_DIR, "mods", "balatrobot", "agent", "record", "android", "cdef.lua")
# 通过 ffi.load 拿到命名空间后按 media./net./ffi.C. 调用原生函数的文件.
FFI_USERS = [
    os.path.join(layout.ROOT_DIR, "mods", "balatrobot", "agent", "record", "android", "encoder_thread.lua"),
    os.path.join(layout.ROOT_DIR, "mods", "balatrobot", "agent", "record", "android", "backend.lua"),
    os.path.join(layout.ROOT_DIR, "mods", "balatrobot", "agent", "net", "bbnet.lua"),
]


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
    """cdef.lua 的 CDECL 块里声明的 AMedia* 函数名 (注释里的引用不算)."""
    with open(CDEF_LUA, encoding="utf-8") as handle:
        text = handle.read()
    start = text.index("M.CDECL = [[")
    block = text[start:]
    # 声明块以 ]] 结束 (可能带缩进); 声明文本里不会出现 ]]
    block = block[: block.index("]]")]
    # 去掉行注释, 免得把注释里提到的类型名当成函数
    block = re.sub(r"//[^\n]*", "", block)
    return sorted(set(re.findall(r"\b(AMedia[A-Za-z_]+)\s*\(", block)))


def declared_names():
    """cdef.lua 里声明的所有函数名 (介不介意命名空间, 一律收)."""
    with open(CDEF_LUA, encoding="utf-8") as handle:
        text = handle.read()
    block = text[text.index("M.CDECL = [[") :]
    block = block[: block.index("]]")]
    block = re.sub(r"//[^\n]*", "", block)
    # 函数声明形如 `返回值 名字(`; 结构体定义里的字段不会带括号.
    return set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", block))


# 原生符号的命名特征: Android 媒体库的 AMedia*, bbnet 的 bbnet_*, 以及库里的其他 C 函数.
# 只收这些前缀, 免得把 media.probe 这类本模块自己的 Lua 接口算进来.
NATIVE_PREFIXES = ("AMedia", "bbnet_", "android_")


def used_native_symbols():
    """各文件里对 media.*, net.*, ffi.C.* 的调用 (键是符号名, 值是出现它的文件)."""
    uses = {}
    for path in FFI_USERS:
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        text = re.sub(r"--[^\n]*", "", text)  # 去掉行注释
        for name in re.findall(r"\b(?:media|net|ffi\.C)\.([A-Za-z_][A-Za-z0-9_]*)", text):
            if name.startswith(NATIVE_PREFIXES):
                uses.setdefault(name, set()).add(os.path.basename(path))
    return uses


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
            "cdef.lua 声明了 libmediandk 里不存在的符号: %s (C++ 类方法不会被导出, 要改用 C 接口)"
            % ", ".join(missing),
        )

    def test_declarations_are_not_empty(self):
        self.assertGreater(len(declared_functions()), 20, "声明解析似乎失效了")

    def test_every_used_symbol_is_declared(self):
        """用了但没声明的符号: ffi.cdef 只声明不校验, 这类错误要到真机第一次调用才炸.

        真机上报过的 "missing declaration for symbol 'bbnet_nv12_size'" 就是这一种:
        编码线程用了 bbnet 的换算函数, 而 cdef.lua 里只声明了 mediandk 的部分.
        """
        declared = declared_names()
        missing = {
            name: sorted(files)
            for name, files in used_native_symbols().items()
            if name not in declared
        }
        self.assertEqual(
            missing, {},
            "这些原生符号被调用但没有在 cdef.lua 里声明: %s"
            % "; ".join("%s (%s)" % (name, ", ".join(files)) for name, files in sorted(missing.items())),
        )

    def test_bbnet_declarations_match_the_real_library(self):
        """cdef.lua 里声明的 bbnet_* 符号要与 libbbnet 的导出一致."""
        lib = os.path.join(layout.ROOT_DIR, "mods", "balatrobot", "native", "macos", "libbbnet.dylib")
        if not os.path.isfile(lib):
            self.skipTest("还没编译 macos 版 bbnet (just native build macos)")
        output = subprocess.run(
            ["nm", "-gU", lib], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True,
        ).stdout
        exported = set()
        for line in output.splitlines():
            parts = line.split()
            if parts:
                exported.add(parts[-1].lstrip("_"))
        declared_bbnet = {name for name in declared_names() if name.startswith("bbnet_")}
        self.assertGreater(len(declared_bbnet), 0, "cdef.lua 里应该有 bbnet_* 的声明")
        self.assertEqual(sorted(declared_bbnet - exported), [], "声明的 bbnet_* 在库里不存在")


if __name__ == "__main__":
    unittest.main()
