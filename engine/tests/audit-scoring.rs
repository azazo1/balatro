//! 带 mod 游戏计分阶段和交互的关键回归.
mod common;

use balatro_engine::cards::Edition;
use balatro_engine::jokers::Joker;
use balatro_engine::scoring::{BackEffect, EvalEnv, HandCard, HandTable, ScoreResult, score_play_with_held};
use common::card;

fn score(played: &[HandCard], held: &[HandCard], keys: &[&str]) -> ScoreResult {
    let mut jokers: Vec<_> = keys.iter().map(|key| Joker::new(key).unwrap()).collect();
    score_play_with_held(played, held, &HandTable::new(), &EvalEnv::default(), BackEffect::Plain, &mut jokers).unwrap()
}

#[test]
fn brainstorm_copies_individual_and_chains() {
    let played = [card("S_2"), card("H_2")];
    assert_eq!(score(&played, &[], &["j_even_steven", "j_brainstorm"]).mult, 18.0);
    assert_eq!(score(&played, &[], &["j_blueprint", "j_blueprint", "j_even_steven"]).mult, 26.0);
}

#[test]
fn copied_repetitions_repeat_the_entire_card() {
    let played = [card("S_2")];
    let result = score(&played, &[], &["j_blueprint", "j_hack", "j_even_steven"]);
    assert_eq!(result.chips, 11.0);
    assert_eq!(result.mult, 13.0);
}

#[test]
fn copied_held_effects_keep_source_slot_order() {
    let played = [card("S_A")];
    let held = [card("H_K")];
    let result = score(&played, &held, &["j_blueprint", "j_baron"]);
    assert_eq!(result.mult, 2.25);
}

#[test]
fn debuffed_copy_nodes_and_targets_do_not_score() {
    let mut jokers = [Joker::new("j_blueprint").unwrap(), Joker::new("j_even_steven").unwrap()];
    jokers[0].debuffed = true;
    let score = |jokers: &mut [Joker]| score_play_with_held(&[card("S_2")], &[], &HandTable::new(), &EvalEnv::default(), BackEffect::Plain, jokers).unwrap();
    assert_eq!(score(&mut jokers).mult, 5.0);
    jokers[0].debuffed = false;
    jokers[1].debuffed = true;
    assert_eq!(score(&mut jokers).mult, 1.0);
}

#[test]
fn stone_cards_always_join_scoring_hand() {
    let mut stone = card("S_2");
    stone.stone = true;
    stone.bonus = 50.0;
    let result = score(&[stone, card("H_K")], &[], &[]);
    assert_eq!(result.scoring_cards, vec![0, 1]);
    assert_eq!(result.chips, 65.0);
    let mut high_stone = card("S_K");
    high_stone.stone = true;
    high_stone.bonus = 50.0;
    let result = score(&[high_stone, card("H_2")], &[], &[]);
    assert_eq!(result.scoring_cards, vec![0, 1]);
    assert_eq!(result.chips, 57.0);
}

#[test]
fn played_edition_precedes_individual_jokers() {
    let mut king = card("H_K");
    king.edition = Some(Edition::Holo);
    let result = score(&[king], &[], &["j_photograph"]);
    assert_eq!(result.mult, 22.0);
}

#[test]
fn joker_additive_edition_precedes_main_effect() {
    let mut joker = Joker::new("j_card_sharp").unwrap();
    joker.edition = Some(Edition::Holo);
    let mut table = HandTable::new();
    table.record_played(balatro_engine::scoring::PokerHand::HighCard);
    let result = score_play_with_held(&[card("S_A")], &[], &table, &EvalEnv::default(), BackEffect::Plain, &mut [joker]).unwrap();
    assert_eq!(result.mult, 33.0);
}

#[test]
fn baseball_runs_after_each_uncommon_main_effect() {
    let result = score(&[card("S_A")], &[], &["j_baseball", "j_fibonacci", "j_joker"]);
    assert_eq!(result.mult, 17.5);
}

#[test]
fn mime_and_red_seal_repeat_held_joker_effects() {
    let mut king = card("H_K");
    king.h_x_mult = 1.5;
    king.repetitions = 2;
    let result = score(&[card("S_A")], &[king], &["j_mime", "j_baron"]);
    assert!((result.mult - 1.5_f64.powi(6)).abs() < 1e-9);
}

