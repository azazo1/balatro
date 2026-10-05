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
