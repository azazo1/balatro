//! 消耗槽里的一张牌.
//!
//! 为什么不是光一个键: 消耗牌**也带版本** —— 珀克奥 (传奇小丑) 在商店结束时会给一张
//! 消耗牌加上负片, 而开包 / 商店买到的那一张本身也可能带版本.
//! 只存键的话这些版本就没地方放, 对拍时那一格 (`c_earth+n`) 也就对不上.

use crate::cards::Edition;

/// 消耗槽里的一张牌.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Consumable {
    /// 原型键, 例如 `c_mercury`.
    pub key: String,
    pub edition: Option<Edition>,
}

impl Consumable {
    /// 没有版本的一张.
    pub fn plain(key: impl Into<String>) -> Self {
        Consumable {
            key: key.into(),
            edition: None,
        }
    }

    /// 带版本的一张.
    pub fn with_edition(key: impl Into<String>, edition: Option<Edition>) -> Self {
        Consumable {
            key: key.into(),
            edition,
        }
    }
}

impl From<&str> for Consumable {
    fn from(key: &str) -> Self {
        Consumable::plain(key)
    }
}

impl From<String> for Consumable {
    fn from(key: String) -> Self {
        Consumable::plain(key)
    }
}
