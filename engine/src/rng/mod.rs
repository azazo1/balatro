//! 随机数.
//!
//! 分两层, 都对拍过真 LuaJIT:
//!
//! - [`luajit`]: LuaJIT 的 `math.random`, 即 TW223 加 `random_seed` 的种子扩展.
//! - [`balatro`]: 游戏的 `pseudohash` / `pseudoseed` 状态机与 `pseudoshuffle`.

pub mod balatro;
pub mod luajit;

pub use balatro::{pseudohash, Rng};
pub use luajit::Prng;
