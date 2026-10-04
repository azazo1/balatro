//! 几个测试文件共用的构造辅助.
//!
//! 放在子目录里, cargo 不会把它当成一个独立的测试目标, 各测试文件用 `mod common;` 引入.

#![allow(dead_code)]

use std::collections::HashMap;

use balatro_engine::cards::{PlayingCard, Rank, Suit};
use balatro_engine::run::RunState;
use balatro_engine::scoring::HandCard;

/// 存档进度快照, 格式与回放文件 `snapshot.uda` 的值相同.
///
/// 内容取自 `recordings/20261003-224812-ALEEB/` 那一局的 `snapshot.uda`. `recordings/` 不入库,
/// 所以这里存一份快照; 重新生成的办法见 `docs/rewrite/README.md`.
const UDA_TSV: &str = include_str!("../data/aleeb-uda.tsv");

/// 从 ALEEB 的存档进度快照里读出 `原型键 -> "u"/"d"/"a" 标记`.
pub fn aleeb_uda() -> HashMap<String, String> {
    let mut uda = HashMap::new();
    for line in UDA_TSV.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        if let Some((key, flags)) = line.split_once('\t') {
            uda.insert(key.to_owned(), flags.to_owned());
        }
    }
    assert!(uda.len() > 300, "存档进度快照看起来不完整");
    uda
}

/// 种子 ALEEB, 等离子牌组, 黄金赌注 (stake 8), 还没开局.
///
/// 等离子牌组的 `ante_scaling` 是 2, 所以它的盲注目标是标准牌组的两倍.
pub fn aleeb_run() -> RunState {
    RunState::new("ALEEB", 8)
        .with_deck_scaling(2.0)
        .with_uda(aleeb_uda())
}

/// 写 `C_5` 或 `C5` 都认, 前者是游戏里的原型键写法.
pub fn card(code: &str) -> HandCard {
    HandCard::plain(instance(code))
}

/// 一张没有修饰的牌实例.
pub fn instance(code: &str) -> PlayingCard {
    let mut chars = code.chars();
    let suit = match chars.next().expect("花色") {
        'C' => Suit::Clubs,
        'D' => Suit::Diamonds,
        'H' => Suit::Hearts,
        'S' => Suit::Spades,
        other => panic!("未知花色 {other}"),
    };
    let rank_code: String = chars.filter(|c| *c != '_').collect();
    let rank = match rank_code.as_str() {
        "2" => Rank::Two,
        "3" => Rank::Three,
        "4" => Rank::Four,
        "5" => Rank::Five,
        "6" => Rank::Six,
        "7" => Rank::Seven,
        "8" => Rank::Eight,
        "9" => Rank::Nine,
        "T" => Rank::Ten,
        "J" => Rank::Jack,
        "Q" => Rank::Queen,
        "K" => Rank::King,
        "A" => Rank::Ace,
        other => panic!("未知点数 {other}"),
    };
    PlayingCard {
        suit,
        rank,
        sort_id: 0,
    }
}

/// 一串牌.
pub fn hand(codes: &[&str]) -> Vec<HandCard> {
    codes.iter().map(|c| card(c)).collect()
}

/// 手牌的牌面列表, 用 `,` 连起来, 便于与 digest 里的 `hand=` 段对比.
pub fn hand_keys(run: &RunState) -> String {
    run.hand
        .iter()
        .map(|c| c.card.key())
        .collect::<Vec<_>>()
        .join(",")
}

/// 消耗槽里的键 (不带版本) —— 断言时通常只关心"是哪张".
pub fn consumable_keys(run: &balatro_engine::run::RunState) -> Vec<String> {
    run.consumables.iter().map(|card| card.key.clone()).collect()
}