#[test]
fn copied_mime_repeats_baron_even_without_steel() {
    let result = score(&[card("S_A")], &[card("H_K")], &["j_blueprint", "j_mime", "j_baron"]);
    assert_eq!(result.mult, 3.375);
}

#[test]
fn before_growth_happens_before_individual_creation() {
    let played = [card("S_2"), card("H_2"), card("C_3"), card("D_3")];
    let mut jokers = [Joker::new("j_trousers").unwrap()];
    let result = score_play_with_held(&played, &[], &HandTable::new(), &EvalEnv::default(), BackEffect::Plain, &mut jokers).unwrap();
    assert_eq!(result.mult, 4.0);
    assert_eq!(jokers[0].mult, 2.0);
}

#[test]
fn observatory_applies_before_plasma_balance_without_flooring() {
    let env = EvalEnv { observatory_planets: 1, ..EvalEnv::default() };
    let result = score_play_with_held(&[card("S_A")], &[], &HandTable::new(), &env, BackEffect::Plasma, &mut []).unwrap();
    assert_eq!((result.chips, result.mult), (8.0, 8.0));
    let result = score_play_with_held(&[card("S_A")], &[], &HandTable::new(), &env, BackEffect::Plain, &mut []).unwrap();
    assert_eq!(result.mult, 1.5);
}

#[test]
fn hiker_grows_per_trigger_and_returns_persistent_deltas() {
    let mut played = card("S_2");
    played.repetitions = 2;
    let result = score(&[played], &[], &["j_blueprint", "j_hiker"]);
    assert_eq!(result.chips, 19.0);
    assert_eq!(result.perma_bonuses, vec![20.0]);
}

#[test]
fn wee_growth_scores_this_hand_and_does_not_grow_through_copy() {
    let mut played = card("S_2");
    played.repetitions = 2;
    let mut jokers = [Joker::new("j_blueprint").unwrap(), Joker::new("j_wee").unwrap()];
    let result = score_play_with_held(&[played], &[], &HandTable::new(), &EvalEnv::default(), BackEffect::Plain, &mut jokers).unwrap();
    assert_eq!(jokers[1].chips, 16.0);
    assert_eq!(result.chips, 41.0);
}

#[test]
fn identical_cards_keep_first_card_identity_for_photograph_and_chad() {
    let kings = [card("S_K"), card("S_K")];
    let result = score(&kings, &[], &["j_photograph", "j_hanging_chad"]);
    assert_eq!(result.chips, 50.0);
    assert_eq!(result.mult, 16.0);
}

#[test]
fn copy_loops_and_incompatible_targets_do_not_trigger() {
    assert_eq!(score(&[card("S_2")], &[], &["j_brainstorm", "j_blueprint"]).mult, 1.0);
    assert_eq!(score(&[card("S_2")], &[], &["j_blueprint", "j_brainstorm"]).mult, 1.0);
    assert_eq!(score(&[card("S_2")], &[], &["j_blueprint", "j_midas_mask"]).mult, 1.0);
}

#[test]
fn steamodded_hand_level_changes_preserve_unclamped_values() {
    use balatro_engine::scoring::PokerHand;
    let mut table = HandTable::new();
    table.level_up(PokerHand::HighCard, -1);
    assert_eq!(table.get(PokerHand::HighCard).level, 0);
    assert_eq!(table.get(PokerHand::HighCard).chips(PokerHand::HighCard), -5.0);
    assert_eq!(table.get(PokerHand::HighCard).mult(PokerHand::HighCard), 0.0);
    table.level_up(PokerHand::HighCard, -1);
    assert_eq!(table.get(PokerHand::HighCard).level, -1);
}

