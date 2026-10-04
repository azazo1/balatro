//! 金注对拍暴露的折扣, 标签与削弱计分回归.

mod common;

use balatro_engine::cards::Edition;
use balatro_engine::jokers::Joker;
use balatro_engine::run::blind::BlindKind;
use balatro_engine::run::shop::{Shop, ShopCard};
use balatro_engine::run::{Phase, RunState};
use balatro_engine::scoring::{BackEffect, EvalEnv, HandTable, score_play};

fn item(key: &str, cost: f64) -> ShopCard {
    ShopCard {
        key: key.to_owned(), cost, edition: None, eternal: false,
        perishable: false, rental: false, enhancement: None, todo: None,
    }
}

#[test]
fn discount_reprices_the_existing_shelf_and_owned_jokers() {
    let mut run = RunState::new("4AH77J5E", 8);
    run.phase = Phase::Shop;
    run.dollars = 42.0;
    let mut foil = item("j_runner", 7.0);
    foil.edition = Some(Edition::Foil);
    let mut rental = item("j_runner", 1.0);
    rental.rental = true;
    let mut playing = item("S_3", 3.0);
    playing.edition = Some(Edition::Foil);
    run.jokers.push(Joker::new("j_scholar").unwrap());
    run.shop = Some(Shop {
        jokers: vec![foil, rental, playing],
        voucher: Some(item("v_clearance_sale", 10.0)),
        extra_voucher: Some(item("v_blank", 10.0)),
        packs: vec![item("p_celestial_jumbo_1", 6.0)],
    });
    let voucher = run.shop.as_ref().unwrap().voucher.clone().unwrap();
    run.buy(&voucher).unwrap();
    let shop = run.shop.as_ref().unwrap();
    assert_eq!(shop.packs[0].cost, 4.0);
    assert_eq!(shop.jokers[0].cost, 5.0);
    assert_eq!(shop.jokers[1].cost, 1.0);
    assert_eq!(shop.jokers[2].cost, 2.0, "扑克牌使用基础价 1");
    assert_eq!(shop.extra_voucher.as_ref().unwrap().cost, 7.0);
    assert_eq!(run.jokers[0].cost, 3.0);
    let pack = shop.packs[0].clone();
    assert_eq!(run.buy(&pack).unwrap(), 4.0);
    assert_eq!(run.dollars, 28.0);
}

#[test]
fn tag_pack_returns_to_blind_selection_without_skipping_an_extra_blind() {
    for take in [false, true] {
        let mut run = RunState::new("4AH77J5E", 8);
        run.start_run();
        run.blind_tags[0] = Some("tag_standard".to_owned());
        run.skip_blind().unwrap();
        assert_eq!(run.blind_on_deck, BlindKind::Big);
        assert!(!run.tags.iter().any(|tag| tag == "tag_standard"));
        if take {
            run.pick_from_pack(0).unwrap();
            run.pick_from_pack(0).unwrap();
        } else {
            run.skip_pack().unwrap();
        }
        assert_eq!(run.phase, Phase::BlindSelect);
        assert_eq!(run.blind_on_deck, BlindKind::Big);
        assert!(run.next_round().is_err());
        run.select_blind().unwrap();
        assert_eq!(run.round, 1);
        assert_eq!(run.blind.as_ref().unwrap().kind, BlindKind::Big);
    }
}

#[test]
fn stacked_double_tags_queue_all_packs_and_are_consumed() {
    let mut run = RunState::new("4AH77J5E", 8);
    run.start_run();
    run.tags.extend(["tag_double".to_owned(), "tag_double".to_owned()]);
    run.blind_tags[0] = Some("tag_standard".to_owned());
    run.skip_blind().unwrap();
    assert!(!run.tags.iter().any(|tag| tag == "tag_double"));
    for remaining in (0..3).rev() {
        assert_eq!(run.phase, Phase::BoosterOpened);
        assert_eq!(run.tags.iter().filter(|tag| *tag == "tag_standard").count(), remaining);
        run.skip_pack().unwrap();
    }
    assert_eq!(run.phase, Phase::BlindSelect);
    assert_eq!(run.skips, 1);
}

