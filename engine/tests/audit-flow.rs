//! 流程审计的关键行为回归.

use balatro_engine::cards::CardInstance;
use balatro_engine::jokers::Joker;
use balatro_engine::run::{BlindKind, Phase, RunState};
use balatro_engine::scoring::{BackEffect, EvalEnv};

fn card(key: &str) -> CardInstance {
    CardInstance::from_key(key).unwrap()
}

fn ready() -> RunState {
    let mut run = RunState::new("FLOWAUDIT", 1);
    run.start();
    run.blind.as_mut().unwrap().chips = 10_000.0;
    run
}

#[test]
fn cloud_nine_counts_discarded_and_playing_cards() {
    let mut run = ready();
    run.deck = vec![card("S_9")];
    run.hand = vec![card("H_9")];
    run.discard_pile = vec![card("C_9")];
    run.play_area = vec![card("D_9")];
    run.add_joker(Joker::new("j_cloud_9").unwrap());
    run.chips = 10_000.0;
    run.end_round();
    assert_eq!(run.round_eval.unwrap().card_bonus, 4.0);
}

#[test]
fn handy_tag_uses_lifetime_play_count() {
    let mut run = ready();
    run.hand = vec![card("S_2")];
    run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    run.chips = 10_000.0;
    run.end_round();
    run.cash_out().unwrap();
    run.next_round().unwrap();
    run.blind_tags[1] = Some("tag_handy".to_owned());
    let before = run.dollars;
    run.skip_blind().unwrap();
    assert_eq!(run.dollars - before, 1.0);
}

#[test]
fn garbage_tag_uses_lifetime_unused_discards() {
    let mut run = ready();
    run.discards_left = 2;
    run.chips = 10_000.0;
    run.end_round();
    run.cash_out().unwrap();
    run.next_round().unwrap();
    run.blind_tags[1] = Some("tag_garbage".to_owned());
    run.discards_left = 0;
    let before = run.dollars;
    run.skip_blind().unwrap();
    assert_eq!(run.dollars - before, 2.0);
}

#[test]
fn investment_is_paid_once_after_a_survived_boss() {
    let mut run = RunState::new("FLOWAUDIT", 1);
    run.start_run();
    run.blind_tags[0] = Some("tag_investment".to_owned());
    let before = run.dollars;
    run.skip_blind().unwrap();
    assert_eq!(run.dollars, before);
    run.blind_on_deck = BlindKind::Boss;
    run.select_blind().unwrap();
    run.chips = run.blind.as_ref().unwrap().chips;
    run.end_round();
    assert_eq!(run.round_eval.unwrap().total(), 25.0 + 5.0 + 4.0);
    run.cash_out().unwrap();
    assert!(!run.tags.iter().any(|tag| tag == "tag_investment"));
}

#[test]
fn swashbuckler_has_no_multiplier_without_another_joker() {
    let mut run = ready();
    run.hand = vec![card("S_2")];
    run.add_joker(Joker::new("j_swashbuckler").unwrap());
    let result = run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    assert_eq!(result.mult, 1.0);
}

#[test]
fn swashbuckler_reads_current_other_sell_prices_before_scoring() {
    let mut run = ready();
    run.hand = vec![card("S_2")];
    run.add_joker(Joker::new("j_swashbuckler").unwrap());
    let mut other = Joker::new("j_egg").unwrap();
    other.extra_value = 7.0;
    let price = other.sell_price();
    run.add_joker(other);
    let result = run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    assert_eq!(result.mult, 1.0 + price);
}

#[test]
fn rejected_tarot_does_not_change_usage_or_growth() {
    let mut run = ready();
    run.add_joker(Joker::new("j_fortune_teller").unwrap());
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_strength"));
    let before = format!("{run:?}");
    assert!(run.use_consumable(0, &[99]).is_err());
    assert_eq!(format!("{run:?}"), before);
}

#[test]
fn gold_cards_pay_before_interest_is_calculated() {
    let mut run = ready();
    let mut gold = card("S_2");
    gold.set_enhancement(balatro_engine::cards::Enhancement::Gold);
    run.hand = vec![gold];
    run.dollars = 4.0;
    run.chips = 10_000.0;
    run.end_round();
    assert_eq!(run.dollars, 7.0);
    assert_eq!(run.round_eval.unwrap().interest, 1.0);
}

#[test]
fn gold_red_seal_and_mime_repeat_held_round_end_rewards() {
    let mut run = ready();
    let mut gold = card("S_2");
    gold.set_enhancement(balatro_engine::cards::Enhancement::Gold);
    gold.seal = Some(balatro_engine::cards::Seal::Red);
    run.hand = vec![gold];
    run.add_joker(Joker::new("j_mime").unwrap());
    run.dollars = 4.0;
    run.chips = 10_000.0;
    run.end_round();
    assert_eq!(run.dollars, 13.0);
    assert_eq!(run.round_eval.unwrap().interest, 2.0);
}

