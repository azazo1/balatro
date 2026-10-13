"""LuaJIT v2.1 的 PRNG 与 Balatro 的 pseudoseed 的独立复刻 (抄自 C / Lua 源码).

用途: 当随机数的"真值来源". 本机装的 luajit 与 v2.1 源码在约 15% 的种子上不一致
(见 docs/rewrite/README.md), 所以不能拿它当基准; 这份复刻是照源码写的, 而且能复现
LuaJIT 自己写在 lj_prng.h 里的预计算常量, 所以可信.
"""
import struct, math
M64 = (1 << 64) - 1
PI = 3.14159265358979323846
E  = 2.7182818284590452354
STEPS = [(0, 63, 31, 18), (1, 58, 19, 28), (2, 55, 24, 7), (3, 47, 21, 8)]

def bits_of(x):
    return struct.unpack('<Q', struct.pack('<d', x))[0]

def f64_of(b):
    return struct.unpack('<d', struct.pack('<Q', b & M64))[0]

class Prng:
    def __init__(self, u): self.u = list(u)
    def step(self):
        r = 0
        for (i, k, q, s) in STEPS:
            z = self.u[i]
            mask = ((-1) & M64) << (64 - k) & M64
            z = ((((z << q) & M64) ^ z) >> (k - s)) ^ (((z & mask) << s) & M64)
            r ^= z
            self.u[i] = z
        return r & M64
    def u64d(self):
        return (self.step() & 0x000fffffffffffff) | 0x3ff0000000000000
    def draw(self):
        """math.random 的一颗: d in [0,1). 每次调用恰好消耗一颗 (见 math_random)."""
        return f64_of(self.u64d()) - 1.0
    def rand(self, r1, r2):
        d = self.draw()
        return math.floor(d * (r2 - r1 + 1.0)) + r1

def random_seed(d):
    u, r = [0, 0, 0, 0], 0x11090601
    for i in range(4):
        m = 1 << (r & 255); r >>= 8
        d = d * PI + E
        b = bits_of(d)
        if b < m: b += m
        u[i] = b & M64
    p = Prng(u)
    for _ in range(10): p.step()
    return p

def lua_mod(a, b):
    return a - math.floor(a / b) * b

def pseudohash(s):
    num = 1.0
    for i in range(len(s) - 1, -1, -1):
        num = lua_mod((1.1239285023 / num) * ord(s[i]) * math.pi + math.pi * (i + 1), 1.0)
    return num

class Game:
    """G.GAME.pseudorandom 那张表 + 一份全局 math.random 状态."""
    def __init__(self, seed):
        self.seed = seed
        self.hashed = pseudohash(seed)
        self.keys = {}
        self.prng = random_seed(0.0)   # 开局是 fixed seed, 与引擎一致
    def quantize13(self, x):
        return float('%.13f' % x)
    def pseudoseed(self, key):
        cur = self.keys.get(key, pseudohash(key + self.seed))
        adv = abs(self.quantize13(lua_mod(2.134453429141 + cur * 1.72431234, 1.0)))
        self.keys[key] = adv
        return (adv + self.hashed) / 2.0
    def pseudorandom(self, key):
        self.prng = random_seed(self.pseudoseed(key))
        return self.prng.draw()
    def pseudorandom_range(self, key, lo, hi):
        self.prng = random_seed(self.pseudoseed(key))
        return self.prng.rand(lo, hi)
    def math_random_range(self, lo, hi):
        """全局 math.random(lo,hi) —— 接着上一次播种后的位置继续."""
        return self.prng.rand(lo, hi)


def self_check():
    """复现 LuaJIT 写在 lj_prng.h 里的预计算常量 —— 算得对才算抄得对.

    这是这份复刻唯一的自证方式: 那个常量是 LuaJIT 自己算 `random_seed(rs, 0.0)` 得到的结果,
    与我这份实现的代码路径完全无关 (我照的是 lib_math.c).
    """
    expected = [0xa0d277570a345b8c, 0x764a296c5d4aa64f, 0x51220704070adeaa, 0x2a2717b5a7b7b927]
    got = random_seed(0.0).u
    assert got == expected, "random_seed(0.0) 与 lj_prng.h 的常量不一致:\n  得到 %s\n  期望 %s" % (
        [hex(x) for x in got], [hex(x) for x in expected])
    return True


if __name__ == "__main__":
    self_check()
    print("oracle 自检通过: random_seed(0.0) 复现了 lj_prng.h 里的预计算常量")
