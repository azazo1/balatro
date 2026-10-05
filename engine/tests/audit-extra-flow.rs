//! 已应用 mod 的运行层副作用和计分边界回归.
mod common;

use balatro_engine::cards::{CardInstance, Edition, Enhancement, Seal, Rank, standard_deck};
use balatro_engine::jokers::Joker;
use balatro_engine::run::{BlindKind, RunState};
use balatro_engine::scoring::{BackEffect, EvalEnv, PokerHand};

fn boss(key: &str) -> RunState {
    let mut run = RunState::new("flow-audit", 1);
    run.start_run();
    run.boss_key = Some(key.into());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);
    run
}

fn set_hand(run: &mut RunState, codes: &[&str]) {
    run.hand = codes.iter().enumerate().map(|(index, code)| {
        let mut card = CardInstance::from_key(code).unwrap();
        card.card.sort_id = 1000 + index as u32;
        card
    }).collect();
}

#[test]
fn hook_runs_normal_discard_effects_without_consuming_discard_or_burnt() {
    // Blind.press_play 的 Hook 在评分之前调用 discard(..., hook=true).
    let mut run = boss("bl_hook");
    set_hand(&mut run, &["S_2", "H_9", "H_9", "H_9"]);
    for card in &mut run.hand[1..] { card.seal = Some(Seal::Purple); }
    run.mail_rank = Some(Rank::Nine);
    for key in ["j_mail", "j_burnt", "j_green_joker"] { run.add_joker(Joker::new(key).unwrap()); }
    run.jokers[2].mult = 10.0;
    let discards = run.discards_left;
    let dollars = run.dollars;
    run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    assert_eq!(run.dollars, dollars + 10.0);
    assert_eq!(run.consumables.len(), 2);
    assert_eq!(run.discards_left, discards);
    assert_eq!(run.discards_used, 0);
    assert_eq!(run.hands.get(PokerHand::Pair).level, 1);
    assert_eq!(run.jokers[2].mult, 10.0);
}

#[test]
fn hook_removes_cards_before_held_jokers_score() {
    let mut run = boss("bl_hook");
    set_hand(&mut run, &["S_2", "H_K", "C_K", "D_K"]);
    run.add_joker(Joker::new("j_baron").unwrap());
    let score = run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    assert_eq!(score.mult, 1.5);
}

#[test]
fn setting_blind_multiple_marble_sources_draw_once_from_whole_front_pool() {
    let mut run = RunState::new("marble-audit", 1);
    run.start_run();
    for key in ["j_marble", "j_marble", "j_blueprint", "j_marble"] { run.add_joker(Joker::new(key).unwrap()); }
    let mut oracle = run.rng.clone();
    let pool = standard_deck();
    let expected: Vec<_> = (0..4).map(|_| oracle.pick(&pool, "marb_fr").key()).collect();
    common::place_blind(&mut run);
    let mut added: Vec<_> = run.deck.iter().chain(run.hand.iter()).filter(|card| card.enhancement == Some(Enhancement::Stone)).collect();
    added.sort_by_key(|card| card.card.sort_id);
    assert_eq!(added.iter().map(|card| card.card.key()).collect::<Vec<_>>(), expected);
    assert_eq!(run.deck.len() + run.hand.len(), 56);
    assert_eq!(run.rng.pseudorandom("marb_fr"), oracle.pseudorandom("marb_fr"));
}

#[test]
fn first_hand_drawn_multiple_certificates_include_copies_but_skip_debuffed() {
    let mut run = RunState::new("certificate-audit", 1);
    run.start_run();
    for key in ["j_certificate", "j_certificate", "j_blueprint", "j_certificate"] { run.add_joker(Joker::new(key).unwrap()); }
    run.jokers[1].debuffed = true;
    run.jokers[1].perishable = true;
    run.jokers[1].perish_tally = 0;
    let mut oracle = run.rng.clone();
    let pool = standard_deck();
    let expected: Vec<_> = (0..3).map(|_| oracle.pick(&pool, "cert_fr").key()).collect();
    let expected_seals: Vec<_> = (0..3).map(|_| {
        let poll = oracle.pseudorandom("certsl");
        if poll > 0.75 { Seal::Red } else if poll > 0.5 { Seal::Blue }
        else if poll > 0.25 { Seal::Gold } else { Seal::Purple }
    }).collect();

    common::place_blind(&mut run);
    let mut added: Vec<_> = run.hand.iter().filter(|card| card.seal.is_some()).collect();
    added.sort_by_key(|card| card.card.sort_id);
    assert_eq!(added.iter().map(|card| card.card.key()).collect::<Vec<_>>(), expected);
    assert_eq!(added.iter().map(|card| card.seal.unwrap()).collect::<Vec<_>>(), expected_seals);
    assert_eq!(run.hand.len(), 11);
    assert_eq!(run.rng.pseudorandom("cert_fr"), oracle.pseudorandom("cert_fr"));
    assert_eq!(run.rng.pseudorandom("certsl"), oracle.pseudorandom("certsl"));
}