#[test]
fn mr_bones_saves_without_paying_the_blind_reward() {
    let mut run = ready();
    run.add_joker(Joker::new("j_mr_bones").unwrap());
    run.chips = 3_000.0;
    run.end_round();
    assert_eq!(run.phase, Phase::RoundEval);
    assert_eq!(run.round_eval.unwrap().blind_reward, 0.0);
}

#[test]
fn every_joker_gain_path_applies_and_reverses_rule_changes() {
    let mut run = ready();
    let before = run.discards_left;
    let slot = run.add_joker(Joker::new("j_drunkard").unwrap());
    assert_eq!(run.discards_left, before + 1);
    run.sell_joker(slot).unwrap();
    assert_eq!(run.discards_left, before);
    assert_eq!(run.discards_per_round, 3);
    run.add_joker(Joker::new("j_chaos").unwrap());
    assert_eq!(run.free_rerolls, 1);
}

#[test]
fn selling_consumables_grows_campfire() {
    let mut run = ready();
    run.add_joker(Joker::new("j_campfire").unwrap());
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_mercury"));
    run.sell_consumable(0).unwrap();
    assert_eq!(run.jokers[0].x_mult, 1.25);
}

#[test]
fn expired_turtle_bean_releases_its_hand_size_bonus() {
    let mut run = ready();
    let mut bean = Joker::new("j_turtle_bean").unwrap();
    bean.extra = 1.0;
    run.add_joker(bean);
    assert_eq!(run.hand_size_bonus, 1);
    run.chips = 10_000.0;
    run.end_round();
    assert_eq!(run.hand_size_bonus, 0);
    assert!(run.jokers.iter().all(|joker| joker.key != "j_turtle_bean"));
}

#[test]
fn throwback_uses_prior_skips_on_the_first_hand_after_gain() {
    let mut run = ready();
    run.skips = 2;
    run.hand = vec![card("S_2")];
    run.add_joker(Joker::new("j_throwback").unwrap());
    let score = run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    assert_eq!(score.mult, 1.5);
}

#[test]
fn d6_tag_zeros_only_the_next_shop_base_and_preserves_later_tags() {
    let mut run = ready();
    run.tags.extend(["tag_d_six".to_owned(), "tag_d_six".to_owned()]);
    run.chips = 10_000.0;
    run.end_round();
    run.cash_out().unwrap();
    run.dollars = 100.0;
    assert_eq!(run.pay_for_reroll().unwrap(), 0.0);
    assert_eq!(run.pay_for_reroll().unwrap(), 1.0);
    assert_eq!(run.pay_for_reroll().unwrap(), 2.0);
    assert_eq!(run.tags.iter().filter(|tag| tag.as_str() == "tag_d_six").count(), 1);
}

fn voucher(key: &str) -> balatro_engine::run::shop::ShopCard {
    balatro_engine::run::shop::ShopCard {
        key: key.to_owned(), sort_id: 0, edition: None, eternal: false, perishable: false,
        rental: false, couponed: false, todo: None, enhancement: None, cost: 10.0,
    }
}

#[test]
fn voucher_purchase_uses_compacted_actual_index_and_rejections_are_atomic() {
    let mut run = ready();
    run.chips = 10_000.0;
    run.end_round();
    run.cash_out().unwrap();
    run.dollars = 100.0;
    run.shop.as_mut().unwrap().vouchers = vec![voucher("v_blank"), voucher("v_clearance_sale"), voucher("v_wasteful")];
    run.buy_voucher_index(0).unwrap();
    assert_eq!(run.shop.as_ref().unwrap().vouchers[0].key, "v_clearance_sale");
    run.buy_voucher_index(0).unwrap();
    assert!(run.used_vouchers.contains("v_clearance_sale"));
    assert_eq!(run.shop.as_ref().unwrap().vouchers.len(), 1);
    assert_eq!(run.shop.as_ref().unwrap().vouchers[0].key, "v_wasteful");
    let before = format!("{run:?}");
    assert!(run.buy_voucher_index(1).is_err());
    assert_eq!(format!("{run:?}"), before);
    run.dollars = 0.0;
    let before = format!("{run:?}");
    assert!(run.buy_voucher_index(0).is_err());
    assert_eq!(format!("{run:?}"), before);
}

#[test]
fn double_then_voucher_tag_creates_two_extra_objects_without_restocking_them() {
    let mut run = RunState::new("DOUBLEVOUCHER", 1);
    run.start_run();
    run.blind_tags = [Some("tag_double".to_owned()), Some("tag_voucher".to_owned())];
    run.skip_blind().unwrap();
    run.skip_blind().unwrap();
    assert_eq!(run.extra_voucher_keys.len(), 2);
    run.select_blind().unwrap();
    run.chips = run.blind.as_ref().unwrap().chips;
    run.end_round();
    run.cash_out().unwrap();
    assert!(run.extra_voucher_keys.is_empty());
    assert_eq!(run.shop.as_ref().unwrap().vouchers.len(), 3);
    run.dollars = 100.0;
    for left in [2, 1, 0] {
        run.buy_voucher_index(0).unwrap();
        assert_eq!(run.shop.as_ref().unwrap().vouchers.len(), left);
    }
}

