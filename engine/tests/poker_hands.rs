//! 牌型判定.
//!
//! 用例取自 `docs/game/rules/poker-hands.md`: 四指的复合牌型, 捷径的间隔规则, A 的两端与不环绕,
//! 包含回填, 石头牌与万能牌, 模糊小丑.

use balatro_engine::cards::{PlayingCard, Rank, Suit};
use balatro_engine::scoring::{EvalEnv, HandCard, PokerHand, evaluate_poker_hand};

fn card(code: &str) -> HandCard {
    let mut chars = code.chars();
    let suit = match chars.next().expect("花色") {
        'C' => Suit::Clubs,
        'D' => Suit::Diamonds,
        'H' => Suit::Hearts,
        'S' => Suit::Spades,
        other => panic!("未知花色 {other}"),
    };
    let rank = match &code[1..] {
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
    })
}

fn hand(codes: &[&str]) -> Vec<HandCard> {
    codes.iter().map(|c| card(c)).collect()
}

#[test]
fn plain_hands_pick_the_highest_priority() {
    let env = EvalEnv::default();
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "D2", "H5", "S9", "CK"]), &env).top(),
        Some(PokerHand::Pair)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "D2", "H5", "S5", "CK"]), &env).top(),
        Some(PokerHand::TwoPair)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "D2", "H2", "S5", "CK"]), &env).top(),
        Some(PokerHand::ThreeOfAKind)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "D2", "H2", "S5", "C5"]), &env).top(),
        Some(PokerHand::FullHouse)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "D2", "H2", "S2", "C5"]), &env).top(),
        Some(PokerHand::FourOfAKind)
    );
    // 五张同花, 但不是顺子.
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "C5", "C7", "C9", "CK"]), &env).top(),
        Some(PokerHand::Flush)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "D3", "H4", "S5", "C6"]), &env).top(),
        Some(PokerHand::Straight)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "C3", "H4", "S5", "C6"]), &env).top(),
        Some(PokerHand::Straight)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "C3", "C4", "C5", "C6"]), &env).top(),
        Some(PokerHand::StraightFlush)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "D5", "H7", "S9", "CJ"]), &env).top(),
        Some(PokerHand::HighCard)
    );
}

#[test]
fn short_hands_still_form_their_hand() {
    let env = EvalEnv::default();
    // 出牌不要求凑满 5 张.
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "D2"]), &env).top(),
        Some(PokerHand::Pair)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2"]), &env).top(),
        Some(PokerHand::HighCard)
    );
}

#[test]
fn four_fingers_merges_flush_and_straight_groups() {
    // 黑桃 3,6,8,9 是 4 张同花, 6,7,8,9 是 4 个连续点数 (含红桃 7).
    let cards = hand(&["S3", "S6", "S8", "S9", "H7"]);
    let plain = evaluate_poker_hand(&cards, &EvalEnv::default());
    assert_ne!(plain.top(), Some(PokerHand::StraightFlush));

    let env = EvalEnv {
        four_fingers: true,
        ..Default::default()
    };
    let result = evaluate_poker_hand(&cards, &env);
    assert_eq!(result.top(), Some(PokerHand::StraightFlush));
    // 计分名单是同花组与顺子组的并集, 共 5 张.
    assert_eq!(result.top_group().expect("有计分名单").len(), 5);
}

#[test]
fn four_fingers_lowers_flush_and_straight_to_four() {
    let env = EvalEnv {
        four_fingers: true,
        ..Default::default()
    };
    assert_eq!(
        evaluate_poker_hand(&hand(&["S3", "S6", "S8", "S9"]), &env).top(),
        Some(PokerHand::Flush)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["C3", "D4", "H5", "S6"]), &env).top(),
        Some(PokerHand::Straight)
    );
    // 三条的要求不随四指降低.
    assert_ne!(
        evaluate_poker_hand(&hand(&["C3", "D3", "H3", "S6"]), &env).top(),
        Some(PokerHand::Flush)
    );
}

#[test]
fn shortcut_allows_one_gap_but_not_two() {
    let env = EvalEnv {
        shortcut: true,
        ..Default::default()
    };
    // 花色要打散, 否则会先被判成同花顺.
    assert_eq!(
        evaluate_poker_hand(&hand(&["C2", "D4", "H6", "S8", "CT"]), &env).top(),
        Some(PokerHand::Straight)
    );
    assert!(
        !evaluate_poker_hand(&hand(&["C2", "C5", "C6", "C7", "C8"]), &env).has(PokerHand::Straight),
        "连续缺两个点数不成立"
    );
}