#[test]
fn riff_raff_reserves_capacity_for_multiple_sources_and_ignores_debuffed() {
    let mut run = RunState::new("riff-audit", 1);
    run.start_run();
    run.add_joker(Joker::new("j_blueprint").unwrap());
    run.add_joker(Joker::new("j_riff_raff").unwrap());
    let mut disabled = Joker::new("j_riff_raff").unwrap();
    disabled.debuffed = true;
    disabled.perishable = true;
    disabled.perish_tally = 0;
    run.add_joker(disabled);
    run.jokers[0].edition = Some(Edition::Negative);
    run.jokers[1].edition = Some(Edition::Negative);
    common::place_blind(&mut run);
    assert_eq!(run.jokers.len(), 7);
    assert!(run.jokers[3..].iter().all(|joker| balatro_engine::data::catalog::Catalog::get().record(&joker.key).unwrap().rarity == Some(1)));
    let mut run = RunState::new("riff-disabled-audit", 1);
    run.start_run();
    let mut disabled = Joker::new("j_riff_raff").unwrap();
    disabled.debuffed = true;
    disabled.perishable = true;
    disabled.perish_tally = 0;
    run.add_joker(disabled);
    common::place_blind(&mut run);
    assert_eq!(run.jokers.len(), 1);
}

#[test]
fn disabling_water_needle_and_manacle_restores_stored_budget_and_slots() {
    let mut water = boss("bl_water");
    assert_eq!(water.discards_left, 0);
    water.add_joker(Joker::new("j_chicot").unwrap());
    assert_eq!(water.discards_left, water.discards_per_round);
    let mut needle = boss("bl_needle");
    assert_eq!(needle.hands_left, 1);
    needle.hands_left -= 1;
    needle.add_joker(Joker::new("j_chicot").unwrap());
    assert_eq!(needle.hands_left, needle.hands_per_round - 1);
    let mut manacle = boss("bl_manacle");
    assert_eq!(manacle.hand.len(), 7);
    manacle.add_joker(Joker::new("j_chicot").unwrap());
    assert_eq!(manacle.hand_size(), 8);
    assert_eq!(manacle.hand.len(), 8);
}

#[test]
fn disabling_heart_restores_passive_joker_effects_not_expired_perishables() {
    let mut run = RunState::new("heart-audit", 1);
    run.start_run();
    run.add_joker(Joker::new("j_juggler").unwrap());
    let mut expired = Joker::new("j_joker").unwrap();
    expired.perishable = true;
    expired.perish_tally = 0;
    expired.debuffed = true;
    run.add_joker(expired);
    run.boss_key = Some("bl_final_heart".into());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);
    assert!(run.jokers[0].debuffed);
    assert_eq!(run.hand_size(), 8);
    run.add_joker(Joker::new("j_chicot").unwrap());
    assert!(!run.jokers[0].debuffed);
    assert_eq!(run.hand_size(), 9);
    assert!(run.jokers[1].debuffed);
}

fn use_tarot(run: &mut RunState, key: &str) {
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain(key));
    run.use_consumable(run.consumables.len()-1, &[0]).unwrap();
}

#[test]
fn tarot_enhancements_recalculate_suit_debuffs_on_wild_and_stone() {
    let mut run = boss("bl_club");
    set_hand(&mut run, &["S_2"]);
    use_tarot(&mut run, "c_lovers");
    assert_eq!(run.hand[0].enhancement, Some(Enhancement::Wild));
    assert!(run.hand[0].debuffed);
    use_tarot(&mut run, "c_tower");
    assert_eq!(run.hand[0].enhancement, Some(Enhancement::Stone));
    assert!(!run.hand[0].debuffed);
}

#[test]
fn gaining_and_losing_smeared_recalculates_living_suit_debuffs() {
    let mut run = boss("bl_club");
    set_hand(&mut run, &["S_2"]);
    assert!(!run.hand[0].debuffed);
    let index = run.add_joker(Joker::new("j_smeared").unwrap());
    assert!(run.hand[0].debuffed);
    run.sell_joker(index).unwrap();
    assert!(!run.hand[0].debuffed);
}

#[test]
fn changing_rank_and_pareidolia_recalculates_plant_including_stone_cards() {
    let mut run = boss("bl_plant");
    set_hand(&mut run, &["S_T"]);
    use_tarot(&mut run, "c_strength");
    assert_eq!(run.hand[0].card.rank, Rank::Jack);
    assert!(run.hand[0].debuffed);
    use_tarot(&mut run, "c_tower");
    assert!(!run.hand[0].debuffed);
    let index = run.add_joker(Joker::new("j_pareidolia").unwrap());
    assert!(run.hand[0].debuffed);
    run.sell_joker(index).unwrap();
    assert!(!run.hand[0].debuffed);
}

#[test]
fn before_vampire_updates_stone_and_enhanced_deck_counts_for_main_jokers() {
    let mut run = boss("bl_hook");
    set_hand(&mut run, &["S_2"]);
    run.hand[0].enhancement = Some(Enhancement::Stone);
    for key in ["j_vampire", "j_stone"] { run.add_joker(Joker::new(key).unwrap()); }
    let score = run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    assert_eq!(score.chips, 7.0);
    let mut run = boss("bl_hook");
    set_hand(&mut run, &["S_2"]);
    run.hand[0].enhancement = Some(Enhancement::Steel);
    run.discard_pile.clear();
    run.deck = (0..15).map(|index| {
        let mut card = CardInstance::from_key("S_3").unwrap();
        card.enhancement = Some(Enhancement::Bonus);
        card.card.sort_id = 2000 + index;
        card
    }).collect();
    for key in ["j_vampire", "j_drivers_license"] { run.add_joker(Joker::new(key).unwrap()); }
    let score = run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    assert!((score.mult - 1.1).abs() < 1e-12);
}

#[test]
fn before_dna_updates_alive_deck_count_for_erosion_this_hand() {
    let mut run = boss("bl_hook");
    set_hand(&mut run, &["S_2"]);
    run.deck.clear();
    run.discard_pile.clear();
    run.starting_deck_size = 3;
    for key in ["j_dna", "j_erosion"] { run.add_joker(Joker::new(key).unwrap()); }
    let score = run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    assert_eq!(score.mult, 5.0);
}
