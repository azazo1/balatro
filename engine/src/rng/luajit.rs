//! LuaJIT 2.1 的 `math.random` 复刻.
//!
//! 游戏的 `pseudorandom` 把 `pseudoseed` 算出的浮点数交给 `math.randomseed`, 整局的随机性都落在
//! LuaJIT 的 PRNG 上, 所以这一层必须逐位一致, 否则同一个种子抽不出同样的牌, 后面所有模块都无从对拍.
//!
//! 算法取自 LuaJIT 的 `src/lj_prng.c` 与 `src/lib_math.c`: TW223 (Tausworthe, 四个 64 位状态,
//! 周期 2^223), 以及 `random_seed` 的种子扩展.

use std::f64::consts::{E, PI};

/// TW223 的四路生成器参数: (状态下标, k, q, s).
const TW223_STEPS: [(usize, u32, u32, u32); 4] = [
    (0, 63, 31, 18),
    (1, 58, 19, 28),
    (2, 55, 24, 7),
    (3, 47, 21, 8),
];

/// `lj_prng_u64d` 取低 52 位并补上 [1, 2) 的指数位.
const U64D_MASK: u64 = 0x000f_ffff_ffff_ffff;
const U64D_ONE: u64 = 0x3ff0_0000_0000_0000;

/// LuaJIT 的 PRNG 状态. 对应游戏里全局的 `math.random`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prng {
    u: [u64; 4],
}

impl Default for Prng {
    fn default() -> Self {
        Self::fixed()
    }
}

impl Prng {
    /// `lj_prng_seed_fixed`: `random_seed(rs, 0.0)` 的预计算结果.
    pub fn fixed() -> Self {
        Prng {
            u: [
                0xa0d2_7757_0a34_5b8c,
                0x764a_296c_5d4a_a64f,
                0x5122_0704_070a_deaa,
                0x2a27_17b5_a7b7_b927,
            ],
        }
    }

    /// `random_seed`: `math.randomseed(d)`.
    ///
    /// `d` 每轮都被换成 `d * pi + e`, 再把这一轮的 double 位模式直接当作状态, 低 k 位为 0 时补上
    /// `1 << k`; 最后空转十次打散.
    pub fn seed(&mut self, mut d: f64) {
        let mut r: u32 = 0x1109_0601;
        for slot in self.u.iter_mut() {
            let m: u64 = 1u64 << (r & 255);
            r >>= 8;
            d = d * PI + E;
            let mut bits = d.to_bits();
            if bits < m {
                bits += m;
            }
            *slot = bits;
        }
        for _ in 0..10 {
            self.next_u64();
        }
    }

    /// `lj_prng_u64`.
    pub fn next_u64(&mut self) -> u64 {
        let mut r = 0u64;
        for &(i, k, q, s) in TW223_STEPS.iter() {
            let z = self.u[i];
            let z = (((z << q) ^ z) >> (k - s)) ^ ((z & (u64::MAX << (64 - k))) << s);
            self.u[i] = z;
            r ^= z;
        }
        r
    }

    /// `lj_prng_u64d`: 落在 [1, 2) 的 double.
    fn next_double(&mut self) -> f64 {
        f64::from_bits((self.next_u64() & U64D_MASK) | U64D_ONE)
    }

    /// `math.random()`: [0, 1).
    pub fn random(&mut self) -> f64 {
        self.next_double() - 1.0
    }

    /// `math.random(n)`: [1, n] 的整数. 返回 f64 是为了与 Lua 的数值语义一致.
    pub fn random_int(&mut self, n: f64) -> f64 {
        (self.random() * n).floor() + 1.0
    }

    /// `math.random(m, n)`: [m, n] 的整数.
    pub fn random_int_range(&mut self, m: f64, n: f64) -> f64 {
        (self.random() * (n - m + 1.0)).floor() + m
    }
}