#[test]
fn steamodded_poker_parts_match_executed_lua_oracle() {
    use balatro_engine::scoring::{PokerHand, evaluate_poker_hand};
    let cases: &[(&[&str], EvalEnv, PokerHand, &[usize])] = &[
        (&["S_2", "S_3", "S_4", "H_5", "S_K"], EvalEnv { four_fingers: true, ..EvalEnv::default() }, PokerHand::StraightFlush, &[0,1,2,3,4]),
        (&["S_2", "H_4", "C_6", "D_8", "S_T"], EvalEnv { shortcut: true, ..EvalEnv::default() }, PokerHand::Straight, &[0,1,2,3,4]),
        (&["S_Q", "H_K", "C_A", "D_2", "S_3"], EvalEnv { shortcut: true, ..EvalEnv::default() }, PokerHand::HighCard, &[2]),
        (&["S_2", "H_2", "S_3", "H_3", "S_4", "H_4"], EvalEnv::default(), PokerHand::TwoPair, &[0,1,2,3,4,5]),
        (&["S_2", "H_3", "C_4", "D_5", "S_6", "H_7"], EvalEnv::default(), PokerHand::Straight, &[0,1,2,3,4,5]),
        (&["S_2", "S_3", "S_4", "S_5", "S_6", "S_7"], EvalEnv::default(), PokerHand::StraightFlush, &[0,1,2,3,4,5]),
        (&["S_2", "H_2", "C_2", "S_3", "H_3"], EvalEnv::default(), PokerHand::FullHouse, &[0,1,2,3,4]),
        (&["S_2", "H_2", "C_2", "D_2", "S_2"], EvalEnv::default(), PokerHand::FiveOfAKind, &[0,1,2,3,4]),
        (&["S_2", "H_3", "C_4", "D_5", "S_5"], EvalEnv { four_fingers: true, ..EvalEnv::default() }, PokerHand::Straight, &[0,1,2,3,4]),
        (&["H_2", "D_3", "H_4", "D_5", "H_6"], EvalEnv { smeared: true, ..EvalEnv::default() }, PokerHand::StraightFlush, &[0,1,2,3,4]),
    ];
    for (codes, env, expected_hand, expected_indices) in cases {
        let cards: Vec<_> = codes.iter().map(|code| card(code)).collect();
        let result = evaluate_poker_hand(&cards, env);
        assert_eq!(result.top(), Some(*expected_hand), "{codes:?}");
        let mut group = result.top_group().unwrap().clone();
        group.sort_unstable();
        assert_eq!(group, *expected_indices, "{codes:?}");
    }
    // SMODS 的 >=num 子结果不能用原版大牌型覆盖低牌型名单.
    let cards = [card("S_2"),card("H_2"),card("C_2"),card("S_3"),card("H_3")];
    let result = evaluate_poker_hand(&cards, &EvalEnv::default());
    assert_eq!(result.groups(PokerHand::Pair).len(), 2);
    assert_eq!(result.groups(PokerHand::Pair)[0], vec![3,4]);
}

#[test]
fn before_card_mutations_preserve_initial_scoring_selection() {
    use balatro_engine::scoring::{score_play_with_creation_pre_evaluated, scoring_selection, PokerHand};
    let mut cards = [card("S_2"), card("H_2"), card("S_K")];
    cards[2].stone = true;
    cards[2].bonus = 50.0;
    let env = EvalEnv::default();
    let (evaluated, indices) = scoring_selection(&cards, &env).unwrap();
    cards[2].stone = false;
    cards[2].bonus = 0.0;
    let mut creation = balatro_engine::run::shop::Creation {
        ante: 1, showman: false, banned: Default::default(), used: Default::default(),
        enhanced: Default::default(), played: Default::default(),
    };
    let result = score_play_with_creation_pre_evaluated(&cards, &[], &HandTable::new(), &env, BackEffect::Plain, &mut [], &mut creation, &mut balatro_engine::rng::Rng::new("audit"), &evaluated, &indices).unwrap();
    assert_eq!(result.hand, PokerHand::Pair);
    assert_eq!(result.scoring_cards, vec![0,1,2]);
    assert_eq!(result.chips, 24.0);
}