#[test]
fn debuffed_card_still_forms_a_pair_but_has_no_scoring_triggers() {
    let mut played = [common::card("D_A"), common::card("S_A")];
    played[0].debuffed = true;
    played[0].edition = Some(Edition::Foil);
    played[0].gold_seal = true;
    played[0].repetitions = 3;
    played[0].x_mult = 2.0;
    let mut jokers = ["j_scholar", "j_fibonacci", "j_hanging_chad", "j_photograph"]
        .map(|key| Joker::new(key).unwrap());
    let env = EvalEnv { pareidolia: true, ..EvalEnv::default() };
    let score = score_play(&played, &HandTable::new(), &env, BackEffect::Plain, &mut jokers).unwrap();
    assert_eq!(score.scoring_cards, vec![0, 1]);
    assert_eq!(score.chips, 41.0);
    assert_eq!(score.mult, 28.0);
    assert_eq!(score.dollars, 0.0);
}

#[test]
fn rejected_pack_skip_does_not_grow_red_card() {
    let mut run = RunState::new("4AH77J5E", 8);
    run.start_run();
    run.jokers.push(Joker::new("j_red_card").unwrap());
    let before = run.jokers[0].mult;
    assert!(run.skip_pack().is_err());
    assert_eq!(run.jokers[0].mult, before);
}

#[test]
fn eternal_sale_is_atomic_and_extra_value_is_not_halved() {
    let mut run = RunState::new("4AH77J5E", 8);
    run.phase = Phase::Shop;
    run.dollars = 0.0;
    let mut egg = Joker::new("j_egg").unwrap();
    egg.extra_value = 6.0;
    let mut scholar = Joker::new("j_scholar").unwrap();
    scholar.eternal = true;
    run.jokers.extend([egg, scholar]);
    assert!(run.sell_joker(1).is_err());
    assert_eq!(run.dollars, 0.0);
    assert_eq!(run.jokers.len(), 2);
    run.consumables.push("c_temperance".into());
    run.use_consumable(0, &[]).unwrap();
    assert_eq!(run.dollars, 10.0, "节制包含完整的成长卖价");
    assert_eq!(run.sell_joker(0).unwrap(), 8.0);
}

#[test]
fn edition_changes_and_negative_consumables_use_current_prices() {
    let mut run = RunState::new("4AH77J5E", 8);
    run.phase = Phase::Shop;
    run.discount_percent = 25.0;
    run.jokers.push(Joker::new("j_scholar").unwrap());
    run.consumables.push("c_hex".into());
    run.use_consumable(0, &[]).unwrap();
    assert_eq!(run.jokers[0].edition, Some(Edition::Polychrome));
    assert_eq!(run.jokers[0].cost, 7.0);
    run.consumables.push(balatro_engine::run::consumable::Consumable::with_edition(
        "c_fool", Some(Edition::Negative)));
    assert_eq!(run.sell_consumable(0).unwrap(), 3.0);
}

#[test]
fn debuffed_scoring_card_has_no_persistent_joker_side_effects() {
    let mut run = RunState::new("4AH77J5E", 8);
    run.start();
    let mut card = balatro_engine::cards::CardInstance::from_key("D_K").unwrap();
    card.debuffed = true;
    card.card.sort_id = 9999;
    run.hand = vec![card];
    run.jokers.extend([Joker::new("j_hiker").unwrap(), Joker::new("j_midas_mask").unwrap()]);
    run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    let card = run.discard_pile.iter().chain(run.play_area.iter())
        .find(|card| card.card.sort_id == 9999).unwrap();
    assert_eq!(card.perma_bonus, 0.0);
    assert_eq!(card.enhancement, None);
}