#[test]
fn ace_plays_both_ends_but_does_not_wrap() {
    let env = EvalEnv::default();
    assert_eq!(
        evaluate_poker_hand(&hand(&["CA", "C2", "C3", "C4", "C5"]), &env).top(),
        Some(PokerHand::StraightFlush)
    );
    assert_eq!(
        evaluate_poker_hand(&hand(&["CT", "CJ", "CQ", "CK", "CA"]), &env).top(),
        Some(PokerHand::StraightFlush)
    );
    assert!(
        !evaluate_poker_hand(&hand(&["CQ", "CK", "CA", "C2", "C3"]), &env).has(PokerHand::Straight),
        "A 不能首尾环绕"
    );
}

#[test]
fn higher_hands_are_inherited_downwards() {
    let env = EvalEnv::default();

    let full_house = evaluate_poker_hand(&hand(&["C2", "D2", "H2", "C3", "D3"]), &env);
    assert_eq!(full_house.top(), Some(PokerHand::FullHouse));
    assert!(full_house.has(PokerHand::TwoPair), "葫芦也算两对");

    let four = evaluate_poker_hand(&hand(&["C2", "D2", "H2", "S2", "C3"]), &env);
    assert_eq!(four.top(), Some(PokerHand::FourOfAKind));
    assert!(!four.has(PokerHand::TwoPair), "四条不算两对");
    assert!(four.has(PokerHand::ThreeOfAKind));
    assert!(four.has(PokerHand::Pair));

    let five = evaluate_poker_hand(&hand(&["C2", "D2", "H2", "S2", "C3"]), &env);
    assert!(five.has(PokerHand::Pair));
}

#[test]
fn stone_card_stays_out_of_hands_but_may_be_played() {
    let mut cards = hand(&["C2", "D2", "H5"]);
    // 用 struct update 语法, 这样 HandCard 以后再加字段也不会漏.
    cards.push(HandCard {
        stone: true,
        ..HandCard::plain(card("CT").card)
    });
    let env = EvalEnv::default();
    let result = evaluate_poker_hand(&cards, &env);
    assert_eq!(result.top(), Some(PokerHand::Pair));
    // 石头牌不参与同点数组, 也不参与顺子.
    assert_eq!(result.groups(PokerHand::Pair)[0].len(), 2);
    assert!(!result.has(PokerHand::Straight));
}

#[test]
fn wild_card_matches_every_suit_for_flush() {
    let mut cards = hand(&["C2", "C5", "C9", "D3"]);
    cards[3].wild = true;
    let env = EvalEnv {
        four_fingers: true,
        ..Default::default()
    };
    let result = evaluate_poker_hand(&cards, &env);
    assert!(result.has(PokerHand::Flush));
    assert_eq!(result.groups(PokerHand::Flush)[0].len(), 4);

    // 削弱之后万能花色失效, 按底牌方片算.
    cards[3].debuffed = true;
    assert!(!evaluate_poker_hand(&cards, &env).has(PokerHand::Flush));
}

#[test]
fn smeared_merges_red_and_black_suits() {
    let cards = hand(&["H2", "H5", "H9", "HT", "D3"]);
    assert!(!evaluate_poker_hand(&cards, &EvalEnv::default()).has(PokerHand::Flush));
    let env = EvalEnv {
        smeared: true,
        ..Default::default()
    };
    assert!(evaluate_poker_hand(&cards, &env).has(PokerHand::Flush));
}

#[test]
fn flush_prefers_spades_then_hearts() {
    // 五张牌里黑桃与红桃各有 4 张时, 花色搜索顺序是 黑桃 / 红桃 / 梅花 / 方片.
    let cards = hand(&["S2", "S4", "S6", "S8", "H3"]);
    let env = EvalEnv {
        four_fingers: true,
        ..Default::default()
    };
    let result = evaluate_poker_hand(&cards, &env);
    let group = &result.groups(PokerHand::Flush)[0];
    assert!(group.iter().all(|&i| cards[i].card.suit == Suit::Spades));
}