#[test]
fn lucky_cat_copy_does_not_double_grow_on_each_lucky_repetition() {
    let mut played = card("S_2");
    played.lucky = true;
    played.gold_seal = true;
    played.repetitions = 2;
    let env = EvalEnv { probability_extra: 100.0, ..EvalEnv::default() };
    let mut jokers = [Joker::new("j_blueprint").unwrap(), Joker::new("j_lucky_cat").unwrap()];
    let result = score_play_with_held(&[played], &[], &HandTable::new(), &env, BackEffect::Plain, &mut jokers).unwrap();
    assert_eq!(jokers[1].x_mult, 1.5);
    assert_eq!(result.dollars, 46.0);
    assert_eq!(result.mult, 92.25);
}

#[test]
fn held_random_effects_only_repeat_after_a_first_calculated_effect() {
    use balatro_engine::scoring::score_play_with_rng;
    let mut king = card("S_K");
    king.repetitions = 2;
    let mut jokers = [Joker::new("j_reserved_parking").unwrap(), Joker::new("j_mime").unwrap()];
    let mut rng = balatro_engine::rng::Rng::new("parking-audit");
    let mut expected_rng = rng.clone();
    let first = expected_rng.pseudorandom("parking") < 1.0/2.0;
    if first { expected_rng.pseudorandom("parking"); expected_rng.pseudorandom("parking"); }
    score_play_with_rng(&[card("S_2")], &[king], &HandTable::new(), &EvalEnv::default(), BackEffect::Plain, &mut jokers, &mut rng).unwrap();
    assert_eq!(rng.pseudorandom("parking"), expected_rng.pseudorandom("parking"));
}

#[test]
fn triggered_matador_pays_per_copy_in_slot_order_before_bull_reads_money() {
    let played = [card("S_2")];
    for (keys, triggered, reward, chips, dollars) in [
        (vec!["j_matador", "j_bull"], true, 8.0, 29.0, 8.0),
        (vec!["j_bull", "j_matador"], true, 8.0, 13.0, 8.0),
        (vec!["j_blueprint", "j_matador", "j_bull"], true, 8.0, 45.0, 16.0),
        (vec!["j_matador", "j_bull"], false, 8.0, 13.0, 0.0),
        (vec!["j_blueprint", "j_matador", "j_bull"], true, 11.0, 57.0, 22.0),
    ] {
        let mut jokers: Vec<_> = keys.iter().map(|key| Joker::new(key).unwrap()).collect();
        for joker in &mut jokers { if joker.key == "j_matador" { joker.extra = reward; } }
        let env = EvalEnv { dollars: 3.0, boss_triggered: triggered, ..EvalEnv::default() };
        let result = score_play_with_held(&played, &[], &HandTable::new(), &env, BackEffect::Plain, &mut jokers).unwrap();
        assert_eq!(result.chips, chips, "{keys:?}");
        assert_eq!(result.dollars, dollars, "{keys:?}");
    }
}

#[test]
#[ignore = "需要 Lua 与预先应用 Lovely 的补丁树, 用于真实源码裁判验证"]
fn live_steamodded_poker_oracle_matches_all_reported_groups() {
    use balatro_engine::scoring::{PokerHand, evaluate_poker_hand};
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let lua = std::env::var("BALATRO_AUDIT_LUA").unwrap_or_else(|_| "luajit".into());
    let output = std::process::Command::new(lua)
        .arg("engine/tests/lua/audit_poker.lua").current_dir(root).output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let stdout = String::from_utf8(output.stdout).unwrap();
    let mut count = 0;
    for line in stdout.lines() {
        let row: Vec<_> = line.split('\t').collect();
        assert_eq!(row.len(), 4);
        let cards: Vec<_> = row[0].split(',').map(card).collect();
        let flags = row[1].as_bytes();
        let env = EvalEnv { four_fingers: flags[0] == b'1', shortcut: flags[1] == b'1', smeared: flags[2] == b'1', ..EvalEnv::default() };
        let hand = PokerHand::from_key(row[2]).unwrap();
        let expected: Vec<usize> = row[3].split(',').map(|index| index.parse().unwrap()).collect();
        let result = evaluate_poker_hand(&cards, &env);
        let mut group = result.groups(hand).first().unwrap().clone();
        group.sort_unstable();
        assert_eq!(group, expected, "{line}");
        count += 1;
    }
    assert_eq!(count, 33, "裁判必须实际输出全部牌型子结果");
}
