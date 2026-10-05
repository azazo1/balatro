//! 消耗槽里的一张牌.
//!
//! 为什么不是光一个键: 消耗牌**也带版本** —— 珀克奥 (传奇小丑) 在商店结束时会给一张
//! 消耗牌加上负片, 而开包 / 商店买到的那一张本身也可能带版本.
//! 只存键的话这些版本就没地方放, 对拍时那一格 (`c_earth+n`) 也就对不上.

use crate::cards::Edition;
use crate::data::catalog::Catalog;

use super::{ActionError, Phase, RunState};

/// 消耗槽里的一张牌.
#[derive(Clone, Debug, PartialEq)]
pub struct Consumable {
    /// 原型键, 例如 `c_mercury`.
    pub key: String,
    pub edition: Option<Edition>,
    /// 礼物卡累加的卖出价, 对应 `ability.extra_value`.
    pub extra_value: f64,
}

impl Consumable {
    /// 没有版本的一张.
    pub fn plain(key: impl Into<String>) -> Self {
        Consumable {
            key: key.into(),
            edition: None,
            extra_value: 0.0,
        }
    }

    /// 带版本的一张.
    pub fn with_edition(key: impl Into<String>, edition: Option<Edition>) -> Self {
        Consumable {
            key: key.into(),
            edition,
            extra_value: 0.0,
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

/// 消耗槽中卡牌的可用性, 对应 `Card:can_use_consumeable` 的稳定局面分支.
///
/// 动画中的锁由动作入口处理. 这里不推进随机数, 不写使用统计, 不消耗牌, 因而可以在
/// 原子执行之前先检查. 卡包和商店的卡必须另行检查来源区域的槽位, 不能当作已持有的卡.
pub fn validate_use(run: &RunState, index: usize, targets: &[usize]) -> Result<(), ActionError> {
    let card = run.consumables.get(index).ok_or(ActionError::BadIndex(index))?;
    let prototype = Catalog::get()
        .record(&card.key)
        .ok_or(ActionError::NotImplemented("未知消耗牌"))?;
    if !matches!(prototype.category.as_str(), "Tarot" | "Planet" | "Spectral") {
        return Err(ActionError::NotAllowed("这张牌不是消耗牌"));
    }
    let number = |field: &str| {
        prototype.config.as_ref().and_then(|config| config.get(field)).and_then(|value| value.as_f64())
    };
    let needs_hand = number("max_highlighted").is_some() || matches!(card.key.as_str(),
        "c_aura" | "c_familiar" | "c_grim" | "c_incantation" | "c_immolate" | "c_sigil" | "c_ouija");
    if needs_hand && !matches!(run.phase, Phase::SelectingHand | Phase::BoosterOpened) {
        return Err(ActionError::NotInPhase { expected: Phase::SelectingHand, actual: run.phase });
    }
    if let Some(limit) = number("max_highlighted") {
        let least = number("min_highlighted").unwrap_or(1.0) as usize;
        if targets.is_empty() && least > 0 {
            return Err(ActionError::NoCards);
        }
        if targets.len() < least {
            return Err(ActionError::TooFewCards { least, got: targets.len() });
        }
        if targets.len() > limit as usize {
            return Err(ActionError::TooManyCards { limit: limit as usize, got: targets.len() });
        }
        for (position, &target) in targets.iter().enumerate() {
            if target >= run.hand.len() {
                return Err(ActionError::BadIndex(target));
            }
            if targets[..position].contains(&target) {
                return Err(ActionError::NotAllowed("不能重复选择同一张牌"));
            }
        }
    }
    let has_editionless_joker = || run.jokers.iter().any(|joker| joker.edition.is_none());
    match card.key.as_str() {
        "c_aura" => {
            if targets.is_empty() {
                return Err(ActionError::NoCards);
            }
            if targets.len() > 1 {
                return Err(ActionError::TooManyCards { limit: 1, got: targets.len() });
            }
            let target = run.hand.get(targets[0]).ok_or(ActionError::BadIndex(targets[0]))?;
            if target.edition.is_some() {
                return Err(ActionError::NotAllowed("光环只能用于没有版本的牌"));
            }
        }
        "c_wheel_of_fortune" | "c_hex" | "c_ectoplasm" if !has_editionless_joker() => {
            return Err(ActionError::NotAllowed("没有可以添加版本的小丑"));
        }
        "c_ankh" if run.jokers.is_empty() || run.joker_capacity() <= 1
            || run.jokers.len() >= run.joker_capacity() => {
            return Err(ActionError::NotAllowed("生命十字章需要现有小丑及空闲复制槽位"));
        }
        "c_judgement" | "c_wraith" | "c_soul" if run.jokers.len() >= run.joker_capacity() => {
            return Err(ActionError::NotAllowed("没有空闲小丑槽位"));
        }
        "c_fool" if run.last_tarot_planet.as_deref().is_none_or(|last| last == "c_fool") => {
            return Err(ActionError::NotAllowed("没有可复制的上一次塔罗或行星"));
        }
        "c_familiar" | "c_grim" | "c_incantation" | "c_immolate" | "c_sigil" | "c_ouija"
            if run.hand.len() <= 1 => {
                return Err(ActionError::NotAllowed("这张幻灵牌需要至少两张手牌"));
            }
        _ => {}
    }
    Ok(())
}