#[test]
fn pack_transfer_keeps_birth_order_even_when_player_picks_in_reverse() {
    use balatro_engine::run::shop::{OpenPack, PackCard};
    let mut run = ready();
    run.deck.clear();
    run.hand.clear();
    let before = run.next_card_id;
    let make = |key: &str, sort_id| PackCard {
        key: key.to_owned(), sort_id, edition: None, seal: None, enhancement: None,
        todo: None, eternal: false, perishable: false, rental: false,
    };
    run.next_card_id += 5;
    run.add_joker(Joker::new("j_hologram").unwrap());
    run.open_pack = Some(OpenPack {
        key: "p_standard_jumbo_1".to_owned(), size: 5, choices_left: 2,
        contents: vec![make("S_2", before + 1), make("H_3", before + 2),
            make("C_A", before + 3), make("C_4", before + 4), make("D_K", before + 5)],
    });
    run.pack_return_phase = Phase::Shop;
    run.phase = Phase::BoosterOpened;
    let last_birth = run.next_card_id;
    run.pick_from_pack(4).unwrap();
    run.pick_from_pack(2).unwrap();
    let ace = run.deck.iter().find(|card| card.card.rank == balatro_engine::cards::Rank::Ace).unwrap();
    let king = run.deck.iter().find(|card| card.card.rank == balatro_engine::cards::Rank::King).unwrap();
    assert_eq!(ace.card.sort_id, before + 3);
    assert_eq!(king.card.sort_id, before + 5);
    assert!(ace.card.sort_id < king.card.sort_id);
    assert_eq!(run.next_card_id, last_birth);
    assert_eq!(run.jokers[0].x_mult, 1.5);
}

#[test]
fn stock_joker_transfer_preserves_birth_but_ankh_copy_gets_new_identity() {
    let mut run = ready();
    run.chips = 10_000.0;
    run.end_round();
    run.cash_out().unwrap();
    run.dollars = 100.0;
    let mut stock = voucher("j_joker");
    stock.sort_id = run.next_card_id + 1;
    run.next_card_id += 1;
    run.shop.as_mut().unwrap().jokers = vec![stock.clone()];
    let before = run.next_card_id;
    run.buy(&stock).unwrap();
    assert_eq!(run.jokers[0].sort_id, stock.sort_id);
    assert_eq!(run.next_card_id, before);
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_ankh"));
    run.use_consumable(0, &[]).unwrap();
    assert_eq!(run.jokers.len(), 2);
    assert_eq!(run.jokers[0].sort_id, stock.sort_id);
    assert!(run.jokers[1].sort_id > stock.sort_id);
}

#[test]
fn random_boss_and_madness_targets_follow_birth_identity_after_reorder() {
    for boss in ["bl_final_heart", "bl_small"] {
        let mut left = RunState::new("BIRTHTARGET", 1);
        left.start_run();
        if boss == "bl_final_heart" {
            left.boss_key = Some(boss.to_owned());
            left.blind_on_deck = BlindKind::Boss;
        }
        for key in ["j_joker", "j_zany", "j_madness", "j_greedy_joker"] {
            left.add_joker(Joker::new(key).unwrap());
        }
        let mut right = left.clone();
        right.rearrange_jokers(&[3, 2, 1, 0]).unwrap();
        left.select_blind().unwrap();
        right.select_blind().unwrap();
        let identities = |run: &RunState| {
            let mut ids: Vec<_> = run.jokers.iter().map(|joker| (joker.sort_id, joker.debuffed)).collect();
            ids.sort_unstable();
            ids
        };
        assert_eq!(identities(&left), identities(&right));
        let key = if boss == "bl_final_heart" { "crimson_heart" } else { "madness" };
        assert_eq!(left.rng.pseudorandom(key), right.rng.pseudorandom(key));
    }
    let mut left = ready();
    left.blind.as_mut().unwrap().key = "bl_final_bell".to_owned();
    for card in &mut left.hand { card.forced_selection = false; }
    let mut right = left.clone();
    let reversed: Vec<_> = (0..right.hand.len()).rev().collect();
    right.rearrange_hand(&reversed).unwrap();
    left.draw_to_hand();
    right.draw_to_hand();
    let selected = |run: &RunState| run.hand.iter().find(|card| card.forced_selection).unwrap().card.sort_id;
    assert_eq!(selected(&left), selected(&right));
    assert_eq!(left.rng.pseudorandom("cerulean_bell"), right.rng.pseudorandom("cerulean_bell"));
}
