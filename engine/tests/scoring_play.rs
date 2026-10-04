//! 一次出牌的计分与真游戏对拍.
//!
//! 目标取自 `recordings/20261003-224812-ALEEB/` 的第 2 步. 那一步的解说里写明了真值:
//!
//! ```text
//! 打顺子: 70 筹码 x 4.0 倍率, 等离子平衡成 37 x 37 ≈ 1369
//! ```
//!
//! 手牌是 `C_T,D_T,S_9,D_8,S_7,H_6,C_4,H_2`, 打出的顺子是 `6,7,8,9,T` 五张. 顺子基础
//! 30 筹码 × 4 倍率, 加上五张牌的点数 6+7+8+9+10=40, 得到 70. 等离子牌组把两者平均成 37,
//! 于是 37 × 37 = 1369.

use balatro_engine::cards::{PlayingCard, Rank, Suit};
use balatro_engine::scoring::{BackEffect, EvalEnv, HandCard, HandTable, PokerHand, score_play};

/// 写 `C_5` 或 `C5` 都认, 前者是游戏里的原型键写法.
fn card(code: &str) -> HandCard {
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
    HandCard::plain(PlayingCard {
        suit,
        rank,
        sort_id: 0,
        original_suit: suit,
    })
}

#[test]
fn aleeb_first_play_matches_the_replay() {
    // 第 1 步弃牌后的手牌, 按游戏里的手牌顺序 (nominal 降序) 排列.
    let hand = ["C_T", "D_T", "S_9", "D_8", "S_7", "H_6", "C_4", "H_2"]
        .map(card);

    // 打出的顺子 6,7,8,9,T, 按手牌从左到右的顺序取出.
    let played = [hand[5], hand[4], hand[3], hand[2], hand[0]];

    let table = HandTable::new();
    let result = score_play(&played, &table, &EvalEnv::default(), BackEffect::Plasma, &mut [])
        .expect("这手牌能识别出牌型");

    assert_eq!(result.hand, PokerHand::Straight);
    assert_eq!(result.base_chips, 30.0, "顺子的基础筹码");
    assert_eq!(result.base_mult, 4.0, "顺子的基础倍率");
    assert_eq!(result.scoring_cards.len(), 5, "五张牌全在顺子里");

    let raw_chips: f64 = played.iter().map(HandCard::chip_bonus).sum();
    assert_eq!(raw_chips, 40.0, "6+7+8+9+10");
    assert_eq!(result.chips, 37.0, "等离子把 70 与 4 平均成 37");
    assert_eq!(result.mult, 37.0);
    assert_eq!(result.total, 1369.0, "37 * 37");
}

#[test]
fn without_the_plasma_deck_the_numbers_stay_apart() {
    let played = ["H_6", "S_7", "D_8", "S_9", "C_T"].map(card);
    let table = HandTable::new();
    let result = score_play(&played, &table, &EvalEnv::default(), BackEffect::Plain, &mut [])
        .expect("这手牌能识别出牌型");

    assert_eq!(result.chips, 70.0, "30 基础加 40 点数");
    assert_eq!(result.mult, 4.0);
    assert_eq!(result.total, 280.0);
}

#[test]
fn only_the_scoring_cards_add_chips() {
    // 一对 5 加三张垫牌: 垫牌不计分, 但仍在打出的牌里.
    let played = ["C_5", "D_5", "H_2", "S_9", "C_K"].map(card);
    let table = HandTable::new();
    let result = score_play(&played, &table, &EvalEnv::default(), BackEffect::Plain, &mut [])
        .expect("这手牌能识别出牌型");

    assert_eq!(result.hand, PokerHand::Pair);
    assert_eq!(result.scoring_cards, vec![0, 1], "只有那张对子计分");
    // 对子基础 10 筹码, 两张 5 共 10 点.
    assert_eq!(result.chips, 20.0);
    assert_eq!(result.mult, 2.0);
    assert_eq!(result.total, 40.0);
}

#[test]
fn debuffed_cards_score_nothing() {
    let mut played = ["H_6", "S_7", "D_8", "S_9", "C_T"].map(card);
    played[2].debuffed = true; // 方片 8 被 Boss 削弱

    let table = HandTable::new();
    let result = score_play(&played, &table, &EvalEnv::default(), BackEffect::Plain, &mut [])
        .expect("这手牌能识别出牌型");

    assert_eq!(result.hand, PokerHand::Straight, "被削弱的牌仍参与牌型识别");
    assert_eq!(result.chips, 30.0 + 6.0 + 7.0 + 9.0 + 10.0, "少掉那一张的 8 点");
}

#[test]
fn a_higher_level_raises_the_base() {
    let mut table = HandTable::new();
    table.level_up(PokerHand::Straight, 1); // 用一张土星牌

    let played = ["H_6", "S_7", "D_8", "S_9", "C_T"].map(card);
    let result = score_play(&played, &table, &EvalEnv::default(), BackEffect::Plain, &mut [])
        .expect("这手牌能识别出牌型");

    // 顺子每级 +30 筹码 +3 倍率.
    assert_eq!(result.chips, 60.0 + 40.0);
    assert_eq!(result.mult, 7.0);
}

/// 牌上的**版本**在它自己那份之后结算: 闪箔加筹码, 镭射加倍率, 多彩乘倍率.
///
/// 数值取自原型 (`e_foil` 是 50, `e_holo` 是 10, `e_polychrome` 是 1.5).
/// 负片只加小丑格子数, 计分上没有东西.
#[test]
fn card_editions_add_their_share() {
    use balatro_engine::cards::Edition;

    let table = HandTable::new();
    let with = |edition: Option<Edition>| -> (f64, f64) {
        let mut played = [card("C_5"), card("D_5")];
        played[0].edition = edition;
        let r = score_play(&played, &table, &EvalEnv::default(), BackEffect::Plain, &mut [])
            .expect("对子能识别");
        (r.chips, r.mult)
    };

    // 基础: 对子 10 + 5 + 5 = 20 筹码, 2 倍率.
    assert_eq!(with(None), (20.0, 2.0), "没有版本时是干净的");

    assert_eq!(with(Some(Edition::Foil)), (20.0 + 50.0, 2.0), "闪箔加筹码");
    assert_eq!(with(Some(Edition::Holo)), (20.0, 2.0 + 10.0), "镭射加倍率");
    assert_eq!(
        with(Some(Edition::Polychrome)),
        (20.0, 2.0 * 1.5),
        "多彩乘倍率"
    );
    assert_eq!(with(Some(Edition::Negative)), (20.0, 2.0), "负片不计分");

    // 留在**手里**的牌不算版本 —— 只有参与计分的那张算.
    let mut held = card("H_7");
    held.edition = Some(Edition::Foil);
    let played = [card("C_5"), card("D_5")];
    let r = balatro_engine::scoring::score_play_with_held(
        &played,
        &[held],
        &table,
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut [],
    )
    .expect("对子能识别");
    assert_eq!(r.chips, 20.0, "手里的牌不给版本加成");
}
