//! 牌型等级与基础值.
//!
//! 期望值来自牌型基础值表与 Steamodded 的 upgrade_poker_hands 实现.

use balatro_engine::scoring::{HandTable, PokerHand};

#[test]
fn level_one_uses_the_starting_values() {
    let table = HandTable::new();
    for hand in PokerHand::BY_PRIORITY {
        let info = hand.info();
        let entry = table.get(hand);
        assert_eq!(entry.level, 1);
        assert_eq!(entry.chips(hand), info.s_chips, "{} 的初始筹码", info.key);
        assert_eq!(entry.mult(hand), info.s_mult, "{} 的初始倍率", info.key);
    }
}

#[test]
fn each_level_adds_the_growth_step() {
    let mut table = HandTable::new();
    table.level_up(PokerHand::Flush, 2);
    let entry = table.get(PokerHand::Flush);
    assert_eq!(entry.level, 3);
    assert_eq!(entry.chips(PokerHand::Flush), 35.0 + 15.0 * 2.0);
    assert_eq!(entry.mult(PokerHand::Flush), 4.0 + 2.0 * 2.0);
}

#[test]
fn modded_level_zero_preserves_the_unclamped_growth_values() {
    let mut table = HandTable::new();
    // Steamodded 直接按等级步长增减, 不沿用原版的筹码与倍率钳制.
    table.level_up(PokerHand::HighCard, -1);
    let entry = table.get(PokerHand::HighCard);
    assert_eq!(entry.level, 0);
    assert_eq!(entry.chips(PokerHand::HighCard), -5.0);
    assert_eq!(entry.mult(PokerHand::HighCard), 0.0);
}

#[test]
fn upgrades_accumulate_from_the_base_not_from_the_current_value() {
    let mut table = HandTable::new();
    table.level_up(PokerHand::Straight, 1);
    table.level_up(PokerHand::Straight, 1);
    table.level_up(PokerHand::Straight, 1);
    let entry = table.get(PokerHand::Straight);
    assert_eq!(entry.level, 4);
    assert_eq!(entry.chips(PokerHand::Straight), 30.0 + 30.0 * 3.0);
    assert_eq!(entry.mult(PokerHand::Straight), 4.0 + 3.0 * 3.0);
}

#[test]
fn hidden_hands_turn_visible_once_played() {
    let mut table = HandTable::new();
    assert!(!table.get(PokerHand::FlushFive).visible);
    assert!(!table.get(PokerHand::FlushHouse).visible);
    assert!(!table.get(PokerHand::FiveOfAKind).visible);
    assert!(table.get(PokerHand::Flush).visible);

    table.record_played(PokerHand::FlushFive);
    assert!(table.get(PokerHand::FlushFive).visible);
    assert_eq!(table.get(PokerHand::FlushFive).played, 1);
    assert_eq!(table.get(PokerHand::FlushFive).played_this_round, 1);
}

/// 新回合只清"本回合"的计数, 本局累计的 `played` 留着 —— 超新星与牛看的是后者.
#[test]
fn a_new_round_clears_only_the_this_round_counts() {
    let mut table = HandTable::new();
    table.record_played(PokerHand::Flush);
    table.record_played(PokerHand::Flush);
    table.record_played(PokerHand::Pair);
    assert_eq!(table.get(PokerHand::Flush).played_this_round, 2);

    table.reset_round();

    assert_eq!(table.get(PokerHand::Flush).played_this_round, 0, "同花清零");
    assert_eq!(table.get(PokerHand::Pair).played_this_round, 0, "对子也清零");
    assert_eq!(table.get(PokerHand::Flush).played, 2, "本局累计不动");
    assert_eq!(table.get(PokerHand::Pair).played, 1, "本局累计不动");
    assert_eq!(table.most_played(), PokerHand::Flush, "最常打的那手不受影响");
}
