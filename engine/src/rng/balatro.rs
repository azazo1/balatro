//! 游戏的伪随机状态机: `pseudohash`, `pseudoseed`, `pseudorandom`, `pseudoshuffle`.
//!
//! 抄自 `game/functions/misc_functions.lua` 与 `game/cardarea.lua` 的 `CardArea:shuffle`.
//!
//! 有一点必须注意: `pseudoseed` 对同一个 key 是递推的, 第 N 次调用依赖前 N-1 次的结果.
//! 所以每个 key 被调用的次数也要与真游戏一致, 否则同一个种子从某一手起就会岔开.

use std::collections::HashMap;
use std::f64::consts::PI;

use super::luajit::Prng;

/// Lua 的 `%`: 结果与右操作数同号, 恒非负, 等价于 `a - floor(a/b)*b`.
fn lua_mod(a: f64, b: f64) -> f64 {
    a - (a / b).floor() * b
}

/// `tonumber(string.format("%.13f", x))`: 按 13 位小数量化.
fn quantize13(x: f64) -> f64 {
    format!("{:.13}", x).parse().unwrap_or(x)
}

/// `pseudohash`: 从字符串尾部往前迭代的浮点哈希.
pub fn pseudohash(s: &str) -> f64 {
    let bytes = s.as_bytes();
    let mut num = 1.0f64;
    for i in (0..bytes.len()).rev() {
        let ord = f64::from(bytes[i]);
        let pos = (i + 1) as f64; // Lua 的下标从 1 起
        num = lua_mod((1.1239285023 / num) * ord * PI + PI * pos, 1.0);
    }
    num
}

/// 一局的随机源: 对应游戏里全局的 `math.random` 状态与 `G.GAME.pseudorandom` 表.
///
/// 游戏里 `math.random` 是一份全局状态, `pseudorandom` 每次都会先 `math.randomseed` 再取一个,
/// 所以两者放在一起. 快照与回滚要连这个结构一起带走.
#[derive(Clone, Debug)]
pub struct Rng {
    prng: Prng,
    seed: String,
    hashed_seed: f64,
    keys: HashMap<String, f64>,
}

impl Rng {
    /// 按开局参数里的种子初始化, 对应 `G.GAME.pseudorandom.seed` 与 `.hashed_seed`.
    pub fn new(seed: &str) -> Self {
        Rng {
            prng: Prng::fixed(),
            seed: seed.to_owned(),
            hashed_seed: pseudohash(seed),
            keys: HashMap::new(),
        }
    }

    pub fn seed_str(&self) -> &str {
        &self.seed
    }

    pub fn hashed_seed(&self) -> f64 {
        self.hashed_seed
    }

    /// 当前全局 PRNG 的下一颗 [0, 1). 用于核对内部状态.
    pub fn peek_prng(&self) -> &Prng {
        &self.prng
    }

    /// `pseudoseed(key)`: 推进这个 key 的递推值, 返回交给 `math.randomseed` 的浮点数.
    pub fn pseudoseed(&mut self, key: &str) -> f64 {
        if key == "seed" {
            return self.random();
        }
        let current = match self.keys.get(key) {
            Some(v) => *v,
            None => pseudohash(&format!("{key}{}", self.seed)),
        };
        let advanced = quantize13(lua_mod(2.134453429141 + current * 1.72431234, 1.0)).abs();
        self.keys.insert(key.to_owned(), advanced);
        (advanced + self.hashed_seed) / 2.0
    }

    /// `math.randomseed(v)`.
    pub fn seed_prng(&mut self, v: f64) {
        self.prng.seed(v);
    }

    /// 全局的 `math.random()`.
    pub fn random(&mut self) -> f64 {
        self.prng.random()
    }

    /// 全局的 `math.random(n)`.
    pub fn random_int(&mut self, n: f64) -> f64 {
        self.prng.random_int(n)
    }

    /// 全局的 `math.random(m, n)`.
    pub fn random_int_range(&mut self, m: f64, n: f64) -> f64 {
        self.prng.random_int_range(m, n)
    }

    /// `pseudorandom(key)`: 用这个 key 取一个 [0, 1).
    pub fn pseudorandom(&mut self, key: &str) -> f64 {
        let s = self.pseudoseed(key);
        self.prng.seed(s);
        self.prng.random()
    }

    /// `pseudorandom(key, min, max)`: 用这个 key 取一个 [min, max] 的整数.
    pub fn pseudorandom_int_range(&mut self, key: &str, min: f64, max: f64) -> f64 {
        let s = self.pseudoseed(key);
        self.prng.seed(s);
        self.prng.random_int_range(min, max)
    }

    /// `pseudoshuffle(list, pseudoseed(key))`: 从尾往前做一次 Fisher-Yates.
    ///
    /// 游戏在这之前会按 `sort_id` 排序, 那一步由调用方负责.
    pub fn pseudoshuffle<T>(&mut self, list: &mut [T], key: &str) {
        let s = self.pseudoseed(key);
        self.prng.seed(s);
        for i in (1..list.len()).rev() {
            // Lua 侧是 math.random(i+1), 即 [1, i+1], 这里取 0 基的同一颗.
            let j = (self.prng.random() * (i as f64 + 1.0)).floor() as usize;
            list.swap(i, j);
        }
    }

    /// `pseudorandom_element(list, seed)` 里"取第几个"这一步, 下标从 0 起.
    ///
    /// 游戏那个函数先把元素按 key 排序再取; 候选池是数组, 键就是 `1..=n`, 排序后仍是原顺序,
    /// 所以对池子而言它就是 `math.random(n)`. 对哈希表形态的入参则不适用.
    pub fn pick_index(&mut self, len: usize, seed: f64) -> usize {
        self.prng.seed(seed);
        let index = (self.prng.random() * len as f64).floor() as usize;
        index.min(len.saturating_sub(1))
    }

    /// `pseudorandom_element(list, pseudoseed(key))`: 用这个 key 从等长列表里取一项.
    pub fn pick<'a, T>(&mut self, list: &'a [T], key: &str) -> &'a T {
        let seed = self.pseudoseed(key);
        let index = self.pick_index(list.len(), seed);
        &list[index]
    }
}
